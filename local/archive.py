#!/usr/bin/env python3
"""Progressively compacted local archive for Codex usage snapshots."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
import time
from typing import Any

from storage import (
    ArchiveCorruptionError,
    SCHEMA_VERSION,
    connect_database,
    is_corruption_error,
)

RECENT_SECONDS = 24 * 60 * 60
MEDIUM_SECONDS = 7 * 24 * 60 * 60
MEDIUM_BUCKET_SECONDS = 30 * 60
OLD_BUCKET_SECONDS = 60 * 60
RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT = 20
RANDOM_WEEKLY_RESET_FULL_REFILL_PCT = 99
RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS = 2 * 60 * 60
MAX_RETENTION_DAYS = 36500


class ArchiveInputError(ValueError):
    """A snapshot or configuration value is invalid."""


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def error(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)


def finite_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def optional_number(value: Any) -> float | None:
    if value is None:
        return None
    if not finite_number(value):
        return None
    return float(value)


def optional_positive_epoch(value: Any) -> int | None:
    if value is None or not finite_number(value) or value <= 0:
        return None
    return int(value)


def parse_timestamp(value: Any) -> tuple[str, int] | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    epoch = int(parsed.timestamp())
    if epoch <= 0:
        return None
    return value, epoch


def normalize_snapshot(value: Any, *, strict: bool) -> dict[str, Any] | None:
    if not isinstance(value, dict) or isinstance(value, list):
        if strict:
            raise ArchiveInputError("snapshot must be a JSON object")
        return None

    timestamp = parse_timestamp(value.get("scraped_at"))
    if timestamp is None:
        if strict:
            raise ArchiveInputError("snapshot has an invalid scraped_at timestamp")
        return None

    normalized: dict[str, Any] = {
        "scraped_at": timestamp[0],
        "scraped_at_epoch": timestamp[1],
        "five_h_pct": optional_number(value.get("five_h_pct")),
        "five_h_reset": None,
        "five_h_reset_at": optional_positive_epoch(value.get("five_h_reset_at")),
        "weekly_pct": optional_number(value.get("weekly_pct")),
        "weekly_reset": None,
        "weekly_reset_at": optional_positive_epoch(value.get("weekly_reset_at")),
        "sample_interval_seconds": None,
        "history_window_hours": None,
        "limit_id": None,
    }

    for key in ("five_h_reset", "weekly_reset"):
        reset = value.get(key)
        if isinstance(reset, str) and len(reset) <= 100 and "@" not in reset:
            normalized[key] = reset
        elif reset is not None:
            normalized[key] = "unknown"

    interval = value.get("sample_interval_seconds")
    if finite_number(interval) and interval > 0:
        normalized["sample_interval_seconds"] = int(interval)

    window = value.get("history_window_hours")
    if finite_number(window) and window >= 0:
        normalized["history_window_hours"] = float(window)

    limit_id = value.get("limit_id")
    if isinstance(limit_id, str) and len(limit_id) <= 100 and not any(ord(char) < 32 for char in limit_id):
        normalized["limit_id"] = limit_id

    if normalized["five_h_pct"] is None and normalized["weekly_pct"] is None:
        if strict:
            raise ArchiveInputError("snapshot has no valid usage percentage")
        return None
    return normalized


def row_values(snapshot: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(snapshot[key] for key in (
        "scraped_at_epoch",
        "scraped_at",
        "five_h_pct",
        "five_h_reset",
        "five_h_reset_at",
        "weekly_pct",
        "weekly_reset",
        "weekly_reset_at",
        "sample_interval_seconds",
        "history_window_hours",
        "limit_id",
    ))


def read_history(history_path: Path) -> list[dict[str, Any]]:
    if not history_path.exists():
        return []
    try:
        value = json.loads(history_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        warn(f"Could not read rolling history for archive migration: {exc}")
        return []
    if not isinstance(value, list):
        warn("Rolling history is not an array; archive migration will keep only the current snapshot.")
        return []
    normalized: list[dict[str, Any]] = []
    for item in value:
        entry = normalize_snapshot(item, strict=False)
        if entry is not None:
            normalized.append(entry)
    return normalized


def insert_snapshot(connection: sqlite3.Connection, snapshot: dict[str, Any]) -> None:
    connection.execute(
        """
        INSERT INTO snapshots (
            scraped_at_epoch, scraped_at, five_h_pct, five_h_reset, five_h_reset_at,
            weekly_pct, weekly_reset, weekly_reset_at, sample_interval_seconds,
            history_window_hours, limit_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(scraped_at_epoch) DO UPDATE SET
            scraped_at = excluded.scraped_at,
            five_h_pct = excluded.five_h_pct,
            five_h_reset = excluded.five_h_reset,
            five_h_reset_at = excluded.five_h_reset_at,
            weekly_pct = excluded.weekly_pct,
            weekly_reset = excluded.weekly_reset,
            weekly_reset_at = excluded.weekly_reset_at,
            sample_interval_seconds = excluded.sample_interval_seconds,
            history_window_hours = excluded.history_window_hours,
            limit_id = excluded.limit_id
        """,
        row_values(snapshot),
    )


def compact(connection: sqlite3.Connection, retention_days: int) -> None:
    anchor_row = connection.execute("SELECT MAX(scraped_at_epoch) FROM snapshots").fetchone()
    anchor = anchor_row[0] if anchor_row else None
    if anchor is None:
        return

    medium_start = anchor - MEDIUM_SECONDS
    recent_start = anchor - RECENT_SECONDS

    connection.execute(
        """
        DELETE FROM snapshots
        WHERE scraped_at_epoch >= ?
          AND scraped_at_epoch < ?
          AND scraped_at_epoch NOT IN (
              SELECT MAX(scraped_at_epoch)
              FROM snapshots
              WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
              GROUP BY scraped_at_epoch / ?
          )
        """,
        (medium_start, recent_start, medium_start, recent_start, MEDIUM_BUCKET_SECONDS),
    )
    connection.execute(
        """
        DELETE FROM snapshots
        WHERE scraped_at_epoch < ?
          AND scraped_at_epoch NOT IN (
              SELECT MAX(scraped_at_epoch)
              FROM snapshots
              WHERE scraped_at_epoch < ?
              GROUP BY scraped_at_epoch / ?
          )
        """,
        (medium_start, medium_start, OLD_BUCKET_SECONDS),
    )

    if retention_days > 0:
        cutoff = anchor - retention_days * 24 * 60 * 60
        connection.execute("DELETE FROM snapshots WHERE scraped_at_epoch < ?", (cutoff,))


def rebuild_reset_events(connection: sqlite3.Connection) -> None:
    """Derive scheduled and unexpected weekly resets from retained snapshots."""
    rows = connection.execute(
        """
        SELECT scraped_at_epoch, five_h_pct, five_h_reset_at,
               weekly_pct, weekly_reset_at
        FROM snapshots
        ORDER BY scraped_at_epoch
        """
    ).fetchall()
    connection.execute("DELETE FROM reset_events")
    windows = (("5h", 1, 2), ("weekly", 3, 4))
    for previous, current in zip(rows, rows[1:]):
        for window, pct_index, reset_index in windows:
            reset_at = previous[reset_index]
            if not isinstance(reset_at, int) or reset_at <= 0:
                continue
            if previous[0] < reset_at <= current[0]:
                connection.execute(
                    """
                    INSERT OR IGNORE INTO reset_events (
                        window, reset_at_epoch, observed_at_epoch,
                        before_pct, after_pct, detection_method
                    ) VALUES (?, ?, ?, ?, ?, 'scheduled_crossing')
                    """,
                    (
                        window,
                        reset_at,
                        current[0],
                        previous[pct_index],
                        current[pct_index],
                    ),
                )

        # Codex can refill the weekly window before its previously announced
        # deadline. Record this separately: the exact instant is unknown, so
        # the event is anchored to the first post-reset observation.
        previous_pct, current_pct = previous[3], current[3]
        previous_deadline, current_deadline = previous[4], current[4]
        refill_change = (
            current_pct - previous_pct
            if isinstance(previous_pct, (int, float))
            and isinstance(current_pct, (int, float))
            else None
        )
        if (
            refill_change is not None
            and isinstance(previous_deadline, int)
            and isinstance(current_deadline, int)
            and previous[0] < previous_deadline
            and not previous[0] < previous_deadline <= current[0]
            and current_deadline >= previous_deadline + RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS
            and refill_change > 0
            and (
                refill_change >= RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT
                or current_pct >= RANDOM_WEEKLY_RESET_FULL_REFILL_PCT
            )
        ):
            connection.execute(
                """
                INSERT OR IGNORE INTO reset_events (
                    window, reset_at_epoch, observed_at_epoch,
                    before_pct, after_pct, detection_method
                ) VALUES ('weekly', ?, ?, ?, ?, 'random_observed')
                """,
                (current[0], current[0], previous_pct, current_pct),
            )


def ingest(
    database_path: Path,
    history_path: Path,
    snapshot: dict[str, Any],
    retention_days: int,
) -> None:
    database_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(database_path.parent, 0o700)
    connection = connect_database(database_path)
    try:
        with connection:
            migrated = connection.execute(
                "SELECT value FROM metadata WHERE key = 'history_json_migrated'"
            ).fetchone()
            if not migrated or migrated[0] != "1":
                for entry in read_history(history_path):
                    insert_snapshot(connection, entry)
                connection.execute(
                    """
                    INSERT INTO metadata(key, value) VALUES('history_json_migrated', '1')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """
                )
            connection.execute(
                """
                INSERT INTO metadata(key, value) VALUES('schema_version', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                (SCHEMA_VERSION,),
            )
            insert_snapshot(connection, snapshot)
            compact(connection, retention_days)
            rebuild_reset_events(connection)
    finally:
        connection.close()
    os.chmod(database_path, 0o600)


def backup_corrupt_database(database_path: Path) -> Path:
    timestamp = int(time.time())
    backup = database_path.with_name(f"{database_path.name}.corrupt.{timestamp}")
    suffix = 1
    while backup.exists():
        backup = database_path.with_name(f"{database_path.name}.corrupt.{timestamp}.{suffix}")
        suffix += 1
    os.replace(database_path, backup)
    return backup


def parse_retention(value: str) -> int:
    if not value.isdigit():
        raise ArchiveInputError("archive retention must be an integer from 0 to 36500 days")
    retention = int(value)
    if retention < 0 or retention > MAX_RETENTION_DAYS:
        raise ArchiveInputError("archive retention must be an integer from 0 to 36500 days")
    return retention


def run(args: argparse.Namespace) -> int:
    try:
        retention_days = parse_retention(args.retention_days)
        value = json.load(sys.stdin)
        snapshot = normalize_snapshot(value, strict=True)
        assert snapshot is not None
    except (ArchiveInputError, json.JSONDecodeError, OSError) as exc:
        error(f"Archive input failed: {exc}")
        return 1

    database_path = Path(args.database)
    history_path = Path(args.history)
    try:
        ingest(database_path, history_path, snapshot, retention_days)
        return 0
    except ArchiveCorruptionError as exc:
        try:
            backup = backup_corrupt_database(database_path)
        except OSError as backup_error:
            error(f"Archive database is corrupt ({exc}); recovery backup failed: {backup_error}")
            return 1
        warn(f"Corrupt archive copied to {backup}; rebuilding it from rolling history.")
        try:
            ingest(database_path, history_path, snapshot, retention_days)
            return 0
        except (ArchiveCorruptionError, OSError, sqlite3.DatabaseError) as rebuild_error:
            error(f"Could not rebuild archive after corruption: {rebuild_error}")
            return 1
    except (OSError, sqlite3.DatabaseError) as exc:
        error(f"Archive update failed: {exc}")
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, help="SQLite archive path")
    parser.add_argument("--history", required=True, help="Rolling history JSON path")
    parser.add_argument("--retention-days", required=True, help="0 for unlimited, otherwise 1..36500")
    return parser


if __name__ == "__main__":
    raise SystemExit(run(build_parser().parse_args()))
