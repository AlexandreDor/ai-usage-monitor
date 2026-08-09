#!/usr/bin/env python3
"""Shared private SQLite storage for limits and advanced analytics."""

from __future__ import annotations

from collections.abc import Callable
import os
from pathlib import Path
import sqlite3
import time
from typing import TypeVar


SCHEMA_VERSION = "2"
SCHEMA_VERSION_NUMBER = 2
# Keep SQLite's own wait short.  The retry loop below supplies a second,
# explicit and bounded chance for the handful of setup/commit operations that
# are expected to contend with the monitor or the analytics reader.
SQLITE_BUSY_TIMEOUT_MS = 150
SQLITE_RETRY_ATTEMPTS = 5
SQLITE_RETRY_DELAY_SECONDS = 0.02
SQLITE_RETRY_MAX_DELAY_SECONDS = 0.1
SQLITE_CONNECT_TIMEOUT_SECONDS = SQLITE_BUSY_TIMEOUT_MS / 1000
V1_BACKUP_SUFFIX = ".v1.bak"
V1_BACKUP_COLLISION_LIMIT = 100


_Result = TypeVar("_Result")


class ArchiveCorruptionError(RuntimeError):
    """The SQLite file cannot be safely read."""


class ArchiveSchemaError(sqlite3.DatabaseError):
    """The SQLite file has an unsupported or incomplete archive schema."""


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


def _is_locked_error(exc: sqlite3.DatabaseError) -> bool:
    """Return whether SQLite reported a transient lock/busy condition."""
    error_code = getattr(exc, "sqlite_errorcode", None)
    lock_codes = {
        code
        for name in (
            "SQLITE_BUSY",
            "SQLITE_BUSY_RECOVERY",
            "SQLITE_BUSY_SNAPSHOT",
            "SQLITE_LOCKED",
            "SQLITE_LOCKED_SHAREDCACHE",
            "SQLITE_LOCKED_VTAB",
        )
        if (code := getattr(sqlite3, name, None)) is not None
    }
    if error_code in lock_codes:
        return True
    message = str(exc).lower()
    return "busy" in message or "locked" in message


def _retry_locked(operation: Callable[[], _Result]) -> _Result:
    """Run a SQLite operation with a short, finite lock retry policy."""
    delay = SQLITE_RETRY_DELAY_SECONDS
    for attempt in range(SQLITE_RETRY_ATTEMPTS):
        try:
            return operation()
        except sqlite3.DatabaseError as exc:
            if not _is_locked_error(exc) or attempt + 1 >= SQLITE_RETRY_ATTEMPTS:
                raise
            time.sleep(delay)
            delay = min(delay * 2, SQLITE_RETRY_MAX_DELAY_SECONDS)
    raise AssertionError("unreachable retry loop")


class _RetryingCursor(sqlite3.Cursor):
    """Cursor that gives individual statements the same bounded retry policy."""

    def execute(self, sql: str, parameters: object = ()) -> sqlite3.Cursor:
        return _retry_locked(lambda: sqlite3.Cursor.execute(self, sql, parameters))


class _RetryingConnection(sqlite3.Connection):
    """SQLite connection preserving the public sqlite3 API with safe retries."""

    def cursor(self, factory: type[sqlite3.Cursor] | None = None) -> sqlite3.Cursor:
        return sqlite3.Connection.cursor(self, factory or _RetryingCursor)

    def execute(self, sql: str, parameters: object = ()) -> sqlite3.Cursor:
        return _retry_locked(lambda: sqlite3.Connection.execute(self, sql, parameters))

    def commit(self) -> None:
        _retry_locked(lambda: sqlite3.Connection.commit(self))

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        if exc_type is None:
            self.commit()
        else:
            sqlite3.Connection.rollback(self)
        return False


def _execute(
    connection: sqlite3.Connection,
    sql: str,
    parameters: object = (),
) -> sqlite3.Cursor:
    """Execute through the base class so callers get exactly one retry loop."""
    return _retry_locked(
        lambda: sqlite3.Connection.execute(connection, sql, parameters)
    )


def _commit(connection: sqlite3.Connection) -> None:
    _retry_locked(lambda: sqlite3.Connection.commit(connection))


def _rollback(connection: sqlite3.Connection) -> None:
    try:
        sqlite3.Connection.rollback(connection)
    except sqlite3.DatabaseError:
        # Rollback is cleanup.  Do not hide the migration/opening error with a
        # second error from a connection that may already be closing.
        pass


def _close_connection(connection: sqlite3.Connection) -> None:
    """Rollback and close a failed setup without touching SQLite sidecars."""
    _rollback(connection)
    try:
        sqlite3.Connection.close(connection)
    except sqlite3.DatabaseError:
        pass


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
        for row in _execute(
            connection,
            "SELECT name FROM sqlite_master WHERE type = 'table'",
        )
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
            str(row[1])
            for row in _execute(connection, f'PRAGMA table_info("{table}")')
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
            str(row[1])
            for row in _execute(connection, f'PRAGMA table_info("{table}")')
        }
        missing_columns = sorted(columns - actual)
        if missing_columns:
            raise ArchiveSchemaError(
                f"archive schema v{version} table {table} is missing columns: "
                f"{', '.join(missing_columns)}"
            )


def _set_schema_metadata(connection: sqlite3.Connection) -> None:
    _execute(
        connection,
        """
        INSERT INTO metadata(key, value) VALUES('schema_version', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (SCHEMA_VERSION,),
    )


def _schema_state(connection: sqlite3.Connection) -> tuple[int, set[str]]:
    raw_version = _execute(connection, "PRAGMA user_version").fetchone()
    try:
        version = int(raw_version[0]) if raw_version else 0
    except (TypeError, ValueError) as exc:
        raise ArchiveSchemaError("archive schema version is not an integer") from exc
    return version, _table_names(connection)


def _migration_kind(version: int, tables: set[str]) -> tuple[bool, bool]:
    """Return (fresh, v1 migration) after checking the version marker."""
    fresh = version == 0 and not tables
    legacy_without_pragma = version == 0 and {"metadata", "snapshots"}.issubset(tables)
    if version not in (0, 1, SCHEMA_VERSION_NUMBER):
        raise ArchiveSchemaError(
            f"unsupported archive schema version {version}; expected 1 or {SCHEMA_VERSION_NUMBER}"
        )
    if version == 0 and not fresh and not legacy_without_pragma:
        raise ArchiveSchemaError("archive has tables but no recognized schema version")
    return fresh, version == 1 or legacy_without_pragma


def _connection_database_path(connection: sqlite3.Connection) -> Path | None:
    row = _execute(connection, "PRAGMA database_list").fetchone()
    if not row or not row[2]:
        return None
    return Path(str(row[2]))


def _read_only_uri(database_path: Path) -> str:
    return f"{database_path.resolve().as_uri()}?mode=ro"


def _v1_backup_candidate(database_path: Path, suffix: int | None = None) -> Path:
    name = f"{database_path.name}{V1_BACKUP_SUFFIX}"
    if suffix is not None:
        name = f"{name}.{suffix}"
    return database_path.with_name(name)


def _is_restorable_v1_backup(backup_path: Path) -> bool:
    if not backup_path.is_file():
        return False
    backup_connection: sqlite3.Connection | None = None
    try:
        backup_connection = sqlite3.connect(
            str(backup_path),
            timeout=SQLITE_CONNECT_TIMEOUT_SECONDS,
            factory=_RetryingConnection,
        )
        _execute(
            backup_connection,
            f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}",
        )
        check_integrity(backup_connection)
        version, tables = _schema_state(backup_connection)
        return version in (0, 1) and {"metadata", "snapshots"}.issubset(tables)
    except (OSError, sqlite3.DatabaseError, ArchiveCorruptionError):
        return False
    finally:
        if backup_connection is not None:
            _close_connection(backup_connection)


def _reserve_v1_backup(database_path: Path) -> tuple[Path, bool]:
    """Find an existing valid backup or reserve a never-overwritten pathname."""
    for suffix in [None, *range(1, V1_BACKUP_COLLISION_LIMIT)]:
        candidate = _v1_backup_candidate(database_path, suffix)
        if candidate.exists():
            if _is_restorable_v1_backup(candidate):
                return candidate, False
            continue
        try:
            descriptor = os.open(
                candidate,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600,
            )
        except FileExistsError:
            continue
        else:
            os.close(descriptor)
            return candidate, True
    raise FileExistsError(
        f"could not reserve a unique v1 backup for {database_path}"
    )


def _backup_v1_database(
    connection: sqlite3.Connection,
    database_path: Path | None,
    *,
    transaction_owned: bool,
) -> Path | None:
    """Create one coherent, restorable v1 backup before changing the source."""
    if database_path is None:
        # In-memory databases have no durable artifact to preserve.  Keep the
        # direct create_schema(connection) API useful for tests and callers
        # that intentionally use an in-memory archive.
        return None

    backup_path, reserved = _reserve_v1_backup(database_path)
    if not reserved:
        return backup_path

    backup_connection: sqlite3.Connection | None = None
    source_connection: sqlite3.Connection | None = None
    try:
        backup_connection = sqlite3.connect(
            str(backup_path),
            timeout=SQLITE_CONNECT_TIMEOUT_SECONDS,
            factory=_RetryingConnection,
        )
        if transaction_owned:
            # A backup invoked on the same connection that owns BEGIN IMMEDIATE
            # can wait on its own write transaction.  WAL explicitly permits a
            # second read connection, so use that stable reader while the
            # writer lock held by `connection` prevents another process from
            # changing the v1 source.
            source_connection = sqlite3.connect(
                _read_only_uri(database_path),
                uri=True,
                timeout=SQLITE_CONNECT_TIMEOUT_SECONDS,
                factory=_RetryingConnection,
            )
            _configure_connection(source_connection, read_only=True)
            # The source transaction is already serialized with BEGIN
            # IMMEDIATE; backup captures the v1 pages including any committed
            # state represented by an active WAL without copying the WAL file.
            _retry_locked(lambda: source_connection.backup(backup_connection))
        else:
            # Preserve the long-standing direct create_schema(connection) API
            # when its caller already owns an uncommitted transaction.  A
            # second SQLite connection cannot see those pages, so use SQLite's
            # own dump iterator to build the backup from this exact snapshot.
            backup_connection.executescript("\n".join(connection.iterdump()))
            user_version = _execute(connection, "PRAGMA user_version").fetchone()[0]
            _execute(backup_connection, f"PRAGMA user_version = {int(user_version)}")
        _commit(backup_connection)
        # The backup is now a standalone v1 artifact.  Keep its own journal
        # lifecycle simple and let SQLite remove only these private sidecars;
        # the source database's active WAL is never inspected or unlinked.
        backup_journal = _execute(
            backup_connection,
            "PRAGMA journal_mode = DELETE",
        ).fetchone()
        if not backup_journal or str(backup_journal[0]).lower() != "delete":
            raise sqlite3.DatabaseError(
                f"could not finalize v1 backup journal: {backup_journal[0] if backup_journal else 'no result'}"
            )
        check_integrity(backup_connection)
        version, tables = _schema_state(backup_connection)
        if version not in (0, 1) or {"metadata", "snapshots"} - tables:
            raise ArchiveSchemaError(
                f"v1 backup {backup_path} is not a restorable legacy archive"
            )
        os.chmod(backup_path, 0o600)
        return backup_path
    except Exception:
        if reserved:
            try:
                backup_path.unlink()
            except FileNotFoundError:
                pass
        raise
    finally:
        if backup_connection is not None:
            _close_connection(backup_connection)
        if source_connection is not None:
            _close_connection(source_connection)


def create_schema(
    connection: sqlite3.Connection,
    *,
    database_path: Path | None = None,
) -> None:
    """Create the archive or migrate an explicitly recognized v1 archive to v2."""
    if database_path is None:
        database_path = _connection_database_path(connection)

    started_transaction = not connection.in_transaction
    if started_transaction:
        _execute(connection, "BEGIN IMMEDIATE")
    try:
        # Read the schema only after the write lock is acquired.  A second
        # opener may have completed the migration while this connection was
        # waiting; re-reading here prevents a second backup or stale v1 write.
        version, tables = _schema_state(connection)
        fresh, migrating_v1 = _migration_kind(version, tables)
        if migrating_v1:
            _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
            _validate_existing_tables(
                connection,
                _V2_TABLE_COLUMNS,
                version=SCHEMA_VERSION_NUMBER,
            )
            _backup_v1_database(
                connection,
                database_path,
                transaction_owned=started_transaction,
            )
        elif version == SCHEMA_VERSION_NUMBER:
            _validate_tables(
                connection,
                _V2_TABLE_COLUMNS,
                version=SCHEMA_VERSION_NUMBER,
            )

        if fresh or version in (0, 1):
            for statement in _V2_SCHEMA_STATEMENTS:
                _execute(connection, statement)
            _execute(connection, "PRAGMA user_version = 2")
        elif version == SCHEMA_VERSION_NUMBER:
            # Keep indexes repairable without silently accepting a partial table schema.
            _execute(connection, "CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at ON snapshots(scraped_at_epoch)")
            _execute(connection, "CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at ON reset_events(observed_at_epoch)")
            _execute(connection, "CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_usage_events(occurred_at_epoch)")
            _execute(connection, "CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time ON token_usage_events(source, model, occurred_at_epoch)")
            _execute(connection, "CREATE INDEX IF NOT EXISTS idx_token_events_provider_time ON token_usage_events(provider, occurred_at_epoch)")
        _set_schema_metadata(connection)
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
        # Validate the post-migration layout before making it durable.  This is
        # also run for already-v2 connections so concurrent open/read cycles
        # never silently accept a damaged archive.
        check_integrity(connection)
        if started_transaction:
            _commit(connection)
    except Exception:
        if started_transaction:
            _rollback(connection)
        raise


def check_integrity(connection: sqlite3.Connection) -> None:
    try:
        result = _execute(connection, "PRAGMA quick_check").fetchone()
    except sqlite3.DatabaseError as exc:
        if is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
    if not result or result[0] != "ok":
        detail = result[0] if result else "no integrity result"
        raise ArchiveCorruptionError(str(detail))


def _configure_connection(
    connection: sqlite3.Connection,
    *,
    read_only: bool,
) -> None:
    _execute(
        connection,
        f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}",
    )
    _execute(connection, "PRAGMA foreign_keys = ON")
    if read_only:
        _execute(connection, "PRAGMA query_only = ON")
        return

    journal_mode = _execute(connection, "PRAGMA journal_mode = WAL").fetchone()
    if not journal_mode or str(journal_mode[0]).lower() != "wal":
        raise sqlite3.DatabaseError(
            f"SQLite did not enable WAL journal mode: {journal_mode[0] if journal_mode else 'no result'}"
        )


def connect_database(database_path: Path, *, read_only: bool = False) -> sqlite3.Connection:
    database_path = Path(database_path)
    if database_path.is_symlink():
        raise OSError(f"archive database must not be a symbolic link: {database_path}")
    if read_only:
        connection = sqlite3.connect(
            _read_only_uri(database_path),
            uri=True,
            timeout=SQLITE_CONNECT_TIMEOUT_SECONDS,
            factory=_RetryingConnection,
        )
        try:
            _configure_connection(connection, read_only=True)
            check_integrity(connection)
            version = int(_execute(connection, "PRAGMA user_version").fetchone()[0])
            if version != SCHEMA_VERSION_NUMBER:
                raise ArchiveSchemaError(
                    f"read-only analytics requires archive schema v{SCHEMA_VERSION_NUMBER}; found v{version}"
                )
            _validate_tables(connection, _V2_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
            return connection
        except Exception:
            _close_connection(connection)
            raise

    existed = database_path.exists()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            str(database_path),
            timeout=SQLITE_CONNECT_TIMEOUT_SECONDS,
            factory=_RetryingConnection,
        )
        _configure_connection(connection, read_only=False)
        if existed:
            check_integrity(connection)
        create_schema(connection, database_path=database_path)
        os.chmod(database_path, 0o600)
        return connection
    except Exception as exc:
        if connection is not None:
            _close_connection(connection)
        if (
            existed
            and isinstance(exc, sqlite3.DatabaseError)
            and is_corruption_error(exc)
        ):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
