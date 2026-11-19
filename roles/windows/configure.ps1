# catlab Windows role configuration. Runs INSIDE a guest via PowerShell Direct:
#   Invoke-Command -VMName X -FilePath configure.ps1 -ArgumentList $ctx, $phase
# $ctx: Name, Role, Ip, AppPw, AdminPw, Domain, NetBios, DcIp, Deps[], AgentScript, AcceptSql, SqlUrl, Servers{name->ip}
# $phase: base | dc-promote | dc-post | join | sql
param($ctx, [string]$Phase = 'base')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$out = New-Object System.Collections.Generic.List[string]
# $ctx arrives deserialized; normalise Servers to a hashtable
$servers = @{}
if ($ctx.Servers -is [hashtable]) { $servers = $ctx.Servers } else { $ctx.Servers.PSObject.Properties | ForEach-Object { $servers[$_.Name] = $_.Value } }
function Say($m) { $out.Add("[$($ctx.Name)] $m") }

function Install-DepsAgent {
    New-Item -ItemType Directory -Force C:\catlab | Out-Null
    ConvertTo-Json @($ctx.Deps) -Depth 3 | Set-Content C:\catlab\deps.json -Encoding ascii
    Set-Content C:\catlab\catlab-deps.ps1 -Value $ctx.AgentScript -Encoding ascii
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\catlab\catlab-deps.ps1'
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName CatlabDeps -Action $act -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest) -Settings $set -Force | Out-Null
    Stop-ScheduledTask -TaskName CatlabDeps -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName CatlabDeps
    Say "deps agent running ($(@($ctx.Deps).Count) upstreams)"
}

function Set-MarkerSite([string]$Title, [string]$Marker) {
    $f = Install-WindowsFeature Web-Server, Web-Asp-Net45, Web-Mgmt-Console
    Set-Content C:\inetpub\wwwroot\index.html "<html><body><h1>$Title</h1><p>catalyst-lab marker: $Marker</p></body></html>"
    Say "IIS ($($f.ExitCode)) serving '$Marker'"
}

switch ($Phase) {
'base' {
    Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | Set-NetConnectionProfile -NetworkCategory Private   # DomainAuthenticated can't be changed
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -ErrorAction SilentlyContinue
    switch ($ctx.Role) {
        'fileserver' {
            $pw = ConvertTo-SecureString $ctx.AppPw -AsPlainText -Force
            if (-not (Get-LocalUser svc_app -ErrorAction SilentlyContinue)) { New-LocalUser svc_app -Password $pw -PasswordNeverExpires -Description 'Catlab app service account' | Out-Null }
            foreach ($s in 'Finance', 'Reports', 'Invoices', 'EDI-Inbox', 'HR') {
                $p = "C:\Shares\$s"; New-Item -ItemType Directory -Force $p | Out-Null
                icacls $p /grant 'Everyone:(OI)(CI)M' | Out-Null
                if (-not (Get-SmbShare -Name $s -ErrorAction SilentlyContinue)) { New-SmbShare -Name $s -Path $p -FullAccess Everyone | Out-Null }
            }
            Set-Content C:\Shares\Finance\budget-2027.csv "dept,budget`nOps,120000`nSales,90000"
            Say "SMB shares: $((Get-SmbShare | Where-Object Path -like 'C:\Shares*').Name -join ', ')"
        }
        'sql' {
            New-NetFirewallRule -Name CatlabSql -DisplayName 'SQL Server 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue | Out-Null
            Say $(if ($ctx.AcceptSql) { 'SQL install runs in phase sql' } else { 'SQL Server Express NOT installed (AcceptSqlExpressLicense=false)' })
        }
        'web-storefront' { Set-MarkerSite 'Catlab Retail storefront (CAT-WEB01)' 'windows-iis' }
        'web-hr'         { Set-MarkerSite 'Catlab HR portal (CAT-HRWEB01)' 'hr-portal' }
        'web-timesheets' { Set-MarkerSite 'Catlab timesheets (CAT-TIME01)' 'timesheets' }
        'bi'             { New-Item -ItemType Directory -Force C:\Reports | Out-Null; Say 'reporting server (deps agent only)' }
        default          { Say "no role-specific setup for $($ctx.Role)" }
    }
    if ($ctx.Role -ne 'dc') { Install-DepsAgent }
}
'dc-promote' {
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) { Say 'already a domain controller'; break }
    Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
    $safe = ConvertTo-SecureString $ctx.AdminPw -AsPlainText -Force
    Install-ADDSForest -DomainName $ctx.Domain -DomainNetbiosName $ctx.NetBios -SafeModeAdministratorPassword $safe `
        -InstallDns -Force -NoRebootOnCompletion -WarningAction SilentlyContinue | Out-Null
    Say "promoted to DC for $($ctx.Domain) (reboot required)"
}
'dc-post' {
    Import-Module ActiveDirectory, DnsServer
    # Promotion with a DHCP-assigned DNS client can leave the DNS server with no zones (event 708).
    # Create the AD-integrated zones, point the DC at itself and re-register its SRV/A records.
    if (-not (Get-DnsServerZone -Name $ctx.Domain -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -Name $ctx.Domain -ReplicationScope Domain -DynamicUpdate Secure
    }
    if (-not (Get-DnsServerZone -Name "_msdcs.$($ctx.Domain)" -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -Name "_msdcs.$($ctx.Domain)" -ReplicationScope Forest -DynamicUpdate Secure
    }
    $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses 127.0.0.1
    ipconfig /registerdns | Out-Null
    Restart-Service Netlogon
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Resolve-DnsName "_ldap._tcp.dc._msdcs.$($ctx.Domain)" -Type SRV -Server 127.0.0.1 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    Say "DC locator SRV record: $([bool](Resolve-DnsName "_ldap._tcp.dc._msdcs.$($ctx.Domain)" -Type SRV -Server 127.0.0.1 -ErrorAction SilentlyContinue))"
    Set-DnsServerForwarder -IPAddress 168.63.129.16
    foreach ($n in $servers.Keys) {
        $short = $n.ToLower()
        if (-not (Get-DnsServerResourceRecord -ZoneName $ctx.Domain -Name $short -ErrorAction SilentlyContinue)) {
            Add-DnsServerResourceRecordA -ZoneName $ctx.Domain -Name $short -IPv4Address $servers[$n] -ErrorAction SilentlyContinue
        }
    }
    $pw = ConvertTo-SecureString $ctx.AppPw -AsPlainText -Force
    foreach ($ou in 'Servers', 'Staff', 'Service Accounts') { if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'")) { New-ADOrganizationalUnit -Name $ou | Out-Null } }
    $dn = (Get-ADDomain).DistinguishedName
    foreach ($u in @('svc_sql', 'svc_web', 'svc_reporting')) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'")) { New-ADUser -Name $u -Path "OU=Service Accounts,$dn" -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true }
    }
    foreach ($u in @('ana.finance', 'ben.ops', 'chen.sales', 'dee.hr')) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'")) { New-ADUser -Name $u -Path "OU=Staff,$dn" -AccountPassword $pw -Enabled $true }
    }
    Say "DNS forwarder + $($servers.Count) A records; OUs, 3 service accounts, 4 staff users"
}
'join' {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Say "already joined to $((Get-CimInstance Win32_ComputerSystem).Domain)"; break }
    $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $ctx.DcIp, '168.63.129.16'
    $cred = New-Object PSCredential "$($ctx.NetBios)\Administrator", (ConvertTo-SecureString $ctx.AdminPw -AsPlainText -Force)
    Add-Computer -DomainName $ctx.Domain -Credential $cred -Force -WarningAction SilentlyContinue
    Say "joined $($ctx.Domain) (reboot required)"
}
'sql' {
    if (-not $ctx.AcceptSql) { Say 'skipped: SQL Server license not accepted'; break }
    if (Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue) { Say 'SQL Express already installed' }
    else {
        $d = 'C:\SQLSetup'; New-Item -ItemType Directory -Force $d | Out-Null
        & curl.exe -fsSL --retry 5 -o "$d\SQL2022-SSEI-Expr.exe" $ctx.SqlUrl
        Start-Process "$d\SQL2022-SSEI-Expr.exe" -ArgumentList "/ACTION=Download /MEDIAPATH=$d /MEDIATYPE=Core /QUIET" -Wait
        $pkg = Get-ChildItem $d -Filter 'SQLEXPR*.exe' | Select-Object -First 1
        Start-Process $pkg.FullName -ArgumentList "/Q /x:$d\x" -Wait
        $sqlArgs = "/Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=SQLEXPRESS /SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`" " +
                "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`" /SECURITYMODE=SQL /SAPWD=`"$($ctx.AppPw)`" /TCPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS"
        $p = Start-Process "$d\x\setup.exe" -ArgumentList $sqlArgs -Wait -PassThru
        Say "SQL setup exit $($p.ExitCode)"
    }
    $k = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' | Where-Object Name -match 'MSSQL\d+\.SQLEXPRESS$' | Select-Object -First 1
    $ipall = "$($k.PSPath)\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
    Set-ItemProperty $ipall -Name TcpDynamicPorts -Value ''
    Set-ItemProperty $ipall -Name TcpPort -Value '1433'
    Restart-Service 'MSSQL$SQLEXPRESS' -Force
    Start-Sleep -Seconds 10
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost,1433;User Id=sa;Password=$($ctx.AppPw);TrustServerCertificate=True"
    $cn.Open()
    foreach ($db in 'Storefront', 'Timesheets') {
        $c = $cn.CreateCommand(); $c.CommandText = "IF DB_ID('$db') IS NULL CREATE DATABASE [$db]"; [void]$c.ExecuteNonQuery()
    }
    $c = $cn.CreateCommand(); $c.CommandText = "USE Storefront; IF OBJECT_ID('dbo.Orders') IS NULL CREATE TABLE dbo.Orders(Id int identity primary key, Sku nvarchar(20), Qty int, Created datetime2 default sysutcdatetime())"; [void]$c.ExecuteNonQuery()
    $cn.Close()
    Say 'SQL Express listening on 1433 with Storefront + Timesheets databases'
}
}
$out
