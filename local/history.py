#!/usr/bin/env python3
"""Manage the rolling public ``history.json`` file.

The file deliberately remains a JSON array of public snapshot objects.  The
collector currently writes ISO-8601 timestamps because that is the format used
by the dashboard and by the Gist consumer.  This module parses those values to
epoch microseconds before doing any temporal operation; numeric epoch values
are accepted as input as well and are written back as canonical UTC ISO-8601.

The module has no dependency on the monitor shell script.  It can therefore be
used by the monitor as a small command-line storage helper while keeping all
validation, recovery and size limiting in one place.
"""

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
import uuid
from dataclasses import dataclass
from typing import Any, Mapping


DEFAULT_RETENTION_HOURS = 192.0
MAX_ENTRIES = 10_000
MAX_BYTES = 16 * 1024 * 1024

# Descriptive aliases make the defensive limits easy to discover for callers.
MAX_HISTORY_ENTRIES = MAX_ENTRIES
MAX_HISTORY_BYTES = MAX_BYTES

_UTC = dt.timezone.utc
_EPOCH = dt.datetime(1970, 1, 1, tzinfo=_UTC)
_MAX_EPOCH_MICROSECONDS = (
    dt.datetime(9999, 12, 31, 23, 59, 59, 999999, tzinfo=_UTC) - _EPOCH
).days * 86_400_000_000 + (
    dt.datetime(9999, 12, 31, 23, 59, 59, 999999, tzinfo=_UTC) - _EPOCH
).seconds * 1_000_000 + (
    dt.datetime(9999, 12, 31, 23, 59, 59, 999999, tzinfo=_UTC) - _EPOCH
).microseconds

PUBLIC_FIELDS = (
    "five_h_pct",
    "five_h_reset",
    "five_h_reset_at",
    "weekly_pct",
    "weekly_reset",
    "weekly_reset_at",
    "scraped_at",
    "sample_interval_seconds",
    "history_window_hours",
    "limit_id",
)
PERCENTAGE_FIELDS = ("five_h_pct", "weekly_pct")
RESET_LABEL_FIELDS = ("five_h_reset", "weekly_reset")
RESET_EPOCH_FIELDS = ("five_h_reset_at", "weekly_reset_at")


class HistoryError(ValueError):
    """Base class for invalid history input or configuration."""


class SnapshotValidationError(HistoryError):
    """A snapshot does not satisfy the public history contract."""


class HistoryCorruptionError(HistoryError):
    """The existing history cannot be decoded or safely interpreted."""


@dataclass(frozen=True)
class _Entry:
    public: dict[str, Any]
    epoch_microseconds: int

    @property
    def epoch(self) -> float:
        return self.epoch_microseconds / 1_000_000


@dataclass(frozen=True)
class HistoryUpdate:
    """Details returned by :func:`update_history`."""

    history: list[dict[str, Any]]
    added: bool
    data_updated: bool
    backup: Path | None = None


@dataclass(frozen=True)
class _LoadedHistory:
    entries: list[_Entry]
    corrupt: bool = False
    reason: str = ""


def warn(message: str) -> None:
    """Emit a bounded, non-sensitive warning suitable for monitor logs."""

    print(f"[WARN] {message}", file=sys.stderr)


def error(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)


def _is_finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def _normal_number(value: float | int) -> int | float:
    numeric = float(value)
    return int(numeric) if numeric.is_integer() else numeric


def _epoch_microseconds_from_datetime(value: dt.datetime) -> int:
    value = value.astimezone(_UTC)
    delta = value - _EPOCH
    microseconds = (
        delta.days * 86_400_000_000
        + delta.seconds * 1_000_000
        + delta.microseconds
    )
    if not 0 <= microseconds <= _MAX_EPOCH_MICROSECONDS:
        raise SnapshotValidationError("scraped_at is outside the supported epoch range")
    return microseconds


def _epoch_microseconds(value: Any, *, field: str = "scraped_at") -> int:
    """Parse an ISO timestamp or a numeric Unix epoch to microseconds."""

    if _is_finite_number(value):
        numeric = float(value)
        if numeric < 0 or numeric > _MAX_EPOCH_MICROSECONDS / 1_000_000:
            raise SnapshotValidationError(f"{field} must be a non-negative Unix epoch")
        # JSON numbers have no promise of decimal precision.  Microseconds are
        # enough to distinguish real instants while avoiding float comparison
        # errors for offset-equivalent ISO strings.
        microseconds = int(round(numeric * 1_000_000))
        if microseconds > _MAX_EPOCH_MICROSECONDS:
            raise SnapshotValidationError(f"{field} is outside the supported epoch range")
        return microseconds

    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise SnapshotValidationError(f"{field} must be an ISO-8601 timestamp or epoch")

    raw = value.strip()
    # Accept a decimal epoch string for command-line integrations that cannot
    # preserve JSON number types.  Scientific notation is intentionally not
    # accepted: it is too easy to pass a configuration value by mistake.
    try:
        if raw.replace(".", "", 1).lstrip("+-").isdigit():
            numeric = float(raw)
            if numeric < 0 or numeric > _MAX_EPOCH_MICROSECONDS / 1_000_000:
                raise SnapshotValidationError(
                    f"{field} must be a non-negative Unix epoch"
                )
            microseconds = int(round(numeric * 1_000_000))
            if microseconds > _MAX_EPOCH_MICROSECONDS:
                raise SnapshotValidationError(
                    f"{field} is outside the supported epoch range"
                )
            return microseconds
    except ValueError:
        pass

    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError) as exc:
        raise SnapshotValidationError(f"{field} is not a valid timestamp") from exc

    # Existing monitor snapshots are always timezone-aware.  Treat a legacy
    # naive value as UTC rather than silently using the host's local timezone.
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_UTC)
    try:
        return _epoch_microseconds_from_datetime(parsed)
    except (OverflowError, ValueError) as exc:
        raise SnapshotValidationError(f"{field} is outside the supported epoch range") from exc


def timestamp_to_epoch(value: Any) -> int | float:
    """Return a validated timestamp as Unix epoch seconds.

    This public helper is intentionally strict and is useful to callers that
    need the same temporal interpretation as the history manager.
    """

    microseconds = _epoch_microseconds(value)
    seconds = microseconds / 1_000_000
    return int(seconds) if seconds.is_integer() else seconds


def _canonical_timestamp(microseconds: int) -> str:
    seconds, remainder = divmod(microseconds, 1_000_000)
    value = _EPOCH + dt.timedelta(seconds=seconds, microseconds=remainder)
    if remainder:
        return value.isoformat(timespec="microseconds").replace("+00:00", "Z")
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _validate_percentage(field: str, value: Any) -> int | float | None:
    if value is None:
        return None
    if not _is_finite_number(value) or not 0 <= float(value) <= 100:
        raise SnapshotValidationError(f"{field} must be a finite percentage from 0 to 100")
    return _normal_number(value)


def _validate_optional_epoch(field: str, value: Any) -> int | float | None:
    if value is None:
        return None
    if not _is_finite_number(value) or float(value) < 0:
        raise SnapshotValidationError(f"{field} must be a non-negative epoch or null")
    return _normal_number(value)


def _validate_label(field: str, value: Any) -> str | None:
    if value is None:
        return None
    if (
        not isinstance(value, str)
        or len(value) > 100
        or any(ord(character) < 32 for character in value)
    ):
        raise SnapshotValidationError(f"{field} must be a short text value or null")
    return value


def _validate_snapshot_entry(snapshot: Any) -> _Entry:
    if not isinstance(snapshot, Mapping) or isinstance(snapshot, list):
        raise SnapshotValidationError("snapshot must be a JSON object")

    timestamp_microseconds = _epoch_microseconds(snapshot.get("scraped_at"))
    normalized: dict[str, Any] = {
        "scraped_at": _canonical_timestamp(timestamp_microseconds),
    }

    for field in PERCENTAGE_FIELDS:
        normalized[field] = _validate_percentage(field, snapshot.get(field))
    if all(normalized[field] is None for field in PERCENTAGE_FIELDS):
        raise SnapshotValidationError(
            "snapshot must contain at least one non-null usage percentage"
        )

    for field in RESET_LABEL_FIELDS:
        normalized[field] = _validate_label(field, snapshot.get(field))
    for field in RESET_EPOCH_FIELDS:
        normalized[field] = _validate_optional_epoch(field, snapshot.get(field))

    interval = snapshot.get("sample_interval_seconds")
    if interval is None:
        normalized["sample_interval_seconds"] = None
    elif (
        not _is_finite_number(interval)
        or float(interval) <= 0
        or not float(interval).is_integer()
        or float(interval) > 86_400
    ):
        raise SnapshotValidationError(
            "sample_interval_seconds must be an integer from 1 to 86400 or null"
        )
    else:
        normalized["sample_interval_seconds"] = int(interval)

    window = snapshot.get("history_window_hours")
    if window is None:
        normalized["history_window_hours"] = None
    elif not _is_finite_number(window) or float(window) < 0 or float(window) > 8760:
        raise SnapshotValidationError(
            "history_window_hours must be a finite number from 0 to 8760 or null"
        )
    else:
        normalized["history_window_hours"] = _normal_number(window)

    normalized["limit_id"] = _validate_label("limit_id", snapshot.get("limit_id"))

    # Unknown input fields are deliberately not copied.  This keeps account
    # identifiers, tokens or future private collector details out of the public
    # history even when a caller hands the module a larger Codex response.
    return _Entry(normalized, timestamp_microseconds)


def validate_snapshot(snapshot: Any) -> dict[str, Any]:
    """Validate and normalize one public snapshot.

    The returned object contains only the public history fields.  Its
    ``scraped_at`` is a canonical UTC ISO string; use :func:`timestamp_to_epoch`
    when an epoch value is needed by a caller.
    """

    return dict(_validate_snapshot_entry(snapshot).public)


def normalize_snapshot(snapshot: Any) -> dict[str, Any]:
    """Compatibility alias for :func:`validate_snapshot`."""

    return validate_snapshot(snapshot)


def _entry_key(entry: _Entry) -> int:
    return entry.epoch_microseconds


def _merge_entries(previous: _Entry, current: _Entry) -> _Entry:
    """Merge same-instant snapshots without losing a valid partial window."""

    merged = dict(previous.public)
    for field, value in current.public.items():
        if field == "scraped_at":
            continue
        if field in PERCENTAGE_FIELDS and value is None:
            continue
        if value is not None:
            merged[field] = value
    return _Entry(merged, current.epoch_microseconds)


def _deduplicate(entries: list[_Entry]) -> list[_Entry]:
    by_timestamp: dict[int, _Entry] = {}
    for entry in entries:
        key = _entry_key(entry)
        previous = by_timestamp.get(key)
        by_timestamp[key] = entry if previous is None else _merge_entries(previous, entry)
    return sorted(by_timestamp.values(), key=_entry_key, reverse=True)


def _read_history(path: Path) -> _LoadedHistory:
    if not path.exists():
        return _LoadedHistory([])

    try:
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return _LoadedHistory([], True, f"history is not valid JSON: {exc}")

    if not isinstance(value, list):
        return _LoadedHistory([], True, "history root is not a JSON array")

    entries: list[_Entry] = []
    invalid = 0
    for item in value:
        try:
            entries.append(_validate_snapshot_entry(item))
        except SnapshotValidationError:
            invalid += 1

    if invalid:
        return _LoadedHistory(
            _deduplicate(entries),
            True,
            f"history contains {invalid} invalid snapshot(s)",
        )
    return _LoadedHistory(_deduplicate(entries))


def read_history(path: str | os.PathLike[str]) -> list[dict[str, Any]]:
    """Read valid entries from a history file without modifying it.

    Recovery and backups happen only as part of :func:`update_history`, where a
    new valid snapshot is available to reconstruct the file safely.
    """

    loaded = _read_history(Path(path))
    if loaded.corrupt:
        warn(loaded.reason)
    return [dict(entry.public) for entry in loaded.entries]


def _backup_corrupt_history(path: Path) -> Path:
    """Copy a corrupt history to a collision-resistant, never-overwritten name."""

    parent = path.parent
    for _ in range(8):
        candidate = parent / (
            f"{path.name}.corrupt.{time.time_ns()}.{uuid.uuid4().hex}"
        )
        try:
            source = path.open("rb")
            try:
                descriptor = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                )
                try:
                    with os.fdopen(descriptor, "wb") as destination:
                        shutil.copyfileobj(source, destination)
                        destination.flush()
                        os.fsync(destination.fileno())
                except BaseException:
                    # fdopen owns the descriptor after it succeeds; if it did
                    # not, closing an already closed descriptor is harmlessly
                    # avoided by the surrounding cleanup below.
                    raise
            finally:
                source.close()
            return candidate
        except FileExistsError:
            continue
        except BaseException:
            try:
                candidate.unlink()
            except FileNotFoundError:
                pass
            raise
    raise HistoryError("could not choose a unique backup name for corrupt history")


def backup_corrupt_history(path: str | os.PathLike[str]) -> Path:
    """Public wrapper used by recovery tooling and tests."""

    return _backup_corrupt_history(Path(path))


def _atomic_write(path: Path, content: bytes) -> None:
    """Replace a file atomically after flushing its contents to disk."""

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
            directory_descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
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


def atomic_write(path: str | os.PathLike[str], content: bytes | str) -> None:
    """Public atomic-write helper."""

    if isinstance(content, str):
        content = content.encode("utf-8")
    _atomic_write(Path(path), content)


def _serialize(entries: list[_Entry]) -> bytes:
    payload = [entry.public for entry in entries]
    try:
        text = json.dumps(
            payload,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        ) + "\n"
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"could not serialize history: {exc}") from exc
    return text.encode("utf-8")


def _serialize_snapshot(entry: _Entry) -> bytes:
    try:
        text = json.dumps(
            entry.public,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        ) + "\n"
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"could not serialize data snapshot: {exc}") from exc
    return text.encode("utf-8")


def _largest_fitting_prefix(entries: list[_Entry], maximum_bytes: int) -> int:
    if not entries:
        return 0
    if len(_serialize(entries)) <= maximum_bytes:
        return len(entries)

    low, high = 1, len(entries)
    if len(_serialize(entries[:1])) > maximum_bytes:
        raise HistoryError("a validated snapshot is larger than the 16 MiB history limit")
    while low < high:
        middle = (low + high + 1) // 2
        if len(_serialize(entries[:middle])) <= maximum_bytes:
            low = middle
        else:
            high = middle - 1
    return low


def _retention_hours(value: Any) -> float:
    if value is None:
        value = os.environ.get("HISTORY_RETENTION_HOURS", DEFAULT_RETENTION_HOURS)
    if isinstance(value, bool):
        raise HistoryError("retention hours must be a finite non-negative number")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise HistoryError("retention hours must be a finite non-negative number") from exc
    if not math.isfinite(result) or result < 0:
        raise HistoryError("retention hours must be a finite non-negative number")
    return result


def _now_epoch(value: Any) -> float:
    if value is None:
        return time.time()
    if not _is_finite_number(value) or float(value) < 0:
        raise HistoryError("now must be a finite non-negative epoch")
    return float(value)


def _covered_hours(entries: list[_Entry], anchor_epoch: float) -> float:
    if not entries:
        return 0.0
    return max(0.0, (anchor_epoch - entries[-1].epoch) / 3600)


def _format_hours(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".")


def _warn_limit(
    label: str,
    before: list[_Entry],
    after: list[_Entry],
    anchor_epoch: float,
    requested_hours: float,
) -> None:
    if len(after) >= len(before) or not after:
        return
    before_hours = min(requested_hours, _covered_hours(before, anchor_epoch))
    after_hours = _covered_hours(after, anchor_epoch)
    warn(
        f"{label} shortened the requested { _format_hours(requested_hours) }h "
        f"history window to about {_format_hours(after_hours)}h "
        f"({len(before) - len(after)} older entr{'y' if len(before) - len(after) == 1 else 'ies'} dropped; "
        f"available window was about {_format_hours(before_hours)}h)."
    )


def _apply_limits(
    entries: list[_Entry],
    *,
    anchor_epoch: float,
    requested_hours: float,
) -> list[_Entry]:
    limited = entries
    if len(limited) > MAX_ENTRIES:
        by_count = limited[:MAX_ENTRIES]
        _warn_limit(
            f"the {MAX_ENTRIES}-entry defensive limit",
            limited,
            by_count,
            anchor_epoch,
            requested_hours,
        )
        limited = by_count

    fitting_count = _largest_fitting_prefix(limited, MAX_BYTES)
    if fitting_count < len(limited):
        by_size = limited[:fitting_count]
        _warn_limit(
            "the 16 MiB defensive limit",
            limited,
            by_size,
            anchor_epoch,
            requested_hours,
        )
        limited = by_size
    return limited


def update_history(
    history_path: str | os.PathLike[str],
    snapshot: Mapping[str, Any],
    *,
    data_path: str | os.PathLike[str] | None = None,
    retention_hours: Any = None,
    now: Any = None,
) -> HistoryUpdate:
    """Validate, merge, retain and atomically write one snapshot.

    ``history_path`` is always updated.  When ``data_path`` is provided, it is
    replaced only when it is absent, invalid, or older than the incoming real
    instant.  An older snapshot still remains in the rolling history.
    """

    history_file = Path(history_path)
    data_file = Path(data_path) if data_path is not None else None
    if data_file is not None and history_file.resolve() == data_file.resolve():
        raise HistoryError("--history and --data must refer to different files")
    requested_hours = _retention_hours(retention_hours)
    incoming = _validate_snapshot_entry(snapshot)
    current_epoch = _now_epoch(now)

    loaded = _read_history(history_file)
    backup: Path | None = None
    if loaded.corrupt:
        if history_file.exists():
            try:
                backup = _backup_corrupt_history(history_file)
            except OSError as exc:
                raise HistoryError(
                    f"could not back up corrupt history before reconstruction: {exc}"
                ) from exc
            warn(f"Corrupt history copied to {backup} before reconstruction: {loaded.reason}")
        entries = loaded.entries
    else:
        entries = loaded.entries

    before_keys = {_entry_key(entry) for entry in entries}
    combined = _deduplicate(entries + [incoming])
    incoming_key = _entry_key(incoming)
    added = incoming_key not in before_keys

    anchor_epoch = max(
        current_epoch,
        max((entry.epoch for entry in combined), default=current_epoch),
    )
    cutoff = anchor_epoch - requested_hours * 3600
    retained = [entry for entry in combined if entry.epoch >= cutoff]
    retained = _apply_limits(
        retained,
        anchor_epoch=anchor_epoch,
        requested_hours=requested_hours,
    )
    _atomic_write(history_file, _serialize(retained))

    data_updated = False
    if data_file is not None:
        current: _Entry | None = None
        if data_file.exists():
            try:
                current = _validate_snapshot_entry(
                    json.loads(data_file.read_text(encoding="utf-8"))
                )
            except (OSError, UnicodeError, json.JSONDecodeError, SnapshotValidationError) as exc:
                warn(f"Current data snapshot is invalid and will be replaced: {exc}")

        selected = next(
            (entry for entry in retained if _entry_key(entry) == incoming_key),
            incoming,
        )
        if current is None or _entry_key(selected) >= _entry_key(current):
            _atomic_write(data_file, _serialize_snapshot(selected))
            data_updated = True
        else:
            warn("Older snapshot retained in history but did not replace data.json.")

    return HistoryUpdate(
        history=[dict(entry.public) for entry in retained],
        added=added,
        data_updated=data_updated,
        backup=backup,
    )


def _load_snapshot_argument(args: argparse.Namespace) -> Any:
    if args.snapshot is not None and args.snapshot_file is not None:
        raise HistoryError("--snapshot and --snapshot-file are mutually exclusive")

    if args.snapshot_file is not None:
        try:
            raw = Path(args.snapshot_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise HistoryError(f"could not read snapshot file: {exc}") from exc
    elif args.snapshot is not None:
        raw = sys.stdin.read() if args.snapshot == "-" else args.snapshot
        if raw.startswith("@") and len(raw) > 1:
            try:
                raw = Path(raw[1:]).read_text(encoding="utf-8")
            except OSError as exc:
                raise HistoryError(f"could not read snapshot file: {exc}") from exc
    else:
        raw = sys.stdin.read()

    if not raw.strip():
        raise HistoryError("a JSON snapshot is required via --snapshot or stdin")
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise HistoryError(f"snapshot is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise SnapshotValidationError("snapshot must be a JSON object")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and atomically update the rolling history.json array."
    )
    parser.add_argument("--history", required=True, type=Path, help="history.json path")
    parser.add_argument("--data", type=Path, help="optional current data.json path")
    parser.add_argument(
        "--snapshot",
        help="snapshot JSON object; '-' reads stdin (default is stdin)",
    )
    parser.add_argument("--snapshot-file", type=Path, help="read the snapshot JSON object from a file")
    parser.add_argument(
        "--retention-hours",
        type=float,
        default=None,
        help="age-based rolling retention (default: HISTORY_RETENTION_HOURS or 192)",
    )
    parser.add_argument(
        "--now",
        type=float,
        default=None,
        help="override the current epoch for deterministic maintenance/tests",
    )
    parser.add_argument(
        "--print-history",
        action="store_true",
        help="print the resulting public JSON array to stdout",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        snapshot = _load_snapshot_argument(args)
        result = update_history(
            args.history,
            snapshot,
            data_path=args.data,
            retention_hours=args.retention_hours,
            now=args.now,
        )
    except (HistoryError, OSError, TypeError, ValueError) as exc:
        error(str(exc))
        return 2

    if args.print_history:
        print(json.dumps(result.history, ensure_ascii=False, indent=2) + "\n", end="")
    else:
        print(f"[OK] History updated: {len(result.history)} entr{'y' if len(result.history) == 1 else 'ies'}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
