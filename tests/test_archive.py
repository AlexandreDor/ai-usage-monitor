import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))

import archive


def snapshot(epoch: int, five=80, weekly=60):
    from datetime import datetime, timezone

    return {
        "five_h_pct": five,
        "five_h_reset": "later",
        "five_h_reset_at": None,
        "weekly_pct": weekly,
        "weekly_reset": "later",
        "weekly_reset_at": None,
        "limit_id": "test",
        "scraped_at": datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z"),
        "sample_interval_seconds": 900,
        "history_window_hours": 192,
    }


class ArchiveMigrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.database = self.root / "archive.sqlite3"
        self.history = self.root / "history.json"
        self.current = archive.normalize_snapshot(snapshot(2000), strict=True)

    def tearDown(self):
        self.directory.cleanup()

    def marker(self):
        with sqlite3.connect(self.database) as connection:
            row = connection.execute(
                "SELECT value FROM metadata WHERE key = 'history_json_migrated'"
            ).fetchone()
        return row[0] if row else None

    def test_invalid_history_is_not_marked_and_is_repaired_next_cycle(self):
        self.history.write_text("{broken", encoding="utf-8")
        with self.assertRaises(archive.ArchiveInputError):
            archive.ingest(self.database, self.history, self.current, 365)
        self.assertIsNone(self.marker())

        self.history.write_text(json.dumps([snapshot(1900)]), encoding="utf-8")
        archive.ingest(self.database, self.history, self.current, 365)
        self.assertEqual("1", self.marker())
        with sqlite3.connect(self.database) as connection:
            epochs = connection.execute(
                "SELECT scraped_at_epoch FROM snapshots ORDER BY scraped_at_epoch"
            ).fetchall()
        self.assertEqual([(1900,), (2000,)], epochs)

    def test_invalid_percentage_and_future_history_never_mark_migration(self):
        for value in (snapshot(1900, five=-1), snapshot(2401)):
            if self.database.exists():
                self.database.unlink()
            self.history.write_text(json.dumps([value]), encoding="utf-8")
            with self.assertRaises(archive.ArchiveInputError):
                archive.ingest(self.database, self.history, self.current, 365)
            self.assertIsNone(self.marker())

    def test_incoming_snapshot_is_checked_against_injected_clock(self):
        with self.assertRaisesRegex(archive.ArchiveInputError, "future timestamp"):
            archive.ingest(
                self.database,
                self.history,
                archive.normalize_snapshot(snapshot(2000), strict=True),
                365,
                now=1000,
            )
        self.assertFalse(self.database.exists())

    def test_legacy_history_is_checked_against_clock_and_snapshot_anchor(self):
        self.history.write_text(json.dumps([snapshot(2401)]), encoding="utf-8")
        with self.assertRaises(archive.ArchiveInputError):
            archive.ingest(self.database, self.history, self.current, 365, now=2000)
        self.assertIsNone(self.marker())

    def test_missing_history_is_not_marked_until_restored(self):
        archive.ingest(self.database, self.history, self.current, 365)
        self.assertIsNone(self.marker())

        self.history.write_text(json.dumps([snapshot(1900)]), encoding="utf-8")
        archive.ingest(self.database, self.history, self.current, 365)
        self.assertEqual("1", self.marker())
        with sqlite3.connect(self.database) as connection:
            epochs = connection.execute(
                "SELECT scraped_at_epoch FROM snapshots ORDER BY scraped_at_epoch"
            ).fetchall()
        self.assertEqual([(1900,), (2000,)], epochs)

    def test_history_larger_than_16_mib_migrates_in_a_bounded_stream(self):
        encoded = json.dumps(snapshot(1900)).encode()
        self.history.write_bytes(b"[" + b" " * (17 * 1024 * 1024) + encoded + b"]")
        archive.ingest(self.database, self.history, self.current, 365)
        self.assertEqual("1", self.marker())
        with sqlite3.connect(self.database) as connection:
            self.assertEqual(2, connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0])

    def test_future_legacy_row_refuses_compaction_without_purging_real_history(self):
        self.history.write_text("[]", encoding="utf-8")
        archive.ingest(self.database, self.history, self.current, 365)
        with sqlite3.connect(self.database) as connection:
            future = archive.normalize_snapshot(snapshot(10_000), strict=True)
            archive.insert_snapshot(connection, future)
            connection.commit()
            before = connection.execute(
                "SELECT scraped_at_epoch FROM snapshots ORDER BY scraped_at_epoch"
            ).fetchall()

        older_current = archive.normalize_snapshot(snapshot(2_100), strict=True)
        with self.assertRaisesRegex(archive.ArchiveInputError, "clock rollback"):
            archive.ingest(self.database, self.history, older_current, 1)

        with sqlite3.connect(self.database) as connection:
            after = connection.execute(
                "SELECT scraped_at_epoch FROM snapshots ORDER BY scraped_at_epoch"
            ).fetchall()
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
