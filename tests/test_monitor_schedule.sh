#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# Sourcing defines functions only: configuration and developer runtime stay untouched.
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

assert_delay() {
  local now_epoch="$1"
  local interval="$2"
  local expected="$3"
  local actual
  actual="$(seconds_until_next_interval "$now_epoch" "$interval")"
  [[ "$actual" -eq "$expected" ]] || fail "expected ${expected}s, got ${actual}s"
}

# 12:07 schedules the next scrape at 12:15.
assert_delay "$((12 * 3600 + 7 * 60))" 900 480

# Completing exactly on a boundary schedules the following boundary.
assert_delay "$((12 * 3600))" 900 900

# A cycle that overruns 12:15 skips it and schedules 12:30 without drifting.
assert_delay "$((12 * 3600 + 15 * 60 + 20))" 900 880

validate_interval 900
if validate_interval 0 2>/dev/null || validate_interval invalid 2>/dev/null; then
  fail "invalid intervals were accepted"
fi

# Loop mode must scrape immediately before sleeping until the first boundary.
LOOP_LOG="${TEST_ROOT}/loop.log"
LOOP_OUTPUT="${TEST_ROOT}/loop.out"
(
  # These overrides are called indirectly by main from the sourced monitor.
  # shellcheck disable=SC2329
  check_requirements() { :; }
  run_once() { printf 'scrape:%s\n' "$1" >> "$LOOP_LOG"; }
  date() {
    case "$*" in
      '-u +%s') printf '43620\n' ;;
      '-d @44100 +%d/%m/%Y %H:%M') printf '01/01/1970 13:15\n' ;;
      '+%d/%m/%Y %H:%M') printf '01/01/1970 13:07\n' ;;
      *) return 1 ;;
    esac
  }
  sleep() {
    printf 'sleep:%s\n' "$1" >> "$LOOP_LOG"
    exit 0
  }
  main --loop 900 > "$LOOP_OUTPUT"
)

expected_log=$'scrape:900\nsleep:5'
actual_log="$(<"$LOOP_LOG")"
[[ "$actual_log" == "$expected_log" ]] || fail "loop did not scrape before aligned sleep"
assert_contains "$(<"$LOOP_OUTPUT")" '[01/01/1970 13:07] Next regular check at 01/01/1970 13:15 (in 480s)...' "loop timestamps are not formatted in Paris time"

printf 'PASS: monitor schedule tests\n'
