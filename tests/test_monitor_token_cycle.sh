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
  CALLS+=(limits)
  return 1
}
collect_token_usage() {
  CALLS+=(tokens)
}

run_cycle 900 >/dev/null 2>&1 && fail "limit collection failure was not propagated"
assert_eq 'tokens' "${CALLS[*]}" "token collection did not run after a limit failure"
assert_contains "$CYCLE_ERROR" 'Codex limit collection failed' "limit failure detail missing"

fetch_status_json() {
  CALLS+=(limits)
  return 1
}
collect_token_usage() {
  CALLS+=(tokens)
  return 1
}
CALLS=()
run_cycle 900 >/dev/null 2>&1 && fail "combined collection failures were not propagated"
assert_contains "$CYCLE_ERROR" 'Local token usage collection failed' "token failure detail missing"

printf 'PASS: independent token collection cycle tests\n'
