#!/usr/bin/env python3
"""Shared private SQLite storage for limits and advanced analytics."""

from __future__ import annotations

import sqlite3
import os
from pathlib import Path


SCHEMA_VERSION = "3"
SCHEMA_VERSION_NUMBER = 3
SQLITE_BUSY_TIMEOUT_MS = 10_000


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
    connection.execute(
        """
        INSERT INTO metadata(key, value) VALUES('schema_version', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (SCHEMA_VERSION,),
    )


def create_schema(connection: sqlite3.Connection) -> None:
    """Create the archive or migrate an explicitly recognized archive to v3."""
    raw_version = connection.execute("PRAGMA user_version").fetchone()
    try:
        version = int(raw_version[0]) if raw_version else 0
    except (TypeError, ValueError) as exc:
        raise ArchiveSchemaError("archive schema version is not an integer") from exc

    tables = _table_names(connection)
    fresh = version == 0 and not tables
    legacy_without_pragma = version == 0 and {"metadata", "snapshots"}.issubset(tables)
    if version not in (0, 1, 2, SCHEMA_VERSION_NUMBER):
        raise ArchiveSchemaError(
            f"unsupported archive schema version {version}; expected 1, 2 or {SCHEMA_VERSION_NUMBER}"
        )
    if version == 0 and not fresh and not legacy_without_pragma:
        raise ArchiveSchemaError("archive has tables but no recognized schema version")

    if version == 1 or legacy_without_pragma:
        _validate_tables(connection, _V1_TABLE_COLUMNS, version=1)
        _validate_existing_tables(connection, _V3_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == 2:
        _validate_tables(connection, _V2_TABLE_COLUMNS, version=2)
        _validate_existing_tables(connection, _V3_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
    elif version == SCHEMA_VERSION_NUMBER:
        _validate_tables(connection, _V3_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)

    started_transaction = not connection.in_transaction
    if started_transaction:
        connection.execute("BEGIN IMMEDIATE")
    try:
        if fresh or version in (0, 1, 2):
            for statement in _V3_SCHEMA_STATEMENTS:
                connection.execute(statement)
            connection.execute("PRAGMA user_version = 3")
        elif version == SCHEMA_VERSION_NUMBER:
            # Keep indexes repairable without silently accepting a partial table schema.
            connection.execute("CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at ON snapshots(scraped_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at ON reset_events(observed_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_time ON token_usage_events(occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time ON token_usage_events(source, model, occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_token_events_provider_time ON token_usage_events(provider, occurred_at_epoch)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_forecast_samples_scraped_at ON forecast_samples(scraped_at_epoch)")
        _set_schema_metadata(connection)
        _validate_tables(connection, _V3_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
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


def connect_database(database_path: Path, *, read_only: bool = False) -> sqlite3.Connection:
    if database_path.is_symlink():
        raise OSError(f"archive database must not be a symbolic link: {database_path}")
    if read_only:
        connection = sqlite3.connect(
            f"file:{database_path}?mode=ro", uri=True, timeout=10
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
            _validate_tables(connection, _V3_TABLE_COLUMNS, version=SCHEMA_VERSION_NUMBER)
            return connection
        except Exception:
            connection.close()
            raise

    existed = database_path.exists()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(str(database_path), timeout=10)
        connection.execute(f"PRAGMA busy_timeout = {SQLITE_BUSY_TIMEOUT_MS}")
        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute("PRAGMA foreign_keys = ON")
        if existed:
            check_integrity(connection)
        create_schema(connection)
        os.chmod(database_path, 0o600)
        return connection
    except (ArchiveCorruptionError, sqlite3.DatabaseError) as exc:
        if connection is not None:
            connection.close()
        if existed and is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
