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

heartbeat_now=1786622400
: > "$HEARTBEAT_FILE"
touch -d "@${heartbeat_now}" "$HEARTBEAT_FILE"
dashboard_activity_recent "$heartbeat_now" || fail "fresh heartbeat was not detected"
assert_eq 300 "$(effective_collection_interval 900 "$heartbeat_now")" "fresh heartbeat did not accelerate collection"
assert_eq 300 "$(effective_collection_interval 300 "$heartbeat_now")" "configured fast cadence was changed"

touch -d "@$((heartbeat_now - DASHBOARD_HEARTBEAT_MAX_AGE_SECONDS - 1))" "$HEARTBEAT_FILE"
if dashboard_activity_recent "$heartbeat_now"; then fail "expired heartbeat remained active"; fi
touch -d "@$((heartbeat_now + 1))" "$HEARTBEAT_FILE"
if dashboard_activity_recent "$heartbeat_now"; then fail "future heartbeat was accepted"; fi
printf 'x' > "$HEARTBEAT_FILE"
if dashboard_activity_recent "$heartbeat_now"; then fail "non-empty heartbeat was accepted"; fi
rm -f "$HEARTBEAT_FILE"
ln -s "${TEST_ROOT}/missing-heartbeat" "$HEARTBEAT_FILE"
if dashboard_activity_recent "$heartbeat_now"; then fail "heartbeat symlink was accepted"; fi
rm -f "$HEARTBEAT_FILE"

LOOP_LOG="${TEST_ROOT}/adaptive-loop"
(
  fake_now=43200
  cycles=0
  dashboard_activity_recent() { return 0; }
  date() {
    case "$*" in
      '-u +%s') printf '%s\n' "$fake_now" ;;
      '-d @'*'+%d/%m/%Y %H:%M') printf '01/01/1970 12:00\n' ;;
      '+%d/%m/%Y %H:%M') printf '01/01/1970 12:00\n' ;;
      *) return 1 ;;
    esac
  }
  sleep() { fake_now=$((fake_now + $1)); }
  run_once() {
    printf '%s:%s:%s:%s\n' "$2" "$1" "$3" "$fake_now" >> "$LOOP_LOG"
    cycles=$((cycles + 1))
    (( cycles != 1 )) || fake_now=$((fake_now + 120))
    (( cycles < 4 )) || exit 0
  }
  run_loop 900 0 >/dev/null
)
expected_loop=$'full:300:900:43200\nlive:300:900:43500\nlive:300:900:43800\nfull:300:900:44100'
assert_eq "$expected_loop" "$(<"$LOOP_LOG")" "adaptive loop did not preserve full/live cadence"

printf 'PASS: monitor dashboard activity tests\n'
