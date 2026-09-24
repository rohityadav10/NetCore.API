<#
.SYNOPSIS
    Rolls back IIS deployment to the last known good backup.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.6 / 4.1 rollback requirement.
    Can restore a specified backup directory, or automatically restore
    the most recent backup from C:\inetpub\backups.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$BackupDir,

    [Parameter(Mandatory = $false)]
    [string]$SitePath = "C:\inetpub\wwwroot\api",

    [Parameter(Mandatory = $false)]
    [string]$AppPoolName = "NetCoreApiAppPool",

    [Parameter(Mandatory = $false)]
    [string]$SiteName = "NetCoreAPI",

    [Parameter(Mandatory = $false)]
    [string]$BackupRoot = "C:\inetpub\backups"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================="
Write-Host "INITIATING ROLLBACK for [$SiteName]"
Write-Host "Site Path    : $SitePath"
Write-Host "App Pool     : $AppPoolName"
Write-Host "=========================================================="

# Auto-locate latest backup if BackupDir is not provided or set to 'latest'
if (-not $BackupDir -or $BackupDir -eq "latest") {
    Write-Host "No specific backup directory supplied. Searching for latest backup in [$BackupRoot]..."
    if (Test-Path $BackupRoot) {
        $LatestBackup = Get-ChildItem -Path $BackupRoot -Directory -Filter "$SiteName-*" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($LatestBackup) {
            $BackupDir = $LatestBackup.FullName
            Write-Host "Found latest backup: $BackupDir"
        } else {
            # Try any backup folder in root
            $AnyBackup = Get-ChildItem -Path $BackupRoot -Directory |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($AnyBackup) {
                $BackupDir = $AnyBackup.FullName
                Write-Host "Found backup: $BackupDir"
            }
        }
    }
}

if (-not $BackupDir -or -not (Test-Path $BackupDir)) {
    Write-Error "CRITICAL: Backup directory does not exist or was not found: $BackupDir. Cannot rollback."
    exit 1
}

Write-Host "Restoring from Backup : $BackupDir"
Write-Host "Target Directory      : $SitePath"
Write-Host "----------------------------------------------------------"

try {
    # 1. Stop App Pool and Site gracefully
    Write-Host "[1/4] Stopping IIS services..."
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        }
        if (Test-Path "IIS:\Sites\$SiteName") {
            Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2

    # 2. Clear current failed deployment
    Write-Host "[2/4] Cleaning failed deployment files from ${SitePath}..."
    if (Test-Path $SitePath) {
        Get-ChildItem -Path $SitePath -Exclude "logs","backups" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -Path $SitePath -ItemType Directory -Force | Out-Null
    }

    # 3. Restore files from backup
    Write-Host "[3/4] Restoring files from backup [$BackupDir] to [$SitePath]..."
    Copy-Item -Path "$BackupDir\*" -Destination $SitePath -Recurse -Force
    Write-Host "SUCCESS: Backup files restored successfully."

    # 4. Restart App Pool and Site
    Write-Host "[4/4] Starting IIS services..."
    if (Get-Module -ListAvailable -Name WebAdministration) {
        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        }
        if (Test-Path "IIS:\Sites\$SiteName") {
            Start-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        }
    }

    Write-Host "=========================================================="
    Write-Host "ROLLBACK COMPLETED: Application restored to previous state from $BackupDir"
    Write-Host "=========================================================="
    exit 0
}
catch {
    Write-Error "CRITICAL: Rollback failed: $_"
    exit 1
}
