#!/usr/bin/env bash
# Remove everything install.sh added.
#
# Keeps your SSID/password and the plugin unless --purge is given, so a
# reinstall does not lose them.
set -uo pipefail
export LC_ALL=C

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ -n "${PKEXEC_UID:-}" ]; then
  USER_NAME="$(id -un "$PKEXEC_UID")"
elif [ -n "${SUDO_USER:-}" ]; then
  USER_NAME="$SUDO_USER"
else
  USER_NAME="${HS_USER:-$(logname 2>/dev/null || echo kouragita)}"
fi
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
APPDIR="$HOME_DIR/.local/share/omarchy-hotspot"
CFGDIR="$HOME_DIR/.config/omarchy-hotspot"
PLUGDIR="$HOME_DIR/.config/omarchy/plugins/kouragita.hotspot"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

echo "stopping and removing the hotspot"
systemctl stop omarchy-hotspot.service >/dev/null 2>&1
rm -f /etc/systemd/system/omarchy-hotspot.service
systemctl daemon-reload
echo "  unit removed"

rm -f /etc/NetworkManager/dispatcher.d/90-omarchy-hotspot
nmcli general reload conf >/dev/null 2>&1 || true
echo "  dispatcher removed"

rm -f /etc/polkit-1/rules.d/60-omarchy-hotspot.rules
systemctl restart polkit >/dev/null 2>&1 || true
echo "  polkit rule removed"

# Runtime nft rules vanish on reboot; drop the ones we own now.
for pat in 'iifname "ap0" oifname "wlp2s0"' 'iifname "wlp2s0" oifname "ap0"'; do
  while nft -a list chain ip filter FORWARD 2>/dev/null | grep -q "$pat"; do
    h=$(nft -a list chain ip filter FORWARD 2>/dev/null | grep "$pat" | head -1 \
        | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
    [ -n "${h:-}" ] || break
    nft delete rule ip filter FORWARD handle "$h" 2>/dev/null || break
  done
done
nft delete table ip hotspot >/dev/null 2>&1
echo "  runtime nft rules removed"

if [ "$PURGE" -eq 1 ]; then
  rm -rf "$CFGDIR" "$HOME_DIR/.cache/omarchy-hotspot" "$PLUGDIR"
  rm -f /etc/NetworkManager/conf.d/99-ap0-unmanaged.conf
  echo "  purged config, cache and plugin"
else
  echo "  kept $CFGDIR and $PLUGDIR"
fi

rm -rf "$APPDIR"
echo "  runtime scripts removed"

echo
echo "done. Restart the shell to drop the icon: omarchy restart shell"
