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
five_h_reset_alert_id="$(state_value five_h_reset_alert_id)"
[[ "$five_h_reset_alert_id" =~ ^[a-f0-9]{24}$ ]] || fail "5h reset alert ID was not persisted"
check_thresholds "" 70 "unknown" "later" "" "$((now + 3600))" "$((now + 302))"
assert_alert_count 1
assert_eq "$five_h_reset_alert_id" "$(state_value five_h_reset_alert_id)" "5h reset alert ID changed"
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
[[ "$(state_value state_version)" == "4" ]] || fail "state was not migrated"

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

# Every legacy version treats historical success as delivered on every channel.
for version in 1 2 3; do
  reset_case
  ALERT_THRESHOLDS=75
  if (( version == 1 )); then
    printf '%s\n' \
      'prev_5h_pct=70' 'prev_weekly_pct=100' 'notified_5h_thresholds=75' \
      "last_notified_5h_reset_at=$((now - 10))" > "$STATE_FILE"
  else
    printf '%s\n' \
      "state_version=${version}" 'prev_5h_pct=70' 'prev_weekly_pct=100' \
      'notified_5h_thresholds=75' "last_notified_5h_reset_at=$((now - 10))" > "$STATE_FILE"
  fi
  check_thresholds 70 100 unknown unknown '' '' "$now"
  assert_alert_count 0
  assert_eq 4 "$(state_value state_version)" "v${version} migration version"
  assert_eq delivered "$(state_value five_h_threshold_discord_status)" "v${version} Discord delivered migration"
  assert_eq delivered "$(state_value five_h_threshold_telegram_status)" "v${version} Telegram delivered migration"
  assert_eq delivered "$(state_value five_h_reset_discord_status)" "v${version} reset Discord migration"
  assert_eq delivered "$(state_value five_h_reset_telegram_status)" "v${version} reset Telegram migration"
done

# Pending legacy alerts retain a stable ID and remain eligible for retry.
for version in 1 2 3; do
  reset_case
  DISCORD_WEBHOOK='configured-for-test'
  if (( version == 1 )); then
    printf '%s\n' 'prev_5h_pct=70' 'prev_weekly_pct=100' 'pending_5h_threshold=75' > "$STATE_FILE"
  else
    printf '%s\n' "state_version=${version}" 'prev_5h_pct=70' 'prev_weekly_pct=100' \
      'pending_5h_threshold=75' > "$STATE_FILE"
  fi
  send_alert() { printf '1\n' >> "$ALERT_COUNT_LOG"; return 1; }
  check_thresholds 70 100 later unknown '' '' "$now" >/dev/null 2>&1 || true
  assert_alert_count 1
  assert_eq 4 "$(state_value state_version)" "pending v${version} migration version"
  assert_eq pending "$(state_value five_h_threshold_discord_status)" "pending v${version} lost retry"
  [[ "$(state_value five_h_threshold_alert_id)" =~ ^[a-f0-9]{24}$ ]] \
    || fail "pending v${version} migration did not create an alert ID"
done

# An incomplete v4 pending occurrence is never acknowledged from default
# delivered values. It receives a deterministic ID and remains retryable.
reset_case
DISCORD_WEBHOOK='configured-for-test'
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=70' 'prev_weekly_pct=100' \
  'pending_5h_threshold=75' > "$STATE_FILE"
check_thresholds 70 100 later unknown '' '' "$now" >/dev/null 2>&1 || true
assert_alert_count 1
v4_alert_id="$(state_value five_h_threshold_alert_id)"
[[ "$v4_alert_id" =~ ^[a-f0-9]{24}$ ]] || fail "incomplete v4 state did not get an alert ID"
assert_eq 75 "$(state_value pending_5h_threshold)" "incomplete v4 pending threshold was acknowledged"
assert_eq pending "$(state_value five_h_threshold_status)" "incomplete v4 alert was marked delivered"
assert_eq pending "$(state_value five_h_threshold_discord_status)" "incomplete v4 channel was not made pending"

check_thresholds 70 100 later unknown '' '' "$((now + 1))" >/dev/null 2>&1 || true
assert_alert_count 2
assert_eq "$v4_alert_id" "$(state_value five_h_threshold_alert_id)" "v4 recovery ID was not deterministic"

printf 'PASS: monitor reset alert tests\n'
