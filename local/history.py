#!/usr/bin/env python3
"""Validate and atomically update the rolling JSON usage history.

The JSON files deliberately contain only the public snapshot fields.  Epoch
timestamps are kept in :class:`ParsedSnapshot` and are never serialized.
"""

from __future__ import annotations

import argparse
import datetime as datetime_module
import json
import heapq
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union


MAX_ENTRIES = 10_000
MAX_BYTES = 16 * 1024 * 1024
STREAM_CHUNK_BYTES = 256 * 1024
MAX_ENTRY_BUFFER_BYTES = 2 * 1024 * 1024
MAX_DATA_READ_BYTES = MAX_ENTRY_BUFFER_BYTES
DEFAULT_RETENTION_HOURS = 192.0
FUTURE_TIMESTAMP_TOLERANCE_SECONDS = 5 * 60

PUBLIC_FIELDS = (
    "five_h_pct",
    "five_h_reset",
    "five_h_reset_at",
    "weekly_pct",
    "weekly_reset",
    "weekly_reset_at",
    "limit_id",
    "scraped_at",
    "sample_interval_seconds",
    "history_window_hours",
)
PERCENTAGE_FIELDS = ("five_h_pct", "weekly_pct")
RESET_TEXT_FIELDS = ("five_h_reset", "weekly_reset")
RESET_AT_FIELDS = ("five_h_reset_at", "weekly_reset_at")


class HistoryError(Exception):
    """Base class for errors that can be shown directly by the CLI."""


class SnapshotValidationError(HistoryError, ValueError):
    """The input snapshot does not satisfy the public contract."""


class HistoryStorageError(HistoryError, OSError):
    """A history or data path cannot be safely read or written."""


@dataclass(frozen=True)
class ParsedSnapshot:
    """A validated public snapshot plus its non-public real-time key."""

    public: Dict[str, Any]
    epoch: float


@dataclass
class UpdateResult:
    """Result of one history update."""

    history: List[Dict[str, Any]]
    data: Dict[str, Any]
    data_updated: bool
    warnings: List[str]
    backup_path: Optional[Path]


@dataclass
class _LoadedHistory:
    entries: List[ParsedSnapshot]
    source_exists: bool
    corrupt: bool
    reason: Optional[str]
    omitted_entries: int = 0


def _reject_json_constant(value: str) -> None:
    raise ValueError("non-finite JSON number is not allowed: " + value)


def _object_pairs_without_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key: " + key)
        result[key] = value
    return result


def _loads(text: str) -> Any:
    return json.loads(
        text,
        object_pairs_hook=_object_pairs_without_duplicates,
        parse_constant=_reject_json_constant,
    )


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_finite_number(value: Any) -> bool:
    if not _is_number(value):
        return False
    if isinstance(value, int):
        return True
    return math.isfinite(value)


def _normalized_number(value: Union[int, float]) -> Union[int, float]:
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def parse_scraped_at(value: Any) -> Tuple[str, float]:
    """Return a public ISO timestamp and its UTC epoch.

    A timestamp without an offset is interpreted as UTC and emitted with an
    explicit ``Z`` so that it cannot later be interpreted in local time.
    """

    if not isinstance(value, str) or not value or len(value) > 128:
        raise SnapshotValidationError("scraped_at must be an ISO-8601 timestamp")
    if "T" not in value and "t" not in value and " " not in value:
        raise SnapshotValidationError("scraped_at must include a time")
    if value.endswith("z"):
        raise SnapshotValidationError("scraped_at must use uppercase Z for UTC")

    parse_value = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime_module.datetime.fromisoformat(parse_value)
        if parsed.tzinfo is not None and parsed.utcoffset() is None:
            raise ValueError("timestamp has no usable UTC offset")
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime_module.timezone.utc)
            public_value = parsed.isoformat().replace("+00:00", "Z")
        else:
            public_value = value
        epoch = float(parsed.timestamp())
    except (TypeError, ValueError, OverflowError, OSError) as exc:
        raise SnapshotValidationError("scraped_at must be a valid ISO-8601 timestamp") from exc
    if not math.isfinite(epoch):
        raise SnapshotValidationError("scraped_at epoch must be finite")
    return public_value, epoch


def _optional_percentage(value: Any, field: str) -> Optional[Union[int, float]]:
    if value is None:
        return None
    if not _is_finite_number(value) or not 0 <= value <= 100:
        raise SnapshotValidationError(
            f"{field} must be a finite number between 0 and 100 or null"
        )
    return _normalized_number(value)


def _optional_text(value: Any, field: str) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 100:
        raise SnapshotValidationError(f"{field} must be a short string or null")
    if any(ord(character) < 32 for character in value):
        raise SnapshotValidationError(f"{field} must not contain control characters")
    return value


def _optional_positive_number(value: Any, field: str) -> Optional[Union[int, float]]:
    if value is None:
        return None
    if not _is_finite_number(value) or value <= 0:
        raise SnapshotValidationError(f"{field} must be a finite positive number or null")
    return _normalized_number(value)


def _optional_nonnegative_number(value: Any, field: str) -> Optional[Union[int, float]]:
    if value is None:
        return None
    if not _is_finite_number(value) or value < 0:
        raise SnapshotValidationError(f"{field} must be a finite non-negative number or null")
    return _normalized_number(value)


def parse_snapshot(value: Any) -> ParsedSnapshot:
    """Strictly validate and normalize one public snapshot.

    ``scraped_at`` and at least one usage percentage are required.  The other
    current public fields are optional to support the partial limit response;
    missing fields are emitted as ``null`` rather than invented values.
    """

    if not isinstance(value, dict):
        raise SnapshotValidationError("snapshot must be a JSON object")

    unknown_fields = sorted(set(value) - set(PUBLIC_FIELDS))
    if unknown_fields:
        raise SnapshotValidationError(
            "snapshot contains unsupported fields: " + ", ".join(unknown_fields)
        )
    if "scraped_at" not in value:
        raise SnapshotValidationError("snapshot is missing scraped_at")

    public_scraped_at, epoch = parse_scraped_at(value["scraped_at"])
    percentages = {
        field: _optional_percentage(value.get(field), field)
        for field in PERCENTAGE_FIELDS
    }
    if all(percentages[field] is None for field in PERCENTAGE_FIELDS):
        raise SnapshotValidationError("snapshot must contain at least one usage percentage")

    public: Dict[str, Any] = {}
    for field in PUBLIC_FIELDS:
        if field in percentages:
            public[field] = percentages[field]
        elif field == "scraped_at":
            public[field] = public_scraped_at
        elif field in RESET_TEXT_FIELDS:
            public[field] = _optional_text(value.get(field), field)
        elif field in RESET_AT_FIELDS:
            public[field] = _optional_positive_number(value.get(field), field)
        elif field == "sample_interval_seconds":
            public[field] = _optional_positive_number(value.get(field), field)
        elif field == "history_window_hours":
            public[field] = _optional_nonnegative_number(value.get(field), field)
        elif field == "limit_id":
            public[field] = _optional_text(value.get(field), field)
        else:
            raise AssertionError("unhandled public field: " + field)
    return ParsedSnapshot(public=public, epoch=epoch)


def validate_snapshot(value: Any) -> Dict[str, Any]:
    """Validate a snapshot and return only its public JSON fields."""

    return dict(parse_snapshot(value).public)


def normalize_snapshot(value: Any) -> Dict[str, Any]:
    """Compatibility spelling for callers that expect a normalizer."""

    return validate_snapshot(value)


def parse_retention_hours(value: Union[str, int, float]) -> float:
    """Parse a finite, non-negative retention duration in hours."""

    if isinstance(value, bool):
        raise HistoryError("retention hours must be a finite non-negative number")
    try:
        hours = float(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise HistoryError("retention hours must be a finite non-negative number") from exc
    if not math.isfinite(hours) or hours < 0:
        raise HistoryError("retention hours must be a finite non-negative number")
    try:
        seconds = hours * 60 * 60
    except OverflowError as exc:
        raise HistoryError("retention hours is too large") from exc
    if not math.isfinite(seconds):
        raise HistoryError("retention hours is too large")
    return hours


def _coerce_now(value: Optional[Union[int, float, datetime_module.datetime]]) -> float:
    if value is None:
        result = time.time()
    elif isinstance(value, datetime_module.datetime):
        parsed = value
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime_module.timezone.utc)
        result = parsed.timestamp()
    else:
        result = value
    if not _is_finite_number(result):
        raise HistoryError("retention anchor must be a finite epoch")
    return float(result)


def _absolute_path(value: Union[str, os.PathLike[str]]) -> Path:
    try:
        path = Path(value)
    except (TypeError, ValueError) as exc:
        raise HistoryStorageError("path is invalid") from exc
    if not path.is_absolute():
        path = Path.cwd() / path
    return path


def _check_parent_components(path: Path) -> None:
    """Reject missing, non-directory, or symlinked parent components."""

    absolute = Path(os.path.abspath(os.fspath(path)))
    parts = absolute.parts
    current = Path(parts[0])
    for component in parts[1:-1]:
        current = current / component
        try:
            component_stat = os.lstat(os.fspath(current))
        except FileNotFoundError as exc:
            raise HistoryStorageError(f"parent directory does not exist: {current}") from exc
        except OSError as exc:
            raise HistoryStorageError(f"cannot inspect parent directory {current}: {exc}") from exc
        if stat.S_ISLNK(component_stat.st_mode):
            raise HistoryStorageError(f"path component must not be a symbolic link: {current}")
        if not stat.S_ISDIR(component_stat.st_mode):
            raise HistoryStorageError(f"parent component is not a directory: {current}")

    try:
        parent_stat = os.lstat(os.fspath(absolute.parent))
    except FileNotFoundError as exc:
        raise HistoryStorageError(f"parent directory does not exist: {absolute.parent}") from exc
    except OSError as exc:
        raise HistoryStorageError(f"cannot inspect parent directory {absolute.parent}: {exc}") from exc
    if stat.S_ISLNK(parent_stat.st_mode):
        raise HistoryStorageError(f"parent directory must not be a symbolic link: {absolute.parent}")
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise HistoryStorageError(f"parent is not a directory: {absolute.parent}")


def _check_target(path: Path) -> bool:
    _check_parent_components(path)
    try:
        target_stat = os.lstat(os.fspath(path))
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise HistoryStorageError(f"cannot inspect {path}: {exc}") from exc
    if stat.S_ISLNK(target_stat.st_mode):
        raise HistoryStorageError(f"path must not be a symbolic link: {path}")
    if not stat.S_ISREG(target_stat.st_mode):
        raise HistoryStorageError(f"path must be a regular file: {path}")
    return True


def _prepare_paths(history_path: Union[str, os.PathLike[str]], data_path: Union[str, os.PathLike[str]]) -> Tuple[Path, Path]:
    history = _absolute_path(history_path)
    data = _absolute_path(data_path)
    _check_target(history)
    _check_target(data)
    if history == data:
        raise HistoryStorageError("history and data paths must be different files")
    try:
        same_file = history.exists() and data.exists() and os.path.samefile(history, data)
    except OSError:
        same_file = False
    if same_file:
        raise HistoryStorageError("history and data paths must be different files")
    return history, data


def _open_regular_for_read(path: Path) -> Optional[int]:
    if not _check_target(path):
        return None
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(os.fspath(path), flags)
    except OSError as exc:
        raise HistoryStorageError(f"cannot read {path}: {exc}") from exc
    try:
        descriptor_stat = os.fstat(descriptor)
        if not stat.S_ISREG(descriptor_stat.st_mode):
            raise HistoryStorageError(f"path must be a regular file: {path}")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _read_regular(path: Path, max_bytes: int = MAX_DATA_READ_BYTES) -> Optional[bytes]:
    descriptor = _open_regular_for_read(path)
    if descriptor is None:
        return None
    chunks: List[bytes] = []
    total = 0
    try:
        while True:
            chunk = os.read(descriptor, STREAM_CHUNK_BYTES)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise HistoryStorageError(
                    f"{path} exceeds defensive read limit {max_bytes} bytes"
                )
    except OSError as exc:
        raise HistoryStorageError(f"cannot read {path}: {exc}") from exc
    finally:
        os.close(descriptor)
    return b"".join(chunks)


def _decode_json(raw: bytes, path_description: str) -> Any:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise HistoryError(f"{path_description} is not valid UTF-8") from exc
    try:
        return _loads(text)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise HistoryError(f"{path_description} contains invalid JSON: {exc}") from exc


def _iter_json_array(path: Path, *, allow_empty_file: bool = False):
    """Decode one JSON array incrementally while bounding any single value."""

    descriptor = _open_regular_for_read(path)
    if descriptor is None:
        return
    decoder = json.JSONDecoder(
        object_pairs_hook=_object_pairs_without_duplicates,
        parse_constant=_reject_json_constant,
    )
    buffer = ""
    state = "start"
    done = False
    try:
        with os.fdopen(descriptor, "r", encoding="utf-8") as source:
            descriptor = -1
            while True:
                chunk = source.read(STREAM_CHUNK_BYTES)
                eof = chunk == ""
                buffer += chunk
                while True:
                    buffer = buffer.lstrip()
                    if state == "start":
                        if not buffer:
                            break
                        if buffer[0] != "[":
                            raise HistoryError("history root must be a JSON array")
                        buffer = buffer[1:]
                        state = "value_or_end"
                        continue
                    if state in ("value", "value_or_end"):
                        if not buffer:
                            break
                        if state == "value_or_end" and buffer[0] == "]":
                            buffer = buffer[1:]
                            state = "trailing"
                            done = True
                            continue
                        try:
                            value, end = decoder.raw_decode(buffer)
                        except (TypeError, ValueError, json.JSONDecodeError) as exc:
                            if not eof:
                                if len(buffer) > MAX_ENTRY_BUFFER_BYTES:
                                    raise HistoryError(
                                        "history entry exceeds the bounded streaming decode limit"
                                    ) from exc
                                break
                            raise HistoryError(f"history file contains invalid JSON: {exc}") from exc
                        yield value
                        buffer = buffer[end:]
                        state = "delimiter"
                        continue
                    if state == "delimiter":
                        if not buffer:
                            break
                        if buffer[0] == ",":
                            buffer = buffer[1:]
                            state = "value"
                            continue
                        if buffer[0] == "]":
                            buffer = buffer[1:]
                            state = "trailing"
                            done = True
                            continue
                        raise HistoryError("history file contains invalid JSON array delimiters")
                    if state == "trailing":
                        if buffer:
                            raise HistoryError("history file contains trailing data")
                        break
                if eof:
                    break
            if not done:
                if state == "start" and not buffer:
                    if allow_empty_file:
                        return
                    raise HistoryError("history file is empty")
                raise HistoryError("history file contains an incomplete JSON array")
    except UnicodeDecodeError as exc:
        raise HistoryError("history file is not valid UTF-8") from exc
    except OSError as exc:
        raise HistoryStorageError(f"cannot read {path}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def iter_validated_history(
    path: Union[str, os.PathLike[str]], *, future_anchor: Optional[float] = None
):
    """Yield every strictly validated history entry from a bounded stream."""

    history_path = _absolute_path(path)
    if not _check_target(history_path):
        return
    for index, item in enumerate(_iter_json_array(history_path)):
        try:
            entry = parse_snapshot(item)
        except SnapshotValidationError as exc:
            raise HistoryError(f"history entry {index} is invalid: {exc}") from exc
        if (
            future_anchor is not None
            and entry.epoch > future_anchor + FUTURE_TIMESTAMP_TOLERANCE_SECONDS
        ):
            raise HistoryError(
                f"history entry {index} exceeds the future timestamp tolerance"
            )
        yield entry


def _load_history(path: Path) -> _LoadedHistory:
    if not _check_target(path):
        return _LoadedHistory(entries=[], source_exists=False, corrupt=False, reason=None)
    try:
        if path.stat().st_size == 0:
            return _LoadedHistory(entries=[], source_exists=True, corrupt=False, reason=None)
    except OSError as exc:
        raise HistoryStorageError(f"cannot inspect history file {path}: {exc}") from exc

    newest: List[Tuple[float, int, ParsedSnapshot]] = []
    invalid_reason: Optional[str] = None
    omitted = 0
    try:
        for index, item in enumerate(_iter_json_array(path, allow_empty_file=True)):
            try:
                entry = parse_snapshot(item)
            except SnapshotValidationError as exc:
                if invalid_reason is None:
                    invalid_reason = f"entry {index} is invalid: {exc}"
                continue
            candidate = (entry.epoch, index, entry)
            if len(newest) < MAX_ENTRIES:
                heapq.heappush(newest, candidate)
            elif candidate[:2] > newest[0][:2]:
                heapq.heapreplace(newest, candidate)
                omitted += 1
            else:
                omitted += 1
    except HistoryError as exc:
        return _LoadedHistory(
            entries=[item[2] for item in newest],
            source_exists=True,
            corrupt=True,
            reason=str(exc),
            omitted_entries=omitted,
        )
    return _LoadedHistory(
        entries=[item[2] for item in newest],
        source_exists=True,
        corrupt=invalid_reason is not None,
        reason=invalid_reason,
        omitted_entries=omitted,
    )


def _load_data(path: Path) -> Tuple[Optional[ParsedSnapshot], Optional[str]]:
    raw = _read_regular(path)
    if raw is None:
        return None, None
    if not raw.strip():
        return None, "data file is empty and will be replaced"
    try:
        value = _decode_json(raw, "data file")
    except HistoryError as exc:
        return None, str(exc) + "; it will be replaced"
    try:
        return parse_snapshot(value), None
    except SnapshotValidationError as exc:
        return None, f"data file is invalid: {exc}; it will be replaced"


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def _fsync_directory(directory: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(os.fspath(directory), flags)
    except OSError as exc:
        raise HistoryStorageError(f"cannot open directory for fsync {directory}: {exc}") from exc
    try:
        os.fsync(descriptor)
    except OSError as exc:
        raise HistoryStorageError(f"cannot fsync directory {directory}: {exc}") from exc
    finally:
        os.close(descriptor)


def _atomic_write(path: Path, content: bytes) -> None:
    _check_target(path)
    descriptor: Optional[int] = None
    temporary_path: Optional[str] = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(
            prefix="." + path.name + ".",
            suffix=".tmp",
            dir=os.fspath(path.parent),
        )
        os.fchmod(descriptor, 0o600)
        _write_all(descriptor, content)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None

        # Do not silently replace a target that became unsafe while preparing
        # the temporary file.  os.replace itself never follows the target.
        _check_target(path)
        os.replace(temporary_path, os.fspath(path))
        temporary_path = None
        _fsync_directory(path.parent)
    except HistoryStorageError:
        raise
    except OSError as exc:
        raise HistoryStorageError(f"atomic write failed for {path}: {exc}") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


def _backup_corrupt_history(path: Path) -> Path:
    """Copy corrupt bytes to a never-overwritten, mode-0600 sibling."""

    prefix = f"{path.name}.corrupt.{time.time_ns()}"
    for suffix in range(10_000):
        name = prefix if suffix == 0 else f"{prefix}.{suffix}"
        candidate = path.with_name(name)
        descriptor: Optional[int] = None
        completed = False
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(os.fspath(candidate), flags, 0o600)
        except FileExistsError:
            continue
        except OSError as exc:
            raise HistoryStorageError(f"cannot create exclusive history backup: {exc}") from exc

        try:
            os.fchmod(descriptor, 0o600)
            source = _open_regular_for_read(path)
            if source is None:
                raise HistoryStorageError("corrupt history disappeared before backup")
            try:
                while chunk := os.read(source, STREAM_CHUNK_BYTES):
                    _write_all(descriptor, chunk)
            finally:
                os.close(source)
            os.fsync(descriptor)
            completed = True
        except OSError as exc:
            raise HistoryStorageError(f"cannot write history backup {candidate}: {exc}") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if not completed:
                try:
                    os.unlink(candidate)
                except FileNotFoundError:
                    pass
        _fsync_directory(path.parent)
        return candidate
    raise HistoryStorageError("could not find a unique name for the corrupt history backup")


def _serialize_history(entries: Sequence[ParsedSnapshot]) -> bytes:
    value = [entry.public for entry in entries]
    try:
        text = json.dumps(value, ensure_ascii=True, allow_nan=False, indent=2) + "\n"
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"history cannot be serialized: {exc}") from exc
    return text.encode("utf-8")


def _serialize_snapshot(snapshot: ParsedSnapshot) -> bytes:
    try:
        text = json.dumps(snapshot.public, ensure_ascii=True, allow_nan=False, indent=2) + "\n"
    except (TypeError, ValueError) as exc:
        raise HistoryError(f"snapshot cannot be serialized: {exc}") from exc
    return text.encode("utf-8")


def _apply_defensive_limits(
    entries: List[ParsedSnapshot], warnings: List[str]
) -> Tuple[List[ParsedSnapshot], bytes]:
    if len(entries) > MAX_ENTRIES:
        removed = len(entries) - MAX_ENTRIES
        entries = entries[:MAX_ENTRIES]
        warnings.append(
            f"MAX_ENTRIES={MAX_ENTRIES} defensively shortened the requested retention window "
            f"by removing {removed} entries"
        )

    encoded = _serialize_history(entries)
    if len(encoded) <= MAX_BYTES:
        return entries, encoded

    original_count = len(entries)
    low = 0
    high = len(entries)
    while low < high:
        middle = (low + high + 1) // 2
        if len(_serialize_history(entries[:middle])) <= MAX_BYTES:
            low = middle
        else:
            high = middle - 1
    if low == 0:
        raise HistoryStorageError(
            f"a single snapshot exceeds defensive MAX_BYTES={MAX_BYTES}"
        )
    entries = entries[:low]
    encoded = _serialize_history(entries)
    warnings.append(
        f"MAX_BYTES={MAX_BYTES} defensively shortened the requested retention window "
        f"by removing {original_count - len(entries)} entries"
    )
    return entries, encoded


def _merge_and_retain(
    old_entries: Sequence[ParsedSnapshot],
    new_entry: ParsedSnapshot,
    retention_hours: float,
    now: float,
    warnings: List[str],
) -> List[ParsedSnapshot]:
    by_epoch: Dict[float, ParsedSnapshot] = {}
    for entry in old_entries:
        if entry.epoch > now + FUTURE_TIMESTAMP_TOLERANCE_SECONDS:
            raise HistoryStorageError(
                "existing history contains timestamps beyond the future tolerance; "
                "refusing to discard data after a possible clock rollback"
            )
        by_epoch[entry.epoch] = entry
    # The current collection wins when two representations describe the same
    # instant, including timestamps with different offsets.
    by_epoch[new_entry.epoch] = new_entry

    cutoff = now - retention_hours * 60 * 60
    retained = [entry for entry in by_epoch.values() if entry.epoch >= cutoff]
    retained.sort(key=lambda entry: entry.epoch, reverse=True)
    return retained


def update_history(
    history_path: Union[str, os.PathLike[str]],
    data_path: Union[str, os.PathLike[str]],
    snapshot: Any,
    retention_hours: Union[str, int, float],
    *,
    now: Optional[Union[int, float, datetime_module.datetime]] = None,
) -> UpdateResult:
    """Validate and persist one snapshot in both public JSON files."""

    new_entry = snapshot if isinstance(snapshot, ParsedSnapshot) else parse_snapshot(snapshot)
    retention = parse_retention_hours(retention_hours)
    anchor = _coerce_now(now)
    if new_entry.epoch > anchor + FUTURE_TIMESTAMP_TOLERANCE_SECONDS:
        raise SnapshotValidationError(
            "scraped_at exceeds the 300-second future timestamp tolerance"
        )
    history, data = _prepare_paths(history_path, data_path)

    loaded_history = _load_history(history)
    warnings: List[str] = []
    backup_path: Optional[Path] = None
    if loaded_history.corrupt:
        backup_path = _backup_corrupt_history(history)
        reason = loaded_history.reason or "invalid history"
        warnings.append(
            f"corrupt history backed up to {backup_path.name} before reconstruction: {reason}"
        )
    if loaded_history.omitted_entries:
        warnings.append(
            f"MAX_ENTRIES={MAX_ENTRIES} bounded history loading by omitting "
            f"{loaded_history.omitted_entries} older entries"
        )

    current_data, data_warning = _load_data(data)
    if data_warning:
        warnings.append(data_warning)
    if (
        current_data is not None
        and current_data.epoch > anchor + FUTURE_TIMESTAMP_TOLERANCE_SECONDS
    ):
        raise HistoryStorageError(
            "data file timestamp is beyond the future tolerance; refusing to overwrite "
            "data after a possible clock rollback"
        )

    # A missing or invalid data file can still be repaired from the newest
    # validated history entry.  Do this before comparing the incoming sample,
    # otherwise an older sample would regress the current snapshot.
    data_baseline = current_data
    if data_baseline is None and loaded_history.entries:
        data_baseline = max(loaded_history.entries, key=lambda entry: entry.epoch)
        warnings.append("data file was repaired from the latest valid history snapshot")

    # data.json is the durable current-snapshot side of the update.  Include it
    # when rebuilding history so a successful data write followed by a failed
    # history write is recovered on the next cycle instead of being lost.
    history_sources = list(loaded_history.entries)
    if current_data is not None:
        history_sources.append(current_data)
    retained = _merge_and_retain(
        history_sources,
        new_entry,
        retention,
        anchor,
        warnings,
    )
    retained, history_bytes = _apply_defensive_limits(retained, warnings)

    if data_baseline is None or new_entry.epoch >= data_baseline.epoch:
        data_to_publish = new_entry
        data_updated = current_data is None or new_entry.epoch >= current_data.epoch
    else:
        data_to_publish = data_baseline
        data_updated = current_data is None
    if data_updated:
        _atomic_write(data, _serialize_snapshot(data_to_publish))
        current_public = dict(data_to_publish.public)
    else:
        # Keep an older collection in history without allowing it to regress
        # the current data object.
        _check_target(data)
        os.chmod(os.fspath(data), 0o600)
        warnings.append("older snapshot retained in history but did not replace data.json")
        current_public = dict(current_data.public)

    # There is no filesystem-wide atomic replace for two independent files.
    # Publish the current snapshot first; the recovery path above makes the
    # following history write failure safe for the next invocation.
    _atomic_write(history, history_bytes)

    return UpdateResult(
        history=[dict(entry.public) for entry in retained],
        data=current_public,
        data_updated=data_updated,
        warnings=warnings,
        backup_path=backup_path,
    )


def process_snapshot(
    snapshot: Any,
    history_path: Union[str, os.PathLike[str]],
    data_path: Union[str, os.PathLike[str]],
    retention_hours: Union[str, int, float],
    *,
    now: Optional[Union[int, float, datetime_module.datetime]] = None,
) -> UpdateResult:
    """Argument-order convenience wrapper for callers processing stdin data."""

    return update_history(
        history_path,
        data_path,
        snapshot,
        retention_hours,
        now=now,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--history",
        "--history-path",
        dest="history",
        required=True,
        help="rolling history.json path",
    )
    parser.add_argument(
        "--data",
        "--data-path",
        dest="data",
        required=True,
        help="current data.json path",
    )
    parser.add_argument(
        "--retention-hours",
        "--retention",
        dest="retention_hours",
        required=True,
        help="HISTORY_RETENTION_HOURS, as a finite non-negative number",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        input_text = sys.stdin.read()
        snapshot = _loads(input_text)
        result = update_history(
            args.history,
            args.data,
            snapshot,
            args.retention_hours,
        )
    except (HistoryError, OSError, UnicodeError, ValueError, OverflowError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    for warning in result.warnings:
        print(f"[WARN] {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
