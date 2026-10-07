"""Allowlisted local dashboard HTTP server (standard library only)."""

import functools
import gzip
import hashlib
import http.server
import json
import math
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

from analytics import AnalyticsError, build_payload

root = pathlib.Path(__file__).parent.resolve()
port = 8080
bind_address = "127.0.0.1"
analytics_database = root / "runtime" / "usage-history.sqlite3"
analytics_pricing = root / "pricing.json"
dashboard_active_interval = 300
runtime_directory = root / "runtime"
heartbeat_path = runtime_directory / "dashboard-heartbeat"


def configure(arguments):
    global root, port, bind_address, analytics_database, analytics_pricing
    global dashboard_active_interval, runtime_directory, heartbeat_path, runtime_files
    root = pathlib.Path(arguments[0]).resolve()
    port = int(arguments[1])
    bind_address = arguments[2]
    analytics_database = pathlib.Path(arguments[3])
    analytics_pricing = pathlib.Path(arguments[4])
    dashboard_active_interval = int(arguments[5])
    runtime_directory = pathlib.Path(arguments[6]).absolute()
    heartbeat_path = runtime_directory / "dashboard-heartbeat"
    runtime_files = {"/data.json": runtime_directory / "data.json", "/history.json": runtime_directory / "history.json"}


heartbeat_lock = threading.Lock()
heartbeat_coalesce_seconds = 5
static_cache = {}
static_cache_lock = threading.Lock()
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

    def accepts_gzip(self):
        qualities = {}
        for item in self.headers.get("Accept-Encoding", "").split(","):
            parts = [part.strip() for part in item.split(";")]
            encoding = parts[0].lower()
            quality = 1.0
            for option in parts[1:]:
                if option.lower().startswith("q="):
                    try:
                        quality = float(option[2:])
                    except ValueError:
                        quality = 0.0
            qualities[encoding] = quality if math.isfinite(quality) and 0 <= quality <= 1 else 0
        return qualities.get("gzip", qualities.get("*", 0)) > 0

    def send_bytes(self, status, body, content_type, *, include_body=True, public=False,
                   extra_headers=(), modified=None):
        self.cache_control = "public, max-age=0, must-revalidate" if public else "no-store"
        encoding = "gzip" if len(body) >= 1024 and self.accepts_gzip() else None
        if encoding:
            body = gzip.compress(body, compresslevel=6, mtime=0)
        etag = '"' + hashlib.sha256(body).hexdigest() + '"' if public else None
        if etag:
            validators = [value.strip().removeprefix("W/") for value in self.headers.get("If-None-Match", "").split(",")]
            if "*" in validators or etag in validators:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Vary", "Accept-Encoding")
                self.end_headers()
                return
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Vary", "Accept-Encoding")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        if etag:
            self.send_header("ETag", etag)
        if modified is not None:
            self.send_header("Last-Modified", self.date_time_string(modified))
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def send_json(self, status, value, *, include_body=True, extra_headers=()):
        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_bytes(status, body, "application/json; charset=utf-8", include_body=include_body,
                        extra_headers=extra_headers)

    def analytics_params(self, *, export=False):
        raw = parse_qs(urlsplit(self.path).query, keep_blank_values=True, max_num_fields=20)
        if any(len(values) != 1 for values in raw.values()):
            raise AnalyticsError("query parameters must not be repeated")
        allowed = {"range", "from_date", "to_date", "source", "sources", "model", "models",
                   "reset_type", "reset_offset", "reset_limit", "breakdown_offset", "sections",
                   "at", "timezone", "compare"}
        if export:
            allowed.add("dataset")
        if set(raw) - allowed:
            raise AnalyticsError("unknown query parameter")
        return {key: values[0] for key, values in raw.items()}

    def serve_analytics(self, *, include_body=True):
        started = time.perf_counter()
        try:
            params = self.analytics_params()
            payload = build_payload(analytics_database, analytics_pricing, params)
        except (AnalyticsError, ValueError, OSError, sqlite3.DatabaseError) as error:
            status = 503 if error.__class__.__name__.endswith("UnavailableError") or "not available" in str(error) or "cannot be read" in str(error) else 400
            self.send_json(status, {"error": str(error)}, include_body=include_body)
            return
        duration = (time.perf_counter() - started) * 1000
        self.send_json(200, payload, include_body=include_body,
                       extra_headers=(("Server-Timing", f"analytics;dur={duration:.1f}"),))

    def serve_export(self, *, include_body=True):
        from analytics_export import build_csv

        try:
            params = self.analytics_params(export=True)
            dataset = params.pop("dataset", "tokens")
            body = build_csv(analytics_database, analytics_pricing, params, dataset)
        except (AnalyticsError, ValueError, OSError, sqlite3.DatabaseError) as error:
            status = 503 if error.__class__.__name__.endswith("UnavailableError") or "not available" in str(error) or "cannot be read" in str(error) else 400
            self.send_json(status, {"error": str(error)}, include_body=include_body)
            return
        self.send_bytes(200, body, "text/csv; charset=utf-8", include_body=include_body,
                        extra_headers=(("Content-Disposition", f'attachment; filename="codex-analytics-{dataset}.csv"'),))

    def serve_diagnostics(self, *, include_body=True):
        from diagnostics import build_diagnostics

        self.send_json(200, build_diagnostics(runtime_directory, analytics_database),
                       include_body=include_body)

    def do_GET(self):
        self.cache_control = "no-store"
        path = unquote(urlsplit(self.path).path)
        if path == "/api/analytics":
            self.serve_analytics()
            return
        if path == "/api/analytics.csv":
            self.serve_export()
            return
        if path == "/api/diagnostics":
            self.serve_diagnostics()
            return
        super().do_GET()

    def do_POST(self):
        self.cache_control = "no-store"
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
        self.cache_control = "no-store"
        path = unquote(urlsplit(self.path).path)
        if path == "/api/analytics":
            self.serve_analytics(include_body=False)
            return
        if path == "/api/analytics.csv":
            self.serve_export(include_body=False)
            return
        if path == "/api/diagnostics":
            self.serve_diagnostics(include_body=False)
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
        with source:
            body = source.read()
        self.send_bytes(200, body, self.guess_type(str(path)),
                        include_body=self.command != "HEAD", modified=metadata.st_mtime)
        return None

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

        path = root / mapped_path.lstrip("/")
        try:
            metadata = path.stat()
            if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
                raise OSError("not a regular public file")
            key = (str(path), metadata.st_ino, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)
            with static_cache_lock:
                body = static_cache.get(key)
            if body is None:
                body = path.read_bytes()
                with static_cache_lock:
                    if len(static_cache) >= 32:
                        static_cache.clear()
                    static_cache[key] = body
        except OSError:
            self.send_error(404, "Not found")
            return None
        self.send_bytes(200, body, self.guess_type(str(path)), public=True,
                        include_body=self.command != "HEAD", modified=metadata.st_mtime)
        return None

    def end_headers(self):
        self.send_header("Cache-Control", getattr(self, "cache_control", "no-store"))
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

    def __init__(self, *args, max_workers=16, **kwargs):
        self.address_family = socket.AF_INET6 if ":" in args[0][0] else socket.AF_INET
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


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if len(arguments) != 7:
        print("[ERROR] Expected dashboard server configuration.", file=sys.stderr)
        return 2
    configure(arguments)
    handler = functools.partial(DashboardHandler, directory=str(root))
    try:
        prepare_runtime_directory()
    except OSError as error:
        print(f"[ERROR] Unable to prepare dashboard runtime: {error}", file=sys.stderr)
        return 1
    try:
        server = BoundedThreadingHTTPServer((bind_address, port), handler)
    except OSError as error:
        print(f"[ERROR] Unable to listen on {bind_address}:{port}: {error}", file=sys.stderr)
        return 1

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
