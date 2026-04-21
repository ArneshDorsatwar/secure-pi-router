#!/usr/bin/env bash
# =============================================================================
# WireGuard VPN Server Setup — Oracle Cloud / any Linux VPS with a public IP
#
# Phone-Bridge VPN Router — server-side component (Mode A)
#   Pi (client)  --[wg0]-->  this server  -->  Internet
#
# What this does:
#   1. Installs WireGuard
#   2. Enables IP forwarding
#   3. Generates server + Pi client keypairs
#   4. Writes /etc/wireguard/wg0.conf (server)
#   5. Writes /etc/wireguard/pi-client.conf (Pi's config — copy to the Pi)
#   6. Opens UDP 51820 in the local firewall and sets up NAT
#   7. Enables wg-quick@wg0 to start on boot
#
# Usage (on the VPS):  sudo bash setup-wireguard-server.sh
#
# Prereq:
#   In the Oracle Cloud console, add an Ingress Rule to the VCN's Security List:
#     Source: 0.0.0.0/0   Protocol: UDP   Port: 51820
# =============================================================================
set -euo pipefail

WG_PORT=51820
WG_SUBNET="10.8.0"
SERVER_IP="${WG_SUBNET}.1"
PI_IP="${WG_SUBNET}.2"
WG_IFACE="wg0"

log()  { echo "[*] $1"; }
ok()   { echo "[OK] $1"; }
warn() { echo "[WARN] $1"; }
err()  { echo "[ERROR] $1"; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root (sudo)."

# --- 1. Detect public IP and outbound interface ---
log "Detecting public IP"
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || true)
[[ -n "$PUBLIC_IP" ]] || err "Could not detect public IP. Set it manually: PUBLIC_IP=x.x.x.x sudo -E bash $0"
ok "Public IP: $PUBLIC_IP"

OUT_IFACE=$(ip route show default | awk '{print $5; exit}')
[[ -n "$OUT_IFACE" ]] || err "Could not detect default outbound interface"
ok "Outbound interface: $OUT_IFACE"

# --- 2. Install packages ---
log "Installing WireGuard + iptables"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables curl > /dev/null
ok "Packages installed"

# --- 3. Enable IP forwarding ---
log "Enabling IP forwarding"
cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null
ok "IP forwarding enabled"

# --- 4. Generate keys (idempotent — only regenerate if missing) ---
log "Generating WireGuard keys"
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077

if [[ ! -f server_private.key ]]; then
    wg genkey | tee server_private.key | wg pubkey > server_public.key
fi
if [[ ! -f pi_private.key ]]; then
    wg genkey | tee pi_private.key | wg pubkey > pi_public.key
fi

SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)
PI_PRIV=$(cat pi_private.key)
PI_PUB=$(cat pi_public.key)
ok "Keys ready"

# --- 5. Server config ---
log "Writing /etc/wireguard/${WG_IFACE}.conf"
cat > /etc/wireguard/${WG_IFACE}.conf << EOF
[Interface]
Address = ${SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

# Insert at TOP of FORWARD (-I) — Oracle/RHEL Ubuntu images have a default REJECT
# rule near the top that drops forwarded traffic if we only append (-A).
PostUp = iptables -I FORWARD 1 -i ${WG_IFACE} -j ACCEPT; iptables -I FORWARD 2 -o ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${OUT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${OUT_IFACE} -j MASQUERADE

[Peer]
# Raspberry Pi
PublicKey = ${PI_PUB}
AllowedIPs = ${PI_IP}/32
EOF
chmod 600 /etc/wireguard/${WG_IFACE}.conf
ok "Server config written"

# --- 6. Pi client config (copy this to the Pi) ---
log "Writing Pi client config to /etc/wireguard/pi-client.conf"
cat > /etc/wireguard/pi-client.conf << EOF
[Interface]
# Pi's VPN IP
Address = ${PI_IP}/24
PrivateKey = ${PI_PRIV}
DNS = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 644 /etc/wireguard/pi-client.conf
ok "Pi client config ready"

# --- 7. Firewall — allow WireGuard port + accept forwarded/tunnel traffic ---
log "Opening UDP ${WG_PORT} in local firewall"
iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -i ${WG_IFACE} -j ACCEPT 2>/dev/null || true
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ok "Firewall rule added"

# --- 8. Enable and start ---
log "Enabling wg-quick@${WG_IFACE}"
systemctl enable wg-quick@${WG_IFACE} > /dev/null 2>&1 || true
systemctl restart wg-quick@${WG_IFACE} || err "Failed to start WireGuard — check journalctl -u wg-quick@${WG_IFACE}"
sleep 1
wg show ${WG_IFACE} > /dev/null && ok "WireGuard server is up"

# --- 9. Summary ---
echo ""
echo "============================================="
echo "  WIREGUARD SERVER READY"
echo "============================================="
echo ""
echo "  Public endpoint:  ${PUBLIC_IP}:${WG_PORT}"
echo "  VPN subnet:       ${WG_SUBNET}.0/24"
echo "  Server VPN IP:    ${SERVER_IP}"
echo "  Pi VPN IP:        ${PI_IP}"
echo ""
echo "  REMINDER: confirm Oracle Cloud VCN Security List has:"
echo "    Ingress: Source 0.0.0.0/0  Protocol UDP  Port ${WG_PORT}"
echo ""
echo "  ---- COPY THIS TO THE PI AT /etc/wireguard/wg0.conf ----"
echo ""
cat /etc/wireguard/pi-client.conf
echo ""
echo "  --------------------------------------------------------"
echo ""
echo "  One-line way to transfer it from your laptop:"
echo "    scp ubuntu@${PUBLIC_IP}:/etc/wireguard/pi-client.conf ."
echo "    scp pi-client.conf arnesh@<PI_IP>:/tmp/wg0.conf"
echo "    ssh arnesh@<PI_IP> 'sudo mv /tmp/wg0.conf /etc/wireguard/wg0.conf && sudo chmod 600 /etc/wireguard/wg0.conf'"
echo ""
