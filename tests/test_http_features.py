import functools
import gzip
import json
import pathlib
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "local"))
import http_server
import storage


class QuietHandler(http_server.DashboardHandler):
    def log_message(self, *_args):
        pass


class HttpFeatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = pathlib.Path(cls.directory.name)
        (cls.root / "assets").mkdir()
        (cls.root / "dashboard.html").write_text("<!doctype html><h1>Dashboard</h1>")
        (cls.root / "assets" / "dashboard.css").write_text("/* CSS */\n" * 1000)
        cls.runtime = cls.root / "runtime"
        cls.runtime.mkdir(mode=0o700)
        (cls.runtime / "data.json").write_text(json.dumps({"example": "value " * 2000}))
        (cls.runtime / "health.json").write_text(json.dumps({"last_cycle": "2026-10-01T00:00:00Z", "last_cycle_result": "failed", "last_error": {"message": "SECRET-CREDENTIAL /private/path"}}))
        cls.database = cls.runtime / "history.sqlite3"
        now = int(time.time())
        with storage.connect_database(cls.database) as connection:
            for index in range(65):
                connection.execute("INSERT INTO token_usage_events(source,provider,model,occurred_at_epoch,input_tokens,output_tokens,quality,external_id) VALUES ('codex','test',?,?,100,2,'exact',?)", (f"model-{index}", now - 60, f"event-{index}"))
        pricing = pathlib.Path(__file__).resolve().parents[1] / "local" / "pricing.json"
        http_server.configure([str(cls.root), "0", "127.0.0.1", str(cls.database), str(pricing), "300", str(cls.runtime)])
        cls.server = http_server.BoundedThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(cls.root)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.directory.cleanup()

    def request(self, path, headers=None, method="GET"):
        request = urllib.request.Request(self.url + path, headers=headers or {}, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as response:
            with response:
                return response.code, response.headers, response.read()
        with response:
            return response.status, response.headers, response.read()

    def test_static_etag_revalidation_and_immediate_invalidation(self):
        path = "/assets/dashboard.css"
        status, headers, body = self.request(path)
        self.assertEqual(status, 200)
        self.assertIn("must-revalidate", headers["Cache-Control"])
        etag = headers["ETag"]
        self.assertEqual(self.request(path, {"If-None-Match": 'W/' + etag})[0], 304)
        (self.root / "assets" / "dashboard.css").write_bytes(body + b"\n/* changed */")
        status, changed, _body = self.request(path, {"If-None-Match": etag})
        self.assertEqual(status, 200)
        self.assertNotEqual(changed["ETag"], etag)

    def test_compression_negotiation_and_head_match(self):
        path = "/assets/dashboard.css"
        status, headers, body = self.request(path, {"Accept-Encoding": "gzip"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Encoding"], "gzip")
        self.assertIn(b"CSS", gzip.decompress(body))
        status, head, head_body = self.request(path, {"Accept-Encoding": "gzip"}, "HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(head["Content-Length"], headers["Content-Length"])
        self.assertEqual(head_body, b"")
        self.assertIsNone(self.request(path, {"Accept-Encoding": "gzip;q=0, *;q=1"})[1].get("Content-Encoding"))
        self.assertIsNone(self.request(path, {"Accept-Encoding": "gzip;q=NaN"})[1].get("Content-Encoding"))

    def test_private_runtime_json_is_compressed_and_never_cached(self):
        status, headers, body = self.request("/data.json", {"Accept-Encoding": "gzip", "If-None-Match": "*"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Content-Encoding"], "gzip")
        self.assertIsNone(headers.get("ETag"))
        self.assertIn("example", json.loads(gzip.decompress(body)))

    def test_component_api_and_csv_export_ignore_page_offset(self):
        status, headers, body = self.request("/api/analytics?range=24h&sections=base&compare=previous&timezone=UTC")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertIn("comparison", data)
        self.assertNotIn("weekly_limit_value", data)
        self.assertIn("Server-Timing", headers)
        self.assertEqual(headers["Cache-Control"], "no-store")
        status, headers, body = self.request("/api/analytics.csv?dataset=breakdown&range=24h&breakdown_offset=50")
        self.assertEqual(status, 200)
        self.assertIn("attachment", headers["Content-Disposition"])
        self.assertEqual(len(body.decode("utf-8-sig").splitlines()), 66)

    def test_diagnostics_never_expose_raw_state_or_credentials(self):
        status, headers, body = self.request("/api/diagnostics")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn(b"SECRET-CREDENTIAL", body)
        self.assertNotIn(b"/private/path", body)
        self.assertEqual(json.loads(body)["archive"]["token_events"], 65)

    def test_invalid_queries_and_nonpublic_files_are_rejected(self):
        for path in ["/api/analytics?sections=secret", "/api/analytics?range=7d&range=24h", "/api/analytics.csv?dataset=secret", "/api/analytics?unknown=value"]:
            self.assertEqual(self.request(path)[0], 400, path)
        for path in ["/http_server.py", "/backup.py", "/runtime/health.json", "/runtime/history.sqlite3", "/../monitor.sh"]:
            self.assertEqual(self.request(path)[0], 404, path)


if __name__ == "__main__":
    unittest.main()
