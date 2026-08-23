#!/usr/bin/env python3
"""Collect local Codex, OpenCode, and Hermes token usage into SQLite."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
from typing import Any, Iterable

from storage import ArchiveCorruptionError, ArchiveSchemaError, connect_database


SOURCES = ("codex", "opencode", "hermes")
MAX_LABEL_LENGTH = 200
MAX_PRICING_PERIODS = 64
# Analytics adds the requested range's start/end to these boundaries when it
# builds SQL segments.  Keep the catalog itself below that 256-boundary SQL
# budget so every validated catalog remains queryable.
MAX_PRICING_BOUNDARIES = 254
PRICING_RATE_FIELDS = (
    "input_per_million",
    "cache_read_per_million",
    "cache_write_per_million",
    "output_per_million",
)
SESSION_ID_RE = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.IGNORECASE,
)


class CollectorError(RuntimeError):
    """A configured local source cannot be read safely."""


class SourceUnavailable(CollectorError):
    """A requested source exists but does not expose a usable data set."""


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def finite_nonnegative_int(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    if not math.isfinite(value) or value < 0:
        return 0
    return int(value)


def safe_label(value: Any, fallback: str = "unknown") -> str:
    if not isinstance(value, str):
        return fallback
    cleaned = "".join(char for char in value.strip() if ord(char) >= 32)
    return cleaned[:MAX_LABEL_LENGTH] or fallback


def json_object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) and not isinstance(value, list) else {}


def stable_id(*parts: Any) -> str:
    raw = json.dumps(parts, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def load_pricing(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CollectorError(f"invalid pricing catalog: {exc}") from exc
    schema_version = value.get("schema_version") if isinstance(value, dict) else None
    if isinstance(schema_version, bool) or schema_version not in (1, 2):
        raise CollectorError("pricing catalog schema_version must be 1 or 2")
    if value.get("currency") != "USD" or value.get("unknown_model_policy") != "assumed_zero":
        raise CollectorError("pricing catalog must use USD and assumed_zero")
    entries = value.get("entries")
    if not isinstance(entries, list):
        raise CollectorError("pricing catalog entries must be an array")
    seen: set[tuple[str, str]] = set()
    pricing_boundaries: set[int] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise CollectorError("pricing entry must be an object")
        key = (safe_label(entry.get("provider"), "").lower(), safe_label(entry.get("model"), "").lower())
        if not all(key) or key in seen:
            raise CollectorError("pricing provider/model keys must be non-empty and unique")
        seen.add(key)
        if schema_version == 1:
            _validate_pricing_rates(entry)
        else:
            periods = entry.get("periods")
            if not isinstance(periods, list) or not periods or len(periods) > MAX_PRICING_PERIODS:
                raise CollectorError(
                    f"pricing periods must be a non-empty array of at most {MAX_PRICING_PERIODS} items"
                )
            previous_epoch: int | None = None
            for period_index, period in enumerate(periods):
                if not isinstance(period, dict):
                    raise CollectorError("pricing period must be an object")
                effective_from = period.get("effective_from")
                epoch = _pricing_effective_epoch(effective_from)
                if previous_epoch is not None and epoch <= previous_epoch:
                    raise CollectorError("pricing period effective_from values must be strictly increasing")
                if period_index == 0 and epoch > 0:
                    raise CollectorError("the first pricing period must cover the history from 1970-01-01T00:00:00Z")
                previous_epoch = epoch
                pricing_boundaries.add(epoch)
                _validate_pricing_rates(period)
        aliases = entry.get("aliases", [])
        if not isinstance(aliases, list) or not all(isinstance(item, str) for item in aliases):
            raise CollectorError("pricing aliases must be an array of strings")
        identifiers = entry.get("identifiers", [])
        if not isinstance(identifiers, list) or not all(
            isinstance(item, str)
            and item.count("/") == 1
            and all(part.strip() for part in item.split("/", 1))
            for item in identifiers
        ):
            raise CollectorError("pricing identifiers must be provider/model strings")
    if len(pricing_boundaries) > MAX_PRICING_BOUNDARIES:
        raise CollectorError(
            f"pricing catalog has more than {MAX_PRICING_BOUNDARIES} effective boundaries"
        )
    return value


def _pricing_effective_epoch(value: Any) -> int:
    """Parse a UTC ISO-8601 pricing boundary into an epoch second."""
    if not isinstance(value, str) or not value.endswith("Z"):
        raise CollectorError("pricing effective_from must be a UTC ISO-8601 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except (TypeError, ValueError, OverflowError, OSError) as exc:
        raise CollectorError("pricing effective_from must be a UTC ISO-8601 timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise CollectorError("pricing effective_from must be a UTC ISO-8601 timestamp")
    timestamp_part = value[:-1].split("T", 1)[-1]
    if "." in timestamp_part or "," in timestamp_part or parsed.microsecond:
        raise CollectorError("pricing effective_from must use whole seconds")
    return int(parsed.timestamp())


def _validate_pricing_rates(period: dict[str, Any]) -> None:
    for field in PRICING_RATE_FIELDS:
        amount = period.get(field)
        if isinstance(amount, bool) or not isinstance(amount, (int, float)) or amount < 0 or not math.isfinite(amount):
            raise CollectorError(f"pricing {field} must be a finite non-negative number")


def read_state(connection: sqlite3.Connection, source: str, key: str) -> dict[str, Any] | None:
    row = connection.execute(
        "SELECT state_json FROM collector_state WHERE source = ? AND state_key = ?",
        (source, key),
    ).fetchone()
    if not row:
        return None
    try:
        value = json.loads(row[0])
    except (TypeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def write_state(
    connection: sqlite3.Connection,
    source: str,
    key: str,
    value: dict[str, Any],
    now: int,
) -> None:
    connection.execute(
        """
        INSERT INTO collector_state(source, state_key, state_json, updated_at_epoch)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(source, state_key) DO UPDATE SET
            state_json = excluded.state_json,
            updated_at_epoch = excluded.updated_at_epoch
        """,
        (source, key, json.dumps(value, separators=(",", ":"), sort_keys=True), now),
    )


def tracking_started(connection: sqlite3.Connection, source: str, now: int) -> int:
    state = read_state(connection, source, "tracking")
    if state and finite_nonnegative_int(state.get("started_at")) > 0:
        return finite_nonnegative_int(state["started_at"])
    write_state(connection, source, "tracking", {"started_at": now}, now)
    return now


def record_run(
    connection: sqlite3.Connection,
    source: str,
    *,
    enabled: bool,
    status: str,
    now: int,
    error: str | None = None,
    schema: str | None = None,
) -> None:
    success = now if status == "ok" else None
    connection.execute(
        """
        INSERT INTO collector_runs(
            source, enabled, status, last_attempt_at_epoch,
            last_success_at_epoch, last_error, source_schema
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source) DO UPDATE SET
            enabled = excluded.enabled,
            status = excluded.status,
            last_attempt_at_epoch = excluded.last_attempt_at_epoch,
            last_success_at_epoch = COALESCE(excluded.last_success_at_epoch, collector_runs.last_success_at_epoch),
            last_error = excluded.last_error,
            source_schema = COALESCE(excluded.source_schema, collector_runs.source_schema)
        """,
        (source, int(enabled), status, now, success, (error or "")[:500] or None, schema),
    )


def upsert_event(
    connection: sqlite3.Connection,
    *,
    occurred_at: int,
    source: str,
    provider: str,
    model: str,
    input_tokens: int,
    cache_read_tokens: int,
    cache_write_tokens: int,
    output_tokens: int,
    reasoning_tokens: int,
    external_id: str,
    imported: bool,
    quality: str,
) -> None:
    if occurred_at <= 0 or not external_id:
        return
    connection.execute(
        """
        INSERT INTO token_usage_events(
            occurred_at_epoch, source, provider, model,
            input_tokens, cache_read_tokens, cache_write_tokens,
            output_tokens, reasoning_tokens, external_id, imported, quality
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, external_id) DO UPDATE SET
            occurred_at_epoch = excluded.occurred_at_epoch,
            provider = excluded.provider,
            model = excluded.model,
            input_tokens = excluded.input_tokens,
            cache_read_tokens = excluded.cache_read_tokens,
            cache_write_tokens = excluded.cache_write_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_tokens = excluded.reasoning_tokens,
            imported = excluded.imported,
            quality = excluded.quality
        """,
        (
            occurred_at,
            source,
            safe_label(provider, "").lower(),
            safe_label(model),
            finite_nonnegative_int(input_tokens),
            finite_nonnegative_int(cache_read_tokens),
            finite_nonnegative_int(cache_write_tokens),
            finite_nonnegative_int(output_tokens),
            finite_nonnegative_int(reasoning_tokens),
            external_id,
            int(imported),
            safe_label(quality),
        ),
    )


def parse_iso_epoch(value: Any) -> int:
    if not isinstance(value, str):
        return 0
    try:
        import datetime as dt

        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return int(parsed.timestamp())
    except (ValueError, OverflowError):
        return 0


def rollout_key(path: Path) -> str:
    match = SESSION_ID_RE.search(path.name)
    return match.group(1).lower() if match else stable_id(path.name)


def codex_rollout_files(data_dir: Path) -> list[Path]:
    roots = (data_dir / "sessions", data_dir / "archived_sessions")
    files: list[Path] = []
    for root in roots:
        if root.exists():
            files.extend(root.rglob("*.jsonl"))
    return sorted(files)


def collect_codex(
    connection: sqlite3.Connection,
    data_dir: Path,
    cutoff: int,
    now: int,
) -> int:
    started = tracking_started(connection, "codex", now)
    files = codex_rollout_files(data_dir)
    if not files:
        raise SourceUnavailable("no Codex rollout files found")

    inserted_before = connection.total_changes
    read_failures = 0
    for path in sorted(files):
        try:
            stat = path.stat()
        except OSError as exc:
            warn(f"Could not inspect Codex rollout {path}: {exc}")
            read_failures += 1
            continue
        key = rollout_key(path)
        state_key = f"rollout:{key}"
        state = read_state(connection, "codex", state_key) or {}
        previous_size = finite_nonnegative_int(state.get("size"))
        previous_inode = finite_nonnegative_int(state.get("inode"))
        previous_device = finite_nonnegative_int(state.get("device"))
        offset = finite_nonnegative_int(state.get("offset"))
        # A rollout can be atomically replaced during rotation while retaining
        # its name. Seeking into the new inode would silently skip its prefix.
        # Treat old state written before inode tracking as unsafe as well.
        identity_unknown = bool(state) and (previous_inode <= 0 or previous_device <= 0)
        identity_changed = bool(state) and (
            identity_unknown
            or previous_inode != int(stat.st_ino)
            or previous_device != int(stat.st_dev)
        )
        truncated = bool(state) and stat.st_size < previous_size
        if identity_changed or truncated or offset > stat.st_size:
            offset = 0
            state = {}
        if stat.st_mtime < cutoff and not state:
            continue
        totals = json_object(state.get("totals"))
        model = safe_label(state.get("model"))
        provider = safe_label(state.get("provider"), "openai").lower()
        skip_as_hermes = bool(state.get("skip_as_hermes"))
        session_id = safe_label(state.get("session_id"), key)

        try:
            with path.open("r", encoding="utf-8", errors="replace") as source_file:
                source_file.seek(offset)
                partial_line_offset: int | None = None
                while True:
                    line_offset = source_file.tell()
                    line = source_file.readline()
                    if not line:
                        break
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        # Do not consume an incomplete final JSONL record. The
                        # next monitor cycle may observe its completed form.
                        if not line.endswith(("\n", "\r")):
                            partial_line_offset = line_offset
                            break
                        continue
                    payload = json_object(item.get("payload"))
                    item_type = item.get("type")
                    if item_type == "session_meta":
                        session_id = safe_label(payload.get("id") or payload.get("session_id"), key)
                        provider = safe_label(payload.get("model_provider"), provider).lower()
                        originator = json.dumps(payload.get("originator"), ensure_ascii=True).lower()
                        skip_as_hermes = "hermes" in originator
                    elif item_type == "turn_context":
                        model = safe_label(payload.get("model"), model)
                    elif item_type == "event_msg" and payload.get("type") == "token_count":
                        info = json_object(payload.get("info"))
                        current = json_object(info.get("total_token_usage"))
                        if not current:
                            continue
                        fields = (
                            "input_tokens",
                            "cached_input_tokens",
                            "cache_write_input_tokens",
                            "output_tokens",
                            "reasoning_output_tokens",
                        )
                        current_values = {field: finite_nonnegative_int(current.get(field)) for field in fields}
                        previous_values = {field: finite_nonnegative_int(totals.get(field)) for field in fields}
                        deltas = {field: current_values[field] - previous_values[field] for field in fields}
                        totals = current_values
                        if skip_as_hermes or any(value < 0 for value in deltas.values()):
                            continue
                        occurred_at = parse_iso_epoch(item.get("timestamp"))
                        if occurred_at < cutoff:
                            continue
                        cached = deltas["cached_input_tokens"]
                        cache_write = deltas["cache_write_input_tokens"]
                        uncached = max(0, deltas["input_tokens"] - cached - cache_write)
                        output = deltas["output_tokens"]
                        reasoning = min(output, deltas["reasoning_output_tokens"])
                        if not any((uncached, cached, cache_write, output)):
                            continue
                        event_id = stable_id(session_id, occurred_at, current_values)
                        upsert_event(
                            connection,
                            occurred_at=occurred_at,
                            source="codex",
                            provider=provider,
                            model=model,
                            input_tokens=uncached,
                            cache_read_tokens=cached,
                            cache_write_tokens=cache_write,
                            output_tokens=output,
                            reasoning_tokens=reasoning,
                            external_id=event_id,
                            imported=occurred_at < started,
                            quality="exact",
                        )
                offset = partial_line_offset if partial_line_offset is not None else source_file.tell()
        except OSError as exc:
            warn(f"Could not read Codex rollout {path}: {exc}")
            read_failures += 1
            continue
        write_state(
            connection,
            "codex",
            state_key,
            {
                "offset": offset,
                "size": stat.st_size,
                "mtime": int(stat.st_mtime),
                "inode": int(stat.st_ino),
                "device": int(stat.st_dev),
                "totals": totals,
                "model": model,
                "provider": provider,
                "session_id": session_id,
                "skip_as_hermes": skip_as_hermes,
            },
            now,
        )
    if read_failures:
        raise CollectorError(f"could not read {read_failures} Codex rollout file(s)")
    return connection.total_changes - inserted_before


def sqlite_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
    connection.execute("PRAGMA query_only = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')}


def collect_opencode(
    connection: sqlite3.Connection,
    database_path: Path,
    cutoff: int,
    now: int,
) -> int:
    started = tracking_started(connection, "opencode", now)
    state = read_state(connection, "opencode", "watermark") or {}
    watermark = max(0, finite_nonnegative_int(state.get("time_updated")) - 60_000)
    inserted_before = connection.total_changes
    try:
        with sqlite_read_only(database_path) as source:
            columns = table_columns(source, "message")
            if not {"id", "time_updated", "data"}.issubset(columns):
                raise SourceUnavailable("OpenCode message schema is not recognized")
            rows = source.execute(
                "SELECT id, time_updated, data FROM message WHERE time_updated >= ? ORDER BY time_updated",
                (watermark,),
            )
            max_updated = watermark
            for message_id, updated, raw in rows:
                max_updated = max(max_updated, finite_nonnegative_int(updated))
                try:
                    item = json.loads(raw)
                except (TypeError, json.JSONDecodeError):
                    continue
                if not isinstance(item, dict) or item.get("role") != "assistant":
                    continue
                times = json_object(item.get("time"))
                completed_ms = finite_nonnegative_int(times.get("completed"))
                if completed_ms <= 0:
                    continue
                occurred_at = completed_ms // 1000
                if occurred_at < cutoff:
                    continue
                tokens = json_object(item.get("tokens"))
                cache = json_object(tokens.get("cache"))
                reasoning = finite_nonnegative_int(tokens.get("reasoning"))
                visible_output = finite_nonnegative_int(tokens.get("output"))
                model_value = item.get("model")
                if isinstance(model_value, dict):
                    model = safe_label(model_value.get("modelID") or model_value.get("id"))
                    provider = safe_label(model_value.get("providerID"), "opencode").lower()
                else:
                    model = safe_label(item.get("modelID"))
                    provider = safe_label(item.get("providerID"), "opencode").lower()
                upsert_event(
                    connection,
                    occurred_at=occurred_at,
                    source="opencode",
                    provider=provider,
                    model=model,
                    input_tokens=finite_nonnegative_int(tokens.get("input")),
                    cache_read_tokens=finite_nonnegative_int(cache.get("read")),
                    cache_write_tokens=finite_nonnegative_int(cache.get("write")),
                    output_tokens=visible_output + reasoning,
                    reasoning_tokens=reasoning,
                    external_id=safe_label(message_id),
                    imported=occurred_at < started,
                    quality="exact",
                )
            write_state(connection, "opencode", "watermark", {"time_updated": max_updated}, now)
    except sqlite3.DatabaseError as exc:
        raise CollectorError("OpenCode database read failed") from exc
    return connection.total_changes - inserted_before


HERMES_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
)


def hermes_rows(source: sqlite3.Connection) -> tuple[str, Iterable[sqlite3.Row]]:
    source.row_factory = sqlite3.Row
    tables = {row[0] for row in source.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if "session_model_usage" in tables:
        return "session_model_usage", source.execute(
            """
            SELECT session_id, model, billing_provider, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_write_tokens, reasoning_tokens, first_seen, last_seen
            FROM session_model_usage
            """
        )
    if "sessions" in tables:
        return "sessions", source.execute(
            """
            SELECT id AS session_id, model, billing_provider, billing_mode, '' AS task,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_write_tokens, reasoning_tokens, started_at AS first_seen,
                   COALESCE(ended_at, started_at) AS last_seen
            FROM sessions
            """
        )
    raise SourceUnavailable("Hermes usage schema is not recognized")


def collect_hermes(
    connection: sqlite3.Connection,
    database_path: Path,
    cutoff: int,
    now: int,
) -> tuple[int, str]:
    started = tracking_started(connection, "hermes", now)
    initialized = read_state(connection, "hermes", "initialized") is not None
    inserted_before = connection.total_changes
    try:
        with sqlite_read_only(database_path) as source:
            schema, rows = hermes_rows(source)
            for row in rows:
                entity_parts = (
                    row["session_id"], row["model"], row["billing_provider"],
                    row["billing_mode"], row["task"],
                )
                entity = stable_id(*entity_parts)
                state_key = f"counter:{entity}"
                previous = read_state(connection, "hermes", state_key)
                current = {field: finite_nonnegative_int(row[field]) for field in HERMES_FIELDS}
                if previous is None and not initialized:
                    write_state(
                        connection,
                        "hermes",
                        state_key,
                        {**current, "baseline": current, "first_seen": row["first_seen"]},
                        now,
                    )
                    continue
                previous_values = previous or {}
                deltas = {field: current[field] - finite_nonnegative_int(previous_values.get(field)) for field in HERMES_FIELDS}
                if any(value < 0 for value in deltas.values()):
                    deltas = {field: 0 for field in HERMES_FIELDS}
                occurred_at = finite_nonnegative_int(row["last_seen"]) or now
                if occurred_at >= cutoff and any(deltas.values()):
                    output = deltas["output_tokens"]
                    reasoning = min(output, deltas["reasoning_tokens"])
                    event_id = stable_id(entity, now, current)
                    upsert_event(
                        connection,
                        occurred_at=occurred_at,
                        source="hermes",
                        provider=safe_label(row["billing_provider"], "hermes").lower(),
                        model=safe_label(row["model"]),
                        input_tokens=deltas["input_tokens"],
                        cache_read_tokens=deltas["cache_read_tokens"],
                        cache_write_tokens=deltas["cache_write_tokens"],
                        output_tokens=output,
                        reasoning_tokens=reasoning,
                        external_id=event_id,
                        imported=occurred_at < started,
                        quality="polled_delta",
                    )
                baseline = json_object(previous_values.get("baseline"))
                write_state(
                    connection,
                    "hermes",
                    state_key,
                    {**current, "baseline": baseline, "first_seen": row["first_seen"]},
                    now,
                )
            write_state(connection, "hermes", "initialized", {"at": now}, now)
    except sqlite3.DatabaseError as exc:
        raise CollectorError("Hermes database read failed") from exc
    return connection.total_changes - inserted_before, schema


def parse_sources(value: str) -> tuple[str, ...]:
    normalized = value.strip().lower()
    if normalized == "none":
        return ()
    if normalized == "auto":
        return SOURCES
    values = tuple(dict.fromkeys(part.strip() for part in normalized.split(",") if part.strip()))
    if not values or any(item not in SOURCES for item in values):
        raise CollectorError("token sources must be auto, none, or codex,opencode,hermes")
    return values


def collect(args: argparse.Namespace) -> int:
    now = int(args.now or time.time())
    retention_days = int(args.retention_days)
    cutoff = 0 if retention_days == 0 else now - retention_days * 86400
    requested = parse_sources(args.sources)
    explicit = args.sources.strip().lower() not in ("auto", "none")
    paths = {
        "codex": Path(args.codex_data_dir).expanduser(),
        "opencode": Path(args.opencode_db).expanduser(),
        "hermes": Path(args.hermes_db).expanduser(),
    }
    load_pricing(Path(args.pricing).expanduser())

    database_path = Path(args.database)
    database_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(database_path.parent, 0o700)
    try:
        connection = connect_database(database_path)
    except (ArchiveCorruptionError, ArchiveSchemaError, OSError, sqlite3.DatabaseError) as exc:
        raise CollectorError(f"analytics archive cannot be opened: {exc}") from exc
    failed = False
    try:
        with connection:
            for source in SOURCES:
                if source not in requested:
                    record_run(connection, source, enabled=False, status="disabled", now=now)
                    continue
                path = paths[source]
                available = path.is_dir() if source == "codex" else path.is_file()
                if not available:
                    record_run(
                        connection,
                        source,
                        enabled=True,
                        status="unavailable" if explicit else "disabled",
                        now=now,
                        error="source path not found" if explicit else None,
                    )
                    failed = failed or explicit
                    continue
                try:
                    if source == "codex":
                        count = collect_codex(connection, path, cutoff, now)
                        schema = "codex-rollout-token_count-v1"
                    elif source == "opencode":
                        count = collect_opencode(connection, path, cutoff, now)
                        schema = "opencode-message-v1"
                    else:
                        count, hermes_schema = collect_hermes(connection, path, cutoff, now)
                        schema = f"hermes-{hermes_schema}-v1"
                    record_run(connection, source, enabled=True, status="ok", now=now, schema=schema)
                    print(f"[OK] {source}: analytics collection completed ({count} database changes).")
                except SourceUnavailable as exc:
                    status = "unavailable" if explicit else "disabled"
                    record_run(
                        connection,
                        source,
                        enabled=True,
                        status=status,
                        now=now,
                        error=str(exc) if explicit else None,
                    )
                    if explicit:
                        warn(f"{source}: {exc}")
                    failed = failed or explicit
                except (CollectorError, OSError, UnicodeError) as exc:
                    record_run(connection, source, enabled=True, status="error", now=now, error=f"{source} collector failed")
                    warn(f"{source}: {exc}")
                    failed = True
            if retention_days > 0:
                connection.execute("DELETE FROM token_usage_events WHERE occurred_at_epoch < ?", (cutoff,))
                connection.execute("DELETE FROM reset_events WHERE reset_at_epoch < ?", (cutoff,))
    finally:
        connection.close()
    os.chmod(database_path, 0o600)
    return 1 if failed else 0


def check(args: argparse.Namespace) -> int:
    load_pricing(Path(args.pricing).expanduser())
    requested = parse_sources(args.sources)
    explicit = args.sources.strip().lower() not in ("auto", "none")
    paths = {
        "codex": Path(args.codex_data_dir).expanduser(),
        "opencode": Path(args.opencode_db).expanduser(),
        "hermes": Path(args.hermes_db).expanduser(),
    }
    failed = False
    for source in SOURCES:
        if source not in requested:
            print(f"[INFO] {source}: disabled.")
            continue
        path = paths[source]
        available = path.is_dir() if source == "codex" else path.is_file()
        if not available:
            label = "ERROR" if explicit else "INFO"
            print(f"[{label}] {source}: source path not found: {path}", file=sys.stderr if explicit else sys.stdout)
            failed = failed or explicit
            continue
        try:
            if source == "codex":
                if not codex_rollout_files(path):
                    label = "ERROR" if explicit else "INFO"
                    stream = sys.stderr if explicit else sys.stdout
                    print(f"[{label}] codex: no Codex rollout files found under {path}", file=stream)
                    failed = failed or explicit
                    continue
            elif source == "opencode":
                with sqlite_read_only(path) as connection:
                    columns = table_columns(connection, "message")
                    if not {"id", "time_updated", "data"}.issubset(columns):
                        raise CollectorError("OpenCode message schema is not recognized")
            else:
                with sqlite_read_only(path) as connection:
                    schema, _rows = hermes_rows(connection)
                    # hermes_rows executes the SELECT eagerly, so schema
                    # incompatibilities are detected before --check returns.
                    if schema not in ("session_model_usage", "sessions"):
                        raise CollectorError("Hermes usage schema is not recognized")
        except (CollectorError, OSError, sqlite3.DatabaseError) as exc:
            label = "ERROR" if explicit else "INFO"
            stream = sys.stderr if explicit else sys.stdout
            print(f"[{label}] {source}: source validation failed: {exc}", file=stream)
            failed = failed or explicit
            continue
        print(f"[OK] {source}: source is readable.")
    print(f"[OK] pricing: {Path(args.pricing).expanduser()}")
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--pricing", required=True)
    parser.add_argument("--sources", default="auto")
    parser.add_argument("--retention-days", default="365")
    parser.add_argument("--codex-data-dir", default=str(Path.home() / ".codex"))
    parser.add_argument(
        "--opencode-db",
        default=str(Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "opencode" / "opencode.db"),
    )
    parser.add_argument("--hermes-db", default=str(Path.home() / ".hermes" / "state.db"))
    parser.add_argument("--now", type=int, default=0, help=argparse.SUPPRESS)
    parser.add_argument("--check", action="store_true")
    return parser


if __name__ == "__main__":
    try:
        arguments = build_parser().parse_args()
        raise SystemExit(check(arguments) if arguments.check else collect(arguments))
    except (CollectorError, ValueError, ArchiveCorruptionError, ArchiveSchemaError, sqlite3.DatabaseError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise SystemExit(1)
