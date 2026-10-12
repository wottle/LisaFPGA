# ---------------------------------------------------------------------------------------------
# xiao_term.ps1 -- a minimal serial terminal for the LisaNet WiFi board's USB console (AT commands).
# Written with an AI assistant. Run it in a PowerShell window (not Git Bash: its terminal can't pass keystrokes through):
#
#   powershell -ExecutionPolicy Bypass -File tools\lisanet_client\xiao_term.ps1 -Port COM7
#
# Type a command and press Enter. Ctrl+C quits. Opening the port restarts the XIAO, so give it a second.
# ---------------------------------------------------------------------------------------------
param([string]$Port = 'COM7')

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200
$sp.DtrEnable = $true                # the ESP32-S3's USB console sends nothing until DTR is set
$sp.RtsEnable = $false
$sp.Open()
[Console]::TreatControlCAsInput = $false
Write-Host "Connected to $Port. Type AT+HELP and press Enter. Ctrl+C quits." -ForegroundColor Cyan
try {
    while ($true) {
        $in = $sp.ReadExisting()
        if ($in) { [Console]::Write($in) }
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { $sp.Write("`r") }
            elseif ($k.Key -eq 'Backspace') { $sp.Write([char]8) }
            elseif ($k.KeyChar -ne [char]0) { $sp.Write([string]$k.KeyChar) }
        }
        Start-Sleep -Milliseconds 20
    }
} finally {
    $sp.Close()
}
