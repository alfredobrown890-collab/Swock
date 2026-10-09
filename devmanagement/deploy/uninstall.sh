#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run the uninstaller with sudo.' >&2; exit 1; }
[[ $# -le 1 ]] || { echo 'Usage: sudo bash devmanagement/deploy/uninstall.sh [--purge-data]' >&2; exit 2; }
purge_data=0
if [[ ${1:-} == --purge-data ]]; then
  purge_data=1
elif [[ $# -ne 0 ]]; then
  echo 'Usage: sudo bash devmanagement/deploy/uninstall.sh [--purge-data]' >&2
  exit 2
fi

if (( purge_data )); then
  echo 'This removes Swock services, panel data, VPN accounts, client keys, and server keys.'
else
  echo 'This removes Swock services and binaries. Account data, configuration, and keys will be preserved.'
fi
read -r -p "Type 'uninstall' to continue: " confirmation
[[ $confirmation == uninstall ]] || { echo 'Uninstall cancelled.'; exit 1; }

systemctl disable --now swock-devmanagement.service swock-server.service swock-ssh-manager.service 2>/dev/null || true
rm -f \
  /etc/systemd/system/swock-devmanagement.service \
  /etc/systemd/system/swock-server.service \
  /etc/systemd/system/swock-ssh-manager.service \
  /etc/nginx/streams-enabled/swock.conf \
  /etc/nginx/sites-enabled/swock-devmanagement \
  /etc/nginx/sites-available/swock-devmanagement \
  /etc/letsencrypt/renewal-hooks/deploy/50-swock-server \
  /usr/local/sbin/swock-network-setup \
  /usr/local/sbin/swock-ssh-account \
  /usr/local/lib/swock-ssh-manager.js \
  /usr/local/bin/swock-server \
  /usr/local/bin/swock-keygen \
  /etc/sysctl.d/99-swock.conf
rm -rf /opt/swock-devmanagement
rmdir /etc/nginx/streams-enabled 2>/dev/null || true
if [[ -f /etc/nginx/nginx.conf ]]; then
  sed -i '/# BEGIN SWOCK STREAM ROUTING/,/# END SWOCK STREAM ROUTING/d' /etc/nginx/nginx.conf
fi
rmdir /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null || true

if command -v nft >/dev/null 2>&1; then
  nft delete table ip swock 2>/dev/null || true
fi
if command -v ip >/dev/null 2>&1 && ip link show swock0 >/dev/null 2>&1; then
  ip link delete swock0 2>/dev/null || true
fi

if (( purge_data )); then
  rm -rf /var/lib/swock-devmanagement /var/lib/swock
  rm -f /etc/swock-devmanagement.env /etc/swock-server.private
  userdel swock-panel 2>/dev/null || true
  groupdel swock 2>/dev/null || true
fi

systemctl daemon-reload
if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
  systemctl reload nginx 2>/dev/null || true
fi

echo 'Swock panel and tunnel services have been uninstalled.'
if (( purge_data )); then
  echo 'Swock account data and signing keys were permanently removed.'
else
  echo 'Preserved data remains in /var/lib/swock, /var/lib/swock-devmanagement, and /etc/swock-*.'
  echo 'Back it up before running the uninstaller with --purge-data.'
fi
echo 'Existing Linux SSH accounts are left in place.'
