# Runs ON the Hyper-V host. Prepares CAT-APPLIANCE (workgroup Windows Server 2022) over PowerShell Direct and
# downloads Microsoft's Azure Migrate / Catalyst appliance installer into it (installed by 35-Install-Appliance).
param([string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json', [string]$SecretsPath = 'C:\Lab\.lab\secrets.json')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cfg  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sec  = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$cred = New-Object PSCredential 'Administrator', (ConvertTo-SecureString $sec.GuestAdminPassword -AsPlainText -Force)
$vm   = ($cfg.NestedVms | Where-Object Role -eq 'appliance').Name

$deadline = (Get-Date).AddMinutes(30); $ready = $false
while (-not $ready -and (Get-Date) -lt $deadline) {
    try { $ready = (Invoke-Command -VMName $vm -Credential $cred { $env:COMPUTERNAME } -ErrorAction Stop) -eq $vm } catch { Start-Sleep -Seconds 15 }
}
if (-not $ready) { throw "$vm did not finish Windows setup within 30 minutes." }

$dcIp = ($cfg.NestedVms | Where-Object Role -eq 'dc').Ip
$r = Invoke-Command -VMName $vm -Credential $cred -ArgumentList $cfg.Downloads.AzureMigrateInstallerZip, $dcIp -ScriptBlock {
    param($url, $dcIp)
    $ProgressPreference = 'SilentlyContinue'
    Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | Set-NetConnectionProfile -NetworkCategory Private
    # The appliance stays in a workgroup but must resolve the AD domain, or domain credentials fail with
    # ActiveDirectoryServerUnavailable. DC first (forwards everything else), Azure DNS as fallback.
    if ($dcIp) {
        $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $dcIp, '168.63.129.16'
    }
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1
    New-Item -ItemType Directory -Force C:\AzureMigrate | Out-Null
    $zip = 'C:\AzureMigrate\AzureMigrateInstaller.zip'
    if (-not (Test-Path $zip)) { & curl.exe -fsSL --retry 5 -o $zip $url; if ($LASTEXITCODE) { throw "installer download failed ($LASTEXITCODE)" } }
    Expand-Archive $zip -DestinationPath C:\AzureMigrate\Installer -Force
    $sig = Get-AuthenticodeSignature C:\AzureMigrate\Installer\AzureMigrateInstaller.ps1
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "Installer signature check failed: $($sig.Status)" }
    "installer extracted ($((Get-ChildItem C:\AzureMigrate\Installer -File).Count) files), signed by Microsoft"
}
"[ok] ${vm}: $r"

# Make the appliance easy to reach from a Bastion session: Remote Desktop shortcuts with clipboard
# (paste works in the credential prompt) + Hyper-V Enhanced Session for VMConnect.
Set-VMHost -EnableEnhancedSessionMode $true
$dc = $cfg.NestedVms | Where-Object Role -eq 'dc'
$app = $cfg.NestedVms | Where-Object Role -eq 'appliance'
foreach ($s in @(@("$($app.Name) (Catalyst appliance)", $app.Ip, 'Administrator'), @("$($dc.Name) (domain controller)", $dc.Ip, "$($cfg.Company.NetBios)\Administrator"))) {
    "full address:s:$($s[1])`r`nusername:s:$($s[2])`r`nprompt for credentials:i:1`r`nredirectclipboard:i:1`r`nauthentication level:i:0`r`nscreen mode id:i:1`r`ndesktopwidth:i:1600`r`ndesktopheight:i:900" |
        Set-Content "C:\Users\Public\Desktop\$($s[0]).rdp" -Encoding ascii
}
'[ok] RDP shortcuts on the host desktop; Hyper-V Enhanced Session enabled'
