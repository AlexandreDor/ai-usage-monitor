#!/usr/bin/env python3

import contextlib
import datetime as dt
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local"
import sys

sys.path.insert(0, str(LOCAL))
import codex_status


class CodexStatusTests(unittest.TestCase):
    def fixture(self, name):
        return json.loads(
            (ROOT / "tests" / "fixtures" / "codex" / name).read_text(
                encoding="utf-8"
            )
        )

    def test_existing_fixture_keeps_coherent_group_and_json_contract(self):
        now = dt.datetime(2026, 8, 9, 12, 0, tzinfo=dt.timezone.utc)
        payload, warning = codex_status.build_payload(
            self.fixture("multi-id.json"), 900, 192.0, now=now
        )
        self.assertIsNone(warning)
        self.assertEqual("coherent", payload["limit_id"])
        self.assertEqual(79.75, payload["five_h_pct"])
        self.assertEqual(4.5, payload["weekly_pct"])
        self.assertEqual("18/05/2033 05:33", payload["five_h_reset"])
        self.assertEqual("25/05/2033 04:13", payload["weekly_reset"])
        self.assertEqual("2026-08-09T12:00:00Z", payload["scraped_at"])
        self.assertEqual(
            {
                "five_h_pct",
                "five_h_reset",
                "five_h_reset_at",
                "weekly_pct",
                "weekly_reset",
                "weekly_reset_at",
                "limit_id",
                "scraped_at",
                "sample_interval_seconds",
                "history_window_hours",
            },
            set(payload),
        )

    def test_partial_fixture_warns_without_fabricating_window(self):
        payload, warning = codex_status.build_payload(
            self.fixture("partial.json"), 900, 192.0
        )
        self.assertIn("partial limit group", warning)
        self.assertEqual("partial", payload["limit_id"])
        self.assertIsNone(payload["weekly_pct"])
        self.assertEqual("unknown", payload["weekly_reset"])
        self.assertIsNone(payload["weekly_reset_at"])

    def test_unknown_fixture_is_rejected_with_existing_error(self):
        with self.assertRaisesRegex(
            codex_status.CodexStatusError,
            "Codex returned no valid recognized usage window",
        ):
            codex_status.build_payload(self.fixture("unknown.json"), 900, 192.0)

    def test_fragmented_protocol_response_is_reassembled(self):
        with tempfile.TemporaryDirectory() as temporary:
            server = self.write_server(Path(temporary))
            environment = dict(os.environ, FAKE_CODEX_MODE="fragmented")
            result, diagnostic, _ = codex_status.read_rate_limits(
                str(server), 1.0, environ=environment
            )
        self.assertEqual("fragmented", result["rateLimits"]["limitId"])
        self.assertEqual(b"", diagnostic)

    def test_initialize_uses_release_version_and_child_has_no_delivery_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            server = self.write_server(directory)
            capture = directory / "initialize.json"
            environment = dict(
                os.environ,
                FAKE_CODEX_MODE="capture",
                FAKE_CAPTURE=str(capture),
                TELEGRAM_CHAT_ID="telegram-private-id",
                GITHUB_GIST_ID="gist-private-id",
            )
            codex_status.read_rate_limits(str(server), 1.0, environ=environment)
            captured = json.loads(capture.read_text(encoding="utf-8"))
        self.assertEqual(
            (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
            captured["initialize"]["params"]["clientInfo"]["version"],
        )
        self.assertNotIn("TELEGRAM_CHAT_ID", captured["environment"])
        self.assertNotIn("GITHUB_GIST_ID", captured["environment"])

    def test_stdout_without_newline_is_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            server = self.write_server(Path(temporary))
            environment = dict(os.environ, FAKE_CODEX_MODE="stdout-flood")
            started = time.monotonic()
            with self.assertRaises(codex_status.CodexStatusError):
                codex_status.read_rate_limits(str(server), 1.0, environ=environment)
        self.assertLess(time.monotonic() - started, 1.5)

    def test_timeout_is_strict_and_debug_diagnostic_is_bounded_and_redacted(self):
        secret = "private-value-that-must-not-leak"
        with tempfile.TemporaryDirectory() as temporary:
            server = self.write_server(Path(temporary))
            environment = dict(
                os.environ,
                FAKE_CODEX_MODE="timeout",
                FAKE_VISIBLE_SECRET=secret,
                GITHUB_PAT=secret,
            )
            stderr = io.StringIO()
            started = time.monotonic()
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(codex_status.CodexStatusError):
                    codex_status.collect_status(
                        str(server),
                        0.15,
                        900,
                        192.0,
                        debug=True,
                        environ=environment,
                    )
            elapsed = time.monotonic() - started
        output = stderr.getvalue()
        self.assertLess(elapsed, 1.5)
        self.assertIn("[ERROR] Codex app-server did not return usage limits.", output)
        self.assertIn("[REDACTED]", output)
        self.assertNotIn(secret, output)
        diagnostic = output.split("[DEBUG] Codex diagnostic: ", 1)[1].rstrip("\n")
        self.assertLessEqual(len(diagnostic), codex_status.DIAGNOSTIC_LIMIT)

    def write_server(self, directory):
        server = directory / "fake-codex.py"
        server.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys
import time

mode = os.environ["FAKE_CODEX_MODE"]
initialize_line = sys.stdin.readline()
if mode == "timeout":
    secret = os.environ["FAKE_VISIBLE_SECRET"]
    sys.stderr.write("diagnostic=" + secret + ":" + "x" * 6000)
    sys.stderr.flush()
    sys.stdout.write('{"id":')
    sys.stdout.flush()
    time.sleep(5)
    raise SystemExit
if mode == "stdout-flood":
    os.write(sys.stdout.fileno(), b"x" * 100000)
    time.sleep(5)
    raise SystemExit
if mode == "capture":
    with open(os.environ["FAKE_CAPTURE"], "w", encoding="utf-8") as stream:
        json.dump({
            "initialize": json.loads(initialize_line),
            "environment": dict(os.environ),
        }, stream)

initialize = b'{"id":1,"result":{}}\\n'
for chunk in (initialize[:5], initialize[5:13], initialize[13:]):
    os.write(sys.stdout.fileno(), chunk)
    time.sleep(0.01)
sys.stdin.readline()
sys.stdin.readline()
result = {
    "rateLimits": {
        "limitId": "fragmented",
        "primary": {"windowDurationMins": 300, "usedPercent": 10, "resetsAt": 2000000000},
        "secondary": {"windowDurationMins": 10080, "usedPercent": 20, "resetsAt": 2000001000},
    }
}
response = (json.dumps({"id": 2, "result": result}) + "\\n").encode()
for index in range(0, len(response), 7):
    os.write(sys.stdout.fileno(), response[index:index + 7])
    time.sleep(0.002)
""",
            encoding="utf-8",
        )
        server.chmod(0o700)
        return server


if __name__ == "__main__":
    unittest.main()
