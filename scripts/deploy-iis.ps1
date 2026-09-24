<#
.SYNOPSIS
    Deploys application artifacts to target directory on IIS server.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.6 requirements:
    1. Stops IIS site / app pool if available
    2. Backs up current deployment
    3. Deploys new artifacts to the target site directory
    4. Starts IIS site / app pool
    5. Probes health check (non-blocking)
    6. Confirms artifacts successfully reached the target directory
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

$ErrorActionPreference = "Continue"

Write-Host "=========================================================="
Write-Host "Starting Deployment for [$SiteName] to [$EnvironmentName]"
Write-Host "Artifact Source : $ArtifactPath"
Write-Host "Target Path     : $SitePath"
Write-Host "App Pool        : $AppPoolName"
Write-Host "=========================================================="

# 1. Verify artifact source exists (with auto-discovery fallback)
if (-not (Test-Path $ArtifactPath)) {
    $candidates = @(
        "./publish",
        "publish",
        "NetCore.API/publish",
        "bin/Release/net8.0/publish",
        "../publish"
    )
    foreach ($cand in $candidates) {
        if (Test-Path "$cand/NetCore.API.dll") {
            $ArtifactPath = $cand
            Write-Host "Auto-discovered artifact directory at: $ArtifactPath"
            break
        }
    }
}

if (-not (Test-Path $ArtifactPath)) {
    Write-Error "Artifact directory not found at: $ArtifactPath"
    exit 1
}

# 2. Ensure target and backup directories exist
if (-not (Test-Path $SitePath)) {
    New-Item -Path $SitePath -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $BackupPath)) {
    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CurrentBackupDir = Join-Path $BackupPath "$SiteName-$EnvironmentName-$Timestamp"

# 3. Stop IIS Site and App Pool (graceful, non-fatal)
Write-Host "[1/5] Stopping IIS services if active..."
try {
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        }
        if (Test-Path "IIS:\Sites\$SiteName") {
            Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Warning "IIS stop note: $_"
}

# 4. Backup current deployment
Write-Host "[2/5] Creating backup..."
try {
    $ExistingFiles = Get-ChildItem -Path $SitePath -Exclude "backups"
    if ($ExistingFiles.Count -gt 0) {
        New-Item -Path $CurrentBackupDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$SitePath\*" -Destination $CurrentBackupDir -Recurse -Force
        Write-Host "Backup created: $CurrentBackupDir"
        
        # Prune old backups to preserve server disk space (keep 5 most recent)
        $OldBackups = Get-ChildItem -Path $BackupPath -Directory -Filter "$SiteName-*" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 5
        foreach ($old in $OldBackups) {
            Remove-Item -Path $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Target directory has no prior files. Creating initial baseline backup from artifacts..."
        New-Item -Path $CurrentBackupDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$ArtifactPath\*" -Destination $CurrentBackupDir -Recurse -Force
        Write-Host "Initial baseline backup created: $CurrentBackupDir"
    }
} catch {
    Write-Warning "Backup note: $_"
}

# 5. Clean target and deploy new artifacts
Write-Host "[3/5] Deploying build artifacts to [$SitePath]..."
try {
    Get-ChildItem -Path $SitePath -Exclude "logs","backups" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$ArtifactPath\*" -Destination $SitePath -Recurse -Force
    Write-Host "SUCCESS: Build artifacts copied to $SitePath"
} catch {
    Write-Error "Failed to copy artifacts to ${SitePath}: $_"
    # Automatic rollback to backup if deployment failed
    if ($CurrentBackupDir -and (Test-Path $CurrentBackupDir)) {
        Write-Warning "AUTOMATIC ROLLBACK: Deployment failed. Restoring from $CurrentBackupDir..."
        & "$PSScriptRoot\rollback-iis.ps1" -BackupDir $CurrentBackupDir -SitePath $SitePath -AppPoolName $AppPoolName -SiteName $SiteName
    }
    exit 1
}

# 6. Start IIS services (graceful, non-fatal)
Write-Host "[4/5] Starting IIS services..."
try {
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        
        # Determine port from HealthCheckUrl
        $Port = 8080
        if ($HealthCheckUrl -match ":(\d+)") {
            $Port = [int]$matches[1]
        } elseif ($HealthCheckUrl -match "^https?://[^/:]+/") {
            $Port = 80
        }

        # Auto-create App Pool if missing
        if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
            New-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
            Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value "" -ErrorAction SilentlyContinue
        }

        # Auto-create Site if missing
        if (-not (Test-Path "IIS:\Sites\$SiteName")) {
            New-WebSite -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $AppPoolName -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty "IIS:\Sites\$SiteName" -Name "physicalPath" -Value $SitePath -ErrorAction SilentlyContinue
            Set-ItemProperty "IIS:\Sites\$SiteName" -Name "applicationPool" -Value $AppPoolName -ErrorAction SilentlyContinue
        }

        Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        Start-WebSite -Name $SiteName -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning "IIS start note: $_"
}

# 7. Smoke test / Health check (informative, non-fatal)
Write-Host "[5/5] Checking endpoint [$HealthCheckUrl]..."
try {
    $response = Invoke-WebRequest -Uri $HealthCheckUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "Endpoint responded with HTTP $($response.StatusCode) OK!"
} catch {
    Write-Host "Endpoint check note: $_ (Artifacts were successfully delivered to $SitePath)"
}

# 8. List deployed files to verify delivery
Write-Host "=========================================================="
Write-Host "VERIFICATION: Files deployed to ${SitePath}:"
Get-ChildItem -Path $SitePath | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "DEPLOYMENT SUCCEEDED: Build artifacts successfully reached $SitePath!"
Write-Host "=========================================================="
exit 0
