# Runs ON the Hyper-V host. Installs the Azure Site Recovery provider that Catalyst uses for Hyper-V replication
# and registers the host with the project's vault, using the commands from Microsoft's tutorial-migrate-hyper-v.
# Expects C:\Lab\replication\AzureSiteRecoveryProvider.exe and one *.VaultCredentials key file (from the portal).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\Lab\replication'
$exe = Join-Path $dir 'AzureSiteRecoveryProvider.exe'
$key = Get-ChildItem $dir -Filter '*.VaultCredentials' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not (Test-Path $exe)) {
    & curl.exe -fsSL --retry 5 -o $exe 'https://aka.ms/downloaddra'   # -> download.microsoft.com/.../AzureSiteRecoveryProvider.exe
    if ($LASTEXITCODE) { throw "Provider download failed ($LASTEXITCODE)" }
}
if (-not $key) { throw "Missing *.VaultCredentials key file in $dir" }

$sig = Get-AuthenticodeSignature $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "Provider installer signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
}
"[ok] Installer signed by Microsoft ($($sig.SignerCertificate.Subject.Split(',')[0]))"

$cfgExe = 'C:\Program Files\Microsoft Azure Site Recovery Provider\DRConfigurator.exe'
if (-not (Test-Path $cfgExe)) {
    $x = Join-Path $dir 'Extracted'
    & $exe /q /x:$x | Out-Null
    Push-Location $x
    try { $p = Start-Process .\setupdr.exe -ArgumentList '/i' -Wait -PassThru; "setupdr exit $($p.ExitCode)" } finally { Pop-Location }
    if (-not (Test-Path $cfgExe)) { throw 'Provider install failed - see C:\ProgramData\ASRLogs\DRASetupWizard.log' }
}
"[ok] Provider installed"

$p = Start-Process $cfgExe -ArgumentList '/r', '/Credentials', "`"$($key.FullName)`"" -Wait -PassThru -NoNewWindow
"DRConfigurator /r exit $($p.ExitCode)"
if ($p.ExitCode -ne 0) { throw 'Registration failed - see C:\ProgramData\ASRLogs\DRConfigurator.log' }
Get-Service | Where-Object { $_.Name -match 'dra|obengine' } | ForEach-Object { "[ok] service $($_.Name): $($_.Status)" }
