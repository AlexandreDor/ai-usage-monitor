#!/usr/bin/env python3
"""Validate and maintain the rolling public quota history."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Mapping
import uuid


MAX_HISTORY_ENTRIES = 10_000
MAX_HISTORY_BYTES = 16 * 1024 * 1024

PERCENTAGE_FIELDS = ("five_h_pct", "weekly_pct")
RESET_LABEL_FIELDS = ("five_h_reset", "weekly_reset")
RESET_EPOCH_FIELDS = ("five_h_reset_at", "weekly_reset_at")
UTC = dt.timezone.utc
EPOCH = dt.datetime(1970, 1, 1, tzinfo=UTC)


class HistoryError(ValueError):
    """The history update cannot be completed safely."""


class SnapshotValidationError(HistoryError):
    """A public snapshot does not satisfy the history contract."""


@dataclass(frozen=True)
class Entry:
    public: dict[str, Any]
    epoch_microseconds: int


@dataclass(frozen=True)
class LoadedHistory:
    entries: list[Entry]
    corrupt: bool = False
    reason: str = ""


@dataclass(frozen=True)
class HistoryUpdate:
    history: list[dict[str, Any]]
    added: bool
    data_updated: bool
    backup: Path | None = None


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def error(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)


def finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def normal_number(value: int | float) -> int | float:
    numeric = float(value)
    return int(numeric) if numeric.is_integer() else numeric


def parse_timestamp(value: Any) -> tuple[str, int]:
    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise SnapshotValidationError("scraped_at must be an ISO-8601 timestamp")

    raw = value.strip()
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError) as exc:
        raise SnapshotValidationError("scraped_at is not a valid ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    try:
        parsed = parsed.astimezone(UTC)
        delta = parsed - EPOCH
    except (OverflowError, ValueError) as exc:
        raise SnapshotValidationError("scraped_at is outside the supported range") from exc

    epoch_microseconds = (
        delta.days * 86_400_000_000
        + delta.seconds * 1_000_000
        + delta.microseconds
    )
    if epoch_microseconds < 0:
        raise SnapshotValidationError("scraped_at must not precede the Unix epoch")

    if parsed.microsecond:
        canonical = parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    else:
        canonical = parsed.isoformat(timespec="seconds").replace("+00:00", "Z")
    return canonical, epoch_microseconds


def timestamp_to_epoch(value: Any) -> int | float:
    """Return the same epoch interpretation used for history operations."""

    _, microseconds = parse_timestamp(value)
    seconds = microseconds / 1_000_000
    return int(seconds) if seconds.is_integer() else seconds


def validate_percentage(field: str, value: Any) -> int | float | None:
    if value is None:
        return None
    if not finite_number(value) or not 0 <= float(value) <= 100:
        raise SnapshotValidationError(
            f"{field} must be a finite percentage from 0 to 100 or null"
        )
    return normal_number(value)


def sanitize_reset_label(value: Any) -> str:
    if not isinstance(value, str) or len(value) > 100 or "@" in value:
        return "unknown"
    return value


def sanitize_optional_epoch(value: Any) -> int | float | None:
    if not finite_number(value) or float(value) <= 0:
        return None
    return normal_number(value)


def sanitize_limit_id(value: Any) -> str | None:
    if (
        isinstance(value, str)
        and len(value) <= 100
        and not any(ord(character) < 32 for character in value)
    ):
        return value
    return None


def sanitize_forecast(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    chance_24h = value.get("chance_24h_pct")
    chance_6h = value.get("chance_6h_pct")
    generated_at = value.get("generated_at")
    if any(
        not isinstance(chance, int)
        or isinstance(chance, bool)
        or not 0 <= chance <= 100
        for chance in (chance_24h, chance_6h)
    ):
        return None
    if not isinstance(generated_at, str) or not generated_at or len(generated_at) > 100:
        return None
    return {
        "chance_24h_pct": chance_24h,
        "chance_6h_pct": chance_6h,
        "generated_at": generated_at,
    }


def normalize_entry(snapshot: Any, *, include_forecast: bool = False) -> Entry:
    if not isinstance(snapshot, Mapping) or isinstance(snapshot, list):
        raise SnapshotValidationError("snapshot must be a JSON object")

    canonical_timestamp, epoch_microseconds = parse_timestamp(snapshot.get("scraped_at"))
    normalized: dict[str, Any] = {"scraped_at": canonical_timestamp}

    valid_percentage = False
    for field in PERCENTAGE_FIELDS:
        percentage = validate_percentage(field, snapshot.get(field))
        if field in snapshot:
            normalized[field] = percentage
        if percentage is not None:
            valid_percentage = True
    if not valid_percentage:
        raise SnapshotValidationError(
            "snapshot must contain at least one non-null usage percentage"
        )

    for field in RESET_LABEL_FIELDS:
        normalized[field] = sanitize_reset_label(snapshot.get(field))

    for field in RESET_EPOCH_FIELDS:
        if field in snapshot:
            normalized[field] = sanitize_optional_epoch(snapshot.get(field))

    if "sample_interval_seconds" in snapshot:
        interval = snapshot.get("sample_interval_seconds")
        if (
            not finite_number(interval)
            or not float(interval).is_integer()
            or not 1 <= float(interval) <= 86_400
        ):
            raise SnapshotValidationError(
                "sample_interval_seconds must be an integer from 1 to 86400"
            )
        normalized["sample_interval_seconds"] = int(interval)

    if "history_window_hours" in snapshot:
        window = snapshot.get("history_window_hours")
        if not finite_number(window) or not 0 <= float(window) <= 8_760:
            raise SnapshotValidationError(
                "history_window_hours must be a finite number from 0 to 8760"
            )
        normalized["history_window_hours"] = normal_number(window)

    limit_id = sanitize_limit_id(snapshot.get("limit_id"))
    if limit_id is not None:
        normalized["limit_id"] = limit_id

    if include_forecast:
        forecast = sanitize_forecast(snapshot.get("codex_forecast"))
        if forecast is not None:
            normalized["codex_forecast"] = forecast

    return Entry(normalized, epoch_microseconds)


def validate_snapshot(snapshot: Any, *, include_forecast: bool = False) -> dict[str, Any]:
    """Validate a snapshot and return its canonical public representation."""

    return dict(normalize_entry(snapshot, include_forecast=include_forecast).public)


def merge_entries(previous: Entry, current: Entry) -> Entry:
    merged = dict(previous.public)
    for field, value in current.public.items():
        if field == "scraped_at":
            merged[field] = value
        elif field in PERCENTAGE_FIELDS and value is None:
            continue
        else:
            merged[field] = value
    return Entry(merged, current.epoch_microseconds)


def deduplicate(entries: list[Entry]) -> list[Entry]:
    by_timestamp: dict[int, Entry] = {}
    for entry in entries:
        previous = by_timestamp.get(entry.epoch_microseconds)
        by_timestamp[entry.epoch_microseconds] = (
            entry if previous is None else merge_entries(previous, entry)
        )
    return sorted(
        by_timestamp.values(),
        key=lambda entry: entry.epoch_microseconds,
        reverse=True,
    )


def read_existing_history(path: Path) -> LoadedHistory:
    if not path.exists():
        return LoadedHistory([])
    try:
        if path.stat().st_size > MAX_HISTORY_BYTES:
            return LoadedHistory([], True, "history exceeds the 16 MiB input limit")
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return LoadedHistory([], True, f"history is not valid JSON: {exc}")
    if not isinstance(value, list):
        return LoadedHistory([], True, "history root is not a JSON array")

    valid_entries: list[Entry] = []
    invalid_count = 0
    for item in value:
        try:
            valid_entries.append(normalize_entry(item))
        except SnapshotValidationError:
            invalid_count += 1
    entries = deduplicate(valid_entries)
    if invalid_count:
        return LoadedHistory(
            entries,
            True,
            f"history contains {invalid_count} invalid snapshot(s)",
        )
    return LoadedHistory(entries)


def backup_corrupt_history(path: Path) -> Path:
    """Copy a corrupt history without ever overwriting an earlier backup."""

    for _ in range(8):
        backup = path.with_name(
            f"{path.name}.corrupt.{time.time_ns()}.{uuid.uuid4().hex}"
        )
        descriptor: int | None = None
        try:
            descriptor = os.open(
                backup,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with path.open("rb") as source, os.fdopen(descriptor, "wb") as destination:
                descriptor = None
                shutil.copyfileobj(source, destination)
                destination.flush()
                os.fsync(destination.fileno())
            return backup
        except FileExistsError:
            if descriptor is not None:
                os.close(descriptor)
            continue
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
            try:
                backup.unlink()
            except FileNotFoundError:
                pass
            raise
    raise HistoryError("could not choose a unique corrupt history backup name")


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        try:
            directory_descriptor = os.open(
                path.parent,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
        except OSError:
            directory_descriptor = None
        if directory_descriptor is not None:
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def serialize_history(entries: list[Entry]) -> bytes:
    try:
        return (
            json.dumps(
                [entry.public for entry in entries],
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"could not serialize history: {exc}") from exc


def serialize_snapshot(snapshot: Mapping[str, Any]) -> bytes:
    try:
        return (
            json.dumps(
                dict(snapshot),
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"could not serialize current snapshot: {exc}") from exc


def fitting_prefix(entries: list[Entry], maximum_bytes: int) -> int:
    if not entries:
        return 0
    if len(serialize_history(entries)) <= maximum_bytes:
        return len(entries)
    if len(serialize_history(entries[:1])) > maximum_bytes:
        raise HistoryError("one validated snapshot exceeds the 16 MiB history limit")

    low, high = 1, len(entries)
    while low < high:
        middle = (low + high + 1) // 2
        if len(serialize_history(entries[:middle])) <= maximum_bytes:
            low = middle
        else:
            high = middle - 1
    return low


def apply_defensive_limits(entries: list[Entry]) -> list[Entry]:
    limited = entries
    if len(limited) > MAX_HISTORY_ENTRIES:
        dropped = len(limited) - MAX_HISTORY_ENTRIES
        limited = limited[:MAX_HISTORY_ENTRIES]
        warn(
            f"The {MAX_HISTORY_ENTRIES}-entry defensive limit dropped "
            f"{dropped} older snapshot(s) and shortened the requested history window."
        )

    fitting_count = fitting_prefix(limited, MAX_HISTORY_BYTES)
    if fitting_count < len(limited):
        dropped = len(limited) - fitting_count
        limited = limited[:fitting_count]
        warn(
            f"The 16 MiB defensive limit dropped {dropped} older snapshot(s) "
            "and shortened the requested history window."
        )
    return limited


def parse_retention_hours(value: Any) -> float:
    if isinstance(value, bool):
        raise HistoryError("retention hours must be a finite number from 0.25 to 8760")
    try:
        retention = float(value)
    except (TypeError, ValueError) as exc:
        raise HistoryError("retention hours must be a finite number from 0.25 to 8760") from exc
    if not math.isfinite(retention) or not 0.25 <= retention <= 8_760:
        raise HistoryError("retention hours must be a finite number from 0.25 to 8760")
    return retention


def update_history(
    history_path: str | os.PathLike[str],
    data_path: str | os.PathLike[str],
    snapshot: Mapping[str, Any],
    retention_hours: Any,
    *,
    now_epoch: int | float | None = None,
) -> HistoryUpdate:
    """Validate, retain and atomically persist a public quota snapshot."""

    history_file = Path(history_path)
    data_file = Path(data_path)
    if history_file.resolve() == data_file.resolve():
        raise HistoryError("history and data paths must be different")
    retention = parse_retention_hours(retention_hours)
    incoming_history = normalize_entry(snapshot)
    incoming_data = normalize_entry(snapshot, include_forecast=True)

    if now_epoch is None:
        current_epoch = time.time()
    elif not finite_number(now_epoch) or float(now_epoch) < 0:
        raise HistoryError("now_epoch must be a finite non-negative epoch")
    else:
        current_epoch = float(now_epoch)

    loaded = read_existing_history(history_file)
    backup: Path | None = None
    if loaded.corrupt and history_file.exists():
        try:
            backup = backup_corrupt_history(history_file)
        except (OSError, HistoryError) as exc:
            raise HistoryError(
                f"could not back up corrupt history before reconstruction: {exc}"
            ) from exc
        warn(f"Corrupt history copied to {backup} before reconstruction: {loaded.reason}")

    existing_timestamps = {entry.epoch_microseconds for entry in loaded.entries}
    combined = deduplicate(loaded.entries + [incoming_history])
    cutoff_microseconds = int(round((current_epoch - retention * 3_600) * 1_000_000))
    retained = [
        entry for entry in combined if entry.epoch_microseconds >= cutoff_microseconds
    ]
    retained = apply_defensive_limits(retained)

    atomic_write(history_file, serialize_history(retained))

    current_data: Entry | None = None
    if data_file.exists():
        try:
            if data_file.stat().st_size > MAX_HISTORY_BYTES:
                raise SnapshotValidationError("data.json exceeds the 16 MiB input limit")
            current_value = json.loads(data_file.read_text(encoding="utf-8"))
            current_data = normalize_entry(current_value, include_forecast=True)
        except (OSError, UnicodeError, json.JSONDecodeError, SnapshotValidationError) as exc:
            warn(f"Current data snapshot is invalid and will be replaced: {exc}")

    merged_incoming = next(
        (
            entry
            for entry in retained
            if entry.epoch_microseconds == incoming_history.epoch_microseconds
        ),
        incoming_history,
    )
    data_public = dict(merged_incoming.public)
    forecast = incoming_data.public.get("codex_forecast")
    if forecast is not None:
        data_public["codex_forecast"] = forecast

    data_updated = False
    if (
        current_data is None
        or incoming_history.epoch_microseconds >= current_data.epoch_microseconds
    ):
        atomic_write(data_file, serialize_snapshot(data_public))
        data_updated = True
    else:
        warn("Older snapshot retained in history but did not replace data.json.")

    return HistoryUpdate(
        history=[dict(entry.public) for entry in retained],
        added=incoming_history.epoch_microseconds not in existing_timestamps,
        data_updated=data_updated,
        backup=backup,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and update the rolling public quota history."
    )
    parser.add_argument("--history", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--retention-hours", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            raise HistoryError("a JSON snapshot is required on stdin")
        snapshot = json.loads(raw)
        if not isinstance(snapshot, dict):
            raise SnapshotValidationError("snapshot must be a JSON object")
        result = update_history(
            args.history,
            args.data,
            snapshot,
            args.retention_hours,
        )
    except (HistoryError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        error(str(exc))
        return 1

    count = len(result.history)
    print(f"[OK] History updated: {count} entr{'y' if count == 1 else 'ies'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
