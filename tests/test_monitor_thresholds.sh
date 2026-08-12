#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

ALERT_THRESHOLDS=80,70,50,25,10,5,4
ALERT_LOG="${TEST_ROOT}/alerts"
send_alert() { printf '%s\n' "$1" >> "$ALERT_LOG"; }
count_alerts() { [[ -f "$ALERT_LOG" ]] && wc -l < "$ALERT_LOG" || printf '0\n'; }
run_sample() { check_thresholds "$1" 100 later unknown "${2:-}" '' "$3" >/dev/null; }
now=2000000000

run_sample 80 '' "$now"
assert_eq 1 "$(count_alerts)" "80 crossing"
run_sample 70 '' "$((now + 1))"
assert_eq 2 "$(count_alerts)" "80 to 70 crossing"
run_sample 4 '' "$((now + 2))"
assert_eq 3 "$(count_alerts)" "multi-threshold drop emitted more than once"
assert_contains "$(tail -n 1 "$ALERT_LOG")" 'crossed 4% threshold' "most critical threshold not selected"

run_sample 6 '' "$((now + 3))"
run_sample 4 '' "$((now + 4))"
assert_eq 3 "$(count_alerts)" "threshold oscillation duplicated notification"

reset_at=$((now + 300))
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$ALERT_LOG"
run_sample 4 "$reset_at" "$now"
run_sample 100 '' "$((reset_at + 1))"
assert_eq 2 "$(count_alerts)" "4 to 100 reset sequence"
assert_contains "$(tail -n 1 "$ALERT_LOG")" 'limit reset' "reset alert missing"

rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$ALERT_LOG"
decimal_reset_at=$((now + 600))
run_sample 79.75 "$decimal_reset_at" "$now"
assert_eq "$decimal_reset_at" "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" "decimal percentage did not arm reset"

printf 'PASS: monitor threshold tests\n'
