#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
HISTORY_RETENTION_HOURS=8760

snapshot() {
  printf '{"five_h_pct":%s,"weekly_pct":%s,"five_h_reset":"later","weekly_reset":"later","scraped_at":"%s","sample_interval_seconds":900,"history_window_hours":192,"limit_id":"test"}' "$2" "$3" "$1"
}

new_json="$(snapshot '2026-08-03T12:00:00Z' 80 60)"
old_json="$(snapshot '2026-08-03T11:00:00Z' 90 70)"
write_local_snapshot "$new_json" >/dev/null
write_local_snapshot "$old_json" >/dev/null 2>&1
assert_eq '2026-08-03T12:00:00Z' "$(json_field "$DATA_FILE" scraped_at)" "older snapshot replaced data.json"
assert_eq 2 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))))' "$HISTORY_FILE")" "older snapshot missing from history"

printf '{broken' > "$HISTORY_FILE"
write_local_snapshot "$new_json" >/dev/null 2>&1
compgen -G "${HISTORY_FILE}.corrupt.*" >/dev/null || fail "corrupt history was not backed up"
python3 -m json.tool "$HISTORY_FILE" >/dev/null || fail "history was not reconstructed"

update_health failure 'collection failed' 12
assert_eq failure "$(json_field "$HEALTH_FILE" last_cycle_result)"
assert_eq 1 "$(json_field "$HEALTH_FILE" consecutive_failures)"
update_health success '' 7
assert_eq success "$(json_field "$HEALTH_FILE" last_cycle_result)"
assert_eq 0 "$(json_field "$HEALTH_FILE" consecutive_failures)"
assert_file "$HEALTH_FILE"

COLLECTION_LOG="${TEST_ROOT}/collections"
run_cycle() {
  printf 'collect\n' >> "$COLLECTION_LOG"
  sleep 0.4
}
run_once 900 >/dev/null & first=$!
sleep 0.05
run_once 900 >/dev/null & second=$!
wait "$first"
wait "$second"
assert_eq 1 "$(wc -l < "$COLLECTION_LOG")" "concurrent run_once collected twice"

CODEX_BIN="${ROOT_DIR}/tests/fixtures/fake-codex.sh"
export CODEX_BIN FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/multi-id.json"
main --check >/dev/null || fail "--check failed with valid fake Codex"

printf 'PASS: monitor runtime and observability tests\n'
