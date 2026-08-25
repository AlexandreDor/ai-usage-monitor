#!/usr/bin/env python3
import os
import pathlib
import json
import hashlib
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))

import archive  # noqa: E402
import analytics  # noqa: E402
import storage  # noqa: E402


class StorageDurabilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "archive.sqlite3"

    def tearDown(self):
        self.directory.cleanup()

    def test_legacy_migration_has_recoverable_backup_and_wal(self):
        with sqlite3.connect(self.path) as connection:
            connection.executescript(
                """
                CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE snapshots(
                  scraped_at_epoch INTEGER PRIMARY KEY, scraped_at TEXT NOT NULL,
                  five_h_pct REAL, five_h_reset TEXT, five_h_reset_at INTEGER,
                  weekly_pct REAL, weekly_reset TEXT, weekly_reset_at INTEGER,
                  sample_interval_seconds INTEGER, history_window_hours REAL,
                  limit_id TEXT
                );
                INSERT INTO metadata VALUES ('schema_version', '1');
                INSERT INTO snapshots VALUES (100, '1970-01-01T00:01:40Z', 80, NULL, NULL, 60, NULL, NULL, NULL, NULL, 'test');
                PRAGMA user_version = 1;
                """
            )

        with storage.connect_database(self.path) as connection:
            self.assertEqual(("wal",), connection.execute("PRAGMA journal_mode").fetchone())
            self.assertEqual((1,), connection.execute("SELECT COUNT(*) FROM snapshots").fetchone())

        backups = list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))
        self.assertEqual(1, len(backups))
        self.assertEqual(0o600, backups[0].stat().st_mode & 0o777)
        with sqlite3.connect(backups[0]) as connection:
            self.assertEqual((1,), connection.execute("SELECT COUNT(*) FROM snapshots").fetchone())
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())

        storage.connect_database(self.path).close()
        self.assertEqual(1, len(list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))))

    def test_v4_delete_gets_one_backup_before_wal_transition(self):
        connection = storage.connect_database(self.path)
        connection.close()
        storage.checkpoint_database(self.path, mode="TRUNCATE")
        with sqlite3.connect(self.path) as connection:
            self.assertEqual(("delete",), connection.execute("PRAGMA journal_mode = DELETE").fetchone())

        with storage.connect_database(self.path) as connection:
            self.assertEqual(("wal",), connection.execute("PRAGMA journal_mode").fetchone())
        backups = list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))
        self.assertEqual(1, len(backups))
        with sqlite3.connect(backups[0]) as connection:
            self.assertEqual((4,), connection.execute("PRAGMA user_version").fetchone())
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())

        with storage.connect_database(self.path) as connection:
            self.assertEqual(("wal",), connection.execute("PRAGMA journal_mode").fetchone())
        self.assertEqual(1, len(list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))))

    def test_valid_v4_wal_open_does_not_repair_or_backup(self):
        connection = storage.connect_database(self.path)
        connection.close()
        connection = storage.connect_database(self.path)
        self.assertEqual(0, connection.total_changes)
        self.assertEqual(("wal",), connection.execute("PRAGMA journal_mode").fetchone())
        connection.close()
        self.assertEqual([], list(self.path.parent.glob(f"{self.path.name}.pre-migration.*")))

    def test_existing_limit_ids_are_migrated_across_archive_and_analytics(self):
        raw_id = "raw-secret-account-id"
        connection = storage.connect_database(self.path)
        with connection:
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1_700_000_000, "2023-11-14T22:13:20Z", 80, "later", 1_700_000_100,
                 60, "later", 1_700_001_000, 900, 192, raw_id),
            )
            connection.execute(
                "INSERT INTO quota_anomalies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ("anomaly-1", f"{raw_id}|5h|quota_increase|episode", "quota_increase", "5h",
                 raw_id, 1_700_000_000, 20, 80, None, None, "unrelated default setting", None),
            )
            connection.execute(
                "INSERT INTO anomaly_detector_state VALUES (?, ?, ?, ?)",
                (raw_id, "5h", json.dumps({"limit_id": raw_id, "previous": "unrelated default setting"}), 1_700_000_000),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES (?, ?)",
                ("anomaly_active_limit_id", raw_id),
            )
            connection.execute(
                "INSERT INTO collector_state VALUES (?, ?, ?, ?)",
                ("codex", "fixture", json.dumps({"limit_id": raw_id}), 1_700_000_000),
            )
        connection.close()

        # The fixture represents a pre-contract archive rather than a marked
        # v4 archive with a newly inserted raw value.
        with sqlite3.connect(self.path) as connection:
            connection.execute(
                "DELETE FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            )

        connection = storage.connect_database(self.path)
        try:
            canonical = "limit-" + hashlib.sha256(raw_id.encode()).hexdigest()
            table_names = [
                row[0] for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
                )
            ]
            for table in table_names:
                for row in connection.execute(f'SELECT * FROM "{table}"'):
                    self.assertNotIn(raw_id, json.dumps(row, default=str))
            self.assertEqual((canonical,), connection.execute("SELECT limit_id FROM snapshots").fetchone())
            self.assertEqual((canonical,), connection.execute("SELECT limit_id FROM quota_anomalies").fetchone())
            self.assertEqual(
                ("unrelated default setting",),
                connection.execute("SELECT message FROM quota_anomalies").fetchone(),
            )
            self.assertEqual(
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION,),
                connection.execute(
                    "SELECT value FROM metadata WHERE key = ?",
                    (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
                ).fetchone(),
            )
        finally:
            connection.close()

        payload = analytics.build_payload(
            self.path,
            ROOT / "local" / "pricing.json",
            {"range": "24h"},
            now=1_700_000_100,
        )
        self.assertNotIn(raw_id, json.dumps(payload))
        self.assertTrue(list(self.path.parent.glob(f"{self.path.name}.pre-migration.*")))

    def test_limit_id_migration_is_semantic_marked_and_idempotent(self):
        raw_id = "legacy-secret-account-id"
        raw_digest_shaped = "limit-" + "a" * 64
        raw_digest = storage.opaque_limit_id_from_raw(raw_digest_shaped)
        expected = storage.opaque_limit_id_from_raw(raw_id)
        sentinel = "unrelated default setting"

        connection = storage.connect_database(self.path)
        with connection:
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1_700_000_000, "2023-11-14T22:13:20Z", 80, None, None,
                 60, None, None, 900, 192, raw_id),
            )
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1_700_000_100, "2023-11-14T22:15:00Z", 70, None, None,
                 50, None, None, 900, 192, raw_digest_shaped),
            )
            connection.execute(
                "INSERT INTO quota_anomalies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ("anomaly-raw", f"{raw_id}|5h|quota_increase|episode", "quota_increase", "5h",
                 raw_id, 1_700_000_000, 20, 80, None, None, sentinel, None),
            )
            connection.execute(
                "INSERT INTO quota_anomalies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ("anomaly-digest", f"{raw_digest_shaped}|weekly|reset_shift|episode-2",
                 "reset_shift", "weekly", raw_digest_shaped, 1_700_000_100,
                 20, 80, None, None, sentinel, None),
            )
            connection.execute(
                "INSERT INTO anomaly_detector_state VALUES (?, ?, ?, ?)",
                (raw_digest_shaped, "weekly", json.dumps({"limit_id": raw_digest_shaped,
                 "default": sentinel}), 1_700_000_100),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES (?, ?)",
                ("anomaly_active_limit_id", raw_id),
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES (?, ?)",
                ("unrelated-default", sentinel),
            )
            connection.execute(
                "INSERT INTO collector_state VALUES (?, ?, ?, ?)",
                ("codex", "semantic-id", json.dumps({"limit_id": raw_id,
                 "default": sentinel}), 1_700_000_000),
            )
            connection.execute(
                "INSERT INTO collector_state VALUES (?, ?, ?, ?)",
                ("codex", "sentinel", json.dumps({"default": sentinel}), 1_700_000_000),
            )
        connection.close()

        # This is an archive written before P1.17: no marker means even a
        # digest-looking server value is still raw and must be hashed.
        with sqlite3.connect(self.path) as connection:
            connection.execute(
                "DELETE FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            )

        # The read-only analytics projection gets the same migration in memory,
        # while the durable archive remains untouched until a writer opens it.
        with storage.connect_database(self.path, read_only=True) as connection:
            self.assertEqual((expected,), connection.execute(
                "SELECT limit_id FROM snapshots WHERE scraped_at_epoch = 1700000000"
            ).fetchone())
            self.assertEqual((raw_digest,), connection.execute(
                "SELECT limit_id FROM snapshots WHERE scraped_at_epoch = 1700000100"
            ).fetchone())
            self.assertEqual((storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION,), connection.execute(
                "SELECT value FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            ).fetchone())
        payload = analytics.build_payload(
            self.path, ROOT / "local" / "pricing.json", {"range": "24h"},
            now=1_700_000_100,
        )
        self.assertNotIn(raw_id, json.dumps(payload))
        self.assertNotIn(raw_digest_shaped, json.dumps(payload))

        with sqlite3.connect(self.path) as connection:
            self.assertIsNone(connection.execute(
                "SELECT value FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            ).fetchone())
            self.assertEqual((raw_id,), connection.execute(
                "SELECT limit_id FROM snapshots WHERE scraped_at_epoch = 1700000000"
            ).fetchone())

        with storage.connect_database(self.path) as connection:
            self.assertEqual(
                [(expected,), (raw_digest,)],
                connection.execute(
                    "SELECT limit_id FROM snapshots ORDER BY scraped_at_epoch"
                ).fetchall(),
            )
            self.assertEqual((expected,), connection.execute(
                "SELECT limit_id FROM quota_anomalies WHERE anomaly_id = 'anomaly-raw'"
            ).fetchone())
            self.assertEqual((raw_digest,), connection.execute(
                "SELECT limit_id FROM quota_anomalies WHERE anomaly_id = 'anomaly-digest'"
            ).fetchone())
            self.assertEqual((f"{expected}|5h|quota_increase|episode",), connection.execute(
                "SELECT dedupe_key FROM quota_anomalies WHERE anomaly_id = 'anomaly-raw'"
            ).fetchone())
            self.assertEqual((raw_digest,), connection.execute(
                "SELECT limit_id FROM anomaly_detector_state"
            ).fetchone())
            state = json.loads(connection.execute(
                "SELECT state_json FROM anomaly_detector_state"
            ).fetchone()[0])
            self.assertEqual(raw_digest, state["limit_id"])
            self.assertEqual(sentinel, state["default"])
            self.assertEqual((expected,), connection.execute(
                "SELECT value FROM metadata WHERE key = 'anomaly_active_limit_id'"
            ).fetchone())
            self.assertEqual((sentinel,), connection.execute(
                "SELECT value FROM metadata WHERE key = 'unrelated-default'"
            ).fetchone())
            self.assertEqual(json.dumps({"default": sentinel}), connection.execute(
                "SELECT state_json FROM collector_state WHERE state_key = 'sentinel'"
            ).fetchone()[0])
            marker = connection.execute(
                "SELECT value FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            ).fetchone()
            self.assertEqual((storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION,), marker)

        # A marked archive is a no-op on the second writable open: in
        # particular, the opaque values are not hashed a second time.
        with storage.connect_database(self.path) as connection:
            self.assertEqual(
                [(expected,), (raw_digest,)],
                connection.execute(
                    "SELECT limit_id FROM snapshots ORDER BY scraped_at_epoch"
                ).fetchall(),
            )

    def test_limit_id_marker_is_not_written_when_migration_rolls_back(self):
        raw_id = "rollback-secret-account-id"
        connection = storage.connect_database(self.path)
        with connection:
            connection.execute(
                "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (1_700_000_000, "2023-11-14T22:13:20Z", 80, None, None,
                 60, None, None, 900, 192, raw_id),
            )
            connection.execute(
                "DELETE FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            )
        connection.close()

        with mock.patch.object(
            storage, "_migrate_limit_ids",
            side_effect=sqlite3.DatabaseError("simulated ID migration failure"),
        ):
            with self.assertRaisesRegex(sqlite3.DatabaseError, "simulated ID migration failure"):
                storage.connect_database(self.path)

        with sqlite3.connect(self.path) as connection:
            self.assertIsNone(connection.execute(
                "SELECT value FROM metadata WHERE key = ?",
                (storage.PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
            ).fetchone())
            self.assertEqual((raw_id,), connection.execute(
                "SELECT limit_id FROM snapshots"
            ).fetchone())

    def test_wal_failure_does_not_commit_legacy_schema_migration(self):
        with sqlite3.connect(self.path) as connection:
            connection.executescript(
                """
                CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE snapshots(
                  scraped_at_epoch INTEGER PRIMARY KEY, scraped_at TEXT NOT NULL,
                  five_h_pct REAL, five_h_reset TEXT, five_h_reset_at INTEGER,
                  weekly_pct REAL, weekly_reset TEXT, weekly_reset_at INTEGER,
                  sample_interval_seconds INTEGER, history_window_hours REAL,
                  limit_id TEXT
                );
                INSERT INTO metadata VALUES ('schema_version', '1');
                PRAGMA user_version = 1;
                """
            )

        with mock.patch.object(
            storage,
            "_enable_wal",
            side_effect=sqlite3.OperationalError("simulated journal_mode failure"),
        ):
            with self.assertRaises(sqlite3.OperationalError):
                storage.connect_database(self.path)

        with sqlite3.connect(self.path) as connection:
            self.assertEqual((1,), connection.execute("PRAGMA user_version").fetchone())
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())
        backups = list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))
        self.assertEqual(1, len(backups))
        with sqlite3.connect(backups[0]) as connection:
            self.assertEqual((1,), connection.execute("PRAGMA user_version").fetchone())
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())

    def test_reader_can_query_while_writer_transaction_is_open(self):
        seed = storage.connect_database(self.path)
        with seed:
            seed.execute("INSERT INTO metadata(key, value) VALUES ('visible', 'yes')")
        seed.close()
        writer = storage.connect_database(self.path)
        reader = storage.connect_database(self.path, read_only=True)
        try:
            writer.execute("BEGIN IMMEDIATE")
            writer.execute("UPDATE metadata SET value = 'pending' WHERE key = 'visible'")
            self.assertEqual(("yes",), reader.execute("SELECT value FROM metadata WHERE key = 'visible'").fetchone())
            writer.commit()
            self.assertEqual(("pending",), reader.execute("SELECT value FROM metadata WHERE key = 'visible'").fetchone())
        finally:
            reader.close()
            writer.close()

    def test_retries_only_busy_and_are_bounded(self):
        calls = []

        def eventually():
            calls.append(1)
            if len(calls) < 3:
                raise sqlite3.OperationalError("database is locked")
            return "ok"

        with mock.patch.object(storage.time, "sleep") as sleep:
            self.assertEqual("ok", storage.retry_sqlite_operation(eventually))
        self.assertEqual(3, len(calls))
        self.assertEqual(2, sleep.call_count)

        calls.clear()
        with mock.patch.object(storage.time, "sleep"):
            with self.assertRaises(sqlite3.OperationalError):
                storage.retry_sqlite_operation(lambda: (_ for _ in ()).throw(sqlite3.OperationalError("database is locked")))
        calls.clear()
        with self.assertRaises(sqlite3.OperationalError):
            storage.retry_sqlite_operation(lambda: (_ for _ in ()).throw(sqlite3.OperationalError("disk I/O error")))
        self.assertEqual([], calls)
        self.assertFalse(storage.is_busy_error(sqlite3.OperationalError("disk I/O error")))

    def test_cursor_batch_and_explicit_checkpoint_modes(self):
        connection = storage.connect_database(self.path)
        connection.execute("PRAGMA wal_autocheckpoint = 0")
        cursor = connection.cursor()
        self.assertIsInstance(cursor, storage.RetryingCursor)
        cursor.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [("batch-a", "1"), ("batch-b", "2")],
        )
        connection.commit()
        wal, _ = storage.wal_sidecar_paths(self.path)
        self.assertTrue(wal.exists())
        before_passive = wal.stat().st_size
        self.assertGreater(before_passive, 0)
        passive = storage.checkpoint_database(connection, mode="PASSIVE")
        self.assertEqual(0, passive[0])
        self.assertTrue(wal.exists())
        self.assertGreater(wal.stat().st_size, 0)
        truncate = storage.checkpoint_database(connection, mode="TRUNCATE")
        self.assertEqual((0, 0, 0), truncate)
        self.assertTrue(not wal.exists() or wal.stat().st_size == 0)
        connection.close()

    def test_real_lock_retries_and_cursor_execute(self):
        connection = storage.connect_database(self.path)
        connection.execute("INSERT INTO metadata(key, value) VALUES ('locked', 'before')")
        connection.commit()
        connection.close()
        locker = sqlite3.connect(self.path, timeout=0, check_same_thread=False)
        locker.execute("PRAGMA busy_timeout = 0")
        locker.execute("BEGIN IMMEDIATE")
        locker.execute("UPDATE metadata SET value = 'held' WHERE key = 'locked'")
        writer = sqlite3.connect(
            self.path,
            timeout=storage.SQLITE_BUSY_TIMEOUT_MS / 1000,
            factory=storage.RetryingConnection,
            check_same_thread=False,
        )
        writer.execute(f"PRAGMA busy_timeout = {storage.SQLITE_BUSY_TIMEOUT_MS}")
        cursor = writer.cursor()
        result = []

        def write_while_locked():
            try:
                cursor.execute("UPDATE metadata SET value = 'after' WHERE key = 'locked'")
                writer.commit()
                result.append("ok")
            except Exception as exc:  # pragma: no cover - asserted below
                result.append(exc)

        worker = threading.Thread(target=write_while_locked)
        worker.start()
        time.sleep(0.35)
        locker.rollback()
        locker.close()
        worker.join(timeout=3)
        writer.close()
        self.assertEqual(["ok"], result)

        with sqlite3.connect(self.path) as connection:
            self.assertEqual(("after",), connection.execute("SELECT value FROM metadata WHERE key = 'locked'").fetchone())

    def test_corrupt_recovery_preserves_sidecars(self):
        connection = storage.connect_database(self.path)
        with connection:
            connection.execute("INSERT INTO metadata(key, value) VALUES ('sidecars', 'kept')")
        connection.close()
        wal, shm = storage.wal_sidecar_paths(self.path)
        wal.write_bytes(b"wal sidecar")
        shm.write_bytes(b"shm sidecar")
        backup = archive.backup_corrupt_database(self.path)
        self.assertTrue(backup.is_file())
        self.assertEqual(b"wal sidecar", backup.with_name(backup.name + "-wal").read_bytes())
        self.assertEqual(b"shm sidecar", backup.with_name(backup.name + "-shm").read_bytes())

    def test_corrupt_recovery_skips_sidecar_collision(self):
        connection = storage.connect_database(self.path)
        connection.close()
        timestamp = 1234567890
        collision = self.path.with_name(f"{self.path.name}.corrupt.{timestamp}-wal")
        collision.write_bytes(b"do not overwrite")
        with mock.patch.object(archive.time, "time", return_value=timestamp):
            backup = archive.backup_corrupt_database(self.path)
        self.assertTrue(backup.name.endswith(f".corrupt.{timestamp}.1"))
        self.assertEqual(b"do not overwrite", collision.read_bytes())
        self.assertTrue(backup.is_file())

    def test_insecure_parent_refuses_writable_open_without_backup(self):
        insecure = pathlib.Path(self.directory.name) / "insecure"
        insecure.mkdir()
        database = insecure / "archive.sqlite3"
        database.write_bytes(b"preserve this file")
        os.chmod(insecure, 0o777)
        with self.assertRaisesRegex(OSError, "group/other-writable"):
            storage.connect_database(database)
        self.assertEqual(b"preserve this file", database.read_bytes())
        self.assertEqual([], list(insecure.glob("archive.sqlite3.pre-migration.*")))

    def test_insecure_parent_refuses_corrupt_recovery_without_moving_sources(self):
        insecure = pathlib.Path(self.directory.name) / "insecure-recovery"
        insecure.mkdir()
        database = insecure / "archive.sqlite3"
        wal, shm = storage.wal_sidecar_paths(database)
        database.write_bytes(b"corrupt archive")
        wal.write_bytes(b"wal source")
        shm.write_bytes(b"shm source")
        os.chmod(insecure, 0o777)
        with self.assertRaisesRegex(OSError, "group/other-writable"):
            archive.backup_corrupt_database(database)
        self.assertEqual(b"corrupt archive", database.read_bytes())
        self.assertEqual(b"wal source", wal.read_bytes())
        self.assertEqual(b"shm source", shm.read_bytes())
        self.assertEqual([], list(insecure.glob("archive.sqlite3.corrupt.*")))


if __name__ == "__main__":
    unittest.main()
