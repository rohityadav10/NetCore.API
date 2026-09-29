<#
.SYNOPSIS
    SAST gate: runs a pinned Semgrep container over the repository and fails on high-severity
    findings: injection, XSS, hard-coded secrets, and similar.
.DESCRIPTION
    Rules report either the legacy ERROR/WARNING/INFO levels or the newer CRITICAL/HIGH/MEDIUM/LOW
    ones, so ERROR, CRITICAL and HIGH all block. Rulesets come from the public Semgrep Registry;
    no account or token is needed. Lower-severity findings are published in the SARIF report (shown by the "SARIF SAST Scans Tab"
    extension) but don't block. Writes <ReportDir>/summary-sast.json for the PROD preflight.
.EXAMPLE
    ./semgrep-scan.ps1 -Configs p/csharp,p/secrets,p/owasp-top-ten -ReportDir ./reports `
        -SemgrepImage semgrep/semgrep:1.178.0 -Exclude tests
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string[]]$Configs,
    [Parameter(Mandatory = $true)] [string]$ReportDir,
    [Parameter(Mandatory = $true)] [string]$SemgrepImage,
    [string]$SourceDir = (Get-Location).Path,
    [string[]]$Exclude = @()
)

$ErrorActionPreference = 'Stop'
# Accept both arrays and comma-separated strings (pwsh -File passes the latter).
$Configs = @($Configs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Exclude = @($Exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$reports = (Resolve-Path $ReportDir).Path
$source = (Resolve-Path $SourceDir).Path

$arguments = @('scan', '--metrics=off', '--disable-version-check',
    '--json-output=/reports/semgrep.json', '--sarif-output=/reports/semgrep.sarif')
foreach ($config in $Configs) { $arguments += @('--config', $config) }
foreach ($path in $Exclude) { $arguments += @('--exclude', $path) }

Write-Host "Semgrep $($Configs -join ', ') over $source"
& docker run --rm -v "${source}:/src:ro" -v "${reports}:/reports" -w /src $SemgrepImage semgrep @arguments
# Exit 0 = ran (with or without findings), 1 = findings with --error (not used). Others = tool failure.
if ($LASTEXITCODE -gt 1) { throw "Semgrep failed to run (exit $LASTEXITCODE)." }

$result = Get-Content -Raw (Join-Path $reports 'semgrep.json') | ConvertFrom-Json
$findings = @($result.results)
$blockingSeverities = @('ERROR', 'CRITICAL', 'HIGH')
$blocking = @($findings | Where-Object { $blockingSeverities -contains $_.extra.severity })

[ordered]@{
    check    = 'sast'
    tool     = 'semgrep'
    rulesets = $Configs
    blocking = $blocking.Count
    total    = $findings.Count
    passed   = ($blocking.Count -eq 0)
} | ConvertTo-Json | Set-Content (Join-Path $reports 'summary-sast.json')

foreach ($f in $findings) {
    $type = if ($blockingSeverities -contains $f.extra.severity) { 'error' } else { 'warning' }
    Write-Host "##vso[task.logissue type=$type;sourcepath=$($f.path);linenumber=$($f.start.line)]$($f.check_id): $($f.extra.message)"
}
if ($blocking.Count -gt 0) {
    Write-Host "##vso[task.logissue type=error]SAST gate FAILED: $($blocking.Count) ERROR/CRITICAL/HIGH finding(s)."
    exit 1
}
Write-Host "SAST gate passed ($($findings.Count) non-blocking finding(s))."
exit 0
