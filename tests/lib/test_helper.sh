#!/usr/bin/env bash
# Shared globals are consumed by scripts that source this helper.
# shellcheck disable=SC2034

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MONITOR_PATH="${ROOT_DIR}/local/monitor.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local haystack="$1" needle="$2" message="${3:-missing text}"
  [[ "$haystack" == *"$needle"* ]] || fail "${message}: '${needle}'"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

use_test_runtime() {
  RUNTIME_DIR="${TEST_ROOT}/runtime"
  STATE_FILE="${RUNTIME_DIR}/.alert_state"
  DATA_FILE="${RUNTIME_DIR}/data.json"
  HISTORY_FILE="${RUNTIME_DIR}/history.json"
  ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
  HEALTH_FILE="${RUNTIME_DIR}/health.json"
  LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
  ENV_FILE="${TEST_ROOT}/.env"
  mkdir -p "$RUNTIME_DIR"
}

monitor_defaults() {
  local index
  for (( index = 1; index <= 99; index++ )); do
    unset "ALERT_SCRIPT_${index}" "ALERT_SCRIPT_${index}_EVENTS"
  done
  ALERT_THRESHOLDS=75,50,25,10,5
  ALERT_SCRIPT_TIMEOUT_SECONDS=30
  ARCHIVE_RETENTION_DAYS=365
  HISTORY_RETENTION_HOURS=192
  LOOP_INTERVAL=900
  CODEX_STATUS_TIMEOUT_SECONDS=5
  CURL_CONNECT_TIMEOUT_SECONDS=1
  CURL_MAX_TIME_SECONDS=2
  CURL_RETRIES=0
  CURL_RETRY_DELAY_SECONDS=0
  MONITOR_DEBUG=0
  DISCORD_WEBHOOK=""
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
  GITHUB_PAT=""
  GITHUB_GIST_ID=""
  GITHUB_API_URL=https://api.github.com
  TELEGRAM_API_URL=https://api.telegram.org
  TOKEN_USAGE_SOURCES=none
  TOKEN_PRICING_FILE="${ROOT_DIR}/local/pricing.json"
  CODEX_DATA_DIR="${TEST_ROOT}/missing-codex"
  OPENCODE_DB_PATH="${TEST_ROOT}/missing-opencode.db"
  HERMES_DB_PATH="${TEST_ROOT}/missing-hermes.db"
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print("null" if value is None else str(value).lower() if isinstance(value, bool) else value)
PY
}
