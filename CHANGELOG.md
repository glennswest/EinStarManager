# Changelog

## [Unreleased]

### 2026-06-08
- **feat:** In-app scan download — each scan in the Stored-objects panel has a **Download** button: pick a folder, RigilKit connects + fires the trigger, receives the stream, extracts the bundled files + preview via `RigilArchive`, saves them, and shows the preview image inline. The real app now does discover → list scans → download, no scripts.
- **feat:** RigilKit data plane — `RigilDownloader` (control+data connections, env-0x01 download trigger, `op52` ranged file fetch via `path|start|end`, stream drain) and `RigilArchive` (Swift port of the capture extractor: carves preview PNGs + `QVariantMap`-bundled files). Moves the proven download mechanics out of throwaway scripts into the app's library.
- **feat:** `Scripts/hotspot-connect.sh` — one command to join the Rigil hotspot AND keep internet: auto-joins the AP, then a retry loop deletes ONLY the scanner's default route (gw 192.168.76.1) and pins `192.168.76.0/24` to Wi-Fi. Never bulk-deletes routes, so it can't drop the uplink. (This is the sequence the app will perform via a privileged helper.)
- **feat:** `RigilKit` Swift library — CBOR codec, port-5678 frame codec, and an async `RigilControlClient` (connect, handshake, ping/pong keepalive, `deviceInfo`, `projectsInfo`) with typed `RigilProject`/`RigilDeviceInfo` models.
- **feat:** App "List objects" panel — lists stored scans (group/name, size, mesh/texture, date) live from the scanner via RigilKit.
- **feat:** `Scripts/extract-capture.py` — carve project files (preview PNGs, calibration, bins) straight out of a download capture.
- **docs:** PROTOCOL.md expanded to the full three-channel architecture (control + data + ZeroMQ `TXCommData` event bus), the env-0x01 download trigger, and the `QVariantMap` file-bundle/ranged-read data format.

### 2026-06-08
- **docs:** Added `PROTOCOL.md` — full reverse-engineered EinScan Rigil WiFi protocol (TCP 5678, framed CBOR control plane + Qt-style data plane). Verified live: handshake, `deviceInfo`, `projectsInfo` (object listing), ping/pong keepalive. Data/file channel format decoded from capture.

### 2026-06-07
- **feat:** Auto-discovery — in-app subnet sweep finds the Einstar automatically. TCP-probes `:8081` across the Mac's own subnets plus user-listed `/24` prefixes (ICMP-independent, since the Rigil firewalls ping), then confirms each hit by the `:8080` `application/x-empty` signature. Confirmed devices are auto-selected; one-click Use/Connect from the results list.
- **chore:** Renamed project/app from `RigilGrab` to `EinStarManager` (target, sources, bundle id, docs).
- **docs:** Noted EXStar is Windows-only — protocol capture must be done on Windows (Wireshark).
- **feat:** Initial `EinStarManager` SwiftUI macOS app — connects to the Einstar Rigil 3D scanner over WiFi (WebSocket `:8081` + HTTP `:8080`), keeps the socket alive (ping/pong), sends commands, logs/inspects/saves received frames, and detects STL/OBJ/PLY/PNG/JPEG payloads.
- **feat:** `Scripts/make-app.sh` bundles the release binary into a double-clickable `.app`.
- **docs:** Documented the reverse-engineered Rigil transport (scanner at `192.168.76.1`; `:8081` WebSocket data channel that closes on unknown commands; `:8080` HTTP resource server).
