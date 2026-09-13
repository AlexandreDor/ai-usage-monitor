#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

assert_eq $'⏱️ Codex · 5h quota · Low balance\nRemaining: 12.5%\nThreshold crossed: 25%\nResets: 18/05/2033 05:33' \
  "$(format_alert_message threshold 5h 12.5 25 '18/05/2033 05:33')" \
  "5h threshold message"
assert_eq $'⏱️ Codex · 5h quota · Low balance\nRemaining: 12.5%\nThreshold crossed: 25%\nResets: 18/05/2033 05:33\n\nWeekly pace vs ideal: -10.0 pts · 20.0% below' \
  "$(format_alert_message threshold 5h 12.5 25 '18/05/2033 05:33' '-10.0 pts · 20.0% below')" \
  "5h threshold message with pace"
assert_eq $'📅 Codex · Weekly quota · Low balance\nRemaining: 40%\nThreshold crossed: 50%\nResets: 25/05/2033 04:13' \
  "$(format_alert_message threshold weekly 40 50 '25/05/2033 04:13')" \
  "weekly threshold message without pace"
assert_eq $'📅 Codex · Weekly quota · Low balance\nRemaining: 40%\nThreshold crossed: 50%\nResets: tomorrow\n\nWeekly pace vs ideal: -10.0 pts · 20.0% below' \
  "$(format_alert_message threshold weekly 40 50 tomorrow '-10.0 pts · 20.0% below')" \
  "weekly threshold message with pace"
assert_eq $'⏱️ Codex · 5h quota · Reset\nA new usage cycle is available.' \
  "$(format_alert_message reset 5h)" "5h reset message"
assert_eq $'📅 Codex · Weekly quota · Reset\nA new usage cycle is available.' \
  "$(format_alert_message reset weekly)" "weekly reset message"
assert_eq $'⏱️ Codex · 5h quota · Anomaly\nQuota rose unexpectedly.' \
  "$(format_alert_message anomaly 5h '' '' '' '' 'Quota rose unexpectedly.')" \
  "5h anomaly message"
assert_eq $'📅 Codex · Weekly quota · Anomaly\nReset deadline moved unexpectedly.' \
  "$(format_alert_message anomaly weekly '' '' '' '' 'Reset deadline moved unexpectedly.')" \
  "weekly anomaly message"

# Newline-containing messages reach both transports as one payload.
message="$(format_alert_message threshold weekly 40 50 tomorrow '-10.0 pts · 20.0% below')"
DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
TELEGRAM_BOT_TOKEN='123:token'
TELEGRAM_CHAT_ID='-456'
captured_discord_payload="${TEST_ROOT}/discord-payload"
captured_message="${TEST_ROOT}/telegram-message"
# shellcheck disable=SC2329
curl() {
  local output='' argument
  while (($#)); do
    argument="$1"
    case "$argument" in
      --output) output="$2"; shift 2 ;;
      --data)
        printf '%s' "$2" > "$captured_discord_payload"
        shift 2 ;;
      --data-urlencode)
        [[ "$2" == text=* ]] && printf '%s' "${2#text=}" > "$captured_message"
        shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$output" ]] || printf '{"ok":true}' > "$output"
  printf '200'
}
alert_http_attempt discord "$message"
assert_eq "$message" "$(python3 - "$captured_discord_payload" <<'PYEOF'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["content"])
PYEOF
)" "Discord lost message newlines"
alert_http_attempt telegram "$message"
assert_eq "$message" "$(<"$captured_message")" "Telegram lost message newlines"

# A pending occurrence that predates the formatter keeps its old payload after
# a failed delivery and a later retry.
unset -f curl
FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_BIN"
ln -s "${ROOT_DIR}/tests/fixtures/fake-curl.sh" "${FAKE_BIN}/curl"
export PATH="${FAKE_BIN}:$PATH"
hash -r
FAKE_CURL_LOG="${TEST_ROOT}/retry-curl.log"
export FAKE_CURL_LOG
export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/retry-counts"
export FAKE_CURL_DISCORD_STATUS_SEQUENCE=500,204
export FAKE_CURL_DISCORD_EXIT=0
CURL_RETRIES=0
CURL_RETRY_DELAY_SECONDS=0
TELEGRAM_BOT_TOKEN=''
TELEGRAM_CHAT_ID=''
printf '{"completed_at":2000000000,"alerts":[]}\n' \
  | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version 5
old_message='*Codex weekly limit at 40% remaining* (crossed 50% threshold). Resets tomorrow'
retry_limit_id="$(canonicalize_alert_limit_id group-a)"
register_network_alert threshold weekly 50 "limit:${retry_limit_id}|unarmed" "$old_message" \
  "{\"limit_id\":\"${retry_limit_id}\",\"remaining_pct\":40,\"reset_epoch\":0,\"covered_thresholds\":[50]}" \
  2000000000 0 true
deliver_due_alerts 2000000000
assert_eq pending "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.channels.discord.status)" \
  "failed pre-existing alert was not left pending"
assert_eq "$old_message" "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.message)" \
  "failed delivery changed pre-existing payload"
deliver_due_alerts 2000000001
assert_eq delivered "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.status)" \
  "pre-existing alert did not deliver on retry"
assert_eq "$old_message" "$(json_field "$ALERT_DELIVERIES_FILE" alerts.0.message)" \
  "retry changed pre-existing payload"
assert_eq 2 "$(<"${FAKE_CURL_COUNT_DIR}/discord")" "pre-existing alert retry count"

printf 'PASS: monitor alert format tests\n'
