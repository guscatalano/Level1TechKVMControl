# Probes a serial port across common baud rates and sends a few wake bytes
# to figure out what the Level1Techs KVM responds to.
#
# Usage:  .\probe-kvm-serial.ps1            # uses COM3 by default
#         .\probe-kvm-serial.ps1 -Port COM4

param(
    [string]$Port = "COM3",
    [int]$ReadMs = 1500
)

$bauds   = 115200, 57600, 38400, 19200, 9600, 4800, 2400
# Probes: CR, LF, CRLF, '?', 'help', Ctrl-Ctrl (common KVM hotkey trigger), Esc
$probes  = @(
    @{ Name = "CR";        Bytes = [byte[]](0x0D) },
    @{ Name = "LF";        Bytes = [byte[]](0x0A) },
    @{ Name = "CRLF";      Bytes = [byte[]](0x0D,0x0A) },
    @{ Name = "?+CR";      Bytes = [byte[]][System.Text.Encoding]::ASCII.GetBytes("?`r") },
    @{ Name = "help+CR";   Bytes = [byte[]][System.Text.Encoding]::ASCII.GetBytes("help`r") },
    @{ Name = "Ctrl-Ctrl"; Bytes = [byte[]](0x03,0x03) },
    @{ Name = "ESC";       Bytes = [byte[]](0x1B) }
)

function Try-Baud {
    param([int]$Baud)

    Write-Host ""
    Write-Host "==== $Port @ $Baud 8N1 ====" -ForegroundColor Cyan

    $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
    $sp.Handshake   = 'None'
    $sp.ReadTimeout = $ReadMs
    $sp.NewLine     = "`r`n"

    try {
        $sp.Open()
    } catch {
        Write-Host "  open failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    Start-Sleep -Milliseconds 200
    $sp.DiscardInBuffer()

    foreach ($p in $probes) {
        $sp.DiscardInBuffer()
        try {
            $sp.Write($p.Bytes, 0, $p.Bytes.Length)
        } catch {
            Write-Host "  [$($p.Name)] write failed: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        # Drain whatever shows up within ReadMs
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $buf = New-Object System.Collections.Generic.List[byte]
        while ($sw.ElapsedMilliseconds -lt $ReadMs) {
            if ($sp.BytesToRead -gt 0) {
                $b = $sp.ReadByte()
                if ($b -ge 0) { [void]$buf.Add([byte]$b) }
            } else {
                Start-Sleep -Milliseconds 25
            }
        }

        if ($buf.Count -eq 0) {
            Write-Host ("  [{0,-9}] (no response)" -f $p.Name) -ForegroundColor DarkGray
        } else {
            $bytes = $buf.ToArray()
            $printable = -join ($bytes | ForEach-Object {
                if ($_ -ge 0x20 -and $_ -lt 0x7F) { [char]$_ } else { '.' }
            })
            $hex = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $color = 'Green'
            # Heuristic: lots of 0x00 / 0xFF / repeats means probably wrong baud
            $junk = ($bytes | Where-Object { $_ -eq 0 -or $_ -eq 0xFF }).Count
            if ($junk -gt ($bytes.Count / 2)) { $color = 'Yellow' }
            Write-Host ("  [{0,-9}] {1} bytes  ascii: {2}" -f $p.Name, $bytes.Count, $printable) -ForegroundColor $color
            Write-Host ("              hex:   {0}" -f $hex) -ForegroundColor DarkGray
        }
    }

    $sp.Close()
    $sp.Dispose()
}

Write-Host "Probing $Port across ${($bauds.Count)} baud rates..." -ForegroundColor White
foreach ($b in $bauds) { Try-Baud -Baud $b }

Write-Host ""
Write-Host "Done. Look for a row where ASCII is clean readable text — that's your baud." -ForegroundColor White
Write-Host "If everything is '(no response)', RJ-11 TX/RX is likely swapped — try a null-modem adapter." -ForegroundColor White
