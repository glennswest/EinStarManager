#!/bin/bash
#
# hotspot-connect.sh — join the EinScan Rigil's WiFi hotspot WITHOUT letting it
# steal the default route / internet.
#
# SAFETY: this script ONLY ever deletes the *scanner's own* default route
# (gateway 192.168.76.1). It never deletes the wired default route, so it
# cannot leave you with no internet.
#
# Usage (needs root — run via:  ! sudo ./Scripts/hotspot-connect.sh ... ):
#   sudo ./Scripts/hotspot-connect.sh "<SSID>"   # join hotspot + fix routing
#   sudo ./Scripts/hotspot-connect.sh            # fix routing only (already joined)
#   sudo ./Scripts/hotspot-connect.sh --off      # leave hotspot
set -uo pipefail

WIFI_DEV="${WIFI_DEV:-en1}"
SCANNER_NET="192.168.76.0/24"
SCANNER_GW="192.168.76.1"

if [[ "${1:-}" == "--off" ]]; then
  networksetup -setairportpower "$WIFI_DEV" off
  networksetup -setairportpower "$WIFI_DEV" on
  echo "left hotspot."; exit 0
fi

SSID="${1:-}"
if [[ -n "$SSID" ]]; then
  echo "==> Joining '$SSID' on $WIFI_DEV (open/saved network)"
  networksetup -setairportpower "$WIFI_DEV" on
  networksetup -setairportnetwork "$WIFI_DEV" "$SSID"
  for _ in $(seq 1 20); do
    [[ "$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)" == 192.168.76.* ]] && break
    sleep 1
  done
fi

ip="$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)"
if [[ "$ip" != 192.168.76.* ]]; then
  echo "!! $WIFI_DEV is not on the scanner subnet (got '${ip:-none}'). Join the hotspot first."
  exit 1
fi

# The ONLY mutation: drop the scanner's default route (targeted gateway).
# The wired default route is never touched.
echo "==> Removing scanner default route ($SCANNER_GW), keeping wired default"
route -n delete default "$SCANNER_GW" 2>/dev/null && echo "    deleted." || echo "    (none present — fine)"
# Make sure the scanner subnet is still reachable over Wi-Fi.
route -n add -net "$SCANNER_NET" -interface "$WIFI_DEV" 2>/dev/null

gw="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
echo "==> default route now via: ${gw:-none}"
if [[ "$gw" == "$SCANNER_GW" || -z "$gw" ]]; then
  echo "!!  default is '$gw' — NOT fixed (wired default missing?). Toggle Ethernet and retry."
  exit 1
fi
echo "    OK — internet via $gw, scanner reachable at $SCANNER_GW over $WIFI_DEV."
