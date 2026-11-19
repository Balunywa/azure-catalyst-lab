<#
.SYNOPSIS
  After you register the appliance (project key + Azure sign-in), configure discovery with no clicking:
  Hyper-V host credential + discovery source, guest credentials (domain, Windows, Linux) for software
  inventory and agentless dependency analysis, then Start discovery. Idempotent; safe to re-run.
#>
. "$PSScriptRoot/LabCommon.ps1"
Write-Step 'Configuring appliance discovery (host source + guest credentials)'
Invoke-LabHostScript -Name '60-Configure-ApplianceDiscovery.ps1' | ForEach-Object { "    $_" }
Write-Host "`nServers appear in the Catalyst project in ~15 min; software inventory + dependency data follow over the next hours." -ForegroundColor Yellow
