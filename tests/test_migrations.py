#!/usr/bin/env python3
"""Explicit acceptance tests for the SQLite archive schema lifecycle."""

from __future__ import annotations

import pathlib
import sqlite3
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))

import storage  # noqa: E402


_V1_SCHEMA = """
CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE snapshots(
  scraped_at_epoch INTEGER PRIMARY KEY, scraped_at TEXT NOT NULL,
  five_h_pct REAL, five_h_reset TEXT, five_h_reset_at INTEGER,
  weekly_pct REAL, weekly_reset TEXT, weekly_reset_at INTEGER,
  sample_interval_seconds INTEGER, history_window_hours REAL,
  limit_id TEXT
);
CREATE INDEX idx_snapshots_scraped_at ON snapshots(scraped_at_epoch);
"""

# These fixtures intentionally duplicate the SQL that was deployed at each
# schema version. Keep them independent from local/storage.py's migration
# constants: otherwise a regression in those constants could make the test
# construct the same broken schema that the migration accepts.
_V2_SCHEMA = """
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
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
CREATE INDEX idx_snapshots_scraped_at ON snapshots(scraped_at_epoch);
CREATE TABLE reset_events (
    window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
    reset_at_epoch INTEGER NOT NULL,
    observed_at_epoch INTEGER NOT NULL,
    before_pct REAL,
    after_pct REAL,
    detection_method TEXT NOT NULL DEFAULT 'scheduled_crossing',
    PRIMARY KEY(window, reset_at_epoch)
);
CREATE INDEX idx_reset_events_observed_at ON reset_events(observed_at_epoch);
CREATE TABLE token_usage_events (
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
CREATE INDEX idx_token_events_time ON token_usage_events(occurred_at_epoch);
CREATE INDEX idx_token_events_source_model_time
    ON token_usage_events(source, model, occurred_at_epoch);
CREATE INDEX idx_token_events_provider_time
    ON token_usage_events(provider, occurred_at_epoch);
CREATE TABLE collector_state (
    source TEXT NOT NULL,
    state_key TEXT NOT NULL,
    state_json TEXT NOT NULL,
    updated_at_epoch INTEGER NOT NULL,
    PRIMARY KEY(source, state_key)
);
CREATE TABLE collector_runs (
    source TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
    status TEXT NOT NULL CHECK(status IN ('ok', 'disabled', 'unavailable', 'error')),
    last_attempt_at_epoch INTEGER,
    last_success_at_epoch INTEGER,
    last_error TEXT,
    source_schema TEXT
);
"""

_V3_SCHEMA = """
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
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
CREATE INDEX idx_snapshots_scraped_at ON snapshots(scraped_at_epoch);
CREATE TABLE reset_events (
    window TEXT NOT NULL CHECK(window IN ('5h', 'weekly')),
    reset_at_epoch INTEGER NOT NULL,
    observed_at_epoch INTEGER NOT NULL,
    before_pct REAL,
    after_pct REAL,
    detection_method TEXT NOT NULL DEFAULT 'scheduled_crossing',
    PRIMARY KEY(window, reset_at_epoch)
);
CREATE INDEX idx_reset_events_observed_at ON reset_events(observed_at_epoch);
CREATE TABLE token_usage_events (
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
CREATE INDEX idx_token_events_time ON token_usage_events(occurred_at_epoch);
CREATE INDEX idx_token_events_source_model_time
    ON token_usage_events(source, model, occurred_at_epoch);
CREATE INDEX idx_token_events_provider_time
    ON token_usage_events(provider, occurred_at_epoch);
CREATE TABLE collector_state (
    source TEXT NOT NULL,
    state_key TEXT NOT NULL,
    state_json TEXT NOT NULL,
    updated_at_epoch INTEGER NOT NULL,
    PRIMARY KEY(source, state_key)
);
CREATE TABLE collector_runs (
    source TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
    status TEXT NOT NULL CHECK(status IN ('ok', 'disabled', 'unavailable', 'error')),
    last_attempt_at_epoch INTEGER,
    last_success_at_epoch INTEGER,
    last_error TEXT,
    source_schema TEXT
);
CREATE TABLE forecast_samples (
    scraped_at_epoch INTEGER PRIMARY KEY,
    generated_at_epoch INTEGER NOT NULL,
    chance_24h_pct INTEGER NOT NULL CHECK(chance_24h_pct BETWEEN 0 AND 100),
    chance_6h_pct INTEGER NOT NULL CHECK(chance_6h_pct BETWEEN 0 AND 100)
);
CREATE INDEX idx_forecast_samples_scraped_at
    ON forecast_samples(scraped_at_epoch);
"""

_EXPECTED_V4_COLUMNS = {
    "metadata": {"key", "value"},
    "snapshots": {
        "scraped_at_epoch", "scraped_at", "five_h_pct", "five_h_reset",
        "five_h_reset_at", "weekly_pct", "weekly_reset", "weekly_reset_at",
        "sample_interval_seconds", "history_window_hours", "limit_id",
    },
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
    "forecast_samples": {
        "scraped_at_epoch", "generated_at_epoch", "chance_24h_pct", "chance_6h_pct",
    },
    "quota_anomalies": {
        "anomaly_id", "dedupe_key", "anomaly_type", "window", "limit_id",
        "detected_at_epoch", "before_pct", "after_pct", "before_reset_at",
        "after_reset_at", "message", "journaled_at",
    },
    "anomaly_detector_state": {
        "limit_id", "window", "state_json", "updated_at_epoch",
    },
}


class SQLiteMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "archive.sqlite3"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def _create_legacy_archive(self, version: int) -> None:
        # Each subtest uses the same temporary directory. Remove SQLite
        # sidecars and migration artifacts so a prior WAL cannot be replayed
        # into the next fixture and each assertion sees one backup.
        for artifact in self.path.parent.glob(f"{self.path.name}*"):
            artifact.unlink()
        schema = {1: _V1_SCHEMA, 2: _V2_SCHEMA, 3: _V3_SCHEMA}[version]
        with sqlite3.connect(self.path) as connection:
            connection.executescript(schema)
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES ('schema_version', ?)",
                (str(version),),
            )
            connection.execute(
                """INSERT INTO snapshots(
                    scraped_at_epoch, scraped_at, five_h_pct, weekly_pct, limit_id
                ) VALUES (?, ?, ?, ?, ?)""",
                (1000 + version, "1970-01-01T00:16:41Z", 80, 70, f"v{version}"),
            )
            if version >= 2:
                connection.execute(
                    """INSERT INTO token_usage_events(
                        occurred_at_epoch, source, provider, model,
                        external_id
                    ) VALUES (?, ?, ?, ?, ?)""",
                    (2000 + version, "codex", "openai", "gpt-test", f"legacy-{version}"),
                )
            if version >= 3:
                connection.execute(
                    """INSERT INTO forecast_samples(
                        scraped_at_epoch, generated_at_epoch, chance_24h_pct,
                        chance_6h_pct
                    ) VALUES (?, ?, ?, ?)""",
                    (3000 + version, 3000 + version, 75, 25),
                )
            connection.execute(f"PRAGMA user_version = {version}")

    def _assert_v4_layout(self, connection: sqlite3.Connection) -> None:
        for table, expected_columns in _EXPECTED_V4_COLUMNS.items():
            actual_columns = {
                str(row[1])
                for row in connection.execute(f'PRAGMA table_info("{table}")')
            }
            self.assertEqual(expected_columns, actual_columns, table)

    def test_fresh_database_is_created_at_v4_and_integrity_checked(self) -> None:
        with storage.connect_database(self.path) as connection:
            self.assertEqual((4,), connection.execute("PRAGMA user_version").fetchone())
            self.assertEqual(
                ("4",),
                connection.execute(
                    "SELECT value FROM metadata WHERE key = 'schema_version'"
                ).fetchone(),
            )
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())
            self._assert_v4_layout(connection)

        self.assertEqual(
            [], list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))
        )

    def test_supported_legacy_versions_migrate_to_v4_without_losing_rows(self) -> None:
        for version in (1, 2, 3):
            with self.subTest(version=version):
                self._create_legacy_archive(version)
                with storage.connect_database(self.path) as connection:
                    self.assertEqual(
                        (4,), connection.execute("PRAGMA user_version").fetchone()
                    )
                    self._assert_v4_layout(connection)
                    self.assertEqual(
                        (f"v{version}",),
                        connection.execute(
                            "SELECT limit_id FROM snapshots WHERE scraped_at_epoch = ?",
                            (1000 + version,),
                        ).fetchone(),
                    )
                    if version >= 2:
                        self.assertEqual(
                            (f"legacy-{version}",),
                            connection.execute(
                                "SELECT external_id FROM token_usage_events"
                            ).fetchone(),
                        )
                    if version >= 3:
                        self.assertEqual(
                            (75,),
                            connection.execute(
                                "SELECT chance_24h_pct FROM forecast_samples"
                            ).fetchone(),
                        )
                    self.assertEqual(
                        ("ok",), connection.execute("PRAGMA quick_check").fetchone()
                    )

                self.assertEqual(
                    1,
                    len(list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))),
                )

    def test_future_schema_is_rejected_before_any_migration_or_backup(self) -> None:
        with sqlite3.connect(self.path) as connection:
            connection.execute("PRAGMA user_version = 5")

        with self.assertRaisesRegex(storage.ArchiveSchemaError, "unsupported archive schema"):
            storage.connect_database(self.path)

        self.assertEqual(
            [], list(self.path.parent.glob(f"{self.path.name}.pre-migration.*"))
        )
        with sqlite3.connect(self.path) as connection:
            self.assertEqual((5,), connection.execute("PRAGMA user_version").fetchone())

    def test_partial_known_schema_is_rejected_without_being_completed(self) -> None:
        with sqlite3.connect(self.path) as connection:
            connection.executescript(_V1_SCHEMA)
            connection.execute("INSERT INTO metadata VALUES ('schema_version', '4')")
            connection.execute("PRAGMA user_version = 4")

        with self.assertRaisesRegex(
            storage.ArchiveSchemaError, "archive schema v4 is missing tables"
        ):
            storage.connect_database(self.path)

        with sqlite3.connect(self.path) as connection:
            self.assertEqual((4,), connection.execute("PRAGMA user_version").fetchone())
            self.assertEqual(("ok",), connection.execute("PRAGMA quick_check").fetchone())


if __name__ == "__main__":
    unittest.main()
