# ---------------------------------------------------------------------------------------------
# fujinet_test.ps1 -- a PC stand-in for a Lisa FujiNet program, to test the LisaNet WiFi board's FujiNet adapter.
# Written with an AI assistant. Its FujiBus code (SLIP, checksum, descriptors) is written separately from the
# firmware's, from the protocol as fujinet-firmware implements it, so the two check each other.
#
# Setup: on lisanet.local -> Settings -> FujiNet, set Serial B to "Bench test". That wires the board's real Serial B
# port -- the CP2102N "LisaFPGA Serial B" USB port, COM5 on this PC -- straight to the WiFi board. Then:
#
#   powershell -ExecutionPolicy Bypass -File tools\lisanet_client\fujinet_test.ps1 -Port COM5 -Baud 9600
#
# The baud rate must match the FujiNet card's. Set Serial B back to "Its own port" (or This WiFi board) afterwards.
# ---------------------------------------------------------------------------------------------
param(
    [string]$Port = 'COM5',
    [int]$Baud = 9600,
    [string]$Url = 'HTTPS://fujinet.online/8bitnews/news.php?t=lf&ps=76x14',   # LisaFuji's news page, spelled as it sends it
    [string]$JsonUrl = 'https://httpbin.org/json',
    [string]$JsonQuery = '/slideshow/title'
)

$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.Open()
$sp.DiscardInBuffer()
$script:fails = 0

function Sum8([byte[]]$b) {
    $c = 0
    foreach ($x in $b) { $c += $x; $c = ($c -shr 8) + ($c -band 0xFF) }
    return [byte]$c
}

# params: a list of @(value, size) with size 1, 2 or 4; consecutive same-size values share a descriptor
function Send-Packet([byte]$dev, [byte]$cmd, $params = @(), [byte[]]$data = @()) {
    $descr = New-Object System.Collections.Generic.List[byte]
    $pbytes = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $params.Count) {
        $size = $params[$i][1]; $n = 0; $max = [Math]::Floor(4 / $size)
        while ($i -lt $params.Count -and $params[$i][1] -eq $size -and $n -lt $max) {
            for ($k = 0; $k -lt $size; $k++) { $pbytes.Add([byte](($params[$i][0] -shr (8 * $k)) -band 0xFF)) }
            $n++; $i++
        }
        $code = switch ($size) { 1 { $n } 2 { 4 + $n } 4 { 7 } }
        $descr.Add([byte]($code -bor 0x80))
    }
    if ($descr.Count) { $descr[$descr.Count - 1] = $descr[$descr.Count - 1] -band 0x7F }
    $first = if ($descr.Count) { $descr[0] } else { 0 }
    $body = New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]]@($dev, $cmd, 0, 0, 0, $first))
    for ($k = 1; $k -lt $descr.Count; $k++) { $body.Add($descr[$k]) }
    $body.AddRange($pbytes); $body.AddRange($data)
    $len = $body.Count
    $body[2] = [byte]($len -band 0xFF); $body[3] = [byte]($len -shr 8)
    $body[4] = Sum8 $body.ToArray()
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add(0xC0)
    foreach ($x in $body) {
        if ($x -eq 0xC0) { $out.Add(0xDB); $out.Add(0xDC) }
        elseif ($x -eq 0xDB) { $out.Add(0xDB); $out.Add(0xDD) }
        else { $out.Add($x) }
    }
    $out.Add(0xC0)
    $sp.Write($out.ToArray(), 0, $out.Count)
}

# Waits for one reply frame; returns @{dev; ack; data} or $null
function Read-Reply([int]$timeoutMs = 15000) {
    $buf = New-Object System.Collections.Generic.List[byte]
    $in = $false; $esc = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        try { $b = $sp.ReadByte() } catch [TimeoutException] { continue }
        if ($b -eq 0xC0) {
            if ($in -and $buf.Count) { break }
            $in = $true; $buf.Clear(); continue
        }
        if (-not $in) { continue }
        if ($esc) { $esc = $false; $b = if ($b -eq 0xDC) { 0xC0 } elseif ($b -eq 0xDD) { 0xDB } else { $b } }
        elseif ($b -eq 0xDB) { $esc = $true; continue }
        $buf.Add([byte]$b)
    }
    if ($buf.Count -lt 6) { return $null }
    $p = $buf.ToArray()
    $len = $p[2] + 256 * $p[3]
    $ck = $p[4]; $p[4] = 0
    if ($len -ne $p.Count) { Write-Host "  bad length $len vs $($p.Count)" -ForegroundColor Red; return $null }
    if ((Sum8 $p) -ne $ck) { Write-Host "  bad checksum" -ForegroundColor Red; return $null }
    $data = if ($p.Count -gt 6) { $p[6..($p.Count - 1)] } else { @() }
    return @{ dev = $p[0]; ack = ($p[1] -eq 0x06); nak = ($p[1] -eq 0x15); data = [byte[]]$data }
}

function Call($name, [byte]$dev, [byte]$cmd, $params = @(), [byte[]]$data = @(), [switch]$ExpectNak) {
    Send-Packet $dev $cmd $params $data
    $r = Read-Reply
    if (-not $r) { Write-Host ("FAIL {0}: no reply" -f $name) -ForegroundColor Red; $script:fails++; return $null }
    $ok = if ($ExpectNak) { $r.nak } else { $r.ack }
    if ($r.dev -ne $dev) { $ok = $false; Write-Host "  reply from device $($r.dev), not $dev" -ForegroundColor Red }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("{0} {1}: {2}, {3} data bytes" -f ($(if ($ok) { 'ok  ' } else { 'FAIL' }), $name,
        $(if ($r.ack) { 'ACK' } else { 'NAK' }), $r.data.Count)) -ForegroundColor $color
    if (-not $ok) { $script:fails++ }
    return $r
}

function Text([byte[]]$b) { if (-not $b) { return '' }; ([Text.Encoding]::ASCII.GetString($b)).TrimEnd([char]0) }
function Bytes([string]$s) { [Text.Encoding]::ASCII.GetBytes($s) }

# Reads a network unit to the end the way a Lisa program would: STATUS until bytes wait or EOF, then READ them
function Read-Unit([byte]$dev, [int]$limit = 200000) {
    $all = New-Object System.Collections.Generic.List[byte]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 30000 -and $all.Count -lt $limit) {
        Send-Packet $dev 0x53
        $s = Read-Reply
        if (-not $s -or -not $s.ack -or $s.data.Count -lt 4) { Write-Host "  STATUS failed" -ForegroundColor Red; $script:fails++; break }
        $avail = $s.data[0] + 256 * $s.data[1]; $err = $s.data[3]
        if ($avail -eq 0) {
            if ($err -eq 136) { break }                                      # EOF
            if ($err -ne 1) { Write-Host "  STATUS error $err" -ForegroundColor Yellow; break }
            Start-Sleep -Milliseconds 50; continue
        }
        Send-Packet $dev 0x52 @(, @([Math]::Min($avail, 256), 2))     # LisaFuji reads at most 256 at a time
        $r = Read-Reply
        if (-not $r -or -not $r.ack) { Write-Host "  READ failed" -ForegroundColor Red; $script:fails++; break }
        $all.AddRange($r.data)
    }
    return $all.ToArray()
}

Write-Host "FujiNet adapter test on $Port at $Baud baud" -ForegroundColor Cyan

$r = Call 'device test (DEVICE_READY)' 0x70 0x00
if ($r -and ($r.data.Count -ne 512 -or ($r.data | Where-Object { $_ -ne 0x41 }))) { Write-Host '  expected 512 A' -ForegroundColor Red; $fails++ }

$r = Call 'WiFi status' 0x70 0xFA
if ($r) { Write-Host "  status $($r.data[0]) (3 = connected)" }

$r = Call 'adapter config' 0x70 0xE8
if ($r -and $r.data.Count -eq 140) {
    $d = $r.data
    Write-Host ("  SSID '{0}', host '{1}', IP {2}.{3}.{4}.{5}, version '{6}'" -f (Text $d[0..32]), (Text $d[33..96]),
        $d[97], $d[98], $d[99], $d[100], (Text $d[125..139]))
} elseif ($r) { Write-Host "  expected 140 bytes" -ForegroundColor Red; $fails++ }

$r = Call 'clock: day month yy h m s (as LisaFuji asks)' 0x45 0x93 @(, @(0, 1))
if ($r -and $r.data.Count -eq 6) { $d = $r.data; Write-Host ("  20{2:d2}-{1:d2}-{0:d2} {3:d2}:{4:d2}:{5:d2}" -f $d[0], $d[1], $d[2], $d[3], $d[4], $d[5]) }
$r = Call 'clock: ISO local time' 0x45 0x49
if ($r) { Write-Host "  $(Text $r.data)" }
$r = Call 'clock: simple binary time' 0x45 0x54
if ($r -and $r.data.Count -eq 7) { $d = $r.data; Write-Host ("  {0}{1:d2}-{2:d2}-{3:d2} {4:d2}:{5:d2}:{6:d2}" -f $d[0], $d[1], $d[2], $d[3], $d[4], $d[5], $d[6]) }

Write-Host "--- HTTP GET $Url" -ForegroundColor Cyan
$null = Call 'N1 OPEN (read, no translation, as LisaFuji)' 0x71 0x4F @(@(4, 1), @(0, 1)) (Bytes ('N1:' + $Url))
$body = Read-Unit 0x71
Write-Host "  read $($body.Count) bytes"
if ($body.Count -eq 0) { $fails++ } else { Write-Host ('  starts: ' + ((Text $body[0..([Math]::Min(79, $body.Count - 1))]) -replace '\s+', ' ')) }
$null = Call 'N1 CLOSE' 0x71 0x43

Write-Host "--- JSON $JsonUrl $JsonQuery" -ForegroundColor Cyan
$null = Call 'N2 OPEN' 0x72 0x4F @(@(12, 1), @(0, 1)) (Bytes ('N2:' + $JsonUrl))
$null = Call 'N2 SET_PARSER json' 0x72 0xFC @(@(0, 1), @(1, 1))
$null = Call 'N2 PARSE' 0x72 0x50
$null = Call 'N2 QUERY' 0x72 0x51 @() (Bytes $JsonQuery)
$v = Read-Unit 0x72
Write-Host "  value: '$((Text $v).TrimEnd())'"
if ($v.Count -eq 0) { $fails++ }
$null = Call 'N2 CLOSE' 0x72 0x43

$null = Call 'an unsupported command is refused' 0x70 0xD2 -ExpectNak

$sp.Close()
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
