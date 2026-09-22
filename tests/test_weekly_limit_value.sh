#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

database="${TEST_ROOT}/weekly-value.sqlite3"
window_seconds=43200
base_epoch=1000000000
python3 - "$ROOT_DIR" "$database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

db = Path(sys.argv[2])
with connect_database(db) as connection:
    window = 43200
    base = 1000000000

    def snapshot(epoch, weekly, limit_id="limit-a", deadline=1000100000):
        connection.execute(
            "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (epoch, f"2001-09-09T00:00:{epoch % 60:02d}Z", 80, None, None, weekly, None, deadline, 900, 192, limit_id),
        )

    deadline = base + 20 * window
    snapshot(base, 100, deadline=deadline)
    snapshot(base + window, 98, deadline=deadline)
    # Keep a close pre-reset boundary observation; reset-boundary rules remain
    # tied to the local cadence even though value windows span twelve hours.
    snapshot(base + 2 * window - 900, 98, deadline=deadline)
    snapshot(base + 2 * window, 96, deadline=deadline)
    snapshot(base + 3 * window, 94, deadline=deadline)
    # Two weekly resets make the second cycle complete; the first remains N/A.
    connection.executemany(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        [
            ("weekly", base, base, 100, 100, "scheduled_crossing"),
            ("weekly", base + 2 * window, base + 2 * window + 100, 40, 100, "scheduled_crossing"),
            ("5h", base + 2 * window, base + 2 * window + 100, 40, 100, "scheduled_crossing"),
        ],
    )
    # The estimator includes every locally collected source: Codex (1.50 USD),
    # OpenCode (150.00 USD), and Hermes (0.50 USD) in the first twelve-hour window.
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 300000, 'codex-cost')""",
        (base + window // 2,),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 300000, 'codex-cost-2')""",
        (base + 2 * window + window // 2,),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'opencode', 'openai', 'gpt-5.6-sol', 30000000, 'other-source')""",
        (base + window // 2,),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'hermes', 'openai', 'gpt-5.6-sol', 100000, 'hermes-cost')""",
        (base + window // 2,),
    )
PY

payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"all","reset_type":"all"}' --now "$((base_epoch + 3 * window_seconds + 1000))")"
assert_eq "$window_seconds" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_limit_value"]["window_seconds"])' <<<"$payload")" "weekly value payload uses a twelve-hour window"
assert_eq 21600 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_limit_value"]["point_interval_seconds"])' <<<"$payload")" "weekly value payload exposes its six-hour point cadence"
assert_eq 7600.0 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["raw_value_usd"] for p in d["series"] if p["observed_cost_usd"] == 152.0))' <<<"$payload")" "all-source cost is divided by the quota fraction"
assert_eq 0.02 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["consumed_fraction"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "quota percentage converted to fraction"
assert_eq 1.5 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["observed_cost_usd"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "second interval cost remains correct"
assert_eq 152.0 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["estimated_cycle_cost_usd"] for p in d if p["reset_at"] == "2001-09-10T01:46:40Z"))' <<<"$payload")" "cycle cost includes every source"
assert_eq 253.33333333 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["extrapolated_100_value_usd"] for p in d if p["reset_at"] == "2001-09-10T01:46:40Z"))' <<<"$payload")" "cycle extrapolation with remaining quota"
assert_eq weekly_only "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["cycle_cost_reason"] for p in d if p["window"] == "5h"))' <<<"$payload")" "5-hour cycle is not extrapolated"
assert_eq incomplete_cycle "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["cycle_cost_reason"] for p in d if p["reset_at"] == "2001-09-09T01:46:40Z"))' <<<"$payload")" "first cycle is qualified"

stale_payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"all","reset_type":"all"}' --now "$((base_epoch + 3 * window_seconds + 5000))")"
assert_eq stale_data "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(d["current_status"])' <<<"$stale_payload")" "stale latest sample qualifies the current estimate"
assert_eq stale_data "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["reason"] for p in d["series"] if p["at"] == d["current_at"]))' <<<"$stale_payload")" "stale latest sample remains visible with a reason"
assert_eq 2 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(sum(1 for p in d["series"] if p["quality"] != "unavailable"))' <<<"$payload")" "two valid historical estimates are preserved"

python3 - "$ROOT_DIR" "$TEST_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
test_root = Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
from analytics import (_cadence_rows, _event_cost, _load_cost_events,
                       _snapshot_limit_id_around_reset, _window_pair_reason,
                       _window_start, price_index, weekly_limit_value,
                       weekly_reset_cycle_metrics)
from storage import connect_database
from token_usage import load_pricing

window = 43200

def snap(epoch, weekly, limit_id="limit-a", deadline=999999999):
    return {
        "scraped_at_epoch": epoch, "weekly_pct": weekly,
        "weekly_reset_at": deadline, "limit_id": limit_id,
    }

valid = [snap(1000, 90), snap(4000, 80)]
assert _snapshot_limit_id_around_reset(valid, 2000, 2100, 900) == ("limit-a", None)
wide_local = [
    {**snap(0, 90), "sample_interval_seconds": 86400},
    {**snap(100000, 80), "sample_interval_seconds": 86400},
]
assert _snapshot_limit_id_around_reset(wide_local, 50000, 50100, 900) == ("limit-a", None)
long_gap = [snap(0, 90), snap(100000, 80)]
assert _snapshot_limit_id_around_reset(long_gap, 50000, 50100, 900) == (None, "stale_boundary")

boundary_db = test_root / "weekly-value-boundary.sqlite3"
with connect_database(boundary_db) as connection:
    connection.row_factory = __import__("sqlite3").Row
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(0, "0", 80, None, None, 90, None, 999999, 900, 192, "limit-a"),
         (100000, "100000", 80, None, None, 80, None, 999999, 900, 192, "limit-a"),
         (200000, "200000", 80, None, None, 70, None, 999999, 86400, 192, "limit-a")],
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("weekly", 50000, 50100, 90, 100, "random_observed"),
    )
    metrics = weekly_reset_cycle_metrics(
        connection, load_pricing(root / "local/pricing.json"),
        [connection.execute("SELECT * FROM reset_events WHERE window = 'weekly'").fetchone()],
    )
    assert metrics[50000]["cycle_cost_reason"] == "stale_boundary", metrics
    assert metrics[50000]["estimated_cycle_cost_usd"] is None
    assert metrics[50000]["extrapolated_100_value_usd"] is None
start = snap(0, 98)
end = snap(window, 98)
assert _window_pair_reason(start, end, 0, window) is None
end["weekly_reset_at"] += 179
assert _window_pair_reason(start, end, 0, window) is None
end["weekly_reset_at"] += 1
assert _window_pair_reason(start, end, 0, window) == "deadline_transition"
end["weekly_reset_at"] = start["weekly_reset_at"]
assert _window_pair_reason(start, end, 0, 11 * 3600 + 45 * 60) is None
assert _window_pair_reason(start, end, 0, 12 * 3600 + 15 * 60) is None
assert _window_pair_reason(start, end, 0, 11 * 3600 + 44 * 60) == "window_duration"
assert _window_pair_reason(start, end, 0, 12 * 3600 + 16 * 60) == "window_duration"
end["weekly_pct"] = 97.8
assert _window_pair_reason(start, end, 0, window) is None
middle = snap(window // 2, 98, deadline=start["weekly_reset_at"] + 179)
_, middle_reason = _window_start([start, middle, end], end, window, [0, window // 2, window])
assert middle_reason is None
middle["weekly_reset_at"] += 1
_, middle_reason = _window_start([start, middle, end], end, window, [0, window // 2, window])
assert middle_reason == "deadline_transition"
end["weekly_pct"] = 96
end["limit_id"] = "limit-b"
assert _window_pair_reason(start, end, 0, window) == "limit_transition"
end["limit_id"] = "limit-a"
end["weekly_reset_at"] = 20000
assert _window_pair_reason(start, end, 0, window) == "deadline_transition"
assert _event_cost({"provider": "openai", "model": "missing", "input_tokens": 1,
                    "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0}, {}) == (None, "missing_price")
assert _event_cost({"provider": "openai", "model": "priced", "input_tokens": -1,
                    "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0},
                   {("openai", "priced"): {"input_per_million": 1, "cache_read_per_million": 1,
                                             "cache_write_per_million": 1, "output_per_million": 1}}) == (None, "invalid_event")

pricing = price_index(load_pricing(root / "local/pricing.json"))
for model, expected in (("gpt-6-sol", 14.7), ("gpt-6-luna", 0.735)):
    for provider in ("openai", "openai-codex", "auto"):
        cost, reason = _event_cost(
            {"provider": provider, "model": model,
             "input_tokens": 1000000, "cache_read_tokens": 1000000,
             "cache_write_tokens": 1000000, "output_tokens": 1000000},
            pricing,
        )
        assert (cost, reason) == (expected, None), (provider, model, cost, reason)
pricing_boundary = 1787270400
for occurred_at, expected in ((pricing_boundary - 1, 5.0), (pricing_boundary, 4.0)):
    cost, reason = _event_cost(
        {"provider": "openai", "model": "gpt-5.6-sol", "occurred_at_epoch": occurred_at,
         "input_tokens": 1000000, "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0},
        pricing,
    )
    assert (cost, reason) == (expected, None), (occurred_at, cost, reason)
temporal_cost_db = test_root / "weekly-value-temporal-pricing.sqlite3"
with connect_database(temporal_cost_db) as connection:
    connection.executemany(
        """INSERT INTO token_usage_events(
             occurred_at_epoch, source, provider, model, input_tokens, external_id
           ) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)""",
        [(pricing_boundary - 1, 1000000, "weekly-old"), (pricing_boundary, 1000000, "weekly-new")],
    )
    connection.row_factory = __import__("sqlite3").Row
    events = _load_cost_events(connection, pricing, pricing_boundary - 1, pricing_boundary + 1)
    assert [item[1] for item in events] == [5.0, 4.0], events

smooth_db = test_root / "weekly-value-smoothing.sqlite3"
with connect_database(smooth_db) as connection:
    rows = [
        (0, 100, 20 * window, "limit-a"), (window, 98, 20 * window, "limit-a"),
        (2 * window, 96, 20 * window, "limit-a"), (3 * window, 94, 30 * window, "limit-a"),
        (4 * window, 92, 30 * window, "limit-a"), (5 * window, 90, 30 * window, "limit-a"),
        (6 * window, 90, 30 * window, "limit-a"), (7 * window, 89.8, 30 * window, "limit-a"),
        (8 * window, 87.8, 30 * window, "limit-b"), (9 * window, 85.8, 40 * window, "limit-b"),
        (10 * window, 84, 40 * window, "limit-b"), (11 * window, 82, 40 * window, "limit-b"),
    ]
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(epoch, str(epoch), 80, None, None, weekly, None, deadline, 900, 192, limit_id)
         for epoch, weekly, deadline, limit_id in rows],
    )
    connection.executemany(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)",
         [(window // 2, 200000, "smooth-1"), (window + window // 2, 800000, "smooth-2"),
         (3 * window + window // 2, 800000, "smooth-3"), (4 * window + window // 2, 800000, "smooth-4")],
    )
    connection.execute(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'model-without-price', ?, ?)",
        (9 * window + window // 2, 100000, "smooth-missing-price"),
    )
    connection.execute(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)",
        (10 * window + window // 2, 0, "smooth-zero-cost"),
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("weekly", 3 * window, 3 * window, 94, 100, "scheduled_crossing"),
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(connection, load_pricing(root / "local/pricing.json"), 0, 11 * window + 1, now=11 * window, sample_interval_seconds=900)
    iso = lambda epoch: __import__('datetime').datetime.fromtimestamp(epoch, __import__('datetime').timezone.utc).isoformat().replace('+00:00', 'Z')
    volatile = next(point for point in result["series"] if point["at"] == iso(2 * window))
    assert volatile["quality"] == "volatile" and volatile["value_usd"] == 125.0, volatile
    after_reset = next(point for point in result["series"] if point["at"] == iso(4 * window))
    assert after_reset["raw_value_usd"] == 200.0 and after_reset["value_usd"] == 200.0, after_reset
    by_at = {point["at"]: point for point in result["series"]}
    assert by_at[iso(6 * window)]["reason"] == "zero_quota_delta"
    assert by_at[iso(7 * window)]["reason"] == "insufficient_quota_delta"
    assert by_at[iso(8 * window)]["reason"] == "limit_transition"
    assert by_at[iso(9 * window)]["reason"] == "deadline_transition"
    assert by_at[iso(10 * window)]["reason"] == "missing_price"
    assert by_at[iso(11 * window)]["reason"] == "no_cost"

jitter_smooth_db = test_root / "weekly-value-jitter-smoothing.sqlite3"
with connect_database(jitter_smooth_db) as connection:
    deadline = 20 * window
    rows = [
        (0, 100, deadline), (window, 99.5, deadline + 179),
        (2 * window, 98, deadline), (3 * window, 96, deadline + 179),
    ]
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(epoch, str(epoch), 80, None, None, weekly, None, row_deadline, 900, 192, "limit-a")
         for epoch, weekly, row_deadline in rows],
    )
    connection.executemany(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)",
        [(window + window // 2, 400000, "jitter-1"),
         (2 * window + window // 2, 800000, "jitter-2")],
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(
        connection, load_pricing(root / "local/pricing.json"), 0, 3 * window + 1,
        now=3 * window, sample_interval_seconds=900,
    )
    by_at = {point["at"]: point for point in result["series"]}
    assert by_at[iso(2 * window)]["value_usd"] == 133.33333333, by_at[iso(2 * window)]
    assert by_at[iso(3 * window)]["value_usd"] == 166.66666667, by_at[iso(3 * window)]

cadence_db = test_root / "weekly-value-cadence.sqlite3"
cadence_end = 4 * 21600
with connect_database(cadence_db) as connection:
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(index * 900, str(index * 900), 80, None, None, 100 - index * 0.1, None,
          999999999, 900, 192, "limit-cadence") for index in range(96)],
    )
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 1000000, ?)""",
        [(30000, "cadence-cost-1"), (50000, "cadence-cost-2")],
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(
        connection, load_pricing(root / "local/pricing.json"), 0, cadence_end,
        now=cadence_end, sample_interval_seconds=900,
    )
    assert result["candidate_points"] == 96
    assert result["cadenced_points"] == 4
    assert result["returned_points"] == 4
    assert result["omitted_points"] == 92
    assert result["point_interval_seconds"] == 21600
    epochs = [
        int(__import__("datetime").datetime.fromisoformat(point["at"].replace("Z", "+00:00")).timestamp())
        for point in result["series"]
    ]
    assert epochs == sorted(epochs)
    assert len({epoch // 21600 for epoch in epochs}) == len(epochs)
    assert epochs[-1] == 95 * 900, epochs

long_db = test_root / "weekly-value-long.sqlite3"
count = 10001
base = 2000000000
with connect_database(long_db) as connection:
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(base + i * 21600, str(base + i * 21600), 80, None, None, 100 - (i % 50), None,
          base + count * 21600 + 100000, 21600, 192, "limit-long") for i in range(count)],
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(
        connection, load_pricing(root / "local/pricing.json"), base, base + (count - 1) * 21600 + 1,
        now=base + (count - 1) * 21600 + 1, sample_interval_seconds=21600,
    )
    assert result["candidate_points"] == count
    assert result["cadenced_points"] == count
    assert result["point_interval_seconds"] == 21600
    assert result["returned_points"] == 10000
    assert result["omitted_points"] == 1 and result["points_reduced"] is True
    assert result["series"][-1]["at"] == f"{__import__('datetime').datetime.fromtimestamp(base + (count - 1) * 21600, __import__('datetime').timezone.utc).isoformat().replace('+00:00', 'Z')}"
    assert result["series"][-1]["window_seconds"] == window

cadence_rows = [
    {"scraped_at_epoch": 0, "marker": "first"},
    {"scraped_at_epoch": 900, "marker": "latest-first-bucket"},
    {"scraped_at_epoch": "invalid", "marker": "ignored"},
    {"scraped_at_epoch": 21600, "marker": "second-bucket"},
    {"scraped_at_epoch": 22500, "marker": "latest-second-bucket"},
]
cadenced = _cadence_rows(cadence_rows)
assert [row["marker"] for row in cadenced] == ["latest-first-bucket", "latest-second-bucket"], cadenced
assert [row["scraped_at_epoch"] // 21600 for row in cadenced] == [0, 1], cadenced
PY

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from analytics import (
    WEEKLY_VALUE_MIXED_REASON_FIXED_MIX,
    WEEKLY_VALUE_MIXED_REASON_INSUFFICIENT_SAMPLES,
    WEEKLY_VALUE_MIXED_REASON_TARGET_MISMATCH,
    WEEKLY_VALUE_MIXED_REASON_UNSTABLE,
    _adaptive_target_observation,
    _adaptive_training_observations,
    _carry_weekly_model_values,
    _fit_mixed_regression,
    _mixed_point_from_fit,
    _mixed_training_fit,
    _mixed_window_observation,
)

a = ("openai", "gpt-5.6-sol")
b = ("openai", "gpt-5.6-terra")
nuisance = ("other", "non-gpt-helper")

# Recover known positive coefficients while accounting for a non-GPT nuisance
# identity. The response is a shared quota fraction, not a per-model counter.
samples = []
for index in range(12):
    costs = {
        a: 50.0 + 10.0 * index,
        b: 300.0 - 15.0 * index,
        nuisance: 20.0 + (index % 3) * 25.0,
    }
    fraction = costs[a] / 100.0 + costs[b] / 200.0 + costs[nuisance] / 400.0
    samples.append({"costs": costs, "fraction": fraction, "identities": set(costs)})
fit = _fit_mixed_regression(samples, {a, b, nuisance})
assert fit["ok"], fit
assert abs(fit["coefficients"][a] - 0.01) < 1e-12, fit
assert abs(fit["coefficients"][b] - 0.005) < 1e-12, fit
assert abs(fit["coefficients"][nuisance] - 0.0025) < 1e-12, fit
assert fit["max_relative_coefficient_error"] <= 0.5, fit
stable_point = _mixed_point_from_fit(
    {"quality": "unavailable"}, {"costs": {a: 10.0, b: 20.0, nuisance: 5.0}}, a, fit,
)
assert stable_point["quality"] == "low_confidence", stable_point
assert 0 < stable_point["value_lower_usd"] < stable_point["value_usd"] < stable_point["value_upper_usd"], stable_point
assert stable_point["coefficient_error_bound_fraction_per_usd"] > 0, stable_point
assert stable_point["uncertainty_method"] == "assumed_1_point_quota_error_sensitivity", stable_point

insufficient = _fit_mixed_regression(samples[:4], {a, b})
assert insufficient["reason"] == WEEKLY_VALUE_MIXED_REASON_INSUFFICIENT_SAMPLES, insufficient
fixed = [
    {"costs": {a: float(index), b: float(index * 2)}, "fraction": index / 100.0}
    for index in range(1, 9)
]
fixed_fit = _fit_mixed_regression(fixed, {a, b})
assert fixed_fit["reason"] == WEEKLY_VALUE_MIXED_REASON_FIXED_MIX, fixed_fit

# A formally full-rank fit with little signal remains publishable, but its
# one-point quota-error sensitivity is explicit and has no finite upper bound.
weak = []
for index in range(8):
    costs = {a: 1.0 + index / 10.0, b: 2.0 - index / 20.0}
    weak.append({"costs": costs, "fraction": costs[a] / 1000.0 + costs[b] / 2000.0})
weak_fit = _fit_mixed_regression(weak, {a, b})
assert weak_fit["ok"] and set(weak_fit["unstable_identities"]) == {a, b}, weak_fit
weak_point = _mixed_point_from_fit(
    {"quality": "unavailable"}, {"costs": {a: 1.7, b: 1.65}}, a, weak_fit,
)
assert weak_point["value_usd"] == 1000.0, weak_point
assert weak_point["quality"] == "high_uncertainty", weak_point
assert 0 < weak_point["value_lower_usd"] < weak_point["value_usd"], weak_point
assert weak_point["value_upper_usd"] is None, weak_point

# Training selection uses only prior, non-overlapping windows in one
# uninterrupted regime. A future observation with a wildly different response
# cannot change the recovered coefficients, and an explicit reset invalidates
# the window containing it.
window = 3600
deadline = 100 * window
rows = []
quota = 100.0
events = []
for index in range(14):
    rows.append({
        "scraped_at_epoch": index * window,
        "weekly_pct": quota,
        "weekly_reset_at": deadline + (179 if index % 2 else 0),
        "limit_id": "limit-fit",
    })
    if index == 13:
        break
    cost_a = 3.0 + (index % 4) * 3.0
    cost_b = 4.0 + ((index * 3) % 5) * 3.0
    fraction = cost_a * 0.005 + cost_b * 0.004
    events.extend([
        (index * window + window // 3, a, cost_a, None, "direct"),
        (index * window + 2 * window // 3, b, cost_b, None, "direct"),
    ])
    quota -= fraction * 100.0
epochs = [row["scraped_at_epoch"] for row in rows]
event_epochs = [event[0] for event in events]
target, reason = _adaptive_target_observation(rows, epochs, rows[-1], events, event_epochs, set())
assert reason is None and target is not None, (target, reason)
selected = _mixed_training_fit(rows, epochs, rows, epochs, target, events, event_epochs, set())
assert selected["ok"] and selected["sample_count"] >= 6, selected
assert abs(selected["coefficients"][a] - 0.005) < 1e-12, selected
assert abs(selected["coefficients"][b] - 0.004) < 1e-12, selected
drifted_target = {**target, "fraction": target["fraction"] * 2.0}
drifted = _mixed_training_fit(rows, epochs, rows, epochs, drifted_target, events, event_epochs, set())
assert drifted["reason"] == WEEKLY_VALUE_MIXED_REASON_TARGET_MISMATCH, drifted

future_events = [*events, (15 * window + 1, a, 1000000.0, None, "direct")]
future_fit = _mixed_training_fit(
    rows, epochs, rows, epochs, target, future_events,
    [event[0] for event in future_events], set(),
)
assert future_fit["coefficients"] == selected["coefficients"], (selected, future_fit)
reset_target, reset_reason = _mixed_window_observation(
    rows, epochs, rows[-1], events, event_epochs, {7 * window + window // 2},
)
assert reset_target is None, (reset_target, reset_reason)

# Per-target history is bounded even if a caller supplies older same-regime
# candidates directly.
distant_target = {**target, "start_epoch": 1000 * window, "end_epoch": 1001 * window}
distant = _mixed_training_fit(rows, epochs, rows, epochs, distant_target, events, event_epochs, set())
assert distant["sample_count"] == 0, distant

# Adaptive observations are causal and non-overlapping, survive weekly deadline
# changes between observations, and reject crossings, long gaps, hidden quota
# increases, and an intervening limit that later returns to the same id.
adaptive_rows = [
    {"scraped_at_epoch": 0, "weekly_pct": 100.0, "weekly_reset_at": 10000, "limit_id": "a"},
    {"scraped_at_epoch": 900, "weekly_pct": 99.0, "weekly_reset_at": 10000, "limit_id": "a"},
    {"scraped_at_epoch": 1800, "weekly_pct": 98.0, "weekly_reset_at": 10000, "limit_id": "a"},
    {"scraped_at_epoch": 2700, "weekly_pct": 100.0, "weekly_reset_at": 20000, "limit_id": "a"},
    {"scraped_at_epoch": 3600, "weekly_pct": 98.0, "weekly_reset_at": 20000, "limit_id": "a"},
]
adaptive_events = [
    (450, a, 1.0, None, "direct"), (1350, b, 1.0, None, "direct"),
    (3150, a, 1.0, None, "direct"), (3500, b, 1.0, None, "direct"),
]
adaptive_epochs = [row["scraped_at_epoch"] for row in adaptive_rows]
adaptive_event_epochs = [event[0] for event in adaptive_events]
observations = _adaptive_training_observations(
    adaptive_rows, adaptive_epochs, 0, 3600, "a", adaptive_events, adaptive_event_epochs, set(),
)
assert [(item["start_epoch"], item["end_epoch"]) for item in observations] == [(0, 1800), (2700, 3600)], observations
assert all(item["end_epoch"] <= observations[index + 1]["start_epoch"]
           for index, item in enumerate(observations[:-1])), observations
assert _adaptive_training_observations(
    adaptive_rows, adaptive_epochs, 0, 3600, "a", adaptive_events, adaptive_event_epochs, {1500},
)[0]["end_epoch"] == 3600

increased = [dict(row) for row in adaptive_rows[:3]]
increased[1]["weekly_pct"] = 100.5
assert not _adaptive_training_observations(
    increased, adaptive_epochs[:3], 0, 1800, "a", adaptive_events, adaptive_event_epochs, set(),
)
gapped = [dict(adaptive_rows[0]), {**adaptive_rows[2], "scraped_at_epoch": 6000}]
assert not _adaptive_training_observations(
    gapped, [0, 6000], 0, 6000, "a", adaptive_events, adaptive_event_epochs, set(),
)
returned = [dict(row) for row in adaptive_rows[:3]]
returned[1]["limit_id"] = "b"
assert not _adaptive_training_observations(
    returned, adaptive_epochs[:3], 0, 1800, "a", adaptive_events, adaptive_event_epochs, set(),
)
expired_deadline = [
    {"scraped_at_epoch": epoch, "weekly_pct": quota, "weekly_reset_at": 1000, "limit_id": "a"}
    for epoch, quota in ((2000, 100.0), (2900, 99.0), (3800, 98.0))
]
assert not _adaptive_training_observations(
    expired_deadline, [2000, 2900, 3800], 2000, 3800, "a",
    adaptive_events, adaptive_event_epochs, set(),
)
assert _adaptive_target_observation(
    expired_deadline, [2000, 2900, 3800], expired_deadline[-1],
    adaptive_events, adaptive_event_epochs, set(),
)[0] is None

# Carry preserves the original source, can bridge a reset, expires after seven
# days, and clears on contradictions or any intervening limit regime.
base_point = {"at": "1970-01-01T00:00:00Z", "at_epoch": 0, "limit_id": "a",
              "_limit_regime": 1, "value_usd": 100.0, "raw_value_usd": 100.0,
              "quality": "good", "reason": None}
reset_gap = {"at": "1970-01-01T06:00:00Z", "at_epoch": 21600, "limit_id": "a",
             "_limit_regime": 1, "value_usd": None, "raw_value_usd": None,
             "quality": "unavailable", "reason": "reset_in_window"}
expired = {**reset_gap, "at_epoch": 604801, "at": "1970-01-08T00:00:01Z"}
carry_series = [base_point, reset_gap, expired]
assert _carry_weekly_model_values(carry_series) == 1
assert reset_gap["carried"] and reset_gap["source_at"] == base_point["at"]
assert reset_gap["source_age_seconds"] == 21600 and reset_gap["source_method"] == "exclusive_model_window"
assert expired["quality"] == "unavailable"
contradiction = [{**base_point}, {**reset_gap, "reason": "mixed_models",
    "mixed_model_reason": WEEKLY_VALUE_MIXED_REASON_TARGET_MISMATCH}]
assert _carry_weekly_model_values(contradiction) == 0
changed = [{**base_point}, {**reset_gap, "_limit_regime": 3}]
assert _carry_weekly_model_values(changed) == 0
uncertain_source = {
    **base_point, "quality": "high_uncertainty", "value_usd": 80.0, "raw_value_usd": 80.0,
    "coefficient_fraction_per_usd": 0.0125,
    "coefficient_error_bound_fraction_per_usd": 0.01,
    "coefficient_relative_error": 0.8, "value_lower_usd": 44.44444444,
    "value_upper_usd": 400.0,
    "uncertainty_method": "assumed_1_point_quota_error_sensitivity",
}
uncertain_gap = {**reset_gap}
assert _carry_weekly_model_values([uncertain_source, uncertain_gap]) == 1
assert uncertain_gap["quality"] == uncertain_gap["source_quality"] == "high_uncertainty", uncertain_gap
assert uncertain_gap["source_at"] == uncertain_source["at"], uncertain_gap
assert uncertain_gap["value_lower_usd"] == uncertain_source["value_lower_usd"], uncertain_gap
assert uncertain_gap["value_upper_usd"] == uncertain_source["value_upper_usd"], uncertain_gap
PY

python3 - "$ROOT_DIR" "$TEST_ROOT/mixed-weekly-value.sqlite3" <<'PY'
from pathlib import Path
import sqlite3
import sys

root, database = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
from analytics import weekly_limit_value
from storage import connect_database
from token_usage import load_pricing

window = 3600
deadline = 100 * window
quota = 100.0
with connect_database(database) as connection:
    for index in range(14):
        connection.execute(
            "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (index * window, str(index * window), 80, None, None, quota, None,
             deadline + (179 if index % 2 else 0), 900, 192, "limit-fit"),
        )
        if index == 13:
            break
        # Full-rank but deliberately weakly separated predictors exercise the
        # published high-uncertainty path through the real SQLite pipeline.
        cost_sol = 10 + index
        cost_terra = 20 - index / 2
        connection.executemany(
            """INSERT INTO token_usage_events
               (occurred_at_epoch, source, provider, model, input_tokens, external_id)
               VALUES (?, 'codex', 'openai', ?, ?, ?)""",
            [
                (index * window + window // 3, "gpt-5.6-sol", cost_sol * 200000, f"sol-{index}"),
                (index * window + 2 * window // 3, "gpt-5.6-terra", cost_terra * 400000, f"terra-{index}"),
            ],
        )
        quota -= (cost_sol * 0.001 + cost_terra * 0.0005) * 100
    connection.row_factory = sqlite3.Row
    catalog = load_pricing(root / "local/pricing.json")
    target_epoch = 13 * window
    result = weekly_limit_value(connection, catalog, target_epoch, target_epoch + 1, now=target_epoch)
    by_model = {item["model"]: item for item in result["by_model"]}
    assert all(item["returned_points"] == len(item["series"]) == 1 for item in by_model.values()), by_model
    assert result["series"][0]["value_usd"] is not None, result["series"]
    assert result["mixed_model_diagnostics"]["inferred_points"] == 2, result["mixed_model_diagnostics"]
    assert by_model["gpt-5.6-sol"]["attribution"] == "mixed_model_regression", by_model
    assert by_model["gpt-5.6-terra"]["attribution"] == "mixed_model_regression", by_model
    assert by_model["gpt-5.6-sol"]["series"][0]["value_usd"] == 1000.0, by_model
    assert by_model["gpt-5.6-terra"]["series"][0]["value_usd"] == 2000.0, by_model
    for item in by_model.values():
        point = item["series"][0]
        assert point["quality"] == "high_uncertainty", point
        assert point["coefficient_error_bound_fraction_per_usd"] > point["coefficient_fraction_per_usd"], point
        assert 0 < point["value_lower_usd"] < point["value_usd"], point
        assert point["value_upper_usd"] is None, point
    assert all(item["unavailable_reasons"].get("mixed_models", 0) == 0 for item in by_model.values()), by_model

    wider = weekly_limit_value(connection, catalog, 12 * window, target_epoch + 1, now=target_epoch)
    wider_by_model = {item["model"]: item for item in wider["by_model"]}
    for model, expected in (("gpt-5.6-sol", 1000.0), ("gpt-5.6-terra", 2000.0)):
        target = next(point for point in wider_by_model[model]["series"] if point["at"] == by_model[model]["series"][0]["at"])
        assert target["value_usd"] == expected, (model, target)

    # Split each Sol event over two routes without changing its total cost.
    connection.execute("UPDATE token_usage_events SET input_tokens = input_tokens / 2 WHERE model = 'gpt-5.6-sol'")
    connection.execute("""INSERT INTO token_usage_events
        (occurred_at_epoch, source, provider, model, input_tokens, external_id)
        SELECT occurred_at_epoch, source, 'openai-codex', model, input_tokens, external_id || '-route'
        FROM token_usage_events WHERE model = 'gpt-5.6-sol'""")
    merged = weekly_limit_value(connection, catalog, target_epoch, target_epoch + 1, now=target_epoch)
    assert len(merged["by_model"]) == 2
    sol = next(item for item in merged["by_model"] if item["model"] == 'gpt-5.6-sol')
    assert sol["providers"] == ['openai', 'openai-codex']
    assert sol["series"][0]["value_usd"] == 1000.0
    assert sol["series"][0]["training_predictor_count"] == 2

    stale = weekly_limit_value(connection, catalog, target_epoch, target_epoch + 1, now=target_epoch + 1801)
    assert all(item["series"][0]["reason"] == "stale_data" for item in stale["by_model"]), stale["by_model"]
    assert stale["mixed_model_diagnostics"]["inferred_points"] == 0, stale["mixed_model_diagnostics"]

    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'unpriced-target-model', 1000, 'unpriced-target')""",
        (12 * window + window // 2,),
    )
    missing = weekly_limit_value(connection, catalog, target_epoch, target_epoch + 1, now=target_epoch)
    assert missing["series"][0]["reason"] == "missing_price", missing["series"]
    assert missing["mixed_model_diagnostics"]["inferred_points"] == 0, missing["mixed_model_diagnostics"]
    assert all(item["series"][0]["value_usd"] is None for item in missing["by_model"]), missing["by_model"]
PY

python3 - "$ROOT_DIR" "$database" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from analytics import weekly_limit_value
from storage import connect_database
from token_usage import load_pricing

catalog = load_pricing(Path(sys.argv[1]) / "local/pricing.json")
base, window = 1000000000, 43200
with connect_database(Path(sys.argv[2])) as connection:
    import sqlite3
    connection.row_factory = sqlite3.Row
    def estimate(now=base + 3 * window + 1000):
        return weekly_limit_value(connection, catalog, base, base + 3 * window + 1, now=now)

    result = estimate()
    solo = result["by_model"][0]
    assert solo["model"] == "gpt-5.6-sol"
    aggregate_by_at = {point["at"]: point for point in result["series"]}
    assert all(point == aggregate_by_at[point["at"]]
               for point in solo["series"] if not point.get("carried")), \
        "single-model direct estimates differ from aggregate"
    assert solo["attribution"] == "exclusive_model_windows"
    # Another GPT model invalidates only the overlapping windows for attribution.
    connection.execute("""INSERT INTO token_usage_events
        (occurred_at_epoch, source, provider, model, input_tokens, external_id)
        VALUES (?, 'codex', 'openai', 'gpt-5.6-terra', 300000, 'mixed-gpt')""",
        (base + window // 2,))
    mixed = estimate()
    assert len(mixed["by_model"]) == 2
    by_model = {item["model"]: item for item in mixed["by_model"]}
    sol = by_model["gpt-5.6-sol"]
    assert sol["series"][1]["reason"] == "mixed_models"
    assert sol["series"][1]["value_usd"] is None
    assert sol["series"][-1]["raw_value_usd"] == 75.0
    assert sol["series"][-1]["value_usd"] == 75.0, "mixed window contaminated smoothing"
    assert all(point["value_usd"] is None for point in by_model["gpt-5.6-terra"]["series"])
    assert mixed["series"][1]["value_usd"] is not None, "aggregate lost mixed-model window"
    stale = estimate(base + 3 * window + 5000)
    assert all(item["series"][-1]["reason"] == "stale_data" for item in stale["by_model"])
    # Non-GPT usage must also prevent attributing the quota to GPT.
    connection.execute("UPDATE token_usage_events SET model = 'unknown-model' WHERE external_id = 'mixed-gpt'")
    unknown = estimate()
    assert len(unknown["by_model"]) == 1
    assert unknown["by_model"][0]["series"][1]["reason"] == "mixed_models"
    # Same model routes aggregate after provider-specific pricing; unknown prices still invalidate.
    connection.execute("UPDATE token_usage_events SET model = 'gpt-5.6-sol', provider = 'other' WHERE external_id = 'mixed-gpt'")
    providers = estimate()["by_model"]
    assert len(providers) == 1
    assert set(providers[0]["providers"]) == {"openai", "other"}
    assert all(item["series"][1]["value_usd"] is None for item in providers)
    connection.execute("UPDATE token_usage_events SET provider = 'openai-codex' WHERE external_id = 'mixed-gpt'")
    merged = estimate()
    assert len(merged["by_model"]) == 1
    aggregate_by_at = {point["at"]: point for point in merged["series"]}
    assert all(point == aggregate_by_at[point["at"]]
               for point in merged["by_model"][0]["series"] if not point.get("carried")), \
        "same-model routes must sum costs before attribution"
    connection.execute("DELETE FROM token_usage_events")
    assert estimate()["by_model"] == []
PY

printf 'PASS: weekly limit value analytics tests\n'
