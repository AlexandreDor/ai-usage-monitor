#!/usr/bin/env python3
"""Benchmark backend loading with deterministic synthetic evidence only.

Run from any directory; the default report is test-results/backend-performance.json.
Three samples cover full requests with empty process caches, selective base
requests, and weekly requests warmed by the final full request. Median budgets
are deliberately generous (15/3/3 seconds) to catch gross loading regressions
without treating shared CI hardware noise as a product regression. SQLite's
filesystem cache is not flushed. This does not benchmark production archives,
network transfer, browser rendering, or the old implementation.
"""

from __future__ import annotations

import argparse
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
from statistics import median
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "local"))
import analytics
from analytics_cache import AnalyticsCache
from storage import connect_database
from token_usage import load_pricing


TOKEN_COUNT = 50_000
SNAPSHOT_COUNT = 1_800
CADENCE = 900
BASE = 1_700_000_000
SAMPLES = 3
MODELS = ("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna")
BUDGETS = {"full_cold": 15.0, "base": 3.0, "weekly_warm": 3.0}


def create_fixture(database: Path, pricing: Path) -> dict:
    """Create coherent quota cycles with varying, identifiable model mixes."""
    pricing.write_bytes((ROOT / "local/pricing.json").read_bytes())
    prices = analytics.price_index(load_pricing(pricing))
    duration = (SNAPSHOT_COUNT - 1) * CADENCE
    bucket_costs = [[0.0] * len(MODELS) for _ in range(SNAPSHOT_COUNT)]
    mixes = ((7, 2, 1), (1, 7, 2), (2, 1, 7), (4, 4, 2), (2, 4, 4), (4, 2, 4))
    events = []
    for index in range(TOKEN_COUNT):
        at = BASE + index * duration // TOKEN_COUNT
        bucket = (at - BASE) // CADENCE
        weights = mixes[(bucket // 16) % len(mixes)]
        choice = index % 10
        model_index = 0 if choice < weights[0] else 1 if choice < weights[0] + weights[1] else 2
        model = MODELS[model_index]
        input_tokens = 300 + index * 37 % 801
        output_tokens = 50 + index * 13 % 91
        row = {"occurred_at_epoch": at, "provider": "openai", "model": model,
               "input_tokens": input_tokens, "cache_read_tokens": 0,
               "cache_write_tokens": 0, "output_tokens": output_tokens}
        cost, reason = analytics._event_cost(row, prices)
        if reason is not None or cost is None:
            raise AssertionError("synthetic models must have valid positive prices")
        bucket_costs[bucket][model_index] += cost
        source = analytics.SOURCES[index % len(analytics.SOURCES)]
        events.append((at, source, "openai", model, input_tokens, output_tokens, f"synthetic-{index}"))

    buckets_per_week = analytics.WEEKLY_WINDOW_SECONDS // CADENCE
    first_week_cost = sum(sum(costs) for costs in bucket_costs[:buckets_per_week])
    model_values = [first_week_cost * multiplier for multiplier in (1.3, 1.8, 2.3)]
    snapshots, resets = [], []
    consumed = 0.0
    for index in range(SNAPSHOT_COUNT):
        at = BASE + index * CADENCE
        if index:
            consumed += sum(cost / value for cost, value in zip(bucket_costs[index - 1], model_values))
        if index and index % buckets_per_week == 0:
            resets.append(("weekly", at, at, round(100 * (1 - consumed), 3), 100.0, "scheduled_crossing"))
            consumed = 0.0
        remaining = 100 * (1 - consumed)
        if not 0 <= remaining <= 100:
            raise AssertionError("synthetic quota must stay within a coherent weekly cycle")
        deadline = BASE + (index // buckets_per_week + 1) * analytics.WEEKLY_WINDOW_SECONDS
        snapshots.append((at, analytics.iso_utc(at), 80.0, None, at + 18_000,
                          round(remaining, 3), None, deadline, CADENCE, 192,
                          "limit-" + "a" * 64))

    with closing(connect_database(database)) as connection, connection:
        connection.executemany(
            """INSERT INTO token_usage_events
               (occurred_at_epoch, source, provider, model, input_tokens, output_tokens, external_id)
               VALUES (?, ?, ?, ?, ?, ?, ?)""", events,
        )
        connection.executemany("INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", snapshots)
        connection.executemany("INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)", resets)
    return {"token_events": len(events), "snapshots": len(snapshots), "weekly_resets": len(resets),
            "models": len(MODELS), "sources": len(analytics.SOURCES), "archive_bytes": database.stat().st_size}


def measure(action) -> tuple[dict, float]:
    start = time.perf_counter()
    payload = action()
    return payload, time.perf_counter() - start


def encoded_size(payload: dict) -> int:
    return len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))


def close_fixture_observer(database: Path) -> None:
    """Release the benchmark's persistent observer before temporary cleanup."""
    monitor = analytics.SNAPSHOT_REVISIONS
    with monitor._lock:
        observer = monitor._observers.pop(str(database.resolve()), None)
        if observer is not None:
            observer[1].close()


def run() -> dict:
    report = {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
              "samples_per_scenario": SAMPLES, "budgets_seconds": BUDGETS,
              "fixture": {}, "timings": {}, "response_bytes": {}, "checks": {}, "passed": False}
    with tempfile.TemporaryDirectory(prefix="codex-analytics-benchmark-") as private_dir:
        database, pricing = Path(private_dir) / "archive.sqlite3", Path(private_dir) / "pricing.json"
        try:
            report["fixture"] = create_fixture(database, pricing)
            now = BASE + (SNAPSHOT_COUNT - 1) * CADENCE + 1
            params = {"range": "30d", "at": str(now)}
            def payload(section=None):
                selected = params if section is None else {**params, "sections": section}
                return analytics.build_payload(database, pricing, selected, now=now)

            durations = {name: [] for name in BUDGETS}
            for _ in range(SAMPLES):
                # Fresh result/regression caches make every full sample cold.
                analytics.WEEKLY_CACHE = AnalyticsCache(max_entries=16)
                analytics.REGRESSION_CACHE = AnalyticsCache(max_entries=2048, max_bytes=8 * 1024 * 1024)
                full, elapsed = measure(payload)
                durations["full_cold"].append(elapsed)
            for _ in range(SAMPLES):
                base, elapsed = measure(lambda: payload("base"))
                durations["base"].append(elapsed)
                if base["tokens"] != full["tokens"] or base["limits"] != full["limits"]:
                    raise AssertionError("selective base metrics differ from full metrics")
            report["checks"]["base_matches_full"] = True
            for _ in range(SAMPLES):
                weekly, elapsed = measure(lambda: payload("weekly"))
                durations["weekly_warm"].append(elapsed)
                if weekly["weekly_limit_value"] != full["weekly_limit_value"]:
                    raise AssertionError("warm weekly metrics differ from cold full metrics")
            report["checks"]["warm_weekly_matches_full"] = True

            old_input = base["tokens"]["summary"]["input_tokens"]
            with closing(connect_database(database)) as writer, writer:
                writer.execute("""INSERT INTO token_usage_events
                    (occurred_at_epoch, source, provider, model, input_tokens, external_id)
                    VALUES (?, 'codex', 'openai', ?, 12345, 'synthetic-invalidation')""",
                               (now - 2, MODELS[0]))
            changed = payload("base")
            changed_weekly = payload("weekly")
            if changed["revision"] == base["revision"] or changed["tokens"]["summary"]["input_tokens"] != old_input + 12345:
                raise AssertionError("a committed token row did not invalidate the archive revision")
            if changed_weekly["revision"] == weekly["revision"] or changed_weekly["weekly_limit_value"] == weekly["weekly_limit_value"]:
                raise AssertionError("a committed token row did not invalidate weekly result work")
            report["checks"]["committed_row_invalidates"] = True
            report["response_bytes"] = {"full": encoded_size(full), "base": encoded_size(base), "weekly": encoded_size(weekly)}
            report["timings"] = {
                name: {"samples_seconds": [round(value, 6) for value in values],
                       "median_seconds": round(median(values), 6), "budget_passed": median(values) < BUDGETS[name]}
                for name, values in durations.items()
            }
            report["passed"] = all(value["budget_passed"] for value in report["timings"].values())
        except Exception as exc:
            # Never expose fixture paths, archive payloads, or user diagnostics.
            report["error_type"] = type(exc).__name__
        finally:
            close_fixture_observer(database)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "test-results/backend-performance.json")
    args = parser.parse_args()
    report = run()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # The public artifact contains only synthetic counts, sizes, and timings.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent,
                                     prefix=".backend-performance-", delete=False) as temporary:
        json.dump(report, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    temporary_path.replace(args.output)
    print(json.dumps(report, separators=(",", ":"), sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
