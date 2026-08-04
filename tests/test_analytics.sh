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
        "INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)",
        ("5h", 1785862800, 1785863700, 5, 100, "scheduled_crossing"),
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
    connection.execute(
        "INSERT INTO collector_runs VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("codex", 1, "ok", 1785859500, 1785859500, None, "fixture-v1"),
    )
    connection.execute(
        "INSERT INTO collector_state VALUES (?, ?, ?, ?)",
        ("hermes", "session:model", json.dumps({"baseline": {"input_tokens": 42}}), 1785859500),
    )
connection.close()
PY

payload="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h"}' \
  --now 1785866400)"
assert_eq 21.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["estimated_cost_usd"])' <<<"$payload")" "estimated cost including GPT-5.6 Sol provider aliases"
assert_eq 100 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["assumed_zero_tokens"])' <<<"$payload")" "unknown model token count"
assert_eq priced "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(item["pricing_status"] for item in data["tokens"]["breakdown"] if item["provider"] == "openai-codex"))' <<<"$payload")" "openai-codex GPT-5.6 Sol pricing"
assert_eq priced "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(item["pricing_status"] for item in data["tokens"]["breakdown"] if item["provider"] == "auto"))' <<<"$payload")" "auto GPT-5.6 Sol pricing"
assert_eq 1 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["total"])' <<<"$payload")" "reset count"
assert_eq 42 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["baselines"]["hermes"][0]["tokens"])' <<<"$payload")" "Hermes baseline"

filtered="$(python3 "$ROOT_DIR/local/analytics.py" \
  --database "$database" \
  --pricing "$ROOT_DIR/local/pricing.json" \
  --params '{"range":"24h","source":"codex","model":"gpt-5.6-sol","reset_type":"weekly"}' \
  --now 1785866400)"
assert_eq 1 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["events"])' <<<"$filtered")" "source/model filter"
assert_eq 0 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["total"])' <<<"$filtered")" "reset type filter"

python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"range":"invalid"}' >/dev/null 2>&1 && fail "invalid range accepted"
python3 "$ROOT_DIR/local/analytics.py" --database "$database" --pricing "$ROOT_DIR/local/pricing.json" --params '{"from_date":"2026-08-04"}' >/dev/null 2>&1 && fail "unpaired custom date accepted"

printf 'PASS: advanced analytics query tests\n'
