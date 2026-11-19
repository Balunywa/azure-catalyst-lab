# Runs ON the Hyper-V host. Turns CAT-APPLIANCE into the Azure Catalyst (Azure Migrate) appliance using
# Microsoft's AzureMigrateInstaller.ps1 (downloaded + signature-checked by 31-Configure-Guests).
# The installer takes -Scenario/-Cloud/-PrivateEndpoint, but it still asks to (a) remove IE, (b) install Edge,
# and (c) confirm. We pre-empt (a) and (b) and answer (c) with "Y" on stdin, so it runs unattended.
param([string]$SecretsPath = 'C:\Lab\.lab\secrets.json')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sec  = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$cred = New-Object PSCredential 'Administrator', (ConvertTo-SecureString $sec.GuestAdminPassword -AsPlainText -Force)
$vm   = 'CAT-APPLIANCE'

function Wait-PSDirect([int]$Minutes = 15) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-Command -VMName $vm -Credential $cred { $env:COMPUTERNAME } -ErrorAction Stop) -eq $vm) { return } } catch {}
        Start-Sleep -Seconds 10
    }
    throw "$vm not reachable over PowerShell Direct."
}

# Already installed? (config manager service present and running)
$state = Invoke-Command -VMName $vm -Credential $cred {
    $s = Get-Service | Where-Object { $_.DisplayName -match 'Azure Migrate|Microsoft Azure' }
    [pscustomobject]@{ Count = @($s).Count; Running = @($s | Where-Object Status -eq 'Running').Count }
}
if ($state.Count -ge 5 -and $state.Running -eq $state.Count) { "[ok] Appliance already installed ($($state.Running)/$($state.Count) services running)"; return }

# (a) remove IE, (b) install Edge from the bundled Microsoft bootstrapper
$reboot = Invoke-Command -VMName $vm -Credential $cred {
    $ProgressPreference = 'SilentlyContinue'
    $r = $false
    $ie = Get-WindowsOptionalFeature -Online -FeatureName Internet-Explorer-Optional-amd64
    if ($ie.State -eq 'Enabled') {
        $x = Disable-WindowsOptionalFeature -Online -FeatureName Internet-Explorer-Optional-amd64 -NoRestart
        $r = [bool]$x.RestartNeeded
    }
    if (-not (Test-Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge')) {
        $sig = Get-AuthenticodeSignature C:\AzureMigrate\Installer\MicrosoftEdgeSetup.exe
        if ($sig.Status -ne 'Valid') { throw "Edge bootstrapper signature: $($sig.Status)" }
        Start-Process C:\AzureMigrate\Installer\MicrosoftEdgeSetup.exe -ArgumentList '/silent /install' -Wait
    }
    $r
}
"[ok] IE removed / Edge present (reboot needed: $reboot)"
if ($reboot) { Restart-VM -Name $vm -Force -Wait -For Heartbeat; Start-Sleep -Seconds 20; Wait-PSDirect; "[ok] $vm rebooted" }

# (c) run the installer unattended
$result = Invoke-Command -VMName $vm -Credential $cred {
    $wrapper = 'C:\AzureMigrate\run-installer.ps1'
    Set-Content $wrapper "& 'C:\AzureMigrate\Installer\AzureMigrateInstaller.ps1' -Scenario HyperV -Cloud Public -PrivateEndpoint:`$false" -Encoding ascii
    $log = 'C:\AzureMigrate\installer-output.log'
    cmd.exe /c "(echo Y& echo Y& echo Y)| powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper > $log 2>&1"
    $code = $LASTEXITCODE
    $s = Get-Service | Where-Object { $_.DisplayName -match 'Azure Migrate|Microsoft Azure' }
    [pscustomobject]@{
        Exit     = $code
        Services = ($s | ForEach-Object { "$($_.DisplayName)=$($_.Status)" }) -join '; '
        Tail     = (Get-Content $log -Tail 8 | Where-Object { $_.Trim() }) -join ' | '
        Port     = (Get-NetTCPConnection -LocalPort 44368 -State Listen -ErrorAction SilentlyContinue) -ne $null
    }
}
"installer exit=$($result.Exit) port44368=$($result.Port)"
"services: $($result.Services)"
"log tail: $($result.Tail)"
if (-not $result.Port) { throw 'Appliance configuration manager is not listening on 44368.' }
"[ok] Appliance software installed"
