# Builds the USB host firmware and writes the $readmemh image usb_softcpu.sv loads.
#     powershell -ExecutionPolicy Bypass -File tools/usb_fw/build.ps1
# Toolchain: xPack riscv-none-elf-gcc, unpacked under tools/toolchain (git-ignored; see the design doc).
param([string]$Out = (Join-Path $PSScriptRoot '..\..\LisaFPGA.srcs\sources_1\new\usb_host_fw.mem'))
$ErrorActionPreference = 'Stop'
$bin = Get-ChildItem (Join-Path $PSScriptRoot '..\toolchain') -Directory -Filter 'xpack-riscv-none-elf-gcc-*' |
       Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName 'bin' }
if (-not $bin) { throw 'riscv-none-elf-gcc not found under tools/toolchain' }
$gcc = Join-Path $bin 'riscv-none-elf-gcc.exe'
$objcopy = Join-Path $bin 'riscv-none-elf-objcopy.exe'
$build = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $build | Out-Null
Push-Location $PSScriptRoot
try {
    $src = @('start.S') + (Get-ChildItem *.c | ForEach-Object Name)
    & $gcc -march=rv32ic -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra '-Wl,--gc-sections' '-Wl,--no-warn-rwx-segments' `
        -ffunction-sections -fdata-sections -T link.ld '-Wl,-Map,build/fw.map' -o build/fw.elf @src -lgcc
    if ($LASTEXITCODE) { throw 'compile failed' }
    & $objcopy -O binary build/fw.elf build/fw.bin
    if ($LASTEXITCODE) { throw 'objcopy failed' }
} finally { Pop-Location }
$bytes = [IO.File]::ReadAllBytes((Join-Path $build 'fw.bin'))
if ($bytes.Length -gt 30KB) { throw "firmware is $($bytes.Length) bytes; 30 KB available" }
$words = for ($i = 0; $i -lt $bytes.Length; $i += 4) {
    $w = 0; for ($j = 3; $j -ge 0; $j--) { $w = ($w -shl 8) -bor $(if ($i + $j -lt $bytes.Length) { $bytes[$i + $j] } else { 0 }) }
    '{0:x8}' -f $w
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($Out), (($words -join "`n") + "`n"))
Write-Host "Firmware: $($bytes.Length) bytes -> $Out"
