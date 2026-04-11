#!/usr/bin/env bash
# =============================================================================
# Bluetooth PAN Tethering Helper
# Pairs the Pi with your Android phone over Bluetooth and creates a bnep0
# network interface for internet tethering (fallback uplink).
#
# How it works:
#   1. Scans for nearby Bluetooth devices
#   2. Pairs and trusts your phone
#   3. Connects via Bluetooth PAN (Personal Area Network)
#   4. bnep0 interface appears -> dhcpcd gets an IP -> router uses it as fallback
#
# Prerequisites on your phone:
#   - Bluetooth ON and discoverable
#   - Bluetooth Tethering enabled:
#     Settings > Network > Hotspot & Tethering > Bluetooth Tethering
#
# Usage: sudo bash bluetooth-tether.sh [PHONE_MAC]
#   If PHONE_MAC is provided, skip scanning and pair directly.
#   Example: sudo bash bluetooth-tether.sh AA:BB:CC:DD:EE:FF
# =============================================================================
set -euo pipefail

PHONE_MAC="${1:-}"

log() { echo "[*] $1"; }
ok()  { echo "[OK] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

# Must be root
[[ $EUID -eq 0 ]] || err "Run as root (sudo)."

# Ensure Bluetooth is up
log "Starting Bluetooth service..."
systemctl start bluetooth 2>/dev/null || true
sleep 1

# Power on the adapter
bluetoothctl power on > /dev/null 2>&1
bluetoothctl discoverable on > /dev/null 2>&1
bluetoothctl pairable on > /dev/null 2>&1
ok "Bluetooth adapter powered on"

# If no MAC provided, scan for devices
if [[ -z "$PHONE_MAC" ]]; then
    log "Scanning for Bluetooth devices (10 seconds)..."
    echo "    Make sure your phone's Bluetooth is ON and DISCOVERABLE"
    echo ""

    # Run scan in background, collect results
    bluetoothctl --timeout 10 scan on 2>/dev/null &
    sleep 12

    echo ""
    log "Found devices:"
    echo ""

    # List discovered devices
    mapfile -t DEVICES < <(bluetoothctl devices 2>/dev/null | grep "^Device" || true)

    if [[ ${#DEVICES[@]} -eq 0 ]]; then
        err "No devices found. Make sure phone Bluetooth is on and discoverable."
    fi

    for i in "${!DEVICES[@]}"; do
        local_mac=$(echo "${DEVICES[$i]}" | awk '{print $2}')
        local_name=$(echo "${DEVICES[$i]}" | cut -d' ' -f3-)
        echo "    [$((i+1))] $local_name ($local_mac)"
    done

    echo ""
    read -rp "Select device number: " choice

    if [[ -z "$choice" || "$choice" -lt 1 || "$choice" -gt ${#DEVICES[@]} ]]; then
        err "Invalid selection."
    fi

    PHONE_MAC=$(echo "${DEVICES[$((choice-1))]}" | awk '{print $2}')
    ok "Selected: $PHONE_MAC"
fi

# Pair with the phone
log "Pairing with $PHONE_MAC..."
echo "    You may see a pairing request on your phone — ACCEPT it"
echo ""

bluetoothctl pair "$PHONE_MAC" 2>/dev/null || true
sleep 3

bluetoothctl trust "$PHONE_MAC" 2>/dev/null || true
ok "Device paired and trusted"

# Connect via NAP (Network Access Point) profile for Bluetooth PAN
log "Connecting Bluetooth PAN..."

# Try using bt-network (from bluez-tools) or dbus directly
if command -v bt-network &>/dev/null; then
    bt-network -c "$PHONE_MAC" nap &
    sleep 3
else
    # Use dbus-send to connect to NAP profile
    dbus-send --system --type=method_call --dest=org.bluez \
        "/org/bluez/hci0/dev_$(echo "$PHONE_MAC" | tr ':' '_')" \
        org.bluez.Network1.Connect \
        string:"nap" 2>/dev/null || \

    # Alternative: try GN profile
    dbus-send --system --type=method_call --dest=org.bluez \
        "/org/bluez/hci0/dev_$(echo "$PHONE_MAC" | tr ':' '_')" \
        org.bluez.Network1.Connect \
        string:"gn" 2>/dev/null || {
            echo ""
            echo "[!] Automatic BT PAN connection failed."
            echo "    This can happen if Bluetooth Tethering is not enabled on the phone."
            echo ""
            echo "    On your Android phone, go to:"
            echo "    Settings > Network > Hotspot & Tethering > Bluetooth Tethering -> ON"
            echo ""
            echo "    Then re-run: sudo bash bluetooth-tether.sh $PHONE_MAC"
            exit 1
        }
fi

# Wait for bnep0 to appear
log "Waiting for bnep0 interface..."
attempts=0
while ! ip link show bnep0 &>/dev/null; do
    sleep 1
    attempts=$((attempts + 1))
    if [[ $attempts -ge 20 ]]; then
        err "bnep0 did not appear. Enable Bluetooth Tethering on your phone and retry."
    fi
done

ok "bnep0 interface is up"

# Get IP via DHCP
log "Requesting IP address on bnep0..."
dhcpcd bnep0 2>/dev/null || dhclient bnep0 2>/dev/null || true
sleep 3

BT_IP=$(ip -4 addr show bnep0 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "none")
ok "bnep0 IP: $BT_IP"

# Save MAC for auto-reconnect
echo "$PHONE_MAC" > /etc/bluetooth/phone_mac
ok "Phone MAC saved for auto-reconnect"

# Create a systemd service for auto-reconnect on boot
cat > /etc/systemd/system/bt-tether.service << EOF
[Unit]
Description=Bluetooth PAN Tether
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash -c ' \
    bluetoothctl power on; \
    sleep 2; \
    dbus-send --system --type=method_call --dest=org.bluez \
        /org/bluez/hci0/dev_$(echo $PHONE_MAC | tr ":" "_") \
        org.bluez.Network1.Connect string:"nap" 2>/dev/null || true; \
    sleep 5; \
    dhcpcd bnep0 2>/dev/null || true'
Environment=PHONE_MAC=$PHONE_MAC

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bt-tether.service
ok "Auto-reconnect service enabled (bt-tether.service)"

echo ""
echo "====================================="
echo "  BLUETOOTH TETHERING ACTIVE"
echo "====================================="
echo ""
echo "  Phone MAC:    $PHONE_MAC"
echo "  Interface:    bnep0"
echo "  IP Address:   $BT_IP"
echo "  Role:         Fallback uplink (metric 200)"
echo "  Auto-connect: Enabled on boot"
echo ""
echo "  The router will use this as fallback"
echo "  when the Wi-Fi uplink (wlan1) is down."
echo ""
