#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

ANALYTICS_SCRIPT="${ROOT_DIR}/local/token_usage.py"
PRICING_FILE="${ROOT_DIR}/local/pricing.json"
ANALYTICS_DB="${TEST_ROOT}/usage.sqlite3"
CODEX_DIR="${TEST_ROOT}/codex"
OPENCODE_DB="${TEST_ROOT}/opencode.db"
HERMES_DB="${TEST_ROOT}/hermes.db"

mkdir -p "${CODEX_DIR}/sessions/1970/01/01"
apply_fixture="${CODEX_DIR}/sessions/1970/01/01/rollout-1970-01-01T00-00-00-00000000-0000-0000-0000-000000000001.jsonl"
printf '%s\n' \
  '{"timestamp":"1970-01-01T00:10:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000001","model_provider":"openai","originator":"codex_cli"}}' \
  '{"timestamp":"1970-01-01T00:10:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}' \
  '{"timestamp":"1970-01-01T00:10:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5}}}}' \
  '{"timestamp":"1970-01-01T00:10:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":70,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":7}}}}' \
  > "$apply_fixture"

python3 - "$OPENCODE_DB" "$HERMES_DB" <<'PYEOF'
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("CREATE TABLE message(id TEXT, time_updated INTEGER, data TEXT)")
    connection.execute(
        "INSERT INTO message VALUES (?, ?, ?)",
        (
            "message-1",
            1_500_000,
            json.dumps({
                "role": "assistant",
                "modelID": "gpt-5.6-terra",
                "providerID": "openai",
                "time": {"completed": 1_500_000},
                "tokens": {
                    "input": 10,
                    "output": 3,
                    "reasoning": 2,
                    "cache": {"read": 4, "write": 1},
                },
            }),
        ),
    )

with sqlite3.connect(sys.argv[2]) as connection:
    connection.execute("""
        CREATE TABLE session_model_usage(
            session_id TEXT, model TEXT, billing_provider TEXT,
            billing_mode TEXT, task TEXT, input_tokens INTEGER,
            output_tokens INTEGER, cache_read_tokens INTEGER,
            cache_write_tokens INTEGER, reasoning_tokens INTEGER,
            first_seen REAL, last_seen REAL
        )
    """)
    connection.execute(
        "INSERT INTO session_model_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ("session-1", "gpt-5.6-luna", "openai-codex", "subscription_included", "", 5, 2, 3, 0, 1, 1200, 1800),
    )
PYEOF

collect() {
  python3 "$ANALYTICS_SCRIPT" \
    --database "$ANALYTICS_DB" \
    --pricing "$PRICING_FILE" \
    --sources codex,opencode,hermes \
    --retention-days 365 \
    --codex-data-dir "$CODEX_DIR" \
    --opencode-db "$OPENCODE_DB" \
    --hermes-db "$HERMES_DB" \
    --now "$1" >/dev/null
}

collect 2000
assert_eq 3 "$(python3 - "$ANALYTICS_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM token_usage_events").fetchone()[0])
PYEOF
)" "initial exact event import count"

python3 - "$ANALYTICS_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    codex = connection.execute(
        "SELECT SUM(input_tokens), SUM(cache_read_tokens), SUM(output_tokens), SUM(reasoning_tokens) "
        "FROM token_usage_events WHERE source = 'codex'"
    ).fetchone()
    assert codex == (90, 70, 30, 7), codex
    opencode = connection.execute(
        "SELECT input_tokens, cache_read_tokens, cache_write_tokens, output_tokens, reasoning_tokens "
        "FROM token_usage_events WHERE source = 'opencode'"
    ).fetchone()
    assert opencode == (10, 4, 1, 5, 2), opencode
    assert connection.execute(
        "SELECT COUNT(*) FROM token_usage_events WHERE source = 'hermes'"
    ).fetchone()[0] == 0
PYEOF

python3 - "$HERMES_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "UPDATE session_model_usage SET input_tokens = 13, output_tokens = 6, "
        "cache_read_tokens = 5, reasoning_tokens = 2, last_seen = 2100"
    )
PYEOF

collect 2200
assert_eq 4 "$(python3 - "$ANALYTICS_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM token_usage_events").fetchone()[0])
PYEOF
)" "Hermes delta was not added or exact imports duplicated"

python3 - "$ANALYTICS_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    hermes = connection.execute(
        "SELECT input_tokens, cache_read_tokens, output_tokens, reasoning_tokens, quality "
        "FROM token_usage_events WHERE source = 'hermes'"
    ).fetchone()
    assert hermes == (8, 2, 4, 1, "polled_delta"), hermes
    statuses = connection.execute(
        "SELECT source, status FROM collector_runs ORDER BY source"
    ).fetchall()
    assert statuses == [("codex", "ok"), ("hermes", "ok"), ("opencode", "ok")], statuses
PYEOF

collect 2300
assert_eq 4 "$(python3 - "$ANALYTICS_DB" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM token_usage_events").fetchone()[0])
PYEOF
)" "idempotent collection created duplicate events"

printf 'PASS: local token usage collector tests\n'
