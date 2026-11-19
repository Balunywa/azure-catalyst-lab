# Runs ON the Hyper-V host. Creates the "on-premises" estate on the nested NAT switch:
#   CAT-APPLIANCE  Windows Server 2022 (becomes the Azure Catalyst / Azure Migrate appliance)
#   CAT-WEB01      Windows Server 2022 + IIS
#   CAT-LNX01      Debian 12 + nginx (cloud-init NoCloud seed)
param([string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json', [string]$SecretsPath = 'C:\Lab\.lab\secrets.json',
      [string[]]$Only)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sec = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$pw  = [Security.SecurityElement]::Escape($sec.GuestAdminPassword)

function New-WindowsUnattend([string]$ComputerName) {
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active><Group>Remote Desktop</Group><Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$pw</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function New-CloudInitSeed([string]$Path, [string]$Hostname) {
    $userData = @"
#cloud-config
hostname: $Hostname
fqdn: $Hostname
manage_etc_hosts: true
users:
  - name: labadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
chpasswd:
  expire: false
  users:
    - {name: labadmin, password: "$($sec.GuestAdminPassword)", type: text}
ssh_pwauth: true
package_update: true
packages: [nginx, hyperv-daemons, curl]
write_files:
  - path: /var/www/html/index.html
    defer: true
    content: |
      <html><body><h1>CAT-LNX01</h1><p>catalyst-lab marker: debian-nginx</p></body></html>
runcmd:
  - [systemctl, enable, --now, nginx]
  - [systemctl, enable, --now, hv-kvp-daemon]
  - [touch, /etc/cloud/cloud-init.disabled]
"@
    $metaData = "instance-id: $Hostname-001`nlocal-hostname: $Hostname`n"
    # systemd-networkd sends a DUID client-id by default, which misses the host's MAC-based DHCP reservation.
    # Match by name (not MAC) so the same config still works after the VM is migrated to Azure.
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    match:
      name: eth0
    dhcp4: true
    dhcp-identifier: mac
"@
    if (Test-Path $Path) { Remove-Item $Path -Force }
    New-VHD -Path $Path -SizeBytes 64MB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $Path -Passthru | Get-Disk
    try {
        $disk | Initialize-Disk -PartitionStyle MBR -PassThru | New-Partition -UseMaximumSize -AssignDriveLetter |
            Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'CIDATA' -Confirm:$false | Out-Null
        $letter = ($disk | Get-Partition | Where-Object DriveLetter | Select-Object -First 1).DriveLetter
        $utf8 = New-Object Text.UTF8Encoding $false
        $pre = "C:\Lab\seeds\$($Hostname.ToUpper())"
        if (Test-Path "$pre\user-data") {
            # Rendered on the laptop by 06-Expand-Estate.ps1 (role, dependencies, app config)
            foreach ($f in 'user-data', 'meta-data', 'network-config') { Copy-Item "$pre\$f" "${letter}:\$f" }
        } else {
            [IO.File]::WriteAllText("${letter}:\user-data", ($userData -replace "`r`n", "`n"), $utf8)
            [IO.File]::WriteAllText("${letter}:\meta-data", $metaData, $utf8)
            [IO.File]::WriteAllText("${letter}:\network-config", ($networkConfig -replace "`r`n", "`n"), $utf8)
        }
    } finally { Dismount-VHD -Path $Path }
}

$switch = $cfg.NestedNetwork.SwitchName
foreach ($vm in $cfg.NestedVms) {
    if ($Only -and $vm.Name -notin $Only) { continue }
    $existing = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($vm.Os -ne 'windows' -and $vm.Role -and $existing.Notes -notmatch "role=$([regex]::Escape($vm.Role))(\s|$)") {
            "[..] $($vm.Name) role changed -> rebuilding (cloud-init re-provisions Linux VMs)"
            Stop-VM -Name $vm.Name -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $vm.Name -Force
            Remove-Item "V:\Lab\VMs\$($vm.Name)" -Recurse -Force -ErrorAction SilentlyContinue
        } else { "[ok] $($vm.Name) already exists"; continue }
    }
    "[..] $($vm.Name)"
    $dir = "V:\Lab\VMs\$($vm.Name)"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $osDisk = Join-Path $dir "$($vm.Name)-os.vhdx"

    if ($vm.Os -eq 'windows') {
        Convert-VHD -Path 'V:\Lab\Downloads\ws2022-eval.vhd' -DestinationPath $osDisk -VHDType Dynamic
        if ((Get-VHD $osDisk).Size -lt $vm.DiskGB * 1GB) { Resize-VHD -Path $osDisk -SizeBytes ($vm.DiskGB * 1GB) }
        $disk = Mount-VHD -Path $osDisk -Passthru | Get-Disk
        try {
            $disk | Get-Partition | Where-Object { -not $_.DriveLetter -and $_.Size -gt 5GB } |
                ForEach-Object { $_ | Add-PartitionAccessPath -AssignDriveLetter }
            $win = Get-Disk -Number $disk.Number | Get-Partition | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32") } | Select-Object -First 1
            if (-not $win) { throw 'Windows partition not found in eval VHD' }
            $max = ($win | Get-PartitionSupportedSize).SizeMax
            if ($win.Size -lt $max - 1MB) { $win | Resize-Partition -Size $max }
            $panther = "$($win.DriveLetter):\Windows\Panther"
            New-Item -ItemType Directory -Force $panther | Out-Null
            Set-Content -Path "$panther\unattend.xml" -Value (New-WindowsUnattend $vm.Name) -Encoding utf8
        } finally { Dismount-VHD -Path $osDisk }
    } else {
        Copy-Item 'V:\Lab\Images\debian12.vhdx' $osDisk
        Resize-VHD -Path $osDisk -SizeBytes ($vm.DiskGB * 1GB)
    }

    New-VM -Name $vm.Name -Generation 1 -MemoryStartupBytes ([int64][math]::Round($vm.MemoryGB * 1024) * 1MB) -VHDPath $osDisk `
        -SwitchName $switch -Path 'V:\Lab\VMs' | Out-Null
    Set-VM -Name $vm.Name -ProcessorCount $vm.vCPU -StaticMemory -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Start -AutomaticStopAction ShutDown -Notes "catalyst-lab role=$($vm.Role) app=$($vm.App)"
    Get-VMNetworkAdapter -VMName $vm.Name | Set-VMNetworkAdapter -StaticMacAddress $vm.Mac
    Get-VMIntegrationService -VMName $vm.Name | Where-Object { -not $_.Enabled } | Enable-VMIntegrationService
    if ($vm.Os -ne 'windows') {
        $seed = Join-Path $dir "$($vm.Name)-cidata.vhdx"
        New-CloudInitSeed -Path $seed -Hostname $vm.Name.ToLower()
        Add-VMHardDiskDrive -VMName $vm.Name -ControllerType IDE -ControllerNumber 0 -ControllerLocation 1 -Path $seed
    }
    Start-VM -Name $vm.Name
    "[ok] $($vm.Name) started ($($vm.vCPU) vCPU, $($vm.MemoryGB) GB, $($vm.Ip))"
}
