#!/usr/bin/env python3
"""Create verified private SQLite backups without interrupting the monitor."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import sqlite3
import stat
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import storage
from operations import UnsafePathError, open_owned_regular, open_private_directory, validate_archive_path


BACKUP_NAME = re.compile(r"codex-usage-\d{8}T\d{6}Z-[0-9a-f]{32}\.sqlite3\Z")
LOCK_NAME = ".codex-backup.lock"
BACKUP_TIMEOUT_SECONDS = 30


class BackupError(RuntimeError):
    """An expected failure represented by a fixed, sanitized code."""


def _verify(path: Path) -> None:
    # Read-only storage checks both SQLite integrity and the complete current
    # archive schema. It never upgrades or repairs the on-disk backup.
    connection = storage.connect_database(path, read_only=True)
    connection.close()


def _retention_candidates(destination: Path, directory: int, *, source: Path) -> list[str]:
    candidates = []
    for name in os.listdir(directory):
        if not BACKUP_NAME.fullmatch(name) or destination / name == source:
            continue
        descriptor = -1
        try:
            descriptor = open_owned_regular(name, directory)
            metadata = os.fstat(descriptor)
            if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
                continue
            _verify(destination / name)
        except (OSError, ValueError, sqlite3.DatabaseError, storage.ArchiveCorruptionError):
            # A similarly named file is not ours to delete unless verified.
            continue
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        candidates.append((metadata.st_mtime_ns, name))
    return [name for _, name in sorted(candidates, reverse=True)]


def create_backup(database: Path, destination_directory: Path, *, keep: int = 14) -> dict:
    """Publish a coherent backup, then prune verified backups under one lock."""
    if type(keep) is not int or not 1 <= keep <= 10000:
        raise BackupError("invalid_retention")
    database = validate_archive_path(database)
    destination, directory = open_private_directory(destination_directory, create=True)
    lock = -1
    temporary_fd = -1
    temporary_name = None
    try:
        if database == destination / LOCK_NAME:
            raise UnsafePathError("unsafe lock")
        lock = open_owned_regular(LOCK_NAME, directory, flags=os.O_RDWR | os.O_CREAT)
        metadata = os.fstat(lock)
        if metadata.st_nlink != 1:
            raise UnsafePathError("unsafe lock")
        # Secure an existing lock too; lock contents never carry archive data.
        os.fchmod(lock, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError("backup_running") from None

        unique = uuid.uuid4().hex
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        final_name = f"codex-usage-{timestamp}-{unique}.sqlite3"
        temporary_name = f".codex-backup-{unique}.tmp"
        temporary_fd = os.open(
            temporary_name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600, dir_fd=directory,
        )
        os.fchmod(temporary_fd, 0o600)
        temporary = destination / temporary_name
        source = storage.connect_database(database, read_only=True)
        try:
            target = sqlite3.connect(str(temporary))
            try:
                deadline = time.monotonic() + BACKUP_TIMEOUT_SECONDS

                def progress(_status: int, _remaining: int, _total: int) -> None:
                    if time.monotonic() > deadline:
                        raise BackupError("backup_timeout")

                source.backup(target, pages=256, progress=progress, sleep=0.05)
                # A standalone backup should require no WAL/SHM sidecars.
                target.execute("PRAGMA journal_mode = DELETE")
                storage.check_integrity(target)
            finally:
                target.close()
        finally:
            source.close()
        _verify(temporary)
        os.fsync(temporary_fd)
        # Hard-link publication is atomic and cannot overwrite an old backup,
        # even if a generated name unexpectedly collides.
        os.link(temporary_name, final_name, src_dir_fd=directory, dst_dir_fd=directory,
                follow_symlinks=False)
        os.unlink(temporary_name, dir_fd=directory)
        temporary_name = None
        os.fsync(directory)

        candidates = _retention_candidates(destination, directory, source=database)
        # Always retain the just-published file, including clock rollback.
        ordered = [final_name] + [name for name in candidates if name != final_name]
        removed = 0
        warning = None
        for name in ordered[keep:]:
            try:
                os.unlink(name, dir_fd=directory)
                removed += 1
            except OSError:
                warning = "retention_incomplete"
        os.fsync(directory)
        return {"status": "ok", "backup": final_name,
                "retained": len(ordered) - removed, "removed": removed, "warning_code": warning}
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory)
            except OSError:
                pass
        if lock >= 0:
            os.close(lock)
        os.close(directory)


_ERROR_MESSAGES = {
    "invalid_retention": "Retention must be between 1 and 10000 backups.",
    "backup_running": "Another backup is already running.",
    "backup_timeout": "The archive backup exceeded its time limit.",
    "unsafe_path": "A required file or directory could not be opened safely.",
    "archive_unhealthy": "The archive could not be verified.",
    "backup_failed": "The backup could not be completed.",
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--destination-dir", required=True, type=Path)
    parser.add_argument("--keep", type=int, default=14)
    parser.add_argument("--status-json", action="store_true", help="Print sanitized status JSON to stdout")
    args = parser.parse_args(argv)
    try:
        result = create_backup(args.database, args.destination_dir, keep=args.keep)
    except BackupError as exc:
        code = str(exc) if str(exc) in _ERROR_MESSAGES else "backup_failed"
    except OSError:
        code = "unsafe_path"
    except (sqlite3.DatabaseError, storage.ArchiveCorruptionError, ValueError):
        code = "archive_unhealthy"
    else:
        if args.status_json:
            print(json.dumps(result))
        else:
            print("Archive backup completed.")
        return 0
    message = _ERROR_MESSAGES[code]
    print(f"Backup failed: {message}", file=sys.stderr)
    if args.status_json:
        print(json.dumps({"status": "error", "error_code": code, "message": message}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
