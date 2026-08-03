#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

CALLS=()
fetch_status_json() {
  printf '{"five_h_pct":80,"weekly_pct":60,"five_h_reset":"later","weekly_reset":"later","five_h_reset_at":2000000300,"weekly_reset_at":2000003600,"scraped_at":"2033-05-18T03:33:20Z"}\n'
}

archive_snapshot() {
  CALLS+=(archive)
  return 1
}

write_local_snapshot() {
  CALLS+=(local)
}

sync_gist() {
  CALLS+=(gist)
}

check_thresholds() {
  CALLS+=(alerts)
}

run_once 900 >/dev/null 2>&1 && fail "archive failure was not propagated to run_once"
assert_eq 'archive local gist alerts' "${CALLS[*]}" "archive failure stopped later delivery steps"
assert_eq failure "$(json_field "$HEALTH_FILE" last_cycle_result)" "archive failure was not recorded in health"
assert_contains "$(json_field "$HEALTH_FILE" last_error.message)" 'Long-term archive update failed' "archive failure detail missing"

printf 'PASS: archive failure handling tests\n'
