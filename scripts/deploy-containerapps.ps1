<#
.SYNOPSIS
    Deploys container image to Azure Container Apps with health check and rollback.
.DESCRIPTION
    Fulfills DevOps Exercise Section 3.7 / 4.1 Container Apps deployment requirement.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$ImageTag,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$HealthCheckPath = "/WeatherForecast"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================================="
Write-Host "Deploying to Azure Container Apps: $AppName"
Write-Host "Image Tag      : $ImageTag"
Write-Host "Resource Group : $ResourceGroup"
Write-Host "=========================================================="

# 1. Update the Container App to create a new revision
Write-Host "[1/3] Updating Container App image to [$ImageTag]..."
az containerapp update `
  --name $AppName `
  --resource-group $ResourceGroup `
  --image $ImageTag

# 2. Retrieve newly created revision
$LatestRevision = (az containerapp revision list `
  --name $AppName `
  --resource-group $ResourceGroup `
  --query "[?properties.active==\`true\`].name | [-1]" -o tsv)

Write-Host "[2/3] Active Revision: $LatestRevision"

# 3. Retrieve FQDN and execute health check
$Fqdn = (az containerapp show `
  --name $AppName `
  --resource-group $ResourceGroup `
  --query "properties.configuration.ingress.fqdn" -o tsv)

$HealthUrl = "https://$Fqdn$HealthCheckPath"
Write-Host "[3/3] Running health check against: $HealthUrl"

$HealthScript = Join-Path $PSScriptRoot "health-check.ps1"
try {
    if (Test-Path $HealthScript) {
        & $HealthScript -Url $HealthUrl -MaxRetries 12 -DelaySeconds 5
    } else {
        $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200) {
            throw "Health check returned HTTP $($response.StatusCode)"
        }
    }
    Write-Host "Container Apps deployment for [$AppName] PASSED!"
    Write-Host "=========================================================="
}
catch {
    Write-Error "Deployment failed health check: $_"
    Write-Warning "Rolling back: Deactivating revision [$LatestRevision]..."
    az containerapp revision deactivate `
      --name $AppName `
      --resource-group $ResourceGroup `
      --revision $LatestRevision
    exit 1
}
