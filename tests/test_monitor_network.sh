#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

FAKE_BIN="${TEST_ROOT}/bin"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/curl-counts"
mkdir -p "$FAKE_BIN" "$FAKE_CURL_COUNT_DIR"
ln -s "${ROOT_DIR}/tests/fixtures/fake-curl.sh" "${FAKE_BIN}/curl"
export PATH="${FAKE_BIN}:$PATH"
export FAKE_CURL_LOG="${TEST_ROOT}/curl.log"
response="${TEST_ROOT}/response"

reset_fake_curl() {
  rm -f "$FAKE_CURL_LOG" "$FAKE_CURL_COUNT_DIR"/*
  unset FAKE_CURL_STATUS FAKE_CURL_EXIT FAKE_CURL_BODY FAKE_CURL_HEADERS FAKE_CURL_ERROR
  unset FAKE_CURL_STATUS_SEQUENCE FAKE_CURL_EXIT_SEQUENCE
  unset FAKE_CURL_DISCORD_STATUS FAKE_CURL_DISCORD_EXIT FAKE_CURL_DISCORD_BODY FAKE_CURL_DISCORD_HEADERS FAKE_CURL_DISCORD_ERROR
  unset FAKE_CURL_DISCORD_STATUS_SEQUENCE FAKE_CURL_DISCORD_EXIT_SEQUENCE
  unset FAKE_CURL_TELEGRAM_STATUS FAKE_CURL_TELEGRAM_EXIT FAKE_CURL_TELEGRAM_BODY FAKE_CURL_TELEGRAM_HEADERS FAKE_CURL_TELEGRAM_ERROR
  unset FAKE_CURL_TELEGRAM_STATUS_SEQUENCE FAKE_CURL_TELEGRAM_EXIT_SEQUENCE
  unset FAKE_CURL_STATE_FILE FAKE_CURL_DISCORD_STATE_SNAPSHOT FAKE_CURL_TELEGRAM_STATE_SNAPSHOT
  unset FAKE_CURL_DATA_LOG
  unset FAKE_CURL_ARGUMENT_LOG
  unset FAKE_CURL_PAYLOAD_FILE
}

request_count() {
  [[ -f "$FAKE_CURL_LOG" ]] && wc -l < "$FAKE_CURL_LOG" || printf '0\n'
}

state_value() {
  awk -F= -v wanted="$1" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "$STATE_FILE"
}

reset_fake_curl
export FAKE_CURL_STATUS=204 FAKE_CURL_EXIT=0
http_request Test 204 'url = "https://example.invalid"' POST "$response"

# Permanent client errors are attempted once even when retries are configured.
CURL_RETRIES=2
for status in 400 401 404; do
  reset_fake_curl
  export FAKE_CURL_STATUS="$status" FAKE_CURL_EXIT=0
  http_request Test 204 'url = "https://example.invalid/private"' POST "$response" >/dev/null 2>&1 \
    && fail "HTTP $status accepted"
  assert_eq 1 "$(request_count)" "HTTP $status was retried"
done

# 408, 5xx, and curl timeouts are transient and stop after a later success.
for sequence in '408,204' '500,204'; do
  reset_fake_curl
  export FAKE_CURL_STATUS_SEQUENCE="$sequence" FAKE_CURL_EXIT=0
  http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null
  assert_eq 2 "$(request_count)" "transient HTTP sequence $sequence"
done
reset_fake_curl
export FAKE_CURL_STATUS=500 FAKE_CURL_EXIT=0
http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null 2>&1 \
  && fail "exhausted HTTP 500 accepted"
assert_eq 3 "$(request_count)" "HTTP 500 retries were not bounded"
reset_fake_curl
export FAKE_CURL_STATUS_SEQUENCE='000,204' FAKE_CURL_EXIT_SEQUENCE='28,0'
http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null
assert_eq 2 "$(request_count)" "curl timeout was not retried"

# Retry-After takes precedence over backoff and is capped without sleeping in tests.
reset_fake_curl
CURL_RETRIES=1
CURL_RETRY_DELAY_SECONDS=2
SLEEP_LOG="${TEST_ROOT}/sleep.log"
sleep() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }
export FAKE_CURL_STATUS_SEQUENCE='429,204' FAKE_CURL_HEADERS=$'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 120\r\n\r\n'
http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null
assert_eq 60 "$(<"$SLEEP_LOG")" "numeric Retry-After was not capped"

retry_date="$(date -u -d '@2000000007' '+%a, %d %b %Y %H:%M:%S GMT')"
printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: %s\r\n\r\n' "$retry_date" > "$response.headers"
assert_eq 'transient 7' "$(python3 "$ROOT_DIR/local/alerts.py" retry 0 429 1 0 60 "$response.headers" --now 2000000000)" \
  "HTTP-date Retry-After was not parsed"

# Diagnostics remain structured even if curl emits credentials and sensitive URLs.
reset_fake_curl
CURL_RETRIES=0
MONITOR_DEBUG=1
secret='bot-token-SECRET chat-id-9988 https://discord.com/api/webhooks/123/private-token'
export FAKE_CURL_STATUS=000 FAKE_CURL_EXIT=28 FAKE_CURL_ERROR="$secret" FAKE_CURL_BODY="$secret"
export FAKE_CURL_HEADERS="X-Sensitive: ${secret}"
diagnostic="$(http_request Discord 204 'url = "https://discord.com/api/webhooks/123/private-token"' POST "$response" 2>&1 || true)"
[[ "$diagnostic" != *SECRET* && "$diagnostic" != *private-token* && "$diagnostic" != *chat-id-9988* ]] \
  || fail "network diagnostics leaked sensitive data"
assert_contains "$diagnostic" 'Discord: curl=28, HTTP=000, attempt=1/1, retry_delay=0s' "redacted diagnostic missing fields"

# Partial success is failed globally, persisted per channel, and retries Discord only.
reset_fake_curl
rm -f "$STATE_FILE"
MONITOR_DEBUG=0
CURL_RETRIES=0
CURL_RETRY_DELAY_SECONDS=0
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456
ALERT_THRESHOLDS=75
export FAKE_CURL_DATA_LOG="${TEST_ROOT}/partial-alert-data.log"
export FAKE_CURL_DISCORD_STATUS=500 FAKE_CURL_DISCORD_EXIT=0
export FAKE_CURL_TELEGRAM_STATUS=200 FAKE_CURL_TELEGRAM_EXIT=0 FAKE_CURL_TELEGRAM_BODY='{"ok":true}'
export FAKE_CURL_STATE_FILE="$STATE_FILE" FAKE_CURL_TELEGRAM_STATE_SNAPSHOT="${TEST_ROOT}/state-before-telegram"
check_thresholds 70 100 later unknown '' '' 2000000000 >/dev/null 2>&1 \
  && fail "partial delivery completed the threshold alert"
assert_eq failed "$(awk -F= '$1 == "five_h_threshold_discord_status" {print $2}' "$FAKE_CURL_TELEGRAM_STATE_SNAPSHOT")" \
  "Discord result was not persisted before Telegram"
assert_eq failed "$(state_value five_h_threshold_status)" "partial alert status"
assert_eq failed "$(state_value five_h_threshold_discord_status)" "Discord failure state"
assert_eq delivered "$(state_value five_h_threshold_telegram_status)" "Telegram delivery state"
first_alert_id="$(state_value five_h_threshold_alert_id)"
[[ "$first_alert_id" =~ ^[a-f0-9]{24}$ ]] || fail "stable alert ID was not persisted"

reset_fake_curl
export FAKE_CURL_DATA_LOG="${TEST_ROOT}/partial-alert-data.log"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=500
check_thresholds 69 100 changed unknown '' '' 2000000001 >/dev/null
assert_eq discord "$(<"$FAKE_CURL_LOG")" "delivered Telegram channel was called again"
assert_eq "$first_alert_id" "$(state_value five_h_threshold_alert_id)" "alert ID changed during retry"
assert_eq delivered "$(state_value five_h_threshold_status)" "retried alert did not complete"
assert_eq '' "$(state_value pending_5h_threshold)" "pending threshold not cleared after retry"
mapfile -t partial_messages < <(
  while IFS= read -r line; do
    [[ "$line" == \{* ]] && printf '%s\n' "$line"
  done < "${TEST_ROOT}/partial-alert-data.log"
)
assert_eq 2 "${#partial_messages[@]}" "Discord retry payloads were not captured"
assert_eq "${partial_messages[0]}" "${partial_messages[1]}" "message changed while retrying one alert ID"

reset_fake_curl
check_thresholds 69 100 later unknown '' '' 2000000002 >/dev/null
assert_eq 0 "$(request_count)" "completed alert was called again"

# A permanent channel failure terminates only that occurrence. It is not
# retried, while a reset and a threshold in the next cycle get fresh IDs.
reset_fake_curl
rm -f "$STATE_FILE"
export FAKE_CURL_DISCORD_STATUS=401 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 70 100 later unknown 2000000110 '' 2000000100 >/dev/null 2>&1 \
  && fail "permanent channel failure completed globally"
permanent_alert_id="$(state_value five_h_threshold_alert_id)"
assert_eq '' "$(state_value pending_5h_threshold)" "permanent occurrence remained pending"
assert_eq failed "$(state_value five_h_threshold_status)" "permanent occurrence was marked delivered"
assert_eq failed "$(state_value five_h_threshold_discord_status)" "permanent channel status was lost"
reset_fake_curl
check_thresholds 70 100 later unknown 2000000110 '' 2000000101 >/dev/null 2>&1
assert_eq 0 "$(request_count)" "permanent channel failure was retried on a later cycle"
assert_eq "$permanent_alert_id" "$(state_value five_h_threshold_alert_id)" "terminal alert ID changed without a new event"
assert_eq 0 "$(state_value five_h_threshold_discord_retryable)" "permanent failure marked retryable"

reset_fake_curl
export FAKE_CURL_DISCORD_STATUS=401 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 100 100 unknown unknown '' '' 2000000111 >/dev/null 2>&1 || true
reset_fake_curl
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 70 100 later unknown 2000000500 '' 2000000120 >/dev/null
next_cycle_alert_id="$(state_value five_h_threshold_alert_id)"
[[ "$next_cycle_alert_id" =~ ^[a-f0-9]{24}$ ]] || fail "next cycle threshold has no alert ID"
[[ "$next_cycle_alert_id" != "$permanent_alert_id" ]] || fail "next cycle reused the permanent occurrence ID"
assert_eq 2 "$(request_count)" "next cycle threshold did not notify every configured channel"

# A lower threshold supersedes a transient pending occurrence. It receives a
# distinct ID and immutable message, and every channel starts fresh for it.
reset_fake_curl
rm -f "$STATE_FILE"
ALERT_THRESHOLDS=75,50
export FAKE_CURL_DATA_LOG="${TEST_ROOT}/alert-data.log"
export FAKE_CURL_DISCORD_STATUS=500 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 70 100 later unknown '' '' 2000001000 >/dev/null 2>&1 || true
pending_alert_id="$(state_value five_h_threshold_alert_id)"
assert_eq 75 "$(state_value pending_5h_threshold)" "initial transient threshold was not pending"

reset_fake_curl
export FAKE_CURL_DATA_LOG="${TEST_ROOT}/alert-data.log"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 40 100 later unknown '' '' 2000001001 >/dev/null
lower_alert_id="$(state_value five_h_threshold_alert_id)"
[[ "$lower_alert_id" != "$pending_alert_id" ]] || fail "lower threshold reused pending alert ID"
assert_eq "$pending_alert_id" "$(state_value five_h_threshold_last_terminal_alert_id)" "superseded alert ID was not retained"
assert_eq failed "$(state_value five_h_threshold_last_terminal_status)" "superseded alert was not closed as failed"
assert_eq 2 "$(request_count)" "new lower threshold did not reset both channel states"
assert_contains "$(<"${TEST_ROOT}/alert-data.log")" 'crossed 75% threshold' "original alert message changed"
assert_contains "$(<"${TEST_ROOT}/alert-data.log")" 'crossed 50% threshold' "lower threshold message was not distinct"

# Gist payloads are streamed from the public files, including histories larger
# than typical ARG_MAX, and never from an older in-memory snapshot.
reset_fake_curl
GITHUB_PAT=test-token
GITHUB_GIST_ID=abcdef
export FAKE_CURL_STATUS=200 FAKE_CURL_EXIT=0
export FAKE_CURL_PAYLOAD_FILE="${TEST_ROOT}/gist-payload.json"
export FAKE_CURL_ARGUMENT_LOG="${TEST_ROOT}/gist-curl-arguments.log"
printf '{"scraped_at":"new-published-snapshot"}\n' > "$DATA_FILE"
printf '[%*s{"scraped_at":"old-history-snapshot"}]\n' 2200000 '' > "$HISTORY_FILE"
sync_gist >/dev/null
python3 -c 'import json, pathlib, sys
payload=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["files"]["data.json"]["content"] == pathlib.Path(sys.argv[2]).read_text()
assert payload["files"]["history.json"]["content"] == pathlib.Path(sys.argv[3]).read_text()
  ' "$FAKE_CURL_PAYLOAD_FILE" "$DATA_FILE" "$HISTORY_FILE" \
  || fail "Gist payload did not contain the exact published files"
assert_contains "$({ sed -n '/--max-filesize/{N;p;}' "$FAKE_CURL_ARGUMENT_LOG"; } 2>/dev/null)" \
  $'--max-filesize\n67108864' "Gist response limit can still reject a successful large PATCH"
assert_contains "$(<"$FAKE_CURL_ARGUMENT_LOG")" '/dev/null' "Gist response body was retained unnecessarily"

printf 'PASS: monitor network tests\n'
