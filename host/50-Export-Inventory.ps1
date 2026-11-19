# Runs ON the Hyper-V host. Plays the "discovery source" that feeds the lab CMDB: reads every nested VM's
# hardware from Hyper-V and its OS identity from the guest's KVP (Data Exchange) integration service.
# Prints one compact JSON line (Run Command returns at most 4 KB of stdout).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-Kvp([string]$VmName) {
    $vm  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VmName'"
    $kvp = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_KvpExchangeComponent
    $h = @{}
    foreach ($x in $kvp.GuestIntrinsicExchangeItems) {
        $props = ([xml]$x).INSTANCE.PROPERTY
        $n = ($props | Where-Object NAME -eq 'Name').VALUE
        $d = ($props | Where-Object NAME -eq 'Data').VALUE
        if ($n) { $h[$n] = $d }
    }
    $h
}

$out = foreach ($vm in Get-VM | Sort-Object Name) {
    $k     = Get-Kvp $vm.Name
    $disks = @(Get-VMHardDiskDrive -VMName $vm.Name | ForEach-Object { Get-VHD -Path $_.Path })
    $nics  = @(Get-VMNetworkAdapter -VMName $vm.Name)
    [ordered]@{
        n    = $vm.Name
        fqdn = $k['FullyQualifiedDomainName']
        os   = $k['OSName']
        osv  = $k['OSVersion']
        arch = $k['ProcessorArchitecture']          # 9 = x64 on Windows guests
        ip   = (($nics.IPAddresses | Where-Object { $_ -match '^\d+\.' }) -join ';')
        mac  = (($nics.MacAddress | ForEach-Object { $_ -replace '(..)(?!$)', '$1:' }) -join ';')
        cpu  = $vm.ProcessorCount
        mem  = [int]($vm.MemoryStartup / 1MB)
        gen  = $vm.Generation
        cpuu = $vm.CPUUsage                          # instantaneous %, good enough for a lab CMDB snapshot
        memu = if ($vm.MemoryAssigned) { [math]::Round(100 * $vm.MemoryDemand / $vm.MemoryAssigned) } else { 0 }
        dgb  = @($disks | ForEach-Object { [math]::Round($_.Size / 1GB) })
        used = [math]::Round((($disks | Measure-Object FileSize -Sum).Sum) / 1GB, 1)
        nic  = $nics.Count
        host = $env:COMPUTERNAME
        hb   = "$($vm.Heartbeat)"
    }
}
$json = @{ at = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; vms = @($out) } | ConvertTo-Json -Compress -Depth 4
# Run Command returns at most 4 KB of stdout: gzip + base64 keeps 15+ servers well under that.
$ms = New-Object IO.MemoryStream
$gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
$b = [Text.Encoding]::UTF8.GetBytes($json); $gz.Write($b, 0, $b.Length); $gz.Close()
'GZ:' + [Convert]::ToBase64String($ms.ToArray())
