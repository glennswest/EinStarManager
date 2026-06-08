#!/bin/bash
#
# hotspot-connect.sh — join the EinScan Rigil's WiFi hotspot WITHOUT letting it
# take over the default route / internet.
#
# The Rigil's "hotpot" mode is its own AP (gateway 192.168.76.1). By default macOS
# makes whatever service is highest in the service order the *primary* one and routes
# the default through it — so joining the hotspot kills your uplink. This script keeps
# Ethernet primary and routes ONLY the scanner subnet (192.168.76.0/24) over WiFi.
#
# Usage:
#   sudo ./Scripts/hotspot-connect.sh "<SSID>" "<PASSWORD>"   # join + fix routing
#   sudo ./Scripts/hotspot-connect.sh                          # fix routing only
#   sudo ./Scripts/hotspot-connect.sh --off                    # leave hotspot, restore
#
# Needs root (route + networksetup). Run via:  ! sudo ./Scripts/hotspot-connect.sh ...
set -euo pipefail

WIFI_DEV="${WIFI_DEV:-en1}"
ETH_SERVICE="${ETH_SERVICE:-Ethernet}"
WIFI_SERVICE="${WIFI_SERVICE:-Wi-Fi}"
SCANNER_NET="192.168.76.0/24"
SCANNER_IP="192.168.76.1"

if [[ "${1:-}" == "--off" ]]; then
  echo "==> Disassociating Wi-Fi and clearing scanner route"
  route -n delete -net "$SCANNER_NET" 2>/dev/null || true
  networksetup -setairportpower "$WIFI_DEV" off || true
  networksetup -setairportpower "$WIFI_DEV" on || true
  echo "    done."
  exit 0
fi

SSID="${1:-}"; PASS="${2:-}"

# --- 1. Keep Ethernet primary so the default route never moves to the hotspot ---
# Build a new service order with Ethernet first, Wi-Fi second, everything else after.
mapfile -t CURRENT < <(networksetup -listnetworkserviceorder | sed -n 's/^([0-9][0-9]*) //p')
NEWORDER=("$ETH_SERVICE" "$WIFI_SERVICE")
for s in "${CURRENT[@]}"; do
  [[ "$s" == "$ETH_SERVICE" || "$s" == "$WIFI_SERVICE" ]] && continue
  NEWORDER+=("$s")
done
echo "==> Setting service order (Ethernet primary): ${NEWORDER[*]}"
networksetup -ordernetworkservices "${NEWORDER[@]}"

# --- 2. Join the hotspot (if SSID given) ---
if [[ -n "$SSID" ]]; then
  echo "==> Joining hotspot '$SSID' on $WIFI_DEV"
  networksetup -setairportpower "$WIFI_DEV" on
  if [[ -n "$PASS" ]]; then
    networksetup -setairportnetwork "$WIFI_DEV" "$SSID" "$PASS"
  else
    networksetup -setairportnetwork "$WIFI_DEV" "$SSID"   # open / saved network
  fi
  for _ in $(seq 1 25); do
    ip="$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null || true)"
    [[ "$ip" == 192.168.76.* ]] && break
    sleep 1
  done
fi

ip="$(ipconfig getifaddr "$WIFI_DEV" 2>/dev/null || true)"
if [[ "$ip" != 192.168.76.* ]]; then
  echo "!! Wi-Fi ($WIFI_DEV) is not on the scanner subnet (got '${ip:-none}')."
  echo "   Join the hotspot first, or pass the SSID/password."
  exit 1
fi

# --- 3. Strip the hotspot's default route; pin only the scanner subnet to WiFi ---
echo "==> Pinning $SCANNER_NET to $WIFI_DEV, removing hotspot default route"
route -n delete default "$SCANNER_IP" 2>/dev/null || true   # drop hotspot's default
route -n add -net "$SCANNER_NET" -interface "$WIFI_DEV" 2>/dev/null || true

# --- 4. Report ---
echo "==> Result:"
gw="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
sif="$(route -n get "$SCANNER_IP" 2>/dev/null | awk '/interface/{print $2}')"
echo "    default route : ${gw:-?}   (should be your Ethernet gateway, NOT $SCANNER_IP)"
echo "    scanner $SCANNER_IP via: ${sif:-?}  (should be $WIFI_DEV)"
if [[ "$gw" == "$SCANNER_IP" ]]; then
  echo "!!  default route is STILL the scanner — internet will be broken."
  exit 1
fi
echo "    OK: internet stays on Ethernet, scanner reachable over Wi-Fi."
