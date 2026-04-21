"""
Pi VPN Manager — Windows desktop app for the secure-pi-router project.

Toggles a SSH SOCKS5 tunnel to the Pi (which is itself tunneled via WireGuard),
auto-sets Chrome/Edge to use the proxy, and shows the current exit IP.

Run: python vpn_manager.py
First time: it will generate an SSH key and prompt you for the Pi password once.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
import urllib.request
import winreg
from pathlib import Path
from tkinter import messagebox, ttk

APP_DIR = Path(os.path.expandvars(r"%APPDATA%")) / "PiVPNManager"
APP_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_PATH = APP_DIR / "config.json"
KEY_PATH = APP_DIR / "id_pi"

DEFAULTS = {
    "pi_host": "10.54.81.204",
    "pi_user": "arnesh",
    "socks_port": 1080,
    "vps_ip": "193.122.146.164",  # for status label
}

PROXY_REG_PATH = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"


def load_config() -> dict:
    if CONFIG_PATH.exists():
        return {**DEFAULTS, **json.loads(CONFIG_PATH.read_text())}
    return dict(DEFAULTS)


def save_config(cfg: dict) -> None:
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


# ---------- Windows proxy registry helpers ----------

def set_system_proxy(enable: bool, port: int = 1080) -> None:
    """Toggle Chrome/Edge SOCKS5 proxy via Windows Internet Settings."""
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, PROXY_REG_PATH, 0, winreg.KEY_WRITE) as key:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 1 if enable else 0)
        if enable:
            winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, f"socks=127.0.0.1:{port}")
            # Bypass localhost so the app itself can still reach 127.0.0.1
            winreg.SetValueEx(key, "ProxyOverride", 0, winreg.REG_SZ, "<local>")
    # Notify other applications that proxy settings changed
    subprocess.run(
        ["rundll32.exe", "wininet.dll,InternetSetOption", "0", "39", "0", "0"],
        capture_output=True,
    )


# ---------- SSH key + tunnel helpers ----------

def ensure_ssh_key() -> Path:
    """Generate an ed25519 SSH key in APP_DIR if none exists."""
    if KEY_PATH.exists():
        return KEY_PATH
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-f", str(KEY_PATH), "-N", "", "-q"],
        check=True,
    )
    return KEY_PATH


def public_key() -> str:
    return KEY_PATH.with_suffix(".pub").read_text().strip()


def install_key_on_pi(host: str, user: str, password: str) -> None:
    """SSH to the Pi with password, append our pubkey to authorized_keys."""
    import paramiko
    pub = public_key()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, username=user, password=password, timeout=15)
    cmd = (
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
        f'grep -qxF "{pub}" ~/.ssh/authorized_keys 2>/dev/null || '
        f'echo "{pub}" >> ~/.ssh/authorized_keys && '
        "chmod 600 ~/.ssh/authorized_keys"
    )
    _, stdout, _ = client.exec_command(cmd, timeout=10)
    stdout.channel.recv_exit_status()
    client.close()


def is_socks_alive(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1.5):
            return True
    except OSError:
        return False


def fetch_exit_ip(socks_port: int, timeout: int = 8) -> str:
    """Query an external echo service through the SOCKS proxy."""
    import socks  # PySocks
    s = socks.socksocket()
    s.set_proxy(socks.SOCKS5, "127.0.0.1", socks_port, rdns=True)
    s.settimeout(timeout)
    try:
        s.connect(("api.ipify.org", 80))
        s.sendall(b"GET / HTTP/1.0\r\nHost: api.ipify.org\r\n\r\n")
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        body = buf.split(b"\r\n\r\n", 1)[-1].decode().strip()
        return body or "unknown"
    finally:
        s.close()


# ---------- GUI ----------

class VPNApp:
    def __init__(self) -> None:
        self.cfg = load_config()
        self.ssh_proc: subprocess.Popen | None = None

        self.root = tk.Tk()
        self.root.title("Pi VPN Manager")
        self.root.geometry("380x280")
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        # status
        self.status_var = tk.StringVar(value="🔴 Disconnected")
        self.ip_var = tk.StringVar(value="Exit IP: —")

        tk.Label(self.root, textvariable=self.status_var, font=("Segoe UI", 18)).pack(pady=(20, 4))
        tk.Label(self.root, textvariable=self.ip_var, font=("Segoe UI", 11), fg="#555").pack()

        self.toggle_btn = ttk.Button(
            self.root, text="CONNECT", command=self.toggle, width=24
        )
        self.toggle_btn.pack(pady=18, ipady=6)

        button_row = tk.Frame(self.root)
        button_row.pack()
        ttk.Button(button_row, text="Check IP", command=self.refresh_ip).pack(side="left", padx=4)
        ttk.Button(button_row, text="Settings", command=self.open_settings).pack(side="left", padx=4)

        self.footer_var = tk.StringVar(value=f"Pi: {self.cfg['pi_host']}  •  Port {self.cfg['socks_port']}")
        tk.Label(self.root, textvariable=self.footer_var, font=("Segoe UI", 8), fg="#888").pack(side="bottom", pady=8)

        # Detect existing tunnel on launch (e.g., manual ssh -D)
        if is_socks_alive(self.cfg["socks_port"]):
            self.status_var.set("🟡 Tunnel exists (not started by app)")

        self.root.mainloop()

    # ----- actions -----

    def toggle(self) -> None:
        if self.ssh_proc is None:
            self.connect()
        else:
            self.disconnect()

    def connect(self) -> None:
        try:
            ensure_ssh_key()
        except subprocess.CalledProcessError as e:
            messagebox.showerror("SSH key error", str(e))
            return

        # Test if the Pi accepts our key already; if not, prompt for password
        if not self._key_works():
            pw = self._ask_password()
            if pw is None:
                return
            try:
                install_key_on_pi(self.cfg["pi_host"], self.cfg["pi_user"], pw)
            except Exception as e:
                messagebox.showerror("Key install failed", f"Could not install SSH key on Pi:\n{e}")
                return

        # Spawn ssh -D in background
        cmd = [
            "ssh",
            "-D", str(self.cfg["socks_port"]),
            "-N",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ServerAliveInterval=30",
            "-o", "ExitOnForwardFailure=yes",
            "-i", str(KEY_PATH),
            f"{self.cfg['pi_user']}@{self.cfg['pi_host']}",
        ]
        # CREATE_NO_WINDOW = 0x08000000
        self.ssh_proc = subprocess.Popen(cmd, creationflags=0x08000000)

        # Wait for socket to come up
        for _ in range(20):
            time.sleep(0.25)
            if is_socks_alive(self.cfg["socks_port"]):
                break
        else:
            messagebox.showerror("Connect failed", "SSH tunnel did not come up. Check Pi is reachable.")
            self.ssh_proc.terminate()
            self.ssh_proc = None
            return

        set_system_proxy(True, self.cfg["socks_port"])
        self.status_var.set("🟢 Connected")
        self.toggle_btn.config(text="DISCONNECT")
        threading.Thread(target=self.refresh_ip, daemon=True).start()

    def disconnect(self) -> None:
        if self.ssh_proc:
            self.ssh_proc.terminate()
            try:
                self.ssh_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.ssh_proc.kill()
            self.ssh_proc = None
        set_system_proxy(False)
        self.status_var.set("🔴 Disconnected")
        self.ip_var.set("Exit IP: —")
        self.toggle_btn.config(text="CONNECT")

    def refresh_ip(self) -> None:
        if not is_socks_alive(self.cfg["socks_port"]):
            self.ip_var.set("Exit IP: (no tunnel)")
            return
        self.ip_var.set("Exit IP: …checking…")
        try:
            ip = fetch_exit_ip(self.cfg["socks_port"])
            expected = self.cfg["vps_ip"]
            mark = "✓" if ip == expected else "⚠ NOT VPS"
            self.ip_var.set(f"Exit IP: {ip}  {mark}")
        except Exception as e:
            self.ip_var.set(f"Exit IP: error — {e}")

    def open_settings(self) -> None:
        win = tk.Toplevel(self.root)
        win.title("Settings")
        win.geometry("320x220")
        win.resizable(False, False)

        entries = {}
        for i, (label, key) in enumerate([
            ("Pi host (IP)", "pi_host"),
            ("Pi username", "pi_user"),
            ("SOCKS port", "socks_port"),
            ("VPS public IP (for verify)", "vps_ip"),
        ]):
            tk.Label(win, text=label).grid(row=i, column=0, sticky="e", padx=8, pady=6)
            e = tk.Entry(win, width=22)
            e.insert(0, str(self.cfg[key]))
            e.grid(row=i, column=1, padx=8, pady=6)
            entries[key] = e

        def save():
            for k, e in entries.items():
                v = e.get().strip()
                self.cfg[k] = int(v) if k == "socks_port" else v
            save_config(self.cfg)
            self.footer_var.set(f"Pi: {self.cfg['pi_host']}  •  Port {self.cfg['socks_port']}")
            win.destroy()

        ttk.Button(win, text="Save", command=save).grid(row=99, column=0, columnspan=2, pady=12)

    # ----- helpers -----

    def _key_works(self) -> bool:
        """Quick check: can our SSH key authenticate?"""
        if not KEY_PATH.exists():
            return False
        result = subprocess.run(
            [
                "ssh", "-i", str(KEY_PATH),
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=5",
                "-o", "PreferredAuthentications=publickey",
                f"{self.cfg['pi_user']}@{self.cfg['pi_host']}",
                "exit",
            ],
            capture_output=True, timeout=10, creationflags=0x08000000,
        )
        return result.returncode == 0

    def _ask_password(self) -> str | None:
        win = tk.Toplevel(self.root)
        win.title("First-time setup")
        win.geometry("320x130")
        win.resizable(False, False)
        tk.Label(win, text=f"Enter password for {self.cfg['pi_user']}@{self.cfg['pi_host']}\n(used once to install your SSH key)", justify="left").pack(pady=8, padx=10)
        var = tk.StringVar()
        entry = tk.Entry(win, textvariable=var, show="•", width=24)
        entry.pack()
        entry.focus()
        result = {"value": None}

        def ok():
            result["value"] = var.get()
            win.destroy()

        def cancel():
            win.destroy()

        row = tk.Frame(win)
        row.pack(pady=10)
        ttk.Button(row, text="OK", command=ok).pack(side="left", padx=4)
        ttk.Button(row, text="Cancel", command=cancel).pack(side="left", padx=4)
        entry.bind("<Return>", lambda _: ok())
        win.grab_set()
        win.wait_window()
        return result["value"]

    def on_close(self) -> None:
        if self.ssh_proc:
            self.disconnect()
        self.root.destroy()


if __name__ == "__main__":
    try:
        VPNApp()
    except Exception as e:
        messagebox.showerror("Fatal error", str(e))
        sys.exit(1)
