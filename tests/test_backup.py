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
from urllib.parse import unquote, urlsplit
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

    def test_retention_preserves_source_with_double_slash_alias(self):
        first = self.create()
        source = self.destination / first["backup"]
        alias = pathlib.Path("/" + str(source))
        self.assertTrue(alias.samefile(source))
        self.assertNotEqual(alias, source)
        before = source.read_bytes()
        result = backup.create_backup(alias, self.destination, keep=1)
        self.assertEqual("ok", result["status"])
        self.assertEqual(before, source.read_bytes())
        self.assertEqual(2, len(self.files()))

    def test_lock_cannot_alias_source_with_double_slash_path(self):
        self.destination.mkdir(mode=0o700)
        source = self.destination / backup.LOCK_NAME
        with closing(sqlite3.connect(source)) as copied:
            self.writer.backup(copied)
        source.chmod(0o600)
        before = source.read_bytes()
        with self.assertRaises(operations.UnsafePathError):
            backup.create_backup(pathlib.Path("/" + str(source)), self.destination)
        self.assertEqual(before, source.read_bytes())
        self.assertEqual([], self.files())

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

    def test_replaceable_destination_ancestor_cannot_redirect_sqlite_copy(self):
        shared = self.runtime / "shared"
        shared.mkdir(mode=0o700)
        shared.chmod(0o777)
        container = shared / "container"
        container.mkdir(mode=0o700)
        destination = container / "backups"
        destination.mkdir(mode=0o700)
        original_connect = sqlite3.connect
        redirected = []

        def replace_ancestor(path, *args, **kwargs):
            if isinstance(path, str) and ".codex-backup-" in path:
                container.rename(shared / "moved")
                container.mkdir(mode=0o700)
                destination.mkdir(mode=0o700)
                redirected.append(path)
            return original_connect(path, *args, **kwargs)

        with mock.patch.object(backup.sqlite3, "connect", side_effect=replace_ancestor):
            with self.assertRaises(operations.UnsafePathError):
                backup.create_backup(self.database, destination)
        self.assertEqual([], redirected)
        self.assertEqual([], list(destination.iterdir()))

    def test_owner_directory_move_cannot_publish_an_unverified_inode(self):
        container = self.runtime / "container"
        container.mkdir(mode=0o700)
        destination = container / "backups"
        destination.mkdir(mode=0o700)
        moved = self.runtime / "moved"
        original_connect = sqlite3.connect
        redirected = []

        def move_owner_directory(path, *args, **kwargs):
            if isinstance(path, str) and ".codex-backup-" in path and not redirected:
                container.rename(moved)
                container.mkdir(mode=0o700)
                destination.mkdir(mode=0o700)
                replacement = pathlib.Path(unquote(urlsplit(path).path)) if path.startswith("file:") else pathlib.Path(path)
                replacement.touch(mode=0o600)
                redirected.append(path)
            return original_connect(path, *args, **kwargs)

        with mock.patch.object(backup.sqlite3, "connect", side_effect=move_owner_directory):
            with self.assertRaises(operations.UnsafePathError):
                backup.create_backup(self.database, destination)
        self.assertEqual(1, len(redirected))
        self.assertEqual([], list((moved / "backups").glob("codex-usage-*.sqlite3")))
        self.assertEqual([], list((moved / "backups").glob(".codex-backup-*.tmp")))

    def test_writable_ancestors_are_rejected_for_source_and_destination(self):
        shared = self.runtime / "shared"
        shared.mkdir(mode=0o700)
        private = shared / "private"
        private.mkdir(mode=0o700)
        source = private / "archive.sqlite3"
        with closing(sqlite3.connect(source)) as copied:
            self.writer.backup(copied)
        source.chmod(0o600)
        destination = private / "backups"
        destination.mkdir(mode=0o700)
        for mode in (0o775, 0o777):
            shared.chmod(mode)
            for database, target in ((self.database, destination), (source, self.destination)):
                with self.subTest(mode=oct(mode), source=database == source):
                    with mock.patch.object(backup.sqlite3, "connect", wraps=sqlite3.connect) as opened:
                        with self.assertRaises(operations.UnsafePathError):
                            backup.create_backup(database, target)
                        opened.assert_not_called()

    def test_untrusted_ancestor_owner_is_rejected_even_when_readonly_or_sticky(self):
        ancestor = self.runtime / "ancestor"
        ancestor.mkdir(mode=0o700)
        destination = ancestor / "backups"
        destination.mkdir(mode=0o700)
        identity = ancestor.stat()
        original_fstat = os.fstat

        def untrusted_owner(descriptor):
            metadata = original_fstat(descriptor)
            if (metadata.st_dev, metadata.st_ino) == (identity.st_dev, identity.st_ino):
                fields = list(metadata)
                fields[4] = os.geteuid() + 1
                return os.stat_result(fields)
            return metadata

        for mode in (0o555, 0o1777):
            ancestor.chmod(mode)
            with self.subTest(mode=oct(mode)), mock.patch("operations.os.fstat", side_effect=untrusted_owner):
                with self.assertRaises(operations.UnsafePathError):
                    backup.create_backup(self.database, destination)
        ancestor.chmod(0o700)

    def test_trusted_sticky_ancestor_preserves_private_backup_workflow(self):
        shared = self.runtime / "sticky"
        shared.mkdir(mode=0o700)
        shared.chmod(0o1777)
        private = shared / "private"
        private.mkdir(mode=0o700)
        destination = private / "backups"
        result = backup.create_backup(self.database, destination)
        restored = storage.connect_database(destination / result["backup"], read_only=True)
        restored.close()
        self.assertEqual("ok", result["status"])
        self.assertGreater((destination / result["backup"]).stat().st_size, 0)
        self.assertEqual(0o600, (destination / result["backup"]).stat().st_mode & 0o777)

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
