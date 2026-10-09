#!/usr/bin/env python3
import fcntl
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import backup
import operations
import storage


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runtime = pathlib.Path(self.temporary.name)
        self.database = self.runtime / "archive.sqlite3"
        self.destination = self.runtime / "backups"
        self.writer = storage.connect_database(self.database)

    def tearDown(self):
        self.writer.close()
        self.temporary.cleanup()

    def create(self, **kwargs):
        return backup.create_backup(self.database, self.destination, **kwargs)

    def files(self):
        return list(self.destination.glob("codex-usage-*.sqlite3"))

    def cli(self, *extra):
        return subprocess.run(
            [sys.executable, str(ROOT / "local" / "backup.py"), "--database", str(self.database),
             "--destination-dir", str(self.destination), "--status-json", *extra],
            text=True, capture_output=True, check=False,
        )

    def test_live_wal_backup_includes_committed_rows_and_restores(self):
        self.writer.execute("PRAGMA wal_autocheckpoint = 0")
        with self.writer:
            self.writer.execute("INSERT INTO snapshots (scraped_at_epoch,scraped_at) VALUES (1,'first')")
            self.writer.execute("INSERT INTO token_usage_events (occurred_at_epoch,source,provider,model,"
                                "input_tokens,cache_read_tokens,cache_write_tokens,output_tokens,"
                                "reasoning_tokens,external_id,imported,quality) "
                                "VALUES (1,'codex','openai','test',12,0,0,5,0,'event-1',0,'exact')")
        self.assertTrue(pathlib.Path(str(self.database) + "-wal").exists())
        self.writer.execute("BEGIN")
        self.writer.execute("INSERT INTO snapshots (scraped_at_epoch,scraped_at) VALUES (2,'uncommitted')")
        result = self.create()
        self.writer.rollback()
        path = self.destination / result["backup"]
        self.assertEqual(0o700, self.destination.stat().st_mode & 0o777)
        self.assertEqual(0o600, path.stat().st_mode & 0o777)
        with closing(sqlite3.connect(path)) as restored:
            self.assertEqual(("ok",), restored.execute("PRAGMA quick_check").fetchone())
            self.assertEqual((1,), restored.execute("SELECT COUNT(*) FROM snapshots").fetchone())
            self.assertEqual((12,), restored.execute("SELECT input_tokens FROM token_usage_events").fetchone())
            self.assertEqual(("delete",), restored.execute("PRAGMA journal_mode").fetchone())
        self.assertFalse(pathlib.Path(str(path) + "-wal").exists())
        restore_dir = self.runtime / "restore"
        restore_dir.mkdir(mode=0o700)
        restore_path = restore_dir / "archive.sqlite3"
        shutil.copy2(path, restore_path)
        restored = storage.connect_database(restore_path)
        try:
            self.assertEqual((1,), restored.execute("SELECT COUNT(*) FROM snapshots").fetchone())
        finally:
            restored.close()

    def test_backup_source_is_not_written(self):
        before = self.database.read_bytes()
        self.create()
        self.assertEqual(before, self.database.read_bytes())
        self.assertEqual(("wal",), self.writer.execute("PRAGMA journal_mode").fetchone())

    def test_retention_only_deletes_verified_private_owned_backups(self):
        first = self.create()
        unrelated = self.destination / "customer.sqlite3"
        unrelated.write_text("secret")
        bad_name = "codex-usage-20000101T000000Z-" + "a" * 32 + ".sqlite3"
        corrupt = self.destination / bad_name
        corrupt.write_text("invalid database")
        corrupt.chmod(0o600)
        symlink = self.destination / bad_name.replace("a" * 32, "b" * 32)
        symlink.symlink_to(unrelated)
        self.create(keep=1)
        self.assertFalse((self.destination / first["backup"]).exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(corrupt.exists())
        self.assertTrue(symlink.is_symlink())
        self.assertEqual(2, len([path for path in self.files() if not path.is_symlink()]))

    def test_retention_keeps_latest_creation_with_same_second_names(self):
        first = self.create()
        second = self.create()
        self.create(keep=2)
        self.assertFalse((self.destination / first["backup"]).exists())
        self.assertTrue((self.destination / second["backup"]).exists())

    def test_backup_in_destination_is_never_pruned_as_source(self):
        first = self.create()
        source = self.destination / first["backup"]
        before = source.read_bytes()
        backup.create_backup(source, self.destination, keep=1)
        self.assertEqual(before, source.read_bytes())
        self.assertEqual(2, len(self.files()))

    def test_permissive_umask_cannot_create_public_backup_or_lock(self):
        previous = os.umask(0)
        try:
            result = self.create()
        finally:
            os.umask(previous)
        for path in (self.destination / result["backup"], self.destination / backup.LOCK_NAME):
            self.assertEqual(0o600, path.stat().st_mode & 0o777)

    def test_retention_preserves_hardlinks_and_nonprivate_files(self):
        result = self.create()
        original = self.destination / result["backup"]
        hardlink = self.destination / result["backup"].replace(result["backup"].split("-")[-1][:32], "a" * 32)
        os.link(original, hardlink)
        self.create(keep=1)
        self.assertTrue(original.exists())
        self.assertTrue(hardlink.exists())
        os.unlink(hardlink)
        original.chmod(0o644)
        self.create(keep=1)
        self.assertTrue(original.exists())

    def test_failed_verification_preserves_old_backups_and_cleans_temp(self):
        first = self.create()
        old = (self.destination / first["backup"]).read_bytes()
        with mock.patch.object(backup, "_verify", side_effect=storage.ArchiveCorruptionError("secret")):
            with self.assertRaises(storage.ArchiveCorruptionError):
                self.create(keep=1)
        self.assertEqual(old, (self.destination / first["backup"]).read_bytes())
        self.assertEqual([], list(self.destination.glob(".codex-backup-*.tmp")))
        self.assertEqual(1, len(self.files()))

    def test_timeout_preserves_old_backup_and_cleans_temp(self):
        first = self.create()
        with mock.patch.object(backup.time, "monotonic", side_effect=(0, 100)):
            with self.assertRaisesRegex(backup.BackupError, "backup_timeout"):
                self.create(keep=1)
        self.assertTrue((self.destination / first["backup"]).exists())
        self.assertEqual([], list(self.destination.glob(".codex-backup-*.tmp")))
        self.assertEqual(1, len(self.files()))

    def test_lock_prevents_overlap_and_pruning(self):
        first = self.create()
        with (self.destination / backup.LOCK_NAME).open("r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.cli("--keep", "1")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("backup_running", json.loads(result.stdout)["error_code"])
        self.assertTrue((self.destination / first["backup"]).exists())
        self.assertEqual(1, len(self.files()))

    def test_symlink_source_destination_ancestor_and_lock_are_rejected(self):
        self.destination.mkdir(mode=0o700)
        database_link = self.runtime / "archive-link"
        database_link.symlink_to(self.database)
        with self.assertRaises(OSError):
            backup.create_backup(database_link, self.destination)
        destination_link = self.runtime / "destination-link"
        destination_link.symlink_to(self.destination, target_is_directory=True)
        with self.assertRaises(OSError):
            backup.create_backup(self.database, destination_link)
        ancestor = self.runtime / "ancestor"
        ancestor.symlink_to(self.runtime, target_is_directory=True)
        with self.assertRaises(OSError):
            backup.create_backup(ancestor / self.database.name, self.destination)
        (self.destination / backup.LOCK_NAME).symlink_to(self.database)
        with self.assertRaises(OSError):
            self.create()

    def test_unsafe_destination_and_source_parent_permissions_are_rejected(self):
        self.destination.mkdir(mode=0o777)
        self.destination.chmod(0o777)
        with self.assertRaises(OSError):
            self.create()
        self.destination.chmod(0o700)
        self.runtime.chmod(0o777)
        with self.assertRaises(OSError):
            self.create()
        self.runtime.chmod(0o700)

    def test_nonregular_source_and_unowned_directory_are_rejected(self):
        fifo = self.runtime / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(OSError):
            backup.create_backup(fifo, self.destination)
        with mock.patch("operations.os.geteuid", return_value=os.geteuid() + 1):
            with self.assertRaises(OSError):
                self.create()

    def test_schema_failure_and_missing_source_have_sanitized_cli_errors(self):
        with self.writer:
            self.writer.execute("PRAGMA user_version = 999")
        result = self.cli()
        self.assertEqual(1, result.returncode)
        self.assertEqual("archive_unhealthy", json.loads(result.stdout)["error_code"])
        self.assertNotIn(str(self.runtime), result.stdout + result.stderr)
        self.assertNotIn("999", result.stdout + result.stderr)
        self.assertEqual([], self.files())
        self.database.unlink()
        result = self.cli()
        self.assertEqual("unsafe_path", json.loads(result.stdout)["error_code"])

    def test_retention_validation_and_no_parent_traversal(self):
        for keep in (0, -1, 10001, True):
            with self.subTest(keep=keep):
                with self.assertRaises(backup.BackupError):
                    self.create(keep=keep)
        with self.assertRaises(OSError):
            operations.open_private_directory(self.runtime / "child" / "..")

    def test_cli_success_has_only_sanitized_status_and_default_retention(self):
        result = self.cli()
        self.assertEqual(0, result.returncode, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual("ok", value["status"])
        self.assertTrue(backup.BACKUP_NAME.fullmatch(value["backup"]))
        self.assertNotIn(str(self.runtime), result.stdout)


if __name__ == "__main__":
    unittest.main()
