# Runs ON the Hyper-V host (Windows PowerShell 5.1). Renders per-VM configuration from lab.settings.json:
#   Linux:   C:\Lab\seeds\<NAME>\{user-data,meta-data,network-config}  (cloud-init NoCloud seed)
#   Windows: C:\Lab\.lab\ctx\<NAME>.json  (role context for roles\windows\configure.ps1)
# Role scripts and dependency agents come from C:\Lab\repo\roles.
param([string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json', [string]$SecretsPath = 'C:\Lab\.lab\secrets.json',
      [string]$RolesDir = 'C:\Lab\repo\roles')
$ErrorActionPreference = 'Stop'
$cfg   = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sec   = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$utf8  = New-Object Text.UTF8Encoding $false
function B64([string]$s) { [Convert]::ToBase64String($utf8.GetBytes(($s -replace "`r`n", "`n"))) }
function Write-Lf([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}
$ipOf = @{}; foreach ($v in $cfg.NestedVms) { $ipOf[$v.Name] = $v.Ip }
$dc   = $cfg.NestedVms | Where-Object Role -eq 'dc'

function ConvertTo-Deps($vm) {
    foreach ($d in @($vm.Depends)) {
        $name, $rest = $d -split ':', 2
        $port, $proto = $rest -split '/', 2
        [ordered]@{ name = $name; host = $ipOf[$name]; port = [int]$port; proto = $(if ($proto) { $proto } else { 'tcp' }); path = '/' }
    }
}
$linuxPackages = @{
    'web-proxy' = 'nginx'; 'postgres' = 'postgresql'; 'redis' = 'redis-server'; 'rabbitmq' = 'rabbitmq-server'
    'prometheus' = 'prometheus'; 'inventory-api' = 'python3-psycopg2, python3-redis'
    'orders-worker' = 'python3-pika, python3-psycopg2, smbclient'; 'legacy-edi' = 'vsftpd, smbclient'
}
# ReadAllText, not Get-Content -Raw: in Windows PowerShell 5.1 the latter adds PSPath/... note properties
# and ConvertTo-Json then serialises the string as an object instead of text.
$agentPy   = [IO.File]::ReadAllText((Join-Path $RolesDir 'linux\catlab-deps.py'))
$roleSh    = [IO.File]::ReadAllText((Join-Path $RolesDir 'linux\role.sh'))
$agentPs   = [IO.File]::ReadAllText((Join-Path $RolesDir 'windows\catlab-deps.ps1'))
$envCommon = ($cfg.NestedVms | ForEach-Object { '{0}="{1}"' -f ($_.Name -replace '-', '_'), $_.Ip }) -join "`n"
$domain    = $cfg.Company.Domain

foreach ($vm in $cfg.NestedVms | Where-Object { $_.Os -ne 'windows' }) {
    $h = $vm.Name.ToLower()
    $deps = if ($vm.Role -eq 'prometheus') { @() } else { @(ConvertTo-Deps $vm) }
    $prom = (@($vm.Depends) | ForEach-Object { $n, $p = $_ -split ':'; "'$($ipOf[$n]):$p'" }) -join ','
    $envFile = "ROLE=`"$($vm.Role)`"`nAPP_PW=`"$($sec.AppPassword)`"`nPROM_TARGETS=`"$prom`"`n$envCommon`n"
    $pkgs = @('hyperv-daemons', 'prometheus-node-exporter', 'python3', 'curl') + @(($linuxPackages[$vm.Role] -split ',\s*') | Where-Object { $_ })
    $unit = "[Unit]`nDescription=Catlab dependency agent`nAfter=network-online.target`n[Service]`nExecStart=/usr/bin/python3 /usr/local/bin/catlab-deps.py`nRestart=always`nRestartSec=5`n[Install]`nWantedBy=multi-user.target`n"
    $depsJson = if (@($deps).Count) { ConvertTo-Json -InputObject @($deps) -Depth 3 -Compress } else { '[]' }
    $userData = @"
#cloud-config
hostname: $h
fqdn: $h.$domain
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
packages: [$($pkgs -join ', ')]
write_files:
  - {path: /etc/catlab/env, permissions: '0600', encoding: b64, content: $(B64 $envFile)}
  - {path: /etc/catlab/deps.json, encoding: b64, content: $(B64 $depsJson)}
  - {path: /usr/local/bin/catlab-deps.py, permissions: '0755', encoding: b64, content: $(B64 $agentPy)}
  - {path: /usr/local/sbin/catlab-role.sh, permissions: '0755', encoding: b64, content: $(B64 $roleSh)}
  - {path: /etc/systemd/system/catlab-deps.service, encoding: b64, content: $(B64 $unit)}
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, hv-kvp-daemon]
  - [bash, -c, "/usr/local/sbin/catlab-role.sh > /var/log/catlab-role.log 2>&1"]
  - [systemctl, enable, --now, catlab-deps]
  - [touch, /etc/cloud/cloud-init.disabled]
"@
    $dir = "C:\Lab\seeds\$($vm.Name)"
    Write-Lf "$dir\user-data" $userData
    Write-Lf "$dir\meta-data" "instance-id: $h-$($vm.Role)-001`nlocal-hostname: $h`n"
    # dhcp-identifier: mac so the host's MAC-based DHCP reservation matches (systemd-networkd defaults to DUID)
    Write-Lf "$dir\network-config" "version: 2`nethernets:`n  eth0:`n    match:`n      name: eth0`n    dhcp4: true`n    dhcp-identifier: mac`n"
    "[ok] $($vm.Name): seed ($($vm.Role); $(@($deps).Count) deps)"
}

foreach ($vm in $cfg.NestedVms | Where-Object { $_.Os -eq 'windows' -and $_.Role -ne 'appliance' }) {
    $ctx = [ordered]@{
        Name = $vm.Name; Role = $vm.Role; Ip = $vm.Ip; AppPw = $sec.AppPassword; AdminPw = $sec.GuestAdminPassword
        Domain = $domain; NetBios = $cfg.Company.NetBios; DcIp = $dc.Ip
        Deps = @(ConvertTo-Deps $vm); AgentScript = $agentPs
        AcceptSql = [bool]$cfg.AcceptSqlExpressLicense; SqlUrl = $cfg.Downloads.SqlExpress2022Bootstrapper
        Servers = $ipOf
    }
    Write-Lf "C:\Lab\.lab\ctx\$($vm.Name).json" ($ctx | ConvertTo-Json -Depth 4)
    "[ok] $($vm.Name): role context ($($vm.Role); $(@($ctx.Deps).Count) deps)"
}
New-Item -ItemType Directory -Force C:\Lab\roles\windows | Out-Null
Copy-Item (Join-Path $RolesDir 'windows\configure.ps1') C:\Lab\roles\windows\configure.ps1 -Force
'[ok] roles\windows\configure.ps1 staged'
