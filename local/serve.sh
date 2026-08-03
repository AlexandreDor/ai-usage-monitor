#!/usr/bin/env bash
# Serve only explicitly allowlisted dashboard files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8080
BIND_ADDRESS="127.0.0.1"
POSITIONAL_PORT=""
PORT_WAS_NAMED=false

usage() {
  cat <<'EOF'
Usage: ./serve.sh [--port PORT] [--bind ADDRESS]
       ./serve.sh [PORT]

Serve the local Codex usage dashboard.

Options:
  --port PORT      TCP port (1-65535, default: 8080)
  --bind ADDRESS   IP address to listen on (default: 127.0.0.1)
                   Use --bind 0.0.0.0 explicitly to allow LAN access.
  -h, --help       Show this help

The server provides no authentication and no TLS. Do not expose it to an
untrusted network; use a properly configured reverse proxy if either is needed.

For compatibility, one positional PORT is accepted. Positional bind addresses
are not accepted; network exposure must use --bind explicitly.
EOF
}

while (($#)); do
  case "$1" in
    --port)
      (($# >= 2)) || { echo "[ERROR] --port requires a value." >&2; exit 2; }
      PORT="$2"
      PORT_WAS_NAMED=true
      shift 2
      ;;
    --bind)
      (($# >= 2)) || { echo "[ERROR] --bind requires a value." >&2; exit 2; }
      BIND_ADDRESS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$POSITIONAL_PORT" || "$PORT_WAS_NAMED" == true ]]; then
        echo "[ERROR] Unexpected positional argument: $1" >&2
        usage >&2
        exit 2
      fi
      POSITIONAL_PORT="$1"
      PORT="$1"
      shift
      ;;
  esac
done

if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 is required to serve the dashboard." >&2
  exit 1
fi

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((${#PORT} > 5)) || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  echo "[ERROR] Port must be an integer between 1 and 65535." >&2
  exit 2
fi

if ! python3 - "$BIND_ADDRESS" <<'PYEOF'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print("[ERROR] Bind address must be a valid IPv4 or IPv6 address.", file=sys.stderr)
    raise SystemExit(1)
PYEOF
then
  exit 2
fi

DISPLAY_ADDRESS="$BIND_ADDRESS"
if [[ "$BIND_ADDRESS" == *:* ]]; then
  DISPLAY_ADDRESS="[$BIND_ADDRESS]"
fi

echo "Serving dashboard at http://${DISPLAY_ADDRESS}:${PORT}/dashboard.html"
echo "Only allowlisted dashboard assets and usage JSON are exposed. Press Ctrl+C to stop."

python3 - "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" <<'PYEOF'
import functools
import http.server
import pathlib
import socket
import socketserver
import sys
import threading
from urllib.parse import unquote, urlsplit

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
bind_address = sys.argv[3]
public_files = {
    "/dashboard.html": "/dashboard.html",
    "/assets/dashboard.css": "/assets/dashboard.css",
    "/assets/dashboard.js": "/assets/dashboard.js",
    "/assets/chart.umd.min.js": "/assets/chart.umd.min.js",
    "/images/favicon.png": "/images/favicon.png",
    "/data.json": "/runtime/data.json",
    "/history.json": "/runtime/history.json",
}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "CodexDashboard"
    sys_version = ""

    def send_head(self):
        request_path = unquote(urlsplit(self.path).path)
        if request_path == "/":
            request_path = "/dashboard.html"
        mapped_path = public_files.get(request_path)
        if mapped_path is None:
            self.send_error(404, "Not found")
            return None

        self.path = mapped_path
        return super().send_head()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; style-src 'self'; "
            "connect-src 'self' https://api.github.com; img-src 'self'; "
            "font-src 'none'; object-src 'none'; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'",
        )
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()


class BoundedThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    address_family = socket.AF_INET6 if ":" in bind_address else socket.AF_INET

    def __init__(self, *args, max_workers=16, **kwargs):
        self._worker_slots = threading.BoundedSemaphore(max_workers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        self._worker_slots.acquire()
        try:
            super().process_request(request, client_address)
        except Exception:
            self._worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._worker_slots.release()


handler = functools.partial(DashboardHandler, directory=str(root))
try:
    server = BoundedThreadingHTTPServer((bind_address, port), handler)
except OSError as error:
    print(f"[ERROR] Unable to listen on {bind_address}:{port}: {error}", file=sys.stderr)
    raise SystemExit(1)

try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
PYEOF
