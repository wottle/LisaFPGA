# ---------------------------------------------------------------------------
# asukp.ps1 -- PowerShell port of m1nl/usb_hid_host's rom/asukp.py (Apache-2.0, copyright nand2mario 2023
# and Mateusz Nalewajski 2026). Assembles the usb_hid_host microcode, ukp.s, into the nibble-per-line .mem
# file the dual-port ROM loads. Ported because this Windows machine has no Python.
#
# Usage (from this directory):
#     powershell -ExecutionPolicy Bypass -File asukp.ps1 [-Source ukp.s] [-Out <path to .mem>]
#
# Default output is the ROM image the build actually uses. The port was verified by assembling the
# fork's UNMODIFIED ukp.s and comparing against its shipped usb_hid_host_rom.mem: byte-identical.
#
# Encoding, as in the original: one nibble per ROM word. Labels align to 4 nibbles, because jump and call
# targets are stored as (address >> 2) in two nibbles -- so the ROM can never exceed 1024 nibbles.
# ---------------------------------------------------------------------------
param(
    [string]$Source = (Join-Path $PSScriptRoot 'ukp.s'),
    [string]$Out    = (Join-Path $PSScriptRoot '..\..\LisaFPGA.srcs\sources_1\imports\src\usb_hid_host_rom.mem')
)
$ErrorActionPreference = 'Stop'

$ops = @{ nop=0; ldi=1; start=2; out4=3; out0=4; hiz=5; outb=6; ret=7; call=8; bx=9; outr=10; dec=11;
          save=12; in=13; wait=14; load=15; be=16; bc=17; bnak=18; bstall=19; bnz=20; bz=21; bnf=22; bjmp=23 }

function Parse-Imm([string]$t) { if ($t.StartsWith('0x')) { [Convert]::ToInt32($t.Substring(2), 16) } else { [int]$t } }

$lines = Get-Content $Source

# Pass 1: label addresses
$labels = @{}; $pc = 0
foreach ($raw in $lines) {
    $line = $raw.Split(';')[0].Trim()
    if (-not $line) { continue }
    if ($line.Contains(':')) {
        $label = $line.Split(':')[0].Trim()
        if ($labels.ContainsKey($label)) { throw "$label already defined" }
        $pc = ($pc + 3) -band (-bnot 3)
        $labels[$label] = $pc
        continue
    }
    $op = ($line -split '\s+')[0]
    if (-not $ops.ContainsKey($op)) { throw "syntax error: $line" }
    $code = $ops[$op]
    if ($code -ge 16) { $pc += 4 }
    elseif ($code -in 1,3,6,8,12) { $pc += 3 }
    elseif ($code -in 10,15) { $pc += 2 }
    else { $pc += 1 }
}

# Pass 2: code
$rom = New-Object System.Collections.Generic.List[int]
foreach ($raw in $lines) {
    $line = $raw.Split(';')[0].Trim()
    if (-not $line) { continue }
    if ($line.Contains(':')) {
        while ($rom.Count % 4 -ne 0) { $rom.Add(0) }
        continue
    }
    $tok = $line -split '\s+'
    $code = $ops[$tok[0]]
    if ($code -ge 16) { $rom.Add(9); $rom.Add($code - 16) } else { $rom.Add($code) }
    if ($code -eq 12) {
        if ($tok.Count -ne 3) { throw "Malformed instruction: $line" }
        $rom.Add([int]$tok[1]); $rom.Add([int]$tok[2])
    } elseif ($code -in 10,15) {
        if ($tok.Count -ne 2) { throw "Malformed instruction: $line" }
        $rom.Add([int]$tok[1])
    } elseif ($code -in 1,3,6) {
        $v = Parse-Imm $tok[1]
        $rom.Add($v -band 0xF); $rom.Add(($v -shr 4) -band 0xF)
    } elseif ($code -eq 8 -or $code -ge 16) {
        if (-not $labels.ContainsKey($tok[1])) { throw "undefined label: $($tok[1])" }
        $a = $labels[$tok[1]] -shr 2
        $rom.Add($a -band 0xF); $rom.Add(($a -shr 4) -band 0xF)
    }
}

if ($rom.Count -gt 1024) { throw "ROM is $($rom.Count) nibbles; jump targets only reach 1024" }

# LF line endings, lower-case hex, one nibble per line -- exactly as asukp.py writes it
$text = ($rom | ForEach-Object { '{0:x}' -f $_ }) -join "`n"
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Out), $text + "`n")
Write-Host "Wrote $($rom.Count) nibbles (of 1024) to $Out"
