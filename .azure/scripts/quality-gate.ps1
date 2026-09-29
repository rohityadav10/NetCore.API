<#
.SYNOPSIS
    Test and coverage gate: fails unless every test passed (and at least one ran) and line
    coverage meets the threshold. Reads the files the test runners already produce.
.DESCRIPTION
    Test results: TRX (.NET / xUnit) or JUnit XML (Angular / Karma), detected by content.
    Coverage: Cobertura XML (Coverlet or Karma/istanbul). With several files, covered and valid
    lines are summed.
    Paths accept wildcards (e.g. $(Agent.TempDirectory)/TestResults/*/coverage.cobertura.xml).

    Writes <ReportDir>/summary-tests.json for the PROD preflight, and sets the output variables
    lineCoverage / testsTotal / testsFailed for later steps.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$TestResults,
    [Parameter(Mandatory = $true)] [string]$Coverage,
    [Parameter(Mandatory = $true)] [double]$Threshold,
    [Parameter(Mandatory = $true)] [string]$ReportDir
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$failures = @()

# ── Tests ────────────────────────────────────────────────────────────────────
$total = 0; $failed = 0
$testFiles = @(Resolve-Path $TestResults -ErrorAction SilentlyContinue)
foreach ($file in $testFiles) {
    [xml]$xml = Get-Content -Raw $file
    if ($xml.TestRun) {
        # TRX: failed covers assertion failures; error/timeout/aborted are failures too.
        $c = $xml.TestRun.ResultSummary.Counters
        $total += [int]$c.total
        $failed += [int]$c.failed + [int]$c.error + [int]$c.timeout + [int]$c.aborted
    }
    else {
        # JUnit: <testsuites><testsuite tests= failures= errors=>, or a bare <testsuite>.
        foreach ($suite in $xml.SelectNodes('//testsuite')) {
            $total += [int]$suite.tests
            $failed += [int]$suite.failures + [int]$suite.errors
        }
    }
}
if ($testFiles.Count -eq 0) { $failures += "No test results found at '$TestResults'." }
elseif ($total -eq 0) { $failures += 'No tests were executed.' }
if ($failed -gt 0) { $failures += "$failed of $total test(s) failed (pass rate must be 100%)." }

# ── Coverage ─────────────────────────────────────────────────────────────────
$covered = 0; $valid = 0
$coverageFiles = @(Resolve-Path $Coverage -ErrorAction SilentlyContinue)
foreach ($file in $coverageFiles) {
    [xml]$xml = Get-Content -Raw $file
    $covered += [int]$xml.coverage.'lines-covered'
    $valid += [int]$xml.coverage.'lines-valid'
}
$lineCoverage = if ($valid -gt 0) { [math]::Round(100.0 * $covered / $valid, 2) } else { 0 }
if ($coverageFiles.Count -eq 0) { $failures += "No Cobertura coverage found at '$Coverage'." }
elseif ($lineCoverage -lt $Threshold) { $failures += "Line coverage $lineCoverage% is below the $Threshold% threshold." }

[ordered]@{
    check        = 'tests'
    testsTotal   = $total
    testsFailed  = $failed
    lineCoverage = $lineCoverage
    threshold    = $Threshold
    passed       = ($failures.Count -eq 0)
} | ConvertTo-Json | Set-Content (Join-Path $ReportDir 'summary-tests.json')

Write-Host "Tests: $($total - $failed)/$total passed. Line coverage: $lineCoverage% (threshold $Threshold%)."
Write-Host "##vso[task.setvariable variable=lineCoverage;isOutput=true]$lineCoverage"
Write-Host "##vso[task.setvariable variable=testsTotal;isOutput=true]$total"
Write-Host "##vso[task.setvariable variable=testsFailed;isOutput=true]$failed"

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "##vso[task.logissue type=error]$f" }
    exit 1
}
Write-Host 'Test and coverage gate passed.'
exit 0
