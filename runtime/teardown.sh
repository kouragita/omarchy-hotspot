#!/usr/bin/env bash
# Remove the hotspot. Deliberately does NOTHING to wlp2s0 or the uplink.
set -uo pipefail
UPLINK=wlp2s0
APVIF=ap0
# Matches only our own hostapd invocation, never this script or a shell that
# merely mentions the word.
HOSTAPD_PATTERN='hostapd -P /run/hotspot-hostapd\.pid'

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo/pkexec)" >&2; exit 1; }

echo "stopping hotspot (uplink $UPLINK is not touched)"

ufw route delete allow in on "$APVIF" out on "$UPLINK" >/dev/null 2>&1 || true

# Kill hostapd FIRST, and never trust the pidfile alone.
#
# The previous version did `pkill -F pidfile` then `rm -f pidfile`. When pkill
# failed, the pidfile was deleted anyway and the surviving hostapd owned ap0
# forever - pinning it in AP mode and keeping its AUTH frames registered. Every
# later start then failed with nl80211 EALREADY on set_mode and register_frame,
# which looks exactly like "this driver cannot do AP+STA". It could; the process
# was simply never reaped.
stopped=0
if pkill -F /run/hotspot-hostapd.pid >/dev/null 2>&1; then stopped=1; fi
if pkill -f "$HOSTAPD_PATTERN" >/dev/null 2>&1; then stopped=1; fi
sleep 1
if pgrep -f "$HOSTAPD_PATTERN" >/dev/null 2>&1; then
  pkill -9 -f "$HOSTAPD_PATTERN" >/dev/null 2>&1
  stopped=1
fi
if [ "$stopped" -eq 1 ]; then echo "  hostapd stopped"; else echo "  hostapd was not running"; fi

pkill -F /run/hotspot-dnsmasq.pid >/dev/null 2>&1 && echo "  dnsmasq stopped"

nft delete table ip hotspot >/dev/null 2>&1 && echo "  NAT rules removed"

ip link set "$APVIF" down 2>/dev/null
if iw dev | grep -q "Interface $APVIF"; then
  iw dev "$APVIF" del >/dev/null 2>&1 && echo "  $APVIF removed"
fi

# Only now is the pidfile meaningless.
rm -f /run/hotspot-hostapd.conf /run/hotspot-hostapd.pid /run/hotspot-dnsmasq.pid

# A silent leftover is what caused the original bug, so verify out loud.
if iw dev | grep -q "Interface $APVIF"; then
  echo "  WARNING: $APVIF still exists after teardown" >&2
fi
if pgrep -f "$HOSTAPD_PATTERN" >/dev/null 2>&1; then
  echo "  WARNING: hostapd still running after teardown" >&2
fi

echo
echo "still connected to the uplink:"
iw dev "$UPLINK" info 2>/dev/null | grep -E 'ssid|type|channel' | sed 's/^/  /'
ip -4 -o addr show dev "$UPLINK" | awk '{print "  ip "$4}'
