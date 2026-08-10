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
assert_eq 1 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["schema_version"])' <<<"$payload")" "analytics schema version"
assert_eq 8 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$payload")" "unpaginated breakdown keeps all rows"
assert_eq false "$(python3 -c 'import json,sys; print(str("breakdown_pagination" in json.load(sys.stdin)["tokens"]).lower())' <<<"$payload")" "unpaginated response keeps its existing shape"
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$payload")" "estimated cost including GPT-5.6 Sol provider aliases"
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
assert_eq 52 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["baselines"]["hermes"][0]["tokens"])' <<<"$payload")" "Hermes baseline excludes the reasoning sub-counter"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["samples"])' <<<"$payload")" "limit bucket sample count"
assert_eq 45.0 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["five_h_pct"])' <<<"$payload")" "limit bucket keeps the latest sample"
expected_pricing_hash="$(python3 -c 'from hashlib import sha256; from pathlib import Path; import sys; print(sha256(Path(sys.argv[1]).read_bytes()).hexdigest())' "$ROOT_DIR/local/pricing.json")"
pricing_hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$payload")"
assert_eq "$expected_pricing_hash" "$pricing_hash" "pricing hash uses exact catalog bytes"

paginated="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"2","breakdown_limit":"3"}' \
  --now 1785866400)"
assert_eq 3 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$paginated")" "paginated breakdown page size"
assert_eq '2 3 8' "$(python3 -c 'import json,sys; page=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print(page["offset"], page["limit"], page["total"])' <<<"$paginated")" "breakdown pagination metadata"
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$paginated")" "paginated estimated cost stays global"
assert_eq 8 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["events"])' <<<"$paginated")" "paginated event summary stays global"
assert_eq "$pricing_hash" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$paginated")" "pricing hash is stable"

empty_page="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' \
  --breakdown-offset 100 \
  --breakdown-limit 10 \
  --now 1785866400)"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$empty_page")" "empty breakdown page"
assert_eq '100 10 8' "$(python3 -c 'import json,sys; page=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print(page["offset"], page["limit"], page["total"])' <<<"$empty_page")" "empty breakdown page metadata"
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$empty_page")" "empty page estimated cost stays global"

maximum_offset="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","reset_offset":"1000000","reset_limit":"1","breakdown_offset":"1000000","breakdown_limit":"1"}' \
  --now 1785866400)"
assert_eq 1000000 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["offset"])' <<<"$maximum_offset")" "maximum reset offset"
assert_eq 1000000 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["offset"])' <<<"$maximum_offset")" "maximum breakdown offset"

changed_pricing="${TEST_ROOT}/pricing-changed.json"
cp "$ROOT_DIR/local/pricing.json" "$changed_pricing"
printf '\n' >>"$changed_pricing"
changed_payload="$(python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$changed_pricing" --params '{"range":"24h"}' --now 1785866400)"
changed_hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$changed_payload")"
expected_changed_hash="$(python3 -c 'from hashlib import sha256; from pathlib import Path; import sys; print(sha256(Path(sys.argv[1]).read_bytes()).hexdigest())' "$changed_pricing")"
assert_eq "$expected_changed_hash" "$changed_hash" "changed pricing hash uses exact catalog bytes"
if [[ "$changed_hash" == "$pricing_hash" ]]; then
  fail "pricing hash did not change with catalog bytes"
fi

boundary_database="${TEST_ROOT}/analytics-boundaries.sqlite3"
python3 - "$ROOT_DIR" "$boundary_database" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

with connect_database(Path(sys.argv[2])) as connection:
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (1785859200, 'codex', ?, 'shared-unknown-model', 1, ?)""",
        ((f"unknown-provider-{index:04d}", f"boundary-{index:04d}") for index in range(2000)),
    )
PY
boundary_2000="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$boundary_database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' --now 1785866400)"
assert_eq 2000 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$boundary_2000")" "unpaginated 2000-group boundary"
assert_eq 2000 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["total_tokens"])' <<<"$boundary_2000")" "2000-group global total"
assert_eq 1 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["warnings"]))' <<<"$boundary_2000")" "unknown pricing warnings are aggregated"
assert_eq 2000 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["unknown_pricing_groups"])' <<<"$boundary_2000")" "unknown pricing group counter"

python3 - "$boundary_database" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (1785859200, 'codex', 'unknown-provider-2000', 'shared-unknown-model', 1, 'boundary-2000')"""
    )
PY
boundary_error="${TEST_ROOT}/analytics-boundary-error"
if python3 "$ROOT_DIR/local/analytics.py" \
  --database "$boundary_database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' --now 1785866400 >/dev/null 2>"$boundary_error"; then
  fail "unpaginated 2001-group response was accepted"
fi
assert_contains "$(<"$boundary_error")" 'token breakdown exceeds the 2000-group response limit' "2001-group boundary error"

boundary_page="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$boundary_database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"2000","breakdown_limit":"100"}' --now 1785866400)"
assert_eq 1 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$boundary_page")" "page beyond 2000 groups"
assert_eq '2000 100 2001' "$(python3 -c 'import json,sys; page=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print(page["offset"], page["limit"], page["total"])' <<<"$boundary_page")" "page beyond 2000 metadata"
assert_eq '2001 2001 1' "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["tokens"]["summary"]["events"], data["tokens"]["summary"]["total_tokens"], len(data["warnings"]))' <<<"$boundary_page")" "paginated global totals and bounded warnings"
assert_contains "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["warnings"][0])' <<<"$boundary_page")" '+1981 more' "unknown pricing examples are capped"

boundary_empty="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$boundary_database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"2100","breakdown_limit":"100"}' --now 1785866400)"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$boundary_empty")" "empty page beyond breakdown"
assert_eq '2100 100 2001' "$(python3 -c 'import json,sys; page=json.load(sys.stdin)["tokens"]["breakdown_pagination"]; print(page["offset"], page["limit"], page["total"])' <<<"$boundary_empty")" "empty page metadata beyond breakdown"

python3 - "$boundary_database" <<'PY'
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.executemany(
        """INSERT INTO token_usage_events
           (occurred_at_epoch, source, provider, model, input_tokens, external_id)
           VALUES (1785859200, 'codex', ?, 'shared-unknown-model', 1, ?)""",
        ((f"unknown-provider-{index:04d}", f"boundary-{index:04d}") for index in range(2001, 5000)),
    )
    connection.execute(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (1785840000, "2026-08-04T02:40:00Z", 50, None, None, 70, None, 1786450000, 900, 192, "cardinality"),
    )
    connection.executemany(
        "INSERT INTO reset_events VALUES ('weekly', ?, ?, 30, 100, ?)",
        (
            (1785850000 + index, 1785850000 + index, "random_observed" if index % 2 else "scheduled_crossing")
            for index in range(5000)
        ),
    )
    connection.executemany(
        "INSERT INTO collector_state VALUES ('hermes', ?, ?, 1785860000)",
        (
            (f"baseline-{index:04d}", json.dumps({"baseline": {"input_tokens": 1}}))
            for index in range(1000)
        ),
    )
PY
cardinality_payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$boundary_database" --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"0","breakdown_limit":"50"}' --now 1785866400)"
assert_eq '50 5000 5000' "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(len(data["tokens"]["breakdown"]), data["tokens"]["breakdown_pagination"]["total"], data["tokens"]["summary"]["unknown_pricing_groups"])' <<<"$cardinality_payload")" "large-cardinality breakdown"
assert_contains "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["warnings"][0])' <<<"$cardinality_payload")" 'unknown-provider-0000/shared-unknown-model' "deterministic first unknown pricing example"
assert_contains "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["warnings"][0])' <<<"$cardinality_payload")" '+4980 more' "large-cardinality warning cap"
assert_eq '5000 2500 2500 50' "$(python3 -c 'import json,sys; data=json.load(sys.stdin)["resets"]; print(data["weekly_total"], data["weekly_summary"]["random"]["count"], data["weekly_summary"]["end_of_week"]["count"], len(data["items"]))' <<<"$cardinality_payload")" "large-cardinality reset aggregation"
assert_eq '500 1000 501' "$(python3 -c 'import json,sys; rows=json.load(sys.stdin)["baselines"]["hermes"]; aggregate=rows[-1]; print(len(rows), sum(row["tokens"] for row in rows), aggregate["aggregated_entries"])' <<<"$cardinality_payload")" "bounded Hermes baselines preserve totals"

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
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"0"}' >/dev/null 2>&1 && fail "unpaired breakdown pagination accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"-1","breakdown_limit":"50"}' >/dev/null 2>&1 && fail "negative breakdown offset accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"24h","breakdown_offset":"0","breakdown_limit":"101"}' >/dev/null 2>&1 && fail "oversized breakdown page accepted"
for invalid_pagination in \
  '{"range":"24h","reset_offset":"1000001"}' \
  '{"range":"24h","breakdown_offset":"1000001","breakdown_limit":"1"}' \
  '{"range":"24h","reset_offset":"9223372036854775808"}' \
  '{"range":"24h","breakdown_offset":"999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999","breakdown_limit":"1"}'; do
  pagination_error="${TEST_ROOT}/pagination-error"
  if python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" \
    --params "$invalid_pagination" >/dev/null 2>"$pagination_error"; then
    fail "out-of-range pagination accepted: $invalid_pagination"
  fi
  if grep -Fq 'Traceback' "$pagination_error"; then
    fail "out-of-range pagination exposed a traceback"
  fi
done
extreme_date_error="${TEST_ROOT}/extreme-date-error"
if python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"from_date":"9999-12-31","to_date":"9999-12-31"}' >/dev/null 2>"$extreme_date_error"; then
  fail "out-of-range custom date accepted"
fi
assert_contains "$(<"$extreme_date_error")" '[ERROR] dates must use YYYY-MM-DD' "out-of-range date error"
if grep -Fq 'Traceback' "$extreme_date_error"; then
  fail "out-of-range custom date exposed a traceback"
fi

printf 'PASS: advanced analytics query tests\n'
