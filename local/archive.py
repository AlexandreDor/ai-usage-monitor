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
    validate_database_parent,
    wal_sidecar_paths,
)
from anomalies import (
    RANDOM_WEEKLY_RESET_FULL_REFILL_PCT,
    RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT,
    RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS,
    process_snapshot,
)
from history import (
    SQLITE_INTEGER_MAX,
    SCHEMA_VERSION as SNAPSHOT_SCHEMA_VERSION,
    canonicalize_limit_id,
    opaque_limit_id_from_raw,
)

RECENT_SECONDS = 24 * 60 * 60
MEDIUM_SECONDS = 7 * 24 * 60 * 60
MEDIUM_BUCKET_SECONDS = 30 * 60
OLD_BUCKET_SECONDS = 60 * 60
MAX_RETENTION_DAYS = 36500


class ArchiveInputError(ValueError):
    """A snapshot or configuration value is invalid."""


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def error(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)


def finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, ValueError):
        return False


def optional_number(value: Any, *, strict: bool) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        numeric = float(value)
    except (OverflowError, ValueError) as exc:
        if strict:
            raise ArchiveInputError("snapshot contains a number outside the supported range") from exc
        return None
    if not math.isfinite(numeric) or not 0 <= numeric <= 100:
        if strict:
            raise ArchiveInputError("usage percentages must be finite numbers from 0 to 100")
        return None
    return numeric


def optional_positive_epoch(value: Any, *, strict: bool) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        numeric = float(value)
    except (OverflowError, ValueError) as exc:
        raise ArchiveInputError("reset epoch is outside the supported range") from exc
    if not math.isfinite(numeric):
        raise ArchiveInputError("reset epoch must be finite")
    if numeric <= 0:
        return None
    if numeric > SQLITE_INTEGER_MAX:
        raise ArchiveInputError("reset epoch is outside the supported range")
    if not numeric.is_integer():
        # Fractional reset epochs are never safe to salvage: truncation would
        # change reset-event identity. Reject them even while reading legacy
        # history so archive ingestion cannot write a partial replacement.
        raise ArchiveInputError("reset epoch must be an integer number of seconds")
    return int(numeric)


def parse_timestamp(value: Any) -> tuple[str, int] | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    try:
        epoch = int(parsed.timestamp())
    except (OverflowError, OSError, ValueError):
        return None
    if epoch <= 0:
        return None
    return value, epoch


def normalize_snapshot(value: Any, *, strict: bool) -> dict[str, Any] | None:
    if not isinstance(value, dict) or isinstance(value, list):
        if strict:
            raise ArchiveInputError("snapshot must be a JSON object")
        return None

    declared_version = value.get("schema_version", 0)
    if (
        isinstance(declared_version, bool)
        or not isinstance(declared_version, int)
        or declared_version < 0
    ):
        if strict:
            raise ArchiveInputError("snapshot schema_version must be an integer")
        return None
    if declared_version > SNAPSHOT_SCHEMA_VERSION:
        raise ArchiveInputError(
            "unsupported snapshot schema version; "
            f"maximum supported version is {SNAPSHOT_SCHEMA_VERSION}"
        )

    timestamp = parse_timestamp(value.get("scraped_at"))
    if timestamp is None:
        if strict:
            raise ArchiveInputError("snapshot has an invalid scraped_at timestamp")
        return None

    normalized: dict[str, Any] = {
        "scraped_at": timestamp[0],
        "scraped_at_epoch": timestamp[1],
        "five_h_pct": optional_number(value.get("five_h_pct"), strict=strict),
        "five_h_reset": None,
        "five_h_reset_at": optional_positive_epoch(value.get("five_h_reset_at"), strict=strict),
        "weekly_pct": optional_number(value.get("weekly_pct"), strict=strict),
        "weekly_reset": None,
        "weekly_reset_at": optional_positive_epoch(value.get("weekly_reset_at"), strict=strict),
        "sample_interval_seconds": None,
        "history_window_hours": None,
        "limit_id": None,
        "forecast": None,
    }

    for key in ("five_h_reset", "weekly_reset"):
        reset = value.get(key)
        if isinstance(reset, str) and len(reset) <= 100 and "@" not in reset:
            normalized[key] = reset
        elif reset is not None:
            normalized[key] = "unknown"

    interval = value.get("sample_interval_seconds")
    if interval is not None:
        if not finite_number(interval) or not float(interval).is_integer() or not 1 <= float(interval) <= 86_400:
            if strict:
                raise ArchiveInputError("sample interval must be an integer from 1 to 86400")
        else:
            normalized["sample_interval_seconds"] = int(interval)

    window = value.get("history_window_hours")
    if window is not None:
        if not finite_number(window) or not 0 <= float(window) <= 8_760:
            if strict:
                raise ArchiveInputError("history window must be a finite number from 0 to 8760")
        else:
            normalized["history_window_hours"] = float(window)

    normalized["limit_id"] = (
        canonicalize_limit_id(value.get("limit_id"))
        if declared_version == SNAPSHOT_SCHEMA_VERSION
        else opaque_limit_id_from_raw(value.get("limit_id"))
    )

    forecast = value.get("codex_forecast")
    if isinstance(forecast, dict):
        chance_24h = forecast.get("chance_24h_pct")
        chance_6h = forecast.get("chance_6h_pct")
        generated = parse_timestamp(forecast.get("generated_at"))
        if (
            isinstance(chance_24h, int)
            and not isinstance(chance_24h, bool)
            and 0 <= chance_24h <= 100
            and isinstance(chance_6h, int)
            and not isinstance(chance_6h, bool)
            and 0 <= chance_6h <= 100
            and generated is not None
        ):
            normalized["forecast"] = {
                "generated_at_epoch": generated[1],
                "chance_24h_pct": chance_24h,
                "chance_6h_pct": chance_6h,
            }

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
    except (OSError, UnicodeError, ValueError) as exc:
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
    forecast = snapshot.get("forecast")
    if forecast is not None:
        connection.execute(
            """
            INSERT INTO forecast_samples (
                scraped_at_epoch, generated_at_epoch,
                chance_24h_pct, chance_6h_pct
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(scraped_at_epoch) DO UPDATE SET
                generated_at_epoch = excluded.generated_at_epoch,
                chance_24h_pct = excluded.chance_24h_pct,
                chance_6h_pct = excluded.chance_6h_pct
            """,
            (
                snapshot["scraped_at_epoch"],
                forecast["generated_at_epoch"],
                forecast["chance_24h_pct"],
                forecast["chance_6h_pct"],
            ),
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

    connection.execute(
        """
        DELETE FROM forecast_samples
        WHERE scraped_at_epoch >= ?
          AND scraped_at_epoch < ?
          AND scraped_at_epoch NOT IN (
              SELECT MAX(scraped_at_epoch)
              FROM forecast_samples
              WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
              GROUP BY scraped_at_epoch / ?
          )
        """,
        (medium_start, recent_start, medium_start, recent_start, MEDIUM_BUCKET_SECONDS),
    )
    connection.execute(
        """
        DELETE FROM forecast_samples
        WHERE scraped_at_epoch < ?
          AND scraped_at_epoch NOT IN (
              SELECT MAX(scraped_at_epoch)
              FROM forecast_samples
              WHERE scraped_at_epoch < ?
              GROUP BY scraped_at_epoch / ?
          )
        """,
        (medium_start, medium_start, OLD_BUCKET_SECONDS),
    )

    if retention_days > 0:
        cutoff = anchor - retention_days * 24 * 60 * 60
        connection.execute("DELETE FROM snapshots WHERE scraped_at_epoch < ?", (cutoff,))
        connection.execute(
            "DELETE FROM forecast_samples WHERE scraped_at_epoch < ?", (cutoff,)
        )
        # An anomaly that has not reached the alert journal is still owed to
        # the user, even if it is older than the normal archive horizon.  Once
        # journaled, it follows the same retention boundary as other derived
        # archive events.  Keep the currently active detector group so a
        # returning/slowly sampled limit does not lose its baseline.
        connection.execute(
            "DELETE FROM quota_anomalies "
            "WHERE journaled_at IS NOT NULL AND detected_at_epoch < ?",
            (cutoff,),
        )
        active_row = connection.execute(
            "SELECT value FROM metadata WHERE key = 'anomaly_active_limit_id'"
        ).fetchone()
        active_limit = active_row[0] if active_row else None
        connection.execute(
            "DELETE FROM anomaly_detector_state "
            "WHERE updated_at_epoch < ? AND limit_id IS NOT ?",
            (cutoff, active_limit),
        )


def rebuild_reset_events(connection: sqlite3.Connection) -> None:
    """Derive scheduled and unexpected weekly resets from retained snapshots."""
    rows = connection.execute(
        """
        SELECT scraped_at_epoch, five_h_pct, five_h_reset_at,
               weekly_pct, weekly_reset_at, sample_interval_seconds, limit_id
          FROM snapshots
        ORDER BY scraped_at_epoch
        """
    ).fetchall()
    connection.execute("DELETE FROM reset_events")
    windows = (("5h", 1, 2), ("weekly", 3, 4))
    scheduled_5h_cycles = set()
    scheduled_weekly_cycles = set()
    for previous, current in zip(rows, rows[1:]):
        gap = current[0] - previous[0]
        intervals = [
            value for value in (previous[5], current[5])
            if isinstance(value, (int, float)) and value > 0
        ]
        expected_interval = int(max(intervals, default=900))
        # A deadline crossing alone is not enough evidence across a long gap.
        if gap <= 0 or gap > max(3_600, expected_interval * 2):
            continue
        if previous[6] != current[6]:
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
                if window == "weekly":
                    scheduled_weekly_cycles.add((reset_at, previous[6]))
                else:
                    scheduled_5h_cycles.add((reset_at, previous[6]))

    # A 5-hour reset can be observed even when the quota remains full. Compare
    # only complete observations from one limit group and anchor the event to
    # the first sample carrying the advanced deadline. A scheduled crossing
    # already identified above owns that transition, preventing two markers
    # for the same reset.
    previous_five = None
    for current in rows:
        current_pct, current_deadline = current[1], current[2]
        if not isinstance(current_pct, (int, float)) or not isinstance(current_deadline, int):
            continue
        if previous_five is None:
            previous_five = current
            continue

        previous = previous_five
        previous_pct, previous_deadline = previous[1], previous[2]
        scheduled_crossing = (previous_deadline, previous[6]) in scheduled_5h_cycles
        if (
            previous[6] == current[6]
            and isinstance(previous_pct, (int, float))
            and isinstance(previous_deadline, int)
            and not scheduled_crossing
            and previous_pct == 100
            and current_pct == 100
            and current_deadline > previous_deadline
        ):
            connection.execute(
                """
                INSERT OR IGNORE INTO reset_events (
                    window, reset_at_epoch, observed_at_epoch,
                    before_pct, after_pct, detection_method
                ) VALUES ('5h', ?, ?, ?, ?, 'observed_refill')
                """,
                (current[0], current[0], previous_pct, current_pct),
            )
        previous_five = current

    # A refill plus a later deadline remains positive reset evidence after a
    # long gap or partial samples. Compare coherent observations from the same
    # limit group and anchor the event to the first complete post-reset sample.
    previous_weekly = None
    for current in rows:
        current_pct, current_deadline = current[3], current[4]
        if not isinstance(current_pct, (int, float)) or not isinstance(current_deadline, int):
            continue
        if previous_weekly is None:
            previous_weekly = current
            continue

        previous = previous_weekly
        previous_pct, current_pct = previous[3], current[3]
        previous_deadline, current_deadline = previous[4], current[4]
        refill_change = current_pct - previous_pct
        scheduled_crossing = (previous_deadline, previous[6]) in scheduled_weekly_cycles
        if (
            previous[6] == current[6]
            and isinstance(previous_pct, (int, float))
            and isinstance(previous_deadline, int)
            and not scheduled_crossing
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
        previous_weekly = current


def ingest(
    database_path: Path,
    history_path: Path,
    snapshot: dict[str, Any],
    retention_days: int,
) -> None:
    # Reject future rolling-history entries before creating or mutating the
    # SQLite archive.  Legacy malformed entries are still salvaged as before.
    history_entries = read_history(history_path)
    database_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(database_path.parent, 0o700)
    connection = connect_database(database_path)
    try:
        with connection:
            migrated = connection.execute(
                "SELECT value FROM metadata WHERE key = 'history_json_migrated'"
            ).fetchone()
            if not migrated or migrated[0] != "1":
                for entry in history_entries:
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
            # Detector state is compact and independent from snapshots.  The
            # same call is idempotent when a live cycle replays this sample.
            process_snapshot(connection, snapshot)
    finally:
        connection.close()
    os.chmod(database_path, 0o600)


def backup_corrupt_database(database_path: Path) -> Path:
    database_path = Path(database_path)
    validate_database_parent(database_path)
    timestamp = int(time.time())
    backup = database_path.with_name(f"{database_path.name}.corrupt.{timestamp}")
    suffix = 1
    source_paths = (database_path, *wal_sidecar_paths(database_path))
    while True:
        destinations = (
            backup,
            backup.with_name(f"{backup.name}-wal"),
            backup.with_name(f"{backup.name}-shm"),
        )
        if not any(path.exists() or path.is_symlink() for path in destinations):
            break
        backup = database_path.with_name(f"{database_path.name}.corrupt.{timestamp}.{suffix}")
        suffix += 1
    existing_sources = [path for path in source_paths if path.exists() or path.is_symlink()]
    if not existing_sources:
        raise OSError(f"archive database and WAL sidecars are missing: {database_path}")
    moved: list[tuple[Path, Path]] = []
    try:
        for source_path in existing_sources:
            destination = backup if source_path == database_path else backup.with_name(
                f"{backup.name}{source_path.name[len(database_path.name):]}"
            )
            if destination.exists() or destination.is_symlink():
                raise FileExistsError(destination)
            os.replace(source_path, destination)
            moved.append((source_path, destination))
    except Exception:
        # Keep recovery atomic from the caller's point of view: if a sidecar
        # cannot be moved, put every already-moved member back in place.
        for source_path, destination in reversed(moved):
            try:
                os.replace(destination, source_path)
            except OSError:
                pass
        raise
    return backup


def parse_retention(value: str) -> int:
    if not isinstance(value, str) or len(value) > len(str(MAX_RETENTION_DAYS)) or not value.isdigit():
        raise ArchiveInputError("archive retention must be an integer from 0 to 36500 days")
    try:
        retention = int(value)
    except (ValueError, OverflowError) as exc:
        raise ArchiveInputError("archive retention must be an integer from 0 to 36500 days") from exc
    if retention < 0 or retention > MAX_RETENTION_DAYS:
        raise ArchiveInputError("archive retention must be an integer from 0 to 36500 days")
    return retention


def run(args: argparse.Namespace) -> int:
    try:
        retention_days = parse_retention(args.retention_days)
        value = json.load(sys.stdin)
        snapshot = normalize_snapshot(value, strict=True)
        assert snapshot is not None
    except (ArchiveInputError, OSError, ValueError, OverflowError) as exc:
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
        except (ArchiveCorruptionError, OSError, OverflowError, sqlite3.DatabaseError) as rebuild_error:
            error(f"Could not rebuild archive after corruption: {rebuild_error}")
            return 1
    except (ArchiveInputError, OSError, OverflowError, sqlite3.DatabaseError) as exc:
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
