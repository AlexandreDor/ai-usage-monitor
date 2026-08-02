#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../local/monitor.sh
source "${ROOT_DIR}/local/monitor.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

STATE_FILE="${TEST_DIR}/.alert_state"
ALERT_LOG="${TEST_DIR}/alerts.log"
ALERT_COUNT_LOG="${TEST_DIR}/alert-count.log"
ALERT_THRESHOLDS=0

send_alert() {
  printf '%s\n' "$1" >> "$ALERT_LOG"
  printf '1\n' >> "$ALERT_COUNT_LOG"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
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
  rm -f "$STATE_FILE" "$ALERT_LOG" "$ALERT_COUNT_LOG"
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
[[ "$(state_value state_version)" == "2" ]] || fail "state was not migrated"

# A reset older than its whole window is discarded rather than reported late.
reset_case
check_thresholds 80 100 "later" "unknown" "$((now + 300))" "" "$now"
check_thresholds 100 100 "later" "unknown" "" "" "$((now + 300 + 5 * 60 * 60 + 1))"
assert_alert_count 0
[[ "$(state_value five_h_armed_reset_at)" == "0" ]] || fail "stale 5h cycle was not cleared"

# Threshold alerts include the same weekly pace delta shown by the dashboard.
reset_case
ALERT_THRESHOLDS=50
check_thresholds 100 40 "unknown" "later" "" "$((now + 7 * 24 * 60 * 60 / 2))" "$now"
assert_alert_count 1
alert_message="$(<"$ALERT_LOG")"
[[ "$alert_message" == *$'*Pace vs ideal:* -10.0 pts · 20.0% below'* ]] \
  || fail "weekly pace delta was missing from threshold alert"

printf 'PASS: monitor reset alert tests\n'
