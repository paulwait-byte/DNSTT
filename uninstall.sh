#!/usr/bin/env bash
#
# uninstall.sh — remove the dnstt server installed by install-server.sh.
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: please run as root (sudo)." >&2
  exit 1
fi

echo "==> Stopping and removing service..."
systemctl disable --now dnstt-server 2>/dev/null || true
rm -f /etc/systemd/system/dnstt-server.service
systemctl daemon-reload

echo "==> Removing files in /opt/dnstt (keeping keys backup)..."
if [[ -f /opt/dnstt/server.pub ]]; then
  cp /opt/dnstt/server.pub /root/dnstt-server.pub.bak 2>/dev/null || true
  cp /opt/dnstt/server.key /root/dnstt-server.key.bak 2>/dev/null || true
  echo "    key backup -> /root/dnstt-server.{pub,key}.bak"
fi
rm -rf /opt/dnstt

echo "==> Done. The SSH 'vpn' user (if created) was left in place."
echo "    Remove it manually with: userdel -r vpn"
