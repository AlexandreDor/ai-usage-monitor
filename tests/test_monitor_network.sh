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

# A threshold detected before its reset deadline is known expires when that
# deadline is later armed and reached; it must not be delivered after refill.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-unarmed-reset"
export FAKE_CURL_DISCORD_STATUS=503
unset FAKE_CURL_DISCORD_STATUS_SEQUENCE FAKE_CURL_DISCORD_HEADERS
unarmed_reset=2000000500
check_thresholds 70 100 unknown unknown '' '' 2000000400 >/dev/null 2>&1 \
  && fail "temporary unarmed threshold failure did not fail the cycle"
check_thresholds 70 100 later unknown "$unarmed_reset" '' 2000000401 >/dev/null 2>&1 \
  && fail "temporary armed threshold failure did not fail the cycle"
export FAKE_CURL_DISCORD_STATUS=204
check_thresholds 100 100 unknown unknown '' '' "$((unarmed_reset + 1))" >/dev/null
assert_eq expired_after_reset \
  "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.terminal_reason)" \
  "unarmed threshold was not expired by reset"
assert_eq 2 "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.attempt_count)" \
  "expired unarmed threshold was replayed"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.1.status)" \
  "reset alert was not delivered"
assert_eq "$unarmed_reset" \
  "$(awk -F= '$1 == "last_notified_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "delivered reset was not reconciled into detector state"
assert_eq 0 "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "delivered reset left its old cycle armed"
assert_eq 3 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" \
  "stale threshold was sent after reset"

# If detector state rolls back after a reset has already reached a terminal
# journal state, the old reset is reconciled instead of pinning future threshold
# occurrences to its expired cycle.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-reset-recovery"
export FAKE_CURL_DISCORD_STATUS=204
recovered_reset=2000000600
next_reset=2000600000
check_thresholds 100 80 unknown later '' "$recovered_reset" 2000000500 >/dev/null
check_thresholds 100 100 unknown later '' "$next_reset" "$recovered_reset" >/dev/null
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.status)" \
  "reset recovery fixture was not delivered"
python3 - "$STATE_FILE" "$recovered_reset" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
reset_at = sys.argv[2]
lines = []
for line in path.read_text(encoding="utf-8").splitlines():
    key, _, value = line.partition("=")
    if key == "weekly_armed_reset_at":
        value = reset_at
    elif key == "weekly_armed_limit_id":
        value = "default"
    elif key == "last_notified_weekly_reset_at":
        value = "0"
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
check_thresholds 100 70 unknown later '' "$next_reset" "$((recovered_reset + 1))" >/dev/null
assert_eq "$next_reset" \
  "$(awk -F= '$1 == "weekly_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "terminal reset did not release the stale cycle"
assert_eq 2 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]))' "$ALERT_DELIVERIES_FILE")" \
  "post-reset threshold was not journaled"
assert_eq threshold "$(json_field "$ALERT_DELIVERIES_FILE" alerts.1.kind)" \
  "post-reset occurrence kind"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.1.status)" \
  "post-reset threshold was not delivered"
assert_eq 2 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" \
  "terminal reset was replayed instead of sending the new threshold"

printf 'PASS: monitor network tests\n'
