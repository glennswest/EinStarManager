# Changelog

## [Unreleased]

### 2026-06-07
- **feat:** Initial `RigilGrab` SwiftUI macOS app — connects to the Einstar Rigil 3D scanner over WiFi (WebSocket `:8081` + HTTP `:8080`), keeps the socket alive (ping/pong), sends commands, logs/inspects/saves received frames, and detects STL/OBJ/PLY/PNG/JPEG payloads.
- **feat:** `Scripts/make-app.sh` bundles the release binary into a double-clickable `.app`.
- **docs:** Documented the reverse-engineered Rigil transport (scanner at `192.168.76.1`; `:8081` WebSocket data channel that closes on unknown commands; `:8080` HTTP resource server).
