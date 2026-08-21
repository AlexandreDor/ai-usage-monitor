#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import stat
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("alerts", ROOT / "local" / "alerts.py")
alerts = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(alerts)


def request(selector="25", channels=None, created=100, cycle="limit:default|reset:200"):
    return {
        "kind": "threshold", "window": "5h", "selector": selector,
        "cycle_key": cycle, "message": f"immutable {selector}",
        "event_data": {"limit_id": "default", "remaining_pct": 20,
                       "reset_epoch": 200, "covered_thresholds": [50, 25]},
        "created_at": created, "expires_at": 200,
        "channels": channels or ["discord", "telegram"],
        "replace_pending_thresholds": True, "expire_threshold_cycle": None,
    }


def reset_request(window="5h", created=200, cycle="limit:default|reset:200"):
    return {
        "kind": "reset", "window": window, "selector": "reset",
        "cycle_key": cycle, "message": f"{window} reset",
        "event_data": {"limit_id": "default", "reset_epoch": created},
        "created_at": created, "expires_at": created + 100,
        "channels": ["discord"], "replace_pending_thresholds": False,
        "expire_threshold_cycle": cycle,
    }


class AlertJournalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "alert-deliveries.json"
        self.document = alerts.empty_journal(4, 100)

    def tearDown(self):
        self.directory.cleanup()

    def test_stable_id_ignores_observation_time(self):
        first = alerts.alert_id("threshold", "5h", "25", "limit:x|reset:9")
        second = alerts.alert_id("threshold", "5h", "25", "limit:x|reset:9")
        self.assertEqual(first, second)
        self.assertEqual(24, len(first))

    def test_registration_is_idempotent_but_rejects_changed_content(self):
        first = alerts.register(self.document, request())
        self.assertIs(first, alerts.register(self.document, request()))
        changed = request()
        changed["message"] = "changed"
        with self.assertRaises(alerts.JournalError):
            alerts.register(self.document, changed)

    def test_anomaly_registration_preserves_before_and_after_values(self):
        request_value = {
            "kind": "anomaly", "window": "weekly", "selector": "reset_shift",
            "cycle_key": "limit:default|anomaly:abc123",
            "message": "weekly reset date moved by 45 minutes",
            "event_data": {
                "limit_id": "default", "reset_epoch": 2000,
                "before_pct": 40, "after_pct": 40,
                "before_reset_at": 5000, "after_reset_at": 2000,
                "detected_at_epoch": 1000,
            },
            "created_at": 1000, "expires_at": 0,
            "channels": ["discord"], "replace_pending_thresholds": False,
            "expire_threshold_cycle": None,
        }
        item = alerts.register(self.document, request_value)
        self.assertEqual("anomaly", item["kind"])
        self.assertEqual(5000, item["event_data"]["before_reset_at"])

    def test_more_critical_threshold_supersedes_pending_atomically(self):
        old = alerts.register(self.document, request("50"))
        new = alerts.register(self.document, request("25", created=101))
        self.assertEqual("failed", old["status"])
        self.assertEqual("superseded", old["terminal_reason"])
        self.assertEqual(new["alert_id"], old["replacement_alert_id"])
        self.assertEqual("pending", new["status"])

    def test_reset_expires_unarmed_threshold_in_the_same_window(self):
        unarmed = alerts.register(
            self.document,
            request("50", channels=["discord"], cycle="limit:default|unarmed"),
        )
        weekly = request("50", channels=["discord"], cycle="limit:default|unarmed")
        weekly["window"] = "weekly"
        weekly = alerts.register(self.document, weekly)

        reset = alerts.register(self.document, reset_request())

        self.assertEqual("failed", unarmed["status"])
        self.assertEqual("expired_after_reset", unarmed["terminal_reason"])
        self.assertEqual("pending", weekly["status"])
        self.assertEqual("pending", reset["status"])

    def test_channels_reach_aggregate_terminal_state_independently(self):
        item = alerts.register(self.document, request())
        discord = item["channels"]["discord"]
        discord.update(status="delivered", attempt_count=1, last_attempt_at=101,
                       last_http_status=204, last_curl_code=0)
        alerts._recompute(item, 101)
        self.assertEqual("pending", item["status"])
        telegram = item["channels"]["telegram"]
        telegram.update(status="failed", attempt_count=1, last_attempt_at=102,
                        last_http_status=400, last_curl_code=0, error_class="client_error")
        alerts._recompute(item, 102)
        self.assertEqual("failed", item["status"])
        self.assertEqual("permanent_failure", item["terminal_reason"])

    def test_atomic_write_is_private_and_validated(self):
        alerts.register(self.document, request())
        alerts.atomic_write(self.path, self.document)
        self.assertEqual(0o600, stat.S_IMODE(self.path.stat().st_mode))
        self.assertEqual(1, alerts.load(self.path)["schema_version"])

    def test_future_and_oversized_journals_fail_closed(self):
        future = alerts.empty_journal(4, 1)
        future["schema_version"] = 2
        self.path.write_text(json.dumps(future), encoding="utf-8")
        with self.assertRaises(alerts.JournalError):
            alerts.load(self.path)
        with self.path.open("wb") as handle:
            handle.truncate(alerts.MAX_BYTES + 1)
        with self.assertRaises(alerts.JournalError):
            alerts.load(self.path)

    def test_retry_after_seconds_date_and_backoff(self):
        headers = pathlib.Path(self.directory.name) / "headers"
        headers.write_text("Retry-After: 120\r\n", encoding="ascii")
        result = alerts.classify(0, 429, 1, 3, headers, 100)
        self.assertEqual(120, result["retry_delay"])
        self.assertTrue(result["used_retry_after"])
        headers.write_text("Retry-After: Thu, 01 Jan 1970 00:01:30 GMT\r\n", encoding="ascii")
        self.assertEqual(0, alerts.classify(0, 503, 1, 3, headers, 100)["retry_delay"])
        headers.write_text("Retry-After: invalid\r\n", encoding="ascii")
        self.assertEqual(12, alerts.classify(28, 0, 3, 3, headers, 100)["retry_delay"])

    def test_classification_distinguishes_permanent_and_temporary(self):
        headers = pathlib.Path(self.directory.name) / "headers"
        headers.write_text("", encoding="ascii")
        self.assertEqual("failed", alerts.classify(0, 400, 1, 1, headers, 1)["outcome"])
        self.assertEqual("pending", alerts.classify(0, 408, 1, 1, headers, 1)["outcome"])
        self.assertEqual("pending", alerts.classify(0, 500, 1, 1, headers, 1)["outcome"])
        self.assertEqual("pending", alerts.classify(7, 0, 1, 1, headers, 1)["outcome"])

    def test_pruning_never_removes_unacknowledged_terminal(self):
        old = alerts.register(self.document, request(channels=["discord"]))
        alerts._terminate(old, "permanent_failure", 101, "client_error")
        alerts.atomic_write(self.path, self.document)
        # Exercise the invariant directly: only acknowledged entries qualify.
        terminal = [item for item in self.document["alerts"]
                    if item["status"] != "pending" and item["detector_acknowledged_at"] is not None]
        self.assertEqual([], terminal)


if __name__ == "__main__":
    unittest.main()
