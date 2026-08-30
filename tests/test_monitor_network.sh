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

fake_curl_count() {
  [[ -f "$1" ]] && cat "$1" || printf '0\n'
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

# An observed full 5-hour cycle is local evidence only: configured network
# channels must not receive or retain a reset occurrence.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-silent"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
old_five_deadline=$((2000000100 + 300))
new_five_deadline=$((old_five_deadline + 900))
check_thresholds 100 100 later unknown "$old_five_deadline" '' 2000000100 group-a >/dev/null
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.unlink()
PYEOF
check_thresholds 100 100 later unknown "$new_five_deadline" '' 2000001000 group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "observed 5h reset emitted an HTTP request"
assert_eq 0 "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["alerts"]))' "$ALERT_DELIVERIES_FILE")" \
  "observed 5h reset was queued in the network journal"
ALERT_THRESHOLDS=75
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456

# An observed refill also invalidates a pending threshold attached to the
# already-armed cycle (not only an unarmed threshold).  It must remain local:
# the stale threshold is terminalized/acknowledged, no HTTP is attempted, and
# no network reset occurrence is created.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-armed-silent"
ALERTS_ENABLED=0
ALERT_THRESHOLDS=75
armed_observation_at=2000001100
armed_old_deadline=$((armed_observation_at + 3600))
armed_new_deadline=$((armed_old_deadline + 900))
check_thresholds 100 100 later unknown "$armed_old_deadline" '' "$armed_observation_at" group-a >/dev/null
armed_limit_id="$(canonicalize_alert_limit_id group-a)"
python3 - "$STATE_FILE" "$armed_old_deadline" "$armed_limit_id" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["five_h_armed_reset_at"] = sys.argv[2]
values["five_h_armed_limit_id"] = sys.argv[3]
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
ALERTS_ENABLED=1
register_network_alert threshold 5h 75 "limit:${armed_limit_id}|reset:${armed_old_deadline}" \
  "stale armed threshold" \
  "{\"limit_id\":\"${armed_limit_id}\",\"remaining_pct\":70,\"reset_epoch\":${armed_old_deadline},\"covered_thresholds\":[75]}" \
  "$((armed_observation_at + 1))" "$armed_old_deadline" false >/dev/null
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
check_thresholds 100 100 later unknown "$armed_new_deadline" '' "$((armed_observation_at + 900))" group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "armed observed 5h refill emitted an HTTP request"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 1, items
threshold = items[0]
assert threshold["kind"] == "threshold", threshold
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["channels"]["discord"]["error_class"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
assert not any(item["kind"] == "reset" for item in items), items
PYEOF
ALERTS_ENABLED=1

# Expiry of stale thresholds is fail-closed.  If the atomic invalidation path
# fails, the observed proof and arm remain durable so the next identical sample
# retries before any delivery; the successful retry remains local-only.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-expire-retry"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
retry_observation_at=2000002100
retry_old_deadline=$((retry_observation_at + 3600))
retry_new_deadline=$((retry_old_deadline + 900))
check_thresholds 100 100 later unknown "$retry_old_deadline" '' "$retry_observation_at" group-a >/dev/null
retry_limit_id="$(canonicalize_alert_limit_id group-a)"
python3 - "$STATE_FILE" "$retry_old_deadline" "$retry_limit_id" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["five_h_armed_reset_at"] = sys.argv[2]
values["five_h_armed_limit_id"] = sys.argv[3]
values["pending_5h_threshold"] = "50"
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
register_network_alert threshold 5h 50 "limit:${retry_limit_id}|reset:${retry_old_deadline}" \
  "stale retry threshold" \
  "{\"limit_id\":\"${retry_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":${retry_old_deadline},\"covered_thresholds\":[50]}" \
  "$((retry_observation_at + 1))" "$retry_old_deadline" false >/dev/null
# shellcheck disable=SC2317,SC2329
invalidate_pending_thresholds() { return 1; }
if check_thresholds 100 100 later unknown "$retry_new_deadline" '' "$((retry_observation_at + 900))" group-a >/dev/null 2>&1; then
  fail "observed reset invalidation failure was accepted"
fi
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "failed invalidation attempted network delivery"
assert_eq "$retry_old_deadline" "$(awk -F= '$1 == "observed_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "failed invalidation advanced the observed baseline"
assert_eq "$retry_old_deadline" "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "failed invalidation advanced the reset arm"
invalidate_pending_thresholds() {
  local window="$1" cycle_key="$2" limit_id="$3" now="$4"
  python3 "$ALERTS_PY" expire-thresholds "$ALERT_DELIVERIES_FILE" \
    "$window" "$cycle_key" "$limit_id" --now "$now"
}
check_thresholds 100 100 later unknown "$retry_new_deadline" '' "$((retry_observation_at + 901))" group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "successful observed reset emitted an HTTP request"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 1, items
assert items[0]["kind"] == "threshold", items
assert items[0]["terminal_reason"] == "expired_after_reset", items
assert items[0]["channels"]["discord"]["error_class"] == "expired_after_reset", items
assert not any(item["kind"] == "reset" for item in items), items
PYEOF

# Reconstructing a missing journal must keep legacy occurrences bound to the
# owner persisted in state.  A complete sample from group-b initializes a new
# baseline and must not rewrite A's threshold/reset to B.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-migration-group-switch"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
migration_switch_now=2000003000
migration_a_reset=$((migration_switch_now - 300))
migration_b_reset=$((migration_switch_now - 100))
migration_a_id="$(canonicalize_alert_limit_id group-a)"
migration_b_id="$(canonicalize_alert_limit_id group-b)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=80' 'prev_weekly_pct=100' \
  'observed_5h_pct=80' "observed_5h_reset_at=${migration_a_reset}" \
  "observed_5h_limit_id=${migration_a_id}" \
  'observed_weekly_pct=80' "observed_weekly_reset_at=${migration_a_reset}" \
  "observed_weekly_limit_id=${migration_a_id}" \
  "five_h_armed_reset_at=${migration_a_reset}" \
  "five_h_armed_limit_id=${migration_a_id}" \
  "weekly_armed_reset_at=${migration_a_reset}" "weekly_armed_limit_id=${migration_a_id}" \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=50' 'pending_weekly_threshold=50' > "$STATE_FILE"
check_thresholds 100 100 later later "$migration_b_reset" "$migration_b_reset" "$migration_switch_now" group-b >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "missing-journal group switch delivered an owner-a reset"
python3 - "$ALERT_DELIVERIES_FILE" "$migration_a_id" "$migration_b_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert not items, items
PYEOF
ALERT_THRESHOLDS=75

# A legacy v4 detector state can have no owner fields even though the existing
# journal still carries pending events for A.  Both a complete and a partial B
# sample must interrupt those events before due delivery; returning to A must
# not replay them.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-ownerless-complete"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
ownerless_now=2000003500
ownerless_a_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'five_h_armed_reset_at=0' 'weekly_armed_reset_at=0' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$ownerless_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 4
register_network_alert threshold 5h 50 "limit:${ownerless_a_id}|unarmed" \
  "ownerless stale 5h threshold" \
  "{\"limit_id\":\"${ownerless_a_id}\",\"remaining_pct\":40,\"reset_epoch\":0,\"covered_thresholds\":[50]}" \
  "$ownerless_now" 0 false >/dev/null
register_network_alert reset weekly reset "limit:${ownerless_a_id}|reset:$((ownerless_now - 100))" \
  "ownerless stale weekly reset" \
  "{\"limit_id\":\"${ownerless_a_id}\",\"reset_epoch\":$((ownerless_now - 100))}" \
  "$ownerless_now" "$((ownerless_now + 7 * 24 * 60 * 60))" false >/dev/null
check_thresholds 100 100 later later "$((ownerless_now - 100))" "$((ownerless_now - 100))" \
  "$ownerless_now" group-b >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "ownerless complete B sample delivered A's pending event"
python3 - "$ALERT_DELIVERIES_FILE" "$ownerless_a_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
owner_items = [item for item in items if item["event_data"]["limit_id"] == sys.argv[2]]
assert len(owner_items) == 2, items
assert all(item["terminal_reason"] == "owner_interrupted" for item in owner_items), owner_items
assert all(item["detector_acknowledged_at"] is not None for item in owner_items), owner_items
PYEOF
check_thresholds 100 100 later later "$((ownerless_now + 3600))" "$((ownerless_now + 3600))" \
  "$((ownerless_now + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "ownerless complete B events replayed after returning to A"

rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-ownerless-partial"
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'five_h_armed_reset_at=0' 'weekly_armed_reset_at=0' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$ownerless_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 4
register_network_alert reset 5h reset "limit:${ownerless_a_id}|reset:$((ownerless_now + 3600))" \
  "ownerless stale 5h reset" \
  "{\"limit_id\":\"${ownerless_a_id}\",\"reset_epoch\":$((ownerless_now + 3600))}" \
  "$ownerless_now" "$((ownerless_now + 8 * 60 * 60))" false >/dev/null
register_network_alert threshold weekly 50 "limit:${ownerless_a_id}|unarmed" \
  "ownerless stale weekly threshold" \
  "{\"limit_id\":\"${ownerless_a_id}\",\"remaining_pct\":40,\"reset_epoch\":0,\"covered_thresholds\":[50]}" \
  "$ownerless_now" 0 false >/dev/null
check_thresholds 80 100 unknown unknown '' '' "$((ownerless_now + 1))" group-b >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "ownerless partial B sample delivered A's pending event"
python3 - "$ALERT_DELIVERIES_FILE" "$ownerless_a_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
owner_items = [item for item in items if item["event_data"]["limit_id"] == sys.argv[2]]
assert len(owner_items) == 2, items
assert all(item["terminal_reason"] == "owner_interrupted" for item in owner_items), owner_items
assert all(item["detector_acknowledged_at"] is not None for item in owner_items), owner_items
PYEOF
check_thresholds 100 100 later later "$((ownerless_now + 7200))" "$((ownerless_now + 7200))" \
  "$((ownerless_now + 2))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "ownerless partial B events replayed after returning to A"

# Live continuity is also broken by a partial row from another owner.  When A
# returns with a complete row, both windows must establish fresh baselines
# rather than replaying an observed reset (5h local or weekly network).
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-live-partial-return"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
live_now=2000004000
live_old_reset=$((live_now + 3600))
live_new_reset=$((live_old_reset + 900))
check_thresholds 100 100 later later "$live_old_reset" "$live_old_reset" "$live_now" group-a >/dev/null
check_thresholds 80 80 unknown unknown '' '' "$((live_now + 1))" group-b >/dev/null
check_thresholds 100 100 later later "$live_new_reset" "$live_new_reset" "$((live_now + 2))" group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "live partial owner switch emitted a reset request"
python3 - "$ALERT_DELIVERIES_FILE" "$STATE_FILE" <<'PYEOF'
import json
import pathlib
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert not any(item["kind"] == "reset" for item in items), items
state = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if "=" in line)
assert state["last_notified_5h_reset_at"] == "0", state
assert state["last_notified_weekly_reset_at"] == "0", state
PYEOF

# A terminal delivery from group-a must not rewrite group-b's fresh baseline.
# The next B threshold must still be detected from B's own complete sample.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-reconcile-group-switch"
export FAKE_CURL_DISCORD_STATUS=503 FAKE_CURL_DISCORD_EXIT=0
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
p3_now=2000007000
p3_a_reset=$((p3_now + 3600))
p3_b_reset=$((p3_now + 7200))
p3_a_id="$(canonicalize_alert_limit_id group-a)"
p3_b_id="$(canonicalize_alert_limit_id group-b)"
check_thresholds 100 100 later unknown "$p3_a_reset" '' "$p3_now" group-a >/dev/null
check_thresholds 40 100 later unknown "$p3_a_reset" '' "$((p3_now + 1))" group-a >/dev/null 2>&1 || true
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "group-a threshold was not left pending after delivery failure"
export FAKE_CURL_DISCORD_STATUS=204
check_thresholds 80 100 later unknown "$p3_b_reset" '' "$((p3_now + 2))" group-b >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" \
  "complete owner switch replayed the interrupted A alert"
assert_eq 80 "$(awk -F= '$1 == "prev_5h_pct" {print $2}' "$STATE_FILE")" \
  "terminal group-a delivery polluted group-b baseline"
assert_eq '' "$(awk -F= '$1 == "pending_5h_threshold" {print $2}' "$STATE_FILE")" \
  "group switch left an orphaned pending marker"
check_thresholds 40 100 later unknown "$p3_b_reset" '' "$((p3_now + 3))" group-b >/dev/null
python3 - "$ALERT_DELIVERIES_FILE" "$p3_a_id" "$p3_b_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
by_owner = {item["event_data"]["limit_id"]: item for item in items}
assert set(by_owner) == {sys.argv[2], sys.argv[3]}, items
assert by_owner[sys.argv[2]]["status"] == "failed", items
assert by_owner[sys.argv[2]]["terminal_reason"] == "owner_interrupted", items
assert by_owner[sys.argv[2]]["detector_acknowledged_at"] is not None, items
assert by_owner[sys.argv[3]]["status"] == "delivered", items
assert by_owner[sys.argv[3]]["selector"] == "50", items
PYEOF

# A partial observation from another owner breaks live continuity durably.  All
# pending A threshold/reset occurrences in both windows are terminalized before
# due delivery; they must not survive the interruption or be replayed on return.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-reconcile-partial-return"
export FAKE_CURL_DISCORD_STATUS=503 FAKE_CURL_DISCORD_EXIT=0
ALERT_THRESHOLDS=50
p3_return_now=2000010000
p3_return_reset=$((p3_return_now + 3600))
p3_return_weekly_reset=$((p3_return_now + 4 * 24 * 60 * 60))
p3_return_id="$(canonicalize_alert_limit_id group-a)"
check_thresholds 100 100 later later "$p3_return_reset" "$p3_return_weekly_reset" "$p3_return_now" group-a >/dev/null
check_thresholds 40 100 later later "$p3_return_reset" "$p3_return_weekly_reset" "$((p3_return_now + 1))" group-a >/dev/null 2>&1 || true
register_network_alert reset 5h reset "limit:${p3_return_id}|reset:${p3_return_reset}" \
  "stale 5h reset" "{\"limit_id\":\"${p3_return_id}\",\"reset_epoch\":${p3_return_reset}}" \
  "$((p3_return_now + 1))" "$((p3_return_reset + 5 * 60 * 60))" false >/dev/null
register_network_alert threshold weekly 50 "limit:${p3_return_id}|unarmed" \
  "stale weekly threshold" \
  "{\"limit_id\":\"${p3_return_id}\",\"remaining_pct\":40,\"reset_epoch\":0,\"covered_thresholds\":[50]}" \
  "$((p3_return_now + 1))" 0 false >/dev/null
register_network_alert reset weekly reset "limit:${p3_return_id}|reset:${p3_return_weekly_reset}" \
  "stale weekly reset" "{\"limit_id\":\"${p3_return_id}\",\"reset_epoch\":${p3_return_weekly_reset}}" \
  "$((p3_return_now + 1))" "$((p3_return_weekly_reset + 7 * 24 * 60 * 60))" false >/dev/null
export FAKE_CURL_DISCORD_STATUS=204
check_thresholds 80 100 unknown unknown '' '' "$((p3_return_now + 2))" group-b >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" \
  "interrupted owner pending alerts were delivered during a partial sample"
python3 - "$ALERT_DELIVERIES_FILE" "$p3_return_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
owner_items = [item for item in items if item["event_data"]["limit_id"] == sys.argv[2]]
assert len(owner_items) == 4, items
assert all(item["status"] == "failed" for item in owner_items), owner_items
assert all(item["terminal_reason"] == "owner_interrupted" for item in owner_items), owner_items
assert all(item["detector_acknowledged_at"] is not None for item in owner_items), owner_items
PYEOF
assert_eq '' "$(awk -F= '$1 == "pending_5h_threshold" {print $2}' "$STATE_FILE")" \
  "partial group-b sample retained the interrupted A marker"
check_thresholds 40 100 later unknown "$p3_return_reset" '' "$((p3_return_now + 3))" group-a >/dev/null
assert_eq 1 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" \
  "interrupted owner pending alerts were replayed after returning to A"
assert_eq '' "$(awk -F= '$1 == "pending_5h_threshold" {print $2}' "$STATE_FILE")" \
  "return to group-a recreated an interrupted pending marker"
ALERT_THRESHOLDS=75
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID=-456

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
  'five_h_armed_limit_id=default' \
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
  "five_h_armed_limit_id=${legacy_digest_id}" \
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
  'five_h_armed_limit_id=default' \
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
