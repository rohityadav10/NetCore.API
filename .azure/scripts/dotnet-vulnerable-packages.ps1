<#
.SYNOPSIS
    NuGet dependency gate: fails when any direct or transitive package in the solution has a
    known High or Critical vulnerability.
.DESCRIPTION
    Uses the SDK's own `dotnet list package --vulnerable --include-transitive`, which checks
    the GitHub Advisory Database (the same data Dependabot uses) against the restored graph,
    test projects included. Trivy can't see a .NET dependency graph from source alone: it
    needs packages.lock.json or *.deps.json. The shipped image (which does contain
    NetCore.API.deps.json) is scanned by Trivy separately.

    Requires a prior `dotnet restore`. Writes <ReportDir>/nuget-vulnerabilities.json (the raw
    report) and <ReportDir>/summary-dependencies.json (for the PROD preflight).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$Solution,
    [Parameter(Mandatory = $true)] [string]$ReportDir,
    [string[]]$FailOn = @('High', 'Critical')
)

$ErrorActionPreference = 'Stop'
$FailOn = @($FailOn -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$raw = & dotnet list $Solution package --vulnerable --include-transitive --format json
if ($LASTEXITCODE -ne 0) { throw "dotnet list package failed (exit $LASTEXITCODE). Was the solution restored?" }
$raw | Set-Content (Join-Path $ReportDir 'nuget-vulnerabilities.json')
$report = ($raw -join "`n") | ConvertFrom-Json

$found = foreach ($project in @($report.projects)) {
    foreach ($framework in @($project.frameworks)) {
        foreach ($package in @($framework.topLevelPackages) + @($framework.transitivePackages)) {
            foreach ($vulnerability in @($package.vulnerabilities)) {
                if (-not $vulnerability) { continue }
                [pscustomobject]@{
                    Project  = Split-Path $project.path -Leaf
                    Package  = $package.id
                    Version  = $package.resolvedVersion
                    Severity = $vulnerability.severity
                    Advisory = $vulnerability.advisoryurl
                }
            }
        }
    }
}
$found = @($found | Where-Object { $_ })
$blocking = @($found | Where-Object { $FailOn -contains $_.Severity })

[ordered]@{
    check    = 'dependencies'
    tool     = 'dotnet list package --vulnerable'
    high     = @($blocking | Where-Object Severity -eq 'High').Count
    critical = @($blocking | Where-Object Severity -eq 'Critical').Count
    total    = $found.Count
    passed   = ($blocking.Count -eq 0)
} | ConvertTo-Json | Set-Content (Join-Path $ReportDir 'summary-dependencies.json')

foreach ($v in $found) {
    $type = if ($FailOn -contains $v.Severity) { 'error' } else { 'warning' }
    Write-Host "##vso[task.logissue type=$type]$($v.Severity): $($v.Package) $($v.Version) in $($v.Project) - $($v.Advisory)"
}
if ($blocking.Count -gt 0) {
    Write-Host "##vso[task.logissue type=error]Dependency gate FAILED: $($blocking.Count) $($FailOn -join '/') vulnerable package(s)."
    exit 1
}
Write-Host "Dependency gate passed ($($found.Count) lower-severity finding(s))."
exit 0
