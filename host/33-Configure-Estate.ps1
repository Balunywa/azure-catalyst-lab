# Runs ON the Hyper-V host. Configures the company estate in stages: -Stage dc | members | linux
# (Start-LabBuild.ps1 passes -Stage; when sent as Run Command text, __STAGE__ is substituted instead.)
# Windows guests: C:\Lab\roles\windows\configure.ps1 via PowerShell Direct with C:\Lab\.lab\ctx\<NAME>.json (admin-only ACL)
# Linux guests:   already self-configured by cloud-init; here we wait for readiness and detach the seed disk.
param([string]$Stage = '__STAGE__')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cfg = Get-Content C:\Lab\.lab\lab.settings.json -Raw | ConvertFrom-Json
$sec = Get-Content C:\Lab\.lab\secrets.json -Raw | ConvertFrom-Json
$pw  = ConvertTo-SecureString $sec.GuestAdminPassword -AsPlainText -Force
$nb  = $cfg.Company.NetBios
$configure = 'C:\Lab\roles\windows\configure.ps1'
$credCache = @{}

function Get-GuestCred([string]$Vm, [int]$Minutes = 25) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        foreach ($u in "$nb\Administrator", '.\Administrator', 'Administrator') {
            $c = New-Object PSCredential $u, $pw
            try { if ((Invoke-Command -VMName $Vm -Credential $c { $env:COMPUTERNAME } -ErrorAction Stop) -eq $Vm) { $credCache[$Vm] = $c; return $c } } catch {}
        }
        Start-Sleep -Seconds 15
    }
    throw "$Vm not reachable over PowerShell Direct within $Minutes min"
}
function Get-Ctx([string]$Vm) { Get-Content "C:\Lab\.lab\ctx\$Vm.json" -Raw | ConvertFrom-Json }
function Invoke-Role([string]$Vm, [string]$Phase) {
    $c = if ($credCache[$Vm]) { $credCache[$Vm] } else { Get-GuestCred $Vm }
    Invoke-Command -VMName $Vm -Credential $c -FilePath $configure -ArgumentList (Get-Ctx $Vm), $Phase
}
function Restart-Guest([string]$Vm) {
    Restart-VM -Name $Vm -Force -Wait -For Heartbeat
    Start-Sleep -Seconds 30
    $credCache.Remove($Vm) | Out-Null
    $null = Get-GuestCred $Vm
}
function Test-Ready([string]$Spec, [string]$Ip) {
    $kind, $rest = $Spec -split ':', 2
    $port, $path = $rest -split '/', 2
    if ($kind -eq 'http') {
        try { return (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://${Ip}:$port/$path").StatusCode -lt 500 } catch { return $false }
    }
    $t = New-Object Net.Sockets.TcpClient
    try { return $t.ConnectAsync($Ip, [int]$port).Wait(3000) -and $t.Connected } catch { return $false } finally { $t.Dispose() }
}

$windows = @($cfg.NestedVms | Where-Object { $_.Os -eq 'windows' -and $_.Role -notin 'appliance', 'dc' })
$linux   = @($cfg.NestedVms | Where-Object { $_.Os -ne 'windows' })
$dc      = $cfg.NestedVms | Where-Object Role -eq 'dc'

switch ($Stage) {
'dc' {
    $null = Get-GuestCred $dc.Name 30
    Invoke-Role $dc.Name 'base'
    $isDc = Invoke-Command -VMName $dc.Name -Credential $credCache[$dc.Name] { (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4 }
    if (-not $isDc) {
        Invoke-Role $dc.Name 'dc-promote'
        Restart-Guest $dc.Name
    }
    # The AD PowerShell module talks to AD Web Services; on the WS2022 eval image ADWS can come up Disabled
    # after promotion, so enable + start it explicitly, then wait for the domain to answer.
    $deadline = (Get-Date).AddMinutes(15); $ok = $false
    while (-not $ok -and (Get-Date) -lt $deadline) {
        try {
            $ok = [bool](Invoke-Command -VMName $dc.Name -Credential (Get-GuestCred $dc.Name) -ErrorAction Stop {
                if ((Get-Service ADWS).StartType -ne 'Automatic') { Set-Service ADWS -StartupType Automatic }
                if ((Get-Service ADWS).Status -ne 'Running') { Start-Service ADWS; Start-Sleep -Seconds 15 }
                Import-Module ActiveDirectory -WarningAction SilentlyContinue; (Get-ADDomain).DNSRoot
            })
        } catch { Start-Sleep -Seconds 20 }
    }
    if (-not $ok) { throw 'AD DS did not become ready' }
    Invoke-Role $dc.Name 'dc-post'
    "[ok] $($dc.Name) is the domain controller for $($cfg.Company.Domain)"
}
'members' {
    foreach ($vm in $windows) { $null = Get-GuestCred $vm.Name 30 }
    foreach ($vm in $windows) {
        Invoke-Role $vm.Name 'base'
        $joined = Invoke-Command -VMName $vm.Name -Credential $credCache[$vm.Name] { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
        if (-not $joined) {
            Invoke-Role $vm.Name 'join'
            Restart-Guest $vm.Name
        }
        if ($vm.Role -eq 'sql') { Invoke-Role $vm.Name 'sql' }
    }
    foreach ($vm in $windows) {
        $s = Invoke-Command -VMName $vm.Name -Credential (Get-GuestCred $vm.Name) {
            $cs = Get-CimInstance Win32_ComputerSystem
            $st = $null
            for ($i = 0; $i -lt 3 -and -not $st; $i++) {
                try { $st = Get-Content C:\catlab\deps-status.json -Raw -ErrorAction Stop | ConvertFrom-Json } catch { Start-Sleep -Seconds 2 }
            }
            $ok = if ($st) { @($st.PSObject.Properties | Where-Object { $_.Value.ok }).Count } else { 0 }
            $all = if ($st) { @($st.PSObject.Properties).Count } else { 0 }
            '{0} domain={1} deps={2}/{3}' -f $env:COMPUTERNAME, $cs.Domain, $ok, $all
        }
        "[ok] $s"
    }
}
'linux' {
    foreach ($vm in $linux) {
        $deadline = (Get-Date).AddMinutes(25); $ok = $false
        while (-not $ok -and (Get-Date) -lt $deadline) { $ok = Test-Ready $vm.Ready $vm.Ip; if (-not $ok) { Start-Sleep -Seconds 15 } }
        if (-not $ok) { "[FAIL] $($vm.Name) not ready ($($vm.Ready))"; continue }
        $seed = Get-VMHardDiskDrive -VMName $vm.Name | Where-Object Path -like '*cidata*'
        if ($seed) {
            Start-Sleep -Seconds 20          # let cloud-init finish its final stage
            Stop-VM -Name $vm.Name -Force
            $seed | Remove-VMHardDiskDrive
            Start-VM -Name $vm.Name
            $deadline = (Get-Date).AddMinutes(5); $ok = $false
            while (-not $ok -and (Get-Date) -lt $deadline) { $ok = Test-Ready $vm.Ready $vm.Ip; if (-not $ok) { Start-Sleep -Seconds 10 } }
        }
        $deps = ''
        if (@($vm.Depends).Count -and $vm.Role -ne 'prometheus') {
            try { $st = Invoke-RestMethod -TimeoutSec 5 "http://$($vm.Ip):9109/"; $deps = " deps=$(@($st.PSObject.Properties | Where-Object { $_.Value.ok }).Count)/$(@($st.PSObject.Properties).Count)" } catch { $deps = ' deps=agent-unreachable' }
        }
        "[$(if ($ok) { 'ok' } else { 'FAIL' })] $($vm.Name) ($($vm.Role)) ready on $($vm.Ready)$deps"
    }
}
default { throw "Unknown stage '$Stage'" }
}
