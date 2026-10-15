"""Sanitized, read-only monitor and archive diagnostics for the local dashboard."""

from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

import storage
from operations import open_owned_regular, open_private_directory, validate_archive_path


HEALTH_MAX_BYTES = 64 * 1024
_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
_ERRORS = {
    "alert state persistence failed": ("alert_state_failed", "Alert state could not be saved."),
    "alert journal pruning failed": ("alert_journal_failed", "Alert journal maintenance failed."),
    "interrupted alert script fail-safe cleanup failed": (
        "alert_cleanup_failed", "Alert cleanup failed."),
}
_ANOMALY_TYPES = frozenset({
    "quota_increase", "reset_shift", "reset_in_past", "reset_missing", "reset_oscillation",
})


def _integer(value: object, *, minimum: int = 0, maximum: int = 2**53 - 1) -> int | None:
    return value if type(value) is int and minimum <= value <= maximum else None


def _percentage(value: object) -> float | None:
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 100:
        return None
    return float(value)


def _timestamp(value: object) -> str | None:
    if not isinstance(value, str) or not _TIMESTAMP.fullmatch(value):
        return None
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None
    return value


def _epoch_timestamp(value: object) -> str | None:
    epoch = _integer(value, maximum=253402300799)
    if epoch is None:
        return None
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return None


def _read_health(runtime_directory: Path) -> dict:
    _, directory = open_private_directory(runtime_directory)
    try:
        descriptor = open_owned_regular("health.json", directory)
        try:
            if os.fstat(descriptor).st_size > HEALTH_MAX_BYTES:
                raise ValueError("health is too large")
            with os.fdopen(descriptor, "rb") as stream:
                descriptor = -1
                raw = stream.read(HEALTH_MAX_BYTES + 1)
            if len(raw) > HEALTH_MAX_BYTES:
                raise ValueError("health is too large")
            health = json.loads(raw)
            if not isinstance(health, dict):
                raise ValueError("invalid health")
            return health
        finally:
            if descriptor >= 0:
                os.close(descriptor)
    finally:
        os.close(directory)


def build_diagnostics(runtime_directory: Path, database: Path, *, now: int | None = None) -> dict:
    """Return only allowlisted operational fields, never raw errors or identifiers."""
    now = int(time.time()) if now is None else now
    monitor = dict.fromkeys((
        "last_cycle_at", "last_success_at", "consecutive_failures", "last_cycle_duration_ms",
        "interval_seconds", "age_seconds", "last_error_at", "error_code", "error_message",
    ))
    monitor["status"] = "unavailable"
    archive = dict.fromkeys((
        "snapshots", "token_events", "resets", "anomalies", "pending_anomalies", "last_snapshot_at",
    ))
    archive["status"] = "unavailable"
    result = {"schema_version": 1, "monitor": monitor, "archive": archive,
              "anomalies": [], "warnings": []}
    try:
        health = _read_health(runtime_directory)
    except (OSError, ValueError, RecursionError):
        result["warnings"].append("Monitor health is unavailable.")
    else:
        monitor["last_cycle_at"] = _timestamp(health.get("last_cycle"))
        monitor["last_success_at"] = _timestamp(health.get("last_success"))
        for output, source, minimum in (
            ("consecutive_failures", "consecutive_failures", 0),
            ("last_cycle_duration_ms", "last_cycle_duration_ms", 0),
            ("interval_seconds", "last_cycle_interval_seconds", 1),
        ):
            monitor[output] = _integer(health.get(source), minimum=minimum)
        error = health.get("last_error")
        if isinstance(error, dict):
            monitor["last_error_at"] = _timestamp(error.get("at"))
            message = error.get("message")
            code, message = _ERRORS.get(message if isinstance(message, str) else "", (
                "collection_failed", "Collection or alert delivery failed."))
            monitor["error_code"], monitor["error_message"] = code, message
        if monitor["last_cycle_at"]:
            epoch = int(datetime.strptime(monitor["last_cycle_at"], "%Y-%m-%dT%H:%M:%SZ")
                        .replace(tzinfo=timezone.utc).timestamp())
            monitor["age_seconds"] = max(0, now - epoch)
            monitor["status"] = "healthy" if health.get("last_cycle_result") == "success" else "degraded"
            if monitor["age_seconds"] > max(300, (monitor["interval_seconds"] or 900) * 2):
                monitor["status"] = "stale"
                result["warnings"].append("Monitor health is stale.")
        else:
            result["warnings"].append("Monitor health is unavailable.")
    try:
        safe_database = validate_archive_path(database)
        connection = storage.connect_database(safe_database, read_only=True)
        try:
            connection.execute("BEGIN")
            for key, table in (("snapshots", "snapshots"), ("token_events", "token_usage_events"),
                               ("resets", "reset_events"), ("anomalies", "quota_anomalies")):
                archive[key] = _integer(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
            archive["pending_anomalies"] = _integer(connection.execute(
                "SELECT COUNT(*) FROM quota_anomalies WHERE journaled_at IS NULL").fetchone()[0])
            archive["last_snapshot_at"] = _epoch_timestamp(connection.execute(
                "SELECT MAX(scraped_at_epoch) FROM snapshots").fetchone()[0])
            rows = connection.execute(
                "SELECT window, anomaly_type, detected_at_epoch, before_pct, after_pct "
                "FROM quota_anomalies ORDER BY detected_at_epoch DESC LIMIT 20").fetchall()
            result["anomalies"] = [{
                "window": row[0] if row[0] in ("5h", "weekly") else None,
                "type": row[1] if row[1] in _ANOMALY_TYPES else None,
                "detected_at": _epoch_timestamp(row[2]),
                "before_pct": _percentage(row[3]), "after_pct": _percentage(row[4]),
            } for row in rows]
            archive["status"] = "healthy"
        finally:
            connection.close()
    except OSError:
        result["warnings"].append("Archive is unavailable.")
    except (sqlite3.DatabaseError, storage.ArchiveCorruptionError, ValueError):
        archive.update(dict.fromkeys(key for key in archive if key != "status"))
        archive["status"] = "unhealthy"
        result["anomalies"] = []
        result["warnings"].append("Archive could not be read safely.")
    return result
