#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_BIN"
ln -s "${ROOT_DIR}/tests/fixtures/fake-curl.sh" "${FAKE_BIN}/curl"
export PATH="${FAKE_BIN}:$PATH"
export FAKE_CURL_LOG="${TEST_ROOT}/curl.log"
response="${TEST_ROOT}/response"
SLEEP_LOG="${TEST_ROOT}/sleep.log"

# Retry tests must verify the selected delay without actually waiting.
sleep() {
  printf '%s\n' "$1" >> "$SLEEP_LOG"
}

state_value() {
  local wanted="$1"
  awk -F= -v wanted="$wanted" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$STATE_FILE"
}

reset_alert_case() {
  rm -f "$STATE_FILE" "$FAKE_CURL_LOG" "$SLEEP_LOG"
  monitor_defaults
  ALERT_DELIVERY_STATE_READY=0
  unset FAKE_CURL_STATUS FAKE_CURL_EXIT FAKE_CURL_BODY FAKE_CURL_RETRY_AFTER
  unset FAKE_CURL_DISCORD_STATUS FAKE_CURL_DISCORD_EXIT FAKE_CURL_DISCORD_BODY FAKE_CURL_DISCORD_RETRY_AFTER
  unset FAKE_CURL_TELEGRAM_STATUS FAKE_CURL_TELEGRAM_EXIT FAKE_CURL_TELEGRAM_BODY FAKE_CURL_TELEGRAM_RETRY_AFTER
  : > "$FAKE_CURL_LOG"
}

export FAKE_CURL_STATUS=204 FAKE_CURL_EXIT=0
http_request Test 204 'url = "https://example.invalid"' POST "$response"

for status in 400 404 500 503; do
  export FAKE_CURL_STATUS="$status" FAKE_CURL_EXIT=0
  http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null 2>&1 \
    && fail "HTTP $status accepted"
done
export FAKE_CURL_STATUS=000 FAKE_CURL_EXIT=28
http_request Test 204 'url = "https://example.invalid"' POST "$response" >/dev/null 2>&1 \
  && fail "curl timeout accepted"

# A partial delivery is not complete, and the delivered channel is not called
# again when the failed channel is retried.
reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456
export FAKE_CURL_DISCORD_STATUS=500 FAKE_CURL_DISCORD_EXIT=0
export FAKE_CURL_TELEGRAM_STATUS=200 FAKE_CURL_TELEGRAM_EXIT=0
export FAKE_CURL_TELEGRAM_BODY='{"ok":true}'
if send_alert test >/dev/null 2>&1; then
  fail "partial delivery was reported as complete"
fi
alert_id="$(make_alert_id 'message|test')"
assert_eq pending "$(state_value "alert_${alert_id}_status")" "partial alert status"
assert_eq failed "$(state_value "alert_${alert_id}_discord")" "failed Discord status"
assert_eq delivered "$(state_value "alert_${alert_id}_telegram")" "delivered Telegram status"
assert_eq 1 "$(grep -c '^discord$' "$FAKE_CURL_LOG")" "initial Discord request count"
assert_eq 1 "$(grep -c '^telegram$' "$FAKE_CURL_LOG")" "initial Telegram request count"

export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=200
: > "$FAKE_CURL_LOG"
send_alert test >/dev/null || fail "retry did not complete the partial alert"
assert_eq discord "$(<"$FAKE_CURL_LOG")" "already delivered Telegram was retried"
assert_eq delivered "$(state_value "alert_${alert_id}_status")" "completed alert status"
assert_eq delivered "$(state_value "alert_${alert_id}_discord")" "retried Discord status"
assert_eq delivered "$(state_value "alert_${alert_id}_telegram")" "preserved Telegram status"

# A failed threshold keeps one stable alert_id and retries each failed channel;
# one channel succeeding does not clear the pending threshold.
reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456
ALERT_THRESHOLDS=75
export FAKE_CURL_DISCORD_STATUS=500 FAKE_CURL_TELEGRAM_STATUS=500
check_thresholds 70 100 later unknown '' '' 2000000000 >/dev/null 2>&1 || true
threshold_id="$(state_value pending_5h_alert_id)"
[[ "$threshold_id" =~ ^a-[a-f0-9]{32}$ ]] || fail "threshold alert_id was not persisted"
assert_eq 75 "$(state_value pending_5h_threshold)" "pending threshold"
assert_eq failed "$(state_value "alert_${threshold_id}_discord")" "threshold Discord status"
assert_eq failed "$(state_value "alert_${threshold_id}_telegram")" "threshold Telegram status"

export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=200
: > "$FAKE_CURL_LOG"
check_thresholds 70 100 later unknown '' '' 2000000001 >/dev/null \
  || fail "threshold retry did not complete"
assert_eq "" "$(state_value pending_5h_threshold)" "pending threshold after retry"
assert_eq delivered "$(state_value "alert_${threshold_id}_status")" "threshold overall status"
assert_eq $'discord\ntelegram' "$(<"$FAKE_CURL_LOG")" "threshold retry channels"

# Permanent 4xx errors are journaled as failed and are never retried, even if
# the provider includes a Retry-After header.
reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/sensitive-token'
CURL_RETRIES=3
export FAKE_CURL_DISCORD_STATUS=400 FAKE_CURL_DISCORD_RETRY_AFTER=30
if send_alert permanent >/dev/null 2>&1; then
  fail "permanent 4xx was reported as complete"
fi
assert_eq 1 "$(wc -l < "$FAKE_CURL_LOG")" "permanent 4xx was retried"
[[ ! -e "$SLEEP_LOG" ]] || fail "permanent 4xx honored Retry-After"
permanent_id="$(make_alert_id 'message|permanent')"
assert_eq failed "$(state_value "alert_${permanent_id}_discord")" "permanent channel status"
assert_eq 0 "$(state_value "alert_${permanent_id}_discord_retryable")" "permanent retry marker"
send_alert permanent >/dev/null 2>&1 && fail "terminal alert unexpectedly became complete"
assert_eq 1 "$(wc -l < "$FAKE_CURL_LOG")" "terminal 4xx was retried on a later cycle"

# 429 and 5xx responses retry the bounded number of times and honor
# Retry-After. The sleep function above records the delay without waiting.
reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
CURL_RETRIES=2
CURL_RETRY_DELAY_SECONDS=0
export FAKE_CURL_DISCORD_STATUS=429 FAKE_CURL_DISCORD_RETRY_AFTER=5
send_alert rate-limited >/dev/null 2>&1 && fail "429 unexpectedly succeeded"
assert_eq 3 "$(wc -l < "$FAKE_CURL_LOG")" "429 retry count"
assert_eq $'5\n5' "$(<"$SLEEP_LOG")" "Retry-After delay"

reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
CURL_RETRIES=2
export FAKE_CURL_DISCORD_STATUS=503 FAKE_CURL_DISCORD_RETRY_AFTER=0
send_alert server-error >/dev/null 2>&1 && fail "5xx unexpectedly succeeded"
assert_eq 3 "$(wc -l < "$FAKE_CURL_LOG")" "5xx retry count"

reset_alert_case
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
CURL_RETRIES=2
export FAKE_CURL_DISCORD_STATUS=000 FAKE_CURL_DISCORD_EXIT=28
send_alert timeout >/dev/null 2>&1 && fail "timeout unexpectedly succeeded"
assert_eq 3 "$(wc -l < "$FAKE_CURL_LOG")" "timeout retry count"

# Failure diagnostics never echo credentials, webhook URLs, or chat IDs.
diagnostics="$(MONITOR_DEBUG=1 send_alert diagnostic 2>&1 || true)"
[[ "$diagnostics" != *'sensitive-token'* && "$diagnostics" != *'discord.com/api/webhooks'* ]] \
  || fail "diagnostics exposed a webhook URL or token"
[[ "$diagnostics" != *'123:token'* && "$diagnostics" != *'-456'* ]] \
  || fail "diagnostics exposed a Telegram credential or chat ID"

printf 'PASS: monitor network tests\n'
