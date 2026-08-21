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
DASHBOARD_ACTIVE_INTERVAL_SECONDS=30
CODEX_STATUS_TIMEOUT_SECONDS=5
ARCHIVE_RETENTION_DAYS=0
HISTORY_RETENTION_HOURS=0.25
CURL_CONNECT_TIMEOUT_SECONDS=1
CURL_MAX_TIME_SECONDS=1
CURL_RETRIES=0
CURL_RETRY_DELAY_SECONDS=0
CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=0
CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD=100
ALERT_THRESHOLDS=0,100
validate_config
LOOP_INTERVAL=86400
DASHBOARD_ACTIVE_INTERVAL_SECONDS=86400
CODEX_STATUS_TIMEOUT_SECONDS=300
ARCHIVE_RETENTION_DAYS=36500
HISTORY_RETENTION_HOURS=8760
CURL_CONNECT_TIMEOUT_SECONDS=60
CURL_MAX_TIME_SECONDS=600
CURL_RETRIES=5
CURL_RETRY_DELAY_SECONDS=60
CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=100
CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD=0
validate_config
for assignment in \
  'ALERTS_ENABLED=' 'ALERTS_ENABLED=2' 'ALERTS_ENABLED=-1' 'ALERTS_ENABLED=01' 'ALERTS_ENABLED=yes' \
  'LOOP_INTERVAL=0' 'LOOP_INTERVAL=86401' \
  'DASHBOARD_ACTIVE_INTERVAL_SECONDS=29' 'DASHBOARD_ACTIVE_INTERVAL_SECONDS=86401' \
  'CODEX_STATUS_TIMEOUT_SECONDS=4' 'CODEX_STATUS_TIMEOUT_SECONDS=301' \
  'ARCHIVE_RETENTION_DAYS=-1' 'ARCHIVE_RETENTION_DAYS=36501' 'ARCHIVE_RETENTION_DAYS=1.5' 'ARCHIVE_RETENTION_DAYS=abc' \
  'HISTORY_RETENTION_HOURS=0.24' 'HISTORY_RETENTION_HOURS=8761' \
  'CURL_CONNECT_TIMEOUT_SECONDS=0' 'CURL_MAX_TIME_SECONDS=601' \
  'CURL_RETRIES=6' 'CURL_RETRY_DELAY_SECONDS=61' \
  'CODEX_FORECAST_ENABLED=2' \
  'CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=-1' 'CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=101' \
  'CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=1.5' 'CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD=abc' \
  'ALERT_THRESHOLDS=101' 'ALERT_THRESHOLDS=50,,10'; do
  monitor_defaults
  eval "$assignment"
  validate_config >/dev/null 2>&1 && fail "invalid config accepted: $assignment"
done

monitor_defaults
printf 'ALERTS_ENABLED=\n' > "$ENV_FILE"
load_config
validate_config >/dev/null 2>&1 && fail "explicitly empty ALERTS_ENABLED accepted from .env"

monitor_defaults
printf 'ALERTS_ENABLED=0\nCODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD=65\nCODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD=35\nDASHBOARD_ACTIVE_INTERVAL_SECONDS=120\n' > "$ENV_FILE"
load_config
assert_eq 0 "$ALERTS_ENABLED" "ALERTS_ENABLED was not loaded"
assert_eq 65 "$CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD" "24-hour Forecast threshold was not loaded"
assert_eq 35 "$CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD" "6-hour Forecast threshold was not loaded"
assert_eq 120 "$DASHBOARD_ACTIVE_INTERVAL_SECONDS" "dashboard active interval was not loaded"

python3 - "$MONITOR_PATH" "${ROOT_DIR}/local/.env.example" <<'PYEOF'
import re
import sys
from pathlib import Path

monitor = Path(sys.argv[1]).read_text(encoding="utf-8")
example = Path(sys.argv[2]).read_text(encoding="utf-8")
case = re.search(r'case "\$key" in(.*?)\n\s*\*\)', monitor, re.S)
assert case is not None
keys = set()
for group in re.findall(r'\n\s*([A-Z][A-Z0-9_|]+)\)', case.group(1)):
    keys.update(group.split('|'))
missing = sorted(key for key in keys if key not in example)
if missing:
    raise SystemExit(f".env.example is missing accepted keys: {', '.join(missing)}")
PYEOF

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
printf 'ALERT_SCRIPT_99="%s"\nALERT_SCRIPT_99_EVENTS="5h:75, weekly:reset"\n' "$SCRIPT_FIXTURE" > "$ENV_FILE"
load_config
loaded_path_name=ALERT_SCRIPT_99
loaded_events_name=ALERT_SCRIPT_99_EVENTS
assert_eq "$SCRIPT_FIXTURE" "${!loaded_path_name}" "indexed script path was not loaded from .env"
assert_eq '5h:75, weekly:reset' "${!loaded_events_name}" "indexed script events were not loaded from .env"
validate_config

monitor_defaults
INVALID_ALERT_SCRIPT_CONFIG=0
printf 'ALERT_SCRIPT_100=%s\nALERT_SCRIPT_100_EVENTS=5h:50\n' "$SCRIPT_FIXTURE" > "$ENV_FILE"
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

printf 'PASS: monitor configuration tests\n'
