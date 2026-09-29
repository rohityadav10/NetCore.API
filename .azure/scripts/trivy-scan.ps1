<#
.SYNOPSIS
    Runs a pinned Trivy container against a directory (fs) or a local Docker image, publishes
    JSON/SARIF (and optionally CycloneDX SBOM) reports, and fails on fixable HIGH/CRITICAL CVEs.
.DESCRIPTION
    Gate rule: any HIGH or CRITICAL vulnerability that HAS a fixed version fails the step.
    Unfixed ones (no patched version exists yet) can't be acted on by the team, so they stay
    visible in the reports without blocking. That is the same policy as `--ignore-unfixed`.
    Accepted risks go in .azure/.trivyignore.yaml with a reason and an expiry date.

    The scan runs once. The log table and the SARIF file are converted from its JSON output.
    Writes <ReportDir>/summary-trivy-<Name>.json for the PROD preflight (assert-release-ready.ps1).
.EXAMPLE
    ./trivy-scan.ps1 -ScanType image -Target myacr.azurecr.io/netcore-api:20260928.1 -Name image `
        -ReportDir ./reports -TrivyImage aquasec/trivy:0.74.0 -Sbom
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [ValidateSet('fs', 'image')] [string]$ScanType,
    # fs: a path relative to -SourceDir; image: an image reference present in the local Docker daemon.
    [Parameter(Mandatory = $true)] [string]$Target,
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$ReportDir,
    [Parameter(Mandatory = $true)] [string]$TrivyImage,
    [string]$SourceDir = (Get-Location).Path,
    [switch]$Sbom
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$reports = (Resolve-Path $ReportDir).Path
$source = (Resolve-Path $SourceDir).Path

$docker = @(
    'run', '--rm',
    '-v', '/var/run/docker.sock:/var/run/docker.sock',
    '-v', "${source}:/src:ro",
    '-v', "${reports}:/reports",
    '-e', 'TRIVY_NO_PROGRESS=true',
    $TrivyImage
)
$scanTarget = if ($ScanType -eq 'fs') { "/src/$Target" } else { $Target }
# fs scans include npm devDependencies: build tooling is part of the supply chain too.
$depScope = if ($ScanType -eq 'fs') { @('--include-dev-deps') } else { @() }
$ignore = @()
if (Test-Path (Join-Path $source '.azure/.trivyignore.yaml')) { $ignore = @('--ignorefile', '/src/.azure/.trivyignore.yaml') }

$json = "/reports/trivy-$Name.json"
Write-Host "Trivy $ScanType scan of $Target"
& docker @docker $ScanType --scanners vuln @depScope --format json --output $json @ignore $scanTarget
if ($LASTEXITCODE -ne 0) { throw "Trivy failed to run (exit $LASTEXITCODE)." }

& docker @docker convert --format table --severity 'HIGH,CRITICAL' $json
& docker @docker convert --format sarif --output "/reports/trivy-$Name.sarif" $json
if ($Sbom) {
    Write-Host "Generating CycloneDX SBOM"
    & docker @docker $ScanType --format cyclonedx --output "/reports/sbom-$Name.cdx.json" $scanTarget
    if ($LASTEXITCODE -ne 0) { throw "SBOM generation failed (exit $LASTEXITCODE)." }
}

$report = Get-Content -Raw (Join-Path $reports "trivy-$Name.json") | ConvertFrom-Json
$vulnerabilities = @($report.Results | ForEach-Object { $_.Vulnerabilities } | Where-Object { $_ })
$blocking = @($vulnerabilities | Where-Object { $_.Severity -in 'HIGH', 'CRITICAL' -and $_.FixedVersion })
$unfixed = @($vulnerabilities | Where-Object { $_.Severity -in 'HIGH', 'CRITICAL' -and -not $_.FixedVersion })

[ordered]@{
    check    = "trivy-$Name"
    target   = $Target
    high     = @($blocking | Where-Object Severity -eq 'HIGH').Count
    critical = @($blocking | Where-Object Severity -eq 'CRITICAL').Count
    unfixedHighOrCritical = $unfixed.Count
    passed   = ($blocking.Count -eq 0)
} | ConvertTo-Json | Set-Content (Join-Path $reports "summary-trivy-$Name.json")

if ($unfixed.Count -gt 0) {
    Write-Host "##vso[task.logissue type=warning]$($unfixed.Count) HIGH/CRITICAL finding(s) in $Target have no fix yet (tracked in the report, not blocking)."
}
if ($blocking.Count -gt 0) {
    foreach ($v in $blocking) {
        Write-Host "##vso[task.logissue type=error]$($v.Severity) $($v.VulnerabilityID) in $($v.PkgName) $($v.InstalledVersion) (fixed in $($v.FixedVersion))"
    }
    Write-Host "##vso[task.logissue type=error]Trivy gate FAILED: $($blocking.Count) fixable HIGH/CRITICAL vulnerabilities in $Target."
    exit 1
}
Write-Host "Trivy gate passed for $Target."
exit 0
