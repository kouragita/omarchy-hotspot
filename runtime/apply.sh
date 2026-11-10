#!/usr/bin/env bash
# Concurrent Wi-Fi hotspot: keep wlp2s0 associated to the upstream AP and add a
# SECOND vif (ap0) on the same phy in AP mode.
#
# SAFETY CONTRACT
#   * wlp2s0 is only ever INSPECTED - no down/up/disconnect/reconnect.
#   * The AP mirrors the uplink's channel AND bandwidth (iwlwifi: #channels<=1).
#   * Any change to uplink ssid/ip/route after the AP starts -> full rollback.
#   * hostapd's output is always captured, never discarded.
set -uo pipefail

# Parse tool output and validate character classes in the C locale.
# Without this, ranges like [!-~] are resolved by collation order in a UTF-8
# locale and silently stop matching printable ASCII, which made validation
# pass in a C-locale shell and fail when run as a systemd service.
export LC_ALL=C

UPLINK=wlp2s0
APVIF=ap0
APIP=10.42.0.1
NET=10.42.0.0/24
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF=/run/hotspot-hostapd.conf
LOG=/run/hotspot-hostapd.log

ROLLBACK=0
info() { echo "  -> $*"; }

rollback() {
  [ "$ROLLBACK" -eq 1 ] || return 0
  echo "!! ROLLING BACK (the uplink is never touched)" >&2
  # Kill hostapd by pidfile AND by a pattern unique to our invocation. A
  # surviving hostapd owns ap0 and poisons every later run with EALREADY.
  pkill -F /run/hotspot-hostapd.pid 2>/dev/null
  pkill -f 'hostapd -P /run/hotspot-hostapd\.pid' 2>/dev/null
  sleep 1
  pkill -9 -f 'hostapd -P /run/hotspot-hostapd\.pid' 2>/dev/null
  pkill -F /run/hotspot-dnsmasq.pid 2>/dev/null
  nft delete table ip hotspot 2>/dev/null
  ip link set "$APVIF" down 2>/dev/null
  iw dev "$APVIF" del 2>/dev/null
  ROLLBACK=0
  if pgrep -f 'hostapd -P /run/hotspot-hostapd\.pid' >/dev/null 2>&1; then
    echo "!! WARNING: hostapd survived rollback" >&2
  fi
  echo "!! rollback done" >&2
}

die() {
  echo "ERROR: $*" >&2
  rollback
  exit 1
}

trap 'rollback' EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v hostapd >/dev/null || die "hostapd not installed: sudo pacman -S hostapd"

# ------------------------------------------------ 1. purge NM AP-mode profiles
echo "[1/8] removing NetworkManager AP-mode profiles (these hijack wlp2s0)"
while IFS=: read -r _uuid _name; do
  [ -n "${_uuid:-}" ] || continue
  if nmcli -g 802-11-wireless.mode connection show "$_uuid" 2>/dev/null | grep -qx 'ap'; then
    nmcli connection delete "$_uuid" >/dev/null 2>&1 \
      && info "deleted NM AP profile '$_name'" || true
  fi
done < <(nmcli -t -f UUID,NAME,TYPE connection show | awk -F: '$3=="802-11-wireless"{print $1":"$2}')

# Tell NM to leave the AP vif alone BEFORE it exists. Installing this at the end
# of the run left a window where NM auto-managed ap0 the moment it appeared and
# raced hostapd ("nl80211: Could not configure driver mode").
NM_RELOADED=0
NMCONF=/etc/NetworkManager/conf.d/99-ap0-unmanaged.conf
if [ -d /etc/NetworkManager/conf.d ] && [ ! -e "$NMCONF" ]; then
  install -m 644 "$HERE/99-ap0-unmanaged.conf" "$NMCONF"
  info "installed $NMCONF"
  NM_RELOADED=1
fi
if [ "$NM_RELOADED" -eq 1 ]; then
  nmcli general reload conf >/dev/null 2>&1 && info "NM reloaded: $APVIF is unmanaged from now on"
fi

# ------------------------------------------------------------- 2. preflight
echo "[2/8] preflight: verifying the uplink (read-only)"
UP_SSID=$(iw dev "$UPLINK" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p')
[ -n "$UP_SSID" ] || die "$UPLINK is not associated - refusing to start"
UP_IP=$(ip -4 -o addr show dev "$UPLINK" | awk '{print $4}')
[ -n "$UP_IP" ] || die "$UPLINK has no IPv4 address - refusing to start"
UP_ROUTE=$(ip route show default | head -1)
[ -n "$UP_ROUTE" ] || die "no default route - refusing to start"

FREQ=$(iw dev "$UPLINK" link 2>/dev/null \
  | sed -n 's/^[[:space:]]*freq:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[ -n "${FREQ:-}" ] || die "cannot read uplink frequency"
[ "$FREQ" -lt 3000 ] || die "uplink is ${FREQ}MHz (5GHz); #channels<=1 cannot mirror it"

if   [ "$FREQ" -eq 2484 ]; then CHANNEL=14
elif [ "$FREQ" -ge 2412 ] && [ "$FREQ" -le 2472 ]; then CHANNEL=$(( (FREQ - 2407) / 5 ))
else die "uplink on ${FREQ}MHz is not a usable 2.4GHz channel"; fi

# Mirror the uplink's exact channel context (width + center), which is what
# mac80211/iwlwifi actually check. Mismatched HT width => EBUSY on start.
UPINFO=$(iw dev "$UPLINK" info)
WIDTH=$(sed -n 's/.*width:\? *\([0-9][0-9]*\) MHz.*/\1/p' <<<"$UPINFO")
CENTER=$(sed -n 's/.*center1:\? *\([0-9][0-9]*\).*/\1/p' <<<"$UPINFO")
HT=""
if [ "${WIDTH:-20}" -ge 40 ] && [ -n "${CENTER:-}" ]; then
  if [ "$CENTER" -gt "$FREQ" ]; then HT="[HT40+][SHORT-GI-20][SHORT-GI-40]"
  else HT="[HT40-][SHORT-GI-20][SHORT-GI-40]"; fi
fi

info "uplink : $UPLINK ssid='$UP_SSID' ip=$UP_IP"
info "channel: $CHANNEL (${FREQ}MHz) width=${WIDTH:-20} center=${CENTER:-n/a} ht='${HT:-none}'"

snapshot() {
  printf '%s|%s|%s' \
    "$(iw dev "$UPLINK" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p')" \
    "$(ip -4 -o addr show dev "$UPLINK" 2>/dev/null | awk '{print $4}')" \
    "$(ip route show default 2>/dev/null | head -1)"
}
BEFORE=$(snapshot)

if iw dev | grep -q "Interface $APVIF"; then
  info "$APVIF exists from an earlier run; step 4 reclaims it"
fi

# --------------------------------------------------- 3. render hostapd config
# SSID/password live in the user's config so the bar widget can read them
# without root. Parsed with sed, never sourced, and validated so a crafted
# value cannot inject extra hostapd directives.
HSUSER="${SUDO_USER:-@USER@}"
HSCONF="/home/$HSUSER/.config/omarchy-hotspot/config"
[ -r "$HSCONF" ] || die "missing $HSCONF"
SSID=$(sed -n 's/^SSID=//p' "$HSCONF" | head -1)
PASS=$(sed -n 's/^PASS=//p' "$HSCONF" | head -1)
[ -n "$SSID" ] || die "SSID is not set in $HSCONF"

# 802.11 permits any bytes in an SSID, so only control characters are refused
# here: this config is line-based and a newline would end the value early.
case "$SSID" in
  *[[:cntrl:]]*) die "SSID contains control characters" ;;
esac
if [ "${#SSID}" -gt 32 ]; then die "SSID must be at most 32 bytes"; fi

# Escape a value for a sed *replacement*: backslash first, then the delimiter
# and '&'. Without this an SSID such as "a&b/c" corrupts hostapd.conf.
sed_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[/&]/\\&/g'; }
printf '%s' "$PASS" | grep -qE '^[!-~]{8,63}$' \
  || die "PASS must be 8-63 printable non-space characters"

sed -e "s/^interface=.*/interface=$APVIF/" \
    -e "s/^channel=.*/channel=$CHANNEL/" \
    -e "s/^ht_capab=.*/ht_capab=$HT/" \
    -e "s/^ssid=.*/ssid=$(sed_esc "$SSID")/" \
    -e "s/^wpa_passphrase=.*/wpa_passphrase=$(sed_esc "$PASS")/" \
    "$HERE/hostapd.conf" > "$CONF"
if [ -z "$HT" ]; then sed -i '/^ht_capab=$/d' "$CONF"; fi
chmod 600 "$CONF"
info "ssid='$SSID' pass=<hidden> channel=$CHANNEL ht='${HT:-20MHz}'"

# ------------------------------------------------------- 4. create the vif
# Create it as MANAGED: hostapd's nl80211 driver performs the mode switch to AP
# itself, and needs to be the one that does it.
echo "[4/8] creating $APVIF on the $UPLINK phy"

# Kill a leaked hostapd BEFORE touching the vif.
#
# This was the actual cause of the "nl80211: Could not configure driver mode" /
# "Match already configured" failures: an orphaned hostapd from an earlier run
# (whose pidfile had been deleted before it was killed) still owned ap0, kept it
# in AP mode and held its AUTH frames registered. Every fresh attempt then got
# EALREADY on both set_mode and register_frame - which looks identical to a
# driver that refuses AP+STA. It does not; the process simply was never reaped.
if pgrep -f 'hostapd -P /run/hotspot-hostapd\.pid' >/dev/null 2>&1; then
  pkill -f 'hostapd -P /run/hotspot-hostapd\.pid' 2>/dev/null
  sleep 1
  pkill -9 -f 'hostapd -P /run/hotspot-hostapd\.pid' 2>/dev/null
  info "killed a leaked hostapd from a previous run"
fi
if iw dev | grep -q "Interface $APVIF"; then
  ip link set "$APVIF" down 2>/dev/null || true
  iw dev "$APVIF" del 2>/dev/null || true
  sleep 1
  info "removed leftover $APVIF"
fi
if iw dev "$UPLINK" interface add "$APVIF" type managed 2>/dev/null; then
  info "$APVIF created as managed (hostapd will switch it to AP)"
else
  iw dev "$UPLINK" interface add "$APVIF" type __ap 2>/dev/null \
    || die "phy refused a concurrent vif - uplink untouched"
  info "$APVIF created as AP (managed type was refused by the driver)"
fi
ROLLBACK=1

APTYPE=$(iw dev "$APVIF" info | sed -n 's/^[[:space:]]*type //p')
info "kernel reports $APVIF type=$APTYPE"
case "$APTYPE" in
  managed|AP) : ;;
  *) die "$APVIF came up as '$APTYPE' - unusable for an AP" ;;
esac

# Hand the vif over from NM before hostapd touches it.
nmcli device set "$APVIF" managed no >/dev/null 2>&1 && info "NM released $APVIF"

# --------------------------------------------------------- 5. start hostapd
# NOT daemonised with -B: that forks the error reporting away from us. Running it
# as a plain child means every early failure lands in $LOG where we can show it.
echo "[5/8] starting hostapd (full output -> $LOG)"

attempt_hostapd() {
  : > "$LOG"
  hostapd -P /run/hotspot-hostapd.pid "$CONF" >>"$LOG" 2>&1 &
  HAPD=$!
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    grep -q 'AP-ENABLED' "$LOG" && return 0
    kill -0 "$HAPD" 2>/dev/null || return 1
  done
  kill "$HAPD" 2>/dev/null; wait "$HAPD" 2>/dev/null
  return 1
}

if ! attempt_hostapd; then
  echo "  !! attempt 1 (HT40) failed; resetting $APVIF and retrying as 20MHz" >&2
  sed -i '/^ht_capab=/d' "$CONF"
  # A failed hostapd attempt can leave the vif in AP mode. Recreating it as
  # managed guarantees the next nl80211_set_mode succeeds instead of returning
  # -EALREADY. Deleting ap0 never touches the uplink vif.
  iw dev "$APVIF" del 2>/dev/null
  sleep 1
  iw dev "$UPLINK" interface add "$APVIF" type managed 2>/dev/null \
    || iw dev "$UPLINK" interface add "$APVIF" type __ap 2>/dev/null
  nmcli device set "$APVIF" managed no >/dev/null 2>&1
  if ! attempt_hostapd; then
    echo "===== hostapd output =====" >&2
    cat "$LOG" >&2
    echo "===== end =====" >&2
    die "hostapd never reached AP-ENABLED on $APVIF"
  fi
fi

if ! iw dev "$APVIF" info | grep -qE '^[[:space:]]*type AP'; then
  cat "$LOG" >&2
  die "hostapd said AP-ENABLED but $APVIF is not type AP"
fi
info "$APVIF is AP, channel $CHANNEL, beaconing (pid $HAPD)"

# ======================= 6. THE GATE: uplink must be untouched ==============
echo "[6/8] VERIFYING THE UPLINK SURVIVED"
AFTER=$(snapshot)
if [ "$BEFORE" != "$AFTER" ]; then
  echo "!! before: $BEFORE" >&2
  echo "!! after : $AFTER" >&2
  die "the AP disturbed $UPLINK"
fi
# Starting an AP on the same phy renegotiates the channel context, so the
# uplink can blink for a second or two. One ping is a sample, not a check:
# retry before declaring the uplink dead.
UP_OK=0
for _try in 1 2 3 4 5 6; do
  if timeout 6 ping -c1 -W2 -I "$UPLINK" 1.1.1.1 >/dev/null 2>&1; then
    UP_OK=1
    break
  fi
  sleep 2
done
[ "$UP_OK" -eq 1 ] || die "uplink stopped passing traffic (6 attempts)"
# Re-check identity after the retries: an addressing change could have landed
# late, and that is exactly what this gate exists to catch.
if [ "$BEFORE" != "$(snapshot)" ]; then
  die "uplink changed during verification"
fi
info "uplink intact and still reaching the internet"
# ===========================================================================

# ----------------------------------------------------- 7. addressing + DHCP
echo "[7/8] addressing $APVIF and starting DHCP/DNS"
ip addr add "$APIP/24" dev "$APVIF"

# Discover the real path MTU instead of assuming 1500. On this uplink it is 1492
# (PPPoE-style overhead); telling clients 1500 made every full-size segment die
# upstream, which looks exactly like "browsing works, downloads hang".
PATH_MTU=1500
PING_MODE=do   # "don't fragment": quoting it keeps linters from reading it as a shell keyword
for _sz in 1472 1464 1450 1422 1400 1372 1300 1240; do
  if ping -c1 -W2 -M "$PING_MODE" -s "$_sz" 1.1.1.1 >/dev/null 2>&1; then
    PATH_MTU=$((_sz + 28))
    break
  fi
done
MSS=$((PATH_MTU - 40))
info "path MTU ${PATH_MTU}, clamping MSS to ${MSS}"

ip link set "$APVIF" mtu "$PATH_MTU"
ip link set "$APVIF" up
sysctl -q -w net.ipv4.ip_forward=1 >/dev/null

dnsmasq --conf-file="$HERE/dnsmasq.conf" --pid-file=/run/hotspot-dnsmasq.pid \
        --log-facility=/var/log/hotspot-dnsmasq.log \
        --dhcp-option=26,"$PATH_MTU" \
  || { tail -n 20 /var/log/hotspot-dnsmasq.log 2>/dev/null >&2; die "dnsmasq failed"; }
info "DHCP 10.42.0.10-200, gateway+DNS $APIP, mtu $PATH_MTU"

# ---------------------------------------------------------------- 8. NAT
echo "[8/8] installing NAT + firewall permission"
nft delete table ip hotspot 2>/dev/null
# Render the discovered MSS into the ruleset (nat.nft carries a placeholder).
sed "s/maxseg size set [0-9][0-9]*/maxseg size set $MSS/" "$HERE/nat.nft" > /run/hotspot-nat.nft
nft -f /run/hotspot-nat.nft || die "nft rules failed"

# Docker installs a FORWARD base chain with policy DROP at priority filter, and
# a drop in an earlier base chain is final - our accept at filter+5 never gets a
# say. Docker is often inactive here but its chains persist in the kernel. Add
# the two accepts at the TOP of that chain, idempotently.
if nft list chain ip filter FORWARD >/dev/null 2>&1; then
  nft list chain ip filter FORWARD | grep -q 'iifname "ap0" oifname "wlp2s0"' \
    || nft insert rule ip filter FORWARD iifname "$APVIF" oifname "$UPLINK" accept
  nft list chain ip filter FORWARD | grep -q 'ct state established,related accept' \
    || nft insert rule ip filter FORWARD iifname "$UPLINK" oifname "$APVIF" ct state established,related accept
  info "docker FORWARD chain patched for $APVIF"
fi

if systemctl is-active --quiet ufw; then
  ufw route allow in on "$APVIF" out on "$UPLINK" >/dev/null
  ufw allow in on "$APVIF" to "$APIP" port 53 proto udp >/dev/null
  # DHCPDISCOVER is broadcast to 255.255.255.255, so this rule must NOT
  # carry a destination address or it never matches.
  ufw allow in on "$APVIF" to any port 67 proto udp >/dev/null
  # SECURITY DEFAULT: a hotspot hands out internet, not a login prompt.
  # SSH is opened to clients only when the owner explicitly asks for it, by
  # creating ~/.config/omarchy-hotspot/allow-ssh (phone-tunnel needs this).
  if [ -e "/home/$HSUSER/.config/omarchy-hotspot/allow-ssh" ]; then
    ufw allow in on "$APVIF" to "$APIP" port 22 proto tcp >/dev/null
    info "ufw: SSH:22 exposed to clients (allow-ssh present)"
  else
    info "ufw: client access limited to DNS + DHCP"
  fi
  info "ufw: forwarding $APVIF -> $UPLINK"
fi

ROLLBACK=0
trap - EXIT INT TERM

cat <<EOF

==========================================================================
 HOTSPOT UP - uplink $UPLINK ($UP_SSID) is STILL CONNECTED
--------------------------------------------------------------------------
 SSID      : omarchy-share      (channel $CHANNEL)
 Password  : see wpa_passphrase in $HERE/hostapd.conf
 Gateway   : $APIP     <- the "IP" clients use
 DNS       : $APIP
 NAT       : $NET -> $UPLINK (transparent, no proxy, no port forwarding)

 Tear down : sudo $HERE/teardown.sh
==========================================================================
EOF
