#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
ALERT_THRESHOLDS=0

export FAKE_CURL_DISCORD_STATUS=204 FAKE_CURL_DISCORD_EXIT=0
export FAKE_CURL_TELEGRAM_STATUS=200 FAKE_CURL_TELEGRAM_EXIT=0
export FAKE_CURL_TELEGRAM_BODY='{"ok":true}'
export FAKE_CURL_LOG="${TEST_ROOT}/curl.log"

# Capture the actual transport text while retaining the normal fake responses.
# shellcheck disable=SC2329
curl() {
  local -a arguments=("$@")
  while (($#)); do
    case "$1" in
      --data)
        [[ "$2" != '{'* ]] || printf '%s\n' "$2" >> "$discord_payloads"
        shift 2 ;;
      --data-urlencode)
        [[ "$2" != text=* ]] || printf '%s\n' "${2#text=}" >> "$telegram_payloads"
        shift 2 ;;
      *) shift ;;
    esac
  done
  "$ROOT_DIR/tests/fixtures/fake-curl.sh" "${arguments[@]}"
}

# With no live arm, a failed registration leaves a synthetic arm at the reset
# event itself. A partial retry must preserve the real notification instead
# of creating and delivering an internal suppression marker for that event.
# Cover elapsed, equal, and originally future deadlines, including late retry.
for recovery_case in elapsed equal future; do
  use_test_runtime
  STATE_FILE="${RUNTIME_DIR}/state-${recovery_case}"
  ALERT_DELIVERIES_FILE="${RUNTIME_DIR}/deliveries-${recovery_case}.json"
  export FAKE_CURL_COUNT_DIR="${TEST_ROOT}/counts-${recovery_case}"
  discord_payloads="${TEST_ROOT}/discord-${recovery_case}.jsonl"
  telegram_payloads="${TEST_ROOT}/telegram-${recovery_case}.txt"
  DISCORD_WEBHOOK='https://discord.com/api/webhooks/123/token'
  TELEGRAM_BOT_TOKEN='' TELEGRAM_CHAT_ID=''
  sample_start=2000001060
  event_at=$((sample_start + 300))
  retry_at=$((event_at + 60))
  expected_label=unknown
  case "$recovery_case" in
    elapsed) next_deadline=$((event_at - 60)) ;;
    equal)
      next_deadline="$event_at"
      DISCORD_WEBHOOK=''
      TELEGRAM_BOT_TOKEN='123:token' TELEGRAM_CHAT_ID=-456 ;;
    future)
      next_deadline=$((event_at + 1800))
      retry_at=$((next_deadline + 1))
      expected_label="$(format_paris_timestamp "$next_deadline")"
      TELEGRAM_BOT_TOKEN='123:token' TELEGRAM_CHAT_ID=-456 ;;
  esac
  expected_message="⏱️ · 5h quota · Reset outside normal date · ${expected_label}"
  check_thresholds 26 100 unknown unknown "$((sample_start - 3600))" '' \
    "$sample_start" group-a >/dev/null
  # shellcheck disable=SC2001
  eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /saved_expire_observed_owner_cycle /')"
  expire_observed_owner_cycle() { return 1; }
  if check_thresholds 87 100 unknown unknown "$next_deadline" '' \
    "$event_at" group-a >/dev/null 2>&1; then
    fail "failed observed reset registration was accepted"
  fi
  [[ ! -e "$FAKE_CURL_COUNT_DIR" ]] || fail "registration failure emitted HTTP"
  # shellcheck disable=SC2001
  eval "$(declare -f saved_expire_observed_owner_cycle | sed '1s/^saved_expire_observed_owner_cycle /expire_observed_owner_cycle /')"

  check_thresholds '' 100 unknown unknown '' '' "$retry_at" group-a >/dev/null
  check_thresholds '' 100 unknown unknown '' '' "$((retry_at + 1))" group-a >/dev/null
  assert_eq 0 "$(awk -F= '$1 == "pending_consumed_5h_reset_at" {print $2}' "$STATE_FILE")" \
    "delivered observed reset retained its pending intent"
  python3 - "$ALERT_DELIVERIES_FILE" "$event_at" "$expected_message" \
    "$discord_payloads" "$telegram_payloads" "$DISCORD_WEBHOOK" <<'PY'
import json
import pathlib
import sys

journal, event_at, message, discord_path, telegram_path, discord = sys.argv[1:]
rows = json.loads(pathlib.Path(journal).read_text(encoding="utf-8"))["alerts"]
rows = [row for row in rows if row["kind"] == "reset"
        and row["event_data"]["reset_epoch"] == int(event_at)]
assert len(rows) == 1, rows
row = rows[0]
assert row["message"] == message, row
assert row["created_at"] == int(event_at), row
assert row["status"] == "delivered", row
assert row["terminal_reason"] == "delivered", row
assert all(channel["status"] == "delivered" and channel["attempt_count"] == 1
           for channel in row["channels"].values()), row
discord_messages = ([json.loads(line)["content"]
                     for line in pathlib.Path(discord_path).read_text(encoding="utf-8").splitlines()]
                    if pathlib.Path(discord_path).exists() else [])
telegram_messages = (pathlib.Path(telegram_path).read_text(encoding="utf-8").splitlines()
                     if pathlib.Path(telegram_path).exists() else [])
assert discord_messages == ([message] if discord else []), discord_messages
assert telegram_messages == ([message] if "telegram" in row["channels"] else []), telegram_messages
PY
done

printf 'PASS: consumed observed reset recovery tests\n'
