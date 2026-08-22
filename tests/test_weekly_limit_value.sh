#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

database="${TEST_ROOT}/weekly-value.sqlite3"
python3 - "$ROOT_DIR" "$database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

db = Path(sys.argv[2])
with connect_database(db) as connection:
    def snapshot(epoch, weekly, limit_id="limit-a", deadline=1000100000):
        connection.execute(
            "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (epoch, f"2001-09-09T00:00:{epoch % 60:02d}Z", 80, None, None, weekly, None, deadline, 900, 192, limit_id),
        )

    snapshot(1000000000, 100)
    snapshot(1000003600, 98)
    snapshot(1000007200, 96)
    snapshot(1000010800, 94)
    # Two weekly resets make the second cycle complete; the first remains N/A.
    connection.executemany(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        [
            ("weekly", 1000000000, 1000000000, 100, 100, "scheduled_crossing"),
            ("weekly", 1000007200, 1000007300, 40, 100, "scheduled_crossing"),
            ("5h", 1000007200, 1000007300, 40, 100, "scheduled_crossing"),
        ],
    )
    # 300k input tokens at $5/M = $1.50; the OpenCode event must be ignored.
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 300000, 'codex-cost')""",
        (1000001800,),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 300000, 'codex-cost-2')""",
        (1000009000,),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'opencode', 'openai', 'gpt-5.6-sol', 30000000, 'other-source')""",
        (1000001800,),
    )
PY

payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"all","reset_type":"all"}' --now 1000011000)"
assert_eq 75.0 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["value_usd"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "1.50 USD / 0.02 uses a fraction"
assert_eq 0.02 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["consumed_fraction"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "quota percentage converted to fraction"
assert_eq 1.5 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["observed_cost_usd"] for p in d["series"] if p["raw_value_usd"] == 75.0))' <<<"$payload")" "Codex-only interval cost"
assert_eq 2.5 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["extrapolated_100_value_usd"] for p in d if p["reset_at"] == "2001-09-09T03:46:40Z"))' <<<"$payload")" "cycle extrapolation with remaining quota"
assert_eq weekly_only "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["cycle_cost_reason"] for p in d if p["window"] == "5h"))' <<<"$payload")" "5-hour cycle is not extrapolated"
assert_eq incomplete_cycle "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["resets"]["items"]; print(next(p["cycle_cost_reason"] for p in d if p["reset_at"] == "2001-09-09T01:46:40Z"))' <<<"$payload")" "first cycle is qualified"

stale_payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"all","reset_type":"all"}' --now 1000015000)"
assert_eq stale_data "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(d["current_status"])' <<<"$stale_payload")" "stale latest sample qualifies the current estimate"
assert_eq stale_data "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(next(p["reason"] for p in d["series"] if p["at"] == d["current_at"]))' <<<"$stale_payload")" "stale latest sample remains visible with a reason"
assert_eq 2 "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["weekly_limit_value"]; print(sum(1 for p in d["series"] if p["quality"] != "unavailable"))' <<<"$payload")" "two valid historical estimates are preserved"

python3 - "$ROOT_DIR" "$TEST_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
test_root = Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
from analytics import (_event_cost, _snapshot_limit_id_around_reset, _window_pair_reason,
                       weekly_limit_value, weekly_reset_cycle_metrics)
from storage import connect_database
from token_usage import load_pricing

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
end = snap(3600, 98)
assert _window_pair_reason(start, end, 0, 3600) is None
end["weekly_pct"] = 97.8
assert _window_pair_reason(start, end, 0, 3600) is None
end["weekly_pct"] = 96
end["limit_id"] = "limit-b"
assert _window_pair_reason(start, end, 0, 3600) == "limit_transition"
end["limit_id"] = "limit-a"
end["weekly_reset_at"] = 20000
assert _window_pair_reason(start, end, 0, 3600) == "deadline_transition"
assert _event_cost({"provider": "openai", "model": "missing", "input_tokens": 1,
                    "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0}, {}) == (None, "missing_price")
assert _event_cost({"provider": "openai", "model": "priced", "input_tokens": -1,
                    "cache_read_tokens": 0, "cache_write_tokens": 0, "output_tokens": 0},
                   {("openai", "priced"): {"input_per_million": 1, "cache_read_per_million": 1,
                                             "cache_write_per_million": 1, "output_per_million": 1}}) == (None, "invalid_event")

smooth_db = test_root / "weekly-value-smoothing.sqlite3"
with connect_database(smooth_db) as connection:
    rows = [
        (0, 100, 20000, "limit-a"), (3600, 98, 20000, "limit-a"),
        (7200, 96, 20000, "limit-a"), (10800, 94, 30000, "limit-a"),
        (14400, 92, 30000, "limit-a"), (18000, 90, 30000, "limit-a"),
        (21600, 90, 30000, "limit-a"), (25200, 89.8, 30000, "limit-a"),
        (28800, 87.8, 30000, "limit-b"), (32400, 85.8, 40000, "limit-b"),
        (36000, 84, 40000, "limit-b"), (39600, 82, 40000, "limit-b"),
    ]
    connection.executemany(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [(epoch, str(epoch), 80, None, None, weekly, None, deadline, 900, 192, limit_id)
         for epoch, weekly, deadline, limit_id in rows],
    )
    connection.executemany(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)",
         [(1800, 200000, "smooth-1"), (5400, 800000, "smooth-2"),
         (12600, 800000, "smooth-3"), (16200, 800000, "smooth-4")],
    )
    connection.execute(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'model-without-price', ?, ?)",
        (34200, 100000, "smooth-missing-price"),
    )
    connection.execute(
        "INSERT INTO token_usage_events (occurred_at_epoch, source, provider, model, input_tokens, external_id) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', ?, ?)",
        (37800, 0, "smooth-zero-cost"),
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("weekly", 10800, 10800, 94, 100, "scheduled_crossing"),
    )
    connection.row_factory = __import__("sqlite3").Row
    result = weekly_limit_value(connection, load_pricing(root / "local/pricing.json"), 0, 39601, now=39600, sample_interval_seconds=900)
    volatile = next(point for point in result["series"] if point["at"] == "1970-01-01T02:00:00Z")
    assert volatile["quality"] == "volatile" and volatile["value_usd"] == 125.0, volatile
    after_reset = next(point for point in result["series"] if point["at"] == "1970-01-01T04:00:00Z")
    assert after_reset["raw_value_usd"] == 200.0 and after_reset["value_usd"] == 200.0, after_reset
    by_at = {point["at"]: point for point in result["series"]}
    assert by_at["1970-01-01T06:00:00Z"]["reason"] == "zero_quota_delta"
    assert by_at["1970-01-01T07:00:00Z"]["reason"] == "insufficient_quota_delta"
    assert by_at["1970-01-01T08:00:00Z"]["reason"] == "limit_transition"
    assert by_at["1970-01-01T09:00:00Z"]["reason"] == "deadline_transition"
    assert by_at["1970-01-01T10:00:00Z"]["reason"] == "missing_price"
    assert by_at["1970-01-01T11:00:00Z"]["reason"] == "no_cost"

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
PY

printf 'PASS: weekly limit value analytics tests\n'
