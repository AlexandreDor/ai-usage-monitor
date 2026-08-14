#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

COMMAND_STATUS=0
run_cli() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  COMMAND_STATUS=$?
  set -e
}

CLI_ROOT="${TEST_ROOT}/isolated-cli"
ISOLATED_MONITOR="${CLI_ROOT}/monitor.sh"
FAKE_CODEX="${CLI_ROOT}/fake-codex.sh"
FAKE_CODEX_MARKER="${TEST_ROOT}/fake-codex-invoked"
EXTERNAL_ENV="${TEST_ROOT}/external.env"
mkdir -p "$CLI_ROOT"
cp "$MONITOR_PATH" "$ISOLATED_MONITOR"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf invoked > "$FAKE_CODEX_MARKER"' > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"
printf 'LOOP_INTERVAL=invalid\n' > "$EXTERNAL_ENV"
ln -s "$EXTERNAL_ENV" "${CLI_ROOT}/.env"

LONG_STDOUT="${TEST_ROOT}/help-long.stdout"
LONG_STDERR="${TEST_ROOT}/help-long.stderr"
run_cli "$LONG_STDOUT" "$LONG_STDERR" \
  env CODEX_BIN_OVERRIDE="$FAKE_CODEX" FAKE_CODEX_MARKER="$FAKE_CODEX_MARKER" \
  bash "$ISOLATED_MONITOR" --help
assert_eq 0 "$COMMAND_STATUS" "--help exit status"
[[ ! -s "$LONG_STDERR" ]] || fail "--help wrote to stderr"
assert_contains "$(<"$LONG_STDOUT")" 'Usage: ./monitor.sh' "help usage"
assert_contains "$(<"$LONG_STDOUT")" '--once' "help omits once mode"
assert_contains "$(<"$LONG_STDOUT")" '--loop [SECONDS]' "help omits loop mode"
assert_contains "$(<"$LONG_STDOUT")" '--check' "help omits check mode"
assert_contains "$(<"$LONG_STDOUT")" '--status-json' "help omits status-json mode"
assert_contains "$(<"$LONG_STDOUT")" '-h, --help' "help omits aliases"
assert_contains "$(<"$LONG_STDOUT")" '1 to 86400' "help omits interval range"
assert_contains "$(<"$LONG_STDOUT")" '900 seconds' "help omits default interval"
assert_contains "$(<"$LONG_STDOUT")" 'mutually' "help omits mode exclusivity"
assert_contains "$(<"$LONG_STDOUT")" '--fail-fast can only be used with --loop' "help omits fail-fast restriction"
[[ -L "${CLI_ROOT}/.env" ]] || fail "--help replaced the configuration symlink"
[[ ! -e "${CLI_ROOT}/runtime" ]] || fail "--help created the runtime directory"
[[ ! -e "$FAKE_CODEX_MARKER" ]] || fail "--help invoked Codex"

SHORT_STDOUT="${TEST_ROOT}/help-short.stdout"
SHORT_STDERR="${TEST_ROOT}/help-short.stderr"
run_cli "$SHORT_STDOUT" "$SHORT_STDERR" bash "$ISOLATED_MONITOR" -h
assert_eq 0 "$COMMAND_STATUS" "-h exit status"
[[ ! -s "$SHORT_STDERR" ]] || fail "-h wrote to stderr"
assert_eq "$(<"$LONG_STDOUT")" "$(<"$SHORT_STDOUT")" "help aliases differ"

COMBINED_STDOUT="${TEST_ROOT}/help-combined.stdout"
COMBINED_STDERR="${TEST_ROOT}/help-combined.stderr"
run_cli "$COMBINED_STDOUT" "$COMBINED_STDERR" \
  bash "$ISOLATED_MONITOR" --once --unknown --help --check
assert_eq 0 "$COMMAND_STATUS" "combined help exit status"
[[ ! -s "$COMBINED_STDERR" ]] || fail "combined help wrote to stderr"
assert_eq "$(<"$LONG_STDOUT")" "$(<"$COMBINED_STDOUT")" "combined help output differs"

assert_usage_error() {
  local label="$1"
  shift
  local stdout_file="${TEST_ROOT}/${label}.stdout"
  local stderr_file="${TEST_ROOT}/${label}.stderr"
  run_cli "$stdout_file" "$stderr_file" bash "$ISOLATED_MONITOR" "$@"
  assert_eq 2 "$COMMAND_STATUS" "$label exit status"
  [[ ! -s "$stdout_file" ]] || fail "$label wrote to stdout"
  assert_contains "$(<"$stderr_file")" '[ERROR]' "$label error message"
  assert_contains "$(<"$stderr_file")" 'Usage: ./monitor.sh' "$label usage"
  [[ ! -e "${CLI_ROOT}/runtime" ]] || fail "$label initialized the runtime"
}

assert_usage_error conflicting-once-check --once --check
assert_usage_error conflicting-loop-status --loop --status-json
assert_usage_error fail-fast-with-once --once --fail-fast
assert_usage_error zero-interval --loop 0
assert_usage_error excessive-interval --loop 86401
assert_usage_error unknown-option --unknown
assert_usage_error unexpected-positional unexpected

# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
DISPATCH_LOG="${TEST_ROOT}/dispatch.log"

initialize() {
  LOOP_INTERVAL=900
}

run_once() {
  printf 'once:%s\n' "$1" >> "$DISPATCH_LOG"
}

run_loop() {
  printf 'loop:%s:%s\n' "$1" "$2" >> "$DISPATCH_LOG"
}

main >/dev/null
main --once >/dev/null
main --loop 60 --fail-fast >/dev/null
main --fail-fast --loop 60 >/dev/null
main --fail-fast --fail-fast --loop 60 >/dev/null

expected_dispatch=$'once:900\nonce:900\nloop:60:1\nloop:60:1\nloop:60:1'
assert_eq "$expected_dispatch" "$(<"$DISPATCH_LOG")" "CLI dispatch"

printf 'PASS: monitor CLI help and parsing tests\n'
