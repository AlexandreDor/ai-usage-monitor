#!/usr/bin/env bash
# Serve only explicitly allowlisted dashboard files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYTICS_DATABASE_PATH="${DASHBOARD_ANALYTICS_DATABASE:-${SCRIPT_DIR}/runtime/usage-history.sqlite3}"
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

if [[ "$ANALYTICS_DATABASE_PATH" != /* ]] || [[ -e "$ANALYTICS_DATABASE_PATH" && -L "$ANALYTICS_DATABASE_PATH" ]]; then
  echo "[ERROR] DASHBOARD_ANALYTICS_DATABASE must be an absolute path and not a symbolic link." >&2
  exit 2
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

python3 - "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" "$ANALYTICS_DATABASE_PATH" <<'PYEOF'
import functools
import http.server
import pathlib
import socket
import socketserver
import sys
import threading
from urllib.parse import parse_qs, unquote, urlsplit

sys.path.insert(0, str(pathlib.Path(sys.argv[1]).resolve()))
from analytics import AnalyticsError, build_payload

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
bind_address = sys.argv[3]
analytics_database = pathlib.Path(sys.argv[4])
public_files = {
    "/dashboard.html": "/dashboard.html",
    "/analytics.html": "/analytics.html",
    "/assets/dashboard.css": "/assets/dashboard.css",
    "/assets/dashboard.js": "/assets/dashboard.js",
    "/assets/analytics.css": "/assets/analytics.css",
    "/assets/analytics.js": "/assets/analytics.js",
    "/assets/chart.umd.min.js": "/assets/chart.umd.min.js",
    "/images/favicon.png": "/images/favicon.png",
    "/data.json": "/runtime/data.json",
    "/history.json": "/runtime/history.json",
}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "CodexDashboard"
    sys_version = ""

    def send_json(self, status, value, *, include_body=True):
        import json

        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def serve_analytics(self, *, include_body=True):
        split = urlsplit(self.path)
        try:
            raw = parse_qs(split.query, keep_blank_values=True, max_num_fields=20)
            if any(len(values) != 1 for values in raw.values()):
                raise AnalyticsError("query parameters must not be repeated")
            allowed = {"range", "from_date", "to_date", "source", "sources", "model", "models", "reset_type", "reset_offset", "reset_limit"}
            if set(raw) - allowed:
                raise AnalyticsError("unknown query parameter")
            params = {key: values[0] for key, values in raw.items()}
            payload = build_payload(analytics_database, root / "pricing.json", params)
        except (AnalyticsError, ValueError) as error:
            status = 503 if "not available" in str(error) or "cannot be read" in str(error) else 400
            self.send_json(status, {"error": str(error)}, include_body=include_body)
            return
        self.send_json(200, payload, include_body=include_body)

    def do_GET(self):
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics()
            return
        super().do_GET()

    def do_HEAD(self):
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics(include_body=False)
            return
        super().do_HEAD()

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
