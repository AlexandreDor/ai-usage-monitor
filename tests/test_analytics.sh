#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

database="${TEST_ROOT}/analytics.sqlite3"
python3 - "$ROOT_DIR" "$database" <<'PY'
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

connection = connect_database(Path(sys.argv[2]))
with connection:
    connection.execute(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (1785859200, "2026-08-04T08:00:00Z", 50, "later", 1785862800, 75, "later", 1786000000, 900, 192, "fixture"),
    )
    connection.execute(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (1785859300, "2026-08-04T08:01:40Z", 45, "later", 1785862800, 70, "later", 1786000000, 900, 192, "fixture-latest"),
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("5h", 1785862800, 1785863700, 5, 100, "scheduled_crossing"),
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("weekly", 1785864600, 1785865500, 35, 100, "scheduled_crossing"),
    )
    connection.execute(
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("weekly", 1785863000, 1785863000, 30, 80, "random_observed"),
    )
    connection.execute(
        "INSERT INTO forecast_samples VALUES (?, ?, ?, ?)",
        (1785861001, 1785860990, 64, 22),
    )
    connection.execute(
        "INSERT INTO forecast_samples VALUES (?, ?, ?, ?)",
        (1785861900, 1785861890, 99, 88),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, cache_read_tokens,
            cache_write_tokens, output_tokens, reasoning_tokens, external_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (1785859200, "codex", "openai", "gpt-5.6-sol", 1000000, 500000, 100000, 200000, 50000, "priced"),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (1785859300, "opencode", "other", "unknown-model", 100, "unknown"),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (1785859400, "hermes", "openai-codex", "gpt-5.6-sol", 1000000, "openai-codex-sol"),
    )
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (1785859500, "hermes", "auto", "gpt-5.6-sol", 1000000, "auto-sol"),
    )
    for index, (provider, model) in enumerate((
        ("ollama", "gemma4:26b-a4b-it-q8_0"),
        ("ollama", "ornith:35b-q8_0"),
        ("openai", "unknown"),
        ("opencode", "nemotron-3-ultra-free"),
    )):
        connection.execute(
            """INSERT INTO token_usage_events
               (occurred_at_epoch, source, provider, model, input_tokens, external_id)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (1785859600 + index, "opencode", provider, model, 100, f"configured-zero-{index}"),
        )
    connection.execute(
        "INSERT INTO collector_runs VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("codex", 1, "ok", 1785859500, 1785859500, None, "fixture-v1"),
    )
    connection.execute(
        "INSERT INTO collector_state VALUES (?, ?, ?, ?)",
        ("hermes", "session:model", json.dumps({"baseline": {"input_tokens": 42, "output_tokens": 10, "reasoning_tokens": 4}}), 1785859500),
    )
connection.close()
PY

payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' \
  --now 1785866400)"
assert_eq 21.875 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$payload")" "estimated cost including GPT-5.6 Sol provider aliases"
assert_eq 900 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["period"]["granularity_seconds"])' <<<"$payload")" "24-hour analytics granularity"
assert_eq 100 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["assumed_zero_tokens"])' <<<"$payload")" "unknown model token count"
assert_eq priced "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(item["pricing_status"] for item in data["tokens"]["breakdown"] if item["provider"] == "openai-codex"))' <<<"$payload")" "openai-codex GPT-5.6 Sol pricing"
assert_eq priced "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(item["pricing_status"] for item in data["tokens"]["breakdown"] if item["provider"] == "auto"))' <<<"$payload")" "auto GPT-5.6 Sol pricing"
assert_eq 4 "$(python3 -c 'import json,sys; data=json.load(sys.stdin); configured={("ollama","gemma4:26b-a4b-it-q8_0"),("ollama","ornith:35b-q8_0"),("openai","unknown"),("opencode","nemotron-3-ultra-free")}; print(sum((item["provider"],item["model"]) in configured and item["pricing_status"] == "priced" for item in data["tokens"]["breakdown"]))' <<<"$payload")" "configured zero-price models"
assert_eq 3 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["total"])' <<<"$payload")" "reset count"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["weekly_total"])' <<<"$payload")" "weekly reset count"
assert_eq 1 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["weekly_summary"]["random"]["count"])' <<<"$payload")" "random reset count"
assert_eq 7.348 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["weekly_summary"]["random"]["lost_vs_ideal_pct_points"])' <<<"$payload")" "random reset loss versus ideal pace"
assert_eq 35.0 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["weekly_summary"]["end_of_week"]["unused_pct_points"])' <<<"$payload")" "end-of-week unused quota"
assert_eq '99:88' "$(python3 -c 'import json,sys; data=json.load(sys.stdin); item=next(item for item in data["resets"]["items"] if item["reset_at"] == "2026-08-04T17:00:00Z"); print("{}:{}".format(item["forecast_chance_24h_pct"], item["forecast_chance_6h_pct"]))' <<<"$payload")" "latest Forecast before 5-hour reset"
assert_eq 'None:None:None' "$(python3 -c 'import json,sys; data=json.load(sys.stdin); item=next(item for item in data["resets"]["items"] if item["reset_at"] == "2026-08-04T17:30:00Z"); print("{}:{}:{}".format(item["forecast_chance_24h_pct"], item["forecast_chance_6h_pct"], item["forecast_sample_at"]))' <<<"$payload")" "Forecast exactly 45 minutes before reset was not treated as N/A"
assert_eq 52 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["baselines"]["hermes"][0]["tokens"])' <<<"$payload")" "Hermes baseline excludes the reasoning sub-counter"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["samples"])' <<<"$payload")" "limit bucket sample count"
assert_eq 45.0 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["five_h_pct"])' <<<"$payload")" "limit bucket keeps the latest sample"
assert_eq 23.28 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["ideal_weekly_pct"])' <<<"$payload")" "limit bucket exposes ideal weekly pace"

pagination_database="${TEST_ROOT}/analytics-pagination.sqlite3"
python3 - "$ROOT_DIR" "$pagination_database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

with connect_database(Path(sys.argv[2])) as connection:
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'opencode', 'unpriced-provider', ?, 1, ?)""",
        [
            (1785859200 + index, f"model-{index:03d}", f"pagination-{index:03d}")
            for index in range(105)
        ],
    )
PY

pagination_page() {
  local offset="$1"
  python3 "$ROOT_DIR/local/analytics.py" \
    --database "$pagination_database" \
    --pricing "$ROOT_DIR/local/pricing.json" \
    --params "{\"range\":\"24h\",\"breakdown_offset\":\"${offset}\"}" \
    --now 1785866400
}

legacy_breakdown="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$pagination_database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' \
  --now 1785866400)"
page_one="$(pagination_page 0)"
page_two="$(pagination_page 50)"
page_three="$(pagination_page 100)"
page_clamped="$(pagination_page 9999)"
assert_eq 105 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$legacy_breakdown")" "legacy token breakdown was paginated without opting in"
assert_eq false "$(python3 -c 'import json,sys; print(str("breakdown_pagination" in json.load(sys.stdin)["tokens"]).lower())' <<<"$legacy_breakdown")" "legacy token breakdown exposed pagination metadata"
assert_eq 50 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$page_one")" "first token breakdown page size"
assert_eq 50 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$page_two")" "second token breakdown page size"
assert_eq 5 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$page_three")" "last token breakdown page size"
assert_eq '105:0:50' "$(python3 -c 'import json,sys; p=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print("{}:{}:{}".format(p["total"],p["offset"],p["limit"]))' <<<"$page_one")" "first token breakdown pagination metadata"
assert_eq '105:50:50' "$(python3 -c 'import json,sys; p=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print("{}:{}:{}".format(p["total"],p["offset"],p["limit"]))' <<<"$page_two")" "second token breakdown pagination metadata"
assert_eq 100 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["offset"])' <<<"$page_clamped")" "excessive token breakdown offset was not clamped"
assert_eq 'model-000:model-049' "$(python3 -c 'import json,sys; b=json.load(sys.stdin)["tokens"]["breakdown"]; print("{}:{}".format(b[0]["model"],b[-1]["model"]))' <<<"$page_one")" "first token breakdown page order"
assert_eq 'model-050:model-099' "$(python3 -c 'import json,sys; b=json.load(sys.stdin)["tokens"]["breakdown"]; print("{}:{}".format(b[0]["model"],b[-1]["model"]))' <<<"$page_two")" "second token breakdown page order"
assert_eq 'model-100:model-104' "$(python3 -c 'import json,sys; b=json.load(sys.stdin)["tokens"]["breakdown"]; print("{}:{}".format(b[0]["model"],b[-1]["model"]))' <<<"$page_three")" "last token breakdown page order"
for page in "$page_one" "$page_two" "$page_three"; do
  assert_eq '105:105:0.0' "$(python3 -c 'import json,sys; s=json.load(sys.stdin)["tokens"]["summary"]; print("{}:{}:{}".format(s["total_tokens"],s["assumed_zero_tokens"],s["estimated_cost_usd"]))' <<<"$page")" "token summary changed with breakdown page"
done
python3 "$ROOT_DIR/local/analytics.py" --database "$pagination_database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"-1"}' --now 1785866400 >/dev/null 2>&1 && fail "negative token breakdown offset accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$pagination_database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"invalid"}' --now 1785866400 >/dev/null 2>&1 && fail "non-integer token breakdown offset accepted"

oversized_database="${TEST_ROOT}/analytics-oversized-pricing.sqlite3"
python3 - "$ROOT_DIR" "$oversized_database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

with connect_database(Path(sys.argv[2])) as connection:
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'opencode', ?, 'shared-model', 1, ?)""",
        [
            (1785859200 + index, f"provider-{index:04d}", f"oversized-{index:04d}")
            for index in range(2001)
        ],
    )
PY
if oversized_error="$(python3 "$ROOT_DIR/local/analytics.py" --database "$oversized_database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"0"}' --now 1785866400 2>&1)"; then
  fail "oversized token pricing breakdown accepted"
fi
assert_contains "$oversized_error" "token pricing breakdown exceeds the 2000-group processing limit" "oversized token pricing breakdown error"

filtered="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","source":"codex","model":"gpt-5.6-sol","reset_type":"weekly"}' \
  --now 1785866400)"
assert_eq 1 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["events"])' <<<"$filtered")" "source/model filter"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["total"])' <<<"$filtered")" "reset type filter"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["weekly_total"])' <<<"$filtered")" "weekly reset metric ignores history filter"

multi_filtered="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","sources":"codex,hermes","models":"gpt-5.6-sol,unknown-model"}' \
  --now 1785866400)"
assert_eq 3 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["events"])' <<<"$multi_filtered")" "multiple source/model filters"

dst_period="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"from_date":"2026-03-29","to_date":"2026-03-30"}' \
  --now 1785866400)"
assert_eq 169200 "$(python3 -c 'import json,sys; value=json.load(sys.stdin)["period"]; print(int((__import__("datetime").datetime.fromisoformat(value["to"].replace("Z","+00:00")).timestamp()) - (__import__("datetime").datetime.fromisoformat(value["from"].replace("Z","+00:00")).timestamp())))' <<<"$dst_period")" "Europe/Paris DST custom period duration"
assert_eq 900 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["period"]["granularity_seconds"])' <<<"$dst_period")" "DST custom period granularity"

python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"invalid"}' >/dev/null 2>&1 && fail "invalid range accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"from_date":"2026-08-04"}' >/dev/null 2>&1 && fail "unpaired custom date accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","sources":"codex,invalid"}' >/dev/null 2>&1 && fail "invalid source list accepted"
extreme_date_error="${TEST_ROOT}/extreme-date-error"
if python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"from_date":"9999-12-31","to_date":"9999-12-31"}' >/dev/null 2>"$extreme_date_error"; then
  fail "out-of-range custom date accepted"
fi
assert_contains "$(<"$extreme_date_error")" '[ERROR] dates must use YYYY-MM-DD' "out-of-range date error"
if grep -Fq 'Traceback' "$extreme_date_error"; then
  fail "out-of-range custom date exposed a traceback"
fi

python3 - "$ROOT_DIR" "$TEST_ROOT" <<'PY'
import copy
import json
from pathlib import Path
import sys
from datetime import datetime, timezone

root = Path(sys.argv[1])
test_root = Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
import analytics
from analytics import AnalyticsError, build_payload, price_index, token_analytics
from storage import connect_database
from token_usage import CollectorError, load_pricing

terra_luna_boundary = 1785369600  # 2026-07-30T00:00:00Z
sol_boundary = 1787270400  # 2026-08-21T00:00:00Z
database = test_root / "temporal-pricing.sqlite3"
with connect_database(database) as connection:
    events = [
        # Calendar pricing boundaries are inclusive at exactly 00:00:00Z.
        (terra_luna_boundary - 1, "openai", "gpt-5.6-terra", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "terra-before"),
        (terra_luna_boundary, "openai", "gpt-5.6-terra", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "terra-at"),
        (terra_luna_boundary - 1, "openai", "gpt-5.6-luna", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "luna-before"),
        (terra_luna_boundary, "openai", "gpt-5.6-luna", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "luna-at"),
        (sol_boundary - 1, "openai", "gpt-5.6-sol", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "sol-before"),
        (sol_boundary, "openai", "gpt-5.6-sol", 1_000_000, 1_000_000, 1_000_000, 1_000_000, "sol-at"),
        (sol_boundary, "openai", "gpt-5.6-sol-pro", 1_000_000, 0, 0, 0, "sol-alias"),
        (sol_boundary, "openai-codex", "gpt-5.6-sol", 1_000_000, 0, 0, 0, "sol-identifier"),
    ]
    connection.executemany(
        """INSERT INTO token_usage_events(
             occurred_at_epoch, source, provider, model, input_tokens,
             cache_read_tokens, cache_write_tokens, output_tokens, external_id
           ) VALUES (?, 'codex', ?, ?, ?, ?, ?, ?, ?)""",
        events,
    )
payload = build_payload(
    database,
    root / "local" / "pricing.json",
    {"from_date": "2026-07-29", "to_date": "2026-08-22"},
    now=sol_boundary + 86400,
)
assert payload["pricing"] == {
    "currency": "USD", "as_of": "2026-08-21", "valuation_mode": "effective_catalog"
}
assert payload["tokens"]["summary"]["estimated_cost_usd"] == 126.745, payload["tokens"]["summary"]
breakdown = {(row["provider"], row["model"]): row["estimated_cost_usd"] for row in payload["tokens"]["breakdown"]}
assert breakdown[("openai", "gpt-5.6-sol")] == 71.15, breakdown
assert breakdown[("openai", "gpt-5.6-sol-pro")] == 4.0, breakdown
assert breakdown[("openai-codex", "gpt-5.6-sol")] == 4.0, breakdown
assert breakdown[("openai", "gpt-5.6-terra")] == 37.575, breakdown
assert breakdown[("openai", "gpt-5.6-luna")] == 10.02, breakdown
series = {row["at"]: row["estimated_cost_usd"] for row in payload["tokens"]["series"]}
assert series == {
    "2026-07-29T23:30:00Z": 29.225,
    "2026-07-30T00:00:00Z": 18.37,
    "2026-08-20T23:30:00Z": 41.75,
    "2026-08-21T00:00:00Z": 37.4,
}, series
assert round(sum(series.values()), 8) == 126.745

catalog = load_pricing(root / "local" / "pricing.json")
v1 = {
    "schema_version": 1, "currency": "USD", "unknown_model_policy": "assumed_zero",
    "entries": [{"provider": "test", "model": "model", "input_per_million": 1,
                 "cache_read_per_million": 1, "cache_write_per_million": 1,
                 "output_per_million": 1}],
}
v1_path = test_root / "pricing-v1.json"
v1_path.write_text(json.dumps(v1), encoding="utf-8")
assert load_pricing(v1_path)["schema_version"] == 1
invalid = copy.deepcopy(catalog)
invalid["entries"][0]["periods"][1]["effective_from"] = invalid["entries"][0]["periods"][0]["effective_from"]
bad_path = test_root / "pricing-invalid-periods.json"
bad_path.write_text(json.dumps(invalid), encoding="utf-8")
try:
    load_pricing(bad_path)
except CollectorError:
    pass
else:
    raise AssertionError("non-increasing pricing periods were accepted")
invalid_rate = copy.deepcopy(catalog)
invalid_rate["entries"][0]["periods"][1]["output_per_million"] = -1
bad_rate_path = test_root / "pricing-invalid-rate.json"
bad_rate_path.write_text(json.dumps(invalid_rate), encoding="utf-8")
try:
    load_pricing(bad_rate_path)
except CollectorError:
    pass
else:
    raise AssertionError("negative pricing rate was accepted")

fractional = copy.deepcopy(catalog)
fractional["entries"][0]["periods"][1]["effective_from"] = "2026-08-21T00:00:00.001Z"
fractional_path = test_root / "pricing-fractional-boundary.json"
fractional_path.write_text(json.dumps(fractional), encoding="utf-8")
try:
    load_pricing(fractional_path)
except CollectorError:
    pass
else:
    raise AssertionError("fractional pricing boundary was accepted")
try:
    price_index(fractional)
except AnalyticsError:
    pass
else:
    raise AssertionError("analytics accepted a fractional pricing boundary")

too_many_boundaries = {
    "schema_version": 2,
    "currency": "USD",
    "unknown_model_policy": "assumed_zero",
    "entries": [],
}
for entry_index in range(5):
    periods = []
    for period_index in range(64):
        seconds = 0 if period_index == 0 else entry_index * 64 + period_index
        effective = datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")
        periods.append({
            "effective_from": effective,
            "input_per_million": 0,
            "cache_read_per_million": 0,
            "cache_write_per_million": 0,
            "output_per_million": 0,
        })
    too_many_boundaries["entries"].append({
        "provider": f"provider-{entry_index}",
        "model": "model",
        "periods": periods,
    })
too_many_path = test_root / "pricing-too-many-boundaries.json"
too_many_path.write_text(json.dumps(too_many_boundaries), encoding="utf-8")
try:
    load_pricing(too_many_path)
except CollectorError:
    pass
else:
    raise AssertionError("catalog with too many effective boundaries was accepted")

global_limit_catalog = {
    "schema_version": 2,
    "currency": "USD",
    "unknown_model_policy": "assumed_zero",
    "entries": [{
        "provider": "test-provider",
        "model": "test-model",
        "periods": [
            {"effective_from": "1970-01-01T00:00:00Z", "input_per_million": 1,
             "cache_read_per_million": 0, "cache_write_per_million": 0, "output_per_million": 0},
            {"effective_from": "1970-01-01T00:01:40Z", "input_per_million": 2,
             "cache_read_per_million": 0, "cache_write_per_million": 0, "output_per_million": 0},
        ],
    }],
}
global_limit_database = test_root / "pricing-global-limit.sqlite3"
with connect_database(global_limit_database) as connection:
    connection.row_factory = __import__("sqlite3").Row
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (?, 'codex', 'test-provider', 'test-model', 1000000, ?)""",
        [(50, "global-limit-before"), (150, "global-limit-after")],
    )
old_processing_limit = analytics.MAX_PRICING_PROCESSING_ROWS
analytics.MAX_PRICING_PROCESSING_ROWS = 1
try:
    try:
        with connect_database(global_limit_database, read_only=True) as connection:
            connection.row_factory = __import__("sqlite3").Row
            token_analytics(connection, global_limit_catalog, 0, 200, 60, (), (), None)
    except AnalyticsError as exc:
        assert "1-row processing limit" in str(exc), exc
    else:
        raise AssertionError("pricing intermediate row limit reset between segments")
finally:
    analytics.MAX_PRICING_PROCESSING_ROWS = old_processing_limit
PY

printf 'PASS: advanced analytics query tests\n'
