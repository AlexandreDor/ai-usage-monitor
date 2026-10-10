#!/usr/bin/env python3
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import diagnostics
import storage


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runtime = pathlib.Path(self.temporary.name)
        self.database = self.runtime / "archive.sqlite3"
        storage.connect_database(self.database).close()
        self.health = self.runtime / "health.json"
        self.write_health({
            "last_cycle": "2023-11-14T22:13:20Z", "last_success": "2023-11-14T22:13:20Z",
            "last_cycle_result": "success", "last_cycle_interval_seconds": 900,
            "last_cycle_duration_ms": 125, "consecutive_failures": 0,
        })

    def tearDown(self):
        self.temporary.cleanup()

    def write_health(self, value):
        self.health.write_text(json.dumps(value), encoding="utf-8")
        self.health.chmod(0o600)

    def build(self, **kwargs):
        return diagnostics.build_diagnostics(self.runtime, self.database, now=1_700_000_010, **kwargs)

    def test_healthy_fields_and_archive_read_only(self):
        before = self.database.read_bytes()
        value = self.build()
        self.assertEqual("healthy", value["monitor"]["status"])
        self.assertEqual(10, value["monitor"]["age_seconds"])
        self.assertEqual(125, value["monitor"]["last_cycle_duration_ms"])
        self.assertEqual("healthy", value["archive"]["status"])
        self.assertEqual(0, value["archive"]["snapshots"])
        self.assertEqual([], value["warnings"])
        self.assertEqual(before, self.database.read_bytes())

    def test_raw_errors_account_ids_paths_and_unknown_fields_never_leak(self):
        secret = "secret-account-token-/home/private/config.env"
        self.write_health({
            "last_cycle": "2023-11-14T22:13:20Z", "last_cycle_result": secret,
            "last_cycle_duration_ms": secret, "last_success": secret,
            "last_cycle_interval_seconds": secret, "consecutive_failures": secret,
            "last_error": {"at": "2023-11-14T22:13:20Z", "message": secret},
            "configuration": {"token": secret}, "path": secret,
        })
        value = self.build()
        self.assertNotIn(secret, json.dumps(value))
        self.assertEqual("degraded", value["monitor"]["status"])
        self.assertEqual("collection_failed", value["monitor"]["error_code"])
        self.assertEqual("Collection or alert delivery failed.", value["monitor"]["error_message"])

    def test_exact_known_error_is_translated(self):
        self.write_health({"last_error": {"message": "alert state persistence failed"}})
        self.assertEqual("alert_state_failed", self.build()["monitor"]["error_code"])
        self.write_health({"last_error": {"message": "alert state persistence failed secret-token"}})
        self.assertEqual("collection_failed", self.build()["monitor"]["error_code"])

    def test_numeric_and_timestamp_fields_are_validated(self):
        self.write_health({
            "last_cycle": "2023-99-01T00:00:00Z", "last_success": "2023-01-01T00:00:00Z-secret",
            "consecutive_failures": True, "last_cycle_duration_ms": -1,
            "last_cycle_interval_seconds": 2**100,
            "last_error": {"at": "2023-01-01T00:00:00Z\nsecret", "message": ["secret"]},
        })
        monitor = self.build()["monitor"]
        for key in ("last_cycle_at", "last_success_at", "consecutive_failures",
                    "last_cycle_duration_ms", "interval_seconds", "last_error_at"):
            self.assertIsNone(monitor[key])

    def test_stale_health_and_invalid_health_are_safe(self):
        value = diagnostics.build_diagnostics(self.runtime, self.database, now=1_700_010_000)
        self.assertEqual("stale", value["monitor"]["status"])
        self.assertIn("Monitor health is stale.", value["warnings"])
        for contents in ("{secret", "[]", "x" * (diagnostics.HEALTH_MAX_BYTES + 1),
                         "[" * 2000 + "]" * 2000):
            with self.subTest(contents=contents[:10]):
                self.health.write_text(contents)
                value = self.build()
                self.assertEqual("unavailable", value["monitor"]["status"])
                self.assertNotIn("secret", json.dumps(value))

    def test_health_symlink_fifo_and_unsafe_parent_are_rejected(self):
        other = self.runtime / "other"
        other.write_text(self.health.read_text())
        self.health.unlink()
        self.health.symlink_to(other)
        self.assertEqual("unavailable", self.build()["monitor"]["status"])
        self.health.unlink()
        os.mkfifo(self.health)
        self.assertEqual("unavailable", self.build()["monitor"]["status"])
        self.health.unlink()
        self.write_health({"last_cycle": "2023-11-14T22:13:20Z"})
        self.runtime.chmod(0o777)
        self.assertEqual("unavailable", self.build()["monitor"]["status"])
        self.runtime.chmod(0o700)

    def test_symlink_ancestor_is_rejected(self):
        link = self.runtime / "link"
        link.symlink_to(self.runtime, target_is_directory=True)
        value = diagnostics.build_diagnostics(link, link / self.database.name)
        self.assertEqual("unavailable", value["monitor"]["status"])
        self.assertEqual("unavailable", value["archive"]["status"])

    def test_unowned_health_is_rejected(self):
        with mock.patch("operations.os.geteuid", return_value=os.geteuid() + 1):
            value = self.build()
        self.assertEqual("unavailable", value["monitor"]["status"])

    def test_unavailable_and_corrupt_archive_never_return_paths_or_errors(self):
        self.database.unlink()
        value = self.build()
        self.assertEqual("unavailable", value["archive"]["status"])
        self.database.write_bytes(b"this is a secret corrupt database")
        self.database.chmod(0o600)
        value = self.build()
        self.assertEqual("unhealthy", value["archive"]["status"])
        self.assertNotIn("secret", json.dumps(value))
        self.assertNotIn(str(self.runtime), json.dumps(value))

    def test_archive_counts_and_latest_twenty_anomalies_are_sanitized(self):
        with closing(storage.connect_database(self.database)) as connection, connection:
            connection.execute("INSERT INTO snapshots (scraped_at_epoch,scraped_at) VALUES (?,?)",
                               (1_700_000_000, "secret"))
            for index in range(25):
                connection.execute(
                    "INSERT INTO quota_anomalies VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    (f"secret-id-{index}", f"secret-dedupe-{index}", "quota_increase", "5h",
                     "secret-limit", 1_700_000_000 + index, 20, 80, None, None,
                     "secret-message", None if index < 5 else 1_700_000_100),
                )
        value = self.build()
        self.assertEqual(1, value["archive"]["snapshots"])
        self.assertEqual(25, value["archive"]["anomalies"])
        self.assertEqual(5, value["archive"]["pending_anomalies"])
        self.assertEqual("2023-11-14T22:13:20Z", value["archive"]["last_snapshot_at"])
        self.assertEqual(20, len(value["anomalies"]))
        self.assertEqual("2023-11-14T22:13:44Z", value["anomalies"][0]["detected_at"])
        self.assertEqual({"window", "type", "detected_at", "before_pct", "after_pct"},
                         set(value["anomalies"][0]))
        self.assertNotIn("secret", json.dumps(value))
        json.dumps(value, allow_nan=False)

    def test_archive_schema_error_is_unhealthy(self):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("DROP TABLE quota_anomalies")
        self.assertEqual("unhealthy", self.build()["archive"]["status"])


if __name__ == "__main__":
    unittest.main()
