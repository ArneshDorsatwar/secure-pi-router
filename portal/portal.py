"""
WireGuard invite portal — lightweight self-hosted onboarding for friends.

Admin creates an invite at /admin (HTTP Basic Auth).
Each invite is a single-use URL that returns a QR + config, then expires itself.

Run: sudo WG_ADMIN_PASS=<password> python3 portal.py
(or via the provided systemd unit)
"""
import base64
import html
import os
import secrets
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs

ADMIN_PASS = os.environ.get("WG_ADMIN_PASS", "")
PORT = int(os.environ.get("WG_PORTAL_PORT", "8443"))
INVITES_DIR = Path("/var/lib/wg-invites")
PEERS_DIR = Path("/etc/wireguard/peers")
ADD_PEER_CMD = "/usr/local/bin/wg-add-peer"


def generate_invite(raw_name: str) -> tuple[str, str]:
    """Create a new WireGuard peer, stash its config behind a random token."""
    safe = "".join(c for c in raw_name if c.isalnum() or c in "-_").strip("-_")[:32]
    if not safe:
        safe = "device"
    peer_name = f"{safe}-{secrets.token_hex(3)}"
    subprocess.run([ADD_PEER_CMD, peer_name], check=True, capture_output=True)
    token = secrets.token_urlsafe(16)
    src = PEERS_DIR / f"{peer_name}.conf"
    dst = INVITES_DIR / f"{token}.conf"
    shutil.copy(src, dst)
    os.chmod(dst, 0o644)
    return token, peer_name


# ---------- HTML ----------

CSS = """
<style>
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
       max-width: 560px; margin: 40px auto; padding: 24px;
       background: #0f1419; color: #e6e1d6; line-height: 1.5; }
h1, h2 { color: #fff; font-weight: 600; }
a { color: #8fbcff; }
img { max-width: 100%; height: auto; border: 12px solid #fff; border-radius: 8px;
      display: block; margin: 20px auto; }
pre { background: #000; color: #a6e3a1; padding: 16px; border-radius: 6px;
      overflow-x: auto; font-size: 12px; white-space: pre-wrap; word-break: break-all; }
.btn { display: inline-block; background: #448aff; color: #fff; padding: 12px 24px;
       border: none; border-radius: 6px; font-size: 16px; text-decoration: none;
       cursor: pointer; }
.btn:hover { background: #5a9bff; }
input { background: #1f2733; color: #e6e1d6; border: 1px solid #2a3442;
        padding: 10px 14px; border-radius: 6px; font-size: 16px; width: 100%;
        margin: 8px 0; }
.card { background: #1a1f29; padding: 20px; border-radius: 8px; margin: 16px 0; }
.warn { background: #402b1a; color: #ffcc88; padding: 12px; border-radius: 6px;
        border-left: 3px solid #ff9933; }
.muted { color: #8a8a8a; font-size: 14px; }
code { background: #000; padding: 2px 6px; border-radius: 3px; font-size: 13px; }
</style>
"""

LANDING = f"""<!DOCTYPE html><html><head><title>WG Portal</title>{CSS}</head><body>
<h1>WireGuard portal</h1>
<p>Nothing to see here. This is a private VPN onboarding portal.</p>
<p class="muted">If you were sent an invite link, open that link directly.</p>
</body></html>"""

ADMIN = f"""<!DOCTYPE html><html><head><title>Admin · WG Portal</title>{CSS}</head><body>
<h1>Create invite</h1>
<div class="card">
  <form method="POST" action="/admin/create">
    <label>Device/friend name (e.g. <code>alice-phone</code>)</label>
    <input name="device" placeholder="friend-phone" required autofocus>
    <button class="btn" type="submit">Generate invite link</button>
  </form>
</div>
<p class="muted">Each invite creates a new WireGuard peer with unique keys.<br>
The invite link is <b>single-use</b> and expires after it's opened.</p>
</body></html>"""

EXPIRED = f"""<!DOCTYPE html><html><head><title>Invite expired</title>{CSS}</head><body>
<h1>⚠️ Invite expired or not found</h1>
<p>This invite link has already been used, or the token is invalid.</p>
<p class="muted">Ask the admin for a new invite.</p>
</body></html>"""

CONFIG_PAGE = """<!DOCTYPE html><html><head><title>Your VPN config</title>{css}</head><body>
<h1>🔐 Your WireGuard config</h1>
<div class="warn">⚠️ This link is single-use. Save the config now — reloading won't work.</div>
<h2>1. Scan this QR in the WireGuard app</h2>
<img src="data:image/png;base64,{qr_b64}"/>
<h2>2. Or import this config file manually</h2>
<pre>{config}</pre>
<p class="muted">After importing, toggle the tunnel ON. Test at <a href="https://ifconfig.me" target="_blank">ifconfig.me</a> — should show <code>{vps_ip}</code>.</p>
</body></html>"""

INVITE_CREATED = """<!DOCTYPE html><html><head><title>Invite created</title>{css}</head><body>
<h1>✅ Invite created</h1>
<p>Peer name: <code>{name}</code></p>
<h2>Share this link with your friend:</h2>
<div class="card"><code style="word-break: break-all; font-size: 15px;">{url}</code></div>
<p class="muted">Copy it to Signal / iMessage / Discord / whatever E2E-encrypted app you use. The link expires after one open.</p>
<a class="btn" href="/admin">Create another</a>
</body></html>"""


# ---------- HTTP handler ----------

class Handler(BaseHTTPRequestHandler):

    def _reply(self, status: int, body: str | bytes, ctype: str = "text/html; charset=utf-8") -> None:
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _require_auth(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            self._ask_auth()
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode()
            _, pw = decoded.split(":", 1)
            if secrets.compare_digest(pw, ADMIN_PASS):
                return True
        except Exception:
            pass
        self._ask_auth()
        return False

    def _ask_auth(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="WG Portal Admin"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path in ("/", ""):
            self._reply(200, LANDING)
            return
        if self.path == "/admin":
            if not self._require_auth():
                return
            self._reply(200, ADMIN)
            return
        if self.path.startswith("/i/"):
            token = self.path[3:].split("?", 1)[0]
            # Safety: tokens are base64url, no slashes
            if "/" in token or "\\" in token or ".." in token:
                self._reply(404, EXPIRED)
                return
            conf_path = INVITES_DIR / f"{token}.conf"
            if not conf_path.exists():
                self._reply(404, EXPIRED)
                return
            try:
                config = conf_path.read_text()
                qr_bytes = subprocess.check_output(
                    ["qrencode", "-t", "PNG", "-s", "8", "-m", "2"],
                    input=config.encode(),
                )
                qr_b64 = base64.b64encode(qr_bytes).decode()
                vps_ip = self._detect_vps_ip(config)
                self._reply(200, CONFIG_PAGE.format(
                    css=CSS, qr_b64=qr_b64,
                    config=html.escape(config),
                    vps_ip=html.escape(vps_ip),
                ))
                conf_path.unlink(missing_ok=True)  # single use
            except Exception as e:
                self._reply(500, f"Error: {html.escape(str(e))}")
            return
        self._reply(404, "Not found")

    def do_POST(self) -> None:
        if self.path == "/admin/create":
            if not self._require_auth():
                return
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode()
            form = parse_qs(body)
            device = form.get("device", ["device"])[0]
            try:
                token, peer_name = generate_invite(device)
            except subprocess.CalledProcessError as e:
                self._reply(500, f"wg-add-peer failed: {html.escape(e.stderr.decode() if e.stderr else str(e))}")
                return
            host = self.headers.get("Host", "")
            url = f"http://{host}/i/{token}"
            self._reply(200, INVITE_CREATED.format(
                css=CSS,
                name=html.escape(peer_name),
                url=html.escape(url),
            ))
            return
        self._reply(404, "Not found")

    def log_message(self, fmt: str, *args) -> None:  # silence default console spam
        pass

    @staticmethod
    def _detect_vps_ip(config: str) -> str:
        for line in config.splitlines():
            if line.strip().startswith("Endpoint"):
                endpoint = line.split("=", 1)[1].strip()
                return endpoint.split(":", 1)[0]
        return "?"


def main() -> None:
    if not ADMIN_PASS or len(ADMIN_PASS) < 8:
        raise SystemExit("Refusing to start: set WG_ADMIN_PASS env var (>= 8 chars).")
    INVITES_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(INVITES_DIR, 0o700)
    print(f"[*] WireGuard portal listening on :{PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
