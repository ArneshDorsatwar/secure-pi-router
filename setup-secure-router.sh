#!/usr/bin/env bash
# =============================================================================
# Portable Secure Router Setup Script
# Turns a Raspberry Pi into a secure portable router with:
#   - Encrypted WPA2 Wi-Fi hotspot (wlan0)
#   - Phone hotspot uplink (wlan1) + Bluetooth tethering fallback (bnep0)
#   - Firewall with kill switch (no traffic leaks)
#   - Multi-uplink failover (fully wireless — no cables needed)
#
# Usage: sudo bash setup-secure-router.sh
# =============================================================================
set -euo pipefail

# =============================================================================
# USER-CONFIGURABLE VARIABLES — Edit these before running
# =============================================================================

# --- Network Interfaces ---
IF_AP="wlan0"           # Built-in Wi-Fi — used for the hotspot
IF_UPLINK="wlan1"       # USB Wi-Fi adapter — connects to phone hotspot
IF_BT="bnep0"           # Bluetooth PAN — wireless cellular fallback

# --- Access Point Settings ---
AP_SSID="SecurePiRouter"
AP_PASS="changeme123"   # Minimum 8 characters
AP_CHANNEL=6
AP_COUNTRY="US"

# --- AP Subnet ---
AP_SUBNET="192.168.4"
AP_GW="${AP_SUBNET}.1"
AP_DHCP_START="${AP_SUBNET}.50"
AP_DHCP_END="${AP_SUBNET}.150"
AP_NETMASK="255.255.255.0"

# --- Phone Hotspot Credentials (for wlan1 uplink) ---
UPLINK_SSID="MyPhoneHotspot"
UPLINK_PASS="phonehotspotpassword"

# --- Bluetooth (for bnep0 fallback) ---
BT_PHONE_MAC=""         # Your phone's Bluetooth MAC address (e.g. AA:BB:CC:DD:EE:FF)
                        # Find it: Settings > About Phone > Bluetooth Address
                        # Or leave blank and run bluetooth-tether.sh to pair

# --- DNS ---
DNS_UPSTREAM="1.1.1.1"
DNS_UPSTREAM2="9.9.9.9"

# --- Routing Table IDs ---
UPLINK_TABLE=100
BT_TABLE=200
UPLINK_METRIC=100       # Lower = preferred
BT_METRIC=200

# =============================================================================
# SENTINEL — used to detect re-runs and avoid duplicate config entries
# =============================================================================
SENTINEL="# --- SECURE-ROUTER-MANAGED ---"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log_step() {
    echo ""
    echo "===> $1"
}

log_ok() {
    echo "     [OK] $1"
}

log_warn() {
    echo "     [WARN] $1"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" && ! -f "${file}.orig.bak" ]]; then
        cp "$file" "${file}.orig.bak"
        log_ok "Backed up $file -> ${file}.orig.bak"
    fi
}

# =============================================================================
# 1. PREREQUISITE CHECKS
# =============================================================================
check_prereqs() {
    log_step "Checking prerequisites"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)."
        exit 1
    fi
    log_ok "Running as root"

    if [[ ! -f /etc/os-release ]]; then
        echo "ERROR: Cannot detect OS. Expected Raspberry Pi OS."
        exit 1
    fi
    log_ok "OS detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"

    if ip link show "$IF_AP" &>/dev/null; then
        log_ok "AP interface $IF_AP found"
    else
        echo "ERROR: AP interface $IF_AP not found."
        exit 1
    fi

    if ! ip link show "$IF_UPLINK" &>/dev/null; then
        log_warn "Uplink interface $IF_UPLINK not found — plug in USB Wi-Fi adapter before reboot"
    fi

    # bnep0 won't exist until Bluetooth tethering is active — that's normal
    log_ok "Bluetooth fallback ($IF_BT) will activate when paired with phone"

    if [[ ${#AP_PASS} -lt 8 ]]; then
        echo "ERROR: AP_PASS must be at least 8 characters."
        exit 1
    fi
}

# =============================================================================
# 2. INSTALL PACKAGES
# =============================================================================
install_packages() {
    log_step "Installing packages"
    apt-get update -qq
    apt-get install -y -qq hostapd dnsmasq iptables-persistent bluez bt-pan 2>/dev/null > /dev/null || \
    apt-get install -y -qq hostapd dnsmasq iptables-persistent bluez > /dev/null
    log_ok "hostapd, dnsmasq, iptables-persistent, bluez installed"

    # Stop services during configuration
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
}

# =============================================================================
# 3. CONFIGURE STATIC IP — on AP interface via NetworkManager
# =============================================================================
configure_static_ip() {
    log_step "Configuring static IP for $IF_AP"

    # Remove any existing NM connection for the AP interface
    nmcli connection delete "secure-router-ap" 2>/dev/null || true

    # Tell NetworkManager not to manage wlan0 (hostapd will manage it)
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/secure-router.conf << EOF
$SENTINEL
[keyfile]
unmanaged-devices=interface-name:$IF_AP
EOF

    # Set the static IP directly
    ip addr flush dev "$IF_AP" 2>/dev/null || true
    ip addr add "${AP_GW}/24" dev "$IF_AP" 2>/dev/null || true
    ip link set "$IF_AP" up

    log_ok "Static IP ${AP_GW}/24 set on $IF_AP (unmanaged by NM)"
}

# =============================================================================
# 4. CONFIGURE HOSTAPD — Wi-Fi access point
# =============================================================================
configure_hostapd() {
    log_step "Configuring hostapd (Access Point)"

    cat > /etc/hostapd/hostapd.conf << EOF
$SENTINEL
interface=$IF_AP
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
country_code=$AP_COUNTRY
wmm_enabled=0
macaddr_acl=0
auth_algs=1
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211n=1
EOF

    # Point hostapd to config
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true

    log_ok "AP configured: SSID=$AP_SSID, Channel=$AP_CHANNEL, WPA2"
}

# =============================================================================
# 5. CONFIGURE DNSMASQ — DHCP + DNS for AP clients
# =============================================================================
configure_dnsmasq() {
    log_step "Configuring dnsmasq (DHCP + DNS)"

    backup_file /etc/dnsmasq.conf

    cat > /etc/dnsmasq.conf << EOF
$SENTINEL
# Listen only on the AP interface
interface=$IF_AP
bind-interfaces
listen-address=$AP_GW

# DHCP range for connected devices
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,$AP_NETMASK,24h

# Upstream DNS servers
server=$DNS_UPSTREAM
server=$DNS_UPSTREAM2

# Don't read /etc/resolv.conf
no-resolv

# Security
bogus-priv
domain-needed
EOF

    log_ok "DHCP range: $AP_DHCP_START - $AP_DHCP_END"
    log_ok "DNS: $DNS_UPSTREAM, $DNS_UPSTREAM2"
}

# =============================================================================
# 6. CONFIGURE UPLINK — connect to phone hotspot via NetworkManager
# =============================================================================
configure_uplink() {
    log_step "Configuring Wi-Fi uplink on $IF_UPLINK via NetworkManager"

    # Remove old connection if re-running
    nmcli connection delete "phone-uplink" 2>/dev/null || true

    # Create a new Wi-Fi connection on the uplink interface
    nmcli connection add \
        type wifi \
        con-name "phone-uplink" \
        ifname "$IF_UPLINK" \
        ssid "$UPLINK_SSID" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$UPLINK_PASS" \
        connection.autoconnect yes \
        ipv4.route-metric "$UPLINK_METRIC"

    log_ok "Wi-Fi uplink: SSID=$UPLINK_SSID (on $IF_UPLINK, metric $UPLINK_METRIC)"
}

# =============================================================================
# 7. CONFIGURE SYSCTL — enable IP forwarding
# =============================================================================
configure_sysctl() {
    log_step "Configuring IP forwarding"

    cat > /etc/sysctl.d/99-router.conf << EOF
$SENTINEL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
EOF

    sysctl -p /etc/sysctl.d/99-router.conf > /dev/null
    log_ok "IP forwarding enabled, rp_filter set to loose"
}

# =============================================================================
# 8. CONFIGURE ROUTING — custom tables for multi-uplink
# =============================================================================
configure_routing() {
    log_step "Configuring routing tables"

    local rt="/etc/iproute2/rt_tables"

    # Create rt_tables if it doesn't exist
    if [[ ! -f "$rt" ]]; then
        mkdir -p /etc/iproute2
        cat > "$rt" << RTEOF
# routing tables
255 local
254 main
253 default
0 unspec
RTEOF
        log_ok "Created $rt"
    fi

    grep -q "^${UPLINK_TABLE} " "$rt" 2>/dev/null || echo "${UPLINK_TABLE} uplink" >> "$rt"
    grep -q "^${BT_TABLE} " "$rt" 2>/dev/null || echo "${BT_TABLE} bluetooth" >> "$rt"

    log_ok "Routing tables: uplink (${UPLINK_TABLE}), bluetooth (${BT_TABLE})"
}

# =============================================================================
# 9. CONFIGURE FIREWALL — iptables kill switch + NAT
# =============================================================================
configure_firewall() {
    log_step "Configuring firewall (kill switch + NAT)"

    # Flush existing rules
    iptables -F
    iptables -t nat -F
    iptables -X 2>/dev/null || true

    # --- Default policies ---
    iptables -P INPUT DROP
    iptables -P FORWARD DROP      # KILL SWITCH: drop everything by default
    iptables -P OUTPUT ACCEPT

    # --- INPUT rules ---
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Allow DHCP on AP
    iptables -A INPUT -i "$IF_AP" -p udp --dport 67 -j ACCEPT
    # Allow DNS on AP
    iptables -A INPUT -i "$IF_AP" -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i "$IF_AP" -p tcp --dport 53 -j ACCEPT
    # Allow SSH from AP only (for management)
    iptables -A INPUT -i "$IF_AP" -p tcp --dport 22 -j ACCEPT
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp -j ACCEPT

    # --- FORWARD rules (kill switch logic) ---
    # Allow established/related
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Allow AP clients -> Wi-Fi uplink
    iptables -A FORWARD -i "$IF_AP" -o "$IF_UPLINK" -j ACCEPT
    # Allow AP clients -> Bluetooth tether
    iptables -A FORWARD -i "$IF_AP" -o "$IF_BT" -j ACCEPT
    # EVERYTHING ELSE IS DROPPED — this is the kill switch

    # --- NAT (masquerade outbound traffic) ---
    iptables -t nat -A POSTROUTING -o "$IF_UPLINK" -j MASQUERADE
    iptables -t nat -A POSTROUTING -o "$IF_BT" -j MASQUERADE

    # Save rules persistently
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    log_ok "FORWARD default: DROP (kill switch active)"
    log_ok "Allowed: $IF_AP -> $IF_UPLINK, $IF_AP -> $IF_BT"
    log_ok "NAT: MASQUERADE on $IF_UPLINK and $IF_BT"
}

# =============================================================================
# 10. NETWORKMANAGER DISPATCHER — dynamic uplink failover routing
# =============================================================================
write_nm_dispatcher() {
    log_step "Writing NetworkManager dispatcher (uplink failover)"

    mkdir -p /etc/NetworkManager/dispatcher.d

    cat > /etc/NetworkManager/dispatcher.d/50-secure-router-failover << 'HOOKEOF'
#!/usr/bin/env bash
# Secure Router — dynamic uplink failover
# Called by NetworkManager when interface state changes
# Args: $1 = interface, $2 = action

IFACE="$1"
ACTION="$2"

IF_UPLINK="wlan1"
IF_BT="bnep0"
UPLINK_TABLE=100
BT_TABLE=200
UPLINK_METRIC=100
BT_METRIC=200

case "$ACTION" in
    up|dhcp4-change)
        if [[ "$IFACE" == "$IF_UPLINK" ]]; then
            GW=$(ip route show dev "$IF_UPLINK" | grep default | awk '{print $3}' | head -1)
            if [[ -n "$GW" ]]; then
                ip route flush table $UPLINK_TABLE 2>/dev/null || true
                ip route add default via "$GW" dev "$IF_UPLINK" table $UPLINK_TABLE 2>/dev/null || true
                ip rule add from all lookup $UPLINK_TABLE priority $UPLINK_METRIC 2>/dev/null || true
                ip route replace default via "$GW" dev "$IF_UPLINK" metric $UPLINK_METRIC 2>/dev/null || true
            fi
        fi

        if [[ "$IFACE" == "$IF_BT" ]]; then
            GW=$(ip route show dev "$IF_BT" | grep default | awk '{print $3}' | head -1)
            if [[ -n "$GW" ]]; then
                ip route flush table $BT_TABLE 2>/dev/null || true
                ip route add default via "$GW" dev "$IF_BT" table $BT_TABLE 2>/dev/null || true
                ip rule add from all lookup $BT_TABLE priority $BT_METRIC 2>/dev/null || true
                ip route replace default via "$GW" dev "$IF_BT" metric $BT_METRIC 2>/dev/null || true
            fi
        fi
        ;;

    down)
        if [[ "$IFACE" == "$IF_UPLINK" ]]; then
            ip route flush table $UPLINK_TABLE 2>/dev/null || true
            ip rule del lookup $UPLINK_TABLE 2>/dev/null || true
            ip route del default dev "$IF_UPLINK" 2>/dev/null || true
        fi

        if [[ "$IFACE" == "$IF_BT" ]]; then
            ip route flush table $BT_TABLE 2>/dev/null || true
            ip rule del lookup $BT_TABLE 2>/dev/null || true
            ip route del default dev "$IF_BT" 2>/dev/null || true
        fi
        ;;
esac
HOOKEOF

    chmod +x /etc/NetworkManager/dispatcher.d/50-secure-router-failover
    log_ok "Failover dispatcher installed at /etc/NetworkManager/dispatcher.d/50-secure-router-failover"
}

# =============================================================================
# 11. ENABLE SERVICES
# =============================================================================
enable_services() {
    log_step "Enabling services"

    # Unmask and enable hostapd
    systemctl unmask hostapd 2>/dev/null || true
    systemctl enable hostapd
    log_ok "hostapd enabled"

    # Enable dnsmasq
    systemctl enable dnsmasq
    log_ok "dnsmasq enabled"

    # NetworkManager handles DHCP and uplink — reload its config
    nmcli general reload
    log_ok "NetworkManager reloaded"

    # Enable Bluetooth
    systemctl enable bluetooth 2>/dev/null || true
    log_ok "bluetooth enabled"

    # Disable systemd-resolved to avoid port 53 conflict
    systemctl disable systemd-resolved 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    log_ok "systemd-resolved disabled (avoids DNS conflict)"

    # Restore iptables on boot
    systemctl enable netfilter-persistent 2>/dev/null || true
    log_ok "iptables rules will persist across reboots"
}

# =============================================================================
# 12. PRINT SUMMARY
# =============================================================================
print_summary() {
    echo ""
    echo "============================================="
    echo "  SECURE ROUTER SETUP COMPLETE"
    echo "============================================="
    echo ""
    echo "  Hotspot SSID:     $AP_SSID"
    echo "  Hotspot Password: $AP_PASS"
    echo "  Gateway IP:       $AP_GW"
    echo "  DHCP Range:       $AP_DHCP_START - $AP_DHCP_END"
    echo ""
    echo "  Wi-Fi Uplink:     $UPLINK_SSID (on $IF_UPLINK)"
    echo "  BT Fallback:      $IF_BT (Bluetooth tether)"
    echo ""
    echo "  Kill Switch:      ACTIVE (FORWARD default DROP)"
    echo "  Failover:         $IF_UPLINK preferred, $IF_BT fallback"
    echo ""
    echo "  Next step:        Run 'sudo bash bluetooth-tether.sh' to pair phone"
    echo ""
    echo "  Useful commands:"
    echo "    sudo systemctl status hostapd    # AP status"
    echo "    sudo systemctl status dnsmasq    # DHCP/DNS status"
    echo "    sudo iptables -L FORWARD -v      # Firewall rules"
    echo "    ip route show                    # Routing table"
    echo "    iw dev $IF_AP station dump       # Connected clients"
    echo ""
    echo "  >>> REBOOT NOW to apply all changes: sudo reboot"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo "============================================="
    echo "  Portable Secure Router Setup"
    echo "============================================="

    check_prereqs
    install_packages
    configure_static_ip
    configure_hostapd
    configure_dnsmasq
    configure_uplink
    configure_sysctl
    configure_routing
    configure_firewall
    write_nm_dispatcher
    enable_services
    print_summary
}

main "$@"
