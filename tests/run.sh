#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$TEST_DIR/test_alerts.py"
python3 "$TEST_DIR/test_anomalies.py"
python3 "$TEST_DIR/test_history.py"

for test_file in "$TEST_DIR"/test_*.sh; do
  bash "$test_file"
done

if command -v node >/dev/null 2>&1; then
  node "$TEST_DIR/test_chart_interactions.js"
  node "$TEST_DIR/test_analytics.js"
  node "$TEST_DIR/test_preferences.js"
  node "$TEST_DIR/test_dashboard.js"
else
  printf 'FAIL: node is required for dashboard tests\n' >&2
  exit 1
fi

printf 'PASS: complete test suite\n'
