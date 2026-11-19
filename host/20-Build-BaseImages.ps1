# Runs ON the Hyper-V host. Downloads the Windows Server 2022 evaluation VHD and the Debian 12 cloud image,
# verifies the Debian checksum, and turns the raw Debian disk into a VHDX (no third-party tools needed).
param([string]$ConfigPath = 'C:\Lab\.lab\lab.settings.json')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$dl  = 'V:\Lab\Downloads'
$img = 'V:\Lab\Images'

function Get-File([string]$Url, [string]$Out) {
    if ((Test-Path $Out) -and (Get-Item $Out).Length -gt 0) { "    cached: $Out"; return }
    & curl.exe -fsSL --retry 5 --retry-delay 5 -o "$Out.part" $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed ($LASTEXITCODE): $Url" }
    Move-Item "$Out.part" $Out -Force
    "    downloaded: $Out ($([math]::Round((Get-Item $Out).Length/1GB,2)) GB)"
}

function Add-FixedVhdFooter([string]$Path) {
    # A fixed VHD is the raw disk followed by a 512-byte footer (VHD spec v1.0).
    $size = (Get-Item $Path).Length
    if ($size % 512) { throw "Raw size $size is not sector aligned." }
    $total = [math]::Min([long]($size / 512), [long](65535 * 16 * 255))
    if ($total -ge 65535 * 16 * 63) { $spt = 255; $heads = 16; $cth = [math]::Floor($total / $spt) }
    else {
        $spt = 17; $cth = [math]::Floor($total / $spt)
        $heads = [math]::Max(4, [math]::Floor(($cth + 1023) / 1024))
        if ($cth -ge $heads * 1024 -or $heads -gt 16) { $spt = 31; $heads = 16; $cth = [math]::Floor($total / $spt) }
        if ($cth -ge $heads * 1024) { $spt = 63; $heads = 16; $cth = [math]::Floor($total / $spt) }
    }
    $cyl = [int][math]::Floor($cth / $heads)
    $f = New-Object byte[] 512
    function BE([byte[]]$b) { [Array]::Reverse($b); , $b }   # big-endian
    [Text.Encoding]::ASCII.GetBytes('conectix').CopyTo($f, 0)
    (BE ([BitConverter]::GetBytes([uint32]2))).CopyTo($f, 8)            # features
    (BE ([BitConverter]::GetBytes([uint32]65536))).CopyTo($f, 12)       # version 1.0
    (BE ([BitConverter]::GetBytes([uint64]::MaxValue))).CopyTo($f, 16)  # data offset (fixed disk)
    $epoch = New-Object DateTime 2000, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $ts = [uint32][math]::Floor(((Get-Date).ToUniversalTime() - $epoch).TotalSeconds)
    (BE ([BitConverter]::GetBytes($ts))).CopyTo($f, 24)
    [Text.Encoding]::ASCII.GetBytes('win ').CopyTo($f, 28)
    (BE ([BitConverter]::GetBytes([uint32]655360))).CopyTo($f, 32)      # creator version 10.0
    [Text.Encoding]::ASCII.GetBytes('Wi2k').CopyTo($f, 36)
    (BE ([BitConverter]::GetBytes([uint64]$size))).CopyTo($f, 40)       # original size
    (BE ([BitConverter]::GetBytes([uint64]$size))).CopyTo($f, 48)       # current size
    (BE ([BitConverter]::GetBytes([uint16]$cyl))).CopyTo($f, 56)
    $f[58] = [byte]$heads; $f[59] = [byte]$spt
    (BE ([BitConverter]::GetBytes([uint32]2))).CopyTo($f, 60)           # disk type: fixed
    [guid]::NewGuid().ToByteArray().CopyTo($f, 68)
    [long]$sum = 0; foreach ($b in $f) { $sum += $b }
    (BE ([BitConverter]::GetBytes([uint32]([uint32]::MaxValue - $sum)))).CopyTo($f, 64)   # one's complement
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    try { $fs.Write($f, 0, 512) } finally { $fs.Dispose() }
}

# --- Windows Server 2022 evaluation VHD -------------------------------------------------------------
"[..] Windows Server 2022 evaluation VHD"
$winVhd = Join-Path $dl 'ws2022-eval.vhd'
Get-File $cfg.Downloads.WindowsServer2022EvalVhd $winVhd
$v = Get-VHD $winVhd
"[ok] ws2022-eval.vhd: format=$($v.VhdFormat) type=$($v.VhdType) virtual=$([math]::Round($v.Size/1GB)) GB"

# --- Debian 12 generic cloud image -> VHDX ------------------------------------------------------------
"[..] Debian 12 genericcloud image"
$raw  = Join-Path $dl 'debian-12-genericcloud-amd64.raw'
$sums = Join-Path $dl 'debian-SHA512SUMS'
Remove-Item $sums -ErrorAction SilentlyContinue
Get-File $cfg.Downloads.DebianSha512Sums $sums
$debVhdx = Join-Path $img 'debian12.vhdx'
if (-not (Test-Path $debVhdx)) {
    Get-File $cfg.Downloads.DebianRaw $raw
    $expected = ((Get-Content $sums) | Where-Object { $_ -match 'debian-12-genericcloud-amd64\.raw$' }) -split '\s+' | Select-Object -First 1
    $actual = (Get-FileHash $raw -Algorithm SHA512).Hash
    if ($actual -ne $expected) { Remove-Item $raw; throw "Debian SHA512 mismatch (expected $expected, got $actual)" }
    "[ok] Debian SHA512 verified"
    $fixed = Join-Path $dl 'debian12-fixed.vhd'
    Move-Item $raw $fixed -Force
    Add-FixedVhdFooter $fixed
    Convert-VHD -Path $fixed -DestinationPath $debVhdx -VHDType Dynamic
    Remove-Item $fixed
}
$d = Get-VHD $debVhdx
"[ok] debian12.vhdx: type=$($d.VhdType) virtual=$([math]::Round($d.Size/1GB,1)) GB"
