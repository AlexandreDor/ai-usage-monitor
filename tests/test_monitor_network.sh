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
assert_eq 0 "$(python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
print(sum(item["kind"] == "reset" and item["status"] == "pending" for item in items))
PYEOF
)" "observed 5h reset was queued in the network journal"
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
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
tombstone = next(item for item in items if item["kind"] == "reset")
assert threshold["kind"] == "threshold", threshold
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["channels"]["discord"]["error_class"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
assert tombstone["status"] == "failed", tombstone
assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["detector_acknowledged_at"] is not None, tombstone
PYEOF
ALERTS_ENABLED=1

# A partially restored detector can retain the observed pre-reset baseline
# while losing its explicit arm.  The observed refill must expire that OLD
# cycle, not the NEW deadline from the sample, before due delivery runs.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-restored"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
restored_now=2000002050
restored_old_deadline=$((restored_now + 3600))
restored_new_deadline=$((restored_old_deadline + 900))
restored_limit_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${restored_old_deadline}" \
  "observed_5h_limit_id=${restored_limit_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=50' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$restored_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold 5h 50 \
  "limit:${restored_limit_id}|reset:${restored_old_deadline}" \
  "restored stale threshold" \
  "{\"limit_id\":\"${restored_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":${restored_old_deadline},\"covered_thresholds\":[50]}" \
  "$((restored_now + 1))" "$((restored_old_deadline + 5 * 60 * 60))" false >/dev/null
check_thresholds 100 100 later unknown "$restored_new_deadline" '' \
  "$((restored_now + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "restored observed 5h refill delivered the stale threshold"
python3 - "$ALERT_DELIVERIES_FILE" "$restored_limit_id" "$restored_old_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = items[0]
assert threshold["kind"] == "threshold", threshold
assert threshold["event_data"]["limit_id"] == sys.argv[2], threshold
assert threshold["event_data"]["reset_epoch"] == int(sys.argv[3]), threshold
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["channels"]["discord"]["error_class"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
tombstone = next(item for item in items if item["kind"] == "reset")
assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["status"] == "failed", tombstone
PYEOF
check_thresholds 100 100 later unknown "$restored_new_deadline" '' \
  "$((restored_now + 2))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "restored stale threshold replayed on the next poll"

# A due, explicitly same-owner arm owns a simultaneous 100% -> 100% deadline
# advance.  With no journal on disk, initialization must reconstruct the
# scheduled reset rather than skipping it as a local observed reset.  The
# stale threshold is still expired before that reset is delivered.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-due-observed-missing-journal"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
due_missing_hook="${TEST_ROOT}/due-observed-missing-hook.sh"
due_missing_hook_log="${TEST_ROOT}/due-observed-missing-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$DUE_MISSING_HOOK_LOG"' \
  > "$due_missing_hook"
chmod 700 "$due_missing_hook"
export DUE_MISSING_HOOK_LOG="$due_missing_hook_log"
due_missing_now=2000015000
due_missing_old=$((due_missing_now - 60))
due_missing_new=$((due_missing_old + 900))
due_missing_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${due_missing_old}" \
  "observed_5h_limit_id=${due_missing_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${due_missing_old}" "five_h_armed_limit_id=${due_missing_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=50' 'pending_weekly_threshold=' > "$STATE_FILE"
export ALERT_SCRIPT_1="$due_missing_hook" ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
check_thresholds 100 100 later unknown "$due_missing_new" '' \
  "$due_missing_now" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "due observed reset was suppressed after missing-journal reconstruction"
assert_eq 1 "$(wc -l < "$due_missing_hook_log")" \
  "due scheduled reset hook did not execute exactly once"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
reset = next(item for item in items if item["kind"] == "reset")
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
assert reset["status"] == "delivered", reset
assert reset["terminal_reason"] == "delivered", reset
assert reset["event_data"]["limit_id"].startswith("limit-"), reset
PYEOF

# The same ownership rule applies when both pending rows already exist: do not
# create a local tombstone or duplicate the scheduled reset, but atomically
# expire the threshold before the existing reset is delivered.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-due-observed-existing-journal"
due_existing_now=2000016000
due_existing_old=$((due_existing_now - 60))
due_existing_new=$((due_existing_old + 900))
due_existing_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${due_existing_old}" \
  "observed_5h_limit_id=${due_existing_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${due_existing_old}" "five_h_armed_limit_id=${due_existing_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$due_existing_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold 5h 50 \
  "limit:${due_existing_id}|reset:${due_existing_old}" \
  "existing stale threshold" \
  "{\"limit_id\":\"${due_existing_id}\",\"remaining_pct\":40,\"reset_epoch\":${due_existing_old},\"covered_thresholds\":[50]}" \
  "$((due_existing_now - 1))" "$((due_existing_old + 5 * 60 * 60))" false >/dev/null
register_network_alert reset 5h reset \
  "limit:${due_existing_id}|reset:${due_existing_old}" \
  "existing scheduled reset" \
  "{\"limit_id\":\"${due_existing_id}\",\"reset_epoch\":${due_existing_old}}" \
  "$((due_existing_now - 1))" "$((due_existing_old + 5 * 60 * 60))" false >/dev/null
due_existing_hook="${TEST_ROOT}/due-observed-existing-hook.sh"
due_existing_hook_log="${TEST_ROOT}/due-observed-existing-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$DUE_EXISTING_HOOK_LOG"' \
  > "$due_existing_hook"
chmod 700 "$due_existing_hook"
export DUE_EXISTING_HOOK_LOG="$due_existing_hook_log"
export ALERT_SCRIPT_1="$due_existing_hook" ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
check_thresholds 100 100 later unknown "$due_existing_new" '' \
  "$due_existing_now" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "existing due scheduled reset was not delivered exactly once"
assert_eq 1 "$(wc -l < "$due_existing_hook_log")" \
  "existing due scheduled reset hook did not execute exactly once"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
reset = next(item for item in items if item["kind"] == "reset")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
assert reset["status"] == "delivered", reset
assert reset["terminal_reason"] == "delivered", reset
PYEOF

# Expiration-only work is fail-closed and retryable for this scheduled path.
# A failed transaction must leave both pending rows and the old detector arm
# untouched; the retry then delivers only the legitimate scheduled reset.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-due-observed-expiry-retry"
retry_now=2000017000
retry_old=$((retry_now - 60))
retry_new=$((retry_old + 900))
retry_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${retry_old}" \
  "observed_5h_limit_id=${retry_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${retry_old}" "five_h_armed_limit_id=${retry_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$retry_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold 5h 50 \
  "limit:${retry_id}|reset:${retry_old}" "retry stale threshold" \
  "{\"limit_id\":\"${retry_id}\",\"remaining_pct\":40,\"reset_epoch\":${retry_old},\"covered_thresholds\":[50]}" \
  "$((retry_now - 1))" "$((retry_old + 5 * 60 * 60))" false >/dev/null
register_network_alert reset 5h reset \
  "limit:${retry_id}|reset:${retry_old}" "retry scheduled reset" \
  "{\"limit_id\":\"${retry_id}\",\"reset_epoch\":${retry_old}}" \
  "$((retry_now - 1))" "$((retry_old + 5 * 60 * 60))" false >/dev/null
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_owner_thresholds_and_suppress_reset | sed '1s/^expire_owner_thresholds_and_suppress_reset /expire_owner_thresholds_and_suppress_reset_due_original /')"
(
  expire_owner_thresholds_and_suppress_reset() { return 1; }
  check_thresholds 100 100 later unknown "$retry_new" '' "$retry_now" group-a
) >/dev/null 2>&1 || true
eval "$(declare -f expire_owner_thresholds_and_suppress_reset_due_original | sed '1s/^expire_owner_thresholds_and_suppress_reset_due_original /expire_owner_thresholds_and_suppress_reset /')"
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "failed due-threshold expiry emitted a reset request"
assert_eq "$retry_old" "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "failed due-threshold expiry advanced the detector arm"
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "failed due-threshold expiry changed the journal"
check_thresholds 80 100 unknown unknown '' '' "$((retry_now + 1))" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "retry after due-threshold expiry did not deliver the scheduled reset"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
threshold = next(item for item in items if item["kind"] == "threshold")
reset = next(item for item in items if item["kind"] == "reset")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert reset["terminal_reason"] == "delivered", reset
PYEOF

# Weekly scheduled resets use the same expiry-only guard.  A failed guard must
# be retryable on a changed/partial sample, without delivering the stale
# threshold first or creating a local tombstone.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-due-weekly-expiry-retry"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
weekly_retry_now=2000018000
weekly_retry_old=$((weekly_retry_now - 60))
weekly_retry_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=' 'observed_5h_reset_at=0' 'observed_5h_limit_id=' \
  'observed_weekly_pct=100' "observed_weekly_reset_at=${weekly_retry_old}" \
  "observed_weekly_limit_id=${weekly_retry_id}" \
  'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
  "weekly_armed_reset_at=${weekly_retry_old}" "weekly_armed_limit_id=${weekly_retry_id}" \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$weekly_retry_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold weekly 50 \
  "limit:${weekly_retry_id}|reset:${weekly_retry_old}" \
  "weekly retry stale threshold" \
  "{\"limit_id\":\"${weekly_retry_id}\",\"remaining_pct\":40,\"reset_epoch\":${weekly_retry_old},\"covered_thresholds\":[50]}" \
  "$((weekly_retry_now - 1))" "$((weekly_retry_old + 7 * 24 * 60 * 60))" false >/dev/null
register_network_alert reset weekly reset \
  "limit:${weekly_retry_id}|reset:${weekly_retry_old}" \
  "weekly retry scheduled reset" \
  "{\"limit_id\":\"${weekly_retry_id}\",\"reset_epoch\":${weekly_retry_old}}" \
  "$((weekly_retry_now - 1))" "$((weekly_retry_old + 7 * 24 * 60 * 60))" false >/dev/null
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_owner_thresholds_and_suppress_reset | sed '1s/^expire_owner_thresholds_and_suppress_reset /expire_owner_thresholds_and_suppress_reset_weekly_original /')"
(
  expire_owner_thresholds_and_suppress_reset() { return 1; }
  check_thresholds 100 80 unknown unknown '' '' "$weekly_retry_now" group-a
) >/dev/null 2>&1 || true
eval "$(declare -f expire_owner_thresholds_and_suppress_reset_weekly_original | sed '1s/^expire_owner_thresholds_and_suppress_reset_weekly_original /expire_owner_thresholds_and_suppress_reset /')"
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "failed weekly due-threshold expiry emitted a reset request"
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "failed weekly due-threshold expiry changed the journal"
check_thresholds 100 80 unknown unknown '' '' "$((weekly_retry_now + 1))" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly due-threshold expiry retry did not deliver the scheduled reset"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
reset = next(item for item in items if item["kind"] == "reset")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert reset["terminal_reason"] == "delivered", reset
PYEOF

# If the process stops after reconciliation has persisted detector state but
# before the final state write, the observed reset must remain local-only on
# restart. The durable marker prevents a scheduled reset POST, while the
# local hook remains eligible exactly once on the retry.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-restart"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
restart_hook="${TEST_ROOT}/observed-restart-hook.sh"
restart_hook_log="${TEST_ROOT}/observed-restart-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$RESTART_HOOK_LOG"' > "$restart_hook"
chmod 700 "$restart_hook"
export RESTART_HOOK_LOG="$restart_hook_log"
restart_now=2000002500
restart_old_deadline=$((restart_now + 1800))
restart_new_deadline=$((restart_old_deadline + 900))
restart_limit_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${restart_old_deadline}" \
  "observed_5h_limit_id=${restart_limit_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=50' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$restart_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold 5h 50 \
  "limit:${restart_limit_id}|reset:${restart_old_deadline}" \
  "restart stale threshold" \
  "{\"limit_id\":\"${restart_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":${restart_old_deadline},\"covered_thresholds\":[50]}" \
  "$((restart_now + 1))" "$((restart_old_deadline + 5 * 60 * 60))" false >/dev/null
# Stop from the hook invocation itself: the write-ahead marker and pending
# context have already been persisted, while the hook has not run yet. This
# crash point is independent of unrelated persistence calls in the monitor.
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="$restart_hook"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    exit 99
  }
  check_thresholds 100 100 later unknown "$restart_new_deadline" '' \
    "$((restart_now + 1))" group-a >/dev/null
) >/dev/null 2>&1 || true
assert_eq "$((restart_now + 1))" "$(awk -F= '$1 == "last_notified_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "restart lost the durable observed-reset marker"
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "crashed observed reset emitted an HTTP request"
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="$restart_hook"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  check_thresholds 100 100 later unknown "$restart_new_deadline" '' \
    "$((restart_now + 2))" group-a >/dev/null
) >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "restarted observed reset emitted an HTTP request"
assert_eq 1 "$(wc -l < "$restart_hook_log")" \
  "restarted observed reset did not execute its local hook exactly once"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
tombstone = next(item for item in items if item["kind"] == "reset")
assert tombstone["status"] == "failed", tombstone
assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["detector_acknowledged_at"] is not None, tombstone
PYEOF

# The reset arm itself can survive on disk when a process stops immediately
# after the write-ahead suppression. Recovery after the old deadline must use
# that journal tombstone as local-only reset evidence and still run the hook.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-write-ahead"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
wal_hook="${TEST_ROOT}/observed-write-ahead-hook.sh"
wal_hook_log="${TEST_ROOT}/observed-write-ahead-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$WAL_HOOK_LOG"' > "$wal_hook"
chmod 700 "$wal_hook"
export WAL_HOOK_LOG="$wal_hook_log"
wal_now=2000007000
wal_old_deadline=$((wal_now + 1800))
wal_new_deadline=$((wal_old_deadline + 900))
wal_limit_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${wal_old_deadline}" \
  "observed_5h_limit_id=${wal_limit_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${wal_old_deadline}" \
  "five_h_armed_limit_id=${wal_limit_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=50' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$wal_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold 5h 50 \
  "limit:${wal_limit_id}|reset:${wal_old_deadline}" \
  "write-ahead stale threshold" \
  "{\"limit_id\":\"${wal_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":${wal_old_deadline},\"covered_thresholds\":[50]}" \
  "$((wal_now + 1))" "$((wal_old_deadline + 5 * 60 * 60))" false >/dev/null
# Preserve the real implementation and stop after the atomic threshold expiry
# plus durable tombstone write.
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /expire_observed_owner_cycle_original /')"
(
  expire_observed_owner_cycle() {
    expire_observed_owner_cycle_original "$@"
    exit 99
  }
  check_thresholds 100 100 later unknown "$wal_new_deadline" '' "$wal_now" group-a >/dev/null
) >/dev/null 2>&1 || true
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "write-ahead crash emitted an HTTP request"
python3 - "$ALERT_DELIVERIES_FILE" "$wal_limit_id" "$wal_old_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
tombstones = [item for item in items if item["kind"] == "reset"]
assert len(tombstones) == 1, items
tombstone = tombstones[0]
assert tombstone["event_data"]["limit_id"] == sys.argv[2], tombstone
assert tombstone["event_data"]["reset_epoch"] == int(sys.argv[3]), tombstone
assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["status"] == "failed", tombstone
PYEOF
# Restore the real wrapper for the retry and let recovery run after OLD.  The
# first retry deliberately omits the 5-hour deadline: the durable local intent
# must close the stale threshold before a complete reset proof is reacquired.
eval "$(declare -f expire_observed_owner_cycle_original | sed '1s/^expire_observed_owner_cycle_original /expire_observed_owner_cycle /')"
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="$wal_hook"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  check_thresholds 100 100 later unknown '' '' "$((wal_old_deadline + 1))" group-a >/dev/null
) >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "write-ahead recovery emitted an HTTP request"
assert_eq 1 "$(wc -l < "$wal_hook_log")" \
  "write-ahead recovery did not run the local hook exactly once"
check_thresholds 100 100 later unknown "$wal_new_deadline" '' "$((wal_old_deadline + 2))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "write-ahead recovery replayed a reset on the next poll"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
thresholds = [item for item in items if item["kind"] == "threshold"]
tombstones = [item for item in items if item["kind"] == "reset"]
assert len(thresholds) == 1, items
assert thresholds[0]["terminal_reason"] == "expired_after_reset", thresholds
assert thresholds[0]["detector_acknowledged_at"] is not None, thresholds
assert len(tombstones) == 1, items
assert tombstones[0]["terminal_reason"] == "local_observed", tombstones
assert tombstones[0]["detector_acknowledged_at"] is not None, tombstones
PYEOF
# Reconciliation itself can fail after the write-ahead marker. The detector
# state must remain on the old arm and retry the same proof on the next poll.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-reconcile-failure"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
reconcile_fail_now=2000009000
reconcile_fail_old=$((reconcile_fail_now + 1800))
reconcile_fail_new=$((reconcile_fail_old + 900))
reconcile_fail_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${reconcile_fail_old}" \
  "observed_5h_limit_id=${reconcile_fail_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${reconcile_fail_old}" \
  "five_h_armed_limit_id=${reconcile_fail_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$reconcile_fail_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f reconcile_alert_deliveries | sed '1s/^reconcile_alert_deliveries /reconcile_alert_deliveries_original /')"
(
  reconcile_alert_deliveries() { return 1; }
  check_thresholds 100 100 later unknown "$reconcile_fail_new" '' "$reconcile_fail_now" group-a >/dev/null
) >/dev/null 2>&1 || true
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "reconcile failure emitted an HTTP request"
assert_eq "$reconcile_fail_old" "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "reconcile failure advanced the old reset arm"
assert_eq "$reconcile_fail_old" "$(awk -F= '$1 == "last_notified_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "reconcile failure advanced local-only marker"
eval "$(declare -f reconcile_alert_deliveries_original | sed '1s/^reconcile_alert_deliveries_original /reconcile_alert_deliveries /')"
check_thresholds 100 100 later unknown "$reconcile_fail_new" '' \
  "$((reconcile_fail_old + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "reconcile retry emitted an HTTP request"
assert_eq local_observed "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.terminal_reason)" \
  "reconcile retry did not retain the local-only tombstone"
assert_eq "$((reconcile_fail_old + 1))" "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.detector_acknowledged_at)" \
  "reconcile retry did not acknowledge the local-only tombstone"

# A process can stop after the write-ahead row, reconciliation, and the
# detector-state write have succeeded, but before the reset hook runs. This
# exercises the same stale-arm recovery path with a different prior journal
# history. The durable marker must suppress the observed reset on recovery and
# leave its hook retryable.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-stale-arm-crash"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
stale_arm_crash_now=2000011000
stale_arm_crash_old=$((stale_arm_crash_now + 1800))
stale_arm_crash_new=$((stale_arm_crash_old + 900))
stale_arm_crash_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${stale_arm_crash_old}" \
  "observed_5h_limit_id=${stale_arm_crash_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${stale_arm_crash_old}" \
  "five_h_armed_limit_id=${stale_arm_crash_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$stale_arm_crash_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
stale_arm_crash_hook="${TEST_ROOT}/observed-stale-arm-crash-hook.sh"
stale_arm_crash_hook_log="${TEST_ROOT}/observed-stale-arm-crash-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$STALE_ARM_CRASH_HOOK_LOG"' > "$stale_arm_crash_hook"
chmod 700 "$stale_arm_crash_hook"
export STALE_ARM_CRASH_HOOK_LOG="$stale_arm_crash_hook_log"
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$stale_arm_crash_hook"
# shellcheck disable=SC2034
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
(
  # The write-ahead marker and pending context have already been persisted;
  # terminate from the hook invocation before the hook can run.
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    exit 99
  }
  check_thresholds 100 100 later unknown "$stale_arm_crash_new" '' "$stale_arm_crash_now" group-a >/dev/null
) >/dev/null 2>&1 || true
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "stale-arm crash emitted an HTTP request"
assert_eq "$stale_arm_crash_now" "$(awk -F= '$1 == "last_notified_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "stale-arm crash lost the durable observed marker"
assert_eq local_observed "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.terminal_reason)" \
  "stale-arm crash lost the write-ahead tombstone"
# The hook variables are intentionally scoped to this recovery subshell.
# shellcheck disable=SC2030
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="$stale_arm_crash_hook"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  # The restart sample has consumed quota and is no longer an observed-reset
  # proof; the durable tombstone must still prevent the stale scheduled path.
  check_thresholds 80 100 later unknown "$stale_arm_crash_new" '' "$((stale_arm_crash_old + 1))" group-a >/dev/null
) >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "stale-arm recovery emitted an HTTP request"
assert_eq 1 "$(wc -l < "$stale_arm_crash_hook_log")" \
  "stale-arm recovery did not run the local hook once"
check_thresholds 100 100 later unknown "$stale_arm_crash_new" '' "$((stale_arm_crash_old + 2))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "stale-arm recovery replayed the reset"
assert_eq 1 "$(wc -l < "$stale_arm_crash_hook_log")" \
  "stale-arm recovery replayed the local hook"
assert_eq "$stale_arm_crash_now" "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.detector_acknowledged_at)" \
  "stale-arm recovery did not acknowledge the tombstone"

# A restored arm is not trustworthy when its owner is absent or belongs to a
# different group. The journal, rather than that arm, is authoritative: a
# pending threshold for the current owner must still be expired on the local
# observed refill, regardless of which reset cycle key it carries.
run_restored_incoherent_arm_case() {
  local case_name="$1" arm_owner="$2"
  local case_now=2000005000
  local case_old_deadline=$((case_now + 1800))
  local case_arm_deadline=$((case_now + 3600))
  local case_new_deadline=$((case_old_deadline + 900))
  local case_limit_id case_cycle
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
  export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-${case_name}"
  export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
  case_limit_id="$(canonicalize_alert_limit_id group-a)"
  case_cycle="limit:${case_limit_id}|reset:${case_arm_deadline}"
  printf '%s\n' \
    'state_version=5' 'limit_id_contract_version=1' \
    'prev_5h_pct=100' 'prev_weekly_pct=100' \
    'observed_5h_pct=100' "observed_5h_reset_at=${case_old_deadline}" \
    "observed_5h_limit_id=${case_limit_id}" \
    'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
    "five_h_armed_reset_at=${case_arm_deadline}" \
    "five_h_armed_limit_id=${arm_owner}" \
    'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
    'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
    'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
    'pending_5h_threshold=50' 'pending_weekly_threshold=' > "$STATE_FILE"
  printf '{"completed_at":%s,"alerts":[]}\n' "$case_now" \
    | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
  register_network_alert threshold 5h 50 "$case_cycle" \
    "incoherent ${case_name} stale threshold" \
    "{\"limit_id\":\"${case_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":${case_arm_deadline},\"covered_thresholds\":[50]}" \
    "$((case_now + 1))" "$((case_arm_deadline + 5 * 60 * 60))" false >/dev/null
  check_thresholds 100 100 later unknown "$case_new_deadline" '' \
    "$((case_now + 1))" group-a >/dev/null
  assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
    "${case_name} arm left a stale threshold deliverable"
python3 - "$ALERT_DELIVERIES_FILE" "$case_limit_id" "$case_arm_deadline" "$arm_owner" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
expected_count = 3 if sys.argv[4] else 2
assert len(items) == expected_count, items
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["kind"] == "threshold", threshold
assert threshold["event_data"]["limit_id"] == sys.argv[2], threshold
assert threshold["event_data"]["reset_epoch"] == int(sys.argv[3]), threshold
assert threshold["status"] == "failed", threshold
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["channels"]["discord"]["error_class"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
if sys.argv[4]:
    tombstone = next(item for item in items
                     if item["kind"] == "reset"
                     and item["event_data"]["limit_id"] == sys.argv[4])
    assert tombstone["event_data"]["limit_id"] == sys.argv[4], tombstone
    assert tombstone["event_data"]["reset_epoch"] == int(sys.argv[3]), tombstone
    assert tombstone["terminal_reason"] == "owner_interrupted", tombstone
else:
    tombstone = next(item for item in items if item["kind"] == "reset")
    assert tombstone["event_data"]["limit_id"] == sys.argv[2], tombstone
    assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["status"] == "failed", tombstone
assert tombstone["detector_acknowledged_at"] is not None, tombstone
if sys.argv[4]:
    local_tombstone = next(item for item in items
                           if item["kind"] == "reset"
                           and item["event_data"]["limit_id"] == sys.argv[2])
    assert local_tombstone["terminal_reason"] == "local_observed", local_tombstone
    assert local_tombstone["status"] == "failed", local_tombstone
PYEOF
  check_thresholds 100 100 later unknown "$case_new_deadline" '' \
    "$((case_now + 2))" group-a >/dev/null
  assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
    "${case_name} stale threshold replayed on the next poll"
}

run_restored_incoherent_arm_case ownerless ""
run_restored_incoherent_arm_case foreign "$(canonicalize_alert_limit_id group-b)"

# A low sample must not borrow a restored arm whose owner is absent or foreign.
# Otherwise the threshold occurrence for A is incorrectly assigned B's reset
# cycle (or an ownerless arm is silently attached to A).
run_low_incoherent_arm_case() {
  local case_name="$1" arm_owner="$2"
  local case_now=2000005500
  local case_old_deadline=$((case_now + 1800))
  local case_arm_deadline=$((case_now + 3600))
  local case_sample_deadline=$((case_now + 5400))
  local case_limit_id case_cycle
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
  export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-low-5h-${case_name}"
  export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
  case_limit_id="$(canonicalize_alert_limit_id group-a)"
  case_cycle="limit:${case_limit_id}|reset:${case_sample_deadline}"
  printf '%s\n' \
    'state_version=5' 'limit_id_contract_version=1' \
    'prev_5h_pct=100' 'prev_weekly_pct=100' \
    'observed_5h_pct=100' "observed_5h_reset_at=${case_old_deadline}" \
    "observed_5h_limit_id=${case_limit_id}" \
    'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
    "five_h_armed_reset_at=${case_arm_deadline}" \
    "five_h_armed_limit_id=${arm_owner}" \
    'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
    'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
    'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
    'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
  printf '{"completed_at":%s,"alerts":[]}\n' "$case_now" \
    | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
  check_thresholds 40 100 later unknown "$case_sample_deadline" '' \
    "$((case_now + 1))" group-a >/dev/null
  assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
    "${case_name} low sample did not deliver its own threshold"
  python3 - "$ALERT_DELIVERIES_FILE" "$case_limit_id" "$case_cycle" "$case_sample_deadline" "$arm_owner" "$case_arm_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
foreign_arm = bool(sys.argv[5]) and sys.argv[5] != sys.argv[2]
expected_count = 2 if foreign_arm else 1
assert len(items) == expected_count, items
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["kind"] == "threshold", threshold
assert threshold["event_data"]["limit_id"] == sys.argv[2], threshold
assert threshold["cycle_key"] == sys.argv[3], threshold
assert threshold["event_data"]["reset_epoch"] == int(sys.argv[4]), threshold
if foreign_arm:
    tombstone = next(item for item in items if item["kind"] == "reset")
    assert tombstone["event_data"]["limit_id"] == sys.argv[5], tombstone
    assert tombstone["event_data"]["reset_epoch"] == int(sys.argv[6]), tombstone
    assert tombstone["terminal_reason"] == "owner_interrupted", tombstone
    assert tombstone["status"] == "failed", tombstone
PYEOF
}

run_low_incoherent_arm_case ownerless ""
run_low_incoherent_arm_case foreign "$(canonicalize_alert_limit_id group-b)"

# Weekly threshold cycles follow the same owner contract. Ownerless arms are
# discarded conservatively; a foreign arm cannot supply B's deadline to A;
# an explicit same-owner arm remains the normal cycle anchor.
run_low_incoherent_weekly_arm_case() {
  local case_name="$1" arm_owner="$2"
  local case_now=2000006500
  local case_old_deadline=$((case_now + 1800))
  local case_arm_deadline=$((case_now + 3600))
  local case_sample_deadline=$((case_now + 5400))
  local case_limit_id case_cycle expected_deadline
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
  export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-low-weekly-${case_name}"
  export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
  DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
  TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
  case_limit_id="$(canonicalize_alert_limit_id group-a)"
  expected_deadline="$case_sample_deadline"
  [[ "$arm_owner" == "$case_limit_id" ]] && expected_deadline="$case_arm_deadline"
  case_cycle="limit:${case_limit_id}|reset:${expected_deadline}"
  printf '%s\n' \
    'state_version=5' 'limit_id_contract_version=1' \
    'prev_5h_pct=100' 'prev_weekly_pct=100' \
    'observed_5h_pct=' 'observed_5h_reset_at=0' 'observed_5h_limit_id=' \
    'observed_weekly_pct=100' "observed_weekly_reset_at=${case_old_deadline}" \
    "observed_weekly_limit_id=${case_limit_id}" \
    'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
    "weekly_armed_reset_at=${case_arm_deadline}" \
    "weekly_armed_limit_id=${arm_owner}" \
    'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
    'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
    'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
  printf '{"completed_at":%s,"alerts":[]}\n' "$case_now" \
    | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
  check_thresholds 100 40 unknown later '' "$case_sample_deadline" \
    "$((case_now + 1))" group-a >/dev/null
  assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
    "${case_name} weekly sample did not deliver its own threshold"
  python3 - "$ALERT_DELIVERIES_FILE" "$case_limit_id" "$case_cycle" "$expected_deadline" "$arm_owner" "$case_arm_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
foreign_arm = bool(sys.argv[5]) and sys.argv[5] != sys.argv[2]
expected_count = 2 if foreign_arm else 1
assert len(items) == expected_count, items
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["kind"] == "threshold", threshold
assert threshold["event_data"]["limit_id"] == sys.argv[2], threshold
assert threshold["cycle_key"] == sys.argv[3], threshold
assert threshold["event_data"]["reset_epoch"] == int(sys.argv[4]), threshold
if foreign_arm:
    tombstone = next(item for item in items if item["kind"] == "reset")
    assert tombstone["event_data"]["limit_id"] == sys.argv[5], tombstone
    assert tombstone["event_data"]["reset_epoch"] == int(sys.argv[6]), tombstone
    assert tombstone["terminal_reason"] == "owner_interrupted", tombstone
    assert tombstone["status"] == "failed", tombstone
PYEOF
}

run_low_incoherent_weekly_arm_case ownerless ""
run_low_incoherent_weekly_arm_case foreign "$(canonicalize_alert_limit_id group-b)"
run_low_incoherent_weekly_arm_case same-owner "$(canonicalize_alert_limit_id group-a)"

# The same journal-authoritative expiration applies to a random weekly refill.
# Weekly reset notification remains network-visible, but a pending threshold
# from the consumed weekly cycle must not be delivered alongside it.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-weekly-stale-threshold"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
weekly_observation_now=2000006000
weekly_old_deadline=$((weekly_observation_now + 4 * 24 * 60 * 60))
weekly_arm_deadline=$((weekly_observation_now + 6 * 24 * 60 * 60))
weekly_new_deadline=$((weekly_old_deadline + 3 * 24 * 60 * 60))
weekly_limit_id="$(canonicalize_alert_limit_id group-a)"
weekly_cycle="limit:${weekly_limit_id}|reset:${weekly_arm_deadline}"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=28' \
  'observed_5h_pct=' 'observed_5h_reset_at=0' 'observed_5h_limit_id=' \
  'observed_weekly_pct=28' "observed_weekly_reset_at=${weekly_old_deadline}" \
  "observed_weekly_limit_id=${weekly_limit_id}" \
  'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
  "weekly_armed_reset_at=${weekly_arm_deadline}" \
  "weekly_armed_limit_id=${weekly_limit_id}" \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=50' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$weekly_observation_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
register_network_alert threshold weekly 50 "$weekly_cycle" \
  "stale weekly threshold" \
  "{\"limit_id\":\"${weekly_limit_id}\",\"remaining_pct\":28,\"reset_epoch\":${weekly_arm_deadline},\"covered_thresholds\":[50]}" \
  "$((weekly_observation_now + 1))" "$((weekly_arm_deadline + 7 * 24 * 60 * 60))" false >/dev/null
check_thresholds 100 100 unknown later '' "$weekly_new_deadline" \
  "$((weekly_observation_now + 1))" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly refill delivered a stale threshold along with its reset"
python3 - "$ALERT_DELIVERIES_FILE" "$weekly_limit_id" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
thresholds = [item for item in items if item["kind"] == "threshold"]
resets = [item for item in items if item["kind"] == "reset"]
assert len(thresholds) == 1, items
assert thresholds[0]["event_data"]["limit_id"] == sys.argv[2], thresholds
assert thresholds[0]["status"] == "failed", thresholds
assert thresholds[0]["terminal_reason"] == "expired_after_reset", thresholds
assert thresholds[0]["detector_acknowledged_at"] is not None, thresholds
assert len(resets) == 1, items
assert resets[0]["status"] == "delivered", resets
PYEOF
check_thresholds 100 100 unknown later '' "$weekly_new_deadline" \
  "$((weekly_observation_now + 2))" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly refill replayed a stale threshold or reset"

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
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /expire_observed_owner_cycle_original /')"
expire_observed_owner_cycle() { return 1; }
if check_thresholds 100 100 later unknown "$retry_new_deadline" '' "$((retry_observation_at + 900))" group-a >/dev/null 2>&1; then
  fail "observed reset invalidation failure was accepted"
fi
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "failed invalidation attempted network delivery"
assert_eq "$retry_old_deadline" "$(awk -F= '$1 == "observed_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "failed invalidation advanced the observed baseline"
assert_eq "$retry_old_deadline" "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "failed invalidation advanced the reset arm"
eval "$(declare -f expire_observed_owner_cycle_original | sed '1s/^expire_observed_owner_cycle_original /expire_observed_owner_cycle /')"
check_thresholds 100 100 later unknown "$retry_new_deadline" '' "$((retry_observation_at + 901))" group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "successful observed reset emitted an HTTP request"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 2, items
threshold = next(item for item in items if item["kind"] == "threshold")
tombstone = next(item for item in items if item["kind"] == "reset")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["channels"]["discord"]["error_class"] == "expired_after_reset", threshold
assert tombstone["terminal_reason"] == "local_observed", tombstone
assert tombstone["detector_acknowledged_at"] is not None, tombstone
PYEOF

# A journal transaction failure must leave a durable recovery intent even when
# the restored detector has no armed reset.  A later changed sample must retry
# the old cycle before it can deliver anything, and the successful retry must
# retire the baseline-only marker rather than reprocessing it forever.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-no-arm-journal-failure"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
no_arm_retry_now=2000002700
no_arm_retry_old=$((no_arm_retry_now + 1800))
no_arm_retry_new=$((no_arm_retry_old + 900))
no_arm_retry_id="$(canonicalize_alert_limit_id group-a)"
check_thresholds 100 100 later unknown "$no_arm_retry_old" '' \
  "$no_arm_retry_now" group-a >/dev/null
register_network_alert threshold 5h 50 \
  "limit:${no_arm_retry_id}|reset:${no_arm_retry_old}" \
  "no-arm journal failure threshold" \
  "{\"limit_id\":\"${no_arm_retry_id}\",\"remaining_pct\":40,\"reset_epoch\":${no_arm_retry_old},\"covered_thresholds\":[50]}" \
  "$((no_arm_retry_now + 1))" "$((no_arm_retry_old + 5 * 60 * 60))" false >/dev/null
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /expire_observed_owner_cycle_original /')"
expire_observed_owner_cycle() { return 1; }
if check_thresholds 100 100 later unknown "$no_arm_retry_new" '' \
  "$((no_arm_retry_now + 2))" group-a >/dev/null 2>&1; then
  fail "no-arm observed journal failure was accepted"
fi
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "no-arm journal failure emitted HTTP"
eval "$(declare -f expire_observed_owner_cycle_original | sed '1s/^expire_observed_owner_cycle_original /expire_observed_owner_cycle /')"
check_thresholds 80 100 later unknown "$no_arm_retry_new" '' \
  "$((no_arm_retry_now + 3))" group-a >/dev/null
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "no-arm recovery emitted HTTP"
assert_eq 0 "$(awk -F= '$1 == "local_observed_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "no-arm recovery marker was reintroduced"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
tombstone = next(item for item in items if item["kind"] == "reset")
assert tombstone["terminal_reason"] == "local_observed", tombstone
PYEOF

# Weekly observed-reset expiry has the complementary durable marker.  If the
# journal transaction fails, a later changed sample retries expiry and may
# deliver only the legitimate weekly reset, never the stale threshold.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-weekly-journal-failure"
weekly_retry_now=2000002900
weekly_retry_old=$((weekly_retry_now + 3600))
weekly_retry_new=$((weekly_retry_old + 3600))
weekly_retry_id="$(canonicalize_alert_limit_id group-a)"
check_thresholds 100 80 unknown later '' "$weekly_retry_old" \
  "$weekly_retry_now" group-a >/dev/null
python3 - "$STATE_FILE" "$weekly_retry_id" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["weekly_armed_reset_at"] = "0"
values["weekly_armed_limit_id"] = ""
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
register_network_alert threshold weekly 50 \
  "limit:${weekly_retry_id}|reset:${weekly_retry_old}" \
  "weekly journal failure threshold" \
  "{\"limit_id\":\"${weekly_retry_id}\",\"remaining_pct\":40,\"reset_epoch\":${weekly_retry_old},\"covered_thresholds\":[50]}" \
  "$((weekly_retry_now + 1))" "$((weekly_retry_old + 7 * 24 * 60 * 60))" false >/dev/null
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /expire_observed_owner_cycle_original /')"
expire_observed_owner_cycle() { return 1; }
if check_thresholds 100 100 unknown later '' "$weekly_retry_new" \
  "$((weekly_retry_now + 2))" group-a >/dev/null 2>&1; then
  fail "weekly journal failure was accepted"
fi
[[ ! -e "$FAKE_CURL_LOG" ]] || fail "weekly journal failure emitted HTTP"
eval "$(declare -f expire_observed_owner_cycle_original | sed '1s/^expire_observed_owner_cycle_original /expire_observed_owner_cycle /')"
check_thresholds 100 80 unknown later '' "$weekly_retry_new" \
  "$((weekly_retry_now + 3))" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly recovery did not deliver exactly its reset"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
threshold = next(item for item in items if item["kind"] == "threshold")
assert threshold["terminal_reason"] == "expired_after_reset", threshold
assert threshold["detector_acknowledged_at"] is not None, threshold
reset = next(item for item in items if item["kind"] == "reset")
assert reset["status"] == "delivered", reset
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
assert len(items) == 2, items
assert {item["kind"] for item in items} == {"reset"}, items
assert {item["window"] for item in items} == {"5h", "weekly"}, items
for item in items:
    assert item["event_data"]["limit_id"] == sys.argv[2], item
    assert item["terminal_reason"] == "owner_interrupted", item
    assert item["status"] == "failed", item
    assert item["detector_acknowledged_at"] is not None, item
PYEOF
ALERT_THRESHOLDS=75

# Missing-journal reconstruction must run after restored arms are checked. A
# foreign or ownerless arm may not supply a deadline to either current-owner
# threshold; an explicit same-owner arm remains the scheduled cycle anchor.
run_missing_journal_incoherent_arm_case() {
  local case_name="$1" arm_owner="$2"
  local case_now=2000008000
  local case_arm_deadline=$((case_now + 3600))
  local case_sample_deadline=$((case_now + 5400))
  local case_limit_id case_other_id
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
  export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-missing-${case_name}"
  export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
  case_limit_id="$(canonicalize_alert_limit_id group-a)"
  case_other_id="$(canonicalize_alert_limit_id group-b)"
  printf '%s\n' \
    'state_version=5' 'limit_id_contract_version=1' \
    'prev_5h_pct=80' 'prev_weekly_pct=80' \
    'observed_5h_pct=80' "observed_5h_reset_at=${case_now}" \
    "observed_5h_limit_id=${case_limit_id}" \
    'observed_weekly_pct=80' "observed_weekly_reset_at=${case_now}" \
    "observed_weekly_limit_id=${case_limit_id}" \
    "five_h_armed_reset_at=${case_arm_deadline}" \
    "five_h_armed_limit_id=${arm_owner}" \
    "weekly_armed_reset_at=${case_arm_deadline}" \
    "weekly_armed_limit_id=${arm_owner}" \
    'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
    'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
    'pending_5h_threshold=50' 'pending_weekly_threshold=50' > "$STATE_FILE"
  [[ "$arm_owner" == "$case_limit_id" || "$arm_owner" == "" || "$arm_owner" == "$case_other_id" ]]
  [[ ! -e "$ALERT_DELIVERIES_FILE" ]] || fail "${case_name} journal was not absent before reconstruction"
  check_thresholds 40 40 later later "$case_sample_deadline" "$case_sample_deadline" \
    "$case_now" group-a >/dev/null
  assert_eq 2 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
    "${case_name} missing-journal threshold reconstruction count"
  python3 - "$ALERT_DELIVERIES_FILE" "$case_limit_id" "$case_arm_deadline" "$case_name" "$arm_owner" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
thresholds = [item for item in items if item["kind"] == "threshold"]
resets = [item for item in items if item["kind"] == "reset"]
assert len(thresholds) == 2, items
expected_resets = 2 if sys.argv[4] == "foreign" else 0
assert len(resets) == expected_resets, items
for item in thresholds:
    assert item["event_data"]["limit_id"] == sys.argv[2], item
    expected = int(sys.argv[3]) if sys.argv[4] == "same-owner" else 0
    assert item["event_data"]["reset_epoch"] == expected, item
    expected_cycle = f"limit:{sys.argv[2]}|reset:{expected}" if expected else f"limit:{sys.argv[2]}|unarmed"
    assert item["cycle_key"].endswith(expected_cycle), item
if expected_resets:
    for item in resets:
        assert item["event_data"]["limit_id"] == sys.argv[5], item
        assert item["terminal_reason"] == "owner_interrupted", item
        assert item["status"] == "failed", item
PYEOF
}

run_missing_journal_incoherent_arm_case ownerless ""
run_missing_journal_incoherent_arm_case foreign "$(canonicalize_alert_limit_id group-b)"
run_missing_journal_incoherent_arm_case same-owner "$(canonicalize_alert_limit_id group-a)"

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

# If a process dies after writing a local-observed tombstone but before
# persisting the detector cleanup, a later owner interruption must promote the
# same reset row to owner_interrupted.  Otherwise a return to A can mistake the
# old local tombstone for permission to run the 5h hook.  This models both
# crash windows: the first write-ahead local tombstone, then B's interruption
# immediately after its promotion and before the arm is persisted.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-local-tombstone-interruption-5h"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
collision_hook="${TEST_ROOT}/local-tombstone-interruption-5h-hook.sh"
collision_hook_log="${TEST_ROOT}/local-tombstone-interruption-5h-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$COLLISION_HOOK_LOG"' \
  > "$collision_hook"
chmod 700 "$collision_hook"
export COLLISION_HOOK_LOG="$collision_hook_log"
collision_now=2000004100
collision_old=$((collision_now + 1800))
collision_a_id="$(canonicalize_alert_limit_id group-a)"
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=100' "observed_5h_reset_at=${collision_old}" \
  "observed_5h_limit_id=${collision_a_id}" \
  'observed_weekly_pct=' 'observed_weekly_reset_at=0' 'observed_weekly_limit_id=' \
  "five_h_armed_reset_at=${collision_old}" "five_h_armed_limit_id=${collision_a_id}" \
  'weekly_armed_reset_at=0' 'weekly_armed_limit_id=' \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$collision_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
python3 "$ALERTS_PY" suppress-local-reset "$ALERT_DELIVERIES_FILE" 5h \
  "$collision_a_id" "$collision_old" --now "$collision_now" >/dev/null
assert_eq local_observed "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.terminal_reason)" \
  "first crash window did not leave a local-observed tombstone"
# shellcheck disable=SC2031
export ALERT_SCRIPT_1="$collision_hook" ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f interrupt_reset_cycle | sed '1s/^interrupt_reset_cycle /interrupt_reset_cycle_collision_original /')"
(
  interrupt_reset_cycle() {
    interrupt_reset_cycle_collision_original "$@"
    exit 99
  }
  check_thresholds 80 100 unknown unknown '' '' "$((collision_now + 1))" group-b
) >/dev/null 2>&1 || true
eval "$(declare -f interrupt_reset_cycle_collision_original | sed '1s/^interrupt_reset_cycle_collision_original /interrupt_reset_cycle /')"
python3 - "$ALERT_DELIVERIES_FILE" "$collision_a_id" "$collision_old" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert len(items) == 1, items
tombstone = items[0]
assert tombstone["event_data"]["limit_id"] == sys.argv[2], tombstone
assert tombstone["event_data"]["reset_epoch"] == int(sys.argv[3]), tombstone
assert tombstone["terminal_reason"] == "owner_interrupted", tombstone
assert tombstone["status"] == "failed", tombstone
PYEOF
# A partial A row after the old deadline must clear the interrupted arm before
# due processing; it must neither POST the reset nor execute its local hook.
check_thresholds 80 100 unknown unknown '' '' "$((collision_old + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "promoted 5h local tombstone emitted an HTTP request on owner return"
[[ ! -e "$collision_hook_log" ]] || fail \
  "promoted 5h local tombstone executed a reset hook on owner return"
assert_eq 0 "$(awk -F= '$1 == "five_h_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "owner-interrupted 5h arm was not cleared after return"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"][0]
assert item["terminal_reason"] == "owner_interrupted", item
assert item["detector_acknowledged_at"] is not None, item
PYEOF

# The generic journal promotion also protects weekly reset hooks.  Keep the
# weekly arm and local tombstone on disk, crash during B's partial interruption,
# then return to A after the deadline and assert the same no-delivery/no-hook
# invariant.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-local-tombstone-interruption-weekly"
weekly_collision_hook="${TEST_ROOT}/local-tombstone-interruption-weekly-hook.sh"
weekly_collision_hook_log="${TEST_ROOT}/local-tombstone-interruption-weekly-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "hook|%s|%s\n" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_WINDOW" >> "$WEEKLY_COLLISION_HOOK_LOG"' \
  > "$weekly_collision_hook"
chmod 700 "$weekly_collision_hook"
export WEEKLY_COLLISION_HOOK_LOG="$weekly_collision_hook_log"
weekly_collision_now=2000005100
weekly_collision_old=$((weekly_collision_now + 3 * 24 * 60 * 60))
printf '%s\n' \
  'state_version=5' 'limit_id_contract_version=1' \
  'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'observed_5h_pct=' 'observed_5h_reset_at=0' 'observed_5h_limit_id=' \
  'observed_weekly_pct=100' "observed_weekly_reset_at=${weekly_collision_old}" \
  "observed_weekly_limit_id=${collision_a_id}" \
  'five_h_armed_reset_at=0' 'five_h_armed_limit_id=' \
  "weekly_armed_reset_at=${weekly_collision_old}" "weekly_armed_limit_id=${collision_a_id}" \
  'last_notified_5h_reset_at=0' 'last_notified_weekly_reset_at=0' \
  'local_observed_5h_reset_at=0' 'local_observed_weekly_reset_at=0' \
  'notified_5h_thresholds=' 'notified_weekly_thresholds=' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
printf '{"completed_at":%s,"alerts":[]}\n' "$weekly_collision_now" \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
python3 "$ALERTS_PY" suppress-local-reset "$ALERT_DELIVERIES_FILE" weekly \
  "$collision_a_id" "$weekly_collision_old" --now "$weekly_collision_now" >/dev/null
assert_eq local_observed "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.terminal_reason)" \
  "weekly first crash window did not leave a local-observed tombstone"
export ALERT_SCRIPT_1="$weekly_collision_hook" ALERT_SCRIPT_1_EVENTS='weekly:reset'
validate_config
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f interrupt_reset_cycle | sed '1s/^interrupt_reset_cycle /interrupt_reset_cycle_weekly_collision_original /')"
(
  interrupt_reset_cycle() {
    interrupt_reset_cycle_weekly_collision_original "$@"
    exit 99
  }
  check_thresholds 100 80 unknown unknown '' '' "$((weekly_collision_now + 1))" group-b
) >/dev/null 2>&1 || true
eval "$(declare -f interrupt_reset_cycle_weekly_collision_original | sed '1s/^interrupt_reset_cycle_weekly_collision_original /interrupt_reset_cycle /')"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"][0]
assert item["window"] == "weekly", item
assert item["terminal_reason"] == "owner_interrupted", item
PYEOF
check_thresholds 100 80 unknown unknown '' '' "$((weekly_collision_old + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "promoted weekly local tombstone emitted an HTTP request on owner return"
[[ ! -e "$weekly_collision_hook_log" ]] || fail \
  "promoted weekly local tombstone executed a reset hook on owner return"
assert_eq 0 "$(awk -F= '$1 == "weekly_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "owner-interrupted weekly arm was not cleared after return"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"][0]
assert item["terminal_reason"] == "owner_interrupted", item
assert item["detector_acknowledged_at"] is not None, item
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
assert len(items) == 3, items
a_threshold = next(item for item in items
                   if item["event_data"]["limit_id"] == sys.argv[2]
                   and item["kind"] == "threshold")
a_reset = next(item for item in items
               if item["event_data"]["limit_id"] == sys.argv[2]
               and item["kind"] == "reset")
b_threshold = next(item for item in items
                   if item["event_data"]["limit_id"] == sys.argv[3]
                   and item["kind"] == "threshold")
for item in (a_threshold, a_reset):
    assert item["status"] == "failed", items
    assert item["terminal_reason"] == "owner_interrupted", items
    assert item["detector_acknowledged_at"] is not None, items
assert b_threshold["status"] == "delivered", items
assert b_threshold["selector"] == "50", items
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

# A weekly refill observed while alerting is disabled is local-only.  Recreate
# the durable pre-cleanup state to model a crash after its local marker write;
# re-enabling alerts must not turn that marker into a network reset.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-disabled-observed-weekly"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERT_THRESHOLDS=0
ALERTS_ENABLED=0
weekly_disabled_now=2000001000
weekly_disabled_old=$((weekly_disabled_now + 4 * 24 * 60 * 60))
weekly_disabled_new=$((weekly_disabled_old + 3 * 24 * 60 * 60))
weekly_disabled_id="$(canonicalize_alert_limit_id group-a)"
check_thresholds 100 40 unknown later '' "$weekly_disabled_old" \
  "$weekly_disabled_now" group-a >/dev/null
check_thresholds 100 100 unknown later '' "$weekly_disabled_new" \
  "$((weekly_disabled_now + 1))" group-a >/dev/null
python3 - "$STATE_FILE" "$((weekly_disabled_now + 1))" "$weekly_disabled_id" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["weekly_armed_reset_at"] = sys.argv[2]
values["weekly_armed_limit_id"] = sys.argv[3]
values["last_notified_weekly_reset_at"] = "0"
values["local_observed_weekly_reset_at"] = sys.argv[2]
values["pending_observed_weekly_reset_at"] = "0"
values["pending_observed_weekly_reset_limit_id"] = ""
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
assert_eq 0 "$(python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]))
PYEOF
)" "disabled weekly observation was queued before re-enable"
ALERTS_ENABLED=1
check_thresholds 100 100 unknown later '' "$weekly_disabled_new" \
  "$((weekly_disabled_now + 2))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "disabled weekly observation was delivered after re-enable"
assert_eq 0 "$(python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]))
PYEOF
)" "disabled weekly observation rebuilt a reset occurrence"
assert_eq 0 "$(awk -F= '$1 == "weekly_armed_reset_at" {print $2}' "$STATE_FILE")" \
  "disabled weekly marker retained a reset arm"
assert_eq 0 "$(awk -F= '$1 == "local_observed_weekly_reset_at" {print $2}' "$STATE_FILE")" \
  "disabled weekly marker was not consumed locally"

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

# Weekly observed-reset recovery must preserve the pending occurrence created
# before a transient 503.  Rebuilding it at the next poll has a different
# observation time, but the same immutable cycle and event data.
rm -f "${STATE_FILE}" "${ALERT_DELIVERIES_FILE}" "${FAKE_CURL_LOG}"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-weekly-retry-reuse"
export FAKE_CURL_DISCORD_STATUS_SEQUENCE=503,204
unset FAKE_CURL_DISCORD_STATUS
ALERTS_ENABLED=1
ALERT_THRESHOLDS=5
weekly_reuse_now=2000002250
weekly_reuse_old=$((weekly_reuse_now + 3600))
weekly_reuse_new=$((weekly_reuse_old + 3600))
weekly_reuse_id="$(canonicalize_alert_limit_id group-a)"
ALERTS_ENABLED=0 check_thresholds 100 40 unknown later '' "${weekly_reuse_old}" \
  "${weekly_reuse_now}" group-a >/dev/null
ALERT_THRESHOLDS=50
register_network_alert threshold weekly 50 \
  "limit:${weekly_reuse_id}|reset:${weekly_reuse_old}" \
  "weekly retry stale threshold" \
  "{\"limit_id\":\"${weekly_reuse_id}\",\"remaining_pct\":40,\"reset_epoch\":${weekly_reuse_old},\"covered_thresholds\":[50]}" \
  "$((weekly_reuse_now + 1))" "$((weekly_reuse_old + 7 * 24 * 60 * 60))" false >/dev/null
check_thresholds 100 100 unknown later '' "${weekly_reuse_new}" \
  "$((weekly_reuse_now + 1))" group-a >/dev/null 2>&1 || true
assert_eq pending "$(json_field "${ALERT_DELIVERIES_FILE}" alerts.1.channels.discord.status)" \
  "weekly 503 reset occurrence was not left pending"
assert_eq 1 "$(json_field "${ALERT_DELIVERIES_FILE}" alerts.1.channels.discord.attempt_count)" \
  "weekly 503 reset attempt was not recorded"
check_thresholds 100 100 unknown later '' "${weekly_reuse_new}" \
  "$((weekly_reuse_now + 2))" group-a >/dev/null
assert_eq 2 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly reset recovery did not retry exactly once"
assert_eq 1 "$(python3 - "${ALERT_DELIVERIES_FILE}" <<'PYEOF'
import json
import sys
items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
print(sum(item["kind"] == "reset" for item in items))
PYEOF
)" "weekly recovery rebuilt a duplicate reset occurrence"
assert_eq delivered "$(json_field "${ALERT_DELIVERIES_FILE}" alerts.1.status)" \
  "weekly reset recovery did not deliver the original occurrence"

# A reset observed from a restored baseline can have no durable arm yet.  The
# first observed poll must persist a local-only arm before the hook runs; if the
# process stops at that boundary, a changed restart sample still runs the hook
# once and never creates a scheduled network reset.
rm -f "${STATE_FILE}" "${ALERT_DELIVERIES_FILE}" "${FAKE_CURL_LOG}"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-5h-no-arm-hook-recovery"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
no_arm_hook="${TEST_ROOT}/observed-no-arm-hook.sh"
no_arm_hook_log="${TEST_ROOT}/observed-no-arm-hook.log"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "hook|%s|%s\n" "${CODEX_ALERT_EVENT}" "${CODEX_ALERT_WINDOW}" >> "${NO_ARM_HOOK_LOG}"' > "${no_arm_hook}"
chmod 700 "${no_arm_hook}"
export NO_ARM_HOOK_LOG="${no_arm_hook_log}"
no_arm_hook_now=2000002300
no_arm_hook_old=$((no_arm_hook_now + 1800))
no_arm_hook_new=$((no_arm_hook_old + 900))
check_thresholds 100 100 later unknown "${no_arm_hook_old}" '' \
  "${no_arm_hook_now}" group-a >/dev/null
printf '{"schema_version":2,"limit_id_contract_version":1,"legacy_migration":{"source_state_version":5,"completed_at":%s},"alerts":[]}\n' \
  "${no_arm_hook_now}" > "${ALERT_DELIVERIES_FILE}"
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="${no_arm_hook}"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  # The local arm and hook intent are durable before the hook invocation;
  # terminate there to model a process crash without a persistence-call count.
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    exit 99
  }
  check_thresholds 100 100 later unknown "${no_arm_hook_new}" '' \
    "$((no_arm_hook_now + 1))" group-a >/dev/null
) >/dev/null 2>&1 || true
assert_eq "$((no_arm_hook_now + 1))" "$(awk -F= '$1 == "local_observed_5h_reset_at" {print $2}' "$STATE_FILE")" \
  "no-arm observed reset marker was not written before final persistence"
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "no-arm observed reset emitted HTTP before restart"
(
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1="${no_arm_hook}"
  # shellcheck disable=SC2034
  ALERT_SCRIPT_1_EVENTS='5h:reset'
  validate_config
  check_thresholds 80 100 later unknown "${no_arm_hook_new}" '' \
    "$((no_arm_hook_old + 1))" group-a >/dev/null
) >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "no-arm observed recovery emitted HTTP"
assert_eq 1 "$(wc -l < "${no_arm_hook_log}")" \
  "no-arm observed recovery did not execute one local hook"
check_thresholds 80 100 later unknown "${no_arm_hook_new}" '' \
  "$((no_arm_hook_old + 2))" group-a >/dev/null
assert_eq 1 "$(wc -l < "${no_arm_hook_log}")" \
  "no-arm observed recovery replayed its local hook"

# A weekly recovery marker with no journal occurrence must not be rebuilt after
# its delivery window has expired. In particular, the reconstructed request
# would have expires_at before created_at and could otherwise block every
# subsequent poll.
rm -f "${STATE_FILE}" "${ALERT_DELIVERIES_FILE}" "${FAKE_CURL_LOG}"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-observed-weekly-expired-marker"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
ALERTS_ENABLED=1
ALERT_THRESHOLDS=50
weekly_expired_now=2000003600
weekly_expired_epoch=$((weekly_expired_now - 8 * 24 * 60 * 60))
weekly_expired_id="$(canonicalize_alert_limit_id group-a)"
python3 - "${STATE_FILE}" "${weekly_expired_epoch}" "${weekly_expired_id}" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
epoch = sys.argv[2]
limit_id = sys.argv[3]
values = {
    "state_version": "5", "limit_id_contract_version": "1",
    "prev_5h_pct": "100", "prev_weekly_pct": "100",
    "observed_5h_pct": "", "observed_5h_reset_at": "0", "observed_5h_limit_id": "",
    "observed_weekly_pct": "100", "observed_weekly_reset_at": epoch,
    "observed_weekly_limit_id": limit_id,
    "five_h_armed_reset_at": "0", "five_h_armed_limit_id": "",
    "weekly_armed_reset_at": epoch, "weekly_armed_limit_id": limit_id,
    "last_notified_5h_reset_at": "0", "last_notified_weekly_reset_at": "0",
    "local_observed_5h_reset_at": "0", "local_observed_weekly_reset_at": epoch,
    "notified_5h_thresholds": "", "notified_weekly_thresholds": "",
    "pending_5h_threshold": "", "pending_weekly_threshold": "",
}
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
printf '{"schema_version":2,"limit_id_contract_version":1,"legacy_migration":{"source_state_version":5,"completed_at":%s},"alerts":[]}\n' \
  "${weekly_expired_now}" > "${ALERT_DELIVERIES_FILE}"
check_thresholds 80 80 unknown later '' "$((weekly_expired_epoch + 1))" \
  "${weekly_expired_now}" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "expired weekly recovery marker emitted HTTP"
assert_eq 0 "$(awk -F= '$1 == "weekly_armed_reset_at" {print $2}' "${STATE_FILE}")" \
  "expired weekly recovery arm was not cleared"
assert_eq 0 "$(awk -F= '$1 == "local_observed_weekly_reset_at" {print $2}' "${STATE_FILE}")" \
  "expired weekly recovery marker was not cleared"
assert_eq 0 "$(python3 - "${ALERT_DELIVERIES_FILE}" <<'PYEOF'
import json
import sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]))
PYEOF
)" "expired weekly recovery rebuilt an occurrence"
check_thresholds 80 80 unknown later '' "$((weekly_expired_epoch + 1))" \
  "$((weekly_expired_now + 1))" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "expired weekly recovery blocked the following poll"

# A full weekly sample before the announced deadline followed by a full
# sample after it is a scheduled crossing, even when the deadline advances.
# The live journal must use the old deadline as the immutable reset identity.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-weekly-full-crossing"
export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
unset FAKE_CURL_DISCORD_STATUS_SEQUENCE
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
ALERTS_ENABLED=1
ALERT_THRESHOLDS=0
weekly_full_before=2000007000
weekly_full_old_deadline=$((weekly_full_before + 900))
weekly_full_after=$((weekly_full_old_deadline + 900))
weekly_full_new_deadline=$((weekly_full_old_deadline + 7 * 24 * 60 * 60))
weekly_full_id="$(canonicalize_alert_limit_id group-a)"
check_thresholds 100 100 unknown later '' "$weekly_full_old_deadline" \
  "$weekly_full_before" group-a >/dev/null
check_thresholds 100 100 unknown later '' "$weekly_full_new_deadline" \
  "$weekly_full_after" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly full-to-full crossing did not send one live reset"
python3 - "$ALERT_DELIVERIES_FILE" "$weekly_full_id" "$weekly_full_old_deadline" \
  "$weekly_full_after" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
resets = [item for item in items if item["kind"] == "reset"]
assert len(resets) == 1, items
reset = resets[0]
assert reset["event_data"] == {
    "limit_id": sys.argv[2], "reset_epoch": int(sys.argv[3]),
}, reset
assert reset["cycle_key"] == f"limit:{sys.argv[2]}|reset:{sys.argv[3]}", reset
assert reset["status"] == "delivered", reset
assert reset["created_at"] == int(sys.argv[3]), reset
assert not any(
    item["kind"] == "reset" and item["event_data"]["reset_epoch"] == int(sys.argv[4])
    for item in items
), items
PYEOF

# A refill observed before the planned deadline remains the historical random
# case; the scheduled-crossing priority applies only after the old deadline
# has actually been crossed.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-weekly-full-random-before-deadline"
weekly_random_before=2000009000
weekly_random_old_deadline=$((weekly_random_before + 1800))
weekly_random_observed=$((weekly_random_before + 900))
weekly_random_new_deadline=$((weekly_random_old_deadline + 3 * 24 * 60 * 60))
check_thresholds 100 97 unknown later '' "$weekly_random_old_deadline" \
  "$weekly_random_before" group-a >/dev/null
check_thresholds 100 100 unknown later '' "$weekly_random_new_deadline" \
  "$weekly_random_observed" group-a >/dev/null
assert_eq 1 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "weekly full-to-full refill before its deadline was not random"
python3 - "$ALERT_DELIVERIES_FILE" "$weekly_random_observed" \
  "$weekly_random_old_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
resets = [item for item in items if item["kind"] == "reset"]
assert len(resets) == 1, items
reset = resets[0]
assert reset["event_data"]["reset_epoch"] == int(sys.argv[2]), reset
assert reset["created_at"] == int(sys.argv[2]), reset
assert reset["event_data"]["reset_epoch"] != int(sys.argv[3]), reset
PYEOF

# A full-to-full weekly transition after a gap larger than the archive's
# evidence window is not a scheduled crossing.  Live and archive must reject
# the same insufficient pair rather than letting live anchor a reset at the
# old deadline.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$FAKE_CURL_LOG"
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-weekly-full-long-gap"
weekly_long_gap_before=2000020000
weekly_long_gap_old_deadline=$((weekly_long_gap_before + 900))
weekly_long_gap_after=$((weekly_long_gap_before + 100000))
weekly_long_gap_new_deadline=$((weekly_long_gap_old_deadline + 7 * 24 * 60 * 60))
check_thresholds 100 100 unknown later '' "$weekly_long_gap_old_deadline" \
  "$weekly_long_gap_before" group-a >/dev/null
check_thresholds 100 100 unknown later '' "$weekly_long_gap_new_deadline" \
  "$weekly_long_gap_after" group-a >/dev/null
assert_eq 0 "$(fake_curl_count "${FAKE_CURL_COUNT_DIR}/discord")" \
  "long-gap weekly full-to-full transition emitted a live reset"
python3 - "$ALERT_DELIVERIES_FILE" "$weekly_long_gap_old_deadline" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert not any(
    item["kind"] == "reset"
    and item["event_data"].get("reset_epoch") == int(sys.argv[2])
    for item in items
), items
PYEOF

printf 'PASS: monitor network tests\n'
