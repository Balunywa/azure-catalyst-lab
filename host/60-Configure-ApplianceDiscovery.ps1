# Runs ON the Hyper-V host. After the appliance is REGISTERED (project key + Azure sign-in in its config
# manager), this does the rest of the config manager's step 2 through its local API (same calls the page makes):
#   Hyper-V host credential -> discovery source 192.168.100.1 (validated) -> guest credentials for software
#   inventory + agentless dependency analysis (domain, Windows local, Linux) -> Start discovery.
# The config manager uses Windows auth + an anti-forgery token, and Windows PowerShell's web client can't
# negotiate its TLS settings, so calls go through curl.exe with NTLM inside the appliance.
param([string]$SecretsPath = 'C:\Lab\.lab\secrets.json', [string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json')
$ErrorActionPreference = 'Stop'
$cfg  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sec  = Get-Content $SecretsPath -Raw | ConvertFrom-Json
$cred = New-Object PSCredential 'Administrator', (ConvertTo-SecureString $sec.GuestAdminPassword -AsPlainText -Force)
$vm   = ($cfg.NestedVms | Where-Object Role -eq 'appliance').Name
$hostIp = $cfg.NestedNetwork.HostIp

Invoke-Command -VMName $vm -Credential $cred -ArgumentList $sec, $cfg.Company.Domain, $hostIp -ScriptBlock {
    param($sec, $domain, $hostIp)
    $ErrorActionPreference = 'Stop'
    $base = 'https://localhost:44368'; $jar = "$env:TEMP\cm-cookies-$PID.txt"; $cmCred = "Administrator:$($sec.GuestAdminPassword)"
    function Invoke-Cm([string[]]$extra) {
        $out = & curl.exe -sk --ntlm -u $cmCred -c $jar -b $jar --max-time 120 -w "`n__HTTP=%{http_code}" @extra 2>&1
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        [pscustomobject]@{ Code = ([regex]::Match($text, '__HTTP=(\d+)$')).Groups[1].Value; Body = ($text -replace "`n?__HTTP=\d+$", '') }
    }
    function Get-CmToken { $p = Invoke-Cm @("$base/"); ([regex]::Match($p.Body, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"')).Groups[1].Value }
    function Send-Cm([string]$path, $obj) {
        $t = Get-CmToken; $f = "$env:TEMP\cm-body-$PID.json"; ($obj | ConvertTo-Json -Compress -Depth 6) | Set-Content $f -Encoding ascii
        try { Invoke-Cm @('-X', 'POST', "$base$path", '-H', "__RequestVerificationToken: $t", '-H', 'Content-Type: application/json', '--data-binary', "@$f") } finally { Remove-Item $f -Force }
    }
    function Read-Cm([string]$path) { $t = Get-CmToken; Invoke-Cm @("$base$path", '-H', "__RequestVerificationToken: $t") }

    $cfgFile = 'C:\ProgramData\Microsoft Azure\Config\appliance.json'
    if (-not (Test-Path $cfgFile) -or (Get-Content $cfgFile -Raw | ConvertFrom-Json).IsApplianceRegistered -ne 'true') {
        throw 'The appliance is not registered yet. Paste the project key and sign in in its configuration manager first.'
    }
    # 1. Hyper-V host credential (local account on the host; the page prefixes .\ for Hyper-V)
    $r = Send-Cm '/Home/AddOrUpdateCredential' @{ credentials = @{ targetType = 'Hyper-V'; friendlyName = 'hyperv-host'; username = ".\$($sec.DiscoveryUser)"; password = $sec.DiscoveryPassword } }
    "[ok] Hyper-V host credential (HTTP $($r.Code))"
    # 2. Discovery source: the page generates a GUID id and status 8 (Added) client-side
    $targets = ((Read-Cm '/Home/GetAllTargets').Body | ConvertFrom-Json).targets
    $t = $targets | Where-Object { $_.IPAddress -eq $hostIp -and $_.id } | Select-Object -First 1
    if (-not $t) {
        $id = [guid]::NewGuid().ToString()
        $null = Send-Cm '/Home/AddTargets' @{ targets = @(@{ id = $id; status = '8'; type = 'Hyper-V Host'; IPAddress = $hostIp; port = ''; friendlyName = 'hyperv-host' }) }
    } else { $id = $t.id }
    $null = Send-Cm '/Home/ValidateTargets' @{ ids = @($id) }
    $deadline = (Get-Date).AddMinutes(5)
    do { Start-Sleep -Seconds 10; $st = (((Read-Cm '/Home/GetAllTargets').Body | ConvertFrom-Json).targets | Where-Object id -eq $id).status } while ($st -in 0, 8 -and (Get-Date) -lt $deadline)
    "[ok] discovery source $hostIp status=$st (1=validated, 6=discovering)"
    # 3. Guest credentials. Domain: domain in its own field + PLAIN username (".\x" or "DOMAIN\x" fail validation).
    #    Windows/Linux non-domain: the page prefixes ".\" on Hyper-V appliances.
    foreach ($c in @(
        @{ targetType = 'Domain credentials';   friendlyName = 'lab-domain';          domain = $domain; username = 'Administrator';  password = $sec.GuestAdminPassword },
        @{ targetType = 'Windows (Non-domain)'; friendlyName = 'windows-local-admin'; domain = '';      username = '.\Administrator'; password = $sec.GuestAdminPassword },
        @{ targetType = 'Linux (Non-domain)';   friendlyName = 'linux-labadmin';      domain = '';      username = '.\labadmin';      password = $sec.GuestAdminPassword })) {
        $existing = ((Read-Cm '/Home/GetAllSmartCredentials').Body | ConvertFrom-Json).credentials | Where-Object targetType -eq $c.targetType | Select-Object -First 1
        if ($existing) { $c.id = $existing.id; $c.friendlyName = $existing.friendlyName }
        $null = Send-Cm '/Home/AddOrUpdateSmartCredential' @{ credentials = $c }
    }
    Start-Sleep -Seconds 40
    ((Read-Cm '/Home/GetAllSmartCredentials').Body | ConvertFrom-Json).credentials | ForEach-Object {
        "[{0}] guest credential {1} ({2})" -f $(if ($_.errorDetails) { 'warn' } else { 'ok' }), $_.friendlyName, $(if ($_.errorDetails) { $_.errorDetails.errorCodeName } else { 'validated' })
    }
    # 4. Start (or restart) discovery
    if ($st -in 1, 2, 6, 9) { $null = Send-Cm '/Home/StartDiscovery' @{ ids = @($id) }; '[ok] discovery started' }
    else { throw "Discovery source did not validate (status $st). Check WinRM on the host and the hyperv-host credential." }
    Remove-Item $jar -Force -ErrorAction SilentlyContinue
}
