#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

LOOP_LOG="${TEST_ROOT}/refresh-loop"
(
  fake_now=43200
  dashboard_activity_recent() { return 1; }
  date() {
    case "$*" in
      '-u +%s') printf '%s\n' "$fake_now" ;;
      *) printf '01/01/1970 12:00\n' ;;
    esac
  }
  sleep() { fake_now=$((fake_now + $1)); }
  run_once() {
    printf '%s:%s\n' "$2" "$fake_now" >> "$LOOP_LOG"
    if (( fake_now == 43200 )); then
      # A 5-hour and a weekly deadline, unrelated to the regular cadence.
      printf '{"five_h_reset_at":43212,"weekly_reset_at":43225,"scraped_at":"1970-01-01T12:00:00Z"}' > "$DATA_FILE"
    fi
    if (( fake_now == 43242 )); then
      # An immediately queued dashboard request must receive a real result.
      printf '{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expires_at":43300}' > "$RUNTIME_DIR/dashboard-refresh.json"
    fi
    (( fake_now < 44100 )) || exit 0
  }
  run_loop 900 0 >/dev/null
)
expected=$'full:43200\nlive:43242\nlive:43242\nlive:43255\nfull:44100'
assert_eq "$expected" "$(<"$LOOP_LOG")" "manual/reset checks changed cadence or missed the 30-second grace period"
assert_eq true "$(json_field "$RUNTIME_DIR/dashboard-refresh-result.json" success)" "manual request was not acknowledged"
assert_eq aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$(json_field "$RUNTIME_DIR/dashboard-refresh-result.json" id)" "wrong manual request acknowledged"

# A colliding requested collection must be distinguishable from a successful
# one so it is retried rather than falsely acknowledged.
(
  exec 9>"$LOCK_FILE"
  flock 9
  status=0
  run_once 900 live 900 1 >/dev/null || status=$?
  assert_eq 75 "$status" "busy requested collection was reported as completed"
)

# A reset timeout must leave a full retry delay after the failed attempt.
(
  rm -f "$RUNTIME_DIR/reset-refresh.json" "$DATA_FILE"
  fake_now=43200
  cycles=0
  dashboard_activity_recent() { return 1; }
  date() {
    case "$*" in
      '-u +%s') printf '%s\n' "$fake_now" ;;
      *) printf '01/01/1970 12:00\n' ;;
    esac
  }
  sleep() { fake_now=$((fake_now + $1)); }
  run_once() {
    cycles=$((cycles + 1))
    if (( cycles == 1 )); then
      printf '{"five_h_reset_at":43200,"scraped_at":"1970-01-01T12:00:00Z"}' > "$DATA_FILE"
    elif (( cycles == 2 )); then
      assert_eq 43230 "$fake_now" "reset collection did not start after the grace period"
      fake_now=$((fake_now + 40))
      return 1
    else
      assert_eq 43300 "$fake_now" "slow failed collection was retried without a full 30-second delay"
      exit 0
    fi
  }
  run_loop 900 0 >/dev/null
)

# Exercise real full/live cycles and their receipts. Notification failures
# remain visible in health; genuine collection/storage failures still fail.
for failure in notification collection storage full; do
  (
    TEST_ROOT="$TEST_ROOT/$failure"
    use_test_runtime
    fake_now=1786622400
    cycles=0
    dashboard_activity_recent() { return 1; }
    date() {
      if [[ "$*" == '-u +%s' ]]; then printf '%s\n' "$fake_now"; else command date "$@"; fi
    }
    sleep() { exit 0; }
    fetch_status_json() {
      if [[ "$failure" == collection ]] && (( cycles == 1 )); then return 1; fi
      python3 - "$fake_now" "$cycles" <<'PY'
from datetime import datetime, timezone
import json
import sys
print(json.dumps({"five_h_pct": 80 if sys.argv[2] == "0" else 70, "weekly_pct": 100,
    "five_h_reset_at": None, "weekly_reset_at": None, "limit_id": "test",
    "scraped_at": datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).isoformat(),
    "sample_interval_seconds": 300, "history_window_hours": 192}))
PY
    }
    archive_snapshot() { return 0; }
    observe_quota_anomalies() { return 0; }
    collect_token_usage() { [[ "$failure" != full ]]; }
    sync_gist() { return 0; }
    if [[ "$failure" == storage ]]; then write_current_snapshot() { return 1; }; fi
    check_thresholds() {
      cycles=$((cycles + 1))
      if [[ "$failure" == full ]]; then
        return 0
      elif (( cycles == 1 )); then
        printf '{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expires_at":1786622460}' > "$RUNTIME_DIR/dashboard-refresh.json"
        fake_now=$((fake_now + 5))
      elif [[ "$failure" == notification ]]; then
        ALERT_PROCESSING_ERROR="alert delivery pending"
        return 1
      fi
    }
    if [[ "$failure" == full ]]; then
      printf '{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expires_at":1786622460}' > "$RUNTIME_DIR/dashboard-refresh.json"
    fi
    (run_loop 900 0 >/dev/null 2>&1)
    assert_eq failure "$(json_field "$HEALTH_FILE" last_cycle_result)" "cycle failure disappeared from health"
    if [[ "$failure" == full ]]; then
      assert_eq true "$(json_field "$RUNTIME_DIR/dashboard-refresh-result.json" success)" "token collection error failed a successful quota collection"
      assert_eq 80 "$(json_field "$DATA_FILE" five_h_pct)" "full cycle did not publish quota"
    elif [[ "$failure" == notification ]]; then
      assert_eq true "$(json_field "$RUNTIME_DIR/dashboard-refresh-result.json" success)" "notification error failed a successful quota collection"
      assert_eq 70 "$(json_field "$DATA_FILE" five_h_pct)" "fresh quota was not published"
    else
      assert_eq false "$(json_field "$RUNTIME_DIR/dashboard-refresh-result.json" success)" "failed quota collection was acknowledged as successful"
      assert_eq 80 "$(json_field "$DATA_FILE" five_h_pct)" "failed collection replaced the last valid quota"
    fi
  )
done

printf 'PASS: manual and automatic post-reset refresh tests\n'
