#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

ALERT_LOG="${TEST_ROOT}/alerts.log"
ALERT_COUNT_LOG="${TEST_ROOT}/alert-count.log"
ALERT_THRESHOLDS=0

# Invoked through register_network_alert's compatibility seam.
# shellcheck disable=SC2317,SC2329
send_alert() {
  printf '%s\n' "$1" >> "$ALERT_LOG"
  printf '1\n' >> "$ALERT_COUNT_LOG"
}

assert_alert_count() {
  local expected="$1"
  local actual=0
  [[ -f "$ALERT_COUNT_LOG" ]] && actual="$(wc -l < "$ALERT_COUNT_LOG")"
  [[ "$actual" -eq "$expected" ]] || fail "expected ${expected} alerts, got ${actual}"
}

state_value() {
  local wanted="$1"
  local key value
  while IFS='=' read -r key value; do
    if [[ "$key" == "$wanted" ]]; then
      printf '%s\n' "$value"
      return
    fi
  done < "$STATE_FILE"
}

reset_case() {
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$ALERT_LOG" "$ALERT_COUNT_LOG"
}

now=2000000000

# First observation arms consumed cycles without reporting a reset.
check_thresholds 80 70 "later" "later" "$((now + 300))" "$((now + 3600))" "$now"
assert_alert_count 0
[[ "$(state_value five_h_armed_reset_at)" == "$((now + 300))" ]] || fail "5h cycle was not armed"
[[ "$(state_value weekly_armed_reset_at)" == "$((now + 3600))" ]] || fail "weekly cycle was not armed"

# A reset is detected even when the 5h window disappears, and only once.
check_thresholds "" 70 "unknown" "later" "" "$((now + 3600))" "$((now + 301))"
assert_alert_count 1
check_thresholds "" 70 "unknown" "later" "" "$((now + 3600))" "$((now + 302))"
assert_alert_count 1
[[ "$(state_value last_notified_5h_reset_at)" == "$((now + 300))" ]] || fail "5h reset was not persisted"

# The weekly deadline produces its own notification and is deduplicated.
check_thresholds "" 100 "unknown" "later" "" "" "$((now + 3601))"
assert_alert_count 2
check_thresholds "" 100 "unknown" "later" "" "" "$((now + 3602))"
assert_alert_count 2
[[ "$(state_value last_notified_weekly_reset_at)" == "$((now + 3600))" ]] || fail "weekly reset was not persisted"

# Existing two-key state migrates silently and arms the current cycles.
reset_case
printf 'prev_5h_pct=80\nprev_weekly_pct=70\n' > "$STATE_FILE"
check_thresholds 80 70 "later" "later" "$((now + 300))" "$((now + 3600))" "$now"
assert_alert_count 0
[[ "$(state_value state_version)" == "5" ]] || fail "state was not migrated"

# A reset older than its whole window is discarded rather than reported late.
reset_case
check_thresholds 80 100 "later" "unknown" "$((now + 300))" "" "$now"
check_thresholds 100 100 "later" "unknown" "" "" "$((now + 300 + 5 * 60 * 60 + 1))"
assert_alert_count 0
[[ "$(state_value five_h_armed_reset_at)" == "0" ]] || fail "stale 5h cycle was not cleared"

# An early weekly refill with a materially advanced deadline is an observed
# reset even though the old scheduled deadline has not arrived yet.
reset_case
old_weekly_deadline=$((now + 4 * 24 * 60 * 60))
new_weekly_deadline=$((old_weekly_deadline + 3 * 24 * 60 * 60))
check_thresholds 100 28 "unknown" "later" "" "$old_weekly_deadline" "$now"
check_thresholds 100 100 "unknown" "later" "" "$new_weekly_deadline" "$((now + 900))"
assert_alert_count 1
[[ "$(state_value last_notified_weekly_reset_at)" == "$((now + 900))" ]] \
  || fail "observed weekly reset was not persisted"
check_thresholds 100 100 "unknown" "later" "" "$new_weekly_deadline" "$((now + 1800))"
assert_alert_count 1

# Reaching exactly 98% is valid even for a small refill when the deadline moves
# by exactly 30 minutes. A deadline jump without a refill is not enough.
reset_case
check_thresholds 100 97 "unknown" "later" "" "$old_weekly_deadline" "$now"
check_thresholds 100 98 "unknown" "later" "" "$((old_weekly_deadline + 30 * 60))" "$((now + 900))"
assert_alert_count 1
reset_case
check_thresholds 100 92 "unknown" "later" "" "$old_weekly_deadline" "$now"
check_thresholds 100 92 "unknown" "later" "" "$new_weekly_deadline" "$((now + 900))"
assert_alert_count 0

# A 20-point refill also qualifies below 98%, including after a long gap and
# intervening partial observations.
reset_case
check_thresholds 100 40 "unknown" "later" "" "$old_weekly_deadline" "$now"
check_thresholds 100 "" "unknown" "unknown" "" "" "$((now + 3600))"
check_thresholds 100 60 "unknown" "later" "" "$((old_weekly_deadline + 30 * 60))" "$((now + 7200))"
assert_alert_count 1

# Values from different limit groups are never compared as one quota cycle.
reset_case
check_thresholds 100 40 "unknown" "later" "" "$old_weekly_deadline" "$now" "group-a"
check_thresholds 100 100 "unknown" "later" "" "$new_weekly_deadline" "$((now + 900))" "group-b"
assert_alert_count 0

# Scheduled deadlines also stay bound to their original limit group.
reset_case
scheduled_deadline=$((now + 100))
check_thresholds 100 40 "unknown" "later" "" "$scheduled_deadline" "$now" "group-a"
check_thresholds 100 40 "unknown" "later" "" "$new_weekly_deadline" "$((now + 101))" "group-b"
assert_alert_count 0

# A partial observation from another group cannot cross notification thresholds.
reset_case
ALERT_THRESHOLDS=50
check_thresholds 100 80 "unknown" "later" "" "$old_weekly_deadline" "$now" "group-a"
check_thresholds 100 40 "unknown" "unknown" "" "" "$((now + 1))" "group-b"
assert_alert_count 0
ALERT_THRESHOLDS=0

# A partial sample after the old deadline reports the scheduled reset once and
# invalidates the old observation so the next complete sample cannot replay it.
reset_case
check_thresholds 100 40 "unknown" "later" "" "$scheduled_deadline" "$now"
check_thresholds 100 "" "unknown" "unknown" "" "" "$((now + 101))"
check_thresholds 100 100 "unknown" "later" "" "$new_weekly_deadline" "$((now + 200))"
assert_alert_count 1

# A failed threshold delivery does not replace the observation baseline used
# to detect a later refill.
reset_case
ALERT_THRESHOLDS=50
check_thresholds 100 100 "unknown" "later" "" "$old_weekly_deadline" "$now"
# shellcheck disable=SC2317,SC2329
send_alert() {
  printf '%s\n' "$1" >> "$ALERT_LOG"
  printf '1\n' >> "$ALERT_COUNT_LOG"
  return 1
}
check_thresholds 100 40 "unknown" "later" "" "$old_weekly_deadline" "$((now + 1))" || true
# shellcheck disable=SC2317,SC2329
send_alert() {
  printf '%s\n' "$1" >> "$ALERT_LOG"
  printf '1\n' >> "$ALERT_COUNT_LOG"
}
check_thresholds 100 100 "unknown" "later" "" "$((old_weekly_deadline + 30 * 60))" "$((now + 2))"
assert_alert_count 2
assert_contains "$(tail -n 1 "$ALERT_LOG")" "weekly limit reset" "failed threshold delivery hid the reset"
[[ -z "$(state_value pending_weekly_threshold)" ]] || fail "old threshold remained pending after reset"

# Legacy threshold baselines have no limit owner and are reinitialized from the
# first complete observation after upgrade.
reset_case
ALERT_THRESHOLDS=50
printf 'state_version=3\nprev_5h_pct=100\nprev_weekly_pct=80\n' > "$STATE_FILE"
check_thresholds 100 40 "unknown" "later" "" "$old_weekly_deadline" "$now" "group-b"
assert_alert_count 0

# Threshold alerts include the same weekly pace delta shown by the dashboard.
reset_case
ALERT_THRESHOLDS=50
check_thresholds 100 40 "unknown" "later" "" "$((now + 7 * 24 * 60 * 60 / 2))" "$now"
assert_alert_count 1
alert_message="$(<"$ALERT_LOG")"
[[ "$alert_message" == *$'*Pace vs ideal:* -10.0 pts · 20.0% below'* ]] \
  || fail "weekly pace delta was missing from threshold alert"

printf 'PASS: monitor reset alert tests\n'
