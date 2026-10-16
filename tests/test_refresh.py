import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "local"))
import refresh


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name)
        self.now = 1786622400

    def snapshot(self, five_h=None, weekly=None, sampled=None, limit="account"):
        from datetime import datetime, timezone

        refresh.write_json(self.runtime / "data.json", {
            "limit_id": limit,
            "five_h_reset_at": five_h,
            "weekly_reset_at": weekly,
            "scraped_at": datetime.fromtimestamp(sampled or self.now, timezone.utc).isoformat(),
        })

    def test_both_resets_fire_after_30_seconds_and_are_not_replayed(self):
        self.snapshot(self.now + 10, self.now + 20)
        self.assertEqual(refresh.plan(self.runtime, self.now), ("-", 40))
        self.assertEqual(refresh.plan(self.runtime, self.now + 39), ("-", 1))
        self.assertEqual(refresh.plan(self.runtime, self.now + 40), ("-", 0))
        refresh.complete(self.runtime, "-", 0, self.now + 40)
        self.assertEqual(refresh.plan(self.runtime, self.now + 40), ("-", 10))
        refresh.complete(self.runtime, "-", 0, self.now + 50)
        self.assertEqual(refresh.plan(self.runtime, self.now + 51), ("-", 86400))

    def test_pending_reset_survives_sparse_or_advanced_snapshot_and_restart(self):
        self.snapshot(self.now + 10)
        refresh.plan(self.runtime, self.now)
        self.snapshot(self.now + 18000, sampled=self.now + 15)
        self.assertEqual(refresh.plan(self.runtime, self.now + 20), ("-", 20))
        self.snapshot(sampled=self.now + 25)
        self.assertEqual(refresh.plan(self.runtime, self.now + 40), ("-", 0))

    def test_collection_after_deadline_satisfies_pending_reset(self):
        self.snapshot(self.now + 10)
        refresh.plan(self.runtime, self.now)
        self.snapshot(sampled=self.now + 40)
        self.assertEqual(refresh.plan(self.runtime, self.now + 41), ("-", 86400))

    def test_updated_future_estimate_replaces_the_previous_deadline(self):
        self.snapshot(self.now + 100)
        refresh.plan(self.runtime, self.now)
        self.snapshot(self.now + 200)
        self.assertEqual(refresh.plan(self.runtime, self.now), ("-", 230))

    def test_coincident_resets_share_check_and_failure_retries(self):
        self.snapshot(self.now, self.now)
        refresh.plan(self.runtime, self.now)
        refresh.complete(self.runtime, "-", 1, self.now + 30)
        self.assertEqual(refresh.plan(self.runtime, self.now + 31), ("-", 29))
        self.assertEqual(refresh.plan(self.runtime, self.now + 60), ("-", 0))
        refresh.complete(self.runtime, "-", 0, self.now + 60)
        self.assertEqual(refresh.plan(self.runtime, self.now + 61), ("-", 86400))

    def test_slow_failure_retries_30_seconds_after_completion(self):
        self.snapshot(self.now)
        refresh.plan(self.runtime, self.now)
        refresh.complete(self.runtime, "-", 1, self.now + 70, self.now + 30)
        self.assertEqual(refresh.plan(self.runtime, self.now + 70), ("-", 30))
        self.assertEqual(refresh.plan(self.runtime, self.now + 100), ("-", 0))

    def test_slow_delivery_does_not_satisfy_a_later_reset(self):
        self.snapshot(self.now + 10)
        refresh.plan(self.runtime, self.now)
        refresh.complete(self.runtime, "-", 0, self.now + 70, self.now + 30)
        self.assertEqual(refresh.plan(self.runtime, self.now + 70), ("-", 0))

    def test_pending_checks_survive_advanced_snapshot_and_report_retry(self):
        self.snapshot(self.now + 10)
        refresh.plan(self.runtime, self.now)
        self.snapshot(self.now + 18000, sampled=self.now + 15)
        refresh.plan(self.runtime, self.now + 20)
        self.assertEqual(refresh.pending_reset_checks(self.runtime), [self.now + 40, self.now + 18030])
        refresh.complete(self.runtime, "-", 1, self.now + 50, self.now + 40)
        self.assertEqual(refresh.pending_reset_checks(self.runtime), [self.now + 80, self.now + 18030])
        refresh.complete(self.runtime, "-", 0, self.now + 80)
        self.assertEqual(refresh.pending_reset_checks(self.runtime), [self.now + 18030])

    def test_pending_checks_include_both_nearby_resets(self):
        self.snapshot(self.now + 10, self.now + 20)
        refresh.plan(self.runtime, self.now)
        self.snapshot(self.now + 18000, self.now + 7 * 86400, sampled=self.now + 25)
        refresh.plan(self.runtime, self.now + 25)
        self.assertEqual(refresh.pending_reset_checks(self.runtime), [self.now + 40, self.now + 50, self.now + 18030, self.now + 7 * 86400 + 30])

    def test_pending_checks_ignore_missing_or_malformed_deadlines(self):
        self.assertEqual(refresh.pending_reset_checks(self.runtime), [])
        for pending in [[], None, {}, {"five_h:1": True}, {"five_h:1": "30"}]:
            with self.subTest(pending=pending):
                refresh.write_json(self.runtime / "reset-refresh.json", {"pending": pending})
                self.assertEqual(refresh.pending_reset_checks(self.runtime), [])

    def test_invalid_reset_values_and_future_outliers_are_ignored(self):
        for value in [None, 0, -1, True, "123", [], self.now + 9 * 86400]:
            with self.subTest(value=value):
                self.snapshot(value, value)
                self.assertEqual(refresh.plan(self.runtime, self.now), ("-", 86400))

    def test_request_round_trip_busy_retry_and_private_files(self):
        outcome = []
        worker = threading.Thread(target=lambda: outcome.append(refresh.request_refresh(self.runtime, timeout=5)))
        worker.start()
        self.addCleanup(worker.join)
        deadline = time.monotonic() + 3
        identifier = "-"
        while identifier == "-" and time.monotonic() < deadline:
            identifier, _ = refresh.plan(self.runtime, int(time.time()))
            time.sleep(0.01)
        self.assertNotEqual(identifier, "-")
        refresh.complete(self.runtime, identifier, 75, int(time.time()))
        self.assertEqual(refresh.plan(self.runtime, int(time.time()))[0], identifier)
        refresh.complete(self.runtime, identifier, 0, int(time.time()))
        worker.join(timeout=3)
        self.assertEqual(outcome, [True])
        self.assertEqual(refresh.plan(self.runtime, int(time.time()))[0], "-")
        for path in self.runtime.glob("*.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_expired_request_and_timeout(self):
        refresh.write_json(self.runtime / "dashboard-refresh.json", {"id": "a" * 32, "expires_at": self.now - 1})
        self.assertEqual(refresh.plan(self.runtime, self.now)[0], "-")
        with self.assertRaises(TimeoutError):
            refresh.request_refresh(self.runtime, timeout=0)

    def test_private_reader_rejects_symlinks_and_malformed_json(self):
        path = self.runtime / "bad.json"
        path.write_text("not JSON")
        self.assertEqual(refresh.read_json(path), {})
        path.unlink()
        path.symlink_to(self.runtime / "missing")
        self.assertEqual(refresh.read_json(path), {})

    def test_published_refresh_finishes_while_downstream_work_is_blocked(self):
        # Keep downstream work blocked until the real refresh client returns.
        # This tests the acknowledgement order without a minute-long sleep.
        script = r'''
source tests/lib/test_helper.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
target_mode="$1"
blocked_stage="$2"
control="$3"
DASHBOARD_HEARTBEAT_POLL_SECONDS=1
cycles=0
fetch_status_json() {
  python3 - "$cycles" <<'PY'
from datetime import datetime, timezone
import json
import sys
print(json.dumps({"five_h_pct": 80 if sys.argv[1] == "0" else 70, "weekly_pct": 100,
    "five_h_reset_at": None, "weekly_reset_at": None, "limit_id": "test",
    "scraped_at": datetime.now(timezone.utc).isoformat(),
    "sample_interval_seconds": 300, "history_window_hours": 192}))
PY
}
archive_snapshot() { return 0; }
observe_quota_anomalies() { return 0; }
block_downstream() {
  if [[ "$1" == "$blocked_stage" && "$cycle_mode" == "$target_mode" ]]; then
    touch "$control/blocked"
    until [[ -f "$control/release" ]]; do sleep 0.02; done
    return 1
  fi
}
sync_gist() { block_downstream gist; }
collect_token_usage() { block_downstream tokens; }
check_thresholds() {
  cycles=$((cycles + 1))
  touch "$control/collected"
  block_downstream notification
}
printf '%s\n' "$RUNTIME_DIR"
if [[ "$target_mode" == full ]]; then
  until [[ -f "$RUNTIME_DIR/dashboard-refresh.json" ]]; do sleep 0.02; done
fi
status=0
run_loop 900 1 >/dev/null 2>&1 || status=$?
json_field "$HEALTH_FILE" last_cycle_result
exit "$status"
'''
        for mode, stage in [("full", "gist"), ("full", "notification"), ("full", "tokens"), ("live", "notification")]:
            with self.subTest(mode=mode, stage=stage):
                control = self.runtime / (mode + "-" + stage)
                control.mkdir()
                process = subprocess.Popen(
                    ["bash", "-c", script, "refresh-test", mode, stage, str(control)],
                    cwd=Path(__file__).resolve().parents[1], text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                )
                try:
                    runtime = Path(process.stdout.readline().strip())
                    if mode == "live":
                        deadline = time.monotonic() + 5
                        while not (control / "collected").exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertTrue((control / "collected").exists(), "initial full cycle did not finish collecting")
                    self.assertTrue(refresh.request_refresh(runtime, timeout=5))
                    self.assertEqual(refresh.read_json(runtime / "data.json")["five_h_pct"], 80 if mode == "full" else 70)
                    deadline = time.monotonic() + 5
                    while not (control / "blocked").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((control / "blocked").exists())
                    self.assertIsNone(process.poll(), "the cycle must still be blocked when the client returns")
                    (control / "release").touch()
                    output, errors = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 1, errors)
                    self.assertEqual(output.strip(), "failure", errors)
                finally:
                    (control / "release").touch()
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
