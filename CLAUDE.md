# CLAUDE.md — einstar / RigilGrab

Native SwiftUI macOS app to pull data (STL/OBJ/PLY/images) from the **Einstar /
EinScan Rigil** 3D scanner over WiFi, replacing/augmenting the official EXStar app.

## Version
- Current: **0.1.0** (pre-1.0; transport working, command protocol WIP)
- Version locations: `Scripts/make-app.sh` (`VERSION`), `README.md` badge line, `CHANGELOG.md`.

## Project layout
- `Package.swift` — SPM executable target `RigilGrab`, macOS 13+.
- `Sources/RigilGrab/`
  - `RigilGrabApp.swift` — `@main` App + AppDelegate (sets `.regular` activation so `swift run` shows a real window).
  - `ScannerClient.swift` — `ObservableObject` transport: WebSocket (`:8081`) + HTTP (`:8080`), ping heartbeat, frame log.
  - `ContentView.swift` — UI: connect panel, command console, HTTP fetch, frame table + detail/save.
  - `PayloadKind.swift` — payload classification (STL/OBJ/PLY/PNG/JPEG/JSON/text/binary) + hex helpers.
- `Scripts/make-app.sh` — wrap release binary into `dist/RigilGrab.app` (ad-hoc signed).

## Reverse-engineered Rigil facts (live device)
- Scanner is its **own WiFi-6 AP**; it is `192.168.76.1` (gateway+DHCP+DNS).
- `:8081` WebSocket = control/data channel. PINGs the client; **CLOSES (1000) on unknown command**; does not auto-stream.
- `:8080` HTTP = resource server; bare GETs 404 with `application/x-empty`.
- Also open: `:21` FTP, `:22` SSH, `:443` HTTPS (unexplored).

## Work plan
- [x] Probe device, identify transport (WS:8081 + HTTP:8080).
- [x] SwiftUI app scaffold: connect, command console, frame inspector, HTTP fetch, save.
- [ ] Discover the app-level command to request an STL/image (best via EXStar packet capture).
- [ ] Once command is known: one-click "Pull STL" button + auto-save.
- [ ] Explore `:8080` file paths and `:21` FTP for stored standalone-mode scans.
- [ ] Optional: live preview rendering of streamed frames.

## Notes
- Keep **Ethernet above Wi-Fi** in macOS service order, else the default route goes to the scanner AP (no uplink) and breaks internet. See README.
