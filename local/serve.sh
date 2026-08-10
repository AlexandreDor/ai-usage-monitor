#!/usr/bin/env bash
# Serve only explicitly allowlisted dashboard files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8080
BIND_ADDRESS="127.0.0.1"
POSITIONAL_PORT=""
PORT_WAS_NAMED=false
CONFIG_PATH=""
CONFIG_REQUIRED=false
STATE_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: ./serve.sh [--port PORT] [--bind ADDRESS] [PATH OPTIONS]
       ./serve.sh [PORT]

Serve the local Codex usage dashboard.

Options:
  --port PORT      TCP port (1-65535, default: 8080)
  --bind ADDRESS   IP address to listen on (default: 127.0.0.1)
                   Use --bind 0.0.0.0 explicitly to allow LAN access.
  --config FILE    Read configuration from FILE
  --state-dir DIR  Read dashboard state from DIR
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
    --config)
      (($# >= 2)) || { echo "[ERROR] --config requires a value." >&2; exit 2; }
      CONFIG_PATH="$2"
      CONFIG_REQUIRED=true
      shift 2
      ;;
    --state-dir)
      (($# >= 2)) || { echo "[ERROR] --state-dir requires a value." >&2; exit 2; }
      STATE_OVERRIDE="$2"
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

resolver_arguments=(--base-dir "$SCRIPT_DIR" --profile serve)
if [[ -n "$CONFIG_PATH" ]]; then
  resolver_arguments+=(--config "$CONFIG_PATH")
  [[ "$CONFIG_REQUIRED" == false ]] || resolver_arguments+=(--config-required)
fi
[[ -z "$STATE_OVERRIDE" ]] || resolver_arguments+=(--set "STATE_DIR=${STATE_OVERRIDE}")
config_output="$(mktemp)" || { echo "[ERROR] Could not create a temporary configuration buffer." >&2; exit 2; }
chmod 600 "$config_output"
status=0
read_error=""
python3 "$SCRIPT_DIR/config.py" "${resolver_arguments[@]}" > "$config_output" || status=$?
if (( status != 0 )); then
  rm -f "$config_output"
  exit 2
fi
while IFS= read -r -d '' config_key; do
  if ! IFS= read -r -d '' config_value; then
    read_error="Configuration resolver returned an incomplete record."
    break
  fi
  case "$config_key" in
    STATE_DIR|DASHBOARD_ANALYTICS_DATABASE|TOKEN_PRICING_FILE)
      printf -v "$config_key" '%s' "$config_value"
      ;;
    *)
      read_error="Configuration resolver returned an unexpected key."
      break
      ;;
  esac
done < "$config_output"
rm -f "$config_output"
if [[ -n "$read_error" ]]; then
  echo "[ERROR] $read_error" >&2
  exit 2
fi
ANALYTICS_DATABASE_PATH="$DASHBOARD_ANALYTICS_DATABASE"
ANALYTICS_PRICING_PATH="$TOKEN_PRICING_FILE"

if [[ "$ANALYTICS_DATABASE_PATH" != /* ]] || [[ -e "$ANALYTICS_DATABASE_PATH" && -L "$ANALYTICS_DATABASE_PATH" ]]; then
  echo "[ERROR] DASHBOARD_ANALYTICS_DATABASE must be an absolute path and not a symbolic link." >&2
  exit 2
fi

if [[ "$ANALYTICS_PRICING_PATH" != /* ]] || [[ ! -f "$ANALYTICS_PRICING_PATH" || ! -r "$ANALYTICS_PRICING_PATH" || -L "$ANALYTICS_PRICING_PATH" ]]; then
  echo "[ERROR] TOKEN_PRICING_FILE must be an absolute readable regular file and not a symbolic link." >&2
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

python3 - "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" "$ANALYTICS_DATABASE_PATH" "$ANALYTICS_PRICING_PATH" "$STATE_DIR" <<'PYEOF'
import functools
import http.server
import ipaddress
import mimetypes
import os
import pathlib
import socket
import socketserver
import sqlite3
import stat
import sys
import threading
from urllib.parse import parse_qs, unquote, urlsplit

sys.path.insert(0, str(pathlib.Path(sys.argv[1]).resolve()))
from analytics import AnalyticsError, build_payload

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
bind_address = sys.argv[3]
analytics_database = pathlib.Path(sys.argv[4])
analytics_pricing = pathlib.Path(sys.argv[5])
state_root = pathlib.Path(sys.argv[6])
max_public_file_size = 32 * 1024 * 1024
socket_timeout_seconds = 5
public_files = {
    "/dashboard.html": root / "dashboard.html",
    "/analytics.html": root / "analytics.html",
    "/assets/dashboard.css": root / "assets/dashboard.css",
    "/assets/dashboard.js": root / "assets/dashboard.js",
    "/assets/preferences.js": root / "assets/preferences.js",
    "/assets/analytics.css": root / "assets/analytics.css",
    "/assets/analytics.js": root / "assets/analytics.js",
    "/assets/chart.umd.min.js": root / "assets/chart.umd.min.js",
    "/images/favicon.png": root / "images/favicon.png",
    "/data.json": state_root / "data.json",
    "/history.json": state_root / "history.json",
}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "CodexDashboard"
    sys_version = ""

    def valid_host(self):
        raw_host = self.headers.get("Host", "")
        if not raw_host or any(character.isspace() for character in raw_host):
            return False
        try:
            parsed = urlsplit(f"//{raw_host}")
            hostname = parsed.hostname
            request_port = parsed.port
        except ValueError:
            return False
        if (
            hostname is None
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.query
            or parsed.fragment
            or request_port != port
        ):
            return False
        if hostname.lower() == "localhost":
            return True
        try:
            address = ipaddress.ip_address(hostname)
            listening_address = ipaddress.ip_address(bind_address)
            local_address = ipaddress.ip_address(self.connection.getsockname()[0])
        except ValueError:
            return False
        return address.is_loopback or address in (listening_address, local_address)

    def reject_invalid_host(self):
        if self.valid_host():
            return False
        self.send_error(400)
        return True

    def send_error(self, code, message=None, explain=None):
        del message, explain
        phrase = self.responses.get(code, ("Error",))[0]
        body = f"{code} {phrase}\n".encode("ascii", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                pass
        self.close_connection = True

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
            allowed = {"range", "from_date", "to_date", "source", "sources", "model", "models", "reset_type", "reset_offset", "reset_limit", "breakdown_offset", "breakdown_limit"}
            if set(raw) - allowed:
                raise AnalyticsError("unknown query parameter")
            params = {key: values[0] for key, values in raw.items()}
            payload = build_payload(analytics_database, analytics_pricing, params)
        except (AnalyticsError, ValueError, OverflowError, OSError, sqlite3.DatabaseError) as error:
            status = 503 if error.__class__.__name__.endswith("UnavailableError") or "not available" in str(error) or "cannot be read" in str(error) else 400
            message = str(error).strip()[:200] or "request failed"
            self.send_json(status, {"error": message}, include_body=include_body)
            return
        self.send_json(200, payload, include_body=include_body)

    def do_GET(self):
        if self.reject_invalid_host():
            return
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics()
            return
        super().do_GET()

    def do_HEAD(self):
        if self.reject_invalid_host():
            return
        if unquote(urlsplit(self.path).path) == "/api/analytics":
            self.serve_analytics(include_body=False)
            return
        super().do_HEAD()

    def send_head(self):
        request_path = unquote(urlsplit(self.path).path)
        if request_path == "/":
            request_path = "/dashboard.html"
        if request_path not in public_files:
            self.send_error(404)
            return None
        path = public_files[request_path]
        descriptor = -1
        directory_descriptor = -1
        try:
            flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            if request_path in ("/data.json", "/history.json"):
                directory_flags = (
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                directory_descriptor = os.open(state_root, directory_flags)
                descriptor = os.open(path.name, flags, dir_fd=directory_descriptor)
            else:
                descriptor = os.open(path, flags)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > max_public_file_size:
                raise OSError("public file is not a bounded regular file")
            stream = os.fdopen(descriptor, "rb")
            descriptor = -1
        except OSError:
            if descriptor >= 0:
                os.close(descriptor)
            self.send_error(404)
            return None
        finally:
            if directory_descriptor >= 0:
                os.close(directory_descriptor)
        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(metadata.st_size))
        self.end_headers()
        self._response_bytes_remaining = metadata.st_size
        return stream

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_response_bytes_remaining", 0)
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)

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
        try:
            request.settimeout(socket_timeout_seconds)
        except OSError:
            self.shutdown_request(request)
            return
        if not self._worker_slots.acquire(blocking=False):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Content-Type: text/plain; charset=utf-8\r\n"
                    b"Content-Length: 24\r\n"
                    b"Connection: close\r\n\r\n"
                    b"503 Service Unavailable\n"
                )
            except OSError:
                pass
            self.shutdown_request(request)
            return
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

    def handle_error(self, request, client_address):
        del request
        print(f"[WARN] Request from {client_address[0]} failed.", file=sys.stderr)


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
