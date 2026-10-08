#!/usr/bin/env bash
# Measure unit tests and the Python processes started by the functional suite.
set -euo pipefail

if (($#)); then
  printf 'Usage: scripts/test-coverage.sh\n' >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Each run combines only its own data. Existing measurements are never erased.
mkdir -p coverage
data_dir="$(mktemp -d "$ROOT_DIR/coverage/.run.XXXXXXXX")"
trap 'rm -rf -- "$data_dir"' EXIT
export COVERAGE_FILE="$data_dir/.coverage"
export COVERAGE_RCFILE="$ROOT_DIR/.coveragerc"
export COVERAGE_PROCESS_START="$COVERAGE_RCFILE"
export PYTHONPATH="$ROOT_DIR/tests/coverage_bootstrap${PYTHONPATH:+:$PYTHONPATH}"

coverage_command() {
  # Reporting must not start another measurement of the reporting process.
  env -u COVERAGE_PROCESS_START python3 -m coverage "$@"
}

test_status=0
python3 -m unittest discover -s tests -p 'test_*.py' || test_status=$?
if SKIP_PYTHON_TESTS=1 bash tests/run.sh; then
  :
else
  shell_status=$?
  if ((test_status == 0)); then
    test_status=$shell_status
  fi
fi

# Generate evidence even when a test fails, and preserve the test's exit status.
report_status=0
if coverage_command combine "$data_dir"; then
  cp -- "$COVERAGE_FILE" coverage/.coverage
  coverage_command report >coverage/report.txt 2>&1 || report_status=$?
  cat coverage/report.txt
  coverage_command xml --fail-under=0 -o coverage/coverage.xml || report_status=$?
  coverage_command json --fail-under=0 -o coverage/coverage.json || report_status=$?
else
  report_status=$?
fi

if ((test_status != 0)); then
  exit "$test_status"
fi
exit "$report_status"
