#!/usr/bin/env python3
"""Progressively compacted local archive for Codex usage snapshots."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import time
from typing import Any

try:
    from . import history as history_storage
except ImportError:
    import history as history_storage

from storage import (
    ArchiveCorruptionError,
    SCHEMA_VERSION,
    connect_database,
    publish_rebuilt_database,
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


def coerce_now(value: Any = None) -> float:
    """Return one finite wall-clock anchor for the whole archive operation."""

    current = time.time() if value is None else value
    if not finite_number(current):
        raise ArchiveInputError("archive clock anchor must be a finite epoch")
    return float(current)


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


def normalize_snapshot(value: Any, *, strict: bool) -> dict[str, Any] | None:
    try:
        parsed = history_storage.parse_snapshot(value)
    except history_storage.SnapshotValidationError as exc:
        if strict:
            raise ArchiveInputError(str(exc)) from exc
        return None
    return normalized_snapshot(parsed)


def normalized_snapshot(parsed: history_storage.ParsedSnapshot) -> dict[str, Any]:
    public = parsed.public
    return {
        "scraped_at": public["scraped_at"],
        "scraped_at_epoch": int(parsed.epoch),
        "five_h_pct": optional_number(public["five_h_pct"]),
        "five_h_reset": public["five_h_reset"],
        "five_h_reset_at": optional_positive_epoch(public["five_h_reset_at"]),
        "weekly_pct": optional_number(public["weekly_pct"]),
        "weekly_reset": public["weekly_reset"],
        "weekly_reset_at": optional_positive_epoch(public["weekly_reset_at"]),
        "sample_interval_seconds": optional_positive_epoch(public["sample_interval_seconds"]),
        "history_window_hours": optional_number(public["history_window_hours"]),
        "limit_id": public["limit_id"],
    }


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


def read_history(history_path: Path, current_epoch: int):
    try:
        for entry in history_storage.iter_validated_history(
            history_path, future_anchor=current_epoch
        ):
            yield normalized_snapshot(entry)
    except (history_storage.HistoryError, OSError) as exc:
        raise ArchiveInputError(
            f"rolling history migration failed validation: {exc}"
        ) from exc


def history_file_present(history_path: Path) -> bool:
    """Return whether the expected history file exists as a regular file."""

    try:
        file_stat = os.lstat(history_path)
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise ArchiveInputError(f"cannot inspect rolling history: {exc}") from exc
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise ArchiveInputError("rolling history must be a regular file")
    return True


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


def reject_future_snapshots(connection: sqlite3.Connection, current_epoch: int) -> None:
    future = connection.execute(
        "SELECT scraped_at_epoch FROM snapshots WHERE scraped_at_epoch > ? "
        "ORDER BY scraped_at_epoch LIMIT 1",
        (current_epoch + history_storage.FUTURE_TIMESTAMP_TOLERANCE_SECONDS,),
    ).fetchone()
    if future:
        raise ArchiveInputError(
            "archive contains a snapshot beyond the future timestamp tolerance; "
            "refusing compaction after a possible clock rollback"
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
               weekly_pct, weekly_reset_at, sample_interval_seconds
          FROM snapshots
        ORDER BY scraped_at_epoch
        """
    ).fetchall()
    connection.execute("DELETE FROM reset_events")
    windows = (("5h", 1, 2), ("weekly", 3, 4))
    for previous, current in zip(rows, rows[1:]):
        gap = current[0] - previous[0]
        intervals = [
            value for value in (previous[5], current[5])
            if isinstance(value, (int, float)) and value > 0
        ]
        expected_interval = int(max(intervals, default=900))
        # A reset deadline crossing a long observation gap is not enough
        # evidence that the reset was observed. Keep the event history
        # conservative instead of inventing missed resets.
        if gap <= 0 or gap > max(3_600, expected_interval * 2):
            continue
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
    *,
    now: float | int | None = None,
) -> None:
    clock_epoch = coerce_now(now)
    if (
        snapshot["scraped_at_epoch"]
        > clock_epoch + history_storage.FUTURE_TIMESTAMP_TOLERANCE_SECONDS
    ):
        raise ArchiveInputError(
            "snapshot scraped_at exceeds the future timestamp tolerance"
        )
    # Keep the old relative guard as well: an old incoming snapshot must not
    # make a future database row look historical after a clock rollback.
    history_anchor = min(float(snapshot["scraped_at_epoch"]), clock_epoch)
    database_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(database_path.parent, 0o700)
    connection = connect_database(database_path)
    try:
        with connection:
            reject_future_snapshots(connection, snapshot["scraped_at_epoch"])
            reject_future_snapshots(connection, clock_epoch)
            migrated = connection.execute(
                "SELECT value FROM metadata WHERE key = 'history_json_migrated'"
            ).fetchone()
            if not migrated or migrated[0] != "1":
                if history_file_present(history_path):
                    for entry in read_history(history_path, history_anchor):
                        insert_snapshot(connection, entry)
                    # Do not acknowledge a file that disappeared during the
                    # migration window; the next cycle must retry it.
                    if not history_file_present(history_path):
                        raise ArchiveInputError(
                            "rolling history disappeared during migration"
                        )
                    connection.execute(
                        """
                        INSERT INTO metadata(key, value) VALUES('history_json_migrated', '1')
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """
                    )
                else:
                    warn(
                        "Rolling history is temporarily unavailable; "
                        "history_json_migrated remains unset."
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


def rebuild_corrupt_database(
    database_path: Path,
    history_path: Path,
    snapshot: dict[str, Any],
    retention_days: int,
    *,
    now: float | int | None = None,
) -> Path:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{database_path.name}.rebuild.",
        suffix=".sqlite3",
        dir=database_path.parent,
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    temporary_path.unlink()
    try:
        ingest(temporary_path, history_path, snapshot, retention_days, now=now)
        return publish_rebuilt_database(database_path, temporary_path)
    finally:
        for suffix in ("", "-wal", "-shm", ".storage.lock"):
            try:
                Path(str(temporary_path) + suffix).unlink()
            except FileNotFoundError:
                pass


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
        now = coerce_now(getattr(args, "now", None))
    except (ArchiveInputError, json.JSONDecodeError, OSError) as exc:
        error(f"Archive input failed: {exc}")
        return 1

    database_path = Path(args.database)
    history_path = Path(args.history)
    try:
        ingest(database_path, history_path, snapshot, retention_days, now=now)
        return 0
    except ArchiveCorruptionError as exc:
        try:
            backup = rebuild_corrupt_database(
                database_path, history_path, snapshot, retention_days, now=now
            )
            warn(f"Corrupt archive moved to {backup}; rebuilt it from rolling history.")
            return 0
        except (
            ArchiveCorruptionError,
            ArchiveInputError,
            OSError,
            sqlite3.DatabaseError,
        ) as rebuild_error:
            error(f"Could not rebuild archive after corruption: {rebuild_error}")
            return 1
    except ArchiveInputError as exc:
        error(f"Archive history migration failed: {exc}")
        return 1
    except (OSError, sqlite3.DatabaseError) as exc:
        error(f"Archive update failed: {exc}")
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, help="SQLite archive path")
    parser.add_argument("--history", required=True, help="Rolling history JSON path")
    parser.add_argument("--retention-days", required=True, help="0 for unlimited, otherwise 1..36500")
    parser.add_argument(
        "--now",
        type=float,
        default=None,
        help="wall-clock epoch used for future timestamp validation (default: current time)",
    )
    return parser


if __name__ == "__main__":
    raise SystemExit(run(build_parser().parse_args()))
