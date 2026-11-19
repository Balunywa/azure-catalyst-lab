# Runs ON the Hyper-V host. Data disk, NAT switch, DHCP, discovery account, WinRM, appliance UI port mapping.
param([string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json', [string]$SecretsPath = 'C:\Lab\.lab\secrets.json')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sec = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$net = $cfg.NestedNetwork

# --- Data disk -> V: -----------------------------------------------------------------------------
if (-not (Get-Volume -DriveLetter V -ErrorAction SilentlyContinue)) {
    $disk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $disk) { throw 'No RAW data disk found.' }
    $disk | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter V -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'LabVMs' -AllocationUnitSize 65536 -Confirm:$false | Out-Null
}
New-Item -ItemType Directory -Force V:\Lab\Downloads, V:\Lab\Images, V:\Lab\VMs | Out-Null
Set-VMHost -VirtualHardDiskPath V:\Lab\VMs -VirtualMachinePath V:\Lab\VMs
"[ok] V: data volume ($([math]::Round((Get-Volume V).SizeRemaining/1GB)) GB free)"

# --- Internal switch + NAT --------------------------------------------------------------------------
if (-not (Get-VMSwitch -Name $net.SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $net.SwitchName -SwitchType Internal | Out-Null
}
$ifAlias = "vEthernet ($($net.SwitchName))"
if (-not (Get-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $net.HostIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $net.HostIp -PrefixLength $net.PrefixLength | Out-Null
}
if (-not (Get-NetNat -Name $net.NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $net.NatName -InternalIPInterfaceAddressPrefix "$($net.Prefix).0/$($net.PrefixLength)" | Out-Null
}
# Treat the lab switch as a private network so WinRM/ICMP rules apply to it.
Get-NetConnectionProfile -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue | Set-NetConnectionProfile -NetworkCategory Private
"[ok] Switch $($net.SwitchName) + NAT $($net.NatName) ($($net.Prefix).0/$($net.PrefixLength))"

# --- DHCP (bound to the lab switch only) with reservations for each nested VM ------------------------
Import-Module DhcpServer
$ifIndex = (Get-NetAdapter -Name $ifAlias).ifIndex
Get-DhcpServerv4Binding | ForEach-Object {
    Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState ($_.InterfaceAlias -eq $ifAlias) | Out-Null
}
$scopeId = "$($net.Prefix).0"
if (-not (Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name 'CatalystLab' -StartRange $net.DhcpStart -EndRange $net.DhcpEnd -SubnetMask 255.255.255.0 -State Active
}
Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $net.HostIp -DnsServer $net.Dns -Force
foreach ($vm in $cfg.NestedVms) {
    $mac = ($vm.Mac -replace '(..)(?!$)', '$1-')
    if (-not (Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $vm.Ip)) {
        Add-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $vm.Ip -ClientId $mac -Name $vm.Name
    }
}
# Silence the "complete DHCP configuration" nag and make sure the service is up.
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
Restart-Service DHCPServer
"[ok] DHCP scope $scopeId with $(@(Get-DhcpServerv4Reservation -ScopeId $scopeId).Count) reservations"

# --- Discovery account for the appliance (least privilege per the Catalyst/Azure Migrate docs) --------
$pw = ConvertTo-SecureString $sec.DiscoveryPassword -AsPlainText -Force
if (-not (Get-LocalUser -Name $sec.DiscoveryUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $sec.DiscoveryUser -Password $pw -PasswordNeverExpires -Description 'Azure Catalyst appliance discovery' | Out-Null
} else { Set-LocalUser -Name $sec.DiscoveryUser -Password $pw }
foreach ($g in 'Remote Management Users', 'Hyper-V Administrators', 'Performance Monitor Users') {
    if (-not (Get-LocalGroupMember -Group $g -Member $sec.DiscoveryUser -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group $g -Member $sec.DiscoveryUser
    }
}
"[ok] Discovery account $($sec.DiscoveryUser)"

# --- WinRM (appliance connects on 5985/5986 from the lab subnet) --------------------------------------
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
foreach ($port in 5985, 5986) {
    $name = "CatalystLab-WinRM-$port"
    if (-not (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $name -DisplayName "Catalyst lab WinRM $port (lab subnet)" -Direction Inbound `
            -Protocol TCP -LocalPort $port -RemoteAddress "$($net.Prefix).0/$($net.PrefixLength)" -Action Allow | Out-Null
    }
}
# HTTPS listener with a self-signed cert so the appliance can use 5986.
if (-not (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })) {
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME, $net.HostIp -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(2)
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
}
"[ok] WinRM listeners: $((Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { ($_.Keys | Where-Object { $_ -like 'Transport=*' }) }) -join ', ')"

# --- Publish the appliance configuration manager (44368) on the host's Azure NIC ---------------------
$appliance = $cfg.NestedVms | Where-Object Role -eq 'appliance'
if (-not (Get-NetNatStaticMapping -NatName $net.NatName -ErrorAction SilentlyContinue | Where-Object ExternalPort -eq 44368)) {
    Add-NetNatStaticMapping -NatName $net.NatName -Protocol TCP -ExternalIPAddress 0.0.0.0/24 -ExternalPort 44368 `
        -InternalIPAddress $appliance.Ip -InternalPort 44368 | Out-Null
}
if (-not (Get-NetFirewallRule -Name 'CatalystLab-ApplianceUI' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'CatalystLab-ApplianceUI' -DisplayName 'Catalyst lab appliance UI 44368' -Direction Inbound `
        -Protocol TCP -LocalPort 44368 -Action Allow | Out-Null
}
"[ok] NAT 0.0.0.0:44368 -> $($appliance.Ip):44368"
