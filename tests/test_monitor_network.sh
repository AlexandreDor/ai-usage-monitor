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

DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456
export FAKE_CURL_DISCORD_STATUS=500 FAKE_CURL_DISCORD_EXIT=0
export FAKE_CURL_TELEGRAM_STATUS=200 FAKE_CURL_TELEGRAM_EXIT=0
export FAKE_CURL_TELEGRAM_BODY='{"ok":true}'
send_alert test >/dev/null || fail "Telegram success did not remain independent of Discord failure"

ALERT_THRESHOLDS=75
export FAKE_CURL_TELEGRAM_STATUS=500
check_thresholds 70 100 later unknown '' '' 2000000000 >/dev/null 2>&1 \
  && fail "failed deliveries did not fail threshold check"
assert_eq 75 "$(awk -F= '$1 == "pending_5h_threshold" {print $2}' "$STATE_FILE")" "pending threshold not persisted"

export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_TELEGRAM_STATUS=200
check_thresholds 70 100 later unknown '' '' 2000000001 >/dev/null
assert_eq "" "$(awk -F= '$1 == "pending_5h_threshold" {print $2}' "$STATE_FILE")" "pending threshold not cleared after retry"

# Delivery is tracked independently: Discord is not replayed after succeeding.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-partial"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
export FAKE_CURL_TELEGRAM_STATUS_SEQUENCE=503,200 FAKE_CURL_TELEGRAM_EXIT=0
unset FAKE_CURL_TELEGRAM_STATUS FAKE_CURL_HEADERS
check_thresholds 70 100 later unknown '' '' 2000000100 >/dev/null 2>&1 \
  && fail "partial channel failure did not fail the cycle"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" "Discord state"
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.telegram.status)" "Telegram pending state"
check_thresholds 70 100 later unknown '' '' 2000000101 >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "Discord was replayed"
assert_eq 2 "$(<"${FAKE_CURL_COUNT_DIR}/telegram")" "Telegram was not retried"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.status)" "aggregate delivery state"

# Permanent client errors are attempted once and never replayed.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-permanent"
export FAKE_CURL_DISCORD_STATUS=400
unset FAKE_CURL_TELEGRAM_STATUS_SEQUENCE
TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
check_thresholds 70 100 later unknown '' '' 2000000200 >/dev/null 2>&1 \
  && fail "permanent failure did not fail its first cycle"
check_thresholds 70 100 later unknown '' '' 2000000201 >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "permanent error was retried"
assert_eq failed "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" "permanent channel state"

# A legacy pending threshold is migrated atomically and keeps a legacy cycle ID.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-migration"
unset FAKE_CURL_DISCORD_STATUS_SEQUENCE FAKE_CURL_DISCORD_HEADERS
export FAKE_CURL_DISCORD_STATUS=204
legacy_reset=$((2000000250 + 300))
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=80' 'prev_weekly_pct=100' \
  "five_h_armed_reset_at=${legacy_reset}" 'weekly_armed_reset_at=0' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=75' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 70 100 later unknown "$legacy_reset" '' 2000000250 >/dev/null
assert_eq 4 "$(json_field "$ALERT_DELIVERIES_FILE" legacy_migration.source_state_version)" "migration source version"
assert_contains "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.cycle_key)" 'legacy-v4|' "legacy cycle key"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.status)" "migrated delivery"

# A long Retry-After is persisted without blocking and suppresses early cycles.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-rate-limit"
export FAKE_CURL_DISCORD_STATUS_SEQUENCE=429,204
export FAKE_CURL_DISCORD_HEADERS='Retry-After: 120'
check_thresholds 70 100 later unknown '' '' 2000000300 >/dev/null 2>&1 \
  && fail "rate limit did not fail its attempt cycle"
assert_eq 2000000420 "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.next_attempt_at)" "Retry-After deadline"
check_thresholds 70 100 later unknown '' '' 2000000301 >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "future retry ran too early"
check_thresholds 70 100 later unknown '' '' 2000000420 >/dev/null
assert_eq 2 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "due retry did not run"

printf 'PASS: monitor network tests\n'
