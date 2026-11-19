<#
.SYNOPSIS
  Build the lab CMDB from real Hyper-V inventory and export it in Azure Catalyst's CSV import format.
.DESCRIPTION
  1. Discovery: host\50-Export-Inventory.ps1 reads each nested VM's hardware (Hyper-V) and OS identity (guest KVP).
  2. CMDB:      merges that with business context from lab.settings.json NestedVms (application, role, environment,
                support group, migration intent, target) -> cmdb\cmdb.csv (one CI per server) and
                cmdb\cmdb_rel_ci.csv (Depends on::Used by relationships).
  3. Export:    maps CMDB fields onto Catalyst's import template (header taken verbatim from
                https://go.microsoft.com/fwlink/?linkid=2109031) -> cmdb\catalyst-import.csv,
                for every workload server (the appliance is excluded). Then validates the file.
  Upload catalyst-import.csv in the portal: project > Discover > Import using CSV.
#>
[CmdletBinding()]
param()
. "$PSScriptRoot/LabCommon.ps1"
$cfg = Get-LabConfig
$outDir = Join-Path $LabRoot 'cmdb'
New-Item -ItemType Directory -Force $outDir | Out-Null

# --- 1. Discovery ---------------------------------------------------------------------------------
Write-Step 'Discovering servers on the Hyper-V host (Hyper-V + guest KVP)'
$raw = Invoke-LabHostScript -Name '50-Export-Inventory.ps1'
$line = $raw | Where-Object { $_ -like 'GZ:*' -or $_ -like '{*' } | Select-Object -Last 1
if ($line -like 'GZ:*') {
    $ms = New-Object IO.MemoryStream (, [Convert]::FromBase64String($line.Substring(3)))
    $line = (New-Object IO.StreamReader (New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress))).ReadToEnd()
}
$inv = $line | ConvertFrom-Json
Write-Ok "$($inv.vms.Count) servers discovered at $($inv.at)"

# --- 2. CMDB --------------------------------------------------------------------------------------
Write-Step 'Building the CMDB (cmdb\cmdb.csv)'
$cmdb = foreach ($v in $inv.vms) {
    $ctx = $cfg.NestedVms | Where-Object Name -eq $v.n
    if (-not $ctx) { Write-Warning "$($v.n) is not in lab.settings.json NestedVms -> marked unassigned"; $ctx = [pscustomobject]@{ App = 'unassigned'; Tier = ''; Environment = 'Unknown'; SupportGroup = ''; MigrationIntent = 'Assess'; TargetHint = ''; OsVersion = ''; Role = '' } }
    $isWin = $v.os -match 'Windows'
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("catlab/$($v.n)"))
    [pscustomobject][ordered]@{
        sys_id            = -join ($sha[0..15] | ForEach-Object { $_.ToString('x2') })   # stable CI id
        name              = $v.n
        fqdn              = $v.fqdn
        sys_class_name    = if ($isWin) { 'cmdb_ci_win_server' } else { 'cmdb_ci_linux_server' }
        ip_address        = $v.ip
        mac_address       = $v.mac
        cpu_core_count    = $v.cpu
        ram_mb            = $v.mem
        os                = $v.os
        os_version        = if ($ctx.OsVersion) { $ctx.OsVersion } else { $v.osv }
        kernel_or_build   = $v.osv
        os_address_width  = 64
        virtual           = 'true'
        hypervisor        = 'Hyper-V'
        hosted_on         = $v.host
        boot_type         = if ($v.gen -eq 2) { 'UEFI' } else { 'BIOS' }
        disk_count        = @($v.dgb).Count
        disk_sizes_gb     = (@($v.dgb) -join ';')
        storage_used_gb   = $v.used
        nic_count         = $v.nic
        cpu_util_pct      = $v.cpuu
        mem_util_pct      = $v.memu
        application       = $ctx.App
        role              = $ctx.Role
        tier              = $ctx.Tier
        environment       = $ctx.Environment
        support_group     = $ctx.SupportGroup
        migration_intent  = $ctx.MigrationIntent
        target_hint       = $ctx.TargetHint
        discovery_source  = "Hyper-V KVP via $($v.host)"
        last_discovered   = ([datetime]$inv.at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}
$cmdbPath = Join-Path $outDir 'cmdb.csv'
$cmdb | Export-Csv $cmdbPath -UseQuotes AsNeeded -Encoding utf8
$cmdb | Format-Table name, os, cpu_core_count, ram_mb, application, role, migration_intent, target_hint -AutoSize | Out-String -Width 200 | ForEach-Object { $_.TrimEnd() }

# Relationships (ServiceNow-style cmdb_rel_ci): parent "Depends on" child, from each server's Depends list
$rel = foreach ($vm in $cfg.NestedVms) {
    foreach ($d in @($vm.Depends)) {
        $child, $rest = $d -split ':', 2; $port, $proto = $rest -split '/', 2
        [pscustomobject][ordered]@{
            parent = $vm.Name; parent_app = $vm.App; type = 'Depends on::Used by'; child = $child
            child_app = ($cfg.NestedVms | Where-Object Name -eq $child).App; port = [int]$port
            protocol = $(if ($proto) { $proto } else { 'tcp' })
        }
    }
}
$rel | Export-Csv (Join-Path $outDir 'cmdb_rel_ci.csv') -UseQuotes AsNeeded -Encoding utf8
Write-Ok "$(@($rel).Count) relationships -> cmdb\cmdb_rel_ci.csv"
$apps = $cmdb | Where-Object application -ne 'migration-tooling' | Group-Object application
Write-Ok "$(@($cmdb | Where-Object application -ne 'migration-tooling').Count) workload servers across $($apps.Count) applications/services"


# --- 3. Catalyst import export --------------------------------------------------------------------
Write-Step 'Exporting to the Azure Catalyst import template (cmdb\catalyst-import.csv)'
$header = '*Server name,IP addresses,*Cores,*Memory (In MB),*OS name,OS version,OS architecture,Server type,Hypervisor,CPU utilization percentage,Memory utilization percentage,Network adapters,Network In throughput,Network Out throughput,Boot type,Number of disks,Storage in use (In GB),Disk 1 size (In GB),Disk 1 read throughput (MB per second),Disk 1 write throughput (MB per second),Disk 1 read ops (operations per second),Disk 1 write ops (operations per second),Disk 2 size (In GB),Disk 2 read throughput (MB per second),Disk 2 write throughput (MB per second),Disk 2 read ops (operations per second),Disk 2 write ops (operations per second)'
$cols = $header -split ','

function ConvertTo-CatalystOsName($ci) {
    # Catalyst recognizes OS names that contain an entry from its supported list ("Windows Server 2022", "Debian GNU/Linux 12" ...)
    switch -Regex ($ci.os) {
        'Windows Server (\d{4})' { return "Microsoft Windows Server $($Matches[1]) (64-bit)" }
        'Debian'                 { return "Debian GNU/Linux $($ci.os_version)" }
        'Ubuntu'                 { return "Ubuntu Linux $($ci.os_version)" }
        default                  { return $ci.os }
    }
}

$rows = foreach ($ci in $cmdb | Where-Object { $_.role -ne 'appliance' }) {   # assess every workload; intent lives in the CMDB
    $disks = @($ci.disk_sizes_gb -split ';' | Where-Object { $_ })
    $r = [ordered]@{}; foreach ($c in $cols) { $r[$c] = '' }
    $r['*Server name']          = $ci.name
    $r['IP addresses']          = $ci.ip_address
    $r['*Cores']                = $ci.cpu_core_count
    $r['*Memory (In MB)']       = $ci.ram_mb
    $r['*OS name']              = ConvertTo-CatalystOsName $ci
    $r['OS version']            = $ci.os_version
    $r['OS architecture']       = 'x64'
    $r['Server type']           = 'Virtual'
    $r['Hypervisor']            = 'Hyper-V'
    # Utilization left blank on purpose: a one-off snapshot of an idle lab VM (~0% CPU) would make
    # performance-based sizing pick undersized SKUs. Blank = Catalyst sizes "as on-premises".
    $r['Network adapters']      = $ci.nic_count
    $r['Boot type']             = $ci.boot_type
    $r['Number of disks']       = $ci.disk_count
    $r['Storage in use (In GB)'] = $ci.storage_used_gb
    if ($disks.Count -ge 1) { $r['Disk 1 size (In GB)'] = $disks[0] }
    if ($disks.Count -ge 2) { $r['Disk 2 size (In GB)'] = $disks[1] }
    [pscustomobject]$r
}
$importPath = Join-Path $outDir 'catalyst-import.csv'
$rows | Export-Csv $importPath -UseQuotes AsNeeded -Encoding utf8BOM

# --- Validate -------------------------------------------------------------------------------------
$lines = Get-Content $importPath
$problems = @()
if ($lines[0].TrimStart([char]0xFEFF) -ne $header) { $problems += 'header does not match the Catalyst template' }
$parsed = Import-Csv $importPath
foreach ($p in $parsed) {
    foreach ($m in '*Server name', '*Cores', '*Memory (In MB)', '*OS name') { if (-not $p.$m) { $problems += "$($p.'*Server name'): missing $m" } }
    if ($p.'*Cores' -notmatch '^\d+$' -or $p.'*Memory (In MB)' -notmatch '^\d+$') { $problems += "$($p.'*Server name'): cores/memory not integers" }
}
if ($problems) { throw "catalyst-import.csv failed validation:`n - $($problems -join "`n - ")" }
Write-Ok "$($parsed.Count) servers exported (appliance excluded); header matches template; mandatory fields present"
$parsed | Format-Table '*Server name', '*Cores', '*Memory (In MB)', '*OS name', 'Boot type', 'Disk 1 size (In GB)' -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() }
Write-Host "`nUpload: $importPath" -ForegroundColor Yellow
