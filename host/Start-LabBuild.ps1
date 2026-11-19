# Runs ON the host VM as the CatalystLabBuild startup task (SYSTEM). Builds the whole lab in stages and
# resumes after reboots/failures. Progress: C:\Lab\status.json  Logs: C:\Lab\logs\<stage>.log
#   Re-run a stage manually:  powershell -File C:\Lab\repo\host\Start-LabBuild.ps1 -Reset <stage>
param([string]$Reset)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$hostDir   = 'C:\Lab\repo\host'
$statePath = 'C:\Lab\.lab\build-state.json'
New-Item -ItemType Directory -Force C:\Lab\logs | Out-Null

$stages = @(
    @{ n = 'network';        f = '10-Configure-HostNetwork.ps1'; d = 'NAT switch, DHCP, discovery account, WinRM' }
    @{ n = 'images';         f = '20-Build-BaseImages.ps1';      d = 'Download Windows Server 2022 eval VHD (9.5 GB) + Debian 12' }
    @{ n = 'render';         f = '25-Render-Estate.ps1';         d = 'Render cloud-init seeds and Windows role contexts' }
    @{ n = 'create';         f = '30-Create-NestedVMs.ps1';      d = 'Create 16 nested VMs' }
    @{ n = 'dc';             f = '33-Configure-Estate.ps1';      a = @('-Stage', 'dc');      d = 'Promote CAT-DC01 (catlab.local)' }
    @{ n = 'members';        f = '33-Configure-Estate.ps1';      a = @('-Stage', 'members'); d = 'Windows app roles + domain join' }
    @{ n = 'linux';          f = '33-Configure-Estate.ps1';      a = @('-Stage', 'linux');   d = 'Wait for Linux apps, detach cloud-init seeds' }
    @{ n = 'appliance-prep'; f = '31-Prepare-Appliance.ps1';     d = 'Prepare CAT-APPLIANCE, download Catalyst installer' }
    @{ n = 'appliance';      f = '35-Install-Appliance.ps1';     d = 'Install the Catalyst (Azure Migrate) appliance software' }
)

$mutex = New-Object Threading.Mutex($false, 'Global\CatalystLabBuild')
if (-not $mutex.WaitOne(0)) { 'another build is running'; exit 0 }

$state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ done = @(); attempts = [pscustomobject]@{}; startedUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z' } }
if ($Reset) { $state.done = @($state.done | Where-Object { $_ -ne $Reset }) }
function Save-State { $state | ConvertTo-Json -Depth 4 | Set-Content $statePath -Encoding ascii }
function Set-Status([string]$S, [string]$Stage, [string]$Msg) {
    $i = [array]::IndexOf(@($stages.n), $Stage) + 1
    [ordered]@{
        state = $S; stage = $Stage; step = "$i/$($stages.Count)"; message = $Msg
        done = @($state.done); startedUtc = $state.startedUtc; updatedUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    } | ConvertTo-Json | Set-Content C:\Lab\status.json -Encoding ascii
}

# Hyper-V management service must be up after the role install reboot
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Service vmms -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }

foreach ($st in $stages) {
    if ($state.done -contains $st.n) { continue }
    $tries = 0
    while ($true) {
        $tries++
        Set-Status 'building' $st.n "$($st.d) (attempt $tries)"
        $log = "C:\Lab\logs\$($st.n).log"
        "===== $(Get-Date -Format s) attempt $tries" | Out-File $log -Append -Encoding utf8
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $hostDir $st.f)) + @($st.a | Where-Object { $_ })
        $ErrorActionPreference = 'Continue'      # PS 5.1 turns native stderr into terminating errors under 'Stop'
        & powershell.exe @psArgs 2>&1 | ForEach-Object { "$_" } | Out-File $log -Append -Encoding utf8
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) { break }
        if ($tries -ge 3) {
            $err = (Get-Content $log -Tail 12) -join ' | '
            Set-Status 'failed' $st.n "Stage failed 3 times. Last log lines: $err"
            $mutex.ReleaseMutex(); exit 1
        }
        Start-Sleep -Seconds 60
    }
    $state.done = @($state.done) + $st.n
    Save-State
}

Set-Status 'succeeded' 'appliance' 'Lab ready: 15 workload VMs + Catalyst appliance. Next: register the appliance (see README).'
$mutex.ReleaseMutex()
