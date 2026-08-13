#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

CALL_LOG="${TEST_ROOT}/cycle-calls"

fetch_status_json() {
  local interval="$1"
  printf '{"five_h_pct":80,"weekly_pct":60,"five_h_reset":"later","weekly_reset":"later","five_h_reset_at":1700010000,"weekly_reset_at":1700600000,"scraped_at":"2026-08-13T12:00:00Z","sample_interval_seconds":%s,"history_window_hours":192,"limit_id":"test"}\n' "$interval"
}

archive_snapshot() { printf 'archive:%s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_interval_seconds"])' <<< "$1")" >> "$CALL_LOG"; }
write_local_snapshot() { printf 'history:%s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_interval_seconds"])' <<< "$1")" >> "$CALL_LOG"; }
write_current_snapshot() { printf 'current:%s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_interval_seconds"])' <<< "$1")" >> "$CALL_LOG"; }
sync_gist() { printf 'gist:%s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sample_interval_seconds"])' <<< "$1")" >> "$CALL_LOG"; }
check_thresholds() { printf 'alerts:%s\n' "$7" >> "$CALL_LOG"; }
collect_token_usage() { printf 'tokens\n' >> "$CALL_LOG"; }

run_cycle 300 full 900 >/dev/null
expected_full=$'archive:300\nhistory:300\ngist:900\nalerts:1786622400\ntokens'
assert_eq "$expected_full" "$(<"$CALL_LOG")" "full active cycle did not preserve persistence boundaries"

: > "$CALL_LOG"
run_cycle 300 live 900 >/dev/null
expected_live=$'current:300\nalerts:1786622400'
assert_eq "$expected_live" "$(<"$CALL_LOG")" "live cycle performed full-cycle work"

if run_cycle 300 unsupported 900 >/dev/null 2>&1; then
  fail "unsupported cycle mode was accepted"
fi

printf 'PASS: monitor dashboard activity tests\n'
