#!/usr/bin/env python3
"""Read-only aggregation for the local advanced analytics page."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys
from typing import Any, Iterable, Sequence
from zoneinfo import ZoneInfo

from storage import ArchiveCorruptionError, ArchiveSchemaError, connect_database
from token_usage import CollectorError, load_pricing


PARIS = ZoneInfo("Europe/Paris")
RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400, "1y": 365 * 86400}
SOURCES = ("codex", "opencode", "hermes")
TOKEN_FIELDS = ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens")
WEEKLY_WINDOW_SECONDS = 7 * 86400
MAX_SERIES_POINTS = 10_000
MAX_RESET_MARKERS = 2_000
DEFAULT_RESET_PAGE_SIZE = 50
DEFAULT_BREAKDOWN_PAGE_SIZE = 50
MAX_BREAKDOWN_PAGE_SIZE = 100
MAX_AVAILABLE_MODELS = 500
SQLITE_MAX_INTEGER = 2**63 - 1
BREAKDOWN_OFFSET_KEYS = ("breakdown_offset", "token_breakdown_offset", "token_offset", "offset")
BREAKDOWN_LIMIT_KEYS = ("breakdown_limit", "token_breakdown_limit", "token_limit", "limit")
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


def pricing_fingerprint(catalog: dict[str, Any]) -> str:
    """Return a stable SHA-256 for the validated catalog contents."""
    canonical = json.dumps(catalog, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


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


def selected_values(raw: str, *, name: str, allowed: Sequence[str] | None = None) -> tuple[str, ...]:
    if raw in ("", "all"):
        return ()
    values = tuple(dict.fromkeys(item.strip() for item in raw.split(",") if item.strip()))
    if not values or len(values) > 50 or any(len(item) > 200 or any(ord(character) < 32 for character in item) for item in values):
        raise AnalyticsError(f"{name} filter is invalid")
    if allowed is not None and any(item not in allowed for item in values):
        raise AnalyticsError(f"{name} must contain only {', '.join(allowed)}")
    return values


def normalize_params(params: Any) -> dict[str, str]:
    """Normalize direct callers while retaining a useful duplicate error."""
    if not isinstance(params, dict):
        raise AnalyticsError("params must be a string map")
    normalized: dict[str, str] = {}
    for key, value in params.items():
        if not isinstance(key, str):
            raise AnalyticsError("params must be a string map")
        if isinstance(value, str):
            normalized[key] = value
            continue
        if isinstance(value, (list, tuple)):
            if len(value) != 1:
                raise AnalyticsError("query parameters must not be repeated")
            value = value[0]
        if not isinstance(value, str):
            raise AnalyticsError("params must be a string map")
        normalized[key] = value
    return normalized


def pagination_parameter(params: dict[str, str], aliases: Sequence[str], name: str) -> str | None:
    present = [key for key in aliases if key in params]
    if len(present) > 1:
        raise AnalyticsError(f"{name} pagination parameters are contradictory")
    return params[present[0]] if present else None


def breakdown_pagination(params: dict[str, str]) -> tuple[int | None, int]:
    raw_offset = pagination_parameter(params, BREAKDOWN_OFFSET_KEYS, "breakdown offset")
    raw_limit = pagination_parameter(params, BREAKDOWN_LIMIT_KEYS, "breakdown limit")
    if raw_offset is None and raw_limit is None:
        return None, DEFAULT_BREAKDOWN_PAGE_SIZE
    try:
        offset = int(raw_offset) if raw_offset is not None else 0
        limit = int(raw_limit) if raw_limit is not None else DEFAULT_BREAKDOWN_PAGE_SIZE
    except (TypeError, ValueError) as exc:
        raise AnalyticsError("breakdown pagination must use integers") from exc
    if offset < 0 or offset > SQLITE_MAX_INTEGER:
        raise AnalyticsError("breakdown_offset must be between 0 and 9223372036854775807")
    if not 1 <= limit <= MAX_BREAKDOWN_PAGE_SIZE:
        raise AnalyticsError("breakdown_limit must be 1..100")
    return offset, limit


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
    breakdown_offset: int | None = None,
    breakdown_limit: int = DEFAULT_BREAKDOWN_PAGE_SIZE,
) -> tuple[dict[str, Any], list[str]]:
    conditions, values = token_conditions(start, end, sources, models)
    sums = ", ".join(f"SUM({field}) AS {field}" for field in TOKEN_FIELDS)
    breakdown_paginated = breakdown_offset is not None
    breakdown_count = int(scalar(
        connection,
        f"SELECT COUNT(*) FROM (SELECT 1 FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model)",
        values,
    ) or 0)
    breakdown_query = (
        f"SELECT source, provider, model, {sums}, COUNT(*) AS events "
        f"FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model ORDER BY source, provider, model"
    )
    breakdown_parameters: list[Any] = list(values)
    if breakdown_paginated:
        breakdown_query += " LIMIT ? OFFSET ?"
        breakdown_parameters.extend((breakdown_limit, breakdown_offset))
    breakdown_rows = connection.execute(breakdown_query, breakdown_parameters).fetchall()
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

    def add_to_summary(item: dict[str, Any]) -> None:
        for field in TOKEN_FIELDS:
            summary[field] += item[field]
        item["events"] = int(item["events"])
        summary["events"] += item["events"]
        cost, assumed_zero = cost_row(item, prices)
        summary["estimated_cost_usd"] += cost
        summary["total_tokens"] += item["total_tokens"]
        if assumed_zero:
            summary["assumed_zero_tokens"] += item["total_tokens"]
            unknown.append(f"{item['provider']}/{item['model']}")

    if breakdown_paginated:
        # A paginated response still reports totals for the complete filtered
        # period. Aggregate by priced identity without materializing every
        # breakdown row in the response.
        summary_rows = connection.execute(
            f"SELECT provider, model, {sums}, COUNT(*) AS events "
            f"FROM token_usage_events WHERE {conditions} GROUP BY provider, model ORDER BY provider, model",
            values,
        ).fetchall()
        for raw in summary_rows:
            item = token_row(raw)
            normalize_token_counts(item)
            add_to_summary(item)

    for raw in breakdown_rows:
        item = token_row(raw)
        normalize_token_counts(item)
        if not breakdown_paginated:
            add_to_summary(item)
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
        "ORDER BY bucket_epoch, source, provider, model",
        [granularity, granularity, *values],
    ).fetchall()
    buckets: dict[int, dict[str, Any]] = {}
    by_source: dict[str, dict[int, dict[str, Any]]] = {}
    for raw in series_rows:
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
    result: dict[str, Any] = {
        "summary": summary,
        "series": series,
        "series_by_source": series_by_source,
        "breakdown": breakdown,
    }
    if breakdown_paginated:
        result["breakdown_pagination"] = {
            "offset": breakdown_offset,
            "limit": breakdown_limit,
            "total": breakdown_count,
        }
    return result, warnings


def limit_series(connection: sqlite3.Connection, start: int, end: int, granularity: int) -> dict[str, Any]:
    rows = connection.execute(
        """WITH bucketed AS (
                 SELECT scraped_at_epoch, five_h_pct, weekly_pct,
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
                    snapshots.weekly_pct, latest.samples
               FROM latest
               JOIN snapshots ON snapshots.scraped_at_epoch = latest.latest_epoch
              ORDER BY latest.bucket_epoch""",
        (granularity, granularity, start, end),
    ).fetchall()
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
        "series": [
            {
                "at": iso_utc(row["bucket_epoch"]),
                "five_h_pct": round(row["five_h_pct"], 3) if row["five_h_pct"] is not None else None,
                "weekly_pct": round(row["weekly_pct"], 3) if row["weekly_pct"] is not None else None,
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


def reset_history(connection: sqlite3.Connection, start: int, end: int, kind: str, offset: int, limit: int) -> dict[str, Any]:
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
                "detection_method": row["detection_method"],
                "ideal_weekly_pace_pct": random_impacts.get(row["reset_at_epoch"], (None, None))[0],
                "pace_delta_pct_points": random_impacts.get(row["reset_at_epoch"], (None, None))[1],
                "unused_pct_points": round(float(row["before_pct"]), 3)
                if row["window"] == "weekly" and row["detection_method"] != "random_observed" and isinstance(row["before_pct"], (int, float)) and row["before_pct"] > 0
                else 0,
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
        params = normalize_params(params)
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

        breakdown_offset, breakdown_limit = breakdown_pagination(params)
        tokens, warnings = token_analytics(
            connection,
            catalog,
            start,
            end,
            granularity,
            sources,
            models,
            breakdown_offset,
            breakdown_limit,
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
        catalog_hash = pricing_fingerprint(catalog)
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
            "tokens": tokens,
            "resets": reset_history(connection, start, end, reset_type, reset_offset, reset_limit),
            "baselines": {"hermes": hermes_baselines(connection)},
            "pricing": {
                "currency": catalog["currency"],
                "as_of": catalog.get("as_of", "unknown"),
                "valuation_mode": catalog.get("valuation_mode", "current_catalog"),
                "sha256": catalog_hash,
                "catalog_sha256": catalog_hash,
            },
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
