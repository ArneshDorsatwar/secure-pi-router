"""
WireGuard invite portal — lightweight self-hosted onboarding + admin.

Features:
    /admin                : list active peers, create invites, remove peers
    /admin/create (POST)  : generate a new peer + single-use invite URL
    /admin/remove (POST)  : revoke a peer (live + config file)
    /i/<token>            : single-use invite page (QR + download config)

Run: sudo WG_ADMIN_PASS=<password> python3 portal.py
"""
import base64
import html
import os
import secrets
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote

ADMIN_PASS = os.environ.get("WG_ADMIN_PASS", "")
PORT = int(os.environ.get("WG_PORTAL_PORT", "8443"))
INVITES_DIR = Path("/var/lib/wg-invites")
PEERS_DIR = Path("/etc/wireguard/peers")
WG_CONF = Path("/etc/wireguard/wg0.conf")
ADD_PEER_CMD = "/usr/local/bin/wg-add-peer"


# =============================================================================
# Peer management
# =============================================================================

def name_map_from_config() -> dict[str, str]:
    """Map each peer's PublicKey to its friendly name (from [Peer] block comments)."""
    if not WG_CONF.exists():
        return {}
    mapping = {}
    current_name = None
    in_peer = False
    for raw in WG_CONF.read_text().splitlines():
        line = raw.strip()
        if line == "[Peer]":
            current_name = None
            in_peer = True
        elif line.startswith("[") and line != "[Peer]":
            in_peer = False
        elif in_peer and line.startswith("#") and current_name is None:
            current_name = line.lstrip("#").strip()
        elif in_peer and line.startswith("PublicKey"):
            pubkey = line.split("=", 1)[1].strip()
            if current_name:
                mapping[pubkey] = current_name
    return mapping


def list_peers() -> list[dict]:
    """Return active WireGuard peers with stats."""
    result = subprocess.run(
        ["wg", "show", "wg0", "dump"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode != 0:
        return []
    names = name_map_from_config()
    peers = []
    lines = result.stdout.strip().split("\n")[1:]  # skip interface line
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        pubkey = parts[0]
        allowed_ips = parts[3] if len(parts) > 3 else ""
        last_hs = int(parts[4]) if len(parts) > 4 and parts[4] else 0
        rx = int(parts[5]) if len(parts) > 5 and parts[5] else 0
        tx = int(parts[6]) if len(parts) > 6 and parts[6] else 0
        peers.append({
            "name": names.get(pubkey, "(unnamed)"),
            "pubkey": pubkey,
            "ip": allowed_ips.split("/")[0].split(",")[0],
            "last_handshake": last_hs,
            "rx": rx,
            "tx": tx,
        })
    peers.sort(key=lambda p: p["ip"])
    return peers


def remove_peer(pubkey: str) -> None:
    """Remove a peer both live (wg set) and persistently (wg0.conf)."""
    # 1. Remove live
    subprocess.run(
        ["wg", "set", "wg0", "peer", pubkey, "remove"],
        check=True, capture_output=True,
    )
    # 2. Remove from config file (preserve [Interface] block + other peers)
    lines = WG_CONF.read_text().splitlines(keepends=True)
    out: list[str] = []
    block: list[str] = []
    in_peer = False
    block_matches = False
    for line in lines:
        stripped = line.strip()
        if stripped == "[Peer]":
            # flush previous block
            if in_peer and not block_matches:
                out.extend(block)
            elif not in_peer:
                out.extend(block)
            block = [line]
            in_peer = True
            block_matches = False
        elif in_peer:
            block.append(line)
            if stripped.startswith("PublicKey") and pubkey in stripped:
                block_matches = True
        else:
            block.append(line)
    # flush final block
    if in_peer and not block_matches:
        out.extend(block)
    elif not in_peer:
        out.extend(block)
    WG_CONF.write_text("".join(out))


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


def human_bytes(n: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} PiB"


def human_time_since(ts: int) -> str:
    if ts == 0:
        return "never"
    diff = int(time.time()) - ts
    if diff < 60:
        return f"{diff}s ago"
    if diff < 3600:
        return f"{diff // 60}m ago"
    if diff < 86400:
        return f"{diff // 3600}h ago"
    return f"{diff // 86400}d ago"


# =============================================================================
# HTML
# =============================================================================

CSS = """
<style>
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
       max-width: 820px; margin: 40px auto; padding: 24px;
       background: #0f1419; color: #e6e1d6; line-height: 1.5; }
h1, h2 { color: #fff; font-weight: 600; }
a { color: #8fbcff; }
img { max-width: 100%; height: auto; border: 12px solid #fff; border-radius: 8px;
      display: block; margin: 20px auto; }
pre { background: #000; color: #a6e3a1; padding: 16px; border-radius: 6px;
      overflow-x: auto; font-size: 12px; white-space: pre-wrap; word-break: break-all; }
.btn { display: inline-block; background: #448aff; color: #fff; padding: 10px 20px;
       border: none; border-radius: 6px; font-size: 15px; text-decoration: none;
       cursor: pointer; }
.btn:hover { background: #5a9bff; }
.btn-danger { background: #e03e52; padding: 6px 14px; font-size: 13px; }
.btn-danger:hover { background: #f05565; }
input { background: #1f2733; color: #e6e1d6; border: 1px solid #2a3442;
        padding: 10px 14px; border-radius: 6px; font-size: 15px; width: 100%;
        margin: 8px 0; }
.card { background: #1a1f29; padding: 20px; border-radius: 8px; margin: 16px 0; }
.warn { background: #402b1a; color: #ffcc88; padding: 12px; border-radius: 6px;
        border-left: 3px solid #ff9933; }
.muted { color: #8a8a8a; font-size: 14px; }
code { background: #000; padding: 2px 6px; border-radius: 3px; font-size: 13px; }
table { width: 100%; border-collapse: collapse; margin-top: 12px; }
th, td { padding: 10px 8px; text-align: left; border-bottom: 1px solid #2a3442;
         font-size: 14px; }
th { color: #8a8a8a; font-weight: 500; text-transform: uppercase; font-size: 11px; }
tr:last-child td { border-bottom: none; }
.status-green { color: #8fd4a3; }
.status-red { color: #e47b88; }
.status-gray { color: #666; }
details > summary { cursor: pointer; margin: 10px 0; color: #8a8a8a; }
</style>
"""

LANDING = f"""<!DOCTYPE html><html><head><title>WG Portal</title>{CSS}</head><body>
<h1>WireGuard portal</h1>
<p>Nothing to see here. This is a private VPN onboarding portal.</p>
<p class="muted">If you were sent an invite link, open that link directly.</p>
</body></html>"""

EXPIRED = f"""<!DOCTYPE html><html><head><title>Invite expired</title>{CSS}</head><body>
<h1>⚠️ Invite expired or not found</h1>
<p>This invite link has already been used, or the token is invalid.</p>
<p class="muted">Ask the admin for a new invite.</p>
</body></html>"""

CONFIG_PAGE = """<!DOCTYPE html><html><head><title>Your VPN config</title>{css}</head><body>
<h1>🔐 Your WireGuard config</h1>
<div class="warn">⚠️ This page is single-use. Save your config now — reloading won't work.</div>
<h2>📱 Phone</h2>
<p>Open the <b>WireGuard</b> app → tap <b>+</b> → <b>Scan from QR code</b> → aim at this image:</p>
<img src="data:image/png;base64,{qr_b64}"/>
<h2>💻 Desktop (Windows / Mac / Linux)</h2>
<p>Download the config file, then in the <b>WireGuard</b> app click <b>Import tunnel(s) from file</b>:</p>
<p><a class="btn" href="data:application/x-wireguard-config;charset=utf-8,{config_url}" download="vpn.conf">⬇️ Download vpn.conf</a></p>
<details><summary>Or copy-paste the config manually</summary>
<pre>{config}</pre>
</details>
<p class="muted">After importing, toggle the tunnel ON. Test at <a href="https://ifconfig.me" target="_blank">ifconfig.me</a> — should show <code>{vps_ip}</code>.</p>
</body></html>"""

INVITE_CREATED = """<!DOCTYPE html><html><head><title>Invite created</title>{css}</head><body>
<h1>✅ Invite created</h1>
<p>Peer name: <code>{name}</code></p>
<h2>Share this link with your friend:</h2>
<div class="card"><code style="word-break: break-all; font-size: 15px;">{url}</code></div>
<p class="muted">Copy it to Signal / iMessage / Discord. The link expires after one open.</p>
<a class="btn" href="/admin">Back to dashboard</a>
</body></html>"""


def admin_page(peers: list[dict]) -> str:
    rows = []
    if not peers:
        rows.append('<tr><td colspan="5" class="muted" style="text-align:center">No peers yet</td></tr>')
    for p in peers:
        hs_class = (
            "status-green" if p["last_handshake"] and (time.time() - p["last_handshake"] < 180)
            else "status-red" if p["last_handshake"]
            else "status-gray"
        )
        rows.append(f"""
        <tr>
          <td>{html.escape(p['name'])}</td>
          <td><code>{p['ip']}</code></td>
          <td class="{hs_class}">{human_time_since(p['last_handshake'])}</td>
          <td>↓ {human_bytes(p['rx'])}<br>↑ {human_bytes(p['tx'])}</td>
          <td>
            <form method="POST" action="/admin/remove" style="display:inline"
                  onsubmit="return confirm('Remove {html.escape(p['name'])} ({p['ip']})? This revokes their access immediately.');">
              <input type="hidden" name="pubkey" value="{html.escape(p['pubkey'])}">
              <button type="submit" class="btn btn-danger">Remove</button>
            </form>
          </td>
        </tr>
        """)
    table_html = "\n".join(rows)
    return f"""<!DOCTYPE html><html><head><title>Admin · WG Portal</title>{CSS}</head><body>
<h1>WireGuard admin</h1>

<div class="card">
  <h2 style="margin-top:0">Active peers ({len(peers)})</h2>
  <table>
    <tr><th>Name</th><th>VPN IP</th><th>Last seen</th><th>Traffic</th><th></th></tr>
    {table_html}
  </table>
</div>

<div class="card">
  <h2 style="margin-top:0">Create invite</h2>
  <form method="POST" action="/admin/create">
    <label>Device/friend name</label>
    <input name="device" placeholder="alice-phone" required autofocus>
    <button class="btn" type="submit">Generate invite link</button>
  </form>
  <p class="muted">Each invite creates a new WireGuard peer with unique keys.
     The invite link is single-use.</p>
</div>
</body></html>"""


# =============================================================================
# HTTP handler
# =============================================================================

class Handler(BaseHTTPRequestHandler):

    # Kill the default reverse-DNS lookup — massively slows down requests from
    # random port scanners (and adds no value to our logs, which we silence).
    def address_string(self) -> str:
        return self.client_address[0]

    # Drop stalled or malformed connections after 15s instead of hogging a worker.
    timeout = 15

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

    def _redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        if self.path in ("/", ""):
            self._reply(200, LANDING)
            return
        if self.path == "/admin":
            if not self._require_auth():
                return
            self._reply(200, admin_page(list_peers()))
            return
        if self.path.startswith("/i/"):
            token = self.path[3:].split("?", 1)[0]
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
                    ["qrencode", "-t", "PNG", "-s", "8", "-m", "2", "-o", "-"],
                    input=config.encode(),
                )
                qr_b64 = base64.b64encode(qr_bytes).decode()
                vps_ip = self._detect_vps_ip(config)
                self._reply(200, CONFIG_PAGE.format(
                    css=CSS, qr_b64=qr_b64,
                    config=html.escape(config),
                    config_url=quote(config),
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
                err = (e.stderr.decode() if e.stderr else str(e))
                self._reply(500, f"wg-add-peer failed: {html.escape(err)}")
                return
            host = self.headers.get("Host", "")
            url = f"http://{host}/i/{token}"
            self._reply(200, INVITE_CREATED.format(
                css=CSS,
                name=html.escape(peer_name),
                url=html.escape(url),
            ))
            return
        if self.path == "/admin/remove":
            if not self._require_auth():
                return
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode()
            form = parse_qs(body)
            pubkey = form.get("pubkey", [""])[0].strip()
            if not pubkey:
                self._reply(400, "Missing pubkey")
                return
            try:
                remove_peer(pubkey)
            except subprocess.CalledProcessError as e:
                err = (e.stderr.decode() if e.stderr else str(e))
                self._reply(500, f"wg set failed: {html.escape(err)}")
                return
            self._redirect("/admin")
            return
        self._reply(404, "Not found")

    def log_message(self, fmt: str, *args) -> None:
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
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True   # let the process exit cleanly even if a worker is stuck
    server.serve_forever()


if __name__ == "__main__":
    main()
