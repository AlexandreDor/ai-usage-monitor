#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
CODEX_BIN="${ROOT_DIR}/tests/fixtures/fake-codex.sh"
export CODEX_BIN

export FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/multi-id.json"
result="$(fetch_status_json 900)"
assert_eq coherent "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limit_id"])' <<< "$result")"
assert_eq 79.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["five_h_pct"])' <<< "$result")" "real-valued percentage lost"
assert_eq 4.5 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_pct"])' <<< "$result")"

export FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/partial.json"
diagnostic="${TEST_ROOT}/partial.err"
result="$(fetch_status_json 900 2>"$diagnostic")"
assert_eq partial "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limit_id"])' <<< "$result")"
assert_eq None "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_pct"])' <<< "$result")" "partial response fabricated weekly data"
assert_contains "$(<"$diagnostic")" 'partial limit group' "partial response did not produce an explicit warning"

export FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/unknown.json"
fetch_status_json 900 >/dev/null 2>&1 && fail "unknown windows were accepted"

printf 'PASS: Codex parsing tests\n'
