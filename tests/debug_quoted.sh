#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/local/monitor.sh"

raw="$(cat "${ROOT_DIR}/tests/parser_fixtures/quoted_status.txt")"
json="$(parse_status_from_raw "$raw" 300)"

echo "=== FULL JSON ==="
echo "$json"
echo "=== CHECKING ACCOUNT ==="
needle='"account": "\"Dan Ops\" <dan@example.com>"'
echo "Looking for: $needle"
if [[ "$json" == *"$needle"* ]]; then
  echo "MATCH"
else
  echo "NO MATCH"
  echo "=== HEX of account line ==="
  echo "$json" | grep account | xxd | head -5
fi

echo "=== CHECKING MODEL ==="
needle2='"model": "codex \"5.4\""'
echo "Looking for: $needle2"
if [[ "$json" == *"$needle2"* ]]; then
  echo "MATCH"
else
  echo "NO MATCH"
  echo "=== HEX of model line ==="
  echo "$json" | grep model | xxd | head -5
fi
