<#
.SYNOPSIS
    Talk to the Level1Techs HDMI 2.1 KVM over RS-232 (RJ-11, COM5 by default).

.EXAMPLES
    .\kvm.ps1 -PC 2                    # switch video + audio + USB to port 2
    .\kvm.ps1 -Video 1                 # just video to port 1
    .\kvm.ps1 -Audio 3 -USB 3          # audio + USB to port 3
    .\kvm.ps1 -Next                    # next active video port
    .\kvm.ps1 -StartScan               # start auto-scan; -StopScan to stop
    .\kvm.ps1 -ScanInterval 5          # scan step 5 (15 seconds)
    .\kvm.ps1 -Restart                 # restart the KVM
    .\kvm.ps1 -FactoryReset            # H=FAC (asks for confirmation)
    .\kvm.ps1 -Status                  # dump device help
    .\kvm.ps1                          # interactive REPL
    .\kvm.ps1 -Cmd "V=1"               # raw command escape hatch
    .\kvm.ps1 -Probe                   # enumerate available commands

    REPL shortcuts: type 1/2/3/4 to switch PC; v2/a3/u1 for individual lanes;
    next, prev, scan, stop, t5, restart, reset, ?, exit. Or `:V=1` for raw.

.NOTES
    Device responds with `>` for accepted, `<` for rejected. Commands are
    case-sensitive (upper case only). EDID is NOT a serial command on this
    KVM — it's the physical button on the back.
#>
[CmdletBinding()]
param(
    [string]$Port = "COM5",
    [int]   $Baud = 19200,

    [Alias('All','Switch')]
    [ValidateRange(1,4)][int]$PC,
    [ValidateRange(1,4)][int]$Video,
    [ValidateRange(1,4)][int]$Audio,
    [ValidateRange(1,4)][int]$USB,
    [switch]$Next,
    [switch]$Prev,
    [switch]$StartScan,
    [switch]$StopScan,
    [ValidateRange(1,8)][int]$ScanInterval,
    [switch]$AudioFollow,
    [switch]$AudioHold,
    [switch]$USBFollow,
    [switch]$USBHold,
    [switch]$Restart,
    [switch]$FactoryReset,
    [switch]$Status,

    [string]$Cmd,
    [switch]$Probe,
    [switch]$DeepProbe,
    [switch]$FullProbe,
    [string]$Prefix = "",

    [int]$IdleMs = 300,
    [int]$MaxMs  = 6000
)

# ──────── helpers ────────

function Open-KvmPort {
    param([string]$Port,[int]$Baud)
    $sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
    $sp.Handshake='None'; $sp.ReadTimeout=500
    $sp.Open()
    Start-Sleep -Milliseconds 150
    $sp.DiscardInBuffer()
    return $sp
}

function Send-Raw {
    param($sp,[string]$Text)
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text + [char]0x0D)
    $sp.Write($bytes,0,$bytes.Length)
}

function Read-UntilIdle {
    param($sp,[int]$IdleMs=300,[int]$MaxMs=6000)
    $buf = New-Object Collections.Generic.List[byte]
    $sw  = [Diagnostics.Stopwatch]::StartNew()
    $last = 0
    while ($sw.ElapsedMilliseconds -lt $MaxMs) {
        if ($sp.BytesToRead -gt 0) {
            $b = $sp.ReadByte()
            if ($b -ge 0) { [void]$buf.Add([byte]$b); $last = $sw.ElapsedMilliseconds }
        } else {
            if ($last -gt 0 -and ($sw.ElapsedMilliseconds - $last) -ge $IdleMs) { break }
            Start-Sleep -Milliseconds 20
        }
    }
    return [Text.Encoding]::ASCII.GetString($buf.ToArray())
}

function Format-Response {
    param([string]$CmdSent,[string]$Raw)
    $body = ($Raw -replace "`r`n","`n" -replace "`r","`n").Trim()
    $echo = $CmdSent
    if ($body.StartsWith($echo)) { $body = $body.Substring($echo.Length).TrimStart("`n") }
    $status = if     ($body.EndsWith('>')) { 'OK' }
              elseif ($body.EndsWith('<')) { 'FAILED' }
              else                         { $null }
    $body = $body.TrimEnd('>','<').Trim()
    [PSCustomObject]@{ Status = $status; Body = $body }
}

function Invoke-KvmCmd {
    param($sp,[string]$Command)
    Send-Raw -sp $sp -Text $Command
    $raw = Read-UntilIdle -sp $sp -IdleMs $IdleMs -MaxMs $MaxMs
    $r = Format-Response -CmdSent $Command -Raw $raw
    $tag, $color = switch ($r.Status) {
        'OK'     { '[ OK ]',     'Green' }
        'FAILED' { '[FAIL]',     'Red'   }
        default  { '[ ?  ]',     'DarkGray' }
    }
    Write-Host ("{0} {1,-8}" -f $tag, $Command) -ForegroundColor $color -NoNewline
    if ($r.Body) { Write-Host "  $($r.Body)" } else { Write-Host "" }
    return $r
}

function Confirm-FactoryReset {
    Write-Host "Factory reset will erase all KVM settings." -ForegroundColor Yellow
    return ((Read-Host "Type 'yes' to continue") -eq 'yes')
}

# Map REPL input to one or more device commands. Returns string, string[], or '__EXIT__'.
function Convert-ReplInput {
    param([string]$Line)
    $t = $Line.Trim()
    if (-not $t) { return $null }
    if ($t.StartsWith(':')) { return $t.Substring(1) }                    # raw escape
    if ($t -match '^[1-4]$') { return @("V=$t","A=$t","U=$t") }           # number → all lanes
    if ($t -match '^t\s*=?\s*([1-8])$') { return "T=$($Matches[1])" }
    if ($t -match '^([vau])\s*=?\s*([1-4])$') {
        return "$($Matches[1].ToUpper())=$($Matches[2])"
    }
    switch -Regex ($t) {
        '^next$'                  { return 'V=>' }
        '^(prev|previous)$'       { return 'V=<' }
        '^(scan|autoscan|start)$' { return 'V=A' }
        '^stop$'                  { return 'V=$' }
        '^restart$'               { return 'H=R' }
        '^(factory|fac|reset)$'   { return 'H=FAC' }
        '^(help|\?)$'             { return '?' }
        '^(exit|quit)$'           { return '__EXIT__' }
    }
    return $t.ToUpper()  # last resort: assume the user typed a raw command
}

function Show-ReplHelp {
    Write-Host @"

KVM REPL on $Port @ $Baud  (responses: [ OK ]=accepted, [FAIL]=rejected)

  1, 2, 3, 4         switch PC (video + audio + USB to port N)
  v2, a3, u1         switch only video / audio / USB
  next, prev         next / previous active video port
  scan, stop         start / stop video auto-scan
  t5                 set auto-scan interval step 1-8 (3..30 seconds)
  restart            restart the KVM
  reset              factory reset (asks for confirmation)
  ?                  print device help menu
  :V=1               raw command escape hatch
  exit               leave REPL

"@ -ForegroundColor Cyan
}

# ──────── main ────────

$sp = Open-KvmPort -Port $Port -Baud $Baud
try {
    if ($Probe -or $DeepProbe -or $FullProbe) {
        if ($FullProbe)     { $modeLabel = 'FULL' ; $eta = '~80 min' }
        elseif ($DeepProbe) { $modeLabel = 'DEEP' ; $eta = '~9 min'  }
        else                { $modeLabel = 'standard'; $eta = '~3 min' }
        Write-Host "Brute-forcing serial commands on $Port @ $Baud (prefix='$Prefix', mode=$modeLabel)." -ForegroundColor Cyan
        Write-Host "Filter: anything matching 'FAC' is excluded. H=R also excluded (would restart mid-probe)." -ForegroundColor Yellow
        Write-Host "Monitors WILL switch around as valid commands execute. K=2 restarts the device — if any 2-letter command does the same, the probe will pause briefly during reboot." -ForegroundColor Yellow
        Write-Host "Estimated time: $eta." -ForegroundColor Yellow
        Write-Host ""

        # Stop any running auto-scan first so V=N tests behave consistently.
        Send-Raw -sp $sp -Text 'V=$'
        [void](Read-UntilIdle -sp $sp -IdleMs 200 -MaxMs 1000)

        $candidates = New-Object Collections.Generic.List[string]

        # Single uppercase letters
        foreach ($c in 65..90) { [void]$candidates.Add("$([char]$c)") }
        [void]$candidates.Add("?")

        # X=value for each letter (skip H — manual covers it; H=R restarts; H=FAC resets)
        $modifiers = @('1','2','3','4','A','$','*','<','>','R')
        foreach ($c in 65..90) {
            if ($c -eq 72) { continue }
            $x = [char]$c
            foreach ($v in $modifiers) { [void]$candidates.Add("$x=$v") }
        }

        # XN=M for per-monitor / per-channel variants (V1=2, A2=3, etc.)
        foreach ($c in 65..90) {
            if ($c -eq 72) { continue }
            $x = [char]$c
            foreach ($n in 1..2) {
                foreach ($m in 1..4) { [void]$candidates.Add("$x$n=$m") }
            }
        }

        # Multi-char identifiers, alone and as X=N
        $idents = @("STATUS","INFO","VER","VERSION","ID","EDID","DEBUG","CONFIG","HELP","MENU",
                    "READ","DUMP","SHOW","LIST","GET","SET","SAVE","LOAD","STATE",
                    "MON","MONITOR","SCREEN","DISP","DISPLAY","MODE","BAUD","DDC")
        foreach ($e in $idents) {
            [void]$candidates.Add($e)
            foreach ($v in 1..4) { [void]$candidates.Add("$e=$v") }
        }

        if ($DeepProbe -or $FullProbe) {
            # Two-letter commands (XY for X,Y in A-Z, skipping any leading H to avoid H= ambiguity)
            # Each tested bare, with =1, and with =A as a letter-value probe.
            foreach ($x in 65..90) {
                if ($x -eq 72) { continue }
                foreach ($y in 65..90) {
                    $xy = "$([char]$x)$([char]$y)"
                    [void]$candidates.Add($xy)
                    [void]$candidates.Add("$xy=1")
                    [void]$candidates.Add("$xy=A")
                }
            }

            # Deep-dive on the discovered K family with letter values.
            foreach ($v in 65..90) { [void]$candidates.Add("K=$([char]$v)") }

            # Single-letter commands with multi-character values that the manual hints at
            # (L=Cap/Lin/Win in the hotkey section, plus common firmware idioms).
            $extValues = @('CAP','LIN','WIN','MAC','ON','OFF','YES','NO',
                           'UP','DOWN','HOLD','FREE','LOCK','TAB',
                           'AA','BB','RR','LL','XX')
            foreach ($x in 'V','A','U','L','M','S','T','D','I','O','K') {
                foreach ($v in $extValues) { [void]$candidates.Add("$x=$v") }
            }
        }

        if ($FullProbe) {
            # 3-letter command sweep: XYZ for X,Y,Z in A-Z. Skip any leading H so we don't
            # collide with the H= command family (HFA / HFC / etc. could otherwise look like
            # partial H=FAC matches the parser may interpret loosely).
            foreach ($x in 65..90) {
                if ($x -eq 72) { continue }
                foreach ($y in 65..90) {
                    foreach ($z in 65..90) {
                        [void]$candidates.Add("$([char]$x)$([char]$y)$([char]$z)")
                    }
                }
            }
        }

        # Apply prefix and hard-exclude anything that could trigger factory reset or restart
        $tested = @($candidates |
            ForEach-Object { "$Prefix$_" } |
            Where-Object { $_ -notmatch '(?i)FAC' -and $_ -ne 'H=R' -and $_ -ne "${Prefix}H=R" })

        Write-Host ("Testing {0} candidates..." -f $tested.Count) -ForegroundColor Cyan

        # Tighter timing for the huge 3-letter sweep — most failures return < within ~50ms.
        $probeIdleMs   = if ($FullProbe) { 120 } else { 200 }
        $probeMaxMs    = if ($FullProbe) { 1500 } else { 2500 }
        $probeSleepMs  = if ($FullProbe) { 20 } else { 50 }
        $progressEvery = [Math]::Max(50, [int]($tested.Count / 40))

        $accepted = New-Object System.Collections.Generic.List[PSObject]
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $i = 0
        foreach ($cand in $tested) {
            $i++
            $sp.DiscardInBuffer()
            Send-Raw -sp $sp -Text $cand
            $raw = Read-UntilIdle -sp $sp -IdleMs $probeIdleMs -MaxMs $probeMaxMs
            $body = ($raw -replace "`r`n","`n" -replace "`r","`n").Trim()
            if ($body.StartsWith($cand)) { $body = $body.Substring($cand.Length).TrimStart("`n") }
            $body = $body.Trim()
            $resp = 'UNK'
            if ($body.EndsWith('>')) { $resp = 'OK' }
            if ($body.EndsWith('<')) { $resp = 'FAIL' }
            if ($resp -ne 'FAIL') {
                $clean = $body.TrimEnd('>','<').Trim()
                $color = if ($resp -eq 'OK') { 'Green' } else { 'Yellow' }
                $preview = if ($clean.Length -gt 100) { $clean.Substring(0,100) + '...' } else { $clean }
                Write-Host ("  [{0,4}] {1,-12}  {2}" -f $resp, $cand, $preview) -ForegroundColor $color
                [void]$accepted.Add([pscustomobject]@{ Cmd = $cand; Status = $resp; Body = $clean })
            }
            if ($i % $progressEvery -eq 0) {
                $pct = [int](100 * $i / $tested.Count)
                $elapsed = [int]$sw.Elapsed.TotalSeconds
                $eta = if ($i -gt 0) { [int](($sw.Elapsed.TotalSeconds / $i) * ($tested.Count - $i)) } else { 0 }
                Write-Host ("  ...$i/$($tested.Count) ($pct%, ${elapsed}s elapsed, ~${eta}s remaining)") -ForegroundColor DarkGray
            }
            Start-Sleep -Milliseconds $probeSleepMs
        }

        # Cleanup: stop auto-scan if a V=A slipped through
        Send-Raw -sp $sp -Text 'V=$'
        [void](Read-UntilIdle -sp $sp -IdleMs 200 -MaxMs 1000)

        Write-Host ""
        Write-Host ("Done. Accepted commands ({0}):" -f $accepted.Count) -ForegroundColor Green
        foreach ($a in $accepted) {
            $color = if ($a.Status -eq 'OK') { 'Green' } else { 'Yellow' }
            $bodyPreview = if ($a.Body) {
                $b = ($a.Body -replace "`n"," | ").Trim()
                if ($b.Length -gt 80) { "  " + $b.Substring(0,80) + "..." } else { "  $b" }
            } else { "" }
            Write-Host ("  {0,-12}  [{1,-4}]{2}" -f $a.Cmd, $a.Status, $bodyPreview) -ForegroundColor $color
        }
        return
    }

    # Build command queue from named flags
    $queue = New-Object Collections.Generic.List[string]
    if ($PSBoundParameters.ContainsKey('PC')) {
        [void]$queue.Add("V=$PC"); [void]$queue.Add("A=$PC"); [void]$queue.Add("U=$PC")
    }
    if ($PSBoundParameters.ContainsKey('Video')) { [void]$queue.Add("V=$Video") }
    if ($PSBoundParameters.ContainsKey('Audio')) { [void]$queue.Add("A=$Audio") }
    if ($PSBoundParameters.ContainsKey('USB'))   { [void]$queue.Add("U=$USB") }
    if ($Next)        { [void]$queue.Add("V=>") }
    if ($Prev)        { [void]$queue.Add("V=<") }
    if ($StartScan)   { [void]$queue.Add("V=A") }
    if ($StopScan)    { [void]$queue.Add('V=$') }
    if ($PSBoundParameters.ContainsKey('ScanInterval')) { [void]$queue.Add("T=$ScanInterval") }
    if ($AudioFollow) { [void]$queue.Add("A=*") }
    if ($AudioHold)   { [void]$queue.Add('A=$') }
    if ($USBFollow)   { [void]$queue.Add("U=*") }
    if ($USBHold)     { [void]$queue.Add('U=$') }
    if ($Restart)     { [void]$queue.Add("H=R") }
    if ($Status)      { [void]$queue.Add("?") }
    if ($Cmd)         { [void]$queue.Add($Cmd) }
    if ($FactoryReset) {
        if (-not (Confirm-FactoryReset)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        [void]$queue.Add("H=FAC")
    }

    if ($queue.Count -gt 0) {
        foreach ($c in $queue) { [void](Invoke-KvmCmd -sp $sp -Command $c) }
        return
    }

    # No flags → REPL
    Show-ReplHelp
    Send-Raw -sp $sp -Text ""
    [void](Read-UntilIdle -sp $sp -IdleMs 200 -MaxMs 1000)
    while ($true) {
        $line = Read-Host "kvm"
        if ($null -eq $line) { break }
        $tx = Convert-ReplInput -Line $line
        if ($null -eq $tx) { continue }
        if ($tx -eq '__EXIT__') { break }
        if ($tx -eq 'H=FAC' -and -not (Confirm-FactoryReset)) {
            Write-Host "Cancelled." -ForegroundColor Yellow; continue
        }
        $cmds = if ($tx -is [array]) { $tx } else { @($tx) }
        foreach ($c in $cmds) { [void](Invoke-KvmCmd -sp $sp -Command $c) }
    }
}
finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sp)                 { $sp.Dispose() }
}
