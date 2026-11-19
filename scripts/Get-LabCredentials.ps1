<#
.SYNOPSIS
  Prints the lab's sign-in details: the host admin (from your .lab/secrets.json) and the nested-VM /
  appliance accounts (generated on the host in C:\Lab\.lab\secrets.json, read via Run Command).
#>
. (Join-Path $PSScriptRoot 'LabCommon.ps1')
$cfg = Get-LabConfig
$local = Get-LabSecrets
$raw = Invoke-LabHost -Command 'Get-Content C:\Lab\.lab\secrets.json -Raw | ConvertFrom-Json | ConvertTo-Json -Compress' -NoThrow
$h = $null; try { $h = ($raw | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
if (-not $h) { Write-Warning 'Could not read secrets from the host yet (still bootstrapping?).'; $h = $local }
$nb = $cfg.Company.NetBios
$rows = [ordered]@{
    'Host VM (Bastion)'               = "$($cfg.AdminUser) / $($local.HostAdminPassword)"
    'Nested Windows VMs + appliance'  = "Administrator / $($h.GuestAdminPassword)"
    'Domain admin (catlab.local)'     = "$nb\Administrator / $($h.GuestAdminPassword)"
    'Nested Linux VMs'                = "labadmin / $($h.GuestAdminPassword)"
    'Appliance -> Hyper-V host creds' = "$($h.DiscoveryUser) / $($h.DiscoveryPassword)   (host IP 192.168.100.1)"
    'App accounts (PG/RabbitMQ/SMB)'  = "app, svc_app / $($h.AppPassword)"
}
$rows.GetEnumerator() | ForEach-Object { "{0,-33} {1}" -f $_.Key, $_.Value }
