#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_file in "$TEST_DIR"/test_*.sh; do
  bash "$test_file"
done

if command -v node >/dev/null 2>&1; then
  node "$TEST_DIR/test_dashboard.js"
else
  printf 'FAIL: node is required for dashboard tests\n' >&2
  exit 1
fi

printf 'PASS: complete test suite\n'
