# Shared helpers for the Azure Catalyst Hyper-V lab. Runs in PowerShell 7 on Windows, macOS, Linux or
# Azure Cloud Shell. Dot-source it:  . "$PSScriptRoot/LabCommon.ps1"

$ErrorActionPreference = 'Stop'
$script:LabRoot  = Split-Path -Parent $PSScriptRoot
$script:LabDir   = Join-Path $LabRoot '.lab'          # your secrets + state (git-ignored)
$script:HostDir  = Join-Path $LabRoot 'host'          # scripts that run ON the Hyper-V host
if (-not (Test-Path $LabDir)) { New-Item -ItemType Directory -Path $LabDir | Out-Null }

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    [ok] $Message" -ForegroundColor Green }

function Get-LabConfig {
    # lab.settings.json (public defaults) overlaid with lab.settings.local.json (yours, git-ignored).
    $cfg = Get-Content (Join-Path $LabRoot 'lab.settings.json') -Raw | ConvertFrom-Json
    $localPath = Join-Path $LabRoot 'lab.settings.local.json'
    if (Test-Path $localPath) {
        $local = Get-Content $localPath -Raw | ConvertFrom-Json
        foreach ($p in $local.PSObject.Properties) {
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.$($p.Name) = $p.Value }
            else { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        }
    }
    if (-not $cfg.SubscriptionId) {
        $sel = if ($cfg.PSObject.Properties['SubscriptionName'] -and $cfg.SubscriptionName) { @('--subscription', $cfg.SubscriptionName) } else { @() }
        $id = az account show @sel --query id -o tsv 2>$null
        if (-not $id) { throw "No Azure subscription selected. Run 'az login' (and 'az account set -s <id>') first." }
        $cfg.SubscriptionId = $id
    }
    if (-not $cfg.CatalystResourceGroup) { $cfg.CatalystResourceGroup = $cfg.ResourceGroup }
    $cfg
}

function Set-LabLocalSettings([hashtable]$Values) {
    # Persists your environment-specific values (subscription, RG, region...) to lab.settings.local.json.
    $path = Join-Path $LabRoot 'lab.settings.local.json'
    $h = [ordered]@{}
    if (Test-Path $path) { (Get-Content $path -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    foreach ($k in $Values.Keys) { $h[$k] = $Values[$k] }
    $h | ConvertTo-Json -Depth 4 | Set-Content $path -Encoding utf8
}

function Protect-LabFile([string]$Path) {
    if ($IsWindows) { icacls $Path /inheritance:r /grant:r "$([Environment]::UserName):F" | Out-Null }
    else { chmod 600 $Path }
}

function New-LabPassword([int]$Length = 20) {
    # Only characters that survive az.cmd, ssh, XML and PowerShell quoting unescaped.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '@#-_+.')
    $all  = -join $sets
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[$rng::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }
    -join ($chars | Sort-Object { $rng::GetInt32([int]::MaxValue) })
}

function Get-LabSecrets {
    $path = Join-Path $LabDir 'secrets.json'
    if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json }
    $s = [pscustomobject]@{
        HostAdminPassword  = New-LabPassword   # labadmin on the Azure host VM
        GuestAdminPassword = New-LabPassword   # Administrator / labadmin inside nested VMs
        DiscoveryUser      = 'catdiscovery'    # least-privilege account the appliance uses on the host
        DiscoveryPassword  = New-LabPassword
    }
    $s | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
    Protect-LabFile $path
    $s
}

function Get-LabState {
    $path = Join-Path $LabDir 'state.json'
    if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
}
function Set-LabState([hashtable]$Values) {
    $state = Get-LabState
    foreach ($k in $Values.Keys) { $state[$k] = $Values[$k] }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $LabDir 'state.json') -Encoding utf8
}

function Invoke-Az {
    # Runs az with the lab subscription pinned and returns parsed JSON (or $null).
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $cfg = $script:Cfg; if (-not $cfg) { $cfg = $script:Cfg = Get-LabConfig }
    $out = & az @Arguments --subscription $cfg.SubscriptionId -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $shown = for ($i = 0; $i -lt $Arguments.Count; $i++) {
            if ($i -gt 0 -and $Arguments[$i - 1] -match 'password|secret|key-value') { '***' } else { $Arguments[$i] }
        }
        throw "az $($shown -join ' ') failed:`n$($out -join "`n")"
    }
    $text = ($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($text.Trim()) { $text | ConvertFrom-Json } else { $null }
}

# --- Host access -------------------------------------------------------------------------------------
# Everything that runs ON the Hyper-V host goes through Azure Run Command (HTTPS to ARM), not SSH/WinRM.
# That works from locked-down corporate devices (many block outbound SSH/RDP to public IPs) and Cloud Shell
# and needs no inbound ports at all. Scripts run as SYSTEM in Windows PowerShell 5.1.

function Invoke-LabHostRaw {
    # Runs the given script text on the host and returns stdout lines. Anything on stderr = failure.
    param([Parameter(Mandatory)][string]$ScriptText, [switch]$NoThrow, [string]$Label = 'remote script')
    $cfg = Get-LabConfig
    $tmp = Join-Path $LabDir ("rc-{0}.ps1" -f [guid]::NewGuid().ToString('n'))
    [IO.File]::WriteAllText($tmp, $ScriptText, (New-Object Text.UTF8Encoding $true))
    try {
        $out = & az vm run-command invoke -g $cfg.ResourceGroup -n $cfg.HostVmName --subscription $cfg.SubscriptionId `
            --command-id RunPowerShellScript --scripts "@$tmp" -o json 2>&1
        $code = $LASTEXITCODE
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        $msg = ($out | ForEach-Object { "$_" }) -join "`n"
        if ($NoThrow) { return "FAIL: run-command error: $msg" }
        throw "Run Command failed for ${Label}:`n$msg"
    }
    $j = (($out | Where-Object { $_ -is [string] }) -join "`n") | ConvertFrom-Json
    $stdout = ($j.value | Where-Object code -like '*StdOut*').message
    $stderr = ($j.value | Where-Object code -like '*StdErr*').message
    if ($stdout) { $stdout -split "`r?`n" | Where-Object { $_ -ne '' } }
    if ($stderr -and $stderr.Trim()) {
        if ($NoThrow) { "FAIL: $($stderr.Trim().Split("`n")[0])" }
        else { throw "$Label wrote errors:`n$($stderr.Trim())" }
    }
}

function Invoke-LabHost {
    # Runs a PowerShell command on the host.
    param([Parameter(Mandatory)][string]$Command, [switch]$NoThrow)
    Invoke-LabHostRaw -ScriptText "`$ProgressPreference='SilentlyContinue'`r`n$Command" -NoThrow:$NoThrow -Label 'command'
}

function Invoke-LabHostScript {
    # Runs host\<Name> on the host (its param() defaults point at C:\Lab\.lab\*.json).
    # -Replace @{ '__STAGE__' = 'dc' } substitutes placeholders before sending.
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Replace = @{}, [switch]$NoThrow)
    $text = Get-Content (Join-Path $HostDir $Name) -Raw
    foreach ($k in $Replace.Keys) { $text = $text.Replace($k, [string]$Replace[$k]) }
    $label = if ($Replace.Count) { "$Name ($(($Replace.Values) -join ','))" } else { $Name }
    Invoke-LabHostRaw -ScriptText $text -NoThrow:$NoThrow -Label $label
}

function Push-LabFiles {
    # Writes files to the host. $Files: @{ 'C:\remote\path' = <byte[] or string> }. Batched to keep each
    # Run Command script small.
    param([Parameter(Mandatory)][hashtable]$Files, [int]$BatchBytes = 120KB)
    $batch = [System.Collections.Generic.List[string]]::new(); $size = 0; $count = 0
    $flush = {
        if ($batch.Count) {
            Invoke-LabHost -Command (($batch -join "`r`n") + "`r`n'wrote $($batch.Count) file(s)'") | Out-Null
            $batch.Clear()
        }
    }
    foreach ($path in ($Files.Keys | Sort-Object)) {
        $v = $Files[$path]
        $bytes = if ($v -is [byte[]]) { $v } else { (New-Object Text.UTF8Encoding $false).GetBytes((([string]$v) -replace "`r`n", "`n")) }
        $b64 = [Convert]::ToBase64String($bytes)
        if ($size + $b64.Length -gt $BatchBytes) { & $flush; $size = 0 }
        $dir = Split-Path $path -Parent
        $batch.Add("New-Item -ItemType Directory -Force '$dir' | Out-Null; [IO.File]::WriteAllBytes('$path', [Convert]::FromBase64String('$b64'))")
        $size += $b64.Length; $count++
    }
    & $flush
    $count
}

function Push-LabFilesToHost {
    # Writes lab.settings.json + secrets.json to C:\Lab\.lab on the host (admins/SYSTEM only).
    $files = @{
        'lab.settings.json' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-LabConfig | ConvertTo-Json -Depth 8)))
        'secrets.json'      = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $LabDir 'secrets.json')))
    }
    $lines = foreach ($k in $files.Keys) { "[IO.File]::WriteAllBytes('C:\Lab\.lab\$k', [Convert]::FromBase64String('$($files[$k])'))" }
    Invoke-LabHost -Command (@(
        "New-Item -ItemType Directory -Force C:\Lab\.lab, C:\Lab\scripts | Out-Null"
        "icacls C:\Lab\.lab /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null"
    ) + $lines + "'pushed ' + (Get-ChildItem C:\Lab\.lab).Count + ' files'" -join "`r`n")
}

$script:Cfg = $null
