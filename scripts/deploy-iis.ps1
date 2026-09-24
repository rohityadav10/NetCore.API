<#
.SYNOPSIS
    Deploys application artifacts to on-premises IIS server.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.6 requirements:
    1. Stops IIS site / app pool
    2. Backs up current deployment
    3. Deploys new artifacts to the IIS site directory
    4. Updates configuration / web.config
    5. Starts IIS site / app pool
    6. Runs smoke test / health check
    7. Automatically rolls back if health check fails
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactPath,

    [Parameter(Mandatory = $true)]
    [string]$SitePath,

    [Parameter(Mandatory = $true)]
    [string]$AppPoolName,

    [Parameter(Mandatory = $true)]
    [string]$SiteName,

    [Parameter(Mandatory = $false)]
    [string]$BackupPath = "C:\inetpub\backups",

    [Parameter(Mandatory = $false)]
    [string]$HealthCheckUrl = "http://localhost:8080/WeatherForecast",

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = "SIT"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================="
Write-Host "Starting IIS Deployment for [$SiteName] to [$EnvironmentName]"
Write-Host "Artifact Source : $ArtifactPath"
Write-Host "Target Path     : $SitePath"
Write-Host "App Pool        : $AppPoolName"
Write-Host "=========================================================="

# Import IIS Administration module
if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw "WebAdministration PowerShell module is not installed. Please enable IIS management tools."
}
Import-Module WebAdministration

# Verify artifact source directory exists
if (-not (Test-Path $ArtifactPath)) {
    throw "Artifact directory not found at: $ArtifactPath"
}

# Ensure target and backup directories exist
if (-not (Test-Path $SitePath)) {
    New-Item -Path $SitePath -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $BackupPath)) {
    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CurrentBackupDir = Join-Path $BackupPath "$SiteName-$EnvironmentName-$Timestamp"

try {
    # 1. Stop IIS Site and Application Pool
    Write-Host "[1/6] Stopping IIS App Pool [$AppPoolName] and Site [$SiteName]..."
    if (Get-Item "IIS:\AppPools\$AppPoolName" -ErrorAction SilentlyContinue) {
        Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if (Get-Item "IIS:\Sites\$SiteName" -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # 2. Backup Current Deployment
    Write-Host "[2/6] Backing up current deployment to [$CurrentBackupDir]..."
    $ExistingFiles = Get-ChildItem -Path $SitePath -Exclude "backups"
    if ($ExistingFiles.Count -gt 0) {
        New-Item -Path $CurrentBackupDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$SitePath\*" -Destination $CurrentBackupDir -Recurse -Force
        Write-Host "Backup created successfully at: $CurrentBackupDir"
    } else {
        Write-Host "Target directory is empty. Skipping backup step."
    }

    # 3. Clean Target Directory (excluding locked logs if any)
    Write-Host "[3/6] Deploying new artifacts to [$SitePath]..."
    Get-ChildItem -Path $SitePath -Exclude "logs" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # 4. Copy New Artifacts
    Copy-Item -Path "$ArtifactPath\*" -Destination $SitePath -Recurse -Force
    Write-Host "Artifacts copied successfully."

    # 5. Start / Ensure IIS App Pool and Site exist
    Write-Host "[4/6] Ensuring IIS App Pool [$AppPoolName] and Site [$SiteName] are configured..."
    
    # Determine port from HealthCheckUrl (default 8080)
    $Port = 8080
    if ($HealthCheckUrl -match ":(\d+)") {
        $Port = [int]$matches[1]
    } elseif ($HealthCheckUrl -match "^https?://[^/:]+/") {
        $Port = 80
    }

    # Ensure App Pool exists with No Managed Code (.NET Core / Angular requirement)
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        Write-Host "Auto-creating IIS App Pool [$AppPoolName] (No Managed Code)..."
        New-WebAppPool -Name $AppPoolName
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value ""
    }

    # Ensure Site exists
    if (-not (Test-Path "IIS:\Sites\$SiteName")) {
        Write-Host "Auto-creating IIS Web Site [$SiteName] on port $Port bound to [$SitePath]..."
        New-WebSite -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $AppPoolName
    } else {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name "physicalPath" -Value $SitePath
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name "applicationPool" -Value $AppPoolName
    }

    # Start App Pool and Site
    Write-Host "Starting App Pool and Web Site..."
    Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
    Start-WebSite -Name $SiteName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    # 6. Execute Health Check
    Write-Host "[5/6] Running health check against [$HealthCheckUrl]..."
    $HealthScript = Join-Path $PSScriptRoot "health-check.ps1"
    if (Test-Path $HealthScript) {
        & $HealthScript -Url $HealthCheckUrl -MaxRetries 6 -DelaySeconds 5
    } else {
        # Inline health check fallback
        $response = Invoke-WebRequest -Uri $HealthCheckUrl -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -ne 200) {
            throw "Health check returned status code: $($response.StatusCode)"
        }
    }

    Write-Host "[6/6] Deployment and health check PASSED for [$SiteName] ($EnvironmentName)!"
    Write-Host "=========================================================="
}
catch {
    Write-Error "DEPLOYMENT FAILED: $_"
    Write-Warning "Initiating automatic rollback to previous backup..."

    $RollbackScript = Join-Path $PSScriptRoot "rollback-iis.ps1"
    if ((Test-Path $RollbackScript) -and (Test-Path $CurrentBackupDir)) {
        & $RollbackScript -BackupDir $CurrentBackupDir -SitePath $SitePath -AppPoolName $AppPoolName -SiteName $SiteName
    } else {
        Write-Warning "No rollback script or backup directory available to restore."
    }
    exit 1
}
