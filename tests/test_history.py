import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from local import history


def snapshot(timestamp, five=40, weekly=70, **overrides):
    value = {
        "five_h_pct": five,
        "five_h_reset": "later",
        "five_h_reset_at": None,
        "weekly_pct": weekly,
        "weekly_reset": "later",
        "weekly_reset_at": None,
        "limit_id": "test",
        "scraped_at": timestamp,
        "sample_interval_seconds": 900,
        "history_window_hours": 192,
    }
    value.update(overrides)
    return value


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.history_path = self.root / "history.json"
        self.data_path = self.root / "data.json"

    def tearDown(self):
        self.directory.cleanup()

    def update(self, value, retention=24, now=2_000_000):
        return history.update_history(
            self.history_path,
            self.data_path,
            value,
            retention,
            now=now,
        )

    def read_json(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def test_naive_is_utc_and_offsets_are_deduplicated_by_real_instant(self):
        naive = history.parse_snapshot(snapshot("1970-01-01T00:16:40"))
        self.assertEqual("1970-01-01T00:16:40Z", naive.public["scraped_at"])
        self.assertEqual(1000, naive.epoch)

        self.update(snapshot("1970-01-24T03:33:20+02:00", weekly=61), retention=1000, now=2_000_000)
        result = self.update(snapshot("1970-01-24T01:33:20Z", weekly=62), retention=1000, now=2_000_000)
        self.assertEqual(1, len(result.history))
        self.assertEqual(62, result.history[0]["weekly_pct"])

        self.update(snapshot("1970-01-24T02:33:20Z", weekly=63), retention=1000, now=2_000_000)
        timestamps = [entry["scraped_at"] for entry in self.read_json(self.history_path)]
        self.assertEqual(
            ["1970-01-24T02:33:20Z", "1970-01-24T01:33:20Z"],
            timestamps,
        )

    def test_strict_percentages_and_non_finite_numbers(self):
        for field, value in (
            ("five_h_pct", -0.1),
            ("weekly_pct", 100.1),
            ("five_h_pct", float("nan")),
            ("weekly_pct", float("inf")),
            ("sample_interval_seconds", float("nan")),
            ("history_window_hours", float("inf")),
        ):
            invalid = snapshot("1970-01-01T00:00:00Z")
            invalid[field] = value
            with self.assertRaises(history.SnapshotValidationError):
                history.parse_snapshot(invalid)

        invalid = snapshot("1970-01-01T00:00:00Z", five=None, weekly=None)
        with self.assertRaises(history.SnapshotValidationError):
            history.parse_snapshot(invalid)

        invalid = snapshot("1970-01-01T00:00:00Z")
        invalid["extra"] = True
        with self.assertRaises(history.SnapshotValidationError):
            history.parse_snapshot(invalid)

    def test_retention_uses_age_not_current_sample_interval(self):
        self.update(
            snapshot("1970-01-01T00:00:00Z", sample_interval_seconds=900),
            retention=2,
            now=10_000,
        )
        self.update(
            snapshot("1970-01-01T02:00:00Z", sample_interval_seconds=60),
            retention=2,
            now=10_000,
        )
        result = self.update(
            snapshot("1970-01-01T03:00:00Z", sample_interval_seconds=900),
            retention=2,
            now=10_800,
        )
        self.assertEqual(
            ["1970-01-01T03:00:00Z", "1970-01-01T02:00:00Z"],
            [entry["scraped_at"] for entry in result.history],
        )

    def test_aberrant_future_timestamp_is_rejected_without_writes(self):
        self.update(snapshot("1970-01-01T02:00:00Z"), retention=2, now=10_000)
        history_before = self.history_path.read_bytes()
        data_before = self.data_path.read_bytes()
        with self.assertRaises(history.SnapshotValidationError):
            self.update(snapshot("2030-01-01T00:00:00Z"), retention=2, now=10_000)
        self.assertEqual(history_before, self.history_path.read_bytes())
        self.assertEqual(data_before, self.data_path.read_bytes())

    def test_future_tolerance_boundary_and_clock_rollback_refuses_data_loss(self):
        tolerated = "1970-01-01T02:51:40Z"  # now + 300 seconds
        self.update(snapshot(tolerated), retention=2, now=10_000)
        with self.assertRaises(history.SnapshotValidationError):
            self.update(snapshot("1970-01-01T02:51:41Z"), retention=2, now=10_000)

        self.history_path.write_text(
            json.dumps([
                snapshot("2030-01-01T00:00:00Z", weekly=99),
                snapshot("1970-01-01T02:00:00Z", weekly=60),
            ]),
            encoding="utf-8",
        )
        self.data_path.write_text(
            json.dumps(snapshot("2030-01-01T00:00:00Z", weekly=99)),
            encoding="utf-8",
        )
        history_before = self.history_path.read_bytes()
        data_before = self.data_path.read_bytes()
        with self.assertRaisesRegex(history.HistoryStorageError, "clock rollback"):
            self.update(
                snapshot("1970-01-01T02:10:00Z", weekly=61), retention=2, now=10_000
            )
        self.assertEqual(history_before, self.history_path.read_bytes())
        self.assertEqual(data_before, self.data_path.read_bytes())

    def test_defensive_entry_and_byte_limits_warn(self):
        with mock.patch.object(history, "MAX_ENTRIES", 2):
            self.update(snapshot("1970-01-01T00:00:00Z"), retention=100, now=10_000)
            result = self.update(snapshot("1970-01-01T00:01:00Z"), retention=100, now=10_000)
            result = self.update(snapshot("1970-01-01T00:02:00Z"), retention=100, now=10_000)
            self.assertTrue(any("MAX_ENTRIES" in warning for warning in result.warnings))
            self.assertLessEqual(len(self.read_json(self.history_path)), 2)

        with mock.patch.object(history, "MAX_BYTES", 600):
            result = self.update(snapshot("1970-01-01T00:03:00Z"), retention=100, now=10_000)
            self.assertTrue(any("MAX_BYTES" in warning for warning in result.warnings))
            self.assertLessEqual(self.history_path.stat().st_size, 600)

    def test_corrupt_history_is_backed_up_exclusively_before_rebuild(self):
        self.history_path.write_text("{broken", encoding="utf-8")
        with mock.patch.object(history.time, "time_ns", return_value=123):
            first = self.update(snapshot("1970-01-01T00:00:00Z"), retention=24, now=10_000)
        self.assertIsNotNone(first.backup_path)
        self.assertEqual(b"{broken", first.backup_path.read_bytes())
        self.assertEqual(0o600, stat.S_IMODE(first.backup_path.stat().st_mode))

        # A second corruption must not overwrite the first backup, even when
        # the backup clock value is identical.
        self.history_path.write_text("still broken", encoding="utf-8")
        with mock.patch.object(history.time, "time_ns", return_value=123):
            second = self.update(snapshot("1970-01-01T00:01:00Z"), retention=24, now=10_000)
        self.assertIsNotNone(second.backup_path)
        self.assertNotEqual(first.backup_path, second.backup_path)
        self.assertEqual(2, len(list(self.root.glob("history.json.corrupt.*"))))

    def test_public_files_contain_current_fields_but_no_internal_epoch(self):
        self.update(snapshot("1970-01-01T00:00:00Z"), retention=24, now=10_000)
        history_value = self.read_json(self.history_path)
        data_value = self.read_json(self.data_path)
        self.assertEqual(set(history.PUBLIC_FIELDS), set(history_value[0]))
        self.assertEqual(set(history.PUBLIC_FIELDS), set(data_value))
        self.assertNotIn("scraped_at_epoch", history_value[0])
        self.assertNotIn("scraped_at_epoch", data_value)

    def test_empty_history_and_current_data_ordering(self):
        self.history_path.write_text("\n", encoding="utf-8")
        self.update(snapshot("1970-01-01T00:10:00Z"), retention=24, now=10_000)
        self.assertEqual(1, len(self.read_json(self.history_path)))
        self.assertEqual(0o600, stat.S_IMODE(self.history_path.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(self.data_path.stat().st_mode))

        older = self.update(snapshot("1970-01-01T00:09:00Z"), retention=24, now=10_000)
        self.assertFalse(older.data_updated)
        self.assertTrue(any("older snapshot" in warning for warning in older.warnings))
        self.assertEqual("1970-01-01T00:10:00Z", self.read_json(self.data_path)["scraped_at"])

    def test_missing_or_corrupt_data_is_repaired_from_newest_history(self):
        self.history_path.write_text(
            json.dumps([
                snapshot("1970-01-01T00:10:00Z", weekly=80),
                snapshot("1970-01-01T00:09:00Z", weekly=79),
            ]),
            encoding="utf-8",
        )
        older = self.update(
            snapshot("1970-01-01T00:08:00Z", weekly=78), retention=24, now=10_000
        )
        self.assertTrue(older.data_updated)
        self.assertEqual("1970-01-01T00:10:00Z", self.read_json(self.data_path)["scraped_at"])
        self.assertEqual(80, self.read_json(self.data_path)["weekly_pct"])

        self.data_path.write_text("{broken", encoding="utf-8")
        older_again = self.update(
            snapshot("1970-01-01T00:07:00Z", weekly=77), retention=24, now=10_000
        )
        self.assertTrue(older_again.data_updated)
        self.assertEqual("1970-01-01T00:10:00Z", self.read_json(self.data_path)["scraped_at"])
        self.assertEqual(80, self.read_json(self.data_path)["weekly_pct"])

    def test_data_write_before_history_failure_is_reconciled_next_cycle(self):
        self.update(snapshot("1970-01-01T00:16:40Z"), retention=24, now=2_000)

        real_atomic_write = history._atomic_write

        def fail_history(path, content):
            if path == self.history_path:
                raise history.HistoryStorageError("injected history write failure")
            return real_atomic_write(path, content)

        with mock.patch.object(history, "_atomic_write", side_effect=fail_history):
            with self.assertRaisesRegex(history.HistoryStorageError, "injected"):
                self.update(snapshot("1970-01-01T00:16:50Z"), retention=24, now=2_000)

        self.assertEqual("1970-01-01T00:16:50Z", self.read_json(self.data_path)["scraped_at"])
        self.assertEqual(
            ["1970-01-01T00:16:40Z"],
            [entry["scraped_at"] for entry in self.read_json(self.history_path)],
        )

        self.update(snapshot("1970-01-01T00:17:00Z"), retention=24, now=2_000)
        self.assertEqual(
            [
                "1970-01-01T00:17:00Z",
                "1970-01-01T00:16:50Z",
                "1970-01-01T00:16:40Z",
            ],
            [entry["scraped_at"] for entry in self.read_json(self.history_path)],
        )

    def test_symlink_and_non_regular_paths_are_rejected(self):
        source = self.root / "source.json"
        source.write_text("[]", encoding="utf-8")
        link = self.root / "history-link.json"
        link.symlink_to(source)
        with self.assertRaises(history.HistoryStorageError):
            history.update_history(link, self.data_path, snapshot("1970-01-01T00:00:00Z"), 24, now=10_000)

        directory = self.root / "history-directory"
        directory.mkdir()
        with self.assertRaises(history.HistoryStorageError):
            history.update_history(directory, self.data_path, snapshot("1970-01-01T00:00:00Z"), 24, now=10_000)

    def test_valid_history_larger_than_16_mib_is_streamed_and_trimmed(self):
        old = json.dumps(snapshot("1970-01-01T00:00:00Z")).encode()
        self.history_path.write_bytes(b"[" + b" " * (17 * 1024 * 1024) + old + b"]")
        result = self.update(
            snapshot("1970-01-01T00:01:00Z"), retention=24, now=10_000
        )
        self.assertEqual(2, len(result.history))
        self.assertLess(self.history_path.stat().st_size, history.MAX_BYTES)

    def test_large_corrupt_history_is_fully_backed_up_before_reconstruction(self):
        raw = b"[" + json.dumps(snapshot("1970-01-01T00:00:00Z")).encode()
        raw += b"," + b" " * (17 * 1024 * 1024)
        self.history_path.write_bytes(raw)
        result = self.update(
            snapshot("1970-01-01T00:01:00Z"), retention=24, now=10_000
        )
        self.assertIsNotNone(result.backup_path)
        self.assertEqual(len(raw), result.backup_path.stat().st_size)
        self.assertEqual(raw, result.backup_path.read_bytes())
        self.assertEqual(2, len(self.read_json(self.history_path)))

    def test_cli_returns_readable_error_without_traceback(self):
        command = [
            sys.executable,
            str(ROOT / "local" / "history.py"),
            "--history",
            str(self.history_path),
            "--data",
            str(self.data_path),
            "--retention-hours",
            "24",
        ]
        completed = subprocess.run(
            command,
            input=json.dumps(snapshot("1970-01-01T00:00:00Z", five=101)),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(0, completed.returncode)
        self.assertIn("[ERROR]", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
