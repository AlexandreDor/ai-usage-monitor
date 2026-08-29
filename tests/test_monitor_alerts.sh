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

# A full 5-hour cycle is observable from a deadline advance even when the
# quota stays at 100%. It is anchored to the first observation carrying the
# new deadline and is acknowledged locally without a network occurrence.
reset_case
old_five_deadline=$((now + 300))
new_five_deadline=$((old_five_deadline + 15 * 60))
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 900))" group-a
assert_alert_count 0
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["alerts"]))' "$ALERT_DELIVERIES_FILE")" \
  "observed 5h reset created a network journal occurrence"
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 1800))" group-a
assert_alert_count 0
check_thresholds 100 100 later later "$((new_five_deadline - 60))" '' "$((now + 2700))" group-a
assert_alert_count 0

# Reconstructing a missing delivery journal from the observed-reset sample
# must not manufacture a 5h network reset or its old threshold occurrence.
reset_case
DISCORD_WEBHOOK=dummy-webhook
ALERTS_ENABLED=0
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.unlink()
PYEOF
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 900))" group-a
assert_eq 0 "$(python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys
print(sum(1 for item in json.load(open(sys.argv[1]))["alerts"] if item["window"] == "5h"))
PYEOF
)" "missing journal reconstructed an observed 5h network occurrence"
DISCORD_WEBHOOK=""
ALERTS_ENABLED=1

# A local observed refill expires a pending threshold before any due delivery,
# while leaving no reset occurrence in the network journal.
reset_case
DISCORD_WEBHOOK=dummy-webhook
ALERTS_ENABLED=0
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
ALERTS_ENABLED=1
group_a_limit_id="$(canonicalize_alert_limit_id group-a)"
register_network_alert threshold 5h 50 "limit:${group_a_limit_id}|unarmed" \
  "stale" "{\"limit_id\":\"${group_a_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":0,\"covered_thresholds\":[50]}" \
  "$((now + 1))" 0 false
ALERTS_ENABLED=0
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 900))" group-a
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys
items = json.load(open(sys.argv[1]))["alerts"]
assert len(items) == 1, items
assert items[0]["terminal_reason"] == "expired_after_reset", items[0]
assert items[0]["channels"]["discord"]["error_class"] == "expired_after_reset", items[0]
PYEOF
DISCORD_WEBHOOK=""
ALERTS_ENABLED=1

# Partial observations and group changes only establish a complete baseline;
# neither can be compared as evidence of a full 5-hour reset.
reset_case
check_thresholds 100 100 later later '' '' "$now" group-a
check_thresholds 100 100 later later "$old_five_deadline" '' "$((now + 900))" group-a
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 1800))" group-b
assert_alert_count 0

# A partial 5h observation from another limit group cannot be compared against
# the previous group's percentage baseline.
reset_case
ALERT_THRESHOLDS=50
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
check_thresholds 40 100 unknown unknown '' '' "$((now + 1))" group-b
assert_alert_count 0
ALERT_THRESHOLDS=0

# An existing state without the new baseline fields migrates silently and
# takes its first complete observation as the baseline.
reset_case
printf 'state_version=5\nlimit_id_contract_version=1\nprev_5h_pct=100\nprev_weekly_pct=100\n' > "$STATE_FILE"
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
assert_alert_count 0

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

# A legacy ownerless 5h arm must not be attached to a partial observation from
# a new group.  In particular, a stale arm from v4 cannot fabricate a reset for
# group-b when the sample has no reset deadline.
reset_case
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=100' 'prev_weekly_pct=100' \
  "five_h_armed_reset_at=$now" 'weekly_armed_reset_at=0' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 80 100 unknown unknown '' '' "$((now + 301))" group-b
assert_alert_count 0
assert_eq 0 "$(state_value five_h_armed_reset_at)" \
  "ownerless legacy arm was attributed to a partial sample"

# A loaded ownerless legacy baseline must not compare a partial 5h sample to
# its stale percentage.  The first complete owner-aware sample will establish
# the new baseline; this row must create neither a network alert nor a marker.
reset_case
ALERT_THRESHOLDS=50
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'five_h_armed_reset_at=0' 'weekly_armed_reset_at=0' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 40 100 unknown unknown '' '' "$((now + 302))" group-b
assert_alert_count 0
assert_eq 100 "$(state_value prev_5h_pct)" \
  "ownerless legacy partial sample crossed a 5h threshold"
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
