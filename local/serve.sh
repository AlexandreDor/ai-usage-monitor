#!/usr/bin/env bash
# Serve only the dashboard assets. Configuration, state and debug files are
# deliberately outside the HTTP allowlist even though they share this folder.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8080}"
BIND_ADDRESS="${2:-${DASHBOARD_BIND_ADDRESS:-0.0.0.0}}"

if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 is required to serve the dashboard." >&2
  exit 1
fi

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "[ERROR] Port must be an integer between 1 and 65535." >&2
  exit 1
fi

echo "Serving dashboard at http://${BIND_ADDRESS}:${PORT}/dashboard.html"
echo "Only dashboard assets and usage JSON are exposed. Press Ctrl+C to stop."

python3 - "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" <<'PYEOF'
import functools
import http.server
import pathlib
import sys
from urllib.parse import unquote, urlsplit

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
bind_address = sys.argv[3]
public_files = {
    "/dashboard.html": "/dashboard.html",
    "/data.json": "/runtime/data.json",
    "/history.json": "/runtime/history.json",
}
public_image_extensions = {".gif", ".jpeg", ".jpg", ".png", ".svg", ".webp"}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "CodexDashboard"
    sys_version = ""

    def is_public_path(self, request_path):
        if request_path in public_files:
            return True
        if not request_path.startswith("/images/"):
            return False

        relative_path = request_path.removeprefix("/")
        candidate = (root / relative_path).resolve()
        images_root = (root / "images").resolve()
        return (
            candidate.is_file()
            and candidate.suffix.lower() in public_image_extensions
            and candidate.parent == images_root
        )

    def send_head(self):
        request_path = unquote(urlsplit(self.path).path)
        if request_path == "/":
            request_path = "/dashboard.html"
        if not self.is_public_path(request_path):
            self.send_error(404, "Not found")
            return None

        self.path = public_files.get(request_path, request_path)
        return super().send_head()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://api.fontshare.com; font-src https://api.fontshare.com https://cdn.fontshare.com data:; connect-src 'self' https://api.github.com; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()


handler = functools.partial(DashboardHandler, directory=str(root))
server = http.server.ThreadingHTTPServer((bind_address, port), handler)

try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
PYEOF
