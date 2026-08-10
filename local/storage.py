#!/usr/bin/env python3
"""Shared private SQLite storage for limits and advanced analytics."""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
from types import TracebackType
from typing import Any, Callable, TypeVar


SCHEMA_VERSION = "2"
SCHEMA_VERSION_NUMBER = 2
SQLITE_BUSY_TIMEOUT_MS = 50
SQLITE_LOCK_RETRY_DELAYS = (0.02, 0.04, 0.08, 0.16)
V1_BACKUP_SUFFIX = ".v1.bak"
READ_ONLY_INTEGRITY_CACHE_SECONDS = 30.0
MAX_INTEGRITY_CACHE_ENTRIES = 32

_T = TypeVar("_T")
_READ_ONLY_INTEGRITY_CACHE: dict[str, tuple[tuple[Any, ...], float]] = {}
_READ_ONLY_INTEGRITY_CACHE_LOCK = threading.Lock()


class ArchiveCorruptionError(RuntimeError):
    """The SQLite file cannot be safely read."""


class ArchiveSchemaError(sqlite3.DatabaseError):
    """The SQLite file has an unsupported or incomplete archive schema."""


def is_lock_error(exc: sqlite3.OperationalError) -> bool:
    code = getattr(exc, "sqlite_errorcode", None)
    if isinstance(code, int) and code & 0xFF in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
        return True
    message = str(exc).lower()
    return "database is locked" in message or "database is busy" in message


def _retry_locked(operation: Callable[[], _T]) -> _T:
    for delay in (*SQLITE_LOCK_RETRY_DELAYS, None):
        try:
            return operation()
        except sqlite3.OperationalError as exc:
            if delay is None or not is_lock_error(exc):
                raise
            time.sleep(delay)
    raise AssertionError("unreachable SQLite retry state")


class RetryingConnection(sqlite3.Connection):
    """SQLite connection with explicit, short and bounded lock retries."""

    def execute(self, sql: str, parameters: Any = (), /) -> sqlite3.Cursor:
        return _retry_locked(lambda: sqlite3.Connection.execute(self, sql, parameters))

    def executemany(self, sql: str, seq_of_parameters: Any, /) -> sqlite3.Cursor:
        return _retry_locked(
            lambda: sqlite3.Connection.executemany(self, sql, seq_of_parameters)
        )

    def executescript(self, sql_script: str, /) -> sqlite3.Cursor:
        return _retry_locked(lambda: sqlite3.Connection.executescript(self, sql_script))

    def commit(self) -> None:
        _retry_locked(lambda: sqlite3.Connection.commit(self))

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> bool:
        if exc_type is None:
            self.commit()
        else:
            sqlite3.Connection.rollback(self)
        return False

    def close(self) -> None:
        lock_descriptor = getattr(self, "_storage_lock_descriptor", None)
        try:
            sqlite3.Connection.close(self)
        finally:
            if lock_descriptor is not None:
                self._storage_lock_descriptor = None
                fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
                os.close(lock_descriptor)


def is_corruption_error(exc: sqlite3.DatabaseError) -> bool:
    message = str(exc).lower()
    return any(
        marker in message
        for marker in (
            "not a database",
            "malformed",
            "unsupported file format",
            "file is encrypted",
            "database disk image is malformed",
        )
    )


_V1_TABLE_COLUMNS = {
    "metadata": {"key", "value"},
    "snapshots": {
        "scraped_at_epoch", "scraped_at", "five_h_pct", "five_h_reset",
        "five_h_reset_at", "weekly_pct", "weekly_reset", "weekly_reset_at",
        "sample_interval_seconds", "history_window_hours", "limit_id",
    },
}

_V2_TABLE_COLUMNS = {
    **_V1_TABLE_COLUMNS,
    "reset_events": {
        "window", "reset_at_epoch", "observed_at_epoch", "before_pct",
        "after_pct", "detection_method",
    },
    "token_usage_events": {
        "id", "occurred_at_epoch", "source", "provider", "model",
        "input_tokens", "cache_read_tokens", "cache_write_tokens",
        "output_tokens", "reasoning_tokens", "external_id", "imported", "quality",
    },
    "collector_state": {"source", "state_key", "state_json", "updated_at_epoch"},
    "collector_runs": {
        "source", "enabled", "status", "last_attempt_at_epoch",
        "last_success_at_epoch", "last_error", "source_schema",
    },
}

_V2_SCHEMA_STATEMENTS = (
    """
    CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS snapshots (
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
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at ON snapshots(scraped_at_epoch)",
    """
    CREATE TABLE IF NOT EXISTS reset_events (
        window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
        reset_at_epoch INTEGER NOT NULL,
        observed_at_epoch INTEGER NOT NULL,
        before_pct REAL,
        after_pct REAL,
        detection_method TEXT NOT NULL DEFAULT 'scheduled_crossing',
        PRIMARY KEY(window, reset_at_epoch)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at ON reset_events(observed_at_epoch)",
    """
    CREATE TABLE IF NOT EXISTS token_usage_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        occurred_at_epoch INTEGER NOT NULL,
        source TEXT NOT NULL CHECK(source IN ('codex', 'opencode', 'hermes')),
        provider TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0 CHECK(input_tokens >= 0),
        cache_read_tokens INTEGER NOT NULL DEFAULT 0 CHECK(cache_read_tokens >= 0),
        cache_write_tokens INTEGER NOT NULL DEFAULT 0 CHECK(cache_write_tokens >= 0),
        output_tokens INTEGER NOT NULL DEFAULT 0 CHECK(output_tokens >= 0),
        reasoning_tokens INTEGER NOT NULL DEFAULT 0 CHECK(reasoning_tokens >= 0),
        external_id TEXT NOT NULL,
        imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN (0, 1)),
        quality TEXT NOT NULL DEFAULT 'exact',
        UNIQUE(source, external_id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_usage_events(occurred_at_epoch)",
    "CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time ON token_usage_events(source, model, occurred_at_epoch)",
    "CREATE INDEX IF NOT EXISTS idx_token_events_provider_time ON token_usage_events(provider, occurred_at_epoch)",
    """
    CREATE TABLE IF NOT EXISTS collector_state (
        source TEXT NOT NULL,
        state_key TEXT NOT NULL,
        state_json TEXT NOT NULL,
        updated_at_epoch INTEGER NOT NULL,
        PRIMARY KEY(source, state_key)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS collector_runs (
        source TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
        status TEXT NOT NULL CHECK(status IN ('ok', 'disabled', 'unavailable', 'error')),
        last_attempt_at_epoch INTEGER,
        last_success_at_epoch INTEGER,
        last_error TEXT,
        source_schema TEXT
    )
    """,
)


def _table_names(connection: sqlite3.Connection) -> set[str]:
    return {
        str(row[0])
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }


def _validate_tables(
    connection: sqlite3.Connection,
    expected: dict[str, set[str]],
    *,
    version: int,
) -> None:
    tables = _table_names(connection)
    missing_tables = sorted(set(expected) - tables)
    if missing_tables:
        raise ArchiveSchemaError(
            f"archive schema v{version} is missing tables: {', '.join(missing_tables)}"
        )
    for table, columns in expected.items():
        actual = {
            str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')
        }
        missing_columns = sorted(columns - actual)
        if missing_columns:
            raise ArchiveSchemaError(
                f"archive schema v{version} table {table} is missing columns: "
                f"{', '.join(missing_columns)}"
            )


def _validate_existing_tables(
    connection: sqlite3.Connection,
    expected: dict[str, set[str]],
    *,
    version: int,
) -> None:
    """Reject partially created known tables before an in-place migration."""
    tables = _table_names(connection)
    for table, columns in expected.items():
        if table not in tables:
            continue
        actual = {
            str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')
        }
        missing_columns = sorted(columns - actual)
        if missing_columns:
            raise ArchiveSchemaError(
                f"archive schema v{version} table {table} is missing columns: "
                f"{', '.join(missing_columns)}"
            )


def _database_file(connection: sqlite3.Connection) -> Path:
    for _, name, filename in connection.execute("PRAGMA database_list"):
        if name == "main" and filename:
            return Path(filename)
    raise ArchiveSchemaError("archive database has no main file")


def _fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _database_lock_path(path: Path) -> Path:
    return path.with_name(path.name + ".storage.lock")


def _acquire_database_lock(path: Path, *, exclusive: bool) -> int:
    lock_path = _database_lock_path(path)
    descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    os.fchmod(descriptor, 0o600)
    operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    try:
        for delay in (*SQLITE_LOCK_RETRY_DELAYS, None):
            try:
                fcntl.flock(descriptor, operation | fcntl.LOCK_NB)
                return descriptor
            except BlockingIOError:
                if delay is None:
                    raise sqlite3.OperationalError(
                        "database is locked by archive recovery"
                    )
                time.sleep(delay)
    except Exception:
        os.close(descriptor)
        raise
    raise AssertionError("unreachable database lock state")


@contextmanager
def exclusive_database_recovery(path: Path):
    descriptor = _acquire_database_lock(path, exclusive=True)
    try:
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _validate_v1_backup(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise ArchiveSchemaError(f"v1 backup is not a regular file: {path}")
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        check_integrity(connection)
        row = connection.execute("PRAGMA user_version").fetchone()
        version = int(row[0]) if row else 0
        if version not in (0, 1):
            raise ArchiveSchemaError(
                f"v1 backup has unexpected schema version {version}: {path}"
            )
        _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
    finally:
        if connection is not None:
            connection.close()


def _ensure_v1_backup(connection: sqlite3.Connection) -> Path:
    """Publish one verified standalone backup before changing a v1 schema."""
    database_path = _database_file(connection)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{database_path.name}.v1.", suffix=".tmp", dir=database_path.parent
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    destination: sqlite3.Connection | None = None
    source: sqlite3.Connection = connection
    try:
        if connection.in_transaction:
            source = sqlite3.connect(
                f"file:{database_path}?mode=ro",
                uri=True,
                timeout=SQLITE_BUSY_TIMEOUT_MS / 1000,
            )
            source.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        destination = sqlite3.connect(str(temporary_path))
        busy_attempts = 0

        def backup_progress(status: int, remaining: int, total: int) -> None:
            del remaining, total
            nonlocal busy_attempts
            if status not in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                busy_attempts = 0
                return
            if busy_attempts >= len(SQLITE_LOCK_RETRY_DELAYS):
                raise sqlite3.OperationalError(
                    "database is busy during bounded v1 backup"
                )
            time.sleep(SQLITE_LOCK_RETRY_DELAYS[busy_attempts])
            busy_attempts += 1

        source.backup(
            destination,
            pages=256,
            progress=backup_progress,
            sleep=0,
        )
        destination.close()
        destination = None
        os.chmod(temporary_path, 0o600)
        _validate_v1_backup(temporary_path)
        _fsync_file(temporary_path)
        digest = _file_digest(temporary_path)
        preferred = database_path.with_name(database_path.name + V1_BACKUP_SUFFIX)
        if not preferred.exists() and not preferred.is_symlink():
            backup_path = preferred
        elif (
            preferred.is_file()
            and not preferred.is_symlink()
            and _file_digest(preferred) == digest
        ):
            _validate_v1_backup(preferred)
            return preferred
        else:
            backup_path = database_path.with_name(
                f"{database_path.name}.{digest[:16]}{V1_BACKUP_SUFFIX}"
            )
            if backup_path.exists() or backup_path.is_symlink():
                if (
                    backup_path.is_file()
                    and not backup_path.is_symlink()
                    and _file_digest(backup_path) == digest
                ):
                    _validate_v1_backup(backup_path)
                    return backup_path
                raise ArchiveSchemaError(
                    f"v1 backup fingerprint collision at {backup_path}"
                )
        try:
            os.link(temporary_path, backup_path)
        except FileExistsError:
            if _file_digest(backup_path) != digest:
                raise ArchiveSchemaError(
                    f"v1 backup changed while being published: {backup_path}"
                )
            _validate_v1_backup(backup_path)
        else:
            _fsync_directory(database_path.parent)
        return backup_path
    finally:
        if destination is not None:
            destination.close()
        if source is not connection:
            source.close()
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def prepare_rebuilt_database(path: Path) -> None:
    """Make a rebuilt database standalone and validate it before publication."""

    connection = sqlite3.connect(path)
    try:
        result = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if result and int(result[0]) != 0:
            raise sqlite3.OperationalError("rebuilt database WAL checkpoint is busy")
        mode = connection.execute("PRAGMA journal_mode = DELETE").fetchone()
        if not mode or str(mode[0]).lower() != "delete":
            raise sqlite3.DatabaseError("rebuilt database could not leave WAL mode")
        check_integrity(connection)
        version = int(connection.execute("PRAGMA user_version").fetchone()[0])
        if version != SCHEMA_VERSION_NUMBER:
            raise ArchiveSchemaError(
                f"rebuilt archive has schema version {version}, expected {SCHEMA_VERSION_NUMBER}"
            )
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    finally:
        connection.close()
    os.chmod(path, 0o600)
    _fsync_file(path)


def publish_rebuilt_database(database_path: Path, rebuilt_path: Path) -> Path:
    """Replace a corrupt active SQLite set without mixing its WAL sidecars."""

    prepare_rebuilt_database(rebuilt_path)
    with exclusive_database_recovery(database_path):
        backup = database_path.with_name(
            f"{database_path.name}.corrupt.{time.time_ns()}"
        )
        while backup.exists() or Path(str(backup) + "-wal").exists():
            backup = database_path.with_name(
                f"{database_path.name}.corrupt.{time.time_ns()}"
            )

        sources = [database_path]
        sources.extend(
            path
            for path in (Path(str(database_path) + "-wal"), Path(str(database_path) + "-shm"))
            if path.exists()
        )
        destinations = [
            backup if source == database_path else Path(str(backup) + str(source)[len(str(database_path)):])
            for source in sources
        ]
        for source in sources:
            if source.is_symlink() or not source.is_file():
                raise OSError(f"archive recovery source is not a regular file: {source}")

        moved: list[tuple[Path, Path]] = []
        published = False
        try:
            for source, destination in zip(sources, destinations):
                os.replace(source, destination)
                moved.append((source, destination))
            os.replace(rebuilt_path, database_path)
            published = True
            _fsync_directory(database_path.parent)
        except Exception:
            if not published:
                for source, destination in reversed(moved):
                    if destination.exists() and not source.exists():
                        os.replace(destination, source)
                _fsync_directory(database_path.parent)
            raise
        return backup


def _set_schema_metadata(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        INSERT INTO metadata(key, value) VALUES('schema_version', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (SCHEMA_VERSION,),
    )


def create_schema(connection: sqlite3.Connection) -> None:
    """Create the archive or migrate an explicitly recognized v1 archive to v2."""
    raw_version = connection.execute("PRAGMA user_version").fetchone()
    try:
        version = int(raw_version[0]) if raw_version else 0
    except (TypeError, ValueError) as exc:
        raise ArchiveSchemaError("archive schema version is not an integer") from exc

    tables = _table_names(connection)
    fresh = version == 0 and not tables
    legacy_without_pragma = version == 0 and {"metadata", "snapshots"}.issubset(tables)
    if version not in (0, 1, SCHEMA_VERSION_NUMBER):
        raise ArchiveSchemaError(
            f"unsupported archive schema version {version}; expected 1 or {SCHEMA_VERSION_NUMBER}"
        )
    if version == 0 and not fresh and not legacy_without_pragma:
        raise ArchiveSchemaError("archive has tables but no recognized schema version")

    migrating_v1 = version == 1 or legacy_without_pragma
    if migrating_v1:
        _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
        _validate_existing_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == SCHEMA_VERSION_NUMBER:
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)

    started_transaction = not connection.in_transaction
    if started_transaction:
        connection.execute("BEGIN IMMEDIATE")
    try:
        if migrating_v1:
            # The reserved write lock keeps the independently read backup and
            # the schema changed below tied to the same committed v1 source.
            _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
            _ensure_v1_backup(connection)
        if fresh or version in (0, 1):
            for statement in _V2_SCHEMA_STATEMENTS:
                connection.execute(statement)
            connection.execute("PRAGMA user_version = 2")
        elif version == SCHEMA_VERSION_NUMBER:
            # Keep indexes repairable without silently accepting a partial table schema.
            connection.execute("CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at ON snapshots(scraped_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at ON reset_events(observed_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_usage_events(occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time ON token_usage_events(source, model, occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_provider_time ON token_usage_events(provider, occurred_at_epoch)")
        _set_schema_metadata(connection)
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
        if started_transaction:
            # Validate the post-migration layout before making it durable.
            check_integrity(connection)
            connection.commit()
    except Exception:
        if started_transaction:
            connection.rollback()
        raise


def check_integrity(connection: sqlite3.Connection) -> None:
    try:
        result = connection.execute("PRAGMA quick_check").fetchone()
    except sqlite3.DatabaseError as exc:
        if is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
    if not result or result[0] != "ok":
        detail = result[0] if result else "no integrity result"
        raise ArchiveCorruptionError(str(detail))


def _file_identity(
    path: Path,
    *,
    ignore_empty_wal: bool = False,
    include_timestamps: bool = True,
) -> tuple[int, ...] | None:
    try:
        metadata = path.stat(follow_symlinks=False)
    except FileNotFoundError:
        return None
    if ignore_empty_wal and metadata.st_size <= 32:
        return None
    identity = (metadata.st_dev, metadata.st_ino, metadata.st_size)
    if include_timestamps:
        identity += (metadata.st_mtime_ns, metadata.st_ctime_ns)
    return identity


def _database_identity(database_path: Path) -> tuple[Any, ...]:
    return (
        _file_identity(database_path),
        _file_identity(Path(str(database_path) + "-wal"), ignore_empty_wal=True),
        # SQLite updates SHM timestamps for reader locks; inode and size still
        # detect sidecar replacement without turning every request into a check.
        _file_identity(Path(str(database_path) + "-shm"), include_timestamps=False),
    )


def check_read_only_integrity(
    connection: sqlite3.Connection,
    database_path: Path,
    opened_identity: tuple[Any, ...],
) -> None:
    """Reuse a recent quick_check only while the SQLite file set is unchanged."""
    cache_key = os.path.abspath(database_path)
    before = _database_identity(database_path)
    now = time.monotonic()
    with _READ_ONLY_INTEGRITY_CACHE_LOCK:
        cached = _READ_ONLY_INTEGRITY_CACHE.get(cache_key)
        if (
            cached is not None
            and cached[0][:2] == before[:2]
            and (cached[0][2] == before[2] or before[2] is None)
            and now - cached[1] <= READ_ONLY_INTEGRITY_CACHE_SECONDS
        ):
            return
        check_integrity(connection)
        after = _database_identity(database_path)
        # SHM can be created while the connection opens and its lock metadata
        # can change during the check. Main/WAL changes, unlike those events,
        # mean the checked snapshot cannot be safely reused.
        if after[:2] != before[:2] or opened_identity[:2] != before[:2]:
            _READ_ONLY_INTEGRITY_CACHE.pop(cache_key, None)
            return
        if cache_key not in _READ_ONLY_INTEGRITY_CACHE and len(_READ_ONLY_INTEGRITY_CACHE) >= MAX_INTEGRITY_CACHE_ENTRIES:
            _READ_ONLY_INTEGRITY_CACHE.clear()
        _READ_ONLY_INTEGRITY_CACHE[cache_key] = (after, time.monotonic())


def connect_database(database_path: Path, *, read_only: bool = False) -> sqlite3.Connection:
    if database_path.is_symlink():
        raise OSError(f"archive database must not be a symbolic link: {database_path}")
    lock_descriptor = _acquire_database_lock(database_path, exclusive=False)
    if read_only:
        connection: RetryingConnection | None = None
        try:
            opened_identity = _database_identity(database_path)
            connection = sqlite3.connect(
                f"file:{database_path}?mode=ro",
                uri=True,
                timeout=SQLITE_BUSY_TIMEOUT_MS / 1000,
                factory=RetryingConnection,
            )
            connection._storage_lock_descriptor = lock_descriptor
            lock_descriptor = -1
            connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
            connection.execute("PRAGMA query_only = ON")
            connection.execute("PRAGMA foreign_keys = ON")
            check_read_only_integrity(connection, database_path, opened_identity)
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version != SCHEMA_VERSION_NUMBER:
                raise ArchiveSchemaError(
                    f"read-only analytics requires archive schema v{SCHEMA_VERSION_NUMBER}; found v{version}"
                )
            _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
            return connection
        except Exception:
            if connection is not None:
                connection.close()
            if lock_descriptor >= 0:
                os.close(lock_descriptor)
            raise

    existed = database_path.exists()
    connection: RetryingConnection | None = None
    try:
        connection = sqlite3.connect(
            str(database_path),
            timeout=SQLITE_BUSY_TIMEOUT_MS / 1000,
            factory=RetryingConnection,
        )
        connection._storage_lock_descriptor = lock_descriptor
        lock_descriptor = -1
        connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        connection.execute("PRAGMA foreign_keys = ON")
        if existed:
            check_integrity(connection)
        journal_mode = connection.execute("PRAGMA journal_mode = WAL").fetchone()
        if not journal_mode or str(journal_mode[0]).lower() != "wal":
            raise sqlite3.DatabaseError("archive database could not enable WAL mode")
        connection.execute("PRAGMA synchronous = NORMAL")
        create_schema(connection)
        check_integrity(connection)
        os.chmod(database_path, 0o600)
        return connection
    except (ArchiveCorruptionError, sqlite3.DatabaseError) as exc:
        if connection is not None:
            connection.close()
        if existed and is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
    except Exception:
        if connection is not None:
            connection.close()
        raise
    finally:
        if lock_descriptor >= 0:
            os.close(lock_descriptor)
