#!/usr/bin/env bash
# =============================================================================
# Add a new WireGuard peer (device) to this VPN server.
#
# Usage:  sudo bash add-wireguard-peer.sh <device-name>
# Example: sudo bash add-wireguard-peer.sh laptop-windows
#          sudo bash add-wireguard-peer.sh pixel-9a
#
# Output:
#   /etc/wireguard/peers/<device-name>.conf   (import into WireGuard client)
#   If qrencode installed: prints QR code to terminal (scan with phone app)
# =============================================================================
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "Usage: sudo bash $0 <device-name>"
    exit 1
fi
if [[ ! "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: device name must contain only letters, numbers, - and _"
    exit 1
fi

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

WG_IFACE="wg0"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
WG_PORT=51820
WG_SUBNET="10.8.0"
PEERS_DIR="/etc/wireguard/peers"

[[ -f "$WG_CONF" ]] || { echo "ERROR: $WG_CONF not found. Run setup-wireguard-server.sh first."; exit 1; }

mkdir -p "$PEERS_DIR"
chmod 700 "$PEERS_DIR"

# Pick next free IP (skip .1 = server, check existing peers)
USED_IPS=$(grep -hE "^AllowedIPs" "$WG_CONF" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' | cut -d'/' -f1)
NEXT_IP=""
for i in $(seq 3 254); do
    CANDIDATE="${WG_SUBNET}.${i}"
    if ! echo "$USED_IPS" | grep -qx "$CANDIDATE"; then
        NEXT_IP="$CANDIDATE"
        break
    fi
done
[[ -n "$NEXT_IP" ]] || { echo "ERROR: no free IPs in subnet"; exit 1; }

# Detect public endpoint (reuse from server config, falls back to public IP lookup)
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || true)
[[ -n "$PUBLIC_IP" ]] || { echo "ERROR: could not detect public IP"; exit 1; }

SERVER_PUB=$(cat /etc/wireguard/server_public.key)

# Generate peer keys
umask 077
PEER_PRIV=$(wg genkey)
PEER_PUB=$(echo "$PEER_PRIV" | wg pubkey)

# Append peer to server config
cat >> "$WG_CONF" << EOF

[Peer]
# $NAME
PublicKey = ${PEER_PUB}
AllowedIPs = ${NEXT_IP}/32
EOF

# Apply live without dropping existing peers
wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")

# Write peer config
CLIENT_CONF="${PEERS_DIR}/${NAME}.conf"
cat > "$CLIENT_CONF" << EOF
[Interface]
# $NAME
Address = ${NEXT_IP}/24
PrivateKey = ${PEER_PRIV}
DNS = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

echo ""
echo "========================================================"
echo "  PEER ADDED: $NAME  (VPN IP: $NEXT_IP)"
echo "========================================================"
echo ""
echo "  Config file: $CLIENT_CONF"
echo ""

# QR code for mobile scan
if command -v qrencode &>/dev/null; then
    echo "  Scan this QR with the WireGuard mobile app:"
    echo ""
    qrencode -t ansiutf8 < "$CLIENT_CONF"
    echo ""
fi

echo "  ---- CONFIG TEXT (copy/paste for desktop clients) ----"
cat "$CLIENT_CONF"
echo "  -------------------------------------------------------"
echo ""
echo "  Verify from client after import:"
echo "    curl https://ifconfig.me     # should return $PUBLIC_IP"
echo ""
