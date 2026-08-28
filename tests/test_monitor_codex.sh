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
expected_coherent="$(python3 -c 'import hashlib; print("limit-" + hashlib.sha256(b"coherent").hexdigest())')"
assert_eq "$expected_coherent" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limit_id"])' <<< "$result")"
assert_eq 79.75 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["five_h_pct"])' <<< "$result")" "real-valued percentage lost"
assert_eq 4.5 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_pct"])' <<< "$result")"
assert_eq '18/05/2033 05:33' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["five_h_reset"])' <<< "$result")" "5h reset is not formatted in Paris time"
assert_eq '25/05/2033 04:13' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_reset"])' <<< "$result")" "weekly reset is not formatted in Paris time"

export FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/partial.json"
diagnostic="${TEST_ROOT}/partial.err"
result="$(fetch_status_json 900 2>"$diagnostic")"
expected_partial="$(python3 -c 'import hashlib; print("limit-" + hashlib.sha256(b"partial").hexdigest())')"
assert_eq "$expected_partial" "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["limit_id"])' <<< "$result")"
assert_eq None "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["weekly_pct"])' <<< "$result")" "partial response fabricated weekly data"
assert_contains "$(<"$diagnostic")" 'partial limit group' "partial response did not produce an explicit warning"

export FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/unknown.json"
fetch_status_json 900 >/dev/null 2>&1 && fail "unknown windows were accepted"

timeout_codex="${TEST_ROOT}/timeout-codex.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$timeout_codex"
chmod +x "$timeout_codex"
CODEX_BIN="$timeout_codex"
CODEX_STATUS_TIMEOUT_SECONDS=5
set +e
timeout_output="$(fetch_status_json 900 2>&1)"
timeout_status=$?
set -e
assert_eq 1 "$timeout_status" "Codex timeout exit status"
assert_contains "$timeout_output" "Timed out" "Codex timeout diagnostic"
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "${3:-unexpected text}: '$2'"
}
assert_not_contains "$timeout_output" "Traceback" "Codex timeout traceback"

initialize() { LOOP_INTERVAL=900; }
CODEX_STATUS_TIMEOUT_SECONDS=0.1
set +e
status_json_output="$(main --status-json 2>&1)"
status_json_status=$?
set -e
assert_eq 1 "$status_json_status" "monitor --status-json timeout exit status"
assert_contains "$status_json_output" "Timed out" "monitor --status-json timeout diagnostic"

printf 'PASS: Codex parsing tests\n'
