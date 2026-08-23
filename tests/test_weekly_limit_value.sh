#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

database="${TEST_ROOT}/weekly-value.sqlite3"
window_seconds=7200
base_epoch=1000000000
python3 - "$ROOT_DIR" "$database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

db = Path(sys.argv[2])
with connect_database(db) as connection:
    window = 7200
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
    # tied to the local cadence even though value windows span two hours.
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
    # OpenCode (150.00 USD), and Hermes (0.50 USD) in the first two-hour window.
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
assert_eq "$window_seconds" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_limit_value"]["window_seconds"])' <<<"$payload")" "weekly value payload uses a two-hour window"
assert_eq 7600.0 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["raw_value_usd"] for p in d["series"] if p["observed_cost_usd"] == 152.0))' <<<"$payload")" "all-source cost is divided by the quota fraction"
assert_eq 0.02 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["consumed_fraction"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "quota percentage converted to fraction"
assert_eq 1.5 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["observed_cost_usd"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "second interval cost remains correct"
assert_eq 152.0 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["estimated_cycle_cost_usd"] for p in d if p["reset_at"] == "2001-09-09T05:46:40Z"))' <<<"$payload")" "cycle cost includes every source"
assert_eq 253.33333333 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["extrapolated_100_value_usd"] for p in d if p["reset_at"] == "2001-09-09T05:46:40Z"))' <<<"$payload")" "cycle extrapolation with remaining quota"
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
from analytics import (_event_cost, _load_cost_events, _snapshot_limit_id_around_reset,
                       _window_pair_reason, _window_start, price_index, weekly_limit_value,
                       weekly_reset_cycle_metrics)
from storage import connect_database
from token_usage import load_pricing

window = 7200

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
assert _window_pair_reason(start, end, 0, 1 * 3600 + 45 * 60) is None
assert _window_pair_reason(start, end, 0, 2 * 3600 + 15 * 60) is None
assert _window_pair_reason(start, end, 0, 1 * 3600 + 44 * 60) == "window_duration"
assert _window_pair_reason(start, end, 0, 2 * 3600 + 16 * 60) == "window_duration"
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

long_db = test_root / "weekly-value-long.sqlite3"
count = 10001
base = 2000000000
with connect_database(long_db) as connection:
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(base + i * 60, str(base + i * 60), 80, None, None, 100 - (i % 50), None,
          base + count * 60 + 100000, 60, 192, "limit-long") for i in range(count)],
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(
        connection, load_pricing(root / "local/pricing.json"), base, base + (count - 1) * 60 + 1,
        now=base + (count - 1) * 60 + 1, sample_interval_seconds=60,
    )
    assert result["candidate_points"] == count
    assert result["returned_points"] == 10000
    assert result["omitted_points"] == 1 and result["points_reduced"] is True
    assert result["series"][-1]["at"] == f"{__import__('datetime').datetime.fromtimestamp(base + (count - 1) * 60, __import__('datetime').timezone.utc).isoformat().replace('+00:00', 'Z')}"
    assert result["series"][-1]["window_seconds"] == window
PY

printf 'PASS: weekly limit value analytics tests\n'
