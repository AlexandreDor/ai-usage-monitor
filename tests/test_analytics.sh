#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

database="${TEST_ROOT}/analytics.sqlite3"
pricing_file="${TEST_ROOT}/pricing.json"
cp "$ROOT_DIR/local/pricing.json" "$pricing_file"
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
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$payload")" "estimated cost including GPT-5.6 Sol provider aliases"
assert_eq 900 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["period"]["granularity_seconds"])' <<<"$payload")" "24-hour analytics granularity"
assert_eq 100 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["assumed_zero_tokens"])' <<<"$payload")" "unknown model token count"
assert_eq 8 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$payload")" "unpaginated breakdown keeps all groups"
assert_eq absent "$(python3 -c 'import json,sys; print("present" if "breakdown_pagination" in json.load(sys.stdin)["tokens"] else "absent")' <<<"$payload")" "unpaginated breakdown has no pagination metadata"
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

pricing_hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$payload")"
if [[ ! "$pricing_hash" =~ ^[0-9a-f]{64}$ ]]; then
  fail "pricing fingerprint is not a SHA-256 digest"
fi

python3 - "$pricing_file" <<'PYEOF'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
catalog = json.loads(path.read_text(encoding="utf-8"))
path.write_text(json.dumps(catalog, indent=4, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
formatted_payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$pricing_file" \
  --params '{"range":"24h"}' \
  --now 1785866400)"
formatted_hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$formatted_payload")"
assert_eq "$pricing_hash" "$formatted_hash" "pricing fingerprint ignores JSON formatting"

paged="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"2","breakdown_limit":"3"}' \
  --now 1785866400)"
assert_eq 3 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$paged")" "breakdown page size"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["offset"])' <<<"$paged")" "breakdown page offset"
assert_eq 3 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["limit"])' <<<"$paged")" "breakdown page limit"
assert_eq 8 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["total"])' <<<"$paged")" "breakdown page total"
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$paged")" "paginated summary remains complete"

empty_page="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","breakdown_offset":"8","breakdown_limit":"50"}' \
  --now 1785866400)"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["breakdown"]))' <<<"$empty_page")" "empty breakdown page"
assert_eq 8 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["breakdown_pagination"]["total"])' <<<"$empty_page")" "empty breakdown page total"

for invalid_params in \
  '{"range":"24h","breakdown_limit":"0"}' \
  '{"range":"24h","breakdown_limit":"101"}' \
  '{"range":"24h","breakdown_offset":"-1"}' \
  '{"range":"24h","breakdown_limit":"not-an-integer"}' \
  '{"range":"24h","breakdown_offset":"1","token_offset":"2"}' \
  '{"range":"24h","breakdown_limit":"50","token_limit":"50"}'; do
  if python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params "$invalid_params" --now 1785866400 >/dev/null 2>&1; then
    fail "invalid breakdown pagination accepted: $invalid_params"
  fi
done

if python3 - "$ROOT_DIR" "$database" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
database = Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
from analytics import AnalyticsError, build_payload

try:
    build_payload(database, root / "local" / "pricing.json", {"range": "24h", "breakdown_limit": ["50", "100"]}, now=1785866400)
except AnalyticsError:
    raise SystemExit(0)
raise SystemExit("repeated breakdown pagination accepted")
PYEOF
then
  :
else
  fail "repeated breakdown pagination did not raise AnalyticsError"
fi

python3 - "$pricing_file" <<'PYEOF'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
catalog = json.loads(path.read_text(encoding="utf-8"))
catalog["entries"][0]["input_per_million"] += 0.001
path.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
changed_payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$pricing_file" \
  --params '{"range":"24h"}' \
  --now 1785866400)"
changed_hash="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pricing"]["sha256"])' <<<"$changed_payload")"
[[ "$changed_hash" != "$pricing_hash" ]] || fail "pricing fingerprint did not change with the catalog"

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

printf 'PASS: advanced analytics query tests\n'
