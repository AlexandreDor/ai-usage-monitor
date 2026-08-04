#!/usr/bin/env python3
"""Shared private SQLite storage for limits and advanced analytics."""

from __future__ import annotations

import sqlite3
from pathlib import Path


SCHEMA_VERSION = "2"


class ArchiveCorruptionError(RuntimeError):
    """The SQLite file cannot be safely read."""


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


def create_schema(connection: sqlite3.Connection) -> None:
    """Create or migrate the private archive schema in place."""
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

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
        );

        CREATE INDEX IF NOT EXISTS idx_snapshots_scraped_at
            ON snapshots(scraped_at_epoch);

        CREATE TABLE IF NOT EXISTS reset_events (
            window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
            reset_at_epoch INTEGER NOT NULL,
            observed_at_epoch INTEGER NOT NULL,
            before_pct REAL,
            after_pct REAL,
            detection_method TEXT NOT NULL DEFAULT 'scheduled_crossing',
            PRIMARY KEY(window, reset_at_epoch)
        );

        CREATE INDEX IF NOT EXISTS idx_reset_events_observed_at
            ON reset_events(observed_at_epoch);

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
        );

        CREATE INDEX IF NOT EXISTS idx_token_events_time
            ON token_usage_events(occurred_at_epoch);
        CREATE INDEX IF NOT EXISTS idx_token_events_source_model_time
            ON token_usage_events(source, model, occurred_at_epoch);

        CREATE TABLE IF NOT EXISTS collector_state (
            source TEXT NOT NULL,
            state_key TEXT NOT NULL,
            state_json TEXT NOT NULL,
            updated_at_epoch INTEGER NOT NULL,
            PRIMARY KEY(source, state_key)
        );

        CREATE TABLE IF NOT EXISTS collector_runs (
            source TEXT PRIMARY KEY,
            enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
            status TEXT NOT NULL CHECK(status IN ('ok', 'disabled', 'unavailable', 'error')),
            last_attempt_at_epoch INTEGER,
            last_success_at_epoch INTEGER,
            last_error TEXT,
            source_schema TEXT
        );
        """
    )
    connection.execute("PRAGMA user_version = 2")


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
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    existed = database_path.exists()
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(str(database_path), timeout=10)
        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute("PRAGMA foreign_keys = ON")
        if existed:
            check_integrity(connection)
        create_schema(connection)
        return connection
    except sqlite3.DatabaseError as exc:
        if connection is not None:
            connection.close()
        if existed and is_corruption_error(exc):
            raise ArchiveCorruptionError(str(exc)) from exc
        raise
