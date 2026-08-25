#!/usr/bin/env python3
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import history  # noqa: E402


def timestamp(epoch, offset=timedelta(0), naive=False):
    value = datetime.fromtimestamp(epoch, timezone.utc).astimezone(timezone(offset))
    if naive:
        return value.replace(tzinfo=None).isoformat()
    return value.isoformat().replace("+00:00", "Z")


def snapshot(epoch, five=50, weekly=75, **extra):
    value = {
        "five_h_pct": five,
        "weekly_pct": weekly,
        "five_h_reset": "later",
        "weekly_reset": "later",
        "scraped_at": timestamp(epoch),
    }
    value.update(extra)
    return value


class HistoryTests(unittest.TestCase):
    def test_unversioned_snapshot_is_read_as_v0_and_written_as_v1(self):
        now = 1_700_000_000
        legacy = snapshot(now)
        self.assertNotIn("schema_version", legacy)
        normalized = history.validate_snapshot(legacy)
        self.assertEqual(1, normalized["schema_version"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text(json.dumps([legacy]), encoding="utf-8")
            history.update_history(history_path, data_path, legacy, 24, now_epoch=now)
            self.assertEqual(1, json.loads(history_path.read_text())[0]["schema_version"])
            self.assertEqual(1, json.loads(data_path.read_text())["schema_version"])

    def test_future_snapshot_schema_is_rejected_without_rewriting_history(self):
        now = 1_700_000_000
        future = {**snapshot(now), "schema_version": history.SCHEMA_VERSION + 1}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            original = json.dumps([future])
            history_path.write_text(original, encoding="utf-8")
            with self.assertRaises(history.UnsupportedSchemaVersionError):
                history.update_history(history_path, data_path, snapshot(now), 24, now_epoch=now)
            self.assertEqual(original, history_path.read_text(encoding="utf-8"))
            self.assertFalse(data_path.exists())

    def test_huge_future_schema_version_is_rejected_without_echoing_the_integer(self):
        huge_version = 10**5_000
        with self.assertRaises(history.UnsupportedSchemaVersionError) as raised:
            history.validate_snapshot({**snapshot(1_700_000_000), "schema_version": huge_version})
        self.assertLess(len(str(raised.exception)), 200)

    def test_timestamp_normalization_sorting_and_equivalent_offsets(self):
        instant = 1_700_000_000
        later = instant + 60
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text(
                json.dumps(
                    [
                        {
                            **snapshot(instant, five=10, weekly=20),
                            "scraped_at": timestamp(instant, timedelta(hours=2)),
                        },
                        snapshot(later, five=30, weekly=40),
                    ]
                ),
                encoding="utf-8",
            )

            history.update_history(
                history_path,
                data_path,
                {
                    **snapshot(instant, five=50, weekly=60),
                    "scraped_at": timestamp(instant, naive=True),
                },
                24,
                now_epoch=later,
            )

            values = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual([timestamp(later), timestamp(instant)], [item["scraped_at"] for item in values])
            self.assertEqual(50, values[1]["five_h_pct"])
            self.assertEqual(60, values[1]["weekly_pct"])
            self.assertEqual(instant, history.timestamp_to_epoch(timestamp(instant, timedelta(hours=2))))

    def test_duplicate_merge_prefers_last_existing_then_incoming_without_null_loss(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            first = snapshot(now, five=10, weekly=20)
            last = snapshot(now, five=30, weekly=None)
            history_path.write_text(json.dumps([first, last]), encoding="utf-8")

            history.update_history(
                history_path,
                data_path,
                snapshot(now, five=None, weekly=60),
                24,
                now_epoch=now,
            )

            values = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual(1, len(values))
            self.assertEqual(30, values[0]["five_h_pct"])
            self.assertEqual(60, values[0]["weekly_pct"])

    def test_percentage_boundaries_and_decimals_are_accepted(self):
        normalized = history.validate_snapshot(snapshot(1_700_000_000, five=0, weekly=100.0))
        self.assertEqual(0, normalized["five_h_pct"])
        self.assertEqual(100, normalized["weekly_pct"])
        normalized = history.validate_snapshot(snapshot(1_700_000_000, five=12.5, weekly=None))
        self.assertEqual(12.5, normalized["five_h_pct"])

    def test_invalid_timestamps_and_percentages_are_rejected(self):
        invalid = [
            snapshot(1_700_000_000, five=-0.1),
            snapshot(1_700_000_000, weekly=100.1),
            snapshot(1_700_000_000, five=True),
            snapshot(1_700_000_000, weekly=float("nan")),
            snapshot(1_700_000_000, five=float("inf")),
            snapshot(1_700_000_000, five=None, weekly=None),
            {"scraped_at": "invalid", "weekly_pct": 50},
            {"scraped_at": 1_700_000_000, "weekly_pct": 50},
        ]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(history.SnapshotValidationError):
                    history.validate_snapshot(value)

    def test_arbitrarily_large_json_integer_is_rejected_without_overflow(self):
        huge = 10**5_000
        value = snapshot(1_700_000_000, five=huge)
        with self.assertRaises(history.SnapshotValidationError):
            history.validate_snapshot(value)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = (
                '{"five_h_pct":' + ("9" * 5_000)
                + ',"weekly_pct":75,"scraped_at":"2023-11-14T22:13:20Z"}'
            )
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--data",
                    str(root / "data.json"),
                    "--data-only",
                ],
                input=raw,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(1, process.returncode)
            self.assertNotIn("Traceback", process.stderr)

            existing = root / "existing-data.json"
            existing.write_text(raw, encoding="utf-8")
            replaced = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--data",
                    str(existing),
                    "--data-only",
                ],
                input=json.dumps(snapshot(1_700_000_001)),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, replaced.returncode, replaced.stderr)
            self.assertNotIn("Traceback", replaced.stderr)

            existing_history = root / "existing-history.json"
            existing_history.write_text("[" + raw + "]", encoding="utf-8")
            migrated = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--history",
                    str(existing_history),
                    "--data",
                    str(root / "history-data.json"),
                    "--retention-hours",
                    "24",
                ],
                input=json.dumps(snapshot(1_700_000_002)),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, migrated.returncode, migrated.stderr)
            self.assertNotIn("Traceback", migrated.stderr)

    def test_extreme_retention_cli_value_is_user_error_without_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--history",
                    str(root / "history.json"),
                    "--data",
                    str(root / "data.json"),
                    "--retention-hours",
                    "9" * 5_000,
                ],
                input=json.dumps(snapshot(1_700_000_000)),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(1, process.returncode)
            self.assertIn("retention hours", process.stderr)
            self.assertNotIn("Traceback", process.stderr)
            self.assertFalse((root / "history.json").exists())

    def test_limit_id_is_opaque_stable_and_migrated_from_legacy(self):
        raw_id = "server-secret /workspace/path\nwith-control"
        expected = "limit-" + hashlib.sha256(raw_id.encode()).hexdigest()
        self.assertEqual(expected, history.sanitize_limit_id(raw_id))
        self.assertEqual(expected, history.sanitize_limit_id(expected))
        now = 1_700_000_000
        legacy = snapshot(now, limit_id=raw_id)
        normalized = history.validate_snapshot(legacy)
        self.assertEqual(expected, normalized["limit_id"])
        self.assertNotIn(raw_id, json.dumps(normalized))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history.update_history(history_path, data_path, legacy, 24, now_epoch=now)
            written = history_path.read_text(encoding="utf-8")
            self.assertIn(expected, written)
            self.assertNotIn(raw_id, written)

            data_path.write_text(json.dumps({**snapshot(now), "limit_id": raw_id}), encoding="utf-8")
            history.update_history(
                history_path,
                data_path,
                {**snapshot(now - 1), "limit_id": raw_id},
                24,
                now_epoch=now,
            )
            current_written = data_path.read_text(encoding="utf-8")
            self.assertIn(expected, current_written)
            self.assertNotIn(raw_id, current_written)

    def test_sqlite_epoch_range_is_rejected(self):
        invalid = snapshot(1_700_000_000, five=50, weekly=75, five_h_reset_at=1e308)
        with self.assertRaises(history.SnapshotValidationError):
            history.validate_snapshot(invalid)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = (
                '{"five_h_pct":50,"weekly_pct":75,"five_h_reset_at":1e308,'
                '"scraped_at":"2023-11-14T22:13:20Z"}'
            )
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--data",
                    str(root / "data.json"),
                    "--data-only",
                ],
                input=raw,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(1, process.returncode)
            self.assertNotIn("Traceback", process.stderr)
            self.assertFalse((root / "data.json").exists())

    def test_retention_is_inclusive_and_independent_of_collection_interval(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            values = [
                snapshot(now - 7_201, sample_interval_seconds=900),
                snapshot(now - 7_200, sample_interval_seconds=900),
                snapshot(now - 3_600, sample_interval_seconds=60),
                snapshot(now, sample_interval_seconds=900),
            ]
            history_path.write_text(json.dumps(values[:-1]), encoding="utf-8")
            history.update_history(
                history_path,
                data_path,
                values[-1],
                2,
                now_epoch=now,
            )

            retained = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual(
                [timestamp(now), timestamp(now - 3_600), timestamp(now - 7_200)],
                [item["scraped_at"] for item in retained],
            )
            self.assertEqual([900, 60, 900], [item["sample_interval_seconds"] for item in retained])

    def test_interruption_prunes_old_values_and_future_values_do_not_move_cutoff(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text(
                json.dumps(
                    [
                        snapshot(now - 90_000),
                        snapshot(now - 3_600),
                        snapshot(now + 86_400),
                    ]
                ),
                encoding="utf-8",
            )
            history.update_history(
                history_path,
                data_path,
                snapshot(now),
                24,
                now_epoch=now,
            )
            retained = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual(
                [timestamp(now + 86_400), timestamp(now), timestamp(now - 3_600)],
                [item["scraped_at"] for item in retained],
            )

    def test_corruption_backups_are_unique_and_partial_history_is_salvaged(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            original = json.dumps([snapshot(now - 60), {"scraped_at": "bad", "weekly_pct": 10}])
            history_path.write_text(original, encoding="utf-8")
            first = history.update_history(
                history_path,
                data_path,
                snapshot(now),
                24,
                now_epoch=now,
            )
            self.assertEqual(original, first.backup.read_text(encoding="utf-8"))
            self.assertEqual(2, len(json.loads(history_path.read_text(encoding="utf-8"))))

            history_path.write_text("{broken", encoding="utf-8")
            second = history.update_history(
                history_path,
                data_path,
                snapshot(now + 1),
                24,
                now_epoch=now + 1,
            )
            self.assertNotEqual(first.backup, second.backup)
            self.assertEqual(2, len(list(root.glob("history.json.corrupt.*"))))

    def test_failed_backup_preserves_corrupt_history_and_does_not_write_data(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text("{broken", encoding="utf-8")
            with patch.object(history, "backup_corrupt_history", side_effect=OSError("denied")):
                with self.assertRaises(history.HistoryError):
                    history.update_history(
                        history_path,
                        data_path,
                        snapshot(now),
                        24,
                        now_epoch=now,
                    )
            self.assertEqual("{broken", history_path.read_text(encoding="utf-8"))
            self.assertFalse(data_path.exists())

    def test_entry_and_byte_limits_keep_the_newest_values_and_warn(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            stderr = io.StringIO()
            values = [snapshot(now - offset, limit_id="x" * 80) for offset in range(5)]
            history_path.write_text(json.dumps(values[:-1]), encoding="utf-8")
            with patch.object(history, "MAX_HISTORY_ENTRIES", 3):
                with contextlib.redirect_stderr(stderr):
                    history.update_history(
                        history_path,
                        data_path,
                        values[-1],
                        24,
                        now_epoch=now,
                    )
            retained = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual(3, len(retained))
            self.assertEqual(
                [timestamp(now), timestamp(now - 1), timestamp(now - 2)],
                [item["scraped_at"] for item in retained],
            )
            self.assertIn("3-entry defensive limit", stderr.getvalue())

            history_path.write_text(json.dumps(values), encoding="utf-8")
            stderr = io.StringIO()
            normalized = [history.normalize_entry(value) for value in values]
            byte_limit = len(history.serialize_history(normalized))
            with patch.object(history, "MAX_HISTORY_BYTES", byte_limit):
                with contextlib.redirect_stderr(stderr):
                    history.update_history(
                        history_path,
                        data_path,
                        snapshot(now + 1, limit_id="y" * 80),
                        24,
                        now_epoch=now + 1,
                    )
            self.assertLessEqual(history_path.stat().st_size, byte_limit)
            self.assertEqual(timestamp(now + 1), json.loads(history_path.read_text(encoding="utf-8"))[0]["scraped_at"])
            self.assertIn("16 MiB defensive limit", stderr.getvalue())

    def test_oversized_input_is_backed_up_before_reconstruction(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            original = json.dumps([snapshot(now - 1)]).encode("utf-8")
            history_path.write_bytes(
                original + b" " * (history.MAX_HISTORY_BYTES + 1 - len(original))
            )
            result = history.update_history(
                history_path,
                data_path,
                snapshot(now),
                24,
                now_epoch=now,
            )
            self.assertIsNotNone(result.backup)
            self.assertEqual(1, len(json.loads(history_path.read_text(encoding="utf-8"))))

    def test_atomic_files_are_private_and_leave_no_temporaries(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history.update_history(
                history_path,
                data_path,
                snapshot(now),
                24,
                now_epoch=now,
            )
            self.assertEqual(0o600, stat.S_IMODE(history_path.stat().st_mode))
            self.assertEqual(0o600, stat.S_IMODE(data_path.stat().st_mode))
            self.assertEqual([], list(root.glob(".history.json.*")))
            self.assertEqual([], list(root.glob(".data.json.*")))

    def test_atomic_write_cleans_its_temporary_file_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "history.json"
            with patch.object(history.os, "replace", side_effect=OSError("replace failed")):
                with self.assertRaises(OSError):
                    history.atomic_write(path, b"[]\n")
            self.assertFalse(path.exists())
            self.assertEqual([], list(root.glob(".history.json.*")))

    def test_data_comparison_uses_real_time_and_forecast_is_historized(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            newer = now + 60
            data_path.write_text(
                json.dumps(
                    {
                        **snapshot(newer),
                        "scraped_at": timestamp(newer, timedelta(hours=-5)),
                    }
                ),
                encoding="utf-8",
            )
            forecast = {
                "chance_24h_pct": 20,
                "chance_6h_pct": 10,
                "generated_at": timestamp(now),
                "highlight_threshold_24h_pct": 50,
                "highlight_threshold_6h_pct": 25,
            }
            result = history.update_history(
                history_path,
                data_path,
                snapshot(now, codex_forecast=forecast),
                24,
                now_epoch=now,
            )
            self.assertFalse(result.data_updated)
            current = json.loads(data_path.read_text(encoding="utf-8"))
            self.assertEqual(timestamp(newer, timedelta(hours=-5)), current["scraped_at"])

            history.update_history(
                history_path,
                data_path,
                snapshot(newer + 60, codex_forecast=forecast),
                24,
                now_epoch=newer + 60,
            )
            current = json.loads(data_path.read_text(encoding="utf-8"))
            rolling = json.loads(history_path.read_text(encoding="utf-8"))
            self.assertEqual(forecast, current["codex_forecast"])
            self.assertTrue(all("codex_forecast" in item for item in rolling))
            self.assertEqual(20, rolling[0]["codex_forecast"]["chance_24h_pct"])
            self.assertNotIn(
                "highlight_threshold_24h_pct", rolling[0]["codex_forecast"]
            )
            self.assertTrue(all("scraped_at_epoch" not in item for item in rolling))

    def test_data_only_updates_snapshot_without_touching_history(self):
        now = 1_700_000_000
        forecast = {
            "chance_24h_pct": 60,
            "chance_6h_pct": 20,
            "generated_at": timestamp(now),
            "highlight_threshold_24h_pct": 50,
            "highlight_threshold_6h_pct": 25,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text(json.dumps([snapshot(now)]), encoding="utf-8")
            original_history = history_path.read_bytes()
            history.update_current_data(
                data_path,
                snapshot(now, five=80, codex_forecast=forecast),
                preserve_existing_forecast=True,
            )
            result = history.update_current_data(
                data_path,
                snapshot(now + 300, five=70, sample_interval_seconds=300),
                preserve_existing_forecast=True,
            )

            self.assertTrue(result.data_updated)
            self.assertEqual(original_history, history_path.read_bytes())
            current = json.loads(data_path.read_text(encoding="utf-8"))
            self.assertEqual(70, current["five_h_pct"])
            self.assertEqual(300, current["sample_interval_seconds"])
            self.assertEqual(forecast, current["codex_forecast"])
            self.assertEqual(0o600, stat.S_IMODE(data_path.stat().st_mode))

    def test_data_only_replaces_forecast_and_rejects_older_snapshot(self):
        now = 1_700_000_000
        first_forecast = {
            "chance_24h_pct": 60,
            "chance_6h_pct": 20,
            "generated_at": timestamp(now),
        }
        next_forecast = {
            "chance_24h_pct": 70,
            "chance_6h_pct": 30,
            "generated_at": timestamp(now + 300),
        }
        with tempfile.TemporaryDirectory() as directory:
            data_path = Path(directory) / "data.json"
            history.update_current_data(
                data_path,
                snapshot(now, codex_forecast=first_forecast),
                preserve_existing_forecast=True,
            )
            history.update_current_data(
                data_path,
                snapshot(now + 300, five=40, codex_forecast=next_forecast),
                preserve_existing_forecast=True,
            )
            result = history.update_current_data(
                data_path,
                snapshot(now + 60, five=10),
                preserve_existing_forecast=True,
            )

            self.assertFalse(result.data_updated)
            current = json.loads(data_path.read_text(encoding="utf-8"))
            self.assertEqual(40, current["five_h_pct"])
            self.assertEqual(next_forecast, current["codex_forecast"])

    def test_data_only_migrates_recent_legacy_snapshot_when_incoming_is_older(self):
        recent = 1_700_000_600
        older = recent - 300
        raw_id = "raw-secret-account-id"
        with tempfile.TemporaryDirectory() as directory:
            data_path = Path(directory) / "data.json"
            data_path.write_text(
                json.dumps(snapshot(recent, five=88, weekly=66, limit_id=raw_id)),
                encoding="utf-8",
            )
            result = history.update_current_data(
                data_path,
                snapshot(older, five=12, weekly=23),
            )
            current = json.loads(data_path.read_text(encoding="utf-8"))

            self.assertFalse(result.data_updated)
            self.assertEqual(timestamp(recent), current["scraped_at"])
            self.assertEqual(88, current["five_h_pct"])
            self.assertEqual(66, current["weekly_pct"])
            self.assertEqual(1, current["schema_version"])
            self.assertEqual(history.opaque_limit_id_from_raw(raw_id), current["limit_id"])
            self.assertNotIn(raw_id, data_path.read_text(encoding="utf-8"))

    def test_reset_epoch_requires_integer_seconds_but_accepts_integral_float(self):
        normalized = history.validate_snapshot(snapshot(1_700_000_000, five_h_reset_at=1.0))
        self.assertEqual(1, normalized["five_h_reset_at"])
        with self.assertRaises(history.SnapshotValidationError):
            history.validate_snapshot(snapshot(1_700_000_000, five_h_reset_at=1.5))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            original = json.dumps([snapshot(1_700_000_000, five_h_reset_at=1.5)])
            history_path.write_text(original, encoding="utf-8")
            with self.assertRaises(history.SnapshotValidationError):
                history.update_history(history_path, data_path, snapshot(1_700_000_001), 24)
            self.assertEqual(original, history_path.read_text(encoding="utf-8"))
            self.assertFalse(data_path.exists())

    def test_data_only_cli_does_not_require_or_repair_history(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            history_path = root / "history.json"
            data_path = root / "data.json"
            history_path.write_text("{broken", encoding="utf-8")
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "local" / "history.py"),
                    "--data",
                    str(data_path),
                    "--data-only",
                ],
                input=json.dumps(snapshot(now)),
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(0, process.returncode, process.stderr)
            self.assertEqual("{broken", history_path.read_text(encoding="utf-8"))
            self.assertTrue(data_path.exists())

    def test_cli_reads_stdin_and_reports_validation_errors_without_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = [
                sys.executable,
                str(ROOT / "local" / "history.py"),
                "--history",
                str(root / "history.json"),
                "--data",
                str(root / "data.json"),
                "--retention-hours",
                "24",
            ]
            valid = subprocess.run(
                command,
                input=json.dumps(snapshot(1_700_000_000)),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, valid.returncode, valid.stderr)
            invalid = subprocess.run(
                command,
                input=json.dumps(snapshot(1_700_000_001, five=101)),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(1, invalid.returncode)
            self.assertIn("[ERROR]", invalid.stderr)
            self.assertNotIn("Traceback", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
