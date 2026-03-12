#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/local/monitor.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "[FAIL] Expected output to contain: $needle"
    exit 1
  fi
}

basic_raw="$(cat "${ROOT_DIR}/tests/parser_fixtures/basic_status.txt")"
basic_json="$(parse_status_from_raw "$basic_raw" 900)"
assert_contains "$basic_json" '"five_h_pct": 82'
assert_contains "$basic_json" '"weekly_pct": 64'
assert_contains "$basic_json" '"sample_interval_seconds": 900'
assert_contains "$basic_json" '"history_window_hours": 24.0'

quoted_raw="$(cat "${ROOT_DIR}/tests/parser_fixtures/quoted_status.txt")"
quoted_json="$(parse_status_from_raw "$quoted_raw" 300)"
assert_contains "$quoted_json" '"account": "\"Dan Ops\" <dan@example.com>"'

echo "[PASS] monitor parser fixtures passed"
