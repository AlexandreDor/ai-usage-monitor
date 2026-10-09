"""Bounded CSV exports of the same filtered data used by Analytics."""

from __future__ import annotations

import csv
import io
import time
from pathlib import Path
from typing import Any

from analytics import AnalyticsError, AnalyticsUnavailableError, build_payload

MAX_EXPORT_ROWS = 10_000
MAX_EXPORT_BYTES = 16 * 1024 * 1024
TOKEN_COLUMNS = ("input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "estimated_cost_usd")
LIMIT_COLUMNS = ("at", "five_h_pct", "weekly_pct", "ideal_weekly_pct", "forecast_chance_24h_pct", "forecast_chance_6h_pct", "forecast_generated_at", "samples")
WEEKLY_COLUMNS = ("at", "model", "providers", "observed_cost_usd", "quota_consumed_pct_points", "raw_value_usd", "value_usd", "quality", "reason", "inferred", "carried", "source_at", "source_age_seconds", "source_method", "value_lower_usd", "value_upper_usd", "high_uncertainty")
RESET_COLUMNS = ("window", "category", "reset_at", "observed_at", "before_pct", "after_pct", "detection_method", "forecast_chance_24h_pct", "forecast_chance_6h_pct", "estimated_cycle_cost_usd", "extrapolated_100_value_usd", "cycle_cost_status", "cycle_cost_reason")
DATASET_SECTIONS = {"limits": "base", "tokens": "breakdown", "weekly_value": "weekly", "breakdown": "breakdown", "resets": "resets"}


def safe_cell(value: Any) -> Any:
    """Keep numeric values numeric and neutralize spreadsheet formulas in text."""
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        value = ", ".join(str(item) for item in value)
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def build_csv(database: Path, pricing: Path, params: dict[str, str], dataset: str,
              *, now: int | None = None) -> bytes:
    if dataset not in DATASET_SECTIONS:
        raise AnalyticsError("dataset must be limits, tokens, weekly_value, breakdown, or resets")
    current = int(time.time() if now is None else now)
    query = dict(params)
    query.pop("compare", None)
    query.pop("breakdown_offset", None)
    query.pop("reset_offset", None)
    query["sections"] = DATASET_SECTIONS[dataset]
    query["reset_limit"] = "100"
    payload = build_payload(database, pricing, query, now=current)
    if dataset == "limits":
        columns, rows = LIMIT_COLUMNS, payload["limits"]["series"]
    elif dataset == "tokens":
        columns = ("at", "source", *TOKEN_COLUMNS)
        tokens = payload["tokens"]
        rows = tokens.get("series_by_source") or [dict(row, source="all") for row in tokens["series"]]
    elif dataset == "breakdown":
        columns = ("source", "provider", "model", *TOKEN_COLUMNS, "pricing_status", "events")
        rows = payload["tokens"]["breakdown"]
    elif dataset == "weekly_value":
        columns = WEEKLY_COLUMNS
        data = payload["weekly_limit_value"]
        rows = [dict(row, model="all", providers=[]) for row in data["series"]]
        for model in data.get("by_model", []):
            rows.extend(dict(row, model=model.get("model", ""), providers=model.get("providers", []))
                        for row in model.get("series", []))
    else:
        columns = RESET_COLUMNS
        resets = payload["resets"]
        if resets["total"] > MAX_EXPORT_ROWS:
            raise AnalyticsError(f"CSV export exceeds {MAX_EXPORT_ROWS} rows; choose a shorter period")
        rows = list(resets["items"])
        revision = payload.get("revision")
        while len(rows) < resets["total"]:
            query["reset_offset"] = str(len(rows))
            page = build_payload(database, pricing, query, now=current)
            if page.get("revision") != revision:
                raise AnalyticsUnavailableError("analytics archive changed during export; retry")
            items = page["resets"]["items"]
            if not items:
                raise AnalyticsUnavailableError("analytics archive changed during export; retry")
            rows.extend(items)
    if len(rows) > MAX_EXPORT_ROWS:
        raise AnalyticsError(f"CSV export exceeds {MAX_EXPORT_ROWS} rows; choose a shorter period")
    stream = io.StringIO(newline="")
    writer = csv.writer(stream)
    writer.writerow(columns)
    for row in rows:
        writer.writerow(safe_cell(row.get(column)) for column in columns)
        if stream.tell() > MAX_EXPORT_BYTES:
            raise AnalyticsError("CSV export is too large; choose a shorter period")
    body = stream.getvalue().encode("utf-8-sig")
    if len(body) > MAX_EXPORT_BYTES:
        raise AnalyticsError("CSV export is too large; choose a shorter period")
    return body
