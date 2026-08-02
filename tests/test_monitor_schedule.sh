#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../local/monitor.sh
source "${ROOT_DIR}/local/monitor.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
LOOP_LOG="${TEST_DIR}/loop.log"
(
  check_requirements() { :; }
  run_once() { printf 'scrape:%s\n' "$1" >> "$LOOP_LOG"; }
  date() {
    case "$*" in
      '-u +%s') printf '43620\n' ;;
      '-u -d @44100 +%H:%M:%SZ') printf '12:15:00Z\n' ;;
      '-u +%H:%M:%SZ') printf '12:07:00Z\n' ;;
      *) return 1 ;;
    esac
  }
  sleep() {
    printf 'sleep:%s\n' "$1" >> "$LOOP_LOG"
    exit 0
  }
  main --loop 900 >/dev/null
)

expected_log=$'scrape:900\nsleep:480'
actual_log="$(<"$LOOP_LOG")"
[[ "$actual_log" == "$expected_log" ]] || fail "loop did not scrape before aligned sleep"

printf 'PASS: monitor schedule tests\n'
