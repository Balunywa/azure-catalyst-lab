<#
.SYNOPSIS
  Shows the in-VM build progress (C:\Lab\status.json on the host) via Azure Run Command.
.EXAMPLE
  ./scripts/Get-LabStatus.ps1 -Wait      # poll every 3 minutes until the build succeeds or fails
#>
[CmdletBinding()]
param([switch]$Wait, [int]$IntervalMinutes = 3)
. (Join-Path $PSScriptRoot 'LabCommon.ps1')
$probe = @'
$s = if (Test-Path C:\Lab\status.json) { Get-Content C:\Lab\status.json -Raw | ConvertFrom-Json } else { [pscustomobject]@{ state = 'bootstrapping'; stage = 'bootstrap'; message = 'waiting for the Custom Script Extension' } }
$tail = if ($s.stage -and (Test-Path "C:\Lab\logs\$($s.stage).log")) { (Get-Content "C:\Lab\logs\$($s.stage).log" -Tail 3) -join ' | ' } else { '' }
$s | Add-Member -NotePropertyName tail -NotePropertyValue $tail -Force
$s | ConvertTo-Json -Compress
'@
while ($true) {
    $raw = Invoke-LabHost -Command $probe -NoThrow
    $s = $null; try { $s = ($raw | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
    $now = Get-Date -Format 'HH:mm'
    if (-not $s) { Write-Host "[$now] host not reachable yet (rebooting or still deploying)" -ForegroundColor DarkYellow }
    else {
        $color = switch ($s.state) { 'succeeded' { 'Green' } 'failed' { 'Red' } default { 'Cyan' } }
        Write-Host ("[{0}] {1,-10} {2,-15} {3,-5} {4}" -f $now, $s.state, $s.stage, $s.step, $s.message) -ForegroundColor $color
        if ($s.state -eq 'failed' -and $s.tail) { Write-Host "         log: $($s.tail)" -ForegroundColor DarkGray }
        if ($s.state -in 'succeeded', 'failed') { break }
    }
    if (-not $Wait) { break }
    Start-Sleep -Seconds ($IntervalMinutes * 60)
}
