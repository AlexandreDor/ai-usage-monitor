#!/usr/bin/env bash
# Serve only explicitly allowlisted dashboard files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PY="${SCRIPT_DIR}/config.py"
ENV_FILE="${CODEX_MONITOR_ENV_FILE:-${SCRIPT_DIR}/.env}"
RUNTIME_DIR="${CODEX_MONITOR_RUNTIME_DIR:-${SCRIPT_DIR}/runtime}"
ANALYTICS_DATABASE_PATH="${DASHBOARD_ANALYTICS_DATABASE:-}"
ANALYTICS_PRICING_PATH="${DASHBOARD_PRICING_FILE:-${TOKEN_PRICING_FILE:-}}"
DASHBOARD_ACTIVE_INTERVAL="${DASHBOARD_ACTIVE_INTERVAL_SECONDS:-}"
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

# The shared Python resolver is the source of truth for the server.
if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 is required to serve the dashboard." >&2
  exit 1
fi
config_transport="$(mktemp "${TMPDIR:-/tmp}/codex-dashboard-config.XXXXXX")" || {
  echo "[ERROR] Unable to create a private configuration transport." >&2
  exit 1
}
config_transport_error=0
if ! python3 "$CONFIG_PY" --profile serve --env-file "$ENV_FILE" \
    --script-dir "$SCRIPT_DIR" --bind "$BIND_ADDRESS" --port "$PORT" >"$config_transport"; then
  rm -f -- "$config_transport"
  exit 2
fi
while IFS= read -r -d '' config_record; do
  config_key="${config_record%%$'\t'*}"
  config_encoded="${config_record#*$'\t'}"
  config_value="$(printf '%s' "$config_encoded" | base64 --decode)" || {
    config_transport_error=1
    break
  }
  case "$config_key" in
    TOKEN_PRICING_FILE) ANALYTICS_PRICING_PATH="$config_value" ;;
    DASHBOARD_ACTIVE_INTERVAL_SECONDS) DASHBOARD_ACTIVE_INTERVAL="$config_value" ;;
    ANALYTICS_DATABASE_PATH|PORT|BIND_ADDRESS) printf -v "$config_key" '%s' "$config_value" ;;
  esac
done <"$config_transport"
rm -f -- "$config_transport"
if (( ${config_transport_error:-0} )); then
  echo "[ERROR] Invalid configuration transport." >&2
  exit 1
fi

DISPLAY_ADDRESS="$BIND_ADDRESS"
if [[ "$BIND_ADDRESS" == *:* ]]; then
  DISPLAY_ADDRESS="[$BIND_ADDRESS]"
fi

echo "Serving dashboard at http://${DISPLAY_ADDRESS}:${PORT}/dashboard.html"
echo "Only allowlisted dashboard assets and usage JSON are exposed. Press Ctrl+C to stop."

python3 - "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" "$ANALYTICS_DATABASE_PATH" "$ANALYTICS_PRICING_PATH" "$DASHBOARD_ACTIVE_INTERVAL" "$RUNTIME_DIR" <<'PYEOF'
import functools
import http.server
import os
import pathlib
import socket
import socketserver
import sqlite3
import stat
import sys
import threading
import time
from urllib.parse import parse_qs, unquote, urlsplit

sys.path.insert(0, str(pathlib.Path(sys.argv[1]).resolve()))
from analytics import AnalyticsError, build_payload

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
bind_address = sys.argv[3]
analytics_database = pathlib.Path(sys.argv[4])
analytics_pricing = pathlib.Path(sys.argv[5])
dashboard_active_interval = int(sys.argv[6])
runtime_directory = pathlib.Path(sys.argv[7]).absolute()
heartbeat_path = runtime_directory / "dashboard-heartbeat"
heartbeat_lock = threading.Lock()
heartbeat_coalesce_seconds = 5
public_files = {
    "/dashboard.html": "/dashboard.html",
    "/analytics.html": "/analytics.html",
    "/assets/dashboard.css": "/assets/dashboard.css",
    "/assets/dashboard.js": "/assets/dashboard.js",
    "/assets/preferences.js": "/assets/preferences.js",
    "/assets/analytics.css": "/assets/analytics.css",
    "/assets/analytics.js": "/assets/analytics.js",
    "/assets/chart.umd.min.js": "/assets/chart.umd.min.js",
    "/assets/chart-interactions.js": "/assets/chart-interactions.js",
    "/images/favicon.png": "/images/favicon.png",
}
runtime_files = {
    "/data.json": runtime_directory / "data.json",
    "/history.json": runtime_directory / "history.json",
}


def prepare_runtime_directory():
    if runtime_directory.is_symlink():
        raise OSError("runtime directory must not be a symbolic link")
    runtime_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = runtime_directory.stat(follow_symlinks=False)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise OSError("runtime directory must be owned by the current user")
    runtime_directory.chmod(0o700)


def record_dashboard_heartbeat():
    with heartbeat_lock:
        try:
            metadata = heartbeat_path.stat(follow_symlinks=False)
        except FileNotFoundError:
            metadata = None
        if metadata is not None:
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise OSError("dashboard heartbeat must be a regular file owned by the current user")
            heartbeat_age = time.time() - metadata.st_mtime
            if 0 <= heartbeat_age < heartbeat_coalesce_seconds:
                return

        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(heartbeat_path, flags, 0o600)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise OSError("dashboard heartbeat must be a regular file owned by the current user")
            os.fchmod(descriptor, 0o600)
            os.ftruncate(descriptor, 0)
            os.utime(descriptor, None)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


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
            allowed = {"range", "from_date", "to_date", "source", "sources", "model", "models", "reset_type", "reset_offset", "reset_limit", "breakdown_offset"}
            if set(raw) - allowed:
                raise AnalyticsError("unknown query parameter")
            params = {key: values[0] for key, values in raw.items()}
            payload = build_payload(analytics_database, analytics_pricing, params)
        except (AnalyticsError, ValueError, OSError, sqlite3.DatabaseError) as error:
            status = 503 if error.__class__.__name__.endswith("UnavailableError") or "not available" in str(error) or "cannot be read" in str(error) else 400
            self.send_json(status, {"error": str(error)}, include_body=include_body)
            return
        self.send_json(200, payload, include_body=include_body)

    def do_GET(self):
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics()
            return
        super().do_GET()

    def do_POST(self):
        request_path = unquote(urlsplit(self.path).path)
        if request_path != "/api/dashboard-heartbeat":
            self.send_error(404, "Not found")
            return
        if self.headers.get("X-Codex-Dashboard-Activity") != "visible":
            self.send_json(403, {"error": "dashboard activity header is required"})
            return
        raw_content_length = self.headers.get("Content-Length", "0")
        try:
            content_length = int(raw_content_length)
        except ValueError:
            self.send_json(400, {"error": "request body must be empty"})
            return
        if content_length != 0 or self.headers.get("Transfer-Encoding") is not None:
            self.send_json(400, {"error": "request body must be empty"})
            return
        try:
            record_dashboard_heartbeat()
        except OSError:
            self.send_json(503, {"error": "dashboard activity cannot be recorded"})
            return
        self.send_response(204)
        self.send_header("X-Codex-Dashboard-Interval-Seconds", str(dashboard_active_interval))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics(include_body=False)
            return
        super().do_HEAD()

    def send_runtime_file(self, path):
        descriptor = -1
        try:
            descriptor = os.open(
                path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            )
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise OSError("runtime file is not a service-owned regular file")
            source = os.fdopen(descriptor, "rb")
            descriptor = -1
        except FileNotFoundError:
            self.send_error(404, "Not found")
            return None
        except OSError:
            self.send_error(404, "Not found")
            return None
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        self.send_response(200)
        self.send_header("Content-type", self.guess_type(str(path)))
        self.send_header("Content-Length", str(metadata.st_size))
        self.send_header("Last-Modified", self.date_time_string(metadata.st_mtime))
        self.end_headers()
        return source

    def send_head(self):
        request_path = unquote(urlsplit(self.path).path)
        if request_path == "/":
            request_path = "/dashboard.html"
        runtime_path = runtime_files.get(request_path)
        if runtime_path is not None:
            return self.send_runtime_file(runtime_path)
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
    prepare_runtime_directory()
except OSError as error:
    print(f"[ERROR] Unable to prepare dashboard runtime: {error}", file=sys.stderr)
    raise SystemExit(1)
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
