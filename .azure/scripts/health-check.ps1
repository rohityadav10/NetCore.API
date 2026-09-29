<#
.SYNOPSIS
    Smoke test: polls a URL until it answers with the expected status (and, optionally,
    the expected build version), or fails after MaxRetries.
.DESCRIPTION
    Used after every IIS deployment by deploy-iis.ps1, and on its own for manual checks.
    Unlike a plain "is it up" probe, -ExpectedVersion proves the NEW build is serving:
    the response must be JSON whose 'version' field equals the build number that was
    deployed. That catches IIS still running an old copy (locked files, wrong path).
    Compatible with Windows PowerShell 5.1 (the IIS server's default shell) and pwsh 7.
.EXAMPLE
    ./health-check.ps1 -Url http://localhost:8181/health
    ./health-check.ps1 -Url http://localhost:8181/api/AppStatus -ExpectedVersion 20260928.1
.OUTPUTS
    Exit code 0 when healthy, 1 when not.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [int]$ExpectedStatus = 200,

    # When set, the body must be JSON with "version" equal to this value.
    [string]$ExpectedVersion = '',

    # When set, the body must contain this text (e.g. '<app-root' for the SPA shell).
    [string]$MustContain = '',

    [int]$MaxRetries = 12,

    [int]$DelaySeconds = 5,

    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

Write-Host "Health check: $Url (expect HTTP $ExpectedStatus$(if ($ExpectedVersion) { ", version $ExpectedVersion" }))"

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    $problem = $null
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -Headers @{ 'Cache-Control' = 'no-cache' }
        $status = [int]$response.StatusCode
        $body = [string]$response.Content

        if ($status -ne $ExpectedStatus) {
            $problem = "HTTP $status"
        }
        elseif ($MustContain -and -not $body.Contains($MustContain)) {
            $problem = "body does not contain '$MustContain'"
        }
        elseif ($ExpectedVersion) {
            $actual = $null
            try { $actual = ($body | ConvertFrom-Json).version } catch { }
            if ($actual -ne $ExpectedVersion) {
                $problem = "version is '$actual', expected '$ExpectedVersion'"
            }
        }
    }
    catch {
        # Invoke-WebRequest throws on non-2xx and on connection errors.
        $problem = $_.Exception.Message
    }

    if (-not $problem) {
        Write-Host "[$attempt/$MaxRetries] HEALTHY: $Url"
        exit 0
    }

    Write-Host "[$attempt/$MaxRetries] not healthy yet: $problem"
    if ($attempt -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

Write-Host "##vso[task.logissue type=error]Health check failed: $Url did not become healthy after $MaxRetries attempts."
exit 1
