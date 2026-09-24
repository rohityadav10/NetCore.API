<#
.SYNOPSIS
    Rolls back IIS deployment to the last known good backup.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.6 / 4.1 rollback requirement.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$BackupDir,

    [Parameter(Mandatory = $true)]
    [string]$SitePath,

    [Parameter(Mandatory = $true)]
    [string]$AppPoolName,

    [Parameter(Mandatory = $true)]
    [string]$SiteName
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================="
Write-Host "INITIATING AUTOMATIC ROLLBACK for [$SiteName]"
Write-Host "Restoring from Backup : $BackupDir"
Write-Host "Target Directory      : $SitePath"
Write-Host "=========================================================="

if (-not (Test-Path $BackupDir)) {
    throw "Backup directory does not exist: $BackupDir. Cannot rollback."
}

Import-Module WebAdministration

try {
    # 1. Stop App Pool and Site
    Write-Host "Stopping IIS App Pool and Site..."
    if (Get-Item "IIS:\AppPools\$AppPoolName" -ErrorAction SilentlyContinue) {
        Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
    }
    if (Get-Item "IIS:\Sites\$SiteName" -ErrorAction SilentlyContinue) {
        Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # 2. Clear current failed deployment
    Write-Host "Cleaning failed deployment files from $SitePath..."
    Get-ChildItem -Path $SitePath -Exclude "logs","backups" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # 3. Restore files from backup
    Write-Host "Restoring backup files..."
    Copy-Item -Path "$BackupDir\*" -Destination $SitePath -Recurse -Force

    # 4. Restart App Pool and Site
    Write-Host "Starting IIS App Pool and Site..."
    if (Get-Item "IIS:\AppPools\$AppPoolName" -ErrorAction SilentlyContinue) {
        Start-WebAppPool -Name $AppPoolName
    }
    if (Get-Item "IIS:\Sites\$SiteName" -ErrorAction SilentlyContinue) {
        Start-WebSite -Name $SiteName
    }

    Write-Host "Rollback completed successfully! Application restored to previous state."
    Write-Host "=========================================================="
}
catch {
    Write-Error "CRITICAL: Rollback failed: $_"
    exit 1
}
