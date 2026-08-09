#!/usr/bin/env python3
"""Focused P0.3 tests for the local SQLite storage boundary."""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest


ROOT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT_DIR / "local"))

from storage import check_integrity, connect_database


V1_SCHEMA = """
    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE snapshots (
        scraped_at_epoch INTEGER PRIMARY KEY,
        scraped_at TEXT NOT NULL,
        five_h_pct REAL,
        five_h_reset TEXT,
        five_h_reset_at INTEGER,
        weekly_pct REAL,
        weekly_reset TEXT,
        weekly_reset_at INTEGER,
        sample_interval_seconds INTEGER,
        history_window_hours REAL,
        limit_id TEXT
    );
"""


def create_v1_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    try:
        with connection:
            connection.executescript(V1_SCHEMA)
            connection.execute("INSERT INTO metadata VALUES ('schema_version', '1')")
            connection.execute(
                """
                INSERT INTO snapshots VALUES
                    (1000, '1970-01-01T00:16:40Z', 80, NULL, NULL,
                     70, NULL, NULL, 900, 192, 'v1')
                """
            )
            connection.execute("PRAGMA user_version = 1")
    finally:
        connection.close()


@contextmanager
def managed_database(path: Path, *, read_only: bool = False):
    connection = connect_database(path, read_only=read_only)
    try:
        yield connection
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
    finally:
        connection.close()


class StorageP0Tests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="storage-p0-")
        self.directory = Path(self._temporary_directory.name)

    def tearDown(self) -> None:
        self._temporary_directory.cleanup()

    def test_v1_migration_keeps_one_restorable_backup(self) -> None:
        database = self.directory / "archive.sqlite3"
        create_v1_database(database)

        with managed_database(database) as connection:
            self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0], "wal")
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(
                connection.execute("SELECT limit_id FROM snapshots").fetchone()[0],
                "v1",
            )
            check_integrity(connection)

        backups = [self.directory / "archive.sqlite3.v1.bak"]
        self.assertTrue(backups[0].is_file())
        self.assertEqual([path.name for path in backups], ["archive.sqlite3.v1.bak"])
        backup = sqlite3.connect(backups[0])
        try:
            with backup:
                self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 1)
                self.assertEqual(
                    backup.execute("SELECT limit_id FROM snapshots").fetchone()[0],
                    "v1",
                )
                self.assertEqual(backup.execute("PRAGMA quick_check").fetchone()[0], "ok")
        finally:
            backup.close()

        # Reopening an already migrated archive must not create a second v1
        # copy or overwrite the first one.
        with managed_database(database) as connection:
            check_integrity(connection)
        self.assertEqual(
            sorted(
                path.name
                for path in self.directory.glob("archive.sqlite3.v1.*")
                if path.name == "archive.sqlite3.v1.bak"
            ),
            ["archive.sqlite3.v1.bak"],
        )

    def test_contention_is_bounded_and_does_not_remove_active_wal(self) -> None:
        database = self.directory / "archive.sqlite3"
        with managed_database(database) as connection:
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1, "1970-01-01T00:00:01Z", 90, None, None, 90, None, None, 900, 1, "seed"),
            )

        blocker = sqlite3.connect(database, timeout=0.05)
        try:
            self.assertEqual(blocker.execute("PRAGMA journal_mode").fetchone()[0], "wal")
            blocker.execute("BEGIN IMMEDIATE")
            blocker.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (2, "1970-01-01T00:00:02Z", 89, None, None, 89, None, None, 900, 1, "held"),
            )
            wal_path = database.with_name(f"{database.name}-wal")
            self.assertTrue(wal_path.exists(), "the write transaction should have an active WAL")
            wal_before = wal_path.read_bytes()

            started = time.monotonic()
            with self.assertRaises(sqlite3.DatabaseError):
                connect_database(database)
            elapsed = time.monotonic() - started

            self.assertLess(elapsed, 3.0, "lock handling exceeded the bounded retry window")
            self.assertTrue(wal_path.exists(), "failed setup must not remove an active WAL")
            self.assertEqual(wal_path.read_bytes(), wal_before)
            check_integrity(blocker)
        finally:
            blocker.rollback()
            blocker.close()

    def test_v1_migration_keeps_an_active_wal_open_for_readers(self) -> None:
        database = self.directory / "archive.sqlite3"
        create_v1_database(database)
        reader = sqlite3.connect(database, timeout=0.05)
        writer = sqlite3.connect(database, timeout=0.05)
        try:
            self.assertEqual(reader.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            reader.execute("BEGIN")
            self.assertEqual(reader.execute("SELECT limit_id FROM snapshots").fetchone()[0], "v1")

            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("UPDATE metadata SET value = '1' WHERE key = 'schema_version'")
            writer.commit()
            wal_path = database.with_name(f"{database.name}-wal")
            self.assertTrue(wal_path.exists())

            with managed_database(database) as connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)
                check_integrity(connection)
            self.assertTrue(wal_path.exists(), "migration must not delete a reader's active WAL")
        finally:
            reader.rollback()
            reader.close()
            writer.close()

    def test_wal_reader_and_writer_run_concurrently_and_remain_integral(self) -> None:
        database = self.directory / "archive.sqlite3"
        with managed_database(database) as connection:
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1, "1970-01-01T00:00:01Z", 90, None, None, 90, None, None, 900, 1, "seed"),
            )

        barrier = threading.Barrier(2)
        errors: list[BaseException] = []
        observed_counts: list[int] = []

        def writer() -> None:
            try:
                with managed_database(database) as connection:
                    barrier.wait()
                    for index in range(2, 22):
                        connection.execute(
                            "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            (index, f"1970-01-01T00:00:{index:02d}Z", 90, None, None, 90, None, None, 900, 1, "writer"),
                        )
                        connection.commit()
            except BaseException as exc:  # report thread failures in the test thread
                errors.append(exc)
                try:
                    barrier.abort()
                except threading.BrokenBarrierError:
                    pass

        def reader() -> None:
            try:
                with managed_database(database, read_only=True) as connection:
                    barrier.wait()
                    for _ in range(20):
                        observed_counts.append(
                            connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0]
                        )
                        time.sleep(0.002)
                    check_integrity(connection)
            except BaseException as exc:
                errors.append(exc)
                try:
                    barrier.abort()
                except threading.BrokenBarrierError:
                    pass

        writer_thread = threading.Thread(target=writer)
        reader_thread = threading.Thread(target=reader)
        writer_thread.start()
        reader_thread.start()
        writer_thread.join()
        reader_thread.join()

        if errors:
            raise errors[0]
        self.assertTrue(observed_counts)
        self.assertGreaterEqual(min(observed_counts), 1)
        with managed_database(database, read_only=True) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0], 21)
            check_integrity(connection)


if __name__ == "__main__":
    unittest.main()
