# CLAUDE.md — einstar / EinStarManager

Native SwiftUI macOS app to pull data (STL/OBJ/PLY/images) from the **Einstar /
EinScan Rigil** 3D scanner over WiFi, replacing/augmenting the official EXStar app.

## Version
- Current: **0.4.0** (pre-1.0; discovery + control protocol + live scan listing + in-app download UI)
- Version locations: `Scripts/make-app.sh` (`VERSION`), `README.md` badge line, `CHANGELOG.md`.

## Project layout
- `Package.swift` — SPM executable target `EinStarManager`, macOS 13+.
- `Sources/EinStarManager/`
  - `EinStarManagerApp.swift` — `@main` App + AppDelegate (sets `.regular` activation so `swift run` shows a real window).
  - `ScannerClient.swift` — `ObservableObject` transport: WebSocket (`:8081`) + HTTP (`:8080`), ping heartbeat, frame log, discovery state.
  - `Discovery.swift` — subnet sweep: `NWConnection` TCP probe of `:8081` + `:8080` signature confirm; local interface `/24` enumeration via `getifaddrs`.
  - `ContentView.swift` — UI: discover panel, connect panel, command console, HTTP fetch, frame table + detail/save.
  - `PayloadKind.swift` — payload classification (STL/OBJ/PLY/PNG/JPEG/JSON/text/binary) + hex helpers.
- `Scripts/make-app.sh` — wrap release binary into `dist/EinStarManager.app` (ad-hoc signed).

## Reverse-engineered Rigil facts (live device)
- Two modes seen: its **own WiFi-6 AP** (`192.168.76.1`, gateway+DHCP+DNS), and **joined to the LAN** (DHCP, e.g. `192.168.9.129` — routable from Ethernet, no routing conflict).
- Identified by signature: `:8081` WebSocket (`Server: webserver`) + `:8080` HTTP returning `application/x-empty` 404. Firewalls ICMP (ping fails even when up) — discover via TCP probe, not ping.
- `:8081` WebSocket = control/data channel. PINGs the client; **CLOSES (1000) on unknown command**; does not auto-stream.
- `:8080` HTTP = resource server; bare GETs 404 with `application/x-empty`.
- Also open: `:21` FTP, `:22` SSH, `:443` HTTPS (unexplored).

## Work plan
- [x] Probe device, identify transport (WS:8081 + HTTP:8080).
- [x] SwiftUI app scaffold: connect, command console, frame inspector, HTTP fetch, save.
- [x] In-app auto-discovery (subnet sweep + signature confirm).
- [ ] Discover the app-level command to request an STL/image (EXStar is **Windows-only** — capture with Wireshark on Windows).
- [ ] Once command is known: one-click "Pull STL" button + auto-save.
- [ ] Explore `:8080` file paths and `:21` FTP for stored standalone-mode scans.
- [ ] Optional: live preview rendering of streamed frames.

## Notes
- Keep **Ethernet above Wi-Fi** in macOS service order, else the default route goes to the scanner AP (no uplink) and breaks internet. See README.
