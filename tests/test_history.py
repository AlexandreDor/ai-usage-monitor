import contextlib
import io
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import history  # noqa: E402


def timestamp(epoch: int, offset: timedelta = timedelta(0)) -> str:
    value = datetime.fromtimestamp(epoch, timezone.utc).astimezone(
        timezone(offset)
    )
    return value.isoformat().replace("+00:00", "Z")


def snapshot(epoch: int, five: float | None = 50, weekly: float | None = 75, **extra):
    value = {
        "scraped_at": timestamp(epoch),
        "five_h_pct": five,
        "weekly_pct": weekly,
    }
    value.update(extra)
    return value


class HistoryModuleTests(unittest.TestCase):
    def test_timestamps_are_compared_as_epoch_and_equivalent_offsets_deduplicate(self):
        instant = 1_700_000_000
        later = instant + 3600
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            history.update_history(
                path,
                {
                    **snapshot(instant, five=20, weekly=None),
                    "scraped_at": timestamp(instant, timedelta(hours=2)),
                },
                retention_hours=24,
                now=later,
            )
            history.update_history(
                path,
                {
                    **snapshot(instant, five=30, weekly=40),
                    "scraped_at": timestamp(instant),
                },
                retention_hours=24,
                now=later,
            )
            history.update_history(
                path,
                snapshot(later, five=60, weekly=70),
                retention_hours=24,
                now=later,
            )

            values = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(2, len(values))
            self.assertEqual(timestamp(later), values[0]["scraped_at"])
            self.assertEqual(timestamp(instant), values[1]["scraped_at"])
            self.assertEqual(30, values[1]["five_h_pct"])
            self.assertEqual(40, values[1]["weekly_pct"])
            self.assertEqual(instant, history.timestamp_to_epoch(values[1]["scraped_at"]))
            self.assertEqual(
                instant,
                history.timestamp_to_epoch(timestamp(instant, timedelta(hours=2))),
            )

    def test_snapshot_validation_rejects_invalid_timestamps_and_percentages(self):
        invalid_snapshots = [
            snapshot(1_700_000_000, five=-0.01),
            snapshot(1_700_000_000, weekly=100.01),
            snapshot(1_700_000_000, five=None, weekly=None),
            {"scraped_at": "not-a-timestamp", "weekly_pct": 50},
            {"scraped_at": True, "weekly_pct": 50},
            {"scraped_at": 1_700_000_000, "weekly_pct": float("nan")},
        ]
        for invalid in invalid_snapshots:
            with self.subTest(snapshot=invalid):
                with self.assertRaises(history.SnapshotValidationError):
                    history.validate_snapshot(invalid)

    def test_retention_uses_age_not_current_poll_interval(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            for epoch, interval in (
                (now - 7201, 900),
                (now - 7200, 60),
                (now - 3600, 900),
                (now, 900),
            ):
                history.update_history(
                    path,
                    snapshot(epoch, sample_interval_seconds=interval),
                    retention_hours=2,
                    now=now,
                )

            values = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(
                [timestamp(now), timestamp(now - 3600), timestamp(now - 7200)],
                [item["scraped_at"] for item in values],
            )

    def test_corrupt_history_is_backed_up_with_unique_names_before_rebuild(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "history.json"
            path.write_text("{broken", encoding="utf-8")
            first = history.update_history(
                path,
                snapshot(now),
                retention_hours=24,
                now=now,
            )
            self.assertIsNotNone(first.backup)
            self.assertEqual("{broken", first.backup.read_text(encoding="utf-8"))

            path.write_text("not-json-again", encoding="utf-8")
            second = history.update_history(
                path,
                snapshot(now + 1),
                retention_hours=24,
                now=now + 1,
            )
            backups = sorted(root.glob("history.json.corrupt.*"))
            self.assertEqual(2, len(backups))
            self.assertNotEqual(first.backup.name, second.backup.name)
            self.assertEqual(1, len(json.loads(path.read_text(encoding="utf-8"))))

    def test_invalid_entry_also_triggers_a_backup_and_valid_entries_are_salvaged(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "history.json"
            path.write_text(
                json.dumps([snapshot(now - 60), {"scraped_at": "bad", "weekly_pct": 10}]),
                encoding="utf-8",
            )
            result = history.update_history(
                path,
                snapshot(now),
                retention_hours=24,
                now=now,
            )
            self.assertIsNotNone(result.backup)
            self.assertEqual(2, len(json.loads(path.read_text(encoding="utf-8"))))
            self.assertEqual(1, len(list(root.glob("history.json.corrupt.*"))))

    def test_defensive_entry_limit_warns_and_keeps_newest_entries(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            stderr = io.StringIO()
            with patch.object(history, "MAX_ENTRIES", 2), contextlib.redirect_stderr(stderr):
                for index in range(3):
                    history.update_history(
                        path,
                        snapshot(now - index * 60),
                        retention_hours=24,
                        now=now,
                    )
            values = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(2, len(values))
            self.assertIn("2-entry defensive limit", stderr.getvalue())
            self.assertIn("shortened", stderr.getvalue())

    def test_defensive_byte_limit_warns_and_output_stays_below_limit(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.json"
            stderr = io.StringIO()
            with patch.object(history, "MAX_BYTES", 900), contextlib.redirect_stderr(stderr):
                for index in range(5):
                    history.update_history(
                        path,
                        snapshot(
                            now - index * 60,
                            limit_id="a" * 80,
                            five_h_reset="later",
                            weekly_reset="later",
                        ),
                        retention_hours=24,
                        now=now,
                    )
            self.assertLessEqual(path.stat().st_size, 900)
            self.assertIn("16 MiB defensive limit", stderr.getvalue())

    def test_data_json_remains_an_object_and_no_temporary_files_are_left(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            result = history.update_history(
                history_path,
                snapshot(now),
                data_path=data_path,
                retention_hours=24,
                now=now,
            )
            self.assertTrue(result.data_updated)
            self.assertIsInstance(json.loads(data_path.read_text(encoding="utf-8")), dict)
            self.assertIsInstance(json.loads(history_path.read_text(encoding="utf-8")), list)
            self.assertEqual([], list(root.glob(".history.json.*")))
            self.assertEqual([], list(root.glob(".data.json.*")))

    def test_cli_updates_history_and_data(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            command = [
                sys.executable,
                str(ROOT / "local" / "history.py"),
                "--history",
                str(history_path),
                "--data",
                str(data_path),
                "--snapshot",
                json.dumps(snapshot(now)),
                "--retention-hours",
                "24",
                "--now",
                str(now),
            ]
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertIn("History updated", completed.stdout)
            self.assertIsInstance(json.loads(history_path.read_text(encoding="utf-8")), list)
            self.assertIsInstance(json.loads(data_path.read_text(encoding="utf-8")), dict)


if __name__ == "__main__":
    unittest.main()
