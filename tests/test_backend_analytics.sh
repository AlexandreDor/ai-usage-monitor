#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

STORAGE_DIR="${ROOT_DIR}/local"
DB="${TEST_ROOT}/archive.sqlite3"

# A real v1 archive contains the metadata and snapshots tables and has the
# SQLite user_version set to 1. Migration must preserve its snapshots.
python3 - "$DB" <<'PYEOF'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.executescript("""
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE snapshots (
          scraped_at_epoch INTEGER PRIMARY KEY, scraped_at TEXT NOT NULL,
          five_h_pct REAL, five_h_reset TEXT, five_h_reset_at INTEGER,
          weekly_pct REAL, weekly_reset TEXT, weekly_reset_at INTEGER,
          sample_interval_seconds INTEGER, history_window_hours REAL,
          limit_id TEXT
        );
        INSERT INTO metadata VALUES ('schema_version', '1');
        INSERT INTO snapshots VALUES (1000, '1970-01-01T00:16:40Z', 80, NULL, NULL, 70, NULL, NULL, 900, 192, 'v1');
        PRAGMA user_version = 1;
    """)
PYEOF
python3 - "$STORAGE_DIR" "$DB" <<'PYEOF'
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, sys.argv[1])
import storage
from storage import ArchiveSchemaError, connect_database

with connect_database(Path(sys.argv[2])) as connection:
    assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
    assert connection.execute("SELECT limit_id FROM snapshots").fetchone()[0] == "v1"
    assert connection.execute("SELECT value FROM metadata WHERE key = 'schema_version'").fetchone()[0] == "4"
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"reset_events", "token_usage_events", "collector_state", "collector_runs", "forecast_samples", "quota_anomalies", "anomaly_detector_state"} <= tables

v2 = Path(sys.argv[2]).with_name("v2.sqlite3")
with connect_database(v2) as connection:
    connection.execute("DROP TABLE forecast_samples")
    connection.execute("PRAGMA user_version = 2")
    connection.execute("UPDATE metadata SET value = '2' WHERE key = 'schema_version'")
with connect_database(v2) as connection:
    assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
    assert connection.execute("SELECT value FROM metadata WHERE key = 'schema_version'").fetchone()[0] == "4"
    assert connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='forecast_samples'"
    ).fetchone()

v3 = Path(sys.argv[2]).with_name("v3.sqlite3")
with sqlite3.connect(v3) as connection:
    for statement in storage._V3_SCHEMA_STATEMENTS:
        connection.execute(statement)
    connection.execute(
        "INSERT INTO metadata(key, value) VALUES ('schema_version', '3')"
    )
    connection.execute("PRAGMA user_version = 3")
with connect_database(v3) as connection:
    assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
    assert connection.execute("SELECT value FROM metadata WHERE key = 'schema_version'").fetchone()[0] == "4"
    assert connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='quota_anomalies'"
    ).fetchone()

partial_v3 = Path(sys.argv[2]).with_name("partial-v3.sqlite3")
with connect_database(partial_v3) as connection:
    connection.execute("DROP TABLE forecast_samples")
    connection.execute("CREATE TABLE forecast_samples (scraped_at_epoch INTEGER PRIMARY KEY)")
try:
    connect_database(partial_v3)
except ArchiveSchemaError:
    pass
else:
    raise AssertionError("partial v3 Forecast table was accepted")

unknown = Path(sys.argv[2]).with_name("unknown.sqlite3")
with sqlite3.connect(unknown) as connection:
    connection.execute("PRAGMA user_version = 99")
try:
    connect_database(unknown)
except ArchiveSchemaError:
    pass
else:
    raise AssertionError("unknown archive schema was accepted")

partial = Path(sys.argv[2]).with_name("partial-legacy.sqlite3")
with sqlite3.connect(partial) as connection:
    connection.executescript("""
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE snapshots (
          scraped_at_epoch INTEGER PRIMARY KEY, scraped_at TEXT NOT NULL,
          five_h_pct REAL, five_h_reset TEXT, five_h_reset_at INTEGER,
          weekly_pct REAL, weekly_reset TEXT, weekly_reset_at INTEGER,
          sample_interval_seconds INTEGER, history_window_hours REAL,
          limit_id TEXT
        );
        CREATE TABLE token_usage_events (id INTEGER PRIMARY KEY);
    """)
try:
    connect_database(partial)
except ArchiveSchemaError:
    pass
else:
    raise AssertionError("partial legacy archive was promoted to schema v4")
PYEOF

# An existing but empty Codex directory is optional in auto mode.
mkdir -p "${TEST_ROOT}/codex/sessions"
python3 "${ROOT_DIR}/local/token_usage.py" \
  --database "${TEST_ROOT}/auto.sqlite3" --pricing "${ROOT_DIR}/local/pricing.json" \
  --sources auto --retention-days 365 --codex-data-dir "${TEST_ROOT}/codex" \
  --opencode-db "${TEST_ROOT}/missing-opencode.db" --hermes-db "${TEST_ROOT}/missing-hermes.db" \
  --now 2000
assert_eq disabled "$(python3 - "${TEST_ROOT}/auto.sqlite3" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT status FROM collector_runs WHERE source='codex'").fetchone()[0])
PYEOF
)" "empty Codex auto source status"

# Exercise a partial final line, then an atomic replacement with a larger
# file. Both cases must resume/replay idempotently rather than lose a prefix.
CODEX_FILE="${TEST_ROOT}/codex/sessions/rollout-00000000-0000-0000-0000-000000000001.jsonl"
printf '%s\n' \
  '{"timestamp":"1970-01-01T00:10:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000001","model_provider":"openai"}}' \
  '{"timestamp":"1970-01-01T00:10:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}' \
  '{"timestamp":"1970-01-01T00:10:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":2}}}}' \
  > "$CODEX_FILE"
printf '%s' '{"timestamp":"1970-01-01T00:10:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":4}}' \
  >> "$CODEX_FILE"
python3 "${ROOT_DIR}/local/token_usage.py" \
  --database "${TEST_ROOT}/cursor.sqlite3" --pricing "${ROOT_DIR}/local/pricing.json" \
  --sources codex --retention-days 365 --codex-data-dir "${TEST_ROOT}/codex" \
  --opencode-db "${TEST_ROOT}/missing-opencode.db" --hermes-db "${TEST_ROOT}/missing-hermes.db" \
  --now 2000 >/dev/null
assert_eq 1 "$(python3 - "${TEST_ROOT}/cursor.sqlite3" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM token_usage_events").fetchone()[0])
PYEOF
)" "partial Codex line was consumed"
printf '}}\n' >> "$CODEX_FILE"
python3 "${ROOT_DIR}/local/token_usage.py" \
  --database "${TEST_ROOT}/cursor.sqlite3" --pricing "${ROOT_DIR}/local/pricing.json" \
  --sources codex --retention-days 365 --codex-data-dir "${TEST_ROOT}/codex" \
  --opencode-db "${TEST_ROOT}/missing-opencode.db" --hermes-db "${TEST_ROOT}/missing-hermes.db" \
  --now 2100 >/dev/null

replacement="${TEST_ROOT}/replacement.jsonl"
printf '%s\n' \
  '{"timestamp":"1970-01-01T00:10:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000001","model_provider":"openai"}}' \
  '{"timestamp":"1970-01-01T00:10:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}' \
  '{"timestamp":"1970-01-01T00:10:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":6}}}}' \
  > "$replacement"
mv "$replacement" "$CODEX_FILE"
python3 "${ROOT_DIR}/local/token_usage.py" \
  --database "${TEST_ROOT}/cursor.sqlite3" --pricing "${ROOT_DIR}/local/pricing.json" \
  --sources codex --retention-days 365 --codex-data-dir "${TEST_ROOT}/codex" \
  --opencode-db "${TEST_ROOT}/missing-opencode.db" --hermes-db "${TEST_ROOT}/missing-hermes.db" \
  --now 2200 >/dev/null
assert_eq 3 "$(python3 - "${TEST_ROOT}/cursor.sqlite3" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM token_usage_events").fetchone()[0])
PYEOF
)" "Codex rotation replay was not idempotent"

# A matching rollout that cannot be inspected must fail the explicit source
# instead of recording a misleading successful collection.
mkdir -p "${TEST_ROOT}/unreadable-codex/sessions"
ln -s "${TEST_ROOT}/missing-rollout.jsonl" "${TEST_ROOT}/unreadable-codex/sessions/broken.jsonl"
if python3 "${ROOT_DIR}/local/token_usage.py" \
  --database "${TEST_ROOT}/unreadable.sqlite3" --pricing "${ROOT_DIR}/local/pricing.json" \
  --sources codex --retention-days 365 --codex-data-dir "${TEST_ROOT}/unreadable-codex" \
  --opencode-db "${TEST_ROOT}/missing-opencode.db" --hermes-db "${TEST_ROOT}/missing-hermes.db" \
  --now 2200 >/dev/null 2>&1; then
  fail "unreadable Codex rollout reported success"
fi
assert_eq error "$(python3 - "${TEST_ROOT}/unreadable.sqlite3" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT status FROM collector_runs WHERE source='codex'").fetchone()[0])
PYEOF
)" "unreadable Codex rollout status"

# Analytics additions: total fields, source series, cost buckets, reset
# markers, and the selected 30-day granularity.
PRICING="${TEST_ROOT}/pricing.json"
cp "${ROOT_DIR}/local/pricing.json" "$PRICING"
python3 - "$ROOT_DIR" "${TEST_ROOT}/analytics.sqlite3" <<'PYEOF'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / "local"))
from storage import connect_database

with connect_database(Path(sys.argv[2])) as connection:
    connection.execute("INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (1000, '1970-01-01T00:16:40Z', 50, None, None, 75, None, None, 900, 192, 'fixture'))
    connection.execute("INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (1900, '1970-01-01T00:31:40Z', 45, None, None, 70, None, None, 900, 192, 'fixture-no-forecast'))
    connection.execute("INSERT INTO forecast_samples VALUES (?, ?, ?, ?)", (1000, 990, 55, 20))
    connection.execute("INSERT INTO forecast_samples VALUES (?, ?, ?, ?)", (1050, 1040, 65, 30))
    connection.execute("INSERT INTO reset_events VALUES (?, ?, ?, ?, ?, ?)", ('5h', 1100, 1200, 5, 100, 'scheduled_crossing'))
    connection.execute("""INSERT INTO token_usage_events
      (occurred_at_epoch, source, provider, model, input_tokens, cache_read_tokens,
       cache_write_tokens, output_tokens, reasoning_tokens, external_id)
      VALUES (1000, 'codex', 'openai', 'gpt-5.6-sol', 100, 20, 10, 30, 5, 'fixture')""")
PYEOF
payload="$(python3 "${ROOT_DIR}/local/analytics.py" --database "${TEST_ROOT}/analytics.sqlite3" --pricing "$PRICING" --params '{"range":"30d"}' --now 2000)"
assert_eq 1800 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["period"]["granularity_seconds"])' <<<"$payload")" "30-day granularity"
assert_eq 160 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tokens"]["summary"]["total_tokens"])' <<<"$payload")" "token total field"
assert_eq 1 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tokens"]["series_by_source"]))' <<<"$payload")" "source series"
assert_eq 1 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["limits"]["reset_markers"]))' <<<"$payload")" "limit reset markers"
assert_eq 2 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["forecast_samples"])' <<<"$payload")" "Forecast sample count"
assert_eq 65 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["forecast_chance_24h_pct"])' <<<"$payload")" "latest independent Forecast bucket value"
assert_eq '1970-01-01T00:17:20Z' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][0]["forecast_generated_at"])' <<<"$payload")" "Forecast generation timestamp"
assert_eq None "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limits"]["series"][1]["forecast_chance_24h_pct"])' <<<"$payload")" "missing Forecast bucket was not null"
assert_eq 50 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resets"]["limit"])' <<<"$payload")" "default reset page size"

python3 - "$ROOT_DIR" "${TEST_ROOT}/concurrent.sqlite3" <<'PYEOF'
from pathlib import Path
import sys
import threading
import time

root = Path(sys.argv[1])
database = Path(sys.argv[2])
sys.path.insert(0, str(root / "local"))
from analytics import build_payload
from storage import connect_database

with connect_database(database) as connection:
    connection.execute(
        "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (1000, "1970-01-01T00:16:40Z", 50, None, None, 70, None, None, 900, 192, "fixture"),
    )

errors = []
ready = threading.Barrier(2)

def writer():
    try:
        with connect_database(database) as connection:
            ready.wait()
            for index in range(30):
                connection.execute(
                    "INSERT OR REPLACE INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (1001 + index, "1970-01-01T00:17:00Z", 50, None, None, 70, None, None, 900, 192, "fixture"),
                )
                connection.commit()
                time.sleep(0.002)
    except BaseException as exc:
        errors.append(("writer", exc))

def reader():
    try:
        ready.wait()
        for _ in range(30):
            build_payload(database, root / "local" / "pricing.json", {"range": "24h"}, now=2000)
    except BaseException as exc:
        errors.append(("reader", exc))

writer_thread = threading.Thread(target=writer)
reader_thread = threading.Thread(target=reader)
writer_thread.start()
reader_thread.start()
writer_thread.join()
reader_thread.join()
if errors:
    raise errors[0][1]
PYEOF

printf 'PASS: backend migration, collector cursor and analytics API tests\n'
