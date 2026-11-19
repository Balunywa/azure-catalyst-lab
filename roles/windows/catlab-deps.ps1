# catlab dependency agent (Windows). Runs as a SYSTEM scheduled task.
# Keeps real TCP / HTTP keep-alive sessions open to each upstream in C:\catlab\deps.json so agentless
# dependency analysis sees them; writes per-dependency status to C:\catlab\deps-status.json.
$ErrorActionPreference = 'Continue'
$deps  = Get-Content C:\catlab\deps.json -Raw | ConvertFrom-Json
$state = @{}
foreach ($d in $deps) { $state["$($d.name):$($d.port)"] = @{ d = $d; c = $null; s = $null; lastHttp = [datetime]::MinValue; ok = $false; err = '' } }

while ($true) {
    foreach ($k in @($state.Keys)) {
        $e = $state[$k]; $d = $e.d
        $dead = $true
        if ($e.c -and $e.c.Connected) {
            try { $dead = $e.c.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $e.c.Client.Available -eq 0 } catch { $dead = $true }
        }
        if ($dead) {
            if ($e.c) { try { $e.c.Close() } catch {} }
            $e.c = New-Object Net.Sockets.TcpClient
            try {
                if ($e.c.ConnectAsync($d.host, [int]$d.port).Wait(5000) -and $e.c.Connected) {
                    $e.s = $e.c.GetStream(); $e.ok = $true; $e.err = ''; $e.lastHttp = [datetime]::MinValue
                } else { $e.ok = $false; $e.err = 'connect timeout'; $e.c.Close(); $e.c = $null }
            } catch { $e.ok = $false; $e.err = 'connect refused'; $e.c = $null }
        }
        if ($e.c -and $d.proto -eq 'http' -and ((Get-Date) - $e.lastHttp).TotalSeconds -ge 20) {
            try {
                $path = if ($d.path) { $d.path } else { '/' }
                $req = [Text.Encoding]::ASCII.GetBytes("GET $path HTTP/1.1`r`nHost: $($d.host)`r`nUser-Agent: catlab-deps`r`nConnection: keep-alive`r`n`r`n")
                $e.s.Write($req, 0, $req.Length)
                Start-Sleep -Milliseconds 400
                $buf = New-Object byte[] 65536
                while ($e.c.Available -gt 0) { [void]$e.s.Read($buf, 0, $buf.Length) }
                $e.lastHttp = Get-Date
            } catch { try { $e.c.Close() } catch {}; $e.c = $null; $e.ok = $false; $e.err = 'http error' }
        }
        if ($e.c) { $e.ok = $true }
    }
    $out = @{}; foreach ($k in $state.Keys) { $out[$k] = @{ ok = $state[$k].ok; err = $state[$k].err } }
    try {   # write-then-rename so readers never see a half-written file
        $out | ConvertTo-Json -Compress | Set-Content C:\catlab\deps-status.tmp -Encoding ascii
        Move-Item C:\catlab\deps-status.tmp C:\catlab\deps-status.json -Force
    } catch {}
    Start-Sleep -Seconds 5
}
