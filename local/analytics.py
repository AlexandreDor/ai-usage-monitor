#!/usr/bin/env python3
"""Read-only aggregation for the local advanced analytics page."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import sys
from typing import Any, Iterable, Sequence
from zoneinfo import ZoneInfo

from storage import connect_database
from token_usage import load_pricing


PARIS = ZoneInfo("Europe/Paris")
RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400, "1y": 365 * 86400}
SOURCES = ("codex", "opencode", "hermes")
TOKEN_FIELDS = ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens")
WEEKLY_WINDOW_SECONDS = 7 * 86400


class AnalyticsError(ValueError):
    """Invalid query or unavailable analytics archive."""


def iso_utc(epoch: int | None) -> str | None:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z") if epoch is not None else None


def parse_day(raw: str, *, end: bool) -> int:
    try:
        value = datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=PARIS)
    except ValueError as exc:
        raise AnalyticsError("dates must use YYYY-MM-DD") from exc
    if end:
        value += timedelta(days=1)
    return int(value.timestamp())


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


def random_reset_impact(connection: sqlite3.Connection, reset_at: int, after: Any) -> tuple[float | None, float | None, float | None]:
    ideal = ideal_weekly_pace(connection, reset_at)
    if not isinstance(after, (int, float)) or ideal is None:
        return ideal, None, None
    delta = round(float(after) - ideal, 3)
    relative = round(100 * delta / ideal, 3) if ideal > 0 else None
    return ideal, delta, relative


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
    # Match the archive's compaction schedule instead of reducing a 30-day
    # view to one point per day. This preserves the useful 15/30-minute and
    # hourly detail while keeping an unbounded "all" request manageable.
    granularity = 900 if duration <= 86400 else 1800 if duration <= 7 * 86400 else 3600 if duration <= 366 * 86400 else 86400
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


def token_analytics(
    connection: sqlite3.Connection,
    catalog: dict[str, Any],
    start: int,
    end: int,
    granularity: int,
    sources: Sequence[str],
    models: Sequence[str],
) -> tuple[dict[str, Any], list[str]]:
    conditions, values = token_conditions(start, end, sources, models)
    sums = ", ".join(f"SUM({field}) AS {field}" for field in TOKEN_FIELDS)
    breakdown_rows = connection.execute(
        f"SELECT source, provider, model, {sums}, COUNT(*) AS events FROM token_usage_events WHERE {conditions} GROUP BY source, provider, model ORDER BY source, model",
        values,
    ).fetchall()
    prices = price_index(catalog)
    breakdown: list[dict[str, Any]] = []
    summary = {field: 0 for field in TOKEN_FIELDS}
    summary.update({"events": 0, "estimated_cost_usd": 0.0, "assumed_zero_tokens": 0})
    unknown: list[str] = []
    for raw in breakdown_rows:
        item = token_row(raw)
        for field in TOKEN_FIELDS:
            item[field] = int(item[field] or 0)
            summary[field] += item[field]
        item["events"] = int(item["events"])
        summary["events"] += item["events"]
        cost, assumed_zero = cost_row(item, prices)
        item["estimated_cost_usd"] = round(cost, 8)
        item["pricing_status"] = "assumed-zero" if assumed_zero else "priced"
        summary["estimated_cost_usd"] += cost
        if assumed_zero:
            zero_tokens = item["input_tokens"] + item["cache_read_tokens"] + item["cache_write_tokens"] + item["output_tokens"]
            summary["assumed_zero_tokens"] += zero_tokens
            unknown.append(f"{item['provider']}/{item['model']}")
        breakdown.append(item)
    summary["estimated_cost_usd"] = round(summary["estimated_cost_usd"], 8)

    series_rows = connection.execute(
        f"SELECT (occurred_at_epoch / ?) * ? AS bucket_epoch, {sums} FROM token_usage_events WHERE {conditions} GROUP BY bucket_epoch ORDER BY bucket_epoch",
        [granularity, granularity, *values],
    ).fetchall()
    series = []
    for raw in series_rows:
        item = token_row(raw)
        item["at"] = iso_utc(item.pop("bucket_epoch"))
        for field in TOKEN_FIELDS:
            item[field] = int(item[field] or 0)
        series.append(item)
    warnings = [f"No catalog price; assumed zero: {name}" for name in sorted(set(unknown))]
    return {"summary": summary, "series": series, "breakdown": breakdown}, warnings


def limit_series(connection: sqlite3.Connection, start: int, end: int, granularity: int) -> dict[str, Any]:
    rows = connection.execute(
        """SELECT (scraped_at_epoch / ?) * ? AS bucket_epoch,
                  AVG(five_h_pct) AS five_h_pct, AVG(weekly_pct) AS weekly_pct,
                  COUNT(*) AS samples
             FROM snapshots
            WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?
            GROUP BY bucket_epoch ORDER BY bucket_epoch""",
        (granularity, granularity, start, end),
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
        row["reset_at_epoch"]: random_reset_impact(connection, row["reset_at_epoch"], row["after_pct"])
        for row in weekly_rows
        if row["detection_method"] == "random_observed"
    }
    random_summary = {
        "count": 0,
        "gained_vs_ideal_pct": 0.0,
        "lost_vs_ideal_pct": 0.0,
        "net_vs_ideal_pct": 0.0,
        "gained_vs_ideal_pct_points": 0.0,
        "lost_vs_ideal_pct_points": 0.0,
        "net_vs_ideal_pct_points": 0.0,
    }
    end_of_week_summary = {"count": 0, "unused_pct_points": 0.0}
    for weekly_row in weekly_rows:
        before, after = weekly_row["before_pct"], weekly_row["after_pct"]
        if weekly_row["detection_method"] == "random_observed":
            random_summary["count"] += 1
            _ideal, change, relative = random_impacts[weekly_row["reset_at_epoch"]]
            if change is not None:
                random_summary["net_vs_ideal_pct"] += relative or 0
                random_summary["net_vs_ideal_pct_points"] += change
                if change >= 0:
                    random_summary["gained_vs_ideal_pct"] += relative or 0
                    random_summary["gained_vs_ideal_pct_points"] += change
                else:
                    random_summary["lost_vs_ideal_pct"] -= relative or 0
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
                "ideal_weekly_pace_pct": random_impacts.get(row["reset_at_epoch"], (None, None, None))[0],
                "pace_delta_pct_points": random_impacts.get(row["reset_at_epoch"], (None, None, None))[1],
                "pace_delta_vs_ideal_pct": random_impacts.get(row["reset_at_epoch"], (None, None, None))[2],
                "unused_pct_points": round(float(row["before_pct"]), 3)
                if row["window"] == "weekly" and row["detection_method"] != "random_observed" and isinstance(row["before_pct"], (int, float)) and row["before_pct"] > 0
                else 0,
            }
            for row in rows
        ],
    }


def collector_freshness(connection: sqlite3.Connection) -> dict[str, Any]:
    latest = scalar(connection, "SELECT MAX(scraped_at_epoch) FROM snapshots")
    collectors = {}
    for row in connection.execute("SELECT * FROM collector_runs ORDER BY source"):
        collectors[row["source"]] = {
            "enabled": bool(row["enabled"]),
            "status": row["status"],
            "last_attempt_at": iso_utc(row["last_attempt_at_epoch"]),
            "last_success_at": iso_utc(row["last_success_at_epoch"]),
            "last_error": row["last_error"],
            "source_schema": row["source_schema"],
        }
    return {"limits_last_sample_at": iso_utc(latest), "collectors": collectors}


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
        tokens = sum(int(baseline.get(field, 0) or 0) for field in TOKEN_FIELDS)
        if tokens:
            results.append({"key": row["state_key"], "tokens": tokens, "counters": baseline})
    return results


def build_payload(database: Path, pricing: Path, params: dict[str, str], *, now: int | None = None) -> dict[str, Any]:
    if not database.is_file():
        raise AnalyticsError("analytics archive is not available yet")
    catalog = load_pricing(pricing)
    try:
        connection = connect_database(database, read_only=True)
    except (OSError, sqlite3.DatabaseError) as exc:
        raise AnalyticsError(f"analytics archive cannot be read: {exc}") from exc
    connection.row_factory = sqlite3.Row
    try:
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
            reset_limit = int(params.get("reset_limit", "25"))
        except ValueError as exc:
            raise AnalyticsError("reset pagination must use integers") from exc
        if reset_offset < 0 or not 1 <= reset_limit <= 100:
            raise AnalyticsError("reset_offset must be positive and reset_limit must be 1..100")

        tokens, warnings = token_analytics(connection, catalog, start, end, granularity, sources, models)
        available_sources = [row[0] for row in connection.execute("SELECT DISTINCT source FROM token_usage_events ORDER BY source")]
        available_models = [row[0] for row in connection.execute("SELECT DISTINCT model FROM token_usage_events ORDER BY model")]
        freshness = collector_freshness(connection)
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
            },
            "filters": {"sources": list(sources), "models": list(models), "reset_type": reset_type},
            "available": {"sources": available_sources, "models": available_models},
            "freshness": freshness,
            "limits": limit_series(connection, start, end, granularity),
            "tokens": tokens,
            "resets": reset_history(connection, start, end, reset_type, reset_offset, reset_limit),
            "baselines": {"hermes": hermes_baselines(connection)},
            "pricing": {"currency": catalog["currency"], "as_of": catalog["as_of"], "valuation_mode": catalog.get("valuation_mode", "current_catalog")},
            "warnings": warnings,
        }
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
