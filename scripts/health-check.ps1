<#
.SYNOPSIS
    Performs HTTP smoke test / health check against deployed endpoint.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.6 / 4.1 health check requirement.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $false)]
    [int]$ExpectedStatus = 200,

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 10,

    [Parameter(Mandatory = $false)]
    [int]$DelaySeconds = 5,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = "Continue"

Write-Host "Starting Health Check / Smoke Test..."
Write-Host "Target Endpoint : $Url"
Write-Host "Expected Status : $ExpectedStatus"
Write-Host "Max Retries     : $MaxRetries (interval: ${DelaySeconds}s)"

$Attempt = 0
$Success = $false

while ($Attempt -lt $MaxRetries) {
    $Attempt++
    Write-Host "[Attempt $Attempt/$MaxRetries] Probing $Url..."

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $statusCode = [int]$response.StatusCode

        if ($statusCode -eq $ExpectedStatus) {
            Write-Host "SUCCESS: Endpoint responded with HTTP $statusCode OK."
            $Success = $true
            break
        } else {
            Write-Warning "Received HTTP $statusCode (expected $ExpectedStatus). Retrying in ${DelaySeconds}s..."
        }
    }
    catch {
        $exMessage = $_.Exception.Message
        Write-Warning "Probe failed: $exMessage. Retrying in ${DelaySeconds}s..."
    }

    Start-Sleep -Seconds $DelaySeconds
}

if (-not $Success) {
    Write-Error "HEALTH CHECK FAILED: Endpoint $Url did not respond with HTTP $ExpectedStatus after $MaxRetries attempts."
    exit 1
}

Write-Host "Health check passed successfully!"
exit 0
