#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
SPEC = importlib.util.spec_from_file_location("anomalies", ROOT / "local" / "anomalies.py")
anomalies = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(anomalies)
import storage  # noqa: E402
import archive  # noqa: E402
import alerts  # noqa: E402


def snapshot(epoch, *, five=50, weekly=50, five_reset=10_000,
             weekly_reset=10_000, limit="group-a"):
    return {
        "scraped_at_epoch": epoch, "five_h_pct": five, "weekly_pct": weekly,
        "five_h_reset_at": five_reset, "weekly_reset_at": weekly_reset,
        "limit_id": limit,
    }


class AnomalyDetectorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.connection = storage.connect_database(pathlib.Path(self.directory.name) / "archive.sqlite3")

    def tearDown(self):
        self.connection.close()
        self.directory.cleanup()

    def observe(self, value):
        with self.connection:
            anomalies.process_snapshot(self.connection, value)

    def rows(self, window=None):
        query = "SELECT anomaly_type, window, before_pct, after_pct FROM quota_anomalies"
        args = ()
        if window:
            query += " WHERE window = ?"
            args = (window,)
        return self.connection.execute(query, args).fetchall()

    def test_quota_increase_is_tolerated_and_deduplicated_until_stable(self):
        self.observe(snapshot(100, five=50, weekly=50))
        self.observe(snapshot(200, five=54, weekly=50))
        self.assertEqual([], self.rows("5h"))
        self.observe(snapshot(300, five=60, weekly=50))
        self.observe(snapshot(400, five=70, weekly=50))
        self.assertEqual(1, len(self.rows("5h")))
        self.observe(snapshot(500, five=70, weekly=50))
        self.observe(snapshot(600, five=80, weekly=50))
        self.assertEqual(2, len(self.rows("5h")))

    def test_planned_and_recognized_weekly_resets_are_excluded(self):
        self.observe(snapshot(100, five=50, weekly=40, five_reset=150, weekly_reset=1_000))
        self.observe(snapshot(200, five=90, weekly=40, five_reset=2_000, weekly_reset=1_000))
        self.observe(snapshot(300, five=90, weekly=40, five_reset=2_000, weekly_reset=1_000))
        self.observe(snapshot(400, five=90, weekly=100, five_reset=2_000,
                             weekly_reset=1_000 + 1_800 + 1))
        self.assertEqual([], self.rows())

    def test_full_five_hour_observed_reset_is_not_a_reset_shift(self):
        previous_deadline = 10_000
        self.observe(snapshot(100, five=100, five_reset=previous_deadline))
        self.observe(snapshot(200, five=100, five_reset=previous_deadline + 900))
        self.assertEqual([], self.rows("5h"))

    def test_weekly_quota_increase_is_reported_independently(self):
        self.observe(snapshot(100, five=50, weekly=40, weekly_reset=10_000))
        self.observe(snapshot(200, five=50, weekly=50, weekly_reset=10_000))
        self.assertEqual([
            ("quota_increase", "weekly", 40.0, 50.0),
        ], self.rows("weekly"))

    def test_missing_reset_requires_two_valid_observations(self):
        self.observe(snapshot(100, five=50, weekly=50))
        self.observe(snapshot(200, five=50, weekly=50, five_reset=None, weekly_reset=None))
        self.assertEqual([], self.rows())
        self.observe(snapshot(300, five=50, weekly=50, five_reset=None, weekly_reset=None))
        self.assertEqual(2, len(self.rows()))
        self.observe(snapshot(400, five=50, weekly=50, five_reset=None, weekly_reset=None))
        self.assertEqual(2, len(self.rows()))

    def test_oscillation_is_one_episode_and_restarts_after_stabilization(self):
        for epoch, reset in ((100, 1_000), (200, 3_000), (300, 1_000),
                             (400, 1_000), (500, 1_000), (600, 3_000),
                             (700, 1_000)):
            self.observe(snapshot(epoch, five_reset=reset, weekly_reset=reset))
        self.assertEqual(2, len([row for row in self.rows("5h") if row[0] == "reset_oscillation"]))

    def test_short_oscillations_are_ignored_without_blocking_later_alerts(self):
        first = 1_700_000_000
        for epoch, reset in (
            (100, first), (200, first + 1), (300, first),
            (400, first + 179), (500, first),
        ):
            self.observe(snapshot(epoch, five_reset=reset, weekly_reset=reset))
        self.assertEqual([], [row for row in self.rows()
                              if row[0] == "reset_oscillation"])

        # The threshold is inclusive: exactly three minutes is reportable.
        for epoch, reset in ((600, first + 180), (700, first)):
            self.observe(snapshot(epoch, five_reset=reset, weekly_reset=reset))
        self.assertEqual(2, len([row for row in self.rows()
                                 if row[0] == "reset_oscillation"]))

    def test_oscillation_message_formats_reset_dates_as_utc(self):
        first = 1_700_000_000
        for epoch, reset in ((100, first), (200, first + 300), (300, first)):
            self.observe(snapshot(epoch, five_reset=reset, weekly_reset=reset))
        messages = self.connection.execute(
            "SELECT window, message FROM quota_anomalies "
            "WHERE anomaly_type = 'reset_oscillation' ORDER BY window"
        ).fetchall()
        self.assertEqual(2, len(messages))
        for window, message in messages:
            with self.subTest(window=window):
                self.assertIn("14/11/2023 - 22:13", message)
                self.assertIn("14/11/2023 - 22:18", message)
                self.assertNotIn(str(first), message)
                self.assertNotIn(str(first + 300), message)

    def test_limit_change_starts_a_baseline(self):
        self.observe(snapshot(100, five=20, limit="group-a"))
        self.observe(snapshot(200, five=90, limit="group-b"))
        self.assertEqual([], self.rows())

    def test_returning_limit_group_resumes_its_segmented_baseline(self):
        self.observe(snapshot(100, five=50, weekly=60, limit="group-a"))
        self.observe(snapshot(200, five=50, weekly=60, limit="group-b"))
        self.observe(snapshot(300, five=70, weekly=75, limit="group-a"))
        rows = self.connection.execute(
            "SELECT limit_id, window, before_pct, after_pct FROM quota_anomalies "
            "ORDER BY window"
        ).fetchall()
        canonical_group = storage.canonicalize_limit_id("group-a")
        self.assertEqual([
            (canonical_group, "5h", 50.0, 70.0),
            (canonical_group, "weekly", 60.0, 75.0),
        ], rows)
        self.assertEqual(2, self.connection.execute(
            "SELECT COUNT(*) FROM anomaly_detector_state WHERE limit_id = ?", (canonical_group,)
        ).fetchone()[0])

    def test_past_reset_is_recorded_with_before_after_values(self):
        self.observe(snapshot(100, five=50, five_reset=2_000))
        self.observe(snapshot(200, five=50, five_reset=100))
        row = self.connection.execute(
            "SELECT anomaly_type, before_pct, after_pct, before_reset_at, after_reset_at "
            "FROM quota_anomalies WHERE window = '5h'"
        ).fetchone()
        self.assertEqual(("reset_in_past", 50.0, 50.0, 2_000, 100), row)

    def test_isolated_reset_shift_is_explained(self):
        self.observe(snapshot(100, five=50, five_reset=5_000))
        self.observe(snapshot(200, five=50, five_reset=7_000))
        row = self.connection.execute(
            "SELECT anomaly_type, message FROM quota_anomalies WHERE window = '5h'"
        ).fetchone()
        self.assertEqual("reset_shift", row[0])
        self.assertIn("moved by 33 minutes", row[1])

    def test_mark_journaled_is_idempotent(self):
        self.observe(snapshot(100, five=50))
        self.observe(snapshot(200, five=60))
        anomaly_id = self.connection.execute(
            "SELECT anomaly_id FROM quota_anomalies WHERE window = '5h'"
        ).fetchone()[0]
        self.assertTrue(anomalies.mark_journaled(self.connection, anomaly_id, 300))
        self.assertFalse(anomalies.mark_journaled(self.connection, anomaly_id, 301))

    def test_parse_snapshot_rejects_non_finite_boolean_and_past_input(self):
        invalid = [
            {"scraped_at_epoch": float("nan"), "five_h_pct": 50},
            {"scraped_at_epoch": float("inf"), "five_h_pct": 50},
            {"scraped_at_epoch": 1e999, "five_h_pct": 50},
            {"scraped_at_epoch": True, "five_h_pct": 50},
            {"scraped_at_epoch": 100, "five_h_pct": float("nan")},
            {"scraped_at_epoch": 100, "weekly_pct": float("inf")},
            {"scraped_at": "1970-01-01T00:00:00Z", "five_h_pct": 50},
        ]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    anomalies._parse_snapshot(value)

    def test_cli_reports_invalid_input_without_traceback(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "local" / "anomalies.py"), "observe",
             "--database", str(pathlib.Path(self.directory.name) / "invalid.sqlite3")],
            input=json.dumps({"scraped_at_epoch": float("inf"), "five_h_pct": 50}),
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("anomalies:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_alert_registration_can_be_replayed_before_sqlite_ack(self):
        journal_path = pathlib.Path(self.directory.name) / "alerts.json"
        document = alerts.empty_journal(4, 100)
        request = {
            "kind": "anomaly", "window": "5h", "selector": "quota_increase",
            "cycle_key": "limit:group-a|anomaly:stable-id",
            "message": "quota rose without a reset",
            "event_data": {
                "limit_id": "group-a", "reset_epoch": 10_000,
                "before_pct": 40, "after_pct": 60,
                "before_reset_at": 10_000, "after_reset_at": 10_000,
                "detected_at_epoch": 200,
            },
            "created_at": 200, "expires_at": 0, "channels": ["discord"],
            "replace_pending_thresholds": False, "expire_threshold_cycle": None,
        }
        first = alerts.register(document, request)
        alerts.atomic_write(journal_path, document)
        replay = alerts.register(alerts.load(journal_path), request)
        self.assertEqual(first["alert_id"], replay["alert_id"])
        self.observe(snapshot(100, five=40))
        self.observe(snapshot(200, five=60))
        anomaly_id = self.connection.execute(
            "SELECT anomaly_id FROM quota_anomalies WHERE window = '5h'"
        ).fetchone()[0]
        self.assertTrue(anomalies.mark_journaled(self.connection, anomaly_id, 200))

    def test_retention_purges_journaled_anomalies_and_inactive_states(self):
        anchor = 200_000
        self.connection.execute(
            "INSERT INTO snapshots(scraped_at_epoch, scraped_at) VALUES (?, ?)",
            (anchor, "1970-01-03T07:33:20Z"),
        )
        self.connection.execute(
            "INSERT INTO metadata(key, value) VALUES ('anomaly_active_limit_id', 'active')"
        )
        self.connection.executemany(
            """
            INSERT INTO quota_anomalies(
                anomaly_id, dedupe_key, anomaly_type, window, limit_id,
                detected_at_epoch, before_pct, after_pct, message, journaled_at
            ) VALUES (?, ?, 'quota_increase', '5h', 'active', ?, 40, 60, 'movement', ?)
            """,
            [("old-journaled", "old-journaled-key", 100, 101),
             ("old-pending", "old-pending-key", 100, None)],
        )
        self.connection.executemany(
            "INSERT INTO anomaly_detector_state(limit_id, window, state_json, updated_at_epoch) "
            "VALUES (?, '5h', '{}', ?)",
            [("inactive", 100), ("active", 100)],
        )
        archive.compact(self.connection, 1)
        self.assertIsNone(self.connection.execute(
            "SELECT 1 FROM quota_anomalies WHERE anomaly_id = 'old-journaled'"
        ).fetchone())
        self.assertIsNotNone(self.connection.execute(
            "SELECT 1 FROM quota_anomalies WHERE anomaly_id = 'old-pending'"
        ).fetchone())
        self.assertIsNone(self.connection.execute(
            "SELECT 1 FROM anomaly_detector_state WHERE limit_id = 'inactive'"
        ).fetchone())
        self.assertIsNotNone(self.connection.execute(
            "SELECT 1 FROM anomaly_detector_state WHERE limit_id = 'active'"
        ).fetchone())

        # Unlimited retention keeps both derived events and state untouched.
        self.connection.execute(
            """
            INSERT INTO quota_anomalies(
                anomaly_id, dedupe_key, anomaly_type, window, limit_id,
                detected_at_epoch, before_pct, after_pct, message, journaled_at
            ) VALUES ('unlimited', 'unlimited-key', 'quota_increase', '5h',
                      'active', 100, 40, 60, 'movement', 101)
            """
        )
        self.connection.execute(
            "INSERT INTO anomaly_detector_state(limit_id, window, state_json, updated_at_epoch) "
            "VALUES ('inactive-old', '5h', '{}', 100)"
        )
        archive.compact(self.connection, 0)
        self.assertIsNotNone(self.connection.execute(
            "SELECT 1 FROM quota_anomalies WHERE anomaly_id = 'unlimited'"
        ).fetchone())
        self.assertIsNotNone(self.connection.execute(
            "SELECT 1 FROM anomaly_detector_state WHERE limit_id = 'inactive-old'"
        ).fetchone())


if __name__ == "__main__":
    unittest.main()
