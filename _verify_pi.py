#!/usr/bin/env python3
"""Check WireGuard state on the Pi without re-running the setup."""
import paramiko

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect("10.54.81.204", username="arnesh", password="2006", timeout=15)

def run(cmd):
    print(f"\n$ {cmd}")
    _, stdout, _ = client.exec_command(cmd, get_pty=True, timeout=30)
    out = stdout.read().decode(errors="replace")
    print(out.encode("ascii", errors="replace").decode())

run("echo '2006' | sudo -S systemctl is-active wg-quick@wg0 2>&1")
run("echo '2006' | sudo -S wg show 2>&1")
run("ip -4 addr show wg0 2>&1 | head -5")
run("ip route show default")
run("ls -la /etc/wireguard/")
run("cat /etc/iptables/rules.v4 2>/dev/null | head -5 || echo 'no rules.v4'")
client.close()
