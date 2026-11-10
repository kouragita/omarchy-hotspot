#!/usr/bin/env bash
# Installer for the Omarchy mobile hotspot.
#
# Run as root (sudo or pkexec). Safe to re-run: every step is idempotent and an
# existing SSID/password is preserved.
#
# Layout it creates for the invoking user:
#
#   ~/.local/share/omarchy-hotspot/     runtime scripts + config templates
#   ~/.config/omarchy-hotspot/config    SSID + password (mode 600)
#   ~/.config/omarchy/plugins/kouragita.hotspot/   the bar widget
#   ~/.local/state/hotspot/enabled      intent flag (auto re-arm on reconnect)
#
#   /etc/systemd/system/omarchy-hotspot.service
#   /etc/NetworkManager/dispatcher.d/90-omarchy-hotspot
#   /etc/NetworkManager/conf.d/99-ap0-unmanaged.conf
#   /etc/polkit-1/rules.d/60-omarchy-hotspot.rules
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Who is this being installed for?
if [ -n "${PKEXEC_UID:-}" ]; then
  USER_NAME="$(id -un "$PKEXEC_UID")"
elif [ -n "${SUDO_USER:-}" ]; then
  USER_NAME="$SUDO_USER"
else
  USER_NAME="${HS_USER:-$(logname 2>/dev/null || echo kouragita)}"
fi
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || { echo "cannot resolve home for $USER_NAME" >&2; exit 1; }

APPDIR="$HOME_DIR/.local/share/omarchy-hotspot"
CFGDIR="$HOME_DIR/.config/omarchy-hotspot"
PLUGDIR="$HOME_DIR/.config/omarchy/plugins/kouragita.hotspot"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0   (or: pkexec $0)" >&2; exit 1; }

say() { echo "  $*"; }

echo "[1/7] packages"
for p in hostapd dnsmasq qrencode; do
  if pacman -Q "$p" >/dev/null 2>&1; then say "$p present"
  else pacman -S --needed --noconfirm "$p" >/dev/null && say "$p installed"; fi
done

echo "[2/7] runtime scripts -> $APPDIR"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$APPDIR"
for f in apply.sh teardown.sh hotspot-clients hotspot-info hotspot-qr phone-tunnel; do
  sed -e "s|@APPDIR@|$APPDIR|g" -e "s|@USER@|$USER_NAME|g" "$HERE/runtime/$f" \
    > "$APPDIR/$f"
  chown "$USER_NAME:$USER_NAME" "$APPDIR/$f"
  chmod 755 "$APPDIR/$f"
done
for f in hostapd.conf dnsmasq.conf nat.nft; do
  install -o "$USER_NAME" -g "$USER_NAME" -m 644 "$HERE/runtime/$f" "$APPDIR/$f"
done
say "installed 6 scripts + 3 templates"

echo "[3/7] config -> $CFGDIR/config"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$CFGDIR"
if [ -s "$CFGDIR/config" ]; then
  say "keeping existing config"
else
  PW="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 16)"
  printf 'SSID=omarchy-share\nPASS=%s\n' "$PW" > "$CFGDIR/config"
  say "created config (password: $PW)"
fi
# Enforced every run: this file holds the Wi-Fi key.
chown "$USER_NAME:$USER_NAME" "$CFGDIR/config"
chmod 600 "$CFGDIR/config"

echo "[4/7] plugin -> $PLUGDIR"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$PLUGDIR"
for f in manifest.json BarWidget.qml Panel.qml; do
  install -o "$USER_NAME" -g "$USER_NAME" -m 644 "$HERE/plugin/$f" "$PLUGDIR/$f"
done
say "bar widget installed"

echo "[5/7] systemd unit"
sed -e "s|@APPDIR@|$APPDIR|g" "$HERE/system/omarchy-hotspot.service" \
  > /etc/systemd/system/omarchy-hotspot.service
chmod 644 /etc/systemd/system/omarchy-hotspot.service
systemctl daemon-reload
say "unit installed"

echo "[6/7] NetworkManager: dispatcher + leave the AP vif alone"
sed -e "s|@USER@|$USER_NAME|g" "$HERE/system/90-omarchy-hotspot" \
  > /etc/NetworkManager/dispatcher.d/90-omarchy-hotspot
chmod 755 /etc/NetworkManager/dispatcher.d/90-omarchy-hotspot
install -m 644 "$HERE/system/99-ap0-unmanaged.conf" /etc/NetworkManager/conf.d/99-ap0-unmanaged.conf
nmcli general reload conf >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1 || true
say "dispatcher installed, NM reloaded"

echo "[7/7] polkit rule (one unit, one user)"
sed -e "s|@USER@|$USER_NAME|g" "$HERE/system/60-omarchy-hotspot.rules" \
  > /etc/polkit-1/rules.d/60-omarchy-hotspot.rules
chmod 644 /etc/polkit-1/rules.d/60-omarchy-hotspot.rules
systemctl restart polkit >/dev/null 2>&1 || true
say "polkit rule installed"

# Put the widget on the bar next to the network icon.
if command -v omarchy >/dev/null 2>&1; then
  if runuser -u "$USER_NAME" -- omarchy bar put kouragita.hotspot --before omarchy.network \
       >/dev/null 2>&1; then
    say "bar layout ensured"
  else
    say "bar already configured"
  fi
fi

cat <<EOF

Done. Start it from the hotspot icon in the bar, or:
  systemctl start omarchy-hotspot.service

  SSID / password : $CFGDIR/config   (mode 600)
  Re-arms itself  : after every reconnect while ~/.local/state/hotspot/enabled exists
  SSH to clients  : OFF by default. Create $CFGDIR/allow-ssh to enable it.
EOF
