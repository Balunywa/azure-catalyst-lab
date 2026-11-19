# Runs ON the Hyper-V host. Collects every host/nested/appliance fact the test suite needs in ONE Run Command
# call and prints a single compact JSON line (Run Command returns <= 4 KB). __TMIPS__ = test-migrated VM IPs.
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$tmIps = '__TMIPS__'.Split(',') | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
$cfg  = Get-Content C:\Lab\.lab\lab.settings.json -Raw | ConvertFrom-Json
$sec  = Get-Content C:\Lab\.lab\secrets.json -Raw | ConvertFrom-Json
$pw   = ConvertTo-SecureString $sec.GuestAdminPassword -AsPlainText -Force
$nb   = if ($cfg.Company) { $cfg.Company.NetBios } else { 'CATLAB' }
function Get-Http([string]$Url) { try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 $Url).Content } catch { "ERR $($_.Exception.Message)" } }
function Test-Port([string]$Ip, [int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.ConnectAsync($Ip, $Port).Wait(3000) -and $c.Connected } catch { $false } finally { $c.Dispose() }
}
function Test-Ready([string]$Spec, [string]$Ip) {
    if (-not $Spec) { return $null }
    $kind, $rest = $Spec -split ':', 2; $port, $path = $rest -split '/', 2
    if ($kind -eq 'http') { return -not ((Get-Http "http://${Ip}:$port/$path") -like 'ERR*') }
    Test-Port $Ip ([int]$port)
}
function Invoke-Guest([string]$Vm, [scriptblock]$Sb) {
    foreach ($u in "$nb\Administrator", '.\Administrator', 'Administrator') {
        try { return Invoke-Command -VMName $Vm -Credential (New-Object PSCredential $u, $pw) -ScriptBlock $Sb -ErrorAction Stop } catch {}
    }
    $null
}

$p = [ordered]@{}
$p.os    = (Get-CimInstance Win32_OperatingSystem).Caption
$p.hv    = "$((Get-WindowsFeature Hyper-V).InstallState)"
$p.vmms  = "$((Get-Service vmms).Status)"
$p.sw    = "$((Get-VMSwitch LabSwitch).SwitchType)"
$p.nat   = (Get-NetNat LabNat).InternalIPInterfaceAddressPrefix
$p.dhcp  = "$((Get-DhcpServerv4Scope -ScopeId 192.168.100.0).State)"
$p.resv  = @(Get-DhcpServerv4Reservation -ScopeId 192.168.100.0).Count
$p.grp   = @('Remote Management Users', 'Hyper-V Administrators', 'Performance Monitor Users' |
             Where-Object { (Get-LocalGroupMember -Group $_).Name -match $sec.DiscoveryUser }).Count
$p.winrm = (Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { ($_.Keys -match 'Transport') -replace 'Transport=' }) -join ','
$p.map   = [bool](Get-NetNatStaticMapping -NatName LabNat | Where-Object ExternalPort -eq 44368)
$p.ramGB = [math]::Round((Get-VM | Measure-Object MemoryAssigned -Sum).Sum / 1GB, 1)

# Per VM: state/heartbeat/ip, role readiness, dependency-agent status (ok/total), domain
$p.vms = @(foreach ($vm in $cfg.NestedVms) {
    $h = Get-VM -Name $vm.Name
    $ip = (($h | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -like '192.168.*' }) -join ','
    $deps = ''; $dom = ''
    if ($h.State -eq 'Running') {
        if ($vm.Os -eq 'windows' -and $vm.Role -ne 'appliance') {
            $g = Invoke-Guest $vm.Name {
                $st = $null
                for ($i = 0; $i -lt 3 -and -not $st; $i++) {
                    try { $st = Get-Content C:\catlab\deps-status.json -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Start-Sleep -Seconds 2 }
                }
                $props = if ($st) { @($st.PSObject.Properties) } else { @() }
                '{0}|{1}/{2}' -f (Get-CimInstance Win32_ComputerSystem).Domain, @($props | Where-Object { $_.Value.ok }).Count, $props.Count
            }
            if ($g) { $dom, $deps = "$g" -split '\|' }
        } elseif ($vm.Os -ne 'windows' -and @($vm.Depends).Count -and $vm.Role -ne 'prometheus') {
            try { $st = Invoke-RestMethod -TimeoutSec 5 "http://$($vm.Ip):9109/"; $props = @($st.PSObject.Properties); $deps = '{0}/{1}' -f @($props | Where-Object { $_.Value.ok }).Count, $props.Count } catch { $deps = 'agent-down' }
        }
    }
    [ordered]@{ n = $vm.Name; s = "$($h.State)"; hb = "$($h.Heartbeat)" -replace 'Applications.*'; ip = $ip; r = Test-Ready $vm.Ready $vm.Ip; d = $deps; dom = $dom }
})
$p.web   = (Get-Http 'http://192.168.100.20/') -match 'windows-iis'
$p.lnx   = (Get-Http 'http://192.168.100.30/') -match 'debian-nginx'
$p.proxy = (Get-Http 'http://192.168.100.30/shop/') -match 'windows-iis'
$p.api   = (Get-Http 'http://192.168.100.31:8080/') -match '"items"'
$p.inet  = [bool](Invoke-Guest CAT-WEB01 { (Test-NetConnection management.azure.com -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded })
$p.asvc  = "$(Invoke-Guest CAT-APPLIANCE {
    $s = Get-Service | Where-Object { $_.DisplayName -like 'Microsoft Azure*' }
    $down = ($s | Where-Object Status -ne 'Running').Name -join ','
    '{0}/{1}{2}' -f @($s | Where-Object Status -eq 'Running').Count, @($s).Count, $(if ($down) { " down: $down" }) })"
$p.aport = Test-Port '192.168.100.10' 44368
$p.prov  = "$((Get-Service dra -ErrorAction SilentlyContinue).Status)"
$p.tm    = @(foreach ($ip in $tmIps) { [ordered]@{ ip = $ip; body = ((Get-Http "http://$ip/") -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() } })
$p | ConvertTo-Json -Compress -Depth 4
