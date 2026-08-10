from pathlib import Path
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
import threading
import time
import unittest
import subprocess
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))

import storage


def create_v1_database(path: Path, limit_id: str = "v1") -> None:
    with sqlite3.connect(path) as connection:
        connection.executescript(
            """
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
            INSERT INTO metadata VALUES ('schema_version', '1');
            PRAGMA user_version = 1;
            """
        )
        connection.execute(
            "INSERT INTO snapshots VALUES (1000, '1970-01-01T00:16:40Z', 80, NULL, NULL, 70, NULL, NULL, 900, 192, ?)",
            (limit_id,),
        )


def insert_snapshot(connection: sqlite3.Connection, epoch: int) -> None:
    connection.execute(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            epoch,
            "1970-01-01T00:16:40Z",
            80,
            None,
            None,
            70,
            None,
            None,
            900,
            192,
            "test",
        ),
    )


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.database = self.root / "archive.sqlite3"
        with storage._READ_ONLY_INTEGRITY_CACHE_LOCK:
            storage._READ_ONLY_INTEGRITY_CACHE.clear()

    def tearDown(self):
        self.directory.cleanup()

    def test_v1_migration_creates_one_verified_restorable_backup(self):
        create_v1_database(self.database)

        connection = storage.connect_database(self.database)
        try:
            self.assertEqual(2, connection.execute("PRAGMA user_version").fetchone()[0])
            self.assertEqual("wal", connection.execute("PRAGMA journal_mode").fetchone()[0])
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])
            self.assertEqual("v1", connection.execute("SELECT limit_id FROM snapshots").fetchone()[0])
        finally:
            connection.close()

        backup = self.database.with_name(self.database.name + storage.V1_BACKUP_SUFFIX)
        self.assertEqual(0o600, stat.S_IMODE(backup.stat().st_mode))
        backup_mtime = backup.stat().st_mtime_ns
        restored = self.root / "restored-v1.sqlite3"
        shutil.copyfile(backup, restored)
        with sqlite3.connect(restored) as connection:
            self.assertEqual(1, connection.execute("PRAGMA user_version").fetchone()[0])
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])
            self.assertEqual("v1", connection.execute("SELECT limit_id FROM snapshots").fetchone()[0])

        connection = storage.connect_database(self.database)
        connection.close()
        self.assertEqual(backup_mtime, backup.stat().st_mtime_ns)
        self.assertEqual(
            [backup], list(self.root.glob(f"*{storage.V1_BACKUP_SUFFIX}"))
        )

    def test_v1_migration_never_reuses_backup_from_replaced_database(self):
        create_v1_database(self.database, "first")
        connection = storage.connect_database(self.database)
        connection.close()
        first_backup = self.database.with_name(
            self.database.name + storage.V1_BACKUP_SUFFIX
        )
        first_bytes = first_backup.read_bytes()

        self.database.unlink()
        create_v1_database(self.database, "second")
        connection = storage.connect_database(self.database)
        connection.close()

        backups = list(self.root.glob(f"*{storage.V1_BACKUP_SUFFIX}"))
        self.assertEqual(2, len(backups))
        self.assertEqual(first_bytes, first_backup.read_bytes())
        second_backup = next(path for path in backups if path != first_backup)
        with sqlite3.connect(second_backup) as connection:
            self.assertEqual(
                "second", connection.execute("SELECT limit_id FROM snapshots").fetchone()[0]
            )

    def test_wal_remains_available_during_concurrent_read(self):
        writer = storage.connect_database(self.database)
        try:
            insert_snapshot(writer, 1000)
            writer.commit()
            writer.execute("BEGIN IMMEDIATE")
            insert_snapshot(writer, 1001)
            wal_path = Path(str(self.database) + "-wal")
            self.assertTrue(wal_path.exists())

            reader = storage.connect_database(self.database, read_only=True)
            try:
                self.assertEqual(1, reader.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0])
                self.assertEqual("ok", reader.execute("PRAGMA quick_check").fetchone()[0])
            finally:
                reader.close()
            self.assertTrue(wal_path.exists())
            writer.rollback()
        finally:
            writer.close()

    def test_read_only_integrity_cache_tracks_database_identity_and_writes(self):
        connection = storage.connect_database(self.database)
        connection.close()
        replacement = self.root / "replacement.sqlite3"
        replacement_connection = storage.connect_database(replacement)
        replacement_connection.close()
        real_check = storage.check_integrity

        with mock.patch.object(storage, "check_integrity", wraps=real_check) as checked:
            for _ in range(2):
                reader = storage.connect_database(self.database, read_only=True)
                reader.close()
            self.assertEqual(1, checked.call_count)

            with sqlite3.connect(self.database) as writer:
                insert_snapshot(writer, 1000)
            reader = storage.connect_database(self.database, read_only=True)
            reader.close()
            self.assertEqual(2, checked.call_count)

            os.replace(replacement, self.database)
            reader = storage.connect_database(self.database, read_only=True)
            reader.close()
            self.assertEqual(3, checked.call_count)

    def test_concurrent_readers_share_one_cached_integrity_check(self):
        connection = storage.connect_database(self.database)
        connection.close()
        real_check = storage.check_integrity
        barrier = threading.Barrier(8)
        errors = []

        def delayed_check(connection):
            time.sleep(0.02)
            return real_check(connection)

        def read_database():
            connection = None
            try:
                barrier.wait()
                connection = storage.connect_database(self.database, read_only=True)
                connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()
            except BaseException as exc:
                errors.append(exc)
            finally:
                if connection is not None:
                    connection.close()

        with mock.patch.object(storage, "check_integrity", side_effect=delayed_check) as checked:
            threads = [threading.Thread(target=read_database) for _ in range(8)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())

        if errors:
            raise errors[0]
        self.assertEqual(1, checked.call_count)

    def test_read_only_integrity_cache_invalidates_when_shm_changes(self):
        connection = storage.connect_database(self.database)
        connection.close()
        real_check = storage.check_integrity

        with mock.patch.object(storage, "check_integrity", wraps=real_check) as checked:
            reader = storage.connect_database(self.database, read_only=True)
            shm_path = Path(str(self.database) + "-shm")
            self.assertTrue(shm_path.exists())
            replacement = self.root / "archive.sqlite3-shm-replacement"
            shutil.copyfile(shm_path, replacement)
            os.replace(replacement, shm_path)
            reader.close()

            reader = storage.connect_database(self.database, read_only=True)
            reader.close()

        self.assertEqual(2, checked.call_count)

    def test_recovery_preserves_a_non_checkpointed_wal_as_one_backup_set(self):
        completed = subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "import os,sqlite3,sys; "
                    "c=sqlite3.connect(sys.argv[1]); "
                    "c.execute('PRAGMA journal_mode=WAL'); "
                    "c.execute('PRAGMA wal_autocheckpoint=0'); "
                    "c.execute('CREATE TABLE evidence(value TEXT)'); "
                    "c.execute(\"INSERT INTO evidence VALUES ('from-wal')\"); "
                    "c.commit(); os._exit(0)"
                ),
                str(self.database),
            ],
            check=False,
        )
        self.assertEqual(0, completed.returncode)
        self.assertTrue(Path(str(self.database) + "-wal").exists())

        rebuilt = self.root / "rebuilt.sqlite3"
        connection = storage.connect_database(rebuilt)
        connection.close()
        backup = storage.publish_rebuilt_database(self.database, rebuilt)

        self.assertTrue(backup.exists())
        self.assertTrue(Path(str(backup) + "-wal").exists())
        with sqlite3.connect(backup) as connection:
            self.assertEqual(
                "from-wal", connection.execute("SELECT value FROM evidence").fetchone()[0]
            )
        with sqlite3.connect(self.database) as connection:
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])

    def test_recovery_contention_is_bounded_and_does_not_touch_active_sidecars(self):
        holder = storage.connect_database(self.database)
        insert_snapshot(holder, 1000)
        holder.commit()
        holder.execute("PRAGMA wal_autocheckpoint = 0")
        insert_snapshot(holder, 1001)
        holder.commit()
        wal_path = Path(str(self.database) + "-wal")
        self.assertTrue(wal_path.exists())
        source_before = self.database.read_bytes()
        wal_before = wal_path.read_bytes()

        rebuilt = self.root / "rebuilt-contention.sqlite3"
        connection = storage.connect_database(rebuilt)
        connection.close()
        started = time.monotonic()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                storage.publish_rebuilt_database(self.database, rebuilt)
            elapsed = time.monotonic() - started
            self.assertGreater(elapsed, 0.2)
            self.assertLess(elapsed, 2.0)
            self.assertEqual(source_before, self.database.read_bytes())
            self.assertEqual(wal_before, wal_path.read_bytes())
            self.assertEqual([], list(self.root.glob("archive.sqlite3.corrupt.*")))
        finally:
            holder.close()

    def test_concurrent_reader_and_writer_finish_with_valid_database(self):
        connection = storage.connect_database(self.database)
        connection.close()
        barrier = threading.Barrier(2)
        errors = []

        def write_rows():
            connection = None
            try:
                connection = storage.connect_database(self.database)
                barrier.wait()
                for epoch in range(1000, 1040):
                    insert_snapshot(connection, epoch)
                    connection.commit()
                    time.sleep(0.001)
            except BaseException as exc:
                errors.append(exc)
            finally:
                if connection is not None:
                    connection.close()

        def read_rows():
            connection = None
            try:
                connection = storage.connect_database(self.database, read_only=True)
                barrier.wait()
                for _ in range(40):
                    connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()
                    time.sleep(0.001)
            except BaseException as exc:
                errors.append(exc)
            finally:
                if connection is not None:
                    connection.close()

        threads = [threading.Thread(target=write_rows), threading.Thread(target=read_rows)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        if errors:
            raise errors[0]

        with sqlite3.connect(self.database) as connection:
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])
            self.assertEqual(40, connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0])

    def test_short_contention_retries_and_prolonged_contention_is_bounded(self):
        holder = storage.connect_database(self.database)
        holder.execute("BEGIN IMMEDIATE")
        errors = []

        def connect_after_lock():
            connection = None
            try:
                connection = storage.connect_database(self.database)
            except BaseException as exc:
                errors.append(exc)
            finally:
                if connection is not None:
                    connection.close()

        thread = threading.Thread(target=connect_after_lock)
        thread.start()
        time.sleep(0.18)
        holder.rollback()
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual([], errors)

        holder.execute("BEGIN IMMEDIATE")
        started = time.monotonic()
        try:
            with self.assertRaises(sqlite3.OperationalError) as caught:
                storage.connect_database(self.database)
        finally:
            elapsed = time.monotonic() - started
            holder.rollback()
            holder.close()
        self.assertTrue(storage.is_lock_error(caught.exception))
        self.assertGreater(elapsed, 0.2)
        self.assertLess(elapsed, 2.0)

        connection = storage.connect_database(self.database)
        try:
            self.assertEqual("ok", connection.execute("PRAGMA quick_check").fetchone()[0])
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main()
