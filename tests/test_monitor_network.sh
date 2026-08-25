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
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
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

# A schema-1 journal and v4 state migrate independently, including a raw ID
# that already has the opaque-looking digest shape.  Delivery remains
# terminal and a second cycle does not replay it.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-journal-migration"
export FAKE_CURL_DISCORD_STATUS=204
legacy_digest_id="limit-$(printf 'a%.0s' {1..64})"
current_digest_id="$(python3 - "$legacy_digest_id" <<'PYEOF'
import hashlib
import sys
print("limit-" + hashlib.sha256(sys.argv[1].encode()).hexdigest())
PYEOF
)"
legacy_journal_now=2000000260
legacy_journal_reset=$((legacy_journal_now + 300))
python3 - "$ALERT_DELIVERIES_FILE" "$legacy_digest_id" "$legacy_journal_now" "$legacy_journal_reset" <<'PYEOF'
import copy
import importlib.util
import json
import pathlib
import sys

path, raw_id, now, reset = sys.argv[1:]
now, reset = map(int, (now, reset))
spec = importlib.util.spec_from_file_location("alerts_fixture", pathlib.Path("local/alerts.py"))
alerts = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(alerts)
document = alerts.empty_journal(4, now)
request = {
    "kind": "threshold", "window": "5h", "selector": "75",
    "cycle_key": f"legacy-v4|limit:{raw_id}|reset:{reset}",
    "id_namespace": "legacy-v4", "message": "legacy migration",
    "event_data": {"limit_id": raw_id, "remaining_pct": 70,
                   "reset_epoch": reset, "covered_thresholds": [75]},
    "created_at": now, "expires_at": reset, "channels": ["discord"],
    "replace_pending_thresholds": True, "expire_threshold_cycle": None,
}
item = alerts.register(document, request)
legacy = copy.deepcopy(document)
legacy["schema_version"] = 1
legacy.pop("limit_id_contract_version")
item = legacy["alerts"][0]
item["event_data"]["limit_id"] = raw_id
item["cycle_key"] = f"legacy-v4|limit:{raw_id}|reset:{reset}"
item["alert_id"] = alerts.alert_id(
    item["kind"], item["window"], item["selector"], item["cycle_key"], "legacy-v4"
)
pathlib.Path(path).write_text(json.dumps(legacy), encoding="utf-8")
PYEOF
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=80' 'prev_weekly_pct=100' \
  "observed_weekly_limit_id=${legacy_digest_id}" \
  "weekly_armed_limit_id=${legacy_digest_id}" \
  "five_h_armed_reset_at=${legacy_journal_reset}" 'weekly_armed_reset_at=0' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=75' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 70 100 later unknown "$legacy_journal_reset" '' "$legacy_journal_now" "$current_digest_id" >/dev/null
assert_eq 2 "$(json_field "$ALERT_DELIVERIES_FILE" schema_version)" "alert journal schema migration"
assert_eq 1 "$(json_field "$ALERT_DELIVERIES_FILE" limit_id_contract_version)" "alert journal contract marker"
assert_eq "$current_digest_id" "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.event_data.limit_id)" "digest-shaped legacy ID migration"
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.status)" "legacy pending delivery"
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "migrated delivery attempt"
check_thresholds 70 100 later unknown "$legacy_journal_reset" '' "$((legacy_journal_now + 1))" "$current_digest_id" >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "migrated delivery replay"
if grep -Fq -- "$legacy_digest_id" "$STATE_FILE" "$ALERT_DELIVERIES_FILE"; then
  fail "legacy raw ID survived alert migration"
fi

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
        value = "limit-" + __import__("hashlib").sha256(b"default").hexdigest()
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

# ALERTS_ENABLED=0 suppresses new network and anomaly deliveries while
# retaining local detector evidence and advancing the threshold baseline.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-disabled"
export FAKE_CURL_STATUS=204 FAKE_CURL_EXIT=0
ALERTS_ENABLED=0
ALERT_THRESHOLDS=75
check_thresholds 70 100 later unknown '' '' 2000000700 >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "disabled alert emitted an HTTP request"
assert_eq 70 "$(awk -F= '$1 == "prev_5h_pct" {print $2}' "$STATE_FILE")" \
  "disabled threshold did not advance its baseline"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["alerts"]))' "$ALERT_DELIVERIES_FILE")" \
  "disabled threshold was queued"

rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE"
ALERT_THRESHOLDS=0
observe_quota_anomalies '{"scraped_at_epoch":2000000800,"five_h_pct":40,"weekly_pct":50,"five_h_reset_at":2000010000,"weekly_reset_at":2000010000,"limit_id":"disabled-group"}'
observe_quota_anomalies '{"scraped_at_epoch":2000000801,"five_h_pct":60,"weekly_pct":50,"five_h_reset_at":2000010000,"weekly_reset_at":2000010000,"limit_id":"disabled-group"}'
check_thresholds 60 50 later later 2000010000 2000010000 2000000801 disabled-group >/dev/null
assert_eq 2000000801 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
print(connection.execute("SELECT journaled_at FROM quota_anomalies").fetchone()[0])
PYEOF
)" "disabled anomaly was not acknowledged locally"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["alerts"]))' "$ALERT_DELIVERIES_FILE")" \
  "disabled anomaly was queued"

# A delivery that was already pending before the pause remains pending and
# resumes after re-enabling without being treated as an unconfigured channel.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-disabled-pending"
export FAKE_CURL_STATUS=503 FAKE_CURL_DISCORD_STATUS=503 FAKE_CURL_DISCORD_EXIT=0
unset FAKE_CURL_DISCORD_STATUS_SEQUENCE
ALERTS_ENABLED=1
ALERT_THRESHOLDS=75
check_thresholds 70 100 later unknown '' '' 2000000900 >/dev/null 2>&1 || true
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "initial pending delivery was not recorded"
pending_requests="$(wc -l < "$FAKE_CURL_LOG")"
ALERTS_ENABLED=0
check_thresholds 60 100 later unknown '' '' 2000000901 >/dev/null
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "disabled cycle changed a pending delivery"
assert_eq "$pending_requests" "$(wc -l < "$FAKE_CURL_LOG")" \
  "disabled cycle transmitted a pending delivery"
ALERTS_ENABLED=1
export FAKE_CURL_STATUS=204
export FAKE_CURL_DISCORD_STATUS=204
check_thresholds 60 100 later unknown '' '' 2000000902 >/dev/null
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "pending delivery did not resume after re-enabling"

# A pending delivery whose expiry passes during the pause gets one delivery
# attempt on the first resumed cycle before ordinary expiry is restored.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-disabled-expiry"
export FAKE_CURL_DISCORD_STATUS=503 FAKE_CURL_DISCORD_EXIT=0
pause_reset=2000001100
ALERTS_ENABLED=1
ALERT_THRESHOLDS=75
check_thresholds 70 100 later unknown "$pause_reset" '' 2000001000 >/dev/null 2>&1 || true
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "expiring delivery was not queued"
ALERTS_ENABLED=0
check_thresholds 70 100 later unknown "$pause_reset" '' "$((pause_reset + 1))" >/dev/null
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "disabled expiry discarded the pending delivery"
ALERTS_ENABLED=1
export FAKE_CURL_DISCORD_STATUS=204
check_thresholds 100 100 unknown unknown '' '' "$((pause_reset + 2))" >/dev/null
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "expired pending delivery was not attempted after re-enabling"
assert_eq 2 "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.attempt_count)" \
  "resumed delivery did not make its second attempt"
assert_eq 0 "$(awk -F= '$1 == "alerts_disabled_since" {print $2}' "$STATE_FILE")" \
  "disabled interval marker was not cleared after resuming"

# Legacy detector state is migrated into the durable journal even while
# alerting is disabled; it predates the pause and must remain deliverable.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-disabled-migration"
export FAKE_CURL_DISCORD_STATUS=204
migration_reset=2000002200
ALERTS_ENABLED=0
ALERT_THRESHOLDS=75
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=80' 'prev_weekly_pct=100' \
  "five_h_armed_reset_at=${migration_reset}" 'weekly_armed_reset_at=0' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=75' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 70 100 later unknown "$migration_reset" '' 2000002100 >/dev/null
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "legacy pending alert was cleared instead of migrated while disabled"
assert_eq threshold "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.kind)" \
  "legacy migration did not preserve the pending threshold"

printf 'PASS: monitor network tests\n'
