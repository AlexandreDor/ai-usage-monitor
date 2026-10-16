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

printf 'PASS: manual and automatic post-reset refresh tests\n'
