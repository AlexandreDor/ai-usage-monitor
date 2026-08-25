#!/usr/bin/env python3
"""Shared private SQLite storage for limits and advanced analytics."""

from __future__ import annotations

import json
import hashlib
import re
import sqlite3
import os
import stat
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, TypeVar

try:
    from history import canonicalize_limit_id, opaque_limit_id_from_raw
except ImportError:  # Standalone storage restore helper used by recovery tooling.
    _OPAQUE_LIMIT_ID_RE = re.compile(r"limit-[0-9a-f]{64}\Z")

    def opaque_limit_id_from_raw(value: object) -> str | None:
        if not isinstance(value, str) or not value:
            return None
        return "limit-" + hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()

    def canonicalize_limit_id(value: object) -> str | None:
        if not isinstance(value, str) or not value:
            return None
        if _OPAQUE_LIMIT_ID_RE.fullmatch(value):
            return value
        return opaque_limit_id_from_raw(value)


SCHEMA_VERSION = "4"
SCHEMA_VERSION_NUMBER = 4
PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY = "public_limit_id_contract_version"
PUBLIC_LIMIT_ID_CONTRACT_VERSION = "1"
SQLITE_RETRY_ATTEMPTS = 5
SQLITE_RETRY_INITIAL_DELAY_SECONDS = 0.05
SQLITE_RETRY_MAX_DELAY_SECONDS = 0.5
SQLITE_WAL_CHECKPOINT_MODES = frozenset({"PASSIVE", "FULL", "RESTART", "TRUNCATE"})
# Keep each SQLite busy wait short; five attempts plus exponential backoff are
# then bounded to roughly two seconds instead of multiplying a ten-second wait.
SQLITE_BUSY_TIMEOUT_MS = 250

_RetryResult = TypeVar("_RetryResult")


class ArchiveCorruptionError(RuntimeError):
    """The SQLite file cannot be safely read."""


class ArchiveSchemaError(sqlite3.DatabaseError):
    """The SQLite file has an unsupported or incomplete archive schema."""


def validate_database_parent(database_path: Path) -> Path:
    """Require the archive parent to be a private directory owned by euid."""
    database_path = Path(database_path)
    parent = database_path.parent
    try:
        metadata = parent.lstat()
    except FileNotFoundError as exc:
        raise OSError(f"archive parent directory does not exist: {parent}") from exc
    if stat.S_ISLNK(metadata.st_mode):
        raise OSError(f"archive parent must not be a symbolic link: {parent}")
    if not stat.S_ISDIR(metadata.st_mode):
        raise OSError(f"archive parent is not a directory: {parent}")
    if metadata.st_uid != os.geteuid():
        raise OSError(f"archive parent is not owned by the current user: {parent}")
    if metadata.st_mode & 0o022:
        raise OSError(
            f"archive parent must not be group/other-writable (mode {metadata.st_mode & 0o777:o}): {parent}"
        )
    return parent


def is_busy_error(exc: BaseException) -> bool:
    """Return whether *exc* is a retryable SQLite lock/busy failure.

    SQLite reports both ``database is locked`` and ``database is busy`` as
    ``OperationalError`` instances.  Do not broaden this predicate to all
    operational errors: malformed databases, missing tables and disk errors
    must remain visible to callers immediately.
    """
    return isinstance(exc, sqlite3.OperationalError) and any(
        marker in str(exc).lower() for marker in ("locked", "busy")
    )


def retry_sqlite_operation(
    operation: Callable[[], _RetryResult],
    *,
    attempts: int = SQLITE_RETRY_ATTEMPTS,
    initial_delay: float = SQLITE_RETRY_INITIAL_DELAY_SECONDS,
    max_delay: float = SQLITE_RETRY_MAX_DELAY_SECONDS,
) -> _RetryResult:
    """Run an SQLite operation with bounded retries for busy/locked only."""
    if attempts < 1:
        raise ValueError("attempts must be positive")
    delay = max(0.0, initial_delay)
    for attempt in range(attempts):
        try:
            return operation()
        except sqlite3.OperationalError as exc:
            if not is_busy_error(exc) or attempt + 1 >= attempts:
                raise
            if delay:
                time.sleep(delay)
                delay = min(max_delay, delay * 2)
    raise AssertionError("unreachable retry loop")


class RetryingCursor(sqlite3.Cursor):
    """Cursor that retries individual statements on transient SQLite locks."""

    def execute(self, sql, parameters=(), /):  # type: ignore[override]
        return retry_sqlite_operation(lambda: sqlite3.Cursor.execute(self, sql, parameters))

    def executemany(self, sql, parameters, /):  # type: ignore[override]
        """Execute a batch atomically so a retry cannot duplicate a prefix."""
        parameters = tuple(parameters)
        savepoint = f"_codex_batch_{id(self):x}"

        def atomic_batch():
            sqlite3.Cursor.execute(self, f'SAVEPOINT "{savepoint}"')
            try:
                result = sqlite3.Cursor.executemany(self, sql, parameters)
                sqlite3.Cursor.execute(self, f'RELEASE SAVEPOINT "{savepoint}"')
                return result
            except Exception:
                try:
                    sqlite3.Cursor.execute(self, f'ROLLBACK TO SAVEPOINT "{savepoint}"')
                    sqlite3.Cursor.execute(self, f'RELEASE SAVEPOINT "{savepoint}"')
                except sqlite3.DatabaseError:
                    pass
                raise

        return retry_sqlite_operation(atomic_batch)


class RetryingConnection(sqlite3.Connection):
    """Retry execute/commit lock failures with a bounded policy.

    ``executescript`` is intentionally inherited without automatic replay:
    SQLite may have applied part of a script before reporting an error. Write
    paths in this project use individual ``execute`` calls and ``commit``;
    cursor batches use a savepoint in :class:`RetryingCursor`.
    """

    def cursor(self, factory=None, /):  # type: ignore[override]
        return sqlite3.Connection.cursor(self, factory or RetryingCursor)

    def execute(self, sql, parameters=(), /):  # type: ignore[override]
        cursor = self.cursor()
        return retry_sqlite_operation(lambda: sqlite3.Cursor.execute(cursor, sql, parameters))

    def executemany(self, sql, parameters, /):  # type: ignore[override]
        return self.cursor().executemany(sql, parameters)

    def commit(self) -> None:  # type: ignore[override]
        retry_sqlite_operation(lambda: sqlite3.Connection.commit(self))

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is None:
            self.commit()
        else:
            self.rollback()
        return False


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

_V3_TABLE_COLUMNS = {
    **_V2_TABLE_COLUMNS,
    "forecast_samples": {
        "scraped_at_epoch", "generated_at_epoch", "chance_24h_pct",
        "chance_6h_pct",
    },
}

_V4_TABLE_COLUMNS = {
    **_V3_TABLE_COLUMNS,
    "quota_anomalies": {
        "anomaly_id", "dedupe_key", "anomaly_type", "window", "limit_id",
        "detected_at_epoch", "before_pct", "after_pct", "before_reset_at",
        "after_reset_at", "message", "journaled_at",
    },
    "anomaly_detector_state": {
        "limit_id", "window", "state_json", "updated_at_epoch",
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

_V3_SCHEMA_STATEMENTS = (
    *_V2_SCHEMA_STATEMENTS,
    """
    CREATE TABLE IF NOT EXISTS forecast_samples (
        scraped_at_epoch INTEGER PRIMARY KEY,
        generated_at_epoch INTEGER NOT NULL,
        chance_24h_pct INTEGER NOT NULL CHECK(chance_24h_pct BETWEEN 0 AND 100),
        chance_6h_pct INTEGER NOT NULL CHECK(chance_6h_pct BETWEEN 0 AND 100)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_forecast_samples_scraped_at ON forecast_samples(scraped_at_epoch)",
)

_V4_SCHEMA_STATEMENTS = (
    *_V3_SCHEMA_STATEMENTS,
    """
    CREATE TABLE IF NOT EXISTS quota_anomalies (
        anomaly_id TEXT PRIMARY KEY,
        dedupe_key TEXT NOT NULL UNIQUE,
        anomaly_type TEXT NOT NULL CHECK(anomaly_type IN (
            'quota_increase', 'reset_shift', 'reset_in_past',
            'reset_missing', 'reset_oscillation'
        )),
        window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
        limit_id TEXT NOT NULL,
        detected_at_epoch INTEGER NOT NULL,
        before_pct REAL,
        after_pct REAL,
        before_reset_at INTEGER,
        after_reset_at INTEGER,
        message TEXT NOT NULL,
        journaled_at INTEGER
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_quota_anomalies_pending ON quota_anomalies(journaled_at, detected_at_epoch)",
    "CREATE INDEX IF NOT EXISTS idx_quota_anomalies_window_time ON quota_anomalies(window, detected_at_epoch)",
    """
    CREATE TABLE IF NOT EXISTS anomaly_detector_state (
        limit_id TEXT NOT NULL,
        window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
        state_json TEXT NOT NULL,
        updated_at_epoch INTEGER NOT NULL,
        PRIMARY KEY(limit_id, window)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_anomaly_detector_state_updated ON anomaly_detector_state(updated_at_epoch)",
)

_V4_INDEX_NAMES = frozenset({
    "idx_snapshots_scraped_at",
    "idx_reset_events_observed_at",
    "idx_token_events_time",
    "idx_token_events_source_model_time",
    "idx_token_events_provider_time",
    "idx_forecast_samples_scraped_at",
    "idx_quota_anomalies_pending",
    "idx_quota_anomalies_window_time",
    "idx_anomaly_detector_state_updated",
})


def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


_LIMIT_ID_COLUMNS = {
    "snapshots": ("limit_id",),
}
_LIMIT_ID_JSON_COLUMNS = {
    "collector_state": ("state_json",),
}
_LIMIT_ID_JSON_KEYS = frozenset({
    "limit_id", "limitId", "active_limit_id", "previous_limit_id",
})
_ANOMALY_WINDOWS = frozenset({"5h", "weekly"})
_ANOMALY_TYPES = frozenset({
    "quota_increase", "reset_shift", "reset_in_past",
    "reset_missing", "reset_oscillation",
})


def _limit_id_contract_version(connection: sqlite3.Connection) -> str | None:
    if "metadata" not in _table_names(connection):
        return None
    row = connection.execute(
        "SELECT value FROM metadata WHERE key = ?",
        (PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY,),
    ).fetchone()
    return str(row[0]) if row and row[0] is not None else None


def _limit_id_migration_required(connection: sqlite3.Connection) -> bool:
    """Require one durable migration until the explicit contract marker exists."""

    return _limit_id_contract_version(connection) != PUBLIC_LIMIT_ID_CONTRACT_VERSION


def _migrate_limit_id(value: object, *, legacy: bool) -> object:
    if not isinstance(value, str) or not value:
        return value
    if legacy:
        return opaque_limit_id_from_raw(value)
    return canonicalize_limit_id(value)


def _is_limit_id_key(key: object) -> bool:
    return isinstance(key, str) and key in _LIMIT_ID_JSON_KEYS


def _migrate_json_limit_ids(value: object, *, legacy: bool) -> tuple[object, bool]:
    """Recursively migrate only explicitly named ID fields in structured JSON."""

    if isinstance(value, dict):
        changed = False
        migrated: dict[object, object] = {}
        for key, child in value.items():
            if _is_limit_id_key(key) and isinstance(child, str):
                new_child = _migrate_limit_id(child, legacy=legacy)
                changed = changed or new_child != child
            else:
                new_child, child_changed = _migrate_json_limit_ids(child, legacy=legacy)
                changed = changed or child_changed
            migrated[key] = new_child
        return migrated, changed
    if isinstance(value, list):
        changed = False
        migrated_list = []
        for child in value:
            new_child, child_changed = _migrate_json_limit_ids(child, legacy=legacy)
            changed = changed or child_changed
            migrated_list.append(new_child)
        return migrated_list, changed
    return value, False


def _migrate_json_text(value: object, *, legacy: bool) -> object:
    if not isinstance(value, str):
        return value
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError, OverflowError):
        return value
    migrated, changed = _migrate_json_limit_ids(parsed, legacy=legacy)
    if not changed:
        return value
    return json.dumps(migrated, ensure_ascii=False, separators=(",", ":"))


def _migrate_dedupe_key(value: object, *, legacy: bool) -> object:
    """Rebuild the exact anomaly dedupe format, never substitute arbitrary text."""

    if not isinstance(value, str):
        return value
    parts = value.split("|", 3)
    if (
        len(parts) != 4
        or not parts[0]
        or parts[1] not in _ANOMALY_WINDOWS
        or parts[2] not in _ANOMALY_TYPES
        or not parts[3]
    ):
        return value
    limit_id = _migrate_limit_id(parts[0], legacy=legacy)
    if not isinstance(limit_id, str):
        return value
    return "|".join((limit_id, parts[1], parts[2], parts[3]))


def _migrate_anomaly_detector_ids(
    connection: sqlite3.Connection,
    *,
    legacy: bool,
) -> None:
    """Move the ID primary key while merging an impossible canonical collision."""

    if "anomaly_detector_state" not in _table_names(connection):
        return
    rows = connection.execute(
        "SELECT limit_id, window, state_json, updated_at_epoch FROM anomaly_detector_state"
    ).fetchall()
    for old_id, window, state_json, updated in rows:
        if not isinstance(old_id, str):
            continue
        new_id = _migrate_limit_id(old_id, legacy=legacy)
        if new_id == old_id:
            new_state_json = _migrate_json_text(state_json, legacy=legacy)
            if new_state_json != state_json:
                connection.execute(
                    "UPDATE anomaly_detector_state SET state_json = ? "
                    "WHERE limit_id = ? AND window = ?",
                    (new_state_json, old_id, window),
                )
            continue
        new_state_json = _migrate_json_text(state_json, legacy=legacy)
        conflict = connection.execute(
            "SELECT state_json, updated_at_epoch FROM anomaly_detector_state "
            "WHERE limit_id = ? AND window = ?",
            (new_id, window),
        ).fetchone()
        if conflict is None:
            connection.execute(
                "UPDATE anomaly_detector_state SET limit_id = ?, state_json = ? "
                "WHERE limit_id = ? AND window = ?",
                (new_id, new_state_json, old_id, window),
            )
        elif updated is not None and conflict[1] is not None and updated > conflict[1]:
            connection.execute(
                "UPDATE anomaly_detector_state SET state_json = ?, updated_at_epoch = ? "
                "WHERE limit_id = ? AND window = ?",
                (new_state_json, updated, new_id, window),
            )
            connection.execute(
                "DELETE FROM anomaly_detector_state WHERE limit_id = ? AND window = ?",
                (old_id, window),
            )
        else:
            connection.execute(
                "DELETE FROM anomaly_detector_state WHERE limit_id = ? AND window = ?",
                (old_id, window),
            )


def _migrate_quota_anomaly_ids(
    connection: sqlite3.Connection,
    *,
    legacy: bool,
) -> None:
    """Rewrite anomaly IDs/dedupe keys without violating their unique key."""

    if "quota_anomalies" not in _table_names(connection):
        return
    rows = connection.execute(
        "SELECT anomaly_id, dedupe_key, limit_id, detected_at_epoch FROM quota_anomalies"
    ).fetchall()
    transformed = []
    for anomaly_id, dedupe_key, limit_id, detected_at in rows:
        new_limit = _migrate_limit_id(limit_id, legacy=legacy)
        new_dedupe = _migrate_dedupe_key(dedupe_key, legacy=legacy)
        transformed.append((anomaly_id, new_dedupe, new_limit, detected_at))

    winners: dict[str, tuple[object, object, object, object]] = {}
    losers: list[object] = []
    for row in transformed:
        key = row[1]
        previous = winners.get(key)
        if previous is None or (row[3] is not None and (previous[3] is None or row[3] > previous[3])):
            if previous is not None:
                losers.append(previous[0])
            winners[key] = row
        else:
            losers.append(row[0])
    for anomaly_id in losers:
        connection.execute("DELETE FROM quota_anomalies WHERE anomaly_id = ?", (anomaly_id,))

    # Use a temporary unique value for every surviving row before assigning its
    # final dedupe key, so a canonical row cannot collide with an old raw one.
    for anomaly_id, _new_dedupe, _new_limit, _ in winners.values():
        connection.execute(
            "UPDATE quota_anomalies SET dedupe_key = ? WHERE anomaly_id = ?",
            (f"__limit_id_migration__{anomaly_id}", anomaly_id),
        )
    for anomaly_id, new_dedupe, new_limit, _ in winners.values():
        connection.execute(
            "UPDATE quota_anomalies SET dedupe_key = ?, limit_id = ? WHERE anomaly_id = ?",
            (new_dedupe, new_limit, anomaly_id),
        )


def _migrate_limit_ids(connection: sqlite3.Connection, *, legacy: bool) -> None:
    """Migrate only schema-defined ID fields in the surrounding transaction."""

    _migrate_quota_anomaly_ids(connection, legacy=legacy)
    _migrate_anomaly_detector_ids(connection, legacy=legacy)

    for table, columns in _LIMIT_ID_COLUMNS.items():
        if table not in _table_names(connection):
            continue
        for column in columns:
            for rowid, value in connection.execute(
                f"SELECT rowid, {_quote_identifier(column)} FROM {_quote_identifier(table)}"
            ).fetchall():
                migrated = _migrate_limit_id(value, legacy=legacy)
                if migrated != value:
                    connection.execute(
                        f"UPDATE {_quote_identifier(table)} SET {_quote_identifier(column)} = ? WHERE rowid = ?",
                        (migrated, rowid),
                    )

    for table, columns in _LIMIT_ID_JSON_COLUMNS.items():
        if table not in _table_names(connection):
            continue
        for column in columns:
            for rowid, value in connection.execute(
                f"SELECT rowid, {_quote_identifier(column)} FROM {_quote_identifier(table)}"
            ).fetchall():
                migrated = _migrate_json_text(value, legacy=legacy)
                if migrated != value:
                    connection.execute(
                        f"UPDATE {_quote_identifier(table)} SET {_quote_identifier(column)} = ? WHERE rowid = ?",
                        (migrated, rowid),
                    )

    if "metadata" in _table_names(connection):
        active = connection.execute(
            "SELECT value FROM metadata WHERE key = 'anomaly_active_limit_id'"
        ).fetchone()
        if active:
            migrated = _migrate_limit_id(active[0], legacy=legacy)
            if migrated != active[0]:
                connection.execute(
                    "UPDATE metadata SET value = ? WHERE key = 'anomaly_active_limit_id'",
                    (migrated,),
                )


def _set_limit_id_contract_marker(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        INSERT INTO metadata(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        WHERE metadata.value IS NOT excluded.value
        """,
        (PUBLIC_LIMIT_ID_CONTRACT_VERSION_KEY, PUBLIC_LIMIT_ID_CONTRACT_VERSION),
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


def _set_schema_metadata(connection: sqlite3.Connection) -> None:
    current = connection.execute(
        "SELECT value FROM metadata WHERE key = 'schema_version'"
    ).fetchone()
    if current and current[0] == SCHEMA_VERSION:
        return
    connection.execute(
        """
        INSERT INTO metadata(key, value) VALUES('schema_version', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (SCHEMA_VERSION,),
    )


def create_schema(connection: sqlite3.Connection) -> None:
    """Create the archive or migrate an explicitly recognized archive to v4."""
    raw_version = connection.execute("PRAGMA user_version").fetchone()
    try:
        version = int(raw_version[0]) if raw_version else 0
    except (TypeError, ValueError) as exc:
        raise ArchiveSchemaError("archive schema version is not an integer") from exc

    tables = _table_names(connection)
    fresh = version == 0 and not tables
    legacy_without_pragma = version == 0 and {"metadata", "snapshots"}.issubset(tables)
    if version not in (0, 1, 2, 3, SCHEMA_VERSION_NUMBER):
        raise ArchiveSchemaError(
            f"unsupported archive schema version {version}; expected 1, 2, 3 or {SCHEMA_VERSION_NUMBER}"
        )
    if version == 0 and not fresh and not legacy_without_pragma:
        raise ArchiveSchemaError("archive has tables but no recognized schema version")

    if version == 1 or legacy_without_pragma:
        _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
        _validate_existing_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == 2:
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=2)
        _validate_existing_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == 3:
        _validate_tables(connection, _V3_TABLE_COLUMNS, version=3)
        _validate_existing_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == SCHEMA_VERSION_NUMBER:
        _validate_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)

    # Capture this before schema metadata is rewritten.  An archive from before
    # the public-ID contract has no reliable way to distinguish a raw value that
    # happens to look like a digest, so every dedicated ID is hashed once.
    legacy_limit_id_contract = (
        _limit_id_contract_version(connection) != PUBLIC_LIMIT_ID_CONTRACT_VERSION
    )
    started_transaction = not connection.in_transaction
    if started_transaction:
        connection.execute("BEGIN IMMEDIATE")
    try:
        if fresh or version in (0, 1, 2, 3):
            for statement in _V4_SCHEMA_STATEMENTS:
                connection.execute(statement)
            connection.execute("PRAGMA user_version = 4")
        elif version == SCHEMA_VERSION_NUMBER:
            # Keep indexes repairable without silently accepting a partial table schema.
            connection.execute("CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at ON snapshots(scraped_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at ON reset_events(observed_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_usage_events(occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time ON token_usage_events(source, model, occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_provider_time ON token_usage_events(provider, occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_forecast_samples_scraped_at ON forecast_samples(scraped_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_quota_anomalies_pending ON quota_anomalies(journaled_at, detected_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_quota_anomalies_window_time ON quota_anomalies(window, detected_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_anomaly_detector_state_updated ON anomaly_detector_state(updated_at_epoch)")
        _set_schema_metadata(connection)
        _validate_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
        if legacy_limit_id_contract:
            _migrate_limit_ids(connection, legacy=True)
        _set_limit_id_contract_marker(connection)
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


def _schema_state(connection: sqlite3.Connection) -> tuple[int, bool, bool]:
    """Inspect schema metadata without changing it.

    Return ``(version, schema_migration_required, schema_repair_required)`` and reject unsupported or
    partially unidentified files before any durable journal-mode mutation.
    """
    raw_version = connection.execute("PRAGMA user_version").fetchone()
    try:
        version = int(raw_version[0]) if raw_version else 0
    except (TypeError, ValueError) as exc:
        raise ArchiveSchemaError("archive schema version is not an integer") from exc
    tables = _table_names(connection)
    if version not in (0, 1, 2, 3, SCHEMA_VERSION_NUMBER):
        raise ArchiveSchemaError(
            f"unsupported archive schema version {version}; expected 1, 2, 3 or {SCHEMA_VERSION_NUMBER}"
        )
    fresh = version == 0 and not tables
    legacy_without_pragma = version == 0 and {"metadata", "snapshots"}.issubset(tables)
    if version == 0 and not fresh and not legacy_without_pragma:
        raise ArchiveSchemaError("archive has tables but no recognized schema version")
    if version in (1, 2, 3):
        return version, True, False
    if version == 0:
        # A genuinely empty file is a fresh archive.  Only the recognized
        # pre-v2 shape is an implicit legacy archive requiring migration.
        return version, legacy_without_pragma, False
    metadata = connection.execute(
        "SELECT value FROM metadata WHERE key = 'schema_version'"
    ).fetchone()
    index_names = {
        str(row[1])
        for row in connection.execute(
            "SELECT type, name FROM sqlite_master WHERE type = 'index'"
        )
    }
    repair_required = not metadata or metadata[0] != SCHEMA_VERSION
    repair_required = repair_required or not _V4_INDEX_NAMES <= index_names
    return version, False, repair_required


def _journal_mode(connection: sqlite3.Connection) -> str:
    row = connection.execute("PRAGMA journal_mode").fetchone()
    return str(row[0]).lower() if row and row[0] is not None else ""


def _enable_wal(connection: sqlite3.Connection) -> None:
    row = connection.execute("PRAGMA journal_mode = WAL").fetchone()
    if not row or str(row[0]).lower() != "wal":
        raise sqlite3.DatabaseError(f"SQLite did not enable WAL journal mode: {row!r}")


def _reserve_backup_path(database_path: Path) -> tuple[Path, tuple[int, int]]:
    """Reserve a unique adjacent mode-0600 path without clobbering a backup."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    base = database_path.with_name(f"{database_path.name}.pre-migration.{stamp}")
    for suffix in range(1000):
        candidate = base if suffix == 0 else base.with_name(f"{base.name}.{suffix}")
        try:
            descriptor = os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            continue
        try:
            identity = os.fstat(descriptor)
            os.fchmod(descriptor, 0o600)
            os.close(descriptor)
        except Exception:
            os.close(descriptor)
            try:
                candidate.unlink()
            except OSError:
                pass
            raise
        return candidate, (identity.st_dev, identity.st_ino)
    raise OSError(f"could not reserve a unique migration backup beside {database_path}")


def _remove_reserved_path(path: Path, identity: tuple[int, int]) -> None:
    """Remove only the regular file instance reserved by this process."""
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    if stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) == identity:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def _assert_reserved_path(path: Path, identity: tuple[int, int]) -> None:
    current = path.lstat()
    if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != identity:
        raise OSError(f"reserved backup destination changed: {path}")


def backup_database(
    source: sqlite3.Connection,
    database_path: Path,
) -> Path:
    """Create an autonomous, verified, no-clobber backup beside ``database_path``.

    The source must already have passed :func:`check_integrity`.  A reserved
    destination is removed on every failure, so callers can safely abort a
    migration without leaving a misleading partial artifact.
    """
    database_path = Path(database_path)
    validate_database_parent(database_path)
    if not database_path.is_file() or database_path.is_symlink():
        raise OSError(f"archive database is not a regular file: {database_path}")
    destination_path, reservation_identity = _reserve_backup_path(database_path)
    target: sqlite3.Connection | None = None
    completed = False
    try:
        _assert_reserved_path(destination_path, reservation_identity)
        target = sqlite3.connect(str(destination_path), timeout=SQLITE_BUSY_TIMEOUT_MS / 1000)
        target.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        retry_sqlite_operation(lambda: source.backup(target))
        result = target.execute("PRAGMA quick_check").fetchone()
        if not result or result[0] != "ok":
            raise ArchiveCorruptionError(
                f"backup quick_check failed: {result[0] if result else 'no result'}"
            )
        target.commit()
        _assert_reserved_path(destination_path, reservation_identity)
        os.chmod(destination_path, 0o600)
        completed = True
        return destination_path
    finally:
        if target is not None:
            target.close()
        if not completed:
            _remove_reserved_path(destination_path, reservation_identity)


def wal_sidecar_paths(database_path: Path) -> tuple[Path, Path]:
    """Return the WAL and shared-memory sidecars for an archive path."""
    return database_path.with_name(f"{database_path.name}-wal"), database_path.with_name(
        f"{database_path.name}-shm"
    )


def checkpoint_database(
    database: sqlite3.Connection | Path,
    *,
    mode: str = "PASSIVE",
) -> tuple[int, int, int]:
    """Run a bounded, explicit WAL checkpoint and return SQLite's three counters."""
    normalized_mode = mode.upper()
    if normalized_mode not in SQLITE_WAL_CHECKPOINT_MODES:
        raise ValueError(f"unsupported WAL checkpoint mode: {mode}")
    own_connection = not isinstance(database, sqlite3.Connection)
    connection = connect_database(Path(database)) if own_connection else database
    try:
        row = connection.execute(f"PRAGMA wal_checkpoint({normalized_mode})").fetchone()
        if not row or len(row) < 3:
            raise sqlite3.DatabaseError("SQLite WAL checkpoint returned no status")
        return int(row[0]), int(row[1]), int(row[2])
    finally:
        if own_connection:
            connection.close()


def connect_database(database_path: Path, *, read_only: bool = False) -> sqlite3.Connection:
    database_path = Path(database_path)
    if not read_only:
        validate_database_parent(database_path)
    if database_path.is_symlink():
        raise OSError(f"archive database must not be a symbolic link: {database_path}")
    if read_only:
        connection = sqlite3.connect(
            f"file:{database_path}?mode=ro", uri=True, timeout=SQLITE_BUSY_TIMEOUT_MS / 1000,
            factory=RetryingConnection,
        )
        try:
            connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
            connection.execute("PRAGMA query_only = ON")
            connection.execute("PRAGMA foreign_keys = ON")
            check_integrity(connection)
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version != SCHEMA_VERSION_NUMBER:
                raise ArchiveSchemaError(
                    f"read-only analytics requires archive schema v{SCHEMA_VERSION_NUMBER}; found v{version}"
                )
            _validate_tables(connection, _V4_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
            if _limit_id_migration_required(connection):
                # Analytics must never expose a legacy raw ID, but its read-only
                # contract must not mutate the on-disk archive.  Query an
                # in-memory copy after applying the same transactional mapper;
                # the next writable archive open still performs the durable
                # migration and backup.
                migrated = sqlite3.connect(":memory:", factory=RetryingConnection)
                try:
                    connection.backup(migrated)
                    migrated.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
                    migrated.execute("PRAGMA foreign_keys = ON")
                    migrated.execute("BEGIN IMMEDIATE")
                    _migrate_limit_ids(migrated, legacy=True)
                    _set_limit_id_contract_marker(migrated)
                    migrated.commit()
                    migrated.execute("PRAGMA query_only = ON")
                except Exception:
                    migrated.close()
                    raise
                connection.close()
                return migrated
            return connection
        except Exception:
            connection.close()
            raise

    existed = database_path.exists()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            str(database_path), timeout=SQLITE_BUSY_TIMEOUT_MS / 1000,
            factory=RetryingConnection,
        )
        connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        connection.execute("PRAGMA foreign_keys = ON")
        if existed:
            check_integrity(connection)
        _, schema_migration_required, schema_repair_required = _schema_state(connection)
        limit_id_migration_required = _limit_id_migration_required(connection)
        current_journal_mode = _journal_mode(connection)
        durable_mutation_required = (
            schema_migration_required
            or schema_repair_required
            or limit_id_migration_required
            or current_journal_mode != "wal"
        )
        if existed and durable_mutation_required:
            # This is deliberately before changing the journal mode or schema:
            # a failed backup must abort the operation before either mutation.
            backup_database(connection, database_path)
        # WAL activation precedes create_schema so a journal-mode failure
        # cannot commit a schema migration.  For a legacy archive, the backup
        # above remains the recovery point if WAL activation itself partially
        # changes the file before reporting an error.
        _enable_wal(connection)
        create_schema(connection)
        os.chmod(database_path, 0o600)
        return connection
    except (ArchiveCorruptionError, OSError, sqlite3.DatabaseError) as exc:
        if connection is not None:
            connection.close()
        if existed and is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
