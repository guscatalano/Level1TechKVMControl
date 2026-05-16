<#
.SYNOPSIS
    LAN web UI for the KVM. Holds COM5 open and serves a phone-friendly
    page with PC 1-4 buttons.

.NOTES
    Runs without admin by binding to localhost + each LAN IPv4 address
    (binding to a specific IP doesn't require a URL ACL).

    First run: Windows Firewall will prompt — click "Allow" for Private/LAN.
    No authentication: don't expose to untrusted networks.
#>
param(
    [string]$Port      = "COM5",
    [int]   $Baud      = 19200,
    [int]   $HttpPort  = 8080,
    [int]   $IdleMs    = 300,
    [int]   $MaxMs     = 6000
)

# ──── Serial helpers ────

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
    if ($body.StartsWith($CmdSent)) { $body = $body.Substring($CmdSent.Length).TrimStart("`n") }
    $status = if     ($body.EndsWith('>')) { 'OK' }
              elseif ($body.EndsWith('<')) { 'FAIL' }
              else                         { 'UNKNOWN' }
    $body = $body.TrimEnd('>','<').Trim()
    [PSCustomObject]@{ status = $status; body = $body }
}

function Invoke-KvmCmd {
    param($sp,[string]$Command)
    Send-Raw -sp $sp -Text $Command
    $raw = Read-UntilIdle -sp $sp -IdleMs $IdleMs -MaxMs $MaxMs
    return Format-Response -CmdSent $Command -Raw $raw
}

# ──── HTML page ────

$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>KVM</title>
<style>
  * { box-sizing: border-box }
  html,body { margin:0; padding:0; }
  body { font-family: system-ui,-apple-system,Segoe UI,sans-serif; background:#0f1116; color:#e5e7eb; min-height:100vh; padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  main { max-width: 580px; margin: 0 auto; padding: 16px; }
  h1 { font-size: 1.1rem; margin: 4px 0 18px; opacity:.6; font-weight:500; letter-spacing:.05em; text-transform:uppercase; }
  section { margin-bottom: 20px; }
  section h2 { font-size: .8rem; margin: 0 0 8px 4px; opacity:.55; font-weight:600; letter-spacing:.08em; text-transform:uppercase; }
  button {
    appearance:none; border:0; border-radius:12px; padding: 14px 8px;
    font-size: 1rem; font-weight: 600; color:#fff; background:#374151;
    cursor:pointer; transition: transform .06s ease, background .15s ease, opacity .15s ease;
    -webkit-tap-highlight-color: transparent; user-select:none; font-family: inherit;
  }
  button:active { transform: scale(0.97); background:#4b5563; }
  button[disabled] { opacity:.5; pointer-events:none; }
  button.big { padding: 32px 12px; font-size: 2.2rem; font-weight: 700; background:#1f3a8a; border-radius:14px; }
  button.big:active { background:#2a4ba8; }
  button.danger { background:#7f1d1d; }
  button.danger:active { background:#991b1b; }
  .g2 { display:grid; grid-template-columns: 1fr 1fr; gap:8px; }
  .g3 { display:grid; grid-template-columns: 1fr 1fr 1fr; gap:8px; }
  .g4 { display:grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap:8px; }
  .g4 + .g4, .g4 + .g2, .g2 + .g2 { margin-top:8px; }
  input[type=text] {
    flex:1; background:#0a0c10; color:#e5e7eb; border:1px solid #374151; border-radius:8px;
    padding:10px 12px; font-family:ui-monospace,Consolas,monospace; font-size:1rem;
  }
  #status {
    margin-top:18px; padding:12px 14px; border-radius:10px; background:#0a0c10;
    border:1px solid #1f2937; min-height:1.5em;
    font-family:ui-monospace,Consolas,monospace; font-size:.85rem; white-space:pre-wrap;
  }
  #status.ok   { color:#86efac; border-color:#14532d; }
  #status.fail { color:#fca5a5; border-color:#7f1d1d; }
  #status.busy { color:#9ca3af; }
</style>
</head>
<body>
<main>
  <h1>KVM Control</h1>

  <section>
    <h2>Switch PC (video + audio + USB)</h2>
    <div class="g4">
      <button class="big" onclick="cmd('pc',1)">1</button>
      <button class="big" onclick="cmd('pc',2)">2</button>
      <button class="big" onclick="cmd('pc',3)">3</button>
      <button class="big" onclick="cmd('pc',4)">4</button>
    </div>
  </section>

  <section>
    <h2>Video</h2>
    <div class="g4">
      <button onclick="cmd('raw','V=1')">V1</button>
      <button onclick="cmd('raw','V=2')">V2</button>
      <button onclick="cmd('raw','V=3')">V3</button>
      <button onclick="cmd('raw','V=4')">V4</button>
    </div>
    <div class="g4">
      <button onclick="cmd('raw','V=<')">‹ Prev</button>
      <button onclick="cmd('raw','V=A')">Auto</button>
      <button onclick="cmd('raw','V=$')">Stop</button>
      <button onclick="cmd('raw','V=>')">Next ›</button>
    </div>
  </section>

  <section>
    <h2>Audio</h2>
    <div class="g4">
      <button onclick="cmd('raw','A=1')">A1</button>
      <button onclick="cmd('raw','A=2')">A2</button>
      <button onclick="cmd('raw','A=3')">A3</button>
      <button onclick="cmd('raw','A=4')">A4</button>
    </div>
    <div class="g2">
      <button onclick="cmd('raw','A=*')">Follow Video</button>
      <button onclick="cmd('raw','A=$')">Hold Current</button>
    </div>
  </section>

  <section>
    <h2>USB 3.2</h2>
    <div class="g4">
      <button onclick="cmd('raw','U=1')">U1</button>
      <button onclick="cmd('raw','U=2')">U2</button>
      <button onclick="cmd('raw','U=3')">U3</button>
      <button onclick="cmd('raw','U=4')">U4</button>
    </div>
    <div class="g2">
      <button onclick="cmd('raw','U=*')">Follow Video</button>
      <button onclick="cmd('raw','U=$')">Hold Current</button>
    </div>
  </section>

  <section>
    <h2>Auto-Scan Interval</h2>
    <div class="g4">
      <button onclick="cmd('raw','T=1')">3s</button>
      <button onclick="cmd('raw','T=2')">5s</button>
      <button onclick="cmd('raw','T=3')">8s</button>
      <button onclick="cmd('raw','T=4')">12s</button>
    </div>
    <div class="g4">
      <button onclick="cmd('raw','T=5')">15s</button>
      <button onclick="cmd('raw','T=6')">20s</button>
      <button onclick="cmd('raw','T=7')">25s</button>
      <button onclick="cmd('raw','T=8')">30s</button>
    </div>
  </section>

  <section>
    <h2>System</h2>
    <div class="g3">
      <button onclick="cmd('raw','?')">Help Menu</button>
      <button onclick="cmd('raw','K=3')">Device Info</button>
      <button class="danger" onclick="if(confirm('Restart the KVM?'))cmd('raw','H=R')">Restart</button>
    </div>
    <div style="display:flex; gap:8px; margin-top:8px;">
      <input id="rawcmd" type="text" placeholder="raw command, e.g. V1=2" onkeydown="if(event.key==='Enter'){cmd('raw',this.value);}">
      <button onclick="cmd('raw',document.getElementById('rawcmd').value)">Send</button>
    </div>
  </section>

  <div id="status">ready</div>
</main>
<script>
const $s = document.getElementById('status');
let inflight = false;
async function cmd(kind, val) {
  if (inflight) return;
  if (kind === 'raw' && !val) return;
  inflight = true;
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  $s.className = 'busy'; $s.textContent = '...';
  try {
    const r = await fetch('/api/cmd', {
      method: 'POST',
      headers: {'content-type':'application/json'},
      body: JSON.stringify({kind, val})
    });
    const j = await r.json();
    $s.className = j.status === 'OK' ? 'ok' : (j.status === 'FAIL' ? 'fail' : '');
    $s.textContent = `[${j.status}] ${(j.commands||[]).join(', ')}` + (j.body ? '\n' + j.body : '');
  } catch (e) {
    $s.className = 'fail';
    $s.textContent = 'error: ' + e.message;
  } finally {
    inflight = false;
    document.querySelectorAll('button').forEach(b => b.disabled = false);
  }
}
</script>
</body>
</html>
'@

# ──── HTTP plumbing ────

function Send-Json {
    param($Resp, $Obj, [int]$Code=200)
    $json = $Obj | ConvertTo-Json -Compress -Depth 4
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Resp.ContentType = 'application/json'
    $Resp.StatusCode = $Code
    $Resp.ContentLength64 = $bytes.Length
    $Resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $Resp.Close()
}

function Send-Html {
    param($Resp, [string]$Html)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Html)
    $Resp.ContentType = 'text/html; charset=utf-8'
    $Resp.ContentLength64 = $bytes.Length
    $Resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $Resp.Close()
}

function Get-LanIPv4Addresses {
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } |
            Select-Object -ExpandProperty IPAddress -Unique
    } catch {
        @()
    }
}

# ──── Main ────

$sp = Open-KvmPort -Port $Port -Baud $Baud
$listener = New-Object System.Net.HttpListener
[void]$listener.Prefixes.Add("http://localhost:$HttpPort/")
$lanIps = @(Get-LanIPv4Addresses)
foreach ($ip in $lanIps) { [void]$listener.Prefixes.Add("http://${ip}:$HttpPort/") }

try {
    try {
        $listener.Start()
    } catch [System.Net.HttpListenerException] {
        Write-Host "Failed to start HTTP listener." -ForegroundColor Red
        Write-Host "If the error mentions 'Access is denied', run once as Administrator:" -ForegroundColor Yellow
        foreach ($p in $listener.Prefixes) {
            Write-Host "  netsh http add urlacl url=$p user=Everyone" -ForegroundColor Cyan
        }
        throw
    }

    Write-Host ""
    Write-Host "KVM web UI is up. Open from this PC or anything on your LAN:" -ForegroundColor Green
    Write-Host "  http://localhost:$HttpPort/"
    foreach ($ip in $lanIps) { Write-Host "  http://${ip}:$HttpPort/" }
    Write-Host ""
    Write-Host "No authentication — only run on trusted networks." -ForegroundColor Yellow
    Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ""

    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $resp = $ctx.Response
        try {
            if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/') {
                Send-Html -Resp $resp -Html $html
            }
            elseif ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/api/cmd') {
                $reader = New-Object System.IO.StreamReader $req.InputStream
                $body = $reader.ReadToEnd()
                $payload = $body | ConvertFrom-Json -ErrorAction Stop

                $commands = @()
                switch ($payload.kind) {
                    'pc' {
                        $n = [int]$payload.val
                        if ($n -ge 1 -and $n -le 4) {
                            $commands = @("V=$n","A=$n","U=$n")
                        }
                    }
                    'raw' {
                        $v = [string]$payload.val
                        if ($v) { $commands = @($v) }
                    }
                }

                if ($commands.Count -eq 0) {
                    Send-Json -Resp $resp -Obj @{ status='ERR'; body='bad payload'; commands=@() } -Code 400
                } else {
                    $worst = 'OK'
                    $bodies = New-Object System.Collections.Generic.List[string]
                    foreach ($c in $commands) {
                        $r = Invoke-KvmCmd -sp $sp -Command $c
                        $color = if     ($r.status -eq 'OK')   { 'Green' }
                                 elseif ($r.status -eq 'FAIL') { 'Red'   }
                                 else                          { 'DarkGray' }
                        Write-Host ("  {0,-6} {1}" -f "[$($r.status)]", $c) -ForegroundColor $color
                        if ($r.status -eq 'FAIL' -and $worst -ne 'ERR') { $worst = 'FAIL' }
                        if ($r.body) { [void]$bodies.Add($r.body) }
                    }
                    Send-Json -Resp $resp -Obj @{
                        status   = $worst
                        commands = $commands
                        body     = ($bodies -join "`n").Trim()
                    }
                }
            }
            else {
                $resp.StatusCode = 404
                $resp.Close()
            }
        } catch {
            try {
                Send-Json -Resp $resp -Obj @{ status='ERR'; body=$_.Exception.Message; commands=@() } -Code 500
            } catch {}
            Write-Host "  request error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
finally {
    if ($listener -and $listener.IsListening) { $listener.Stop() }
    if ($listener) { $listener.Close() }
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sp) { $sp.Dispose() }
}
