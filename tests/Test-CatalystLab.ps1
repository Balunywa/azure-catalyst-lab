<#
.SYNOPSIS
  End-to-end validation for the Azure Catalyst Hyper-V lab. Run from your laptop.
.DESCRIPTION
  Azure-side checks use the Azure CLI/ARM REST. Host, nested-VM and appliance checks are gathered in a single
  Run Command call (host\90-Probe.ps1), so no inbound ports are needed.
.EXAMPLE
  ./tests/Test-CatalystLab.ps1
  ./tests/Test-CatalystLab.ps1 -Phase Infra,Host,Nested,Appliance
#>
[CmdletBinding()]
param([string[]]$Phase = @('Infra', 'Host', 'Nested', 'Appliance', 'Discovery', 'Assessment', 'Replication', 'TestMigration'))

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/LabCommon.ps1')
$all = 'Infra', 'Host', 'Nested', 'Appliance', 'Discovery', 'Assessment', 'Replication', 'TestMigration'
$Phase = $Phase -split ',' | ForEach-Object { $_.Trim() }
if ($bad = $Phase | Where-Object { $_ -notin $all }) { throw "Unknown phase(s): $bad. Use: $($all -join ', ')" }
$ErrorActionPreference = 'Continue'
$cfg = Get-LabConfig
$rg  = $cfg.ResourceGroup
$sub = $cfg.SubscriptionId
$crg = if ($cfg.PSObject.Properties['CatalystResourceGroup'] -and $cfg.CatalystResourceGroup) { $cfg.CatalystResourceGroup } else { $rg }   # where the Catalyst project lives
$results = [System.Collections.Generic.List[object]]::new()

function Test-Case([string]$Phase, [string]$Name, [scriptblock]$Check) {
    try {
        $r = & $Check
        if ($r -is [array]) { $r = $r[-1] }
        if ($r -is [bool]) { $pass = $r; $detail = '' }
        else { $detail = "$r"; $pass = [bool]$detail -and $detail -notmatch '^FAIL' }
    } catch { $pass = $false; $detail = $_.Exception.Message.Split("`n")[0] }
    $tag = if ($pass) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{ Phase = $Phase; Test = $Name; Result = $tag; Detail = "$detail" })
    Write-Host ("  [{0}] {1,-13} {2}  {3}" -f $tag, $Phase, $Name, $detail) -ForegroundColor $(if ($pass) { 'Green' } else { 'Red' })
}
function ArmGet([string]$Path) {
    $out = az rest --method get --url "https://management.azure.com$Path" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $out | ConvertFrom-Json
}
function Get-LabResource([string]$Type) {
    # Resources in the Catalyst RG; when it holds several projects, keep the ones named after ours
    $all = @(az resource list -g $crg --subscription $sub --resource-type $Type -o json 2>$null | ConvertFrom-Json)
    $mine = @($all | Where-Object { $_.name -like "$($cfg.MigrateProjectName)*" })
    if ($mine) { $mine } elseif ($Type -like 'Microsoft.Migrate/migrateProjects') { @() } else { $all }
}

# Test-migrated VMs (needed by the probe so the host can curl them over the VNet)
$tmVms = @(az vm list -g $rg --subscription $sub -d -o json 2>$null | ConvertFrom-Json |
           Where-Object { $_.name -ne $cfg.HostVmName -and $_.name -match '(?i)web01|lnx01' })

$probe = $null
if ($Phase | Where-Object { $_ -in 'Host', 'Nested', 'Appliance', 'TestMigration' }) {
    Write-Step 'Collecting host facts (one Run Command call, ~30 s)'
    $script = (Get-Content (Join-Path $HostDir '90-Probe.ps1') -Raw).Replace('__TMIPS__', (($tmVms.privateIps) -join ','))
    $raw = Invoke-LabHostRaw -ScriptText $script -NoThrow -Label 'probe'
    try { $probe = ($raw | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
    if (-not $probe) { Write-Warning "Probe failed: $($raw -join ' ')" }
}
function P { param($f) if (-not $probe) { throw 'no probe data' }; & $f }

# ----------------------------------------------------------------------------------------------- Infra
if ('Infra' -in $Phase) {
    Write-Step 'Infra (Azure)'
    Test-Case Infra 'Resource group exists' { (az group exists -n $rg --subscription $sub) -eq 'true' }
    $vm = az vm get-instance-view -g $rg -n $cfg.HostVmName --subscription $sub -o json 2>$null | ConvertFrom-Json
    Test-Case Infra 'Host VM running' {
        $s = ($vm.instanceView.statuses | Where-Object code -like 'PowerState*').displayStatus
        if ($s -eq 'VM running') { $s } else { "FAIL: $s" } }
    Test-Case Infra "Host VM size $($cfg.HostVmSize) (nested virtualization)" {
        if ($vm.hardwareProfile.vmSize -eq $cfg.HostVmSize) { $vm.hardwareProfile.vmSize } else { "FAIL: $($vm.hardwareProfile.vmSize)" } }
    Test-Case Infra 'NSG has no inbound allow from Internet/*' {
        $rules = az network nsg rule list -g $rg --nsg-name "$($cfg.NamePrefix)-nsg" --subscription $sub -o json | ConvertFrom-Json
        $open = $rules | Where-Object { $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' -and ($_.sourceAddressPrefix -in '*', '0.0.0.0/0', 'Internet') }
        if ($open) { "FAIL: open rules $($open.name -join ',')" } else { "$(@($rules).Count) rules, all from $(($rules.sourceAddressPrefix | Select-Object -Unique) -join ',')" } }
    Test-Case Infra 'Azure Bastion provisioned' {
        $b = @(az network bastion list -g $rg --subscription $sub -o json 2>$null | ConvertFrom-Json)
        if ($b -and $b[0].provisioningState -eq 'Succeeded') { "$($b[0].name) ($($b[0].sku.name))" } else { 'FAIL: no bastion' } }
    Test-Case Infra 'Run Command reaches host' { [bool]$probe }
}

# ------------------------------------------------------------------------------------------------ Host
if ('Host' -in $Phase) {
    Write-Step 'Host (Hyper-V on Windows Server 2022)'
    Test-Case Host 'OS is Windows Server 2022'            { P { if ($probe.os -match '2022') { $probe.os } else { "FAIL: $($probe.os)" } } }
    Test-Case Host 'Hyper-V installed, vmms running'      { P { "$($probe.hv)/$($probe.vmms)" -eq 'Installed/Running' } }
    Test-Case Host 'Nested virtualization (VMs running)'  { P { $n = @($probe.vms | Where-Object s -eq 'Running').Count; if ($n) { "$n running" } else { 'FAIL: 0 running' } } }
    Test-Case Host 'LabSwitch internal + LabNat'          { P { $probe.sw -eq 'Internal' -and $probe.nat -eq '192.168.100.0/24' } }
    Test-Case Host "DHCP scope active, $(@($cfg.NestedVms).Count) reservations" { P { if ($probe.dhcp -eq 'Active' -and $probe.resv -eq @($cfg.NestedVms).Count) { "$($probe.resv) reservations" } else { "FAIL: $($probe.dhcp) / $($probe.resv)" } } }
    Test-Case Host 'Nested VM memory within host budget'  { P { if ($probe.ramGB -le 56) { "$($probe.ramGB) GB assigned of 64 GB" } else { "FAIL: $($probe.ramGB) GB assigned" } } }
    Test-Case Host 'Discovery account in 3 groups'        { P { if ($probe.grp -eq 3) { '3/3' } else { "FAIL: $($probe.grp)/3" } } }
    Test-Case Host 'WinRM HTTP + HTTPS listeners'         { P { $l = $probe.winrm -split ','; if ($l -contains 'HTTP' -and $l -contains 'HTTPS') { $probe.winrm } else { "FAIL: $($probe.winrm)" } } }
}

# ---------------------------------------------------------------------------------------------- Nested
if ('Nested' -in $Phase) {
    Write-Step "Company estate: $(@($cfg.NestedVms).Count) VMs"
    foreach ($v in $cfg.NestedVms) {
        Test-Case Nested "$($v.Name) running, heartbeat OK, IP $($v.Ip)" { P {
            $m = $probe.vms | Where-Object n -eq $v.Name
            $d = "$($m.s)/$($m.hb)/$($m.ip)"
            if ($m.s -eq 'Running' -and $m.hb -match '^Ok' -and $m.ip -match [regex]::Escape($v.Ip)) { $d } else { "FAIL: $d" } } }
        if ($v.Ready) {
            Test-Case Nested "$($v.Name) $($v.Role) service up ($($v.Ready))" { P { [bool]($probe.vms | Where-Object n -eq $v.Name).r } }
        }
        if (@($v.Depends).Count -and $v.Role -ne 'prometheus') {
            Test-Case Nested "$($v.Name) live dependency sessions" { P {
                $d = ($probe.vms | Where-Object n -eq $v.Name).d
                if ($d -match '^(\d+)/(\d+)$' -and $Matches[1] -eq $Matches[2] -and [int]$Matches[2] -gt 0) { "$d upstreams connected" } else { "FAIL: $d" } } }
        }
        if ($v.Os -eq 'windows' -and $v.Role -notin 'appliance') {
            Test-Case Nested "$($v.Name) joined $($cfg.Company.Domain)" { P {
                $dom = ($probe.vms | Where-Object n -eq $v.Name).dom
                if ($dom -eq $cfg.Company.Domain) { $dom } else { "FAIL: '$dom'" } } }
        }
    }
    Test-Case Nested 'CAT-WEB01 serves IIS storefront'              { P { [bool]$probe.web } }
    Test-Case Nested 'CAT-LNX01 public site serves marker'          { P { [bool]$probe.lnx } }
    Test-Case Nested 'CAT-LNX01 /shop/ proxies to CAT-WEB01'        { P { [bool]$probe.proxy } }
    Test-Case Nested 'Inventory API returns items (PostgreSQL+Redis)' { P { [bool]$probe.api } }
    Test-Case Nested 'Nested VMs reach Azure through NAT'           { P { [bool]$probe.inet } }
}

# ------------------------------------------------------------------------------------------- Appliance
if ('Appliance' -in $Phase) {
    Write-Step 'Azure Catalyst appliance'
    Test-Case Appliance 'Appliance services all running'      { P { if ($probe.asvc -match '^(\d+)/(\d+)$' -and $Matches[1] -eq $Matches[2] -and [int]$Matches[2] -ge 5) { "$($probe.asvc) Microsoft Azure * services" } else { "FAIL: $($probe.asvc)" } } }
    Test-Case Appliance 'Config manager listening on 44368'   { P { [bool]$probe.aport } }
    Test-Case Appliance 'Host NAT publishes 44368'            { P { [bool]$probe.map } }
}

# ------------------------------------------------------------------------------------------- Discovery
if ('Discovery' -in $Phase) {
    Write-Step 'Catalyst project + discovery (CMDB CSV import and/or appliance)'
    $proj = Get-LabResource 'Microsoft.Migrate/migrateProjects' | Select-Object -First 1
    Test-Case Discovery 'Catalyst (Migrate) project exists' { if ($proj) { $proj.name } else { "FAIL: none in $crg" } }
    $importSites = @(Get-LabResource 'Microsoft.OffAzure/ImportSites')
    $hvSites     = @(Get-LabResource 'Microsoft.OffAzure/HyperVSites')
    Test-Case Discovery 'Discovery source present' {
        $src = @()
        if ($importSites) { $src += "CMDB CSV import ($($importSites[0].name))" }
        if ($hvSites)     { $src += "Hyper-V appliance ($($hvSites[0].name))" }
        if ($src) { $src -join ' + ' } else { "FAIL: no ImportSites or HyperVSites in $crg" } }
    foreach ($site in $hvSites) {
        Test-Case Discovery 'Appliance registered + heartbeat < 60 min' {
            $s = ArmGet "$($site.id)?api-version=2023-06-06"
            $hb = $s.properties.agentDetails.lastHeartBeatUtc
            if ($hb -and ((Get-Date).ToUniversalTime() - ([datetime]$hb).ToUniversalTime()).TotalMinutes -lt 60) { "$($site.name), agent v$($s.properties.agentDetails.version), heartbeat $hb" } else { "FAIL: heartbeat '$hb'" } }
    }
    $machines = @(foreach ($site in @($importSites) + @($hvSites)) {
        foreach ($api in '2023-06-06', '2020-07-07', '2020-01-01-preview') {
            $r = ArmGet "$($site.id)/machines?api-version=$api"
            if ($r.value) { $r.value | ForEach-Object { $_ | Add-Member -NotePropertyName _source -NotePropertyValue ($site.type -replace '.*/') -PassThru }; break }
        }
    })
    foreach ($n in 'CAT-WEB01', 'CAT-LNX01') {
        Test-Case Discovery "$n discovered" {
            $m = $machines | Where-Object { $_.properties.displayName -eq $n -or $_.properties.machineName -eq $n -or $_.name -eq $n } | Select-Object -First 1
            if (-not $m) { return "FAIL: not among $($machines.Count) machines" }
            $pr = $m.properties
            $os = if ($pr.operatingSystemDetails.osName) { $pr.operatingSystemDetails.osName } else { $pr.operatingSystemName }
            $cpu = if ($pr.numberOfProcessorCore) { $pr.numberOfProcessorCore } else { $pr.numberOfCores }
            $mem = if ($pr.allocatedMemoryInMb) { $pr.allocatedMemoryInMb } else { $pr.megabytesOfMemory }
            "[$($m._source)] $os | $cpu cores | $mem MB" }
    }
}

# ------------------------------------------------------------------------------------------ Assessment
if ('Assessment' -in $Phase) {
    Write-Step 'Assessment'
    $ap = Get-LabResource 'Microsoft.Migrate/assessmentProjects' | Select-Object -First 1
    Test-Case Assessment 'Assessment project exists' { if ($ap) { $ap.name } else { 'FAIL: none' } }
    if ($ap) {
        $assessments = @(foreach ($g in (ArmGet "$($ap.id)/groups?api-version=2019-10-01").value) { (ArmGet "$($g.id)/assessments?api-version=2019-10-01").value })
        Test-Case Assessment 'Completed Azure VM assessment' {
            $done = $assessments | Where-Object { $_.properties.status -eq 'Completed' }
            if ($done) { "$(@($done).Count) completed: $($done.name -join ', ')" } else { "FAIL: $($assessments.Count) found, none Completed" } }
        Test-Case Assessment 'CAT-WEB01 + CAT-LNX01 suitable for Azure' {
            $a = $assessments | Where-Object { $_.properties.status -eq 'Completed' } | Select-Object -First 1
            if (-not $a) { return 'FAIL: no completed assessment' }
            $am = (ArmGet "$($a.id)/assessedMachines?api-version=2019-10-01").value
            $sum = $am | ForEach-Object { "$($_.properties.displayName)=$($_.properties.suitability)/$($_.properties.recommendedSize)" }
            $bad = $am | Where-Object { $_.properties.displayName -in 'CAT-WEB01', 'CAT-LNX01' -and $_.properties.suitability -notin 'Suitable', 'ConditionallySuitable' }
            if ($am -and -not $bad) { $sum -join '; ' } else { "FAIL: $($sum -join '; ')" } }
    }
}

# ----------------------------------------------------------------------------------------- Replication
if ('Replication' -in $Phase) {
    Write-Step 'Replication (Hyper-V provider -> Azure)'
    $vault = Get-LabResource 'Microsoft.RecoveryServices/vaults' | Select-Object -First 1
    Test-Case Replication 'Migration vault exists' { if ($vault) { $vault.name } else { 'FAIL: none' } }
    if ($vault) {
        $api = 'api-version=2024-04-01'
        Test-Case Replication 'Host registered with the replication provider' {
            $fab = (ArmGet "$($vault.id)/replicationFabrics?$api").value
            $prov = foreach ($f in $fab) { (ArmGet "$($f.id)/replicationRecoveryServicesProviders?$api").value }
            $p = $prov | Where-Object { $_.properties.friendlyName -match $cfg.HostVmName }
            if ($p) { "$($p.properties.friendlyName) $($p.properties.connectionStatus) v$($p.properties.providerVersion)" } else { 'FAIL: provider not registered' } }
        $items = (ArmGet "$($vault.id)/replicationProtectedItems?$api").value
        foreach ($n in 'CAT-WEB01', 'CAT-LNX01') {
            Test-Case Replication "$n protected and healthy" {
                $i = $items | Where-Object { $_.properties.friendlyName -eq $n }
                if (-not $i) { return 'FAIL: not replicating' }
                $st = "$($i.properties.protectionState)/$($i.properties.replicationHealth)"
                if ($i.properties.protectionState -match 'Protected|TestMigration|Migration' -and $i.properties.replicationHealth -ne 'Critical') { $st } else { "FAIL: $st" } }
        }
    }
}

# --------------------------------------------------------------------------------------- TestMigration
if ('TestMigration' -in $Phase) {
    Write-Step 'Test migration'
    Test-Case TestMigration 'Test-migrated VM exists in Azure' {
        if ($tmVms) { ($tmVms | ForEach-Object { "$($_.name) [$($_.powerState)] $($_.privateIps)" }) -join '; ' } else { 'FAIL: none (start a test migration first)' } }
    foreach ($v in $tmVms) {
        $marker = if ($v.name -match '(?i)web01') { 'windows-iis' } else { 'debian-nginx' }
        Test-Case TestMigration "$($v.name) serves its app from Azure" { P {
            $t = $probe.tm | Where-Object ip -eq $v.privateIps
            if ($t.body -match $marker) { "http://$($v.privateIps)/ -> $marker" } else { "FAIL: $($t.body)" } } }
    }
}

# -------------------------------------------------------------------------------------------- Summary
$pass = @($results | Where-Object Result -eq 'PASS').Count
$fail = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "`n$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Yellow' } else { 'Green' })
$out = Join-Path $LabRoot 'logs'; New-Item -ItemType Directory -Force $out | Out-Null
$results | Export-Csv (Join-Path $out "test-results-$(Get-Date -Format yyyyMMdd-HHmmss).csv")
if ($fail) { exit 1 }
