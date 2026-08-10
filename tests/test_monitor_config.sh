#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

before_runtime="$(stat -c '%Y:%s' "${ROOT_DIR}/local/runtime" 2>/dev/null || true)"
before_env="$(stat -c '%Y:%s' "${ROOT_DIR}/local/.env" 2>/dev/null || true)"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
after_runtime="$(stat -c '%Y:%s' "${ROOT_DIR}/local/runtime" 2>/dev/null || true)"
after_env="$(stat -c '%Y:%s' "${ROOT_DIR}/local/.env" 2>/dev/null || true)"
assert_eq "$before_runtime" "$after_runtime" "sourcing touched developer runtime"
assert_eq "$before_env" "$after_env" "sourcing touched developer .env"
use_test_runtime
monitor_defaults

validate_config

for invalid_sources in '' 'codex,' 'auto,codex' 'codex,other'; do
  monitor_defaults
  TOKEN_USAGE_SOURCES="$invalid_sources"
  validate_config >/dev/null 2>&1 && fail "invalid token sources accepted: '$invalid_sources'"
done
monitor_defaults
TOKEN_USAGE_SOURCES=codex,opencode,hermes
validate_config
monitor_defaults
CODEX_DATA_DIR=relative/path
validate_config >/dev/null 2>&1 && fail "relative token source path accepted"
monitor_defaults
TOKEN_PRICING_FILE="${TEST_ROOT}/missing-pricing.json"
validate_config >/dev/null 2>&1 && fail "missing pricing catalog accepted"
monitor_defaults
LOOP_INTERVAL=1
CODEX_STATUS_TIMEOUT_SECONDS=5
ARCHIVE_RETENTION_DAYS=0
HISTORY_RETENTION_HOURS=0.25
CURL_CONNECT_TIMEOUT_SECONDS=1
CURL_MAX_TIME_SECONDS=1
CURL_RETRIES=0
CURL_RETRY_DELAY_SECONDS=0
ALERT_THRESHOLDS=0,100
validate_config
LOOP_INTERVAL=86400
CODEX_STATUS_TIMEOUT_SECONDS=300
ARCHIVE_RETENTION_DAYS=36500
HISTORY_RETENTION_HOURS=8760
CURL_CONNECT_TIMEOUT_SECONDS=60
CURL_MAX_TIME_SECONDS=600
CURL_RETRIES=5
CURL_RETRY_DELAY_SECONDS=60
validate_config
for assignment in \
  'LOOP_INTERVAL=0' 'LOOP_INTERVAL=86401' \
  'CODEX_STATUS_TIMEOUT_SECONDS=4' 'CODEX_STATUS_TIMEOUT_SECONDS=301' \
  'ARCHIVE_RETENTION_DAYS=-1' 'ARCHIVE_RETENTION_DAYS=36501' 'ARCHIVE_RETENTION_DAYS=1.5' 'ARCHIVE_RETENTION_DAYS=abc' \
  'HISTORY_RETENTION_HOURS=0.24' 'HISTORY_RETENTION_HOURS=8761' \
  'CURL_CONNECT_TIMEOUT_SECONDS=0' 'CURL_MAX_TIME_SECONDS=601' \
  'CURL_RETRIES=6' 'CURL_RETRY_DELAY_SECONDS=61' \
  'ALERT_THRESHOLDS=101' 'ALERT_THRESHOLDS=50,,10'; do
  monitor_defaults
  eval "$assignment"
  validate_config >/dev/null 2>&1 && fail "invalid config accepted: $assignment"
done

monitor_defaults
GITHUB_PAT=token
validate_config >/dev/null 2>&1 && fail "partial Gist pair accepted"
monitor_defaults
TELEGRAM_BOT_TOKEN='123:abc'
validate_config >/dev/null 2>&1 && fail "partial Telegram pair accepted"

for chat_id in 0 01 -0 abc '+123'; do
  monitor_defaults
  TELEGRAM_BOT_TOKEN='123:abc'
  TELEGRAM_CHAT_ID="$chat_id"
  validate_config >/dev/null 2>&1 && fail "invalid chat ID accepted: $chat_id"
done
monitor_defaults
TELEGRAM_BOT_TOKEN='123:abc'
TELEGRAM_CHAT_ID=-123
validate_config

for valid_api_url in \
  'https://api.example.com/v1' 'http://localhost:8080' \
  'http://127.0.0.1:8080' 'http://[::1]:8080'; do
  monitor_defaults
  GITHUB_API_URL="$valid_api_url"
  validate_config
done
for invalid_api_url in \
  'http://api.example.com' 'https://user@api.example.com' \
  'https://api.example.com/path#fragment' 'https://api.example.com/path?query=1'; do
  monitor_defaults
  GITHUB_API_URL="$invalid_api_url"
  validate_config >/dev/null 2>&1 && fail "invalid API URL accepted: $invalid_api_url"
done

monitor_defaults
GITHUB_PAT=$'token\nheader'
GITHUB_GIST_ID=abc123
validate_config >/dev/null 2>&1 && fail "control character accepted in credential"

monitor_defaults
SCRIPT_FIXTURE="${TEST_ROOT}/valid alert hook.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_FIXTURE"
chmod 700 "$SCRIPT_FIXTURE"
ALERT_SCRIPT_2="$SCRIPT_FIXTURE"
ALERT_SCRIPT_2_EVENTS=' 5h:050, weekly:reset '
# Indexed alert script variables are consumed indirectly by monitor.sh.
# shellcheck disable=SC2034
ALERT_SCRIPT_9="$SCRIPT_FIXTURE"
# shellcheck disable=SC2034
ALERT_SCRIPT_9_EVENTS='5h:25'
validate_config
assert_eq 3 "${#ALERT_SCRIPT_RULE_INDICES[@]}" "script actions were not normalized"
assert_eq '5h:50' "${ALERT_SCRIPT_RULE_EVENTS[0]}" "leading-zero threshold was not normalized"

monitor_defaults
SCRIPT_LINK="${TEST_ROOT}/alert-hook-link.sh"
ln -s "$SCRIPT_FIXTURE" "$SCRIPT_LINK"
ALERT_SCRIPT_1="$SCRIPT_LINK"
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config >/dev/null 2>&1 && fail "symlink alert script accepted"
monitor_defaults
chmod 720 "$SCRIPT_FIXTURE"
ALERT_SCRIPT_1="$SCRIPT_FIXTURE"
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config >/dev/null 2>&1 && fail "group-writable alert script accepted"
chmod 700 "$SCRIPT_FIXTURE"

monitor_defaults
printf 'ALERT_SCRIPT_99="%s"\nALERT_SCRIPT_99_EVENTS="5h:75, weekly:reset"\n' "$SCRIPT_FIXTURE" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
load_config
loaded_path_name=ALERT_SCRIPT_99
loaded_events_name=ALERT_SCRIPT_99_EVENTS
assert_eq "$SCRIPT_FIXTURE" "${!loaded_path_name}" "indexed script path was not loaded from .env"
assert_eq '5h:75, weekly:reset' "${!loaded_events_name}" "indexed script events were not loaded from .env"
validate_config

monitor_defaults
INVALID_ALERT_SCRIPT_CONFIG=0
printf 'ALERT_SCRIPT_100=%s\nALERT_SCRIPT_100_EVENTS=5h:50\n' "$SCRIPT_FIXTURE" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
load_config >/dev/null 2>&1
validate_config >/dev/null 2>&1 && fail "invalid .env script index accepted"
INVALID_ALERT_SCRIPT_CONFIG=0

for invalid_events in '' '5h' 'daily:50' '5h:101' 'weekly:-1' '5h:reset,'; do
  monitor_defaults
  ALERT_SCRIPT_1="$SCRIPT_FIXTURE"
  ALERT_SCRIPT_1_EVENTS="$invalid_events"
  validate_config >/dev/null 2>&1 && fail "invalid script events accepted: '${invalid_events}'"
done

monitor_defaults
ALERT_SCRIPT_1="$SCRIPT_FIXTURE"
validate_config >/dev/null 2>&1 && fail "unpaired script path accepted"
monitor_defaults
# shellcheck disable=SC2034
ALERT_SCRIPT_100="$SCRIPT_FIXTURE"
validate_config >/dev/null 2>&1 && fail "out-of-range script index accepted"
unset ALERT_SCRIPT_100
monitor_defaults
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config >/dev/null 2>&1 && fail "unpaired script events accepted"
monitor_defaults
ALERT_SCRIPT_1=relative-hook.sh
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config >/dev/null 2>&1 && fail "relative script path accepted"
monitor_defaults
ALERT_SCRIPT_1="${TEST_ROOT}/missing-hook.sh"
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config >/dev/null 2>&1 && fail "missing script accepted"

monitor_defaults
ALERT_SCRIPT_1="$SCRIPT_FIXTURE"
ALERT_SCRIPT_1_EVENTS=5h:50
# shellcheck disable=SC2034
ALERT_SCRIPT_2="$SCRIPT_FIXTURE"
# shellcheck disable=SC2034
ALERT_SCRIPT_2_EVENTS=5h:050
validate_config >/dev/null 2>&1 && fail "duplicate path/event action accepted"

for timeout_value in 0 1801 abc; do
  monitor_defaults
  ALERT_SCRIPT_TIMEOUT_SECONDS="$timeout_value"
  validate_config >/dev/null 2>&1 && fail "invalid script timeout accepted: $timeout_value"
done

monitor_defaults
INJECTION_MARKER="${ROOT_DIR}/injected"
METACHAR_SCRIPT="${TEST_ROOT}/hook \$(touch injected)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$METACHAR_SCRIPT"
chmod 700 "$METACHAR_SCRIPT"
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$METACHAR_SCRIPT"
# shellcheck disable=SC2034
ALERT_SCRIPT_1_EVENTS=5h:50
validate_config
[[ ! -e "$INJECTION_MARKER" ]] || fail "script path was evaluated as shell code"

help_output="$(CODEX_USAGE_MONITOR_CONFIG="${TEST_ROOT}/missing.env" CODEX_BIN="definitely-missing-codex" bash "$MONITOR_PATH" --help)"
for documented_option in '--once' '--loop [SECONDS]' '--check' '--status-json' '--fail-fast' '--config FILE' '--state-dir DIRECTORY'; do
  assert_contains "$help_output" "$documented_option" "monitor help omitted $documented_option"
done

cli_root="${TEST_ROOT}/CLI paths with spaces"
cli_config="${cli_root}/monitor config.env"
cli_state="${cli_root}/selected state"
environment_state="${cli_root}/environment state"
file_state="${cli_root}/file state"
fake_codex="${cli_root}/fake codex"
malicious_marker="${cli_root}/malicious command ran"
mkdir -p "$cli_root"
cp "${ROOT_DIR}/tests/fixtures/fake-codex.sh" "$fake_codex"
chmod 700 "$fake_codex"
printf '%s\n' \
  "CODEX_BIN='${fake_codex}'" \
  'TOKEN_USAGE_SOURCES=none' \
  "TOKEN_PRICING_FILE='${ROOT_DIR}/local/pricing.json'" \
  "STATE_DIR='${file_state}'" \
  "IGNORED_VALUE=\$(touch '${malicious_marker}')" > "$cli_config"
chmod 600 "$cli_config"
CODEX_USAGE_MONITOR_STATE_DIR="$environment_state" \
FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/multi-id.json" \
  bash "$MONITOR_PATH" --config "$cli_config" --state-dir "$cli_state" --check >/dev/null
[[ -d "$cli_state" ]] || fail "explicit monitor state directory was not created"
[[ ! -e "$environment_state" && ! -e "$file_state" ]] || fail "CLI state directory did not take priority"
[[ ! -e "$malicious_marker" ]] || fail "malicious .env text was executed"

curl_arguments="${TEST_ROOT}/curl-arguments"
curl() {
  local output_file="" argument
  : > "$curl_arguments"
  for argument in "$@"; do
    printf '%s\n' "$argument" >> "$curl_arguments"
  done
  while (($#)); do
    case "$1" in
      --output) output_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cat >/dev/null
  [[ -z "$output_file" ]] || printf '{}\n' > "$output_file"
  printf '204'
}
monitor_defaults
http_response="${TEST_ROOT}/http-response"
http_request Test 204 'url = "https://example.invalid"' POST "$http_response" >/dev/null
assert_eq '-q' "$(sed -n '1p' "$curl_arguments")" "curl -q was not the first argument"
assert_contains "$({ sed -n '/--max-filesize/{N;p;}' "$curl_arguments"; } 2>/dev/null)" $'--max-filesize\n1048576' \
  "curl response body limit is missing"
unset -f curl

status_config="${cli_root}/status-only.env"
status_state="${cli_root}/status state must stay absent"
printf '%s\n' \
  "CODEX_BIN='${fake_codex}'" \
  'LOOP_INTERVAL=60' \
  'ALERT_THRESHOLDS=invalid' \
  'TOKEN_USAGE_SOURCES=invalid' \
  'TOKEN_PRICING_FILE=/missing/catalog.json' \
  'GITHUB_API_URL=http://example.com' > "$status_config"
chmod 600 "$status_config"
status_output="$(FAKE_CODEX_FIXTURE="${ROOT_DIR}/tests/fixtures/codex/multi-id.json" \
  bash "$MONITOR_PATH" --config "$status_config" --state-dir "$status_state" --status-json)"
assert_contains "$status_output" '"five_h_pct"' "status-json did not return Codex JSON"
[[ ! -e "$status_state" ]] || fail "status-json created its state directory"

printf 'PASS: monitor configuration tests\n'
