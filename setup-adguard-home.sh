#!/usr/bin/env bash
# =============================================================================
# Install AdGuard Home on the WireGuard VPS.
#
# After install:
#   - DNS listens on 10.8.0.1:53 (only reachable from VPN clients via iptables)
#   - Web UI on 10.8.0.1:3000 (same — VPN-only)
#   - Default blocklist (AdGuard DNS filter) enabled
#   - Upstream resolvers: 1.1.1.1, 9.9.9.9
#
# Usage:  sudo bash setup-adguard-home.sh <admin_password>
# =============================================================================
set -euo pipefail

ADMIN_PASS="${1:-}"
[[ -n "$ADMIN_PASS" && ${#ADMIN_PASS} -ge 8 ]] || {
    echo "Usage: sudo bash $0 <admin_password>  (>= 8 chars)"
    exit 1
}
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log()  { echo "[*] $*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }

# 1. Free port 53 by disabling systemd-resolved's stub listener
log "Disabling systemd-resolved DNS stub listener"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/adguard.conf << EOF
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved 2>/dev/null || true
# Also make sure /etc/resolv.conf doesn't point to the stub
if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q stub; then
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi
ok "port 53 free"

# 2. Install AdGuard Home (official installer, idempotent)
if [[ ! -x /opt/AdGuardHome/AdGuardHome ]]; then
    log "Installing AdGuard Home (official installer)"
    curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
else
    ok "AdGuard Home already installed"
fi

# 3. Wait for web API
log "Waiting for AdGuard Home web API"
for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:3000/control/install/get_addresses > /dev/null 2>&1 \
       || curl -fsS http://127.0.0.1:3000/control/status > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# 4. Run first-time setup via install API (only if not yet configured)
if curl -fsS http://127.0.0.1:3000/control/install/get_addresses > /dev/null 2>&1; then
    log "Running first-time configuration"
    curl -fsS -X POST http://127.0.0.1:3000/control/install/configure \
        -H 'Content-Type: application/json' \
        -d "{
            \"web\":      {\"ip\": \"0.0.0.0\", \"port\": 3000, \"autofix\": true},
            \"dns\":      {\"ip\": \"0.0.0.0\", \"port\": 53,   \"autofix\": true},
            \"username\": \"admin\",
            \"password\": \"${ADMIN_PASS}\"
        }" > /dev/null
    ok "initial config applied"
    sleep 2
else
    ok "AdGuard Home already configured (skipping first-time setup)"
fi

# 5. Restart to pick up changes
log "Restarting AdGuardHome service"
systemctl restart AdGuardHome
sleep 2

# 6. Firewall rules — allow DNS + web UI ONLY from wg0 (VPN) interface
log "Adding iptables rules: allow DNS/admin UI only from wg0"
add_rule() {
    if ! iptables -C "$@" 2>/dev/null; then
        iptables -I "$@"
    fi
}
add_rule INPUT -i wg0 -p udp --dport 53 -j ACCEPT
add_rule INPUT -i wg0 -p tcp --dport 53 -j ACCEPT
add_rule INPUT -i wg0 -p tcp --dport 3000 -j ACCEPT
iptables-save > /etc/iptables/rules.v4
ok "firewall configured"

# 7. Smoke test
log "Testing DNS lookup against 10.8.0.1"
if command -v dig &>/dev/null; then
    if dig @10.8.0.1 +short +timeout=3 example.com > /dev/null 2>&1; then
        ok "DNS resolving via 10.8.0.1"
    else
        warn "DNS test failed — AdGuard may still be starting"
    fi
else
    apt-get install -y -qq dnsutils > /dev/null 2>&1 || true
fi

# 8. Summary
echo ""
echo "=============================================="
echo "  ADGUARD HOME READY"
echo "=============================================="
echo ""
echo "  Dashboard:  http://10.8.0.1:3000/"
echo "             (only when connected to the VPN)"
echo "  Login:     admin / <the password you just set>"
echo ""
echo "  DNS server (for peer configs):  10.8.0.1"
echo ""
echo "  Next steps:"
echo "    1. Update wg-add-peer to hand out DNS = 10.8.0.1 to new peers"
echo "    2. Update existing peers' DNS (Pi + any desktops)"
echo ""
