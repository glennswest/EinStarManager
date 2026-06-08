# EinStarManager

A native **SwiftUI macOS app** for talking to the **Einstar / EinScan Rigil** 3D scanner
over WiFi and pulling data (STL / OBJ / PLY / images) off it without the official
EXStar software.

> Status: **0.3.0 — discovery, control protocol, and live object listing working.**
> The app finds the scanner, connects over the real EXStar protocol (TCP 5678, `RigilKit`),
> and **lists stored scans** live. The download/file format is fully decoded (see
> [PROTOCOL.md](PROTOCOL.md)); the live trigger to start a standalone download is identified
> but still gated by a project-selection step.

## What we know about the Rigil over WiFi

Established by probing a live Rigil (connected to its WiFi-6 AP):

| Endpoint | Role |
|----------|------|
| scanner address | `192.168.76.1` on its **own AP**, or a DHCP address (e.g. `192.168.9.129`) when **joined to your LAN** (routable, no routing conflict). Use **Scan** to find it — it firewalls ICMP, so discovery is by TCP probe of `:8081`, not ping. |
| `:8081` (WebSocket) | Control/data channel. Sends PING frames; **closes the socket (code 1000) on an unrecognized command.** URLSession auto-pongs, so the link stays alive on its own. Does **not** auto-stream — it waits for the correct app-level command. |
| `:8080` (HTTP) | Resource server. Plain `GET /` and common paths return an empty `404`; finished files are likely served from specific paths. |
| `:21`, `:22`, `:443` | FTP / SSH / HTTPS also open (unexplored). |

The application-level command vocabulary on `:8081` is **proprietary**. The official
EXStar software is **Windows-only** (no macOS build yet), so the reliable way to learn
the protocol is to packet-capture EXStar on a Windows machine (Wireshark, filter
`ip.addr == 192.168.76.1`) while it pulls a scan, then replay those commands here. The
app's command console + frame inspector let you discover and drive them interactively
in the meantime.

## Build & run

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
# Dev mode — opens a window directly
swift run

# Or build a double-clickable .app into dist/
./Scripts/make-app.sh
open dist/EinStarManager.app
```

## Using it

0. **Scan** (Auto-discover panel) to sweep your subnets — add prefixes like
   `192.168.8, 192.168.9` if the scanner is on a different subnet than the Mac.
   Confirmed Einstars get a green seal and are auto-selected; hit **Connect**.
1. Or **Connect** manually (WS `8081`, HTTP `8080`).
2. **Send a WebSocket command** — pick a candidate or type your own. Watch the frame
   log for a reply vs. a close. (A close means the command was rejected — reconnect
   and try another.)
3. **Inspect frames** — incoming binary frames are classified (STL/OBJ/PLY/PNG/JPEG/
   JSON). Select one to view hex/text and **Save…** it to disk.
4. **HTTP fetch** — probe `:8080` paths; save any non-empty body (e.g. a served STL).

## Networking note

The Rigil joins as its own WiFi AP. If your Mac's Wi-Fi service outranks Ethernet in
*System Settings → Network → (…) → Set Service Order*, macOS will route the **default
route through the scanner** (which has no uplink) and break internet. Keep **Ethernet
above Wi-Fi** in the service order:

```bash
sudo networksetup -ordernetworkservices "Ethernet" "Wi-Fi" ...
```

This leaves the Rigil reachable on `192.168.76.0/24` while internet goes out the wire.
