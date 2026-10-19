#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
ALERT_THRESHOLDS=0
send_alert() { printf '%s\n' "$1" >> "$TEST_ROOT/notifications.log"; }

check_thresholds 100 100 later later 1792054001 1792473311 1792044001 group-a
check_thresholds 100 100 later later 1792054001 1792649701 1792044901 group-a

# Interrupt immediately after an unrelated 5h write-ahead intent is durable.
# The weekly confirmation in this same sample must remain recoverable.
eval "$(declare -f persist_observed_5h_intent | sed '1s/^persist_observed_5h_intent /original_five_intent /')"
persist_observed_5h_intent() {
  original_five_intent "$@"
  return 1
}
if check_thresholds 100 100 later later 1792058001 1792649711 1792045801 group-a; then
  fail 'simulated interruption was not reached'
fi
eval "$(declare -f original_five_intent | sed '1s/^original_five_intent /persist_observed_5h_intent /')"
check_thresholds 100 100 later later 1792058001 1792649711 1792046701 group-a
assert_eq 1 "$(grep -c 'Reset from 100% to 100%' "$TEST_ROOT/notifications.log")" 'interrupted weekly confirmation was lost'
check_thresholds 100 100 later later 1792058001 1792649711 1792047601 group-a
assert_eq 1 "$(grep -c 'Reset from 100% to 100%' "$TEST_ROOT/notifications.log")" 'recovered weekly confirmation replayed'
printf 'PASS: weekly confirmation survives an interrupted 5h intent\n'
