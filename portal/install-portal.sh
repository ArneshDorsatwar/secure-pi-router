#!/usr/bin/env bash
# Install the WireGuard invite portal on the VPS.
# Usage:  sudo bash install-portal.sh <admin_password>
set -euo pipefail

ADMIN_PASS="${1:-}"
[[ -n "$ADMIN_PASS" && ${#ADMIN_PASS} -ge 8 ]] || {
    echo "Usage: sudo bash install-portal.sh <admin_password>"
    echo "       Admin password must be >= 8 chars"
    exit 1
}
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

PORT=8443

echo "[*] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq qrencode python3 > /dev/null

echo "[*] Copying portal.py to /opt/wg-portal/"
mkdir -p /opt/wg-portal
cp "$(dirname "$0")/portal.py" /opt/wg-portal/
chmod 755 /opt/wg-portal/portal.py

echo "[*] Writing systemd unit"
cat > /etc/systemd/system/wg-portal.service << EOF
[Unit]
Description=WireGuard invite portal
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
Environment=WG_ADMIN_PASS=${ADMIN_PASS}
Environment=WG_PORTAL_PORT=${PORT}
ExecStart=/usr/bin/python3 /opt/wg-portal/portal.py
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/wg-portal.service

echo "[*] Opening port ${PORT} on local iptables"
iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo "[*] Starting wg-portal service"
systemctl daemon-reload
systemctl enable --now wg-portal.service

sleep 2
if systemctl is-active --quiet wg-portal.service; then
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || echo "<VPS_IP>")
    echo ""
    echo "=============================================="
    echo "  WG PORTAL INSTALLED"
    echo "=============================================="
    echo ""
    echo "  Admin URL:    http://${PUBLIC_IP}:${PORT}/admin"
    echo "  Username:     (any — leave blank)"
    echo "  Password:     (the one you just set)"
    echo ""
    echo "  REMINDER: open TCP ${PORT} ingress in Oracle Cloud VCN Security List:"
    echo "    Source 0.0.0.0/0  Protocol TCP  Port ${PORT}"
    echo ""
else
    echo "[ERROR] wg-portal.service failed. Logs:"
    journalctl -u wg-portal.service -n 30 --no-pager
    exit 1
fi
