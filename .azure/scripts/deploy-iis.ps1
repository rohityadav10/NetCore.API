<#
.SYNOPSIS
    Deploys one build to an IIS site in a side-by-side release folder, smoke-tests it, and
    rolls back automatically if anything fails.
.DESCRIPTION
    Layout on the IIS server (ReleasesRoot defaults to C:\inetpub\ado\<SiteName>):

        releases\<BuildNumber>\      one folder per deployed build
        deployments.log              one line per deploy / rollback (audit trail)

    The site's physicalPath points at exactly one release folder. The folders of earlier
    builds are the backups, so a rollback is a path switch plus an app-pool restart, not
    a file copy. Steps (exercise section 3.6):

        1. Copy the artifact into a NEW release folder. The live site is untouched meanwhile.
        2. Write environment-specific settings into that folder:
             AspNetCore -> web.config <aspNetCore><environmentVariables>
             Spa        -> config.json, plus a web.config (SPA fallback routing, no-cache
                           for index.html/config.json, security headers)
        3. Create the app pool / site on first deploy. Otherwise record the live folder: that
           is the backup to return to.
        4. Stop the app pool and site.
        5. Point the site at the new release folder.
        6. Start the app pool and site.
        7. Smoke test with health-check.ps1: liveness, plus the served build version.
        8. On any failure in 4-7: switch back to the previous folder, restart, fail the run.

    Runs on the IIS server itself (the Azure DevOps agent in the OnPrem-IIS pool). With
    -ComputerName, the artifact and these scripts are copied over PowerShell remoting (WinRM)
    and the same steps run on that server instead (jump-box mode).

    Needs: Windows PowerShell 5.1+, the IIS WebAdministration module, local admin rights;
    for AspNetCore apps also the ASP.NET Core Hosting Bundle.
.EXAMPLE
    ./deploy-iis.ps1 -ArtifactPath .\api-drop -SiteName ado-netcore-api-sit -AppPoolName ado-netcore-api-sit `
        -Port 8181 -BuildNumber 20260928.1 -HealthCheckUrl http://localhost:8181/health `
        -VersionUrl http://localhost:8181/api/AppStatus `
        -EnvironmentVariablesJson '{"ASPNETCORE_ENVIRONMENT":"SIT"}'
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ArtifactPath,
    [Parameter(Mandatory = $true)] [string]$SiteName,
    [Parameter(Mandatory = $true)] [string]$AppPoolName,
    [Parameter(Mandatory = $true)] [int]$Port,
    [Parameter(Mandatory = $true)] [string]$BuildNumber,
    [Parameter(Mandatory = $true)] [string]$HealthCheckUrl,

    # URL returning JSON with a "version" field. It must equal -BuildNumber for the deploy to pass.
    [string]$VersionUrl = '',

    [ValidateSet('AspNetCore', 'Spa')]
    [string]$AppType = 'AspNetCore',

    # AspNetCore: JSON object of environment variables written into web.config.
    [string]$EnvironmentVariablesJson = '{}',

    # AspNetCore: comma-separated names of PROCESS environment variables that hold secrets
    # (mapped in by the pipeline from a variable group). Their values go into web.config the
    # same way, but never pass through the command line or the logs.
    [string]$SecretVariableNames = '',

    # Spa: JSON written as the site's config.json.
    [string]$SpaConfigJson = '',

    [string]$ReleasesRoot = '',
    [int]$KeepReleases = 5,

    # Remote (jump-box) mode. Credentials come from IIS_DEPLOY_USERNAME / IIS_DEPLOY_PASSWORD;
    # when those are unset, the agent's own Windows identity is used (Kerberos).
    [string]$ComputerName = '',
    [switch]$UseSsl
)

$ErrorActionPreference = 'Stop'

function Get-SecretVariables([string]$names) {
    $result = @{}
    foreach ($name in ($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $value = [Environment]::GetEnvironmentVariable($name)
        # An undefined pipeline variable arrives as the literal text "$(Name)".
        if ([string]::IsNullOrEmpty($value) -or $value.StartsWith('$(')) {
            Write-Host "##vso[task.logissue type=warning]Secret '$name' is not set in the variable group; skipping it."
            continue
        }
        $result[$name] = $value
    }
    return $result
}

function ConvertFrom-JsonObject([string]$json) {
    $table = @{}
    if ([string]::IsNullOrWhiteSpace($json)) { return $table }
    $parsed = $json | ConvertFrom-Json
    foreach ($property in $parsed.PSObject.Properties) { $table[$property.Name] = [string]$property.Value }
    return $table
}

# ── Remote (jump-box) mode: ship everything to the target and run this script there ──
if ($ComputerName) {
    Write-Host "Remote deployment to $ComputerName over PowerShell remoting (SSL: $UseSsl)"
    $sessionArgs = @{ ComputerName = $ComputerName; UseSSL = [bool]$UseSsl }
    if ($env:IIS_DEPLOY_USERNAME -and -not $env:IIS_DEPLOY_USERNAME.StartsWith('$(')) {
        $password = ConvertTo-SecureString $env:IIS_DEPLOY_PASSWORD -AsPlainText -Force
        $sessionArgs.Credential = New-Object System.Management.Automation.PSCredential($env:IIS_DEPLOY_USERNAME, $password)
    }
    $session = New-PSSession @sessionArgs
    try {
        $stage = Invoke-Command -Session $session -ScriptBlock {
            $path = Join-Path $env:TEMP ('ado-deploy-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path "$path\artifact", "$path\scripts" -Force | Out-Null
            $path
        }
        Copy-Item -Path (Join-Path $ArtifactPath '*') -Destination "$stage\artifact" -Recurse -ToSession $session
        Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination "$stage\scripts" -ToSession $session

        # Secrets are resolved here, where the pipeline mapped them, and travel inside the
        # (encrypted) remoting channel as part of the environment-variable map.
        $environment = ConvertFrom-JsonObject $EnvironmentVariablesJson
        $secrets = Get-SecretVariables $SecretVariableNames
        foreach ($key in $secrets.Keys) { $environment[$key] = $secrets[$key] }

        $remoteParams = @{
            ArtifactPath             = "$stage\artifact"
            SiteName                 = $SiteName
            AppPoolName              = $AppPoolName
            Port                     = $Port
            BuildNumber              = $BuildNumber
            HealthCheckUrl           = $HealthCheckUrl
            VersionUrl               = $VersionUrl
            AppType                  = $AppType
            EnvironmentVariablesJson = ($environment | ConvertTo-Json -Compress)
            SpaConfigJson            = $SpaConfigJson
            ReleasesRoot             = $ReleasesRoot
            KeepReleases             = $KeepReleases
        }
        $exitCode = Invoke-Command -Session $session -ScriptBlock {
            param($scriptPath, $params, $stagePath)
            & $scriptPath @params | Out-Host
            $code = $LASTEXITCODE
            Remove-Item -Path $stagePath -Recurse -Force -ErrorAction SilentlyContinue
            $code
        } -ArgumentList "$stage\scripts\deploy-iis.ps1", $remoteParams, $stage
        exit ([int]$exitCode)
    }
    finally {
        Remove-PSSession $session
    }
}

# ── Local mode: this machine is the IIS server ────────────────────────────────────────
Import-Module WebAdministration

if (-not $ReleasesRoot) { $ReleasesRoot = Join-Path $env:SystemDrive "inetpub\ado\$SiteName" }
$releasesDir = Join-Path $ReleasesRoot 'releases'
$logFile = Join-Path $ReleasesRoot 'deployments.log'

function Write-DeployLog([string]$outcome, [string]$path) {
    $line = '{0:u}  {1,-10} build={2}  path={3}' -f (Get-Date), $outcome, $BuildNumber, $path
    Add-Content -Path $logFile -Value $line
}

# Windows PowerShell 5.1's Set-Content -Encoding UTF8 writes a byte-order mark, which breaks
# JSON parsing of config.json (the version smoke test). Write plain UTF-8 instead.
function Write-Utf8NoBom([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Wait-AppPoolState([string]$name, [string]$state) {
    for ($i = 0; $i -lt 30; $i++) {
        if ((Get-WebAppPoolState -Name $name).Value -eq $state) { return }
        Start-Sleep -Seconds 1
    }
    throw "App pool '$name' did not reach state '$state' within 30s."
}

function Set-AspNetCoreEnvironment([string]$webConfigPath, [hashtable]$variables) {
    [xml]$config = Get-Content -Path $webConfigPath -Raw
    $aspNetCore = $config.SelectSingleNode('//aspNetCore')
    if (-not $aspNetCore) { throw "web.config has no <aspNetCore> element: is this an ASP.NET Core publish output?" }
    $container = $aspNetCore.SelectSingleNode('environmentVariables')
    if (-not $container) {
        $container = $config.CreateElement('environmentVariables')
        [void]$aspNetCore.AppendChild($container)
    }
    foreach ($name in ($variables.Keys | Sort-Object)) {
        $existing = $container.SelectSingleNode("environmentVariable[@name='$name']")
        if ($existing) { [void]$container.RemoveChild($existing) }
        $element = $config.CreateElement('environmentVariable')
        $element.SetAttribute('name', $name)
        $element.SetAttribute('value', $variables[$name])
        [void]$container.AppendChild($element)
    }
    $config.Save($webConfigPath)
}

function Write-SpaWebConfig([string]$path) {
    # The SPA fallback needs the IIS URL Rewrite module. An unknown <rewrite> section makes
    # IIS answer 500.19 for every request, so the rule is only written when the module exists.
    $hasRewrite = [bool](Get-WebGlobalModule -Name 'RewriteModule' -ErrorAction SilentlyContinue)
    $rewrite = ''
    if ($hasRewrite) {
        $rewrite = @'
    <rewrite>
      <rules>
        <rule name="SPA fallback to index.html" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
          </conditions>
          <action type="Rewrite" url="/index.html" />
        </rule>
      </rules>
    </rewrite>
'@
    }
    else {
        Write-Host "##vso[task.logissue type=warning]IIS URL Rewrite is not installed: deep links (e.g. /some/route) will 404 until it is."
    }
    $noCache = '<system.webServer><staticContent><clientCache cacheControlMode="DisableCache" /></staticContent></system.webServer>'
    @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by .azure/scripts/deploy-iis.ps1 for build $BuildNumber. Do not edit on the server. -->
<configuration>
  <system.webServer>
$rewrite
    <staticContent>
      <remove fileExtension=".json" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
    </staticContent>
    <httpProtocol>
      <customHeaders>
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="Referrer-Policy" value="strict-origin-when-cross-origin" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
  <location path="index.html">$noCache</location>
  <location path="config.json">$noCache</location>
</configuration>
"@ | ForEach-Object { Write-Utf8NoBom $path $_ }
}

function Switch-SiteToRelease([string]$path) {
    Write-Host "Stopping app pool '$AppPoolName' and site '$SiteName'"
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $AppPoolName
        Wait-AppPoolState $AppPoolName 'Stopped'
    }
    Stop-Website -Name $SiteName
    Write-Host "Pointing '$SiteName' at $path"
    Set-ItemProperty -Path "IIS:\Sites\$SiteName" -Name physicalPath -Value $path
    Write-Host "Starting app pool and site"
    Start-WebAppPool -Name $AppPoolName
    Wait-AppPoolState $AppPoolName 'Started'
    Start-Website -Name $SiteName
}

Write-Host "=== Deploying build $BuildNumber to IIS site '$SiteName' (port $Port, $AppType) ==="

# 1. New release folder ------------------------------------------------------------------
$marker = if ($AppType -eq 'Spa') { 'index.html' } else { 'web.config' }
if (-not (Test-Path (Join-Path $ArtifactPath $marker))) {
    throw "Artifact at '$ArtifactPath' has no $marker; wrong artifact for a $AppType deployment?"
}
New-Item -ItemType Directory -Path $releasesDir -Force | Out-Null
$releaseDir = Join-Path $releasesDir $BuildNumber
if (Test-Path $releaseDir) {
    # A re-run of the same build: never overwrite a folder that may be live.
    $releaseDir = '{0}-{1:HHmmss}' -f $releaseDir, (Get-Date)
}
Write-Host "[1/8] Copying artifact to $releaseDir"
New-Item -ItemType Directory -Path $releaseDir | Out-Null
Copy-Item -Path (Join-Path $ArtifactPath '*') -Destination $releaseDir -Recurse -Force

# 2. Environment-specific settings ----------------------------------------------------------
Write-Host "[2/8] Writing environment settings"
if ($AppType -eq 'AspNetCore') {
    $variables = ConvertFrom-JsonObject $EnvironmentVariablesJson
    $secrets = Get-SecretVariables $SecretVariableNames
    foreach ($key in $secrets.Keys) { $variables[$key] = $secrets[$key] }
    Set-AspNetCoreEnvironment (Join-Path $releaseDir 'web.config') $variables
    Write-Host "  web.config environment variables: $((@($variables.Keys) | Sort-Object) -join ', ')"
}
else {
    if ($SpaConfigJson) {
        $null = $SpaConfigJson | ConvertFrom-Json   # refuse to ship malformed JSON
        Write-Utf8NoBom (Join-Path $releaseDir 'config.json') $SpaConfigJson
        Write-Host "  config.json: $SpaConfigJson"
    }
    Write-SpaWebConfig (Join-Path $releaseDir 'web.config')
}

# 3. Provision on first deploy, or remember the live folder --------------------------------------
$previousDir = $null
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    Write-Host "[3/8] Creating app pool '$AppPoolName' (No Managed Code)"
    New-WebAppPool -Name $AppPoolName | Out-Null
    Set-ItemProperty -Path "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value ''
}
if (-not (Test-Path "IIS:\Sites\$SiteName")) {
    Write-Host "[3/8] Creating site '$SiteName' on port $Port"
    New-Website -Name $SiteName -Port $Port -PhysicalPath $releaseDir -ApplicationPool $AppPoolName | Out-Null
}
else {
    $previousDir = [Environment]::ExpandEnvironmentVariables((Get-Item "IIS:\Sites\$SiteName").physicalPath)
    Write-Host "[3/8] Live release (rollback target): $previousDir"
    Set-ItemProperty -Path "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
}

# 4-7. Switch and verify, with rollback on any failure ----------------------------------------
try {
    Write-Host "[4-6/8] Switching the site to the new release"
    Switch-SiteToRelease $releaseDir

    Write-Host "[7/8] Smoke test"
    & (Join-Path $PSScriptRoot 'health-check.ps1') -Url $HealthCheckUrl
    if ($LASTEXITCODE -ne 0) { throw "Liveness check failed: $HealthCheckUrl" }
    if ($VersionUrl) {
        & (Join-Path $PSScriptRoot 'health-check.ps1') -Url $VersionUrl -ExpectedVersion $BuildNumber -MaxRetries 3
        if ($LASTEXITCODE -ne 0) { throw "The site is up but is not serving build $BuildNumber ($VersionUrl)" }
    }
}
catch {
    Write-Host "##vso[task.logissue type=error]Deployment of $BuildNumber failed: $($_.Exception.Message)"
    if ($previousDir -and (Test-Path $previousDir)) {
        Write-Host "[8/8] AUTOMATIC ROLLBACK to $previousDir"
        Switch-SiteToRelease $previousDir
        & (Join-Path $PSScriptRoot 'health-check.ps1') -Url $HealthCheckUrl -MaxRetries 6 | Out-Host
        # Kept (renamed) for diagnosis; rollback-iis.ps1 never picks a *.failed folder.
        Rename-Item -Path $releaseDir -NewName ((Split-Path $releaseDir -Leaf) + '.failed') -ErrorAction SilentlyContinue
        Write-DeployLog 'ROLLEDBACK' $previousDir
    }
    else {
        Write-Host "[8/8] No previous release to roll back to (first deployment)."
        Write-DeployLog 'FAILED' $releaseDir
    }
    exit 1
}

Write-DeployLog 'DEPLOYED' $releaseDir

# Retention: keep the newest $KeepReleases folders, and never the live or previous one.
$keep = @($releaseDir, $previousDir) | Where-Object { $_ }
Get-ChildItem -Path $releasesDir -Directory |
    Sort-Object CreationTime -Descending |
    Select-Object -Skip $KeepReleases |
    Where-Object { $keep -notcontains $_.FullName } |
    ForEach-Object {
        Write-Host "Pruning old release $($_.Name)"
        Remove-Item -Path $_.FullName -Recurse -Force
    }

Write-Host "=== Build $BuildNumber is live on '$SiteName' (previous: $(if ($previousDir) { $previousDir } else { 'none' })) ==="
exit 0
