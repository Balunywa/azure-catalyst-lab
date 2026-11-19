<#
.SYNOPSIS
  Pause (deallocate) or delete the Azure Catalyst lab.
.EXAMPLE
  ./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Stop      # stop paying for compute, keep everything
  ./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Start
  ./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Remove    # deletes the whole resource group (asks first)
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Stop', 'Start', 'Remove')][string]$Action)

. "$PSScriptRoot/LabCommon.ps1"
$cfg = Get-LabConfig
switch ($Action) {
    'Stop'  { Write-Step "Deallocating $($cfg.HostVmName)"; Invoke-Az vm deallocate -g $cfg.ResourceGroup -n $cfg.HostVmName | Out-Null; Write-Ok 'Stopped (disks still billed)' }
    'Start' { Write-Step "Starting $($cfg.HostVmName)";     Invoke-Az vm start -g $cfg.ResourceGroup -n $cfg.HostVmName | Out-Null;      Write-Ok 'Started (nested VMs auto-start)' }
    'Remove' {
        $res = Invoke-Az resource list -g $cfg.ResourceGroup
        Write-Host "Resource group $($cfg.ResourceGroup) in subscription $($cfg.SubscriptionId) holds $(@($res).Count) resources:"
        $res | Group-Object type | ForEach-Object { "  {0,3}  {1}" -f $_.Count, $_.Name }
        Write-Host 'Replication must be stopped first or the Recovery Services vault blocks deletion.' -ForegroundColor Yellow
        if ((Read-Host "Type the resource group name to delete it permanently") -ne $cfg.ResourceGroup) { 'Cancelled.'; return }
        Invoke-Az group delete -n $cfg.ResourceGroup --yes --no-wait | Out-Null
        Write-Ok 'Deletion started (takes ~10 min).'
    }
}
