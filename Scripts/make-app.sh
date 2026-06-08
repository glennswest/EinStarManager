#!/bin/bash
# Build EinStarManager and wrap the executable into a double-clickable macOS .app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="EinStarManager"
VERSION="0.2.0"
DIST="dist/${APP}.app"

echo "==> Building release binary"
swift build -c release

BIN=".build/release/${APP}"
[ -x "$BIN" ] || { echo "build output not found at $BIN"; exit 1; }

echo "==> Assembling ${DIST}"
rm -rf "$DIST"
mkdir -p "${DIST}/Contents/MacOS" "${DIST}/Contents/Resources"
cp "$BIN" "${DIST}/Contents/MacOS/${APP}"

cat > "${DIST}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP}</string>
  <key>CFBundleDisplayName</key><string>${APP}</string>
  <key>CFBundleIdentifier</key><string>com.neuralcloud.einstarmanager</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it run locally (no Developer ID needed).
codesign --force --deep --sign - "$DIST" 2>/dev/null || \
  echo "   (codesign skipped — app still runs locally)"

echo "==> Done: ${DIST}"
echo "    open \"${DIST}\"   # or: swift run   for dev mode"
