<#
.SYNOPSIS
    PROD preflight: re-verifies, just before the production deployment, the evidence the Build
    stage recorded (the summary-*.json files published as the quality-* artifacts).
.DESCRIPTION
    Runs after the PROD approval, days after the build perhaps, so it checks:
      - every recorded gate passed
      - tests: at least one ran, none failed (100% pass rate)
      - coverage >= the threshold in force NOW (raising the bar blocks older builds)
      - no blocking SAST / dependency / image findings were recorded
    The fresh re-scan of the exact image digest (catching CVEs published since the build) is a
    separate step in the same job, using trivy-scan.ps1.
    Also writes a Markdown summary onto the run's Summary tab.
#>
[CmdletBinding()]
param (
    # Folder the quality-* artifacts were downloaded into (searched recursively).
    [Parameter(Mandatory = $true)] [string]$EvidenceDir,
    [Parameter(Mandatory = $true)] [double]$CoverageThreshold,
    # Checks that must be present, e.g. tests,sast,dependencies,trivy-image
    [Parameter(Mandatory = $true)] [string[]]$RequiredChecks
)

$ErrorActionPreference = 'Stop'
# Accept both an array and one comma-separated string (pwsh -File passes the latter).
$RequiredChecks = @($RequiredChecks -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$problems = @()
$rows = @()

$summaries = @{}
Get-ChildItem -Path $EvidenceDir -Recurse -Filter 'summary-*.json' | ForEach-Object {
    $s = Get-Content -Raw $_.FullName | ConvertFrom-Json
    $summaries[$s.check] = $s
}

foreach ($check in $RequiredChecks) {
    $s = $summaries[$check]
    if (-not $s) { $problems += "No evidence for '$check': the Build stage did not record it."; $rows += "| $check | missing |"; continue }
    if (-not $s.passed) { $problems += "'$check' was recorded as FAILED." }
    $detail = ($s.PSObject.Properties | Where-Object { $_.Name -notin 'check', 'passed' } |
        ForEach-Object { "$($_.Name)=$($_.Value -join ',')" }) -join '; '
    $rows += "| $check | $(if ($s.passed) { 'passed' } else { 'FAILED' }) | $detail |"
}

$tests = $summaries['tests']
if ($tests) {
    if ([int]$tests.testsTotal -le 0) { $problems += 'No tests ran in the build.' }
    if ([int]$tests.testsFailed -ne 0) { $problems += "$($tests.testsFailed) test(s) failed in the build." }
    if ([double]$tests.lineCoverage -lt $CoverageThreshold) {
        $problems += "Coverage $($tests.lineCoverage)% is below the current $CoverageThreshold% threshold."
    }
}
foreach ($name in @($summaries.Keys)) {
    $s = $summaries[$name]
    foreach ($field in 'high', 'critical', 'blocking') {
        if ($s.PSObject.Properties[$field] -and [int]$s.$field -gt 0) { $problems += "$name recorded $($s.$field) $field finding(s)." }
    }
}

$verdict = if ($problems.Count -eq 0) { 'READY for production' } else { 'NOT ready for production' }
$md = @("## PROD preflight: $verdict", '', '| Check | Result | Detail |', '|---|---|---|') + $rows
if ($problems.Count -gt 0) { $md += ''; $md += ($problems | ForEach-Object { "- $_" }) }
$mdPath = Join-Path $EvidenceDir 'prod-preflight.md'
$md | Set-Content $mdPath
Write-Host "##vso[task.uploadsummary]$mdPath"
$md | ForEach-Object { Write-Host $_ }

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "##vso[task.logissue type=error]$p" }
    exit 1
}
exit 0
