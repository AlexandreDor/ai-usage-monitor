#!/usr/bin/env python3
"""Read-only aggregation for the local advanced analytics page."""

from __future__ import annotations

import argparse
import bisect
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import re
import sqlite3
import sys
from statistics import median
from typing import Any, Iterable, Sequence
from zoneinfo import ZoneInfo

from storage import ArchiveCorruptionError, ArchiveSchemaError, connect_database
from token_usage import CollectorError, load_pricing


PARIS = ZoneInfo("Europe/Paris")
RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400, "1y": 365 * 86400}
SOURCES = ("codex", "opencode", "hermes")
TOKEN_FIELDS = ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens")
WEEKLY_WINDOW_SECONDS = 7 * 86400
WEEKLY_VALUE_WINDOW_SECONDS = 2 * 3600
WEEKLY_VALUE_MIN_WINDOW_SECONDS = 1 * 3600 + 45 * 60
WEEKLY_VALUE_MAX_WINDOW_SECONDS = 2 * 3600 + 15 * 60
WEEKLY_VALUE_MIN_QUOTA_DELTA_POINTS = 0.5
WEEKLY_VALUE_MAX_POINTS = 10_000
WEEKLY_VALUE_STALE_REASON = "stale_data"
MAX_SERIES_POINTS = 10_000
MAX_SERIES_GROUP_ROWS = 100_000
MAX_RESET_MARKERS = 2_000
WEEKLY_RESET_BOUNDARY_MARGIN_SECONDS = 2 * 86400
DEFAULT_RESET_PAGE_SIZE = 50
DEFAULT_BREAKDOWN_PAGE_SIZE = 50
MAX_BREAKDOWN_ROWS = 2_000
MAX_AVAILABLE_MODELS = 500
_LOCAL_PATH_RE = re.compile(r"(?<![A-Za-z0-9_.-])(?:~|/(?:[^\s'\"`,;:)\]}]+/)*[^\s'\"`,;:)\]}]+)")


class AnalyticsError(ValueError):
    """Invalid query or unavailable analytics archive."""


class AnalyticsUnavailableError(AnalyticsError):
    """The archive or its configured dependencies cannot be read."""


def redact_error(value: Any) -> str | None:
    """Keep collector diagnostics useful without returning local paths."""
    if value is None:
        return None
    text = str(value).strip()[:500]
    if not text:
        return None
    return _LOCAL_PATH_RE.sub("<local path>", text)


def iso_utc(epoch: int | None) -> str | None:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z") if epoch is not None else None


def parse_day(raw: str, *, end: bool) -> int:
    try:
        value = datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=PARIS)
        if end:
            value += timedelta(days=1)
        return int(value.timestamp())
    except (ValueError, OverflowError, OSError) as exc:
        raise AnalyticsError("dates must use YYYY-MM-DD") from exc


def scalar(connection: sqlite3.Connection, query: str, parameters: Iterable[Any] = ()) -> Any:
    row = connection.execute(query, tuple(parameters)).fetchone()
    return row[0] if row else None


def ideal_weekly_pace(connection: sqlite3.Connection, reset_at: int) -> float | None:
    """Return the quota that should remain at a random reset's observation time."""
    row = connection.execute(
        """SELECT weekly_reset_at
             FROM snapshots
            WHERE scraped_at_epoch < ?
              AND weekly_reset_at IS NOT NULL
            ORDER BY scraped_at_epoch DESC
            LIMIT 1""",
        (reset_at,),
    ).fetchone()
    deadline = row[0] if row else None
    if not isinstance(deadline, int):
        return None
    remaining = deadline - reset_at
    if not 0 <= remaining <= WEEKLY_WINDOW_SECONDS:
        return None
    return round(100 * remaining / WEEKLY_WINDOW_SECONDS, 3)


def ideal_weekly_remaining(sampled_at: int, reset_at: Any) -> float | None:
    if not isinstance(reset_at, int):
        return None
    remaining = reset_at - sampled_at
    if not 0 <= remaining <= WEEKLY_WINDOW_SECONDS:
        return None
    return round(100 * remaining / WEEKLY_WINDOW_SECONDS, 3)


def random_reset_impact(connection: sqlite3.Connection, reset_at: int, before: Any) -> tuple[float | None, float | None]:
    ideal = ideal_weekly_pace(connection, reset_at)
    if not isinstance(before, (int, float)) or ideal is None:
        return ideal, None
    return ideal, round(ideal - float(before), 3)


def period(connection: sqlite3.Connection, params: dict[str, str], now: int) -> tuple[int, int, str, int]:
    from_date, to_date = params.get("from_date", ""), params.get("to_date", "")
    if bool(from_date) != bool(to_date):
        raise AnalyticsError("from_date and to_date must be provided together")
    if from_date:
        start, end, label = parse_day(from_date, end=False), parse_day(to_date, end=True), "custom"
    else:
        label = params.get("range", "30d")
        if label == "all":
            values = [
                scalar(connection, "SELECT MIN(scraped_at_epoch) FROM snapshots"),
                scalar(connection, "SELECT MIN(occurred_at_epoch) FROM token_usage_events"),
                scalar(connection, "SELECT MIN(reset_at_epoch) FROM reset_events"),
            ]
            start = min((int(value) for value in values if value is not None), default=now - RANGES["30d"])
        elif label in RANGES:
            start = now - RANGES[label]
        else:
            raise AnalyticsError("range must be 24h, 7d, 30d, 90d, 1y, or all")
        end = now
    if start >= end:
        raise AnalyticsError("the requested period is empty")
    duration = end - start
    # Keep the product's stable buckets for ordinary ranges. Very large
    # unlimited-retention archives are coarsened only when necessary to keep
    # the JSON response bounded.
    granularity = 900 if duration <= 48 * 3600 else 1800 if duration <= 30 * 86400 else 3600
    estimated_points = (duration + granularity - 1) // granularity
    if estimated_points > MAX_SERIES_POINTS:
        multiplier = (estimated_points + MAX_SERIES_POINTS - 1) // MAX_SERIES_POINTS
        granularity *= multiplier
    return start, end, label, granularity


def price_index(catalog: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for entry in catalog["entries"]:
        provider = entry["provider"].strip().lower()
        for model in [entry["model"], *entry.get("aliases", [])]:
            result[(provider, model.strip().lower())] = entry
        for identifier in entry.get("identifiers", []):
            alias_provider, alias_model = identifier.split("/", 1)
            result[(alias_provider.strip().lower(), alias_model.strip().lower())] = entry
    return result


def cost_row(row: dict[str, Any], prices: dict[tuple[str, str], dict[str, Any]]) -> tuple[float, bool]:
    price = prices.get((row["provider"].lower(), row["model"].lower()))
    if price is None:
        return 0.0, True
    amount = (
        row["input_tokens"] * price["input_per_million"]
        + row["cache_read_tokens"] * price["cache_read_per_million"]
        + row["cache_write_tokens"] * price["cache_write_per_million"]
        + row["output_tokens"] * price["output_per_million"]
    ) / 1_000_000
    return amount, False


def _finite_quota_number(value: Any, *, minimum: float = 0.0, maximum: float = 100.0) -> bool:
    """Return whether a quota percentage is a finite bounded number."""
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and minimum <= float(value) <= maximum
    )


def _valid_sample_interval(value: Any) -> int | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)) and value > 0:
        return int(value)
    return None


def _positive_price(entry: dict[str, Any] | None) -> bool:
    if not isinstance(entry, dict):
        return False
    return all(
        isinstance(entry.get(field), (int, float))
        and not isinstance(entry.get(field), bool)
        and math.isfinite(float(entry[field]))
        and float(entry[field]) > 0
        for field in ("input_per_million", "cache_read_per_million", "cache_write_per_million", "output_per_million")
    )


def _event_cost(row: sqlite3.Row | dict[str, Any], prices: dict[tuple[str, str], dict[str, Any]]) -> tuple[float | None, str | None]:
    """Price one event for the weekly-value estimator.

    The regular token report deliberately treats unknown/zero-price entries as
    zero.  A quota value must instead be invalidated when any event cannot be
    compared to API pricing, so this helper has stricter semantics.
    """
    provider = row["provider"] if isinstance(row, sqlite3.Row) else row.get("provider")
    model = row["model"] if isinstance(row, sqlite3.Row) else row.get("model")
    if not isinstance(provider, str) or not provider.strip() or not isinstance(model, str) or not model.strip():
        return None, "invalid_event"
    price = prices.get((provider.lower(), model.lower()))
    if not _positive_price(price):
        return None, "missing_price"
    counters = []
    for field in ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens"):
        value = row[field] if isinstance(row, sqlite3.Row) else row.get(field)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)) or float(value) < 0:
            return None, "invalid_event"
        counters.append(float(value))
    amount = (
        counters[0] * float(price["input_per_million"])
        + counters[1] * float(price["cache_read_per_million"])
        + counters[2] * float(price["cache_write_per_million"])
        + counters[3] * float(price["output_per_million"])
    ) / 1_000_000
    if not math.isfinite(amount):
        return None, "invalid_event"
    return amount, None


def _load_cost_events(
    connection: sqlite3.Connection,
    prices: dict[tuple[str, str], dict[str, Any]],
    start: int,
    end: int,
) -> list[tuple[int, float | None, str | None, str | None]]:
    """Load and price all locally collected token events for interval calculations."""
    if start >= end:
        return []
    rows = connection.execute(
        """SELECT occurred_at_epoch, provider, model, input_tokens,
                  cache_read_tokens, cache_write_tokens, output_tokens, quality
             FROM token_usage_events
            WHERE occurred_at_epoch >= ? AND occurred_at_epoch < ?
            ORDER BY occurred_at_epoch, id""",
        (start, end),
    ).fetchall()
    events: list[tuple[int, float | None, str | None, str | None]] = []
    for row in rows:
        epoch = row["occurred_at_epoch"]
        if not isinstance(epoch, (int, float)) or isinstance(epoch, bool) or not math.isfinite(float(epoch)):
            events.append((0, None, "invalid_event", row["quality"]))
            continue
        cost, reason = _event_cost(row, prices)
        events.append((int(epoch), cost, reason, row["quality"]))
    return events


def _interval_event_cost(
    events: list[tuple[int, float | None, str | None, str | None]],
    start: int,
    end: int,
    event_index: tuple[list[int], list[float], dict[str, list[int]], list[int]] | None = None,
) -> tuple[float | None, str | None, bool]:
    """Return cost, invalidation reason, and whether a polled delta occurred."""
    if start >= end or not events:
        return None, "no_events", False
    if event_index is None:
        epochs = [item[0] for item in events]
    else:
        epochs = event_index[0]
    first = bisect.bisect_left(epochs, start)
    last = bisect.bisect_left(epochs, end)
    if first >= last:
        return None, "no_events", False
    if event_index is not None:
        _epochs, prefix_cost, prefix_reasons, prefix_polled = event_index
        for reason in ("invalid_event", "missing_price"):
            if prefix_reasons[reason][last] - prefix_reasons[reason][first] > 0:
                return None, reason, prefix_polled[last] - prefix_polled[first] > 0
        total = prefix_cost[last] - prefix_cost[first]
        polled_delta = prefix_polled[last] - prefix_polled[first] > 0
        if not math.isfinite(total) or total <= 0:
            return None, "no_cost", polled_delta
        return total, None, polled_delta
    total = 0.0
    polled_delta = False
    for epoch, cost, reason, quality in events[first:last]:
        if reason is not None:
            return None, reason, polled_delta or quality == "polled_delta"
        if cost is None or not math.isfinite(cost):
            return None, "invalid_event", polled_delta or quality == "polled_delta"
        total += cost
        polled_delta = polled_delta or quality == "polled_delta"
    if not math.isfinite(total) or total <= 0:
        return None, "no_cost", polled_delta
    return total, None, polled_delta


def _event_index(events: list[tuple[int, float | None, str | None, str | None]]) -> tuple[list[int], list[float], dict[str, list[int]], list[int]]:
    """Build prefix arrays so thousands of two-hour windows stay bounded."""
    epochs = [item[0] for item in events]
    prefix_cost = [0.0]
    prefix_reasons = {"invalid_event": [0], "missing_price": [0]}
    prefix_polled = [0]
    for _epoch, cost, reason, quality in events:
        prefix_cost.append(prefix_cost[-1] + (cost if cost is not None and math.isfinite(cost) else 0.0))
        for known in prefix_reasons:
            prefix_reasons[known].append(prefix_reasons[known][-1] + int(reason == known))
        prefix_polled.append(prefix_polled[-1] + int(quality == "polled_delta"))
    return epochs, prefix_cost, prefix_reasons, prefix_polled


def _window_pair_reason(start_row: sqlite3.Row, end_row: sqlite3.Row, start_epoch: int, end_epoch: int) -> str | None:
    if end_epoch <= start_epoch:
        return "invalid_window"
    duration = end_epoch - start_epoch
    if not WEEKLY_VALUE_MIN_WINDOW_SECONDS <= duration <= WEEKLY_VALUE_MAX_WINDOW_SECONDS:
        return "window_duration"
    if not _finite_quota_number(start_row["weekly_pct"]) or not _finite_quota_number(end_row["weekly_pct"]):
        return "invalid_quota_pct"
    start_limit = start_row["limit_id"]
    end_limit = end_row["limit_id"]
    if not isinstance(start_limit, str) or not start_limit or not isinstance(end_limit, str) or not end_limit:
        return "missing_limit_id"
    if start_limit != end_limit:
        return "limit_transition"
    start_deadline = start_row["weekly_reset_at"]
    end_deadline = end_row["weekly_reset_at"]
    if not isinstance(start_deadline, int) or start_deadline <= start_epoch:
        return "missing_deadline"
    if not isinstance(end_deadline, int):
        return "missing_deadline"
    if end_deadline <= end_epoch or start_deadline != end_deadline:
        return "deadline_transition"
    if start_epoch < start_deadline <= end_epoch:
        return "reset_in_window"
    return None


def _snapshot_epoch_index(rows: list[sqlite3.Row]) -> list[int]:
    # The index is positional; callers remove malformed epochs before
    # constructing it so bisect boundaries remain aligned with ``rows``.
    return [int(row["scraped_at_epoch"]) for row in rows]


def _sample_rows(rows: list[sqlite3.Row], maximum: int) -> list[sqlite3.Row]:
    """Uniformly thin a long range while retaining both boundaries."""
    if len(rows) <= maximum:
        return rows
    last = len(rows) - 1
    return [rows[round(index * last / (maximum - 1))] for index in range(maximum)]


def _window_start(
    rows: list[sqlite3.Row],
    end_row: sqlite3.Row,
    end_epoch: int,
    row_epochs: list[int] | None = None,
) -> tuple[sqlite3.Row | None, str | None]:
    target = end_epoch - WEEKLY_VALUE_WINDOW_SECONDS
    epochs = row_epochs if row_epochs is not None else _snapshot_epoch_index(rows)
    left = bisect.bisect_left(epochs, end_epoch - WEEKLY_VALUE_MAX_WINDOW_SECONDS)
    right = bisect.bisect_right(epochs, end_epoch - WEEKLY_VALUE_MIN_WINDOW_SECONDS)
    candidates: list[tuple[int, sqlite3.Row, int]] = []
    for row in rows[left:right]:
        epoch = row["scraped_at_epoch"]
        if not isinstance(epoch, int) or epoch >= end_epoch:
            continue
        if not _finite_quota_number(row["weekly_pct"]):
            continue
        duration = end_epoch - epoch
        if WEEKLY_VALUE_MIN_WINDOW_SECONDS <= duration <= WEEKLY_VALUE_MAX_WINDOW_SECONDS:
            candidates.append((abs(epoch - target), row, epoch))
    if not candidates:
        return None, "window_duration"
    candidates.sort(key=lambda item: (item[0], item[2]))
    row = candidates[0][1]
    reason = _window_pair_reason(row, end_row, row["scraped_at_epoch"], end_epoch)
    if reason is None:
        limit_id = row["limit_id"]
        deadline = row["weekly_reset_at"]
        middle_left = bisect.bisect_right(epochs, row["scraped_at_epoch"])
        middle_right = bisect.bisect_right(epochs, end_epoch)
        for middle in rows[middle_left:middle_right]:
            middle_epoch = middle["scraped_at_epoch"]
            if not isinstance(middle_epoch, int) or not row["scraped_at_epoch"] < middle_epoch <= end_epoch:
                continue
            if isinstance(middle["limit_id"], str) and middle["limit_id"] and middle["limit_id"] != limit_id:
                reason = "limit_transition"
                break
            if _finite_quota_number(middle["weekly_pct"]) and (not isinstance(middle["limit_id"], str) or not middle["limit_id"]):
                reason = "missing_limit_id"
                break
            if isinstance(middle["weekly_reset_at"], int) and middle["weekly_reset_at"] != deadline:
                reason = "deadline_transition"
                break
            if _finite_quota_number(middle["weekly_pct"]) and not isinstance(middle["weekly_reset_at"], int):
                reason = "missing_deadline"
                break
    return row, reason


def _quality_for_value(delta_points: float, polled_delta: bool) -> str:
    return "low_confidence" if delta_points < 1.0 or polled_delta else "good"


def weekly_limit_value(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    start: int,
    end: int,
    *,
    now: int | None = None,
    sample_interval_seconds: int = 900,
) -> dict[str, Any]:
    """Build the two-hour implicit weekly-limit value series.

    This is intentionally independent of token source/model UI filters: it is
    a quota-wide metric based on all locally collected token events, not a view
    of the currently selected breakdown.
    """
    rows = connection.execute(
        """SELECT scraped_at_epoch, weekly_pct, weekly_reset_at, limit_id,
                  sample_interval_seconds
             FROM snapshots
            WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
            ORDER BY scraped_at_epoch""",
        (start - WEEKLY_VALUE_MAX_WINDOW_SECONDS, end),
    ).fetchall()
    rows = [row for row in rows if isinstance(row["scraped_at_epoch"], int)]
    end_rows = [row for row in rows if start <= row["scraped_at_epoch"] < end]
    candidate_count = len(end_rows)
    selected_rows = _sample_rows(end_rows, WEEKLY_VALUE_MAX_POINTS)
    row_epochs = _snapshot_epoch_index(rows)
    events = _load_cost_events(
        connection,
        price_index(catalog),
        start - WEEKLY_VALUE_MAX_WINDOW_SECONDS,
        end,
    )
    event_index = _event_index(events)
    reset_epochs = {
        row[0]
        for row in connection.execute(
            """SELECT reset_at_epoch FROM reset_events
                WHERE window = 'weekly' AND reset_at_epoch >= ? AND reset_at_epoch <= ?""",
            (start - WEEKLY_VALUE_MAX_WINDOW_SECONDS, end),
        )
        if isinstance(row[0], int)
    }
    series: list[dict[str, Any]] = []
    unavailable: dict[str, int] = {}
    valid_by_segment: dict[tuple[str, int], list[float]] = {}
    latest_archive = connection.execute(
        "SELECT scraped_at_epoch, sample_interval_seconds FROM snapshots ORDER BY scraped_at_epoch DESC LIMIT 1"
    ).fetchone()
    latest_epoch = latest_archive["scraped_at_epoch"] if latest_archive else None
    latest_interval = latest_archive["sample_interval_seconds"] if latest_archive else sample_interval_seconds
    try:
        effective_interval = max(60, int(latest_interval or sample_interval_seconds))
    except (TypeError, ValueError):
        effective_interval = max(60, int(sample_interval_seconds or 900))
    freshness_threshold = max(effective_interval * 2, effective_interval + 60)
    stale_latest = (
        now is not None
        and isinstance(latest_epoch, int)
        and now - latest_epoch > freshness_threshold
    )
    for end_row in selected_rows:
        end_epoch = end_row["scraped_at_epoch"]
        point: dict[str, Any] = {
            "at": iso_utc(end_epoch) if isinstance(end_epoch, int) else None,
            "window_start": None,
            "window_seconds": None,
            "limit_id": end_row["limit_id"] if isinstance(end_row["limit_id"], str) and end_row["limit_id"] else None,
            "quota_consumed_pct_points": None,
            "consumed_fraction": None,
            "observed_cost_usd": None,
            "raw_value_usd": None,
            "value_usd": None,
            "quality": "unavailable",
            "reason": None,
        }
        reason: str | None = None
        start_row: sqlite3.Row | None = None
        if not isinstance(end_epoch, int) or not _finite_quota_number(end_row["weekly_pct"]):
            reason = "invalid_quota_pct"
        else:
            start_row, reason = _window_start(rows, end_row, end_epoch, row_epochs)
            if start_row is None and reason is None:
                reason = "window_duration"
        if reason is None and start_row is not None:
            start_epoch = start_row["scraped_at_epoch"]
            point["window_start"] = iso_utc(start_epoch)
            point["window_seconds"] = end_epoch - start_epoch
            delta = float(start_row["weekly_pct"]) - float(end_row["weekly_pct"])
            point["quota_consumed_pct_points"] = round(delta, 3)
            if stale_latest and end_epoch == latest_epoch:
                reason = WEEKLY_VALUE_STALE_REASON
            elif any(start_epoch < reset_at <= end_epoch for reset_at in reset_epochs):
                reason = "reset_in_window"
            if reason is not None:
                pass
            elif delta <= 0:
                reason = "quota_increase" if delta < 0 else "zero_quota_delta"
            elif delta < WEEKLY_VALUE_MIN_QUOTA_DELTA_POINTS:
                reason = "insufficient_quota_delta"
            else:
                fraction = delta / 100.0
                point["consumed_fraction"] = round(fraction, 8)
                cost, reason, polled_delta = _interval_event_cost(events, start_epoch, end_epoch, event_index)
                if reason is None and cost is not None:
                    raw = cost / fraction
                    if not math.isfinite(raw) or raw <= 0:
                        reason = "invalid_value"
                    else:
                        limit_id = str(start_row["limit_id"])
                        segment = (limit_id, int(start_row["weekly_reset_at"]))
                        previous = valid_by_segment.setdefault(segment, [])[-2:]
                        values = [*previous, raw]
                        smoothed = float(median(values))
                        dispersion = (max(values) - min(values)) / smoothed if smoothed > 0 else math.inf
                        quality = _quality_for_value(delta, polled_delta)
                        if dispersion > 0.5:
                            quality = "volatile"
                        point["observed_cost_usd"] = round(cost, 8)
                        point["raw_value_usd"] = round(raw, 8)
                        point["value_usd"] = round(smoothed, 8)
                        point["quality"] = quality
                        point["dispersion_pct"] = round(dispersion * 100, 3) if math.isfinite(dispersion) else None
                        valid_by_segment[segment].append(raw)
        if reason is not None:
            point["reason"] = reason
            unavailable[reason] = unavailable.get(reason, 0) + 1
        series.append(point)
    return {
        "currency": "USD",
        "window_seconds": WEEKLY_VALUE_WINDOW_SECONDS,
        "minimum_quota_delta_pct_points": WEEKLY_VALUE_MIN_QUOTA_DELTA_POINTS,
        "candidate_points": candidate_count,
        "returned_points": len(series),
        "omitted_points": candidate_count - len(series),
        "points_reduced": candidate_count > len(series),
        "current_status": "stale_data" if stale_latest else "available",
        "current_reason": WEEKLY_VALUE_STALE_REASON if stale_latest else None,
        "current_at": iso_utc(latest_epoch) if isinstance(latest_epoch, int) else None,
        "series": series,
        "unavailable_reasons": unavailable,
    }


def _snapshot_limit_id_around_reset(
    snapshots: list[sqlite3.Row],
    reset_at: int,
    observed_at: int,
    sample_interval_seconds: int | None = None,
) -> tuple[str | None, str | None]:
    """Resolve a reset's limit group from nearby coherent observations.

    A reset marker observed after a collection gap must not borrow a
    several-day-old snapshot as its boundary. Both sides are therefore
    required within ``max(3600, 2 * local_interval)`` of the reset. The local
    interval is the maximum valid cadence on the two boundary snapshots; a
    missing cadence falls back to 900 seconds only when both omit it.
    """
    del observed_at, sample_interval_seconds  # A global/future cadence cannot widen old boundaries.
    ordered = [
        row for row in snapshots
        if isinstance(row["scraped_at_epoch"], int)
        and _finite_quota_number(row["weekly_pct"])
        and isinstance(row["limit_id"], str) and row["limit_id"]
    ]
    epochs = [row["scraped_at_epoch"] for row in ordered]
    before_index = bisect.bisect_left(epochs, reset_at) - 1
    after_index = bisect.bisect_left(epochs, reset_at)
    before_row = ordered[before_index] if before_index >= 0 else None
    after_row = ordered[after_index] if after_index < len(ordered) else None
    # Preserve the exact-reset fallback for archives whose first observation
    # is itself the reset boundary.
    if before_row is None and after_row is not None and after_row["scraped_at_epoch"] == reset_at:
        before_row = after_row
    if before_row is None or after_row is None:
        return None, "stale_boundary"
    def boundary_interval(row: sqlite3.Row) -> int | None:
        try:
            value = row["sample_interval_seconds"]
        except (IndexError, KeyError):
            value = None
        return _valid_sample_interval(value)
    local_intervals = [
        interval for interval in (
            boundary_interval(before_row),
            boundary_interval(after_row),
        ) if interval is not None
    ]
    interval = max(local_intervals, default=900)
    boundary = max(3600, interval * 2)
    if reset_at - before_row["scraped_at_epoch"] > boundary or after_row["scraped_at_epoch"] - reset_at > boundary:
        return None, "stale_boundary"
    if before_row["limit_id"] != after_row["limit_id"]:
        return None, "limit_transition"
    return str(before_row["limit_id"]), None


def weekly_reset_cycle_metrics(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    reset_rows: Sequence[sqlite3.Row],
) -> dict[int, dict[str, Any]]:
    """Calculate full-cycle costs from all local token events in one pass."""
    if not reset_rows:
        return {}
    target_epochs = sorted(
        {row["reset_at_epoch"] for row in reset_rows if isinstance(row["reset_at_epoch"], int)}
    )
    if not target_epochs:
        return {}
    predecessor = connection.execute(
        """SELECT reset_at_epoch, observed_at_epoch, before_pct, after_pct,
                  detection_method
             FROM reset_events
            WHERE window = 'weekly' AND reset_at_epoch < ?
            ORDER BY reset_at_epoch DESC
            LIMIT 1""",
        (target_epochs[0],),
    ).fetchone()
    cycle_start = predecessor["reset_at_epoch"] if predecessor is not None else target_epochs[0]
    all_weekly = connection.execute(
        """SELECT reset_at_epoch, observed_at_epoch, before_pct, after_pct,
                         detection_method
                    FROM reset_events
                   WHERE window = 'weekly'
                     AND reset_at_epoch >= ? AND reset_at_epoch <= ?
                   ORDER BY reset_at_epoch""",
        (cycle_start, target_epochs[-1]),
    ).fetchall()
    # Boundary lookup is restricted to the cycles represented by this page.
    # LOOP_INTERVAL is capped at one day, so two days cover either side of a
    # reset without allowing a global/future cadence to widen an old query.
    snapshots = connection.execute(
        """SELECT scraped_at_epoch, weekly_pct, weekly_reset_at, limit_id,
                          sample_interval_seconds
                    FROM snapshots
                   WHERE scraped_at_epoch >= ? AND scraped_at_epoch <= ?
                   ORDER BY scraped_at_epoch""",
        (
            cycle_start - WEEKLY_RESET_BOUNDARY_MARGIN_SECONDS,
            target_epochs[-1] + WEEKLY_RESET_BOUNDARY_MARGIN_SECONDS,
        ),
    ).fetchall()
    snapshot_rows = [row for row in snapshots if isinstance(row["scraped_at_epoch"], int)]
    snapshot_epochs = [row["scraped_at_epoch"] for row in snapshot_rows]
    resolved: dict[int, tuple[str | None, str | None]] = {}
    for row in all_weekly:
        reset_at = row["reset_at_epoch"]
        observed_at = row["observed_at_epoch"]
        if isinstance(reset_at, int) and isinstance(observed_at, int):
            resolved[reset_at] = _snapshot_limit_id_around_reset(
                snapshots, reset_at, observed_at
            )
        else:
            resolved[reset_at] = (None, "ambiguous_limit")
    valid_resets = [
        row for row in all_weekly
        if isinstance(row["reset_at_epoch"], int) and resolved.get(row["reset_at_epoch"], (None, None))[0]
    ]
    if not valid_resets:
        return {
            row["reset_at_epoch"]: {
                "estimated_cycle_cost_usd": None,
                "extrapolated_100_value_usd": None,
                "cycle_cost_status": "unavailable",
                "cycle_cost_reason": resolved.get(row["reset_at_epoch"], (None, "ambiguous_limit"))[1] or "ambiguous_limit",
            }
            for row in reset_rows
        }
    first_start = min(row["reset_at_epoch"] for row in valid_resets)
    last_end = max(row["reset_at_epoch"] for row in valid_resets)
    events = _load_cost_events(connection, price_index(catalog), first_start, last_end)
    event_index = _event_index(events)
    previous_by_limit: dict[str, sqlite3.Row] = {}
    metrics: dict[int, dict[str, Any]] = {}
    valid_by_epoch = {row["reset_at_epoch"]: row for row in valid_resets}
    for current in all_weekly:
        reset_at = current["reset_at_epoch"]
        if reset_at not in valid_by_epoch:
            previous_by_limit.clear()
            metrics[reset_at] = {
                "estimated_cycle_cost_usd": None,
                "extrapolated_100_value_usd": None,
                "cycle_cost_status": "unavailable",
                "cycle_cost_reason": resolved.get(reset_at, (None, "ambiguous_limit"))[1] or "ambiguous_limit",
            }
            continue
        limit_id, resolution_reason = resolved[reset_at]
        previous = previous_by_limit.get(limit_id)
        previous_by_limit[limit_id] = current
        result: dict[str, Any] = {
            "estimated_cycle_cost_usd": None,
            "extrapolated_100_value_usd": None,
            "cycle_cost_status": "unavailable",
            "cycle_cost_reason": None,
        }
        if resolution_reason is not None or limit_id is None:
            previous_by_limit.clear()
            result["cycle_cost_reason"] = resolution_reason or "ambiguous_limit"
        elif previous is None:
            result["cycle_cost_reason"] = "incomplete_cycle"
        elif not _finite_quota_number(current["before_pct"]):
            result["cycle_cost_reason"] = "invalid_quota_pct"
        else:
            # A transient limit-id change between resets makes both endpoint
            # observations incomparable even if the IDs happen to return.
            left = bisect.bisect_right(snapshot_epochs, previous["reset_at_epoch"])
            right = bisect.bisect_left(snapshot_epochs, reset_at)
            transitions = {
                row["limit_id"] for row in snapshot_rows[left:right]
                if isinstance(row["limit_id"], str) and row["limit_id"]
            }
            if transitions and transitions != {limit_id}:
                result["cycle_cost_reason"] = "limit_transition"
            else:
                cost, reason, _polled = _interval_event_cost(
                    events, previous["reset_at_epoch"], reset_at, event_index
                )
                if reason is not None or cost is None:
                    result["cycle_cost_reason"] = reason or "no_events"
                else:
                    consumed = (100.0 - float(current["before_pct"])) / 100.0
                    result["estimated_cycle_cost_usd"] = round(cost, 8)
                    if consumed <= 0:
                        result["cycle_cost_reason"] = "zero_consumed_fraction"
                    elif consumed > 1:
                        result["cycle_cost_reason"] = "invalid_quota_pct"
                    elif float(current["before_pct"]) > 0:
                        result["extrapolated_100_value_usd"] = round(cost / consumed, 8)
                        result["cycle_cost_status"] = "good"
                    else:
                        result["cycle_cost_status"] = "complete"
                        result["cycle_cost_reason"] = "fully_consumed"
        metrics[reset_at] = result
    return {row["reset_at_epoch"]: metrics.get(row["reset_at_epoch"], {
        "estimated_cycle_cost_usd": None,
        "extrapolated_100_value_usd": None,
        "cycle_cost_status": "not_applicable",
        "cycle_cost_reason": "weekly_only",
    }) for row in reset_rows}


def selected_values(raw: str, *, name: str, allowed: Sequence[str] | None = None) -> tuple[str, ...]:
    if raw in ("", "all"):
        return ()
    values = tuple(dict.fromkeys(item.strip() for item in raw.split(",") if item.strip()))
    if not values or len(values) > 50 or any(len(item) > 200 or any(ord(character) < 32 for character in item) for item in values):
        raise AnalyticsError(f"{name} filter is invalid")
    if allowed is not None and any(item not in allowed for item in values):
        raise AnalyticsError(f"{name} must contain only {', '.join(allowed)}")
    return values


def token_conditions(start: int, end: int, sources: Sequence[str], models: Sequence[str]) -> tuple[str, list[Any]]:
    clauses = ["occurred_at_epoch >= ?", "occurred_at_epoch < ?"]
    values: list[Any] = [start, end]
    if sources:
        clauses.append(f"source IN ({', '.join('?' for _ in sources)})")
        values.extend(sources)
    if models:
        clauses.append(f"model IN ({', '.join('?' for _ in models)})")
        values.extend(models)
    return " AND ".join(clauses), values


def token_row(row: sqlite3.Row) -> dict[str, Any]:
    return {key: row[key] for key in row.keys()}


def billable_total(row: dict[str, Any]) -> int:
    """Return tokens billed by the API-equivalent formula.

    Reasoning is a sub-counter of output for all supported sources, so it is
    intentionally not added a second time here.
    """
    return sum(int(row.get(field, 0) or 0) for field in TOKEN_FIELDS[:4])


def normalize_token_counts(item: dict[str, Any]) -> dict[str, Any]:
    for field in TOKEN_FIELDS:
        item[field] = int(item.get(field, 0) or 0)
    item["total_tokens"] = billable_total(item)
    # Keep both names while clients migrate to the explicit field.
    item["total"] = item["total_tokens"]
    return item


def token_analytics(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    start: int,
    end: int,
    granularity: int,
    sources: Sequence[str],
    models: Sequence[str],
    breakdown_offset: int | None,
) -> tuple[dict[str, Any], list[str]]:
    conditions, values = token_conditions(start, end, sources, models)
    sums = ", ".join(f"SUM({field}) AS {field}" for field in TOKEN_FIELDS)
    breakdown_total = int(scalar(
        connection,
        f"SELECT COUNT(*) FROM (SELECT 1 FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model)",
        values,
    ) or 0)
    if breakdown_offset is None and breakdown_total > MAX_BREAKDOWN_ROWS:
        raise AnalyticsError(f"token breakdown exceeds the {MAX_BREAKDOWN_ROWS}-group response limit")
    last_page_offset = (
        ((breakdown_total - 1) // DEFAULT_BREAKDOWN_PAGE_SIZE) * DEFAULT_BREAKDOWN_PAGE_SIZE
        if breakdown_total else 0
    )
    effective_breakdown_offset = min(breakdown_offset or 0, last_page_offset)
    pricing_rows = connection.execute(
        f"SELECT provider, model, {sums}, COUNT(*) AS events "
        f"FROM token_usage_events WHERE {conditions} GROUP BY provider, model LIMIT ?",
        [*values, MAX_BREAKDOWN_ROWS + 1],
    )
    if breakdown_offset is None:
        breakdown_rows = connection.execute(
            f"SELECT source, provider, model, {sums}, COUNT(*) AS events "
            f"FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model ORDER BY source, model",
            values,
        )
    else:
        breakdown_rows = connection.execute(
            f"SELECT source, provider, model, {sums}, COUNT(*) AS events "
            f"FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model "
            "ORDER BY source, provider, model LIMIT ? OFFSET ?",
            [*values, DEFAULT_BREAKDOWN_PAGE_SIZE, effective_breakdown_offset],
        )
    prices = price_index(catalog)
    breakdown: list[dict[str, Any]] = []
    summary = {field: 0 for field in TOKEN_FIELDS}
    summary.update({
        "events": 0,
        "estimated_cost_usd": 0.0,
        "assumed_zero_tokens": 0,
        "total_tokens": 0,
        "total": 0,
    })
    unknown: list[str] = []
    for pricing_row_count, raw in enumerate(pricing_rows, start=1):
        if pricing_row_count > MAX_BREAKDOWN_ROWS:
            raise AnalyticsError(f"token pricing breakdown exceeds the {MAX_BREAKDOWN_ROWS}-group processing limit")
        item = token_row(raw)
        normalize_token_counts(item)
        for field in TOKEN_FIELDS:
            summary[field] += item[field]
        item["events"] = int(item["events"])
        summary["events"] += item["events"]
        cost, assumed_zero = cost_row(item, prices)
        item["estimated_cost_usd"] = round(cost, 8)
        item["cost_usd"] = item["estimated_cost_usd"]
        item["pricing_status"] = "assumed-zero" if assumed_zero else "priced"
        summary["estimated_cost_usd"] += cost
        summary["total_tokens"] += item["total_tokens"]
        if assumed_zero:
            summary["assumed_zero_tokens"] += item["total_tokens"]
            unknown.append(f"{item['provider']}/{item['model']}")

    for raw in breakdown_rows:
        item = token_row(raw)
        normalize_token_counts(item)
        item["events"] = int(item["events"])
        cost, assumed_zero = cost_row(item, prices)
        item["estimated_cost_usd"] = round(cost, 8)
        item["cost_usd"] = item["estimated_cost_usd"]
        item["pricing_status"] = "assumed-zero" if assumed_zero else "priced"
        item["application"] = item["source"]
        breakdown.append(item)
    summary["estimated_cost_usd"] = round(summary["estimated_cost_usd"], 8)
    summary["cost_usd"] = summary["estimated_cost_usd"]
    summary["total"] = summary["total_tokens"]

    # Compute cost at model granularity before folding into time buckets. A
    # single bucket can contain multiple providers/models with different
    # prices, so pricing an already-summed row would be incorrect.
    series_rows = connection.execute(
        f"SELECT (occurred_at_epoch / ?) * ? AS bucket_epoch, source, provider, model, {sums} "
        f"FROM token_usage_events WHERE {conditions} GROUP BY bucket_epoch, source, provider, model "
        "ORDER BY bucket_epoch, source, provider, model LIMIT ?",
        [granularity, granularity, *values, MAX_SERIES_GROUP_ROWS + 1],
    )
    buckets: dict[int, dict[str, Any]] = {}
    by_source: dict[str, dict[int, dict[str, Any]]] = {}
    for series_row_count, raw in enumerate(series_rows, start=1):
        if series_row_count > MAX_SERIES_GROUP_ROWS:
            raise AnalyticsError(f"token series exceeds the {MAX_SERIES_GROUP_ROWS}-group processing limit")
        item = token_row(raw)
        bucket_epoch = int(item.pop("bucket_epoch"))
        source = str(item.pop("source"))
        normalize_token_counts(item)
        cost, _assumed_zero = cost_row(item, prices)

        bucket = buckets.setdefault(bucket_epoch, {field: 0 for field in TOKEN_FIELDS})
        bucket["estimated_cost_usd"] = bucket.get("estimated_cost_usd", 0.0) + cost
        bucket["cost_usd"] = bucket["estimated_cost_usd"]
        source_buckets = by_source.setdefault(source, {})
        source_bucket = source_buckets.setdefault(bucket_epoch, {field: 0 for field in TOKEN_FIELDS})
        source_bucket["estimated_cost_usd"] = source_bucket.get("estimated_cost_usd", 0.0) + cost
        source_bucket["cost_usd"] = source_bucket["estimated_cost_usd"]
        for field in TOKEN_FIELDS:
            bucket[field] += item[field]
            source_bucket[field] += item[field]

    series = []
    for bucket_epoch in sorted(buckets):
        item = normalize_token_counts(buckets[bucket_epoch])
        item["estimated_cost_usd"] = round(item["estimated_cost_usd"], 8)
        item["cost_usd"] = item["estimated_cost_usd"]
        item["at"] = iso_utc(bucket_epoch)
        series.append(item)
    series_by_source = []
    for source in sorted(by_source):
        for bucket_epoch in sorted(by_source[source]):
            item = normalize_token_counts(by_source[source][bucket_epoch])
            item["estimated_cost_usd"] = round(item["estimated_cost_usd"], 8)
            item["cost_usd"] = item["estimated_cost_usd"]
            item["source"] = source
            item["application"] = source
            item["at"] = iso_utc(bucket_epoch)
            series_by_source.append(item)
    warnings = [f"No catalog price; assumed zero: {name}" for name in sorted(set(unknown))]
    result = {
        "summary": summary,
        "series": series,
        "series_by_source": series_by_source,
        "breakdown": breakdown,
    }
    if breakdown_offset is not None:
        result["breakdown_pagination"] = {
            "total": breakdown_total,
            "offset": effective_breakdown_offset,
            "limit": DEFAULT_BREAKDOWN_PAGE_SIZE,
        }
    return result, warnings


def limit_series(connection: sqlite3.Connection, start: int, end: int, granularity: int) -> dict[str, Any]:
    rows = connection.execute(
        """WITH bucketed AS (
                 SELECT scraped_at_epoch, five_h_pct, weekly_pct, weekly_reset_at,
                        (scraped_at_epoch / ?) * ? AS bucket_epoch
                   FROM snapshots
                  WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
             ), latest AS (
                 SELECT bucket_epoch, MAX(scraped_at_epoch) AS latest_epoch,
                        COUNT(*) AS samples
                   FROM bucketed
                  GROUP BY bucket_epoch
             )
             SELECT latest.bucket_epoch, snapshots.five_h_pct,
                    snapshots.weekly_pct, snapshots.weekly_reset_at, latest.samples
               FROM latest
               JOIN snapshots ON snapshots.scraped_at_epoch = latest.latest_epoch
              ORDER BY latest.bucket_epoch""",
        (granularity, granularity, start, end),
    ).fetchall()
    forecast_rows = connection.execute(
        """WITH bucketed AS (
                 SELECT scraped_at_epoch, generated_at_epoch,
                        chance_24h_pct, chance_6h_pct,
                        (scraped_at_epoch / ?) * ? AS bucket_epoch
                   FROM forecast_samples
                  WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
             ), latest AS (
                 SELECT bucket_epoch, MAX(scraped_at_epoch) AS latest_epoch,
                        COUNT(*) AS samples
                   FROM bucketed
                  GROUP BY bucket_epoch
             )
             SELECT latest.bucket_epoch, forecast_samples.generated_at_epoch,
                    forecast_samples.chance_24h_pct,
                    forecast_samples.chance_6h_pct, latest.samples
               FROM latest
               JOIN forecast_samples
                 ON forecast_samples.scraped_at_epoch = latest.latest_epoch
              ORDER BY latest.bucket_epoch""",
        (granularity, granularity, start, end),
    ).fetchall()
    forecasts_by_bucket = {int(row["bucket_epoch"]): row for row in forecast_rows}
    reset_markers = connection.execute(
        """
        SELECT window, reset_at_epoch, observed_at_epoch, before_pct, after_pct,
               detection_method
          FROM reset_events
         WHERE reset_at_epoch >= ? AND reset_at_epoch < ?
         ORDER BY reset_at_epoch
         LIMIT ?
        """,
        (start, end, MAX_RESET_MARKERS),
    ).fetchall()
    return {
        "samples": int(sum(row["samples"] for row in rows)),
        "forecast_samples": int(sum(row["samples"] for row in forecast_rows)),
        "series": [
            {
                "at": iso_utc(row["bucket_epoch"]),
                "five_h_pct": round(row["five_h_pct"], 3) if row["five_h_pct"] is not None else None,
                "weekly_pct": round(row["weekly_pct"], 3) if row["weekly_pct"] is not None else None,
                "ideal_weekly_pct": ideal_weekly_remaining(row["bucket_epoch"], row["weekly_reset_at"]),
                "forecast_chance_24h_pct": (
                    forecasts_by_bucket[int(row["bucket_epoch"])]["chance_24h_pct"]
                    if int(row["bucket_epoch"]) in forecasts_by_bucket else None
                ),
                "forecast_chance_6h_pct": (
                    forecasts_by_bucket[int(row["bucket_epoch"])]["chance_6h_pct"]
                    if int(row["bucket_epoch"]) in forecasts_by_bucket else None
                ),
                "forecast_generated_at": (
                    iso_utc(forecasts_by_bucket[int(row["bucket_epoch"])]["generated_at_epoch"])
                    if int(row["bucket_epoch"]) in forecasts_by_bucket else None
                ),
                "forecast_samples": (
                    forecasts_by_bucket[int(row["bucket_epoch"])]["samples"]
                    if int(row["bucket_epoch"]) in forecasts_by_bucket else 0
                ),
                "samples": row["samples"],
            }
            for row in rows
        ],
        "reset_markers": [
            {
                "window": row["window"],
                "at": iso_utc(row["reset_at_epoch"]),
                "observed_at": iso_utc(row["observed_at_epoch"]),
                "before_pct": row["before_pct"],
                "after_pct": row["after_pct"],
                "detection_method": row["detection_method"],
            }
            for row in reset_markers
        ],
    }


FORECAST_BEFORE_RESET_MAX_AGE_SECONDS = 45 * 60


def forecast_before_reset(
    connection: sqlite3.Connection, reset_at_epoch: int
) -> sqlite3.Row | None:
    return connection.execute(
        """
        SELECT scraped_at_epoch, chance_24h_pct, chance_6h_pct
          FROM forecast_samples
         WHERE scraped_at_epoch <= ?
           AND scraped_at_epoch > ?
         ORDER BY scraped_at_epoch DESC
         LIMIT 1
        """,
        (reset_at_epoch, reset_at_epoch - FORECAST_BEFORE_RESET_MAX_AGE_SECONDS),
    ).fetchone()


def reset_history(
    connection: sqlite3.Connection,
    start: int,
    end: int,
    kind: str,
    offset: int,
    limit: int,
    catalog: dict[str, Any] | None = None,
) -> dict[str, Any]:
    clauses, values = ["reset_at_epoch >= ?", "reset_at_epoch < ?"], [start, end]
    if kind != "all":
        clauses.append("window = ?")
        values.append(kind)
    where = " AND ".join(clauses)
    total = int(scalar(connection, f"SELECT COUNT(*) FROM reset_events WHERE {where}", values) or 0)
    weekly_rows = connection.execute(
        """SELECT reset_at_epoch, before_pct, after_pct, detection_method
             FROM reset_events
            WHERE reset_at_epoch >= ? AND reset_at_epoch < ? AND window = 'weekly'""",
        (start, end),
    ).fetchall()
    random_impacts = {
        row["reset_at_epoch"]: random_reset_impact(connection, row["reset_at_epoch"], row["before_pct"])
        for row in weekly_rows
        if row["detection_method"] == "random_observed"
    }
    random_summary = {
        "count": 0,
        "gained_vs_ideal_pct_points": 0.0,
        "lost_vs_ideal_pct_points": 0.0,
        "net_vs_ideal_pct_points": 0.0,
    }
    end_of_week_summary = {"count": 0, "unused_pct_points": 0.0}
    for weekly_row in weekly_rows:
        before = weekly_row["before_pct"]
        if weekly_row["detection_method"] == "random_observed":
            random_summary["count"] += 1
            _ideal, change = random_impacts[weekly_row["reset_at_epoch"]]
            if change is not None:
                random_summary["net_vs_ideal_pct_points"] += change
                if change >= 0:
                    random_summary["gained_vs_ideal_pct_points"] += change
                else:
                    random_summary["lost_vs_ideal_pct_points"] -= change
        else:
            end_of_week_summary["count"] += 1
            if isinstance(before, (int, float)) and before > 0:
                end_of_week_summary["unused_pct_points"] += float(before)
    for summary in (random_summary, end_of_week_summary):
        for key, value in tuple(summary.items()):
            if isinstance(value, float):
                summary[key] = round(value, 3)
    rows = connection.execute(
        f"SELECT * FROM reset_events WHERE {where} ORDER BY reset_at_epoch DESC LIMIT ? OFFSET ?",
        [*values, limit, offset],
    ).fetchall()
    forecast_by_reset = {
        row["reset_at_epoch"]: forecast_before_reset(connection, row["reset_at_epoch"])
        for row in rows
    }
    page_weekly_rows = [row for row in rows if row["window"] == "weekly"]
    cycle_metrics = (
        weekly_reset_cycle_metrics(connection, catalog, page_weekly_rows)
        if catalog is not None and page_weekly_rows else {}
    )
    return {
        "total": total,
        "weekly_total": len(weekly_rows),
        "weekly_summary": {"random": random_summary, "end_of_week": end_of_week_summary},
        "offset": offset,
        "limit": limit,
        "items": [
            {
                "window": row["window"],
                "category": "random" if row["detection_method"] == "random_observed" else "end_of_week" if row["window"] == "weekly" else "scheduled",
                "reset_at": iso_utc(row["reset_at_epoch"]),
                "observed_at": iso_utc(row["observed_at_epoch"]),
                "observation_delay_seconds": max(0, row["observed_at_epoch"] - row["reset_at_epoch"]),
                "before_pct": row["before_pct"],
                "after_pct": row["after_pct"],
                "forecast_chance_24h_pct": (
                    forecast_by_reset[row["reset_at_epoch"]]["chance_24h_pct"]
                    if forecast_by_reset[row["reset_at_epoch"]] is not None else None
                ),
                "forecast_chance_6h_pct": (
                    forecast_by_reset[row["reset_at_epoch"]]["chance_6h_pct"]
                    if forecast_by_reset[row["reset_at_epoch"]] is not None else None
                ),
                "forecast_sample_at": (
                    iso_utc(forecast_by_reset[row["reset_at_epoch"]]["scraped_at_epoch"])
                    if forecast_by_reset[row["reset_at_epoch"]] is not None else None
                ),
                "detection_method": row["detection_method"],
                "ideal_weekly_pace_pct": random_impacts.get(row["reset_at_epoch"], (None, None))[0],
                "pace_delta_pct_points": random_impacts.get(row["reset_at_epoch"], (None, None))[1],
                "unused_pct_points": round(float(row["before_pct"]), 3)
                if row["window"] == "weekly" and row["detection_method"] != "random_observed" and isinstance(row["before_pct"], (int, float)) and row["before_pct"] > 0
                else 0,
                "estimated_cycle_cost_usd": (
                    cycle_metrics.get(row["reset_at_epoch"], {}).get("estimated_cycle_cost_usd")
                    if row["window"] == "weekly" else None
                ),
                "extrapolated_100_value_usd": (
                    cycle_metrics.get(row["reset_at_epoch"], {}).get("extrapolated_100_value_usd")
                    if row["window"] == "weekly" else None
                ),
                "cycle_cost_status": (
                    cycle_metrics.get(row["reset_at_epoch"], {}).get("cycle_cost_status", "unavailable")
                    if row["window"] == "weekly" else "not_applicable"
                ),
                "cycle_cost_reason": (
                    cycle_metrics.get(row["reset_at_epoch"], {}).get("cycle_cost_reason", "incomplete_cycle")
                    if row["window"] == "weekly" else "weekly_only"
                ),
            }
            for row in rows
        ],
    }


def _freshness_state(timestamp: int | None, now: int, interval: int) -> tuple[int | None, str]:
    if timestamp is None:
        return None, "unknown"
    age = max(0, now - int(timestamp))
    return age, "stale" if age > max(interval * 2, interval + 60) else "fresh"


def collector_freshness(connection: sqlite3.Connection, now: int) -> dict[str, Any]:
    latest = scalar(connection, "SELECT MAX(scraped_at_epoch) FROM snapshots")
    interval = scalar(
        connection,
        """
        SELECT sample_interval_seconds
          FROM snapshots
         WHERE sample_interval_seconds IS NOT NULL
         ORDER BY scraped_at_epoch DESC
         LIMIT 1
        """,
    )
    try:
        interval_seconds = max(60, int(interval or 900))
    except (TypeError, ValueError):
        interval_seconds = 900
    limits_age, limits_status = _freshness_state(latest, now, interval_seconds)
    collectors = {}
    for row in connection.execute("SELECT * FROM collector_runs ORDER BY source"):
        success_epoch = row["last_success_at_epoch"]
        age, status = _freshness_state(success_epoch, now, interval_seconds)
        if row["status"] in ("disabled", "unavailable", "error"):
            status = row["status"]
        collectors[row["source"]] = {
            "enabled": bool(row["enabled"]),
            "status": row["status"],
            "last_attempt_at": iso_utc(row["last_attempt_at_epoch"]),
            "last_success_at": iso_utc(row["last_success_at_epoch"]),
            "last_error": redact_error(row["last_error"]),
            "source_schema": row["source_schema"],
            "age_seconds": age,
            "freshness_status": status,
        }
    return {
        "limits_last_sample_at": iso_utc(latest),
        "limits_age_seconds": limits_age,
        "limits_freshness_status": limits_status,
        "sample_interval_seconds": interval_seconds,
        "collectors": collectors,
    }


def hermes_baselines(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    results = []
    for row in connection.execute("SELECT state_key, state_json FROM collector_state WHERE source = 'hermes' AND state_key NOT IN ('initialized', 'tracking')"):
        try:
            value = json.loads(row["state_json"])
        except json.JSONDecodeError:
            continue
        baseline = value.get("baseline") if isinstance(value, dict) else None
        if not isinstance(baseline, dict):
            continue
        tokens = billable_total(baseline)
        if tokens:
            results.append({"key": row["state_key"], "tokens": tokens, "counters": baseline})
    return results


def build_payload(database: Path, pricing: Path, params: dict[str, str], *, now: int | None = None) -> dict[str, Any]:
    if not database.is_file():
        raise AnalyticsUnavailableError("analytics archive is not available yet")
    try:
        catalog = load_pricing(pricing)
    except (CollectorError, OSError, UnicodeError, ValueError) as exc:
        raise AnalyticsUnavailableError("pricing catalog cannot be read") from exc
    try:
        connection = connect_database(database, read_only=True)
    except (ArchiveCorruptionError, ArchiveSchemaError, OSError, sqlite3.DatabaseError) as exc:
        raise AnalyticsUnavailableError("analytics archive cannot be read") from exc
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("BEGIN")
        current = int(now if now is not None else datetime.now(timezone.utc).timestamp())
        start, end, range_label, granularity = period(connection, params, current)
        if "source" in params and "sources" in params or "model" in params and "models" in params:
            raise AnalyticsError("use either the singular or plural token filter")
        sources = selected_values(params.get("sources", params.get("source", "all")), name="source", allowed=SOURCES)
        models = selected_values(params.get("models", params.get("model", "")), name="model")
        reset_type = params.get("reset_type", "all")
        if reset_type not in ("all", "5h", "weekly"):
            raise AnalyticsError("reset_type must be all, 5h, or weekly")
        try:
            reset_offset = int(params.get("reset_offset", "0"))
            reset_limit = int(params.get("reset_limit", str(DEFAULT_RESET_PAGE_SIZE)))
        except ValueError as exc:
            raise AnalyticsError("reset pagination must use integers") from exc
        if reset_offset < 0 or not 1 <= reset_limit <= 100:
            raise AnalyticsError("reset_offset must be positive and reset_limit must be 1..100")
        breakdown_offset = None
        if "breakdown_offset" in params:
            try:
                breakdown_offset = int(params["breakdown_offset"])
            except ValueError as exc:
                raise AnalyticsError("breakdown_offset must be an integer") from exc
            if breakdown_offset < 0:
                raise AnalyticsError("breakdown_offset must be non-negative")

        tokens, warnings = token_analytics(
            connection,
            catalog,
            start,
            end,
            granularity,
            sources,
            models,
            breakdown_offset,
        )
        available_sources = [row[0] for row in connection.execute("SELECT DISTINCT source FROM token_usage_events ORDER BY source")]
        available_models_count = int(scalar(connection, "SELECT COUNT(DISTINCT model) FROM token_usage_events") or 0)
        if available_models_count > MAX_AVAILABLE_MODELS:
            raise AnalyticsError(f"available model list exceeds the {MAX_AVAILABLE_MODELS}-model response limit")
        available_models = [row[0] for row in connection.execute("SELECT DISTINCT model FROM token_usage_events ORDER BY model")]
        freshness = collector_freshness(connection, current)
        warnings.extend(
            f"{name} collector: {value['last_error']}"
            for name, value in freshness["collectors"].items()
            if value["status"] == "error" and value["last_error"]
        )
        return {
            "schema_version": 1,
            "period": {
                "range": range_label,
                "from": iso_utc(start),
                "to": iso_utc(end),
                "timezone": "Europe/Paris",
                "granularity_seconds": granularity,
                "sample_interval_seconds": freshness["sample_interval_seconds"],
            },
            "filters": {"sources": list(sources), "models": list(models), "reset_type": reset_type},
            "available": {"sources": available_sources, "models": available_models},
            "freshness": freshness,
            "limits": limit_series(connection, start, end, granularity),
            "weekly_limit_value": weekly_limit_value(
                connection,
                catalog,
                start,
                end,
                now=current,
                sample_interval_seconds=freshness["sample_interval_seconds"],
            ),
            "tokens": tokens,
            "resets": reset_history(connection, start, end, reset_type, reset_offset, reset_limit, catalog),
            "baselines": {"hermes": hermes_baselines(connection)},
            "pricing": {"currency": catalog["currency"], "as_of": catalog.get("as_of", "unknown"), "valuation_mode": catalog.get("valuation_mode", "current_catalog")},
            "warnings": warnings,
        }
    except AnalyticsError:
        raise
    except (ArchiveCorruptionError, ArchiveSchemaError, OSError, sqlite3.DatabaseError) as exc:
        raise AnalyticsUnavailableError("analytics archive query failed") from exc
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--pricing", required=True)
    parser.add_argument("--params", default="{}", help=argparse.SUPPRESS)
    parser.add_argument("--now", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        params = json.loads(args.params)
        if not isinstance(params, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in params.items()):
            raise AnalyticsError("params must be a string map")
        print(json.dumps(build_payload(Path(args.database), Path(args.pricing), params, now=args.now), separators=(",", ":")))
    except (AnalyticsError, json.JSONDecodeError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
