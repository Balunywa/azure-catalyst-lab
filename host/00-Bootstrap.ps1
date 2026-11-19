# Runs ON the new host VM via the Custom Script Extension (SYSTEM), once.
#   1. downloads the lab repo to C:\Lab\repo
#   2. writes settings + generates lab secrets (C:\Lab\.lab, admin-only)
#   3. installs Hyper-V + DHCP, registers the CatalystLabBuild startup task, reboots
# The build continues after the reboot (host\Start-LabBuild.ps1). Progress: C:\Lab\status.json, C:\Lab\logs.
param(
    [string]$RepoUrl = 'https://github.com/Balunywa/azure-catalyst-lab',
    [string]$RepoRef = 'main',
    [string]$AcceptSqlExpressLicense = '0'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force C:\Lab\logs, C:\Lab\.lab | Out-Null
Start-Transcript -Path C:\Lab\logs\00-bootstrap.log -Append | Out-Null
icacls C:\Lab\.lab /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null

function Set-Status([string]$State, [string]$Stage, [string]$Message) {
    [ordered]@{ state = $State; stage = $Stage; message = $Message; updatedUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z' } |
        ConvertTo-Json | Set-Content C:\Lab\status.json -Encoding ascii
}
function New-LabPassword([int]$Length = 20) {
    # Characters that survive az.cmd, XML, YAML and PowerShell quoting unescaped.
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '@#-_+.')
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $pick = { param($s) $b = New-Object byte[] 4; $rng.GetBytes($b); $s[[BitConverter]::ToUInt32($b, 0) % $s.Length] }
    $chars = @(foreach ($s in $sets) { & $pick $s })
    $all = -join $sets
    while ($chars.Count -lt $Length) { $chars += & $pick $all }
    -join ($chars | Sort-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); [BitConverter]::ToUInt32($b, 0) })
}

Set-Status 'bootstrapping' 'bootstrap' "Downloading $RepoUrl@$RepoRef"
# 1. Repo
$zip = 'C:\Lab\repo.zip'
& curl.exe -fsSL --retry 5 -o $zip "$RepoUrl/archive/$RepoRef.zip"
if ($LASTEXITCODE) { throw "Repo download failed ($LASTEXITCODE)" }
Remove-Item C:\Lab\repo-tmp, C:\Lab\repo -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip C:\Lab\repo-tmp
Move-Item (Get-ChildItem C:\Lab\repo-tmp -Directory | Select-Object -First 1).FullName C:\Lab\repo
Remove-Item C:\Lab\repo-tmp, $zip -Recurse -Force
"repo: $((Get-ChildItem C:\Lab\repo -Recurse -File).Count) files"

# 2. Settings + secrets
$cfg = Get-Content C:\Lab\repo\lab.settings.json -Raw | ConvertFrom-Json
$cfg.AcceptSqlExpressLicense = ($AcceptSqlExpressLicense -in '1', 'true', 'True', '$true')
$cfg | ConvertTo-Json -Depth 8 | Set-Content C:\Lab\.lab\lab.settings.json -Encoding utf8
if (-not (Test-Path C:\Lab\.lab\secrets.json)) {
    [ordered]@{
        GuestAdminPassword = New-LabPassword    # Administrator (Windows) / labadmin (Linux) in nested VMs; CATLAB\Administrator
        DiscoveryUser      = 'catdiscovery'     # least-privilege account the appliance uses on the Hyper-V host
        DiscoveryPassword  = New-LabPassword
        AppPassword        = New-LabPassword    # PostgreSQL/RabbitMQ 'app', SMB 'svc_app', SQL 'sa'
    } | ConvertTo-Json | Set-Content C:\Lab\.lab\secrets.json -Encoding utf8
}

# 3. Build task (runs at every startup until the build is complete) + Hyper-V
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\repo\host\Start-LabBuild.ps1'
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName CatalystLabBuild -Action $act -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest) -Settings $set -Force | Out-Null
Set-Status 'bootstrapping' 'bootstrap' 'Installing Hyper-V and DHCP roles'
$r = Install-WindowsFeature -Name Hyper-V, DHCP -IncludeManagementTools
"Install-WindowsFeature: success=$($r.Success) restart=$($r.RestartNeeded)"
Set-Status 'rebooting' 'bootstrap' 'Rebooting to finish Hyper-V; the build resumes automatically'
Stop-Transcript | Out-Null
shutdown.exe /r /t 60 /c 'catalyst-lab: finishing Hyper-V install' | Out-Null
exit 0
