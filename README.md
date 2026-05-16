# Level1Techs KVM Control

PowerShell tooling for the **Level1Techs HDMI 2.1 KVM** over its rear RJ-11 RS-232 port.

Two scripts:

- **`kvm.ps1`** — CLI / REPL for switching video, audio, USB, auto-scan, restart, etc.
- **`kvm-server.ps1`** — phone-friendly LAN web UI; one tap to switch ports from anywhere on your network.

A third script, `probe-kvm-serial.ps1`, is included for first-time bring-up if you don't know what baud the device uses.

---

## Serial setup

The KVM speaks **19200 8N1, no flow control** over RJ-11 → RS-232. Plug an RS-232 USB adapter into the back of the KVM and note which COM port it shows up as in Device Manager. Default in these scripts is `COM5` — pass `-Port COM3` (or whatever) if yours is different.

Accepted commands respond with `>`, rejected with `<`. Commands are uppercase only.

---

## `kvm.ps1` — CLI and REPL

The everyday tool. Run with flags for one-shot actions, or run with no flags for an interactive REPL.

### One-shot examples

```powershell
# Switch video + audio + USB to PC 2 (the common case)
.\kvm.ps1 -PC 2

# Only switch video to port 1
.\kvm.ps1 -Video 1

# Audio and USB to port 3, leave video alone
.\kvm.ps1 -Audio 3 -USB 3

# Cycle to next / previous active video port
.\kvm.ps1 -Next
.\kvm.ps1 -Prev

# Start auto-scan, stop auto-scan
.\kvm.ps1 -StartScan
.\kvm.ps1 -StopScan

# Set auto-scan interval step (1..8 → 3..30 seconds)
.\kvm.ps1 -ScanInterval 5

# Audio / USB follow-video vs. hold-current
.\kvm.ps1 -AudioFollow
.\kvm.ps1 -AudioHold
.\kvm.ps1 -USBFollow
.\kvm.ps1 -USBHold

# Restart the KVM
.\kvm.ps1 -Restart

# Factory reset (asks for 'yes' confirmation)
.\kvm.ps1 -FactoryReset

# Print device help menu
.\kvm.ps1 -Status

# Raw command escape hatch (anything the device understands)
.\kvm.ps1 -Cmd "V=1"

# Different COM port / baud
.\kvm.ps1 -Port COM3 -PC 2
.\kvm.ps1 -Port COM3 -Baud 19200 -Status
```

### REPL

Run with no flags and you get a prompt:

```powershell
.\kvm.ps1
```

Shortcuts inside the REPL:

| Type            | Does                                         |
|-----------------|----------------------------------------------|
| `1` `2` `3` `4` | Switch PC (video + audio + USB to that port) |
| `v2` `a3` `u1`  | Switch only video / audio / USB              |
| `next` `prev`   | Next / previous active video port            |
| `scan` `stop`   | Start / stop video auto-scan                 |
| `t5`            | Auto-scan interval step 1..8                 |
| `restart`       | Restart the KVM                              |
| `reset`         | Factory reset (confirms first)               |
| `?`             | Device help menu                             |
| `:V=1`          | Raw command escape hatch                     |
| `exit`          | Leave REPL                                   |

Responses are tagged `[ OK ]` (green), `[FAIL]` (red), or `[ ?  ]` (unknown).

### Probe mode

If you want to discover what commands the firmware actually accepts:

```powershell
# Standard probe — single letters, X=value, XN=M, common identifiers (~3 min)
.\kvm.ps1 -Probe

# Deep probe — adds all two-letter combos and letter-value variants (~9 min)
.\kvm.ps1 -DeepProbe

# Full probe — adds every three-letter combo (~80 min)
.\kvm.ps1 -FullProbe

# Prefix every probe (e.g., test if commands need a leading character)
.\kvm.ps1 -Probe -Prefix "#"
```

`H=R` (restart) and anything matching `FAC` (factory reset) are hard-excluded so the probe can't brick its own run. Monitors **will** switch around as the probe finds valid commands — that's expected.

---

## `kvm-server.ps1` — LAN web UI

Holds the serial port open and serves a phone-friendly page on `:8080` (default). Bind a browser on your laptop, tablet, or phone and tap PC 1-4 to switch.

### Run it

```powershell
# Default: COM5, 19200, HTTP on 8080
.\kvm-server.ps1

# Different port, different baud, different HTTP port
.\kvm-server.ps1 -Port COM3 -Baud 19200 -HttpPort 8888
```

It binds to `localhost` plus every preferred LAN IPv4 your machine has, and prints the URLs:

```
KVM web UI is up. Open from this PC or anything on your LAN:
  http://localhost:8080/
  http://192.168.1.42:8080/

No authentication — only run on trusted networks.
Press Ctrl+C to stop.
```

First run will trigger a Windows Firewall prompt — click **Allow** for Private/LAN.

### What the UI gives you

- **PC 1-4** big buttons — switch video + audio + USB in one tap
- **Video / Audio / USB** — per-lane port pickers, plus Prev / Auto / Stop / Next for video, Follow Video / Hold Current for audio and USB
- **Auto-scan interval** — 3s / 5s / 8s / 12s / 15s / 20s / 25s / 30s
- **System** — help menu, device info (`K=3`), restart (with confirm)
- **Raw command** — free-text input for anything the device understands (e.g. `V1=2`)

Status line below the buttons shows `[OK]` / `[FAIL]` plus any response body the device returned.

### HTTP API

The web UI calls a single endpoint. You can hit it from `curl` or anything else:

```powershell
# Switch PC
curl.exe -X POST http://localhost:8080/api/cmd `
  -H "content-type: application/json" `
  -d '{"kind":"pc","val":2}'

# Raw command
curl.exe -X POST http://localhost:8080/api/cmd `
  -H "content-type: application/json" `
  -d '{"kind":"raw","val":"V=3"}'
```

Response is JSON: `{ "status": "OK", "commands": ["V=2","A=2","U=2"], "body": "" }`.

### Security note

There is **no authentication**. The script binds to specific LAN IPs (not `+` or `*`) so it does not require an admin URL ACL, but anyone who can reach the IP can switch your KVM. Run on a trusted home/office LAN only.

---

## `probe-kvm-serial.ps1` — first-time bring-up

If you don't know the baud rate or aren't sure the cable is wired correctly, run this once. It sweeps 115200 / 57600 / 38400 / 19200 / 9600 / 4800 / 2400 and pokes each with `CR`, `LF`, `CRLF`, `?`, `help`, `Ctrl-Ctrl`, and `ESC`, printing ASCII + hex of whatever comes back.

```powershell
.\probe-kvm-serial.ps1                # defaults to COM3
.\probe-kvm-serial.ps1 -Port COM5
```

Look for a row where the ASCII column is clean readable text — that's your baud. For this KVM it's **19200**. If every row is `(no response)`, RJ-11 TX/RX is likely swapped — try a null-modem adapter.

---

## Protocol cheatsheet

| Command  | Meaning                                       |
|----------|-----------------------------------------------|
| `V=N`    | Video to port N (1-4)                         |
| `A=N`    | Audio to port N (1-4)                         |
| `U=N`    | USB 3.2 to port N (1-4)                       |
| `V=<` `V=>` | Previous / next active video port          |
| `V=A`    | Start video auto-scan                         |
| `V=$`    | Stop video auto-scan                          |
| `T=N`    | Auto-scan interval step 1-8 (3s..30s)         |
| `A=*` `A=$` | Audio follow video / hold current          |
| `U=*` `U=$` | USB follow video / hold current            |
| `H=R`    | Restart the KVM                               |
| `H=FAC`  | Factory reset                                 |
| `?`      | Print device help                             |
| `K=3`    | Device info (discovered via probe)            |

EDID is **not** a serial command on this KVM — it's the physical button on the back.

---

## Files

```
kvm.ps1                 CLI + REPL
kvm-server.ps1          LAN web UI
probe-kvm-serial.ps1    Baud sweep / bring-up
manual/                 Reference photos from the device manual
```

---

## License

MIT — see [LICENSE](LICENSE).
