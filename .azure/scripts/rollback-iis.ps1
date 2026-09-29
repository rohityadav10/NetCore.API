<#
.SYNOPSIS
    Manual IIS rollback: points a site back at an earlier release folder created by
    deploy-iis.ps1, restarts it and (optionally) smoke-tests it.
.DESCRIPTION
    deploy-iis.ps1 already rolls back on its own when a deployment fails its health check.
    This script is for the other case: a release that passed its checks but turns out to be
    bad later. It is run by the manual pipeline .azure/rollback.yml, or by hand on the server.

    -ToBuild 'previous' (default) picks the newest release folder that is neither live nor
    marked .failed. Otherwise give the build number, e.g. 20260928.3.
.EXAMPLE
    ./rollback-iis.ps1 -SiteName ado-netcore-api-sit -AppPoolName ado-netcore-api-sit `
        -HealthCheckUrl http://localhost:8181/health
    ./rollback-iis.ps1 -SiteName ado-netcore-api-sit -AppPoolName ado-netcore-api-sit -ToBuild 20260927.2
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$SiteName,
    [Parameter(Mandatory = $true)] [string]$AppPoolName,
    [string]$ToBuild = 'previous',
    [string]$HealthCheckUrl = '',
    [string]$ReleasesRoot = ''
)

$ErrorActionPreference = 'Stop'
# IIS's configuration API (WebAdministration) exists only for 64-bit processes. Under 32-bit
# PowerShell (e.g. the x86 build of the Azure DevOps agent) every IIS call fails with
# "80040154 Class not registered", so stop here with the actual cause.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host "##vso[task.logissue type=error]32-bit PowerShell cannot manage IIS. Install the x64 Azure DevOps agent (vsts-agent-win-x64) on this server."
    exit 1
}
Import-Module WebAdministration

if (-not $ReleasesRoot) { $ReleasesRoot = Join-Path $env:SystemDrive "inetpub\ado\$SiteName" }
$releasesDir = Join-Path $ReleasesRoot 'releases'
if (-not (Test-Path "IIS:\Sites\$SiteName")) { throw "IIS site '$SiteName' does not exist." }
if (-not (Test-Path $releasesDir)) { throw "No releases folder at ${releasesDir}: nothing to roll back to." }

$liveDir = [Environment]::ExpandEnvironmentVariables((Get-Item "IIS:\Sites\$SiteName").physicalPath).TrimEnd('\')
Write-Host "Live release: $liveDir"

if ($ToBuild -eq 'previous') {
    $target = Get-ChildItem -Path $releasesDir -Directory |
        Where-Object { $_.FullName.TrimEnd('\') -ne $liveDir -and $_.Name -notlike '*.failed' } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1
    if (-not $target) { throw "No earlier release folder in $releasesDir to roll back to." }
    $targetDir = $target.FullName
}
else {
    $targetDir = Join-Path $releasesDir $ToBuild
    if (-not (Test-Path $targetDir)) {
        $available = (Get-ChildItem -Path $releasesDir -Directory | Select-Object -ExpandProperty Name) -join ', '
        throw "Release '$ToBuild' not found. Available: $available"
    }
}

if ($targetDir.TrimEnd('\') -eq $liveDir) { throw "$targetDir is already live." }

Write-Host "Rolling '$SiteName' back to $targetDir"
if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') { Stop-WebAppPool -Name $AppPoolName }
for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
Stop-Website -Name $SiteName
Set-ItemProperty -Path "IIS:\Sites\$SiteName" -Name physicalPath -Value $targetDir
Start-WebAppPool -Name $AppPoolName
Start-Website -Name $SiteName

Add-Content -Path (Join-Path $ReleasesRoot 'deployments.log') `
    -Value ('{0:u}  {1,-10} to={2}  from={3}' -f (Get-Date), 'ROLLBACK', $targetDir, $liveDir)

if ($HealthCheckUrl) {
    & (Join-Path $PSScriptRoot 'health-check.ps1') -Url $HealthCheckUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##vso[task.logissue type=error]Rolled back to $targetDir but it is not healthy either."
        exit 1
    }
}

Write-Host "Rollback complete: '$SiteName' now serves $targetDir"
exit 0
