<#
.SYNOPSIS
    Posts a pipeline stage result to Microsoft Teams (or any endpoint accepting the same payload).
.DESCRIPTION
    The webhook URL comes from the secret TEAMS_WEBHOOK_URL in the devops-exercise-shared
    variable group. Create it in Teams with Workflows, "Post to a channel when a webhook
    request is received". When the variable is not defined the step logs and exits 0:
    notifications must never fail a deployment.
    Works in Windows PowerShell 5.1 (IIS agent) and pwsh 7 (hosted Linux agents).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$Stage,
    [Parameter(Mandatory = $true)] [string]$Status,
    [string]$Detail = ''
)

$url = $env:TEAMS_WEBHOOK_URL
if ([string]::IsNullOrWhiteSpace($url) -or $url.StartsWith('$(')) {
    Write-Host "Notification skipped: TEAMS_WEBHOOK_URL is not configured. [$Stage] $Status"
    exit 0
}

$runUrl = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_build/results?buildId=$($env:BUILD_BUILDID)"
$color = switch -Regex ($Status) { '^Succeeded' { 'Good' } '^(Failed|Canceled)' { 'Attention' } default { 'Warning' } }
$card = @{
    type        = 'message'
    attachments = @(@{
        contentType = 'application/vnd.microsoft.card.adaptive'
        content     = @{
            '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
            type      = 'AdaptiveCard'
            version   = '1.4'
            body      = @(
                @{ type = 'TextBlock'; size = 'Medium'; weight = 'Bolder'; color = $color
                   text = "$($env:BUILD_DEFINITIONNAME) $($env:BUILD_BUILDNUMBER): $Stage $Status" },
                @{ type = 'FactSet'; facts = @(
                    @{ title = 'Branch'; value = "$($env:BUILD_SOURCEBRANCHNAME)" },
                    @{ title = 'Commit'; value = "$($env:BUILD_SOURCEVERSION)".Substring(0, [Math]::Min(8, "$($env:BUILD_SOURCEVERSION)".Length)) },
                    @{ title = 'Triggered by'; value = "$($env:BUILD_REQUESTEDFOR)" }
                ) },
                @{ type = 'TextBlock'; wrap = $true; text = $Detail }
            )
            actions   = @(@{ type = 'Action.OpenUrl'; title = 'Open run'; url = $runUrl })
        }
    })
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body ($card | ConvertTo-Json -Depth 12) | Out-Null
    Write-Host "Notified: [$Stage] $Status"
}
catch {
    Write-Host "##vso[task.logissue type=warning]Notification failed (deployment unaffected): $($_.Exception.Message)"
}
exit 0
