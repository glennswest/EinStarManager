#!/bin/bash
#
# hotspot-connect.sh — join the EinScan Rigil's WiFi hotspot AND keep internet,
# in one command. Joining the Rigil's "hotpot" AP (gateway 192.168.76.1) makes
# macOS install a default route over Wi-Fi which kills the uplink; this removes
# only that one route and pins the scanner subnet to Wi-Fi.
#
# SAFETY: only ever deletes the *scanner's* default route (gw 192.168.76.1).
# The wired default route is never touched, so this cannot drop your internet.
#
# This is the exact sequence the app must perform (via a privileged helper).
#
# Usage (root — run via:  ! sudo ./Scripts/hotspot-connect.sh [SSID] ):
#   sudo ./Scripts/hotspot-connect.sh                       # auto-join default SSID + fix
#   sudo ./Scripts/hotspot-connect.sh "EinScanRigil_XXXX"   # join a specific SSID + fix
#   sudo ./Scripts/hotspot-connect.sh --fix                 # fix routing only (already joined)
#   sudo ./Scripts/hotspot-connect.sh --off                 # leave hotspot
set -uo pipefail

WIFI_DEV="${WIFI_DEV:-en1}"
SCANNER_NET="192.168.76.0/24"
SCANNER_GW="192.168.76.1"
DEFAULT_SSID="${RIGIL_SSID:-EinScanRigil_BF031C20B}"

note() { printf '%s\n' "$*"; }

leave() {
  networksetup -setairportpower "$WIFI_DEV" off
  networksetup -setairportpower "$WIFI_DEV" on
  note "left hotspot."
}

# Remove ONLY the scanner's default route; re-pin the scanner subnet to Wi-Fi.
# Returns 0 if the surviving default route is NOT the scanner.
fix_routing() {
  route -n delete default "$SCANNER_GW" 2>/dev/null && note "    removed scanner default route" || true
  route -n add -net "$SCANNER_NET" -interface "$WIFI_DEV" 2>/dev/null || true
  local gw; gw="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
  [[ -n "$gw" && "$gw" != "$SCANNER_GW" ]]
}

case "${1:-}" in
  --off) leave; exit 0 ;;
  --fix) SSID="" ;;
  "")    SSID="$DEFAULT_SSID" ;;
  *)     SSID="$1" ;;
esac

# 1. Join (open/saved network — no password)
if [[ -n "$SSID" ]]; then
  note "==> Joining '$SSID' on $WIFI_DEV"
  networksetup -setairportpower "$WIFI_DEV" on
  networksetup -setairportnetwork "$WIFI_DEV" "$SSID" || { note "!! join failed"; exit 1; }
fi

# 2. Wait for an address on the scanner subnet
for _ in $(seq 1 20); do
  [[ "$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)" == 192.168.76.* ]] && break
  sleep 1
done
ip="$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null)"
if [[ "$ip" != 192.168.76.* ]]; then
  note "!! $WIFI_DEV not on scanner subnet (got '${ip:-none}'). Is the hotspot up?"; exit 1
fi
note "==> $WIFI_DEV has $ip on the scanner subnet"

# 3. Fix routing, retrying — DHCP may re-add the scanner default just after the lease
ok=1
for _ in $(seq 1 6); do
  if fix_routing; then ok=0; break; fi
  sleep 1
done

gw="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
if [[ $ok -eq 0 ]]; then
  note "==> OK — default route via $gw (internet on the wire), scanner reachable at $SCANNER_GW over $WIFI_DEV."
  exit 0
else
  note "!! default route is '${gw:-none}', still pointing at the scanner or missing."
  note "   Your wired link must be up (DHCP) to provide a default route. Check Ethernet."
  exit 1
fi
