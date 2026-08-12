#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

HOOK_LOG="${TEST_ROOT}/hook.log"
NOTIFICATION_LOG="${TEST_ROOT}/notifications.log"
STATE_FILE_FOR_HOOK="$STATE_FILE"
export HOOK_LOG STATE_FILE_FOR_HOOK

HOOK_ONE="${TEST_ROOT}/hooks with spaces/record one.sh"
HOOK_TWO="${TEST_ROOT}/hooks with spaces/record two.sh"
FAIL_HOOK="${TEST_ROOT}/hooks with spaces/fail.sh"
SLOW_HOOK="${TEST_ROOT}/hooks with spaces/slow.sh"
CRASH_STATE_HOOK="${TEST_ROOT}/hooks with spaces/capture state.sh"
CRASH_STATE="${TEST_ROOT}/hook-journal.state"
mkdir -p "$(dirname "$HOOK_ONE")"

# Generated fixture scripts intentionally use single-quoted source strings.
# shellcheck disable=SC2016
write_recording_hook() {
  local path="$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'stdin_state=eof' \
    'if IFS= read -r value; then stdin_state=data; fi' \
    'journal_state=missing' \
    'grep -Eq "^attempted_script_(5h|weekly).*[=,][a-f0-9]{24}" "$STATE_FILE_FOR_HOOK" && journal_state=present' \
    'secret_state="${DISCORD_WEBHOOK-unset}:${TELEGRAM_BOT_TOKEN-unset}:${TELEGRAM_CHAT_ID-unset}:${GITHUB_PAT-unset}:${GITHUB_GIST_ID-unset}"' \
    'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$CODEX_ALERT_THRESHOLD" "$CODEX_ALERT_WINDOW" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_RULE_INDEX" "$PWD" "$secret_state" "$stdin_state" "$journal_state" "$CODEX_ALERT_REMAINING_PCT" "$CODEX_ALERT_RESET_AT" "$CODEX_ALERT_RESET_LABEL" "$CODEX_ALERT_SCRAPED_AT" "$CODEX_ALERT_MESSAGE" >> "$HOOK_LOG"' \
    > "$path"
  chmod 700 "$path"
}

write_recording_hook "$HOOK_ONE"
write_recording_hook "$HOOK_TWO"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "fail|%s|%s\n" "$CODEX_ALERT_THRESHOLD" "$CODEX_ALERT_RULE_INDEX" >> "$HOOK_LOG"' 'exit 7' > "$FAIL_HOOK"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 3' > "$SLOW_HOOK"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'cp "$STATE_FILE_FOR_HOOK" "$CRASH_STATE"' > "$CRASH_STATE_HOOK"
chmod 700 "$FAIL_HOOK" "$SLOW_HOOK" "$CRASH_STATE_HOOK"
export CRASH_STATE

send_alert() {
  printf '%s\n' "$1" >> "$NOTIFICATION_LOG"
  return 0
}

state_value() {
  local wanted="$1"
  awk -F= -v wanted="$wanted" '$1 == wanted {print substr($0, index($0, "=") + 1)}' "$STATE_FILE"
}

count_file_lines() {
  [[ -f "$1" ]] && wc -l < "$1" || printf '0\n'
}

reset_case() {
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$HOOK_LOG" "$NOTIFICATION_LOG"
  monitor_defaults
  ALERT_THRESHOLDS=0
}

now=2000000000
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:75,5h:50,5h:25,weekly:50'
ALERT_SCRIPT_2="$HOOK_TWO"
ALERT_SCRIPT_2_EVENTS='5h:50'
validate_config

# Exported monitor credentials must be removed from the hook environment.
export DISCORD_WEBHOOK=discord-secret TELEGRAM_BOT_TOKEN=telegram-secret TELEGRAM_CHAT_ID=123
export GITHUB_PAT=github-secret GITHUB_GIST_ID=abc123

check_thresholds 80 80 later later "$((now + 300))" "$((now + 3600))" "$now"
[[ ! -e "$HOOK_LOG" ]] || fail "first script observation executed an action"
check_thresholds 20 20 later later "$((now + 300))" "$((now + 3600))" "$((now + 1))"
assert_eq 5 "$(wc -l < "$HOOK_LOG")" "multi-threshold action count"
actual_order="$(awk -F'|' '{print $2 ":" $1 ":" $4}' "$HOOK_LOG")"
expected_order=$'5h:75:1\n5h:50:1\n5h:50:2\n5h:25:1\nweekly:50:1'
assert_eq "$expected_order" "$actual_order" "script action ordering"
assert_eq 0 "$(count_file_lines "$NOTIFICATION_LOG")" "independent script thresholds sent notifications"

first_line="$(head -n 1 "$HOOK_LOG")"
assert_contains "$first_line" "|threshold|1|$(dirname "$HOOK_ONE")|unset:unset:unset:unset:unset|eof|present|20|" "hook environment contract"
assert_contains "$first_line" '|later|' "reset label was not exposed"

# An oscillation around an already attempted level does not replay it.
check_thresholds 30 20 later later "$((now + 300))" "$((now + 3600))" "$((now + 2))"
check_thresholds 20 20 later later "$((now + 300))" "$((now + 3600))" "$((now + 3))"
assert_eq 5 "$(wc -l < "$HOOK_LOG")" "threshold oscillation replayed a script"

# A reset runs once, clears the threshold journal, and permits the next cycle.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset,5h:50'
validate_config
check_thresholds 80 100 later unknown "$((now + 10))" '' "$now"
check_thresholds 100 100 unknown unknown '' '' "$((now + 11))"
check_thresholds 100 100 unknown unknown '' '' "$((now + 12))"
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "reset script was not deduplicated"
assert_contains "$(head -n 1 "$HOOK_LOG")" '|5h|reset|1|' "reset event contract"
check_thresholds 80 100 later unknown "$((now + 500))" '' "$((now + 20))"
check_thresholds 40 100 later unknown "$((now + 500))" '' "$((now + 21))"
assert_eq 2 "$(wc -l < "$HOOK_LOG")" "new cycle threshold did not execute"
assert_contains "$(tail -n 1 "$HOOK_LOG")" '50|5h|threshold|1|' "new cycle threshold context"

# An observed early weekly refill follows the same notification and one-shot
# script path as a scheduled reset.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='weekly:reset'
validate_config
old_weekly_deadline=$((now + 4 * 24 * 60 * 60))
new_weekly_deadline=$((old_weekly_deadline + 3 * 24 * 60 * 60))
check_thresholds 100 28 unknown later '' "$old_weekly_deadline" "$now"
check_thresholds 100 100 unknown later '' "$new_weekly_deadline" "$((now + 900))"
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "observed weekly reset script did not execute"
assert_contains "$(head -n 1 "$HOOK_LOG")" '|weekly|reset|1|' "observed weekly reset event contract"
assert_eq 1 "$(wc -l < "$NOTIFICATION_LOG")" "observed weekly reset notification was not sent"
check_thresholds 100 100 unknown later '' "$new_weekly_deadline" "$((now + 1800))"
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "observed weekly reset script was replayed"

# Partial data from another group cannot cross script thresholds.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='weekly:50'
validate_config
check_thresholds 100 80 unknown later '' "$old_weekly_deadline" "$now" group-a
check_thresholds 100 40 unknown unknown '' '' "$((now + 1))" group-b
[[ ! -e "$HOOK_LOG" ]] || fail "partial observation crossed limit groups"

# The hook journal contains the current complete observation. Restoring that
# crash point must still allow the following refill to be detected as a reset.
reset_case
ALERT_SCRIPT_1="$CRASH_STATE_HOOK"
ALERT_SCRIPT_1_EVENTS='weekly:50'
validate_config
# Invoked through register_network_alert's compatibility seam.
# shellcheck disable=SC2317,SC2329
send_alert() { printf '%s\n' "$1" >> "$NOTIFICATION_LOG"; return 1; }
check_thresholds 100 100 unknown later '' "$old_weekly_deadline" "$now" group-a
check_thresholds 100 40 unknown later '' "$old_weekly_deadline" "$((now + 1))" group-a >/dev/null || true
cp "$CRASH_STATE" "$STATE_FILE"
# Invoked through register_network_alert's compatibility seam.
# shellcheck disable=SC2317,SC2329
send_alert() { printf '%s\n' "$1" >> "$NOTIFICATION_LOG"; return 0; }
check_thresholds 100 100 unknown later '' "$((old_weekly_deadline + 30 * 60))" "$((now + 2))" group-a
assert_contains "$(tail -n 1 "$NOTIFICATION_LOG")" "weekly limit reset" "hook journal missed the following reset"

# Notification retries remain independent from the one-shot script journal.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
# Invoked through register_network_alert's compatibility seam.
# shellcheck disable=SC2317,SC2329
send_alert() { printf '%s\n' "$1" >> "$NOTIFICATION_LOG"; return 1; }
check_thresholds 80 100 later unknown "$((now + 10))" '' "$now" >/dev/null || true
check_thresholds 100 100 unknown unknown '' '' "$((now + 11))" >/dev/null || true
check_thresholds 100 100 unknown unknown '' '' "$((now + 12))" >/dev/null || true
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "failed notification replayed reset script"
assert_eq 2 "$(wc -l < "$NOTIFICATION_LOG")" "notification was not retried"

# Script failures and timeouts warn once, do not fail alert processing, and do
# not prevent later actions for the same threshold.
reset_case
ALERT_SCRIPT_TIMEOUT_SECONDS=1
# Indexed variables are consumed indirectly by monitor.sh.
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$FAIL_HOOK"
ALERT_SCRIPT_1_EVENTS='5h:50'
# shellcheck disable=SC2034
ALERT_SCRIPT_2="$SLOW_HOOK"
# shellcheck disable=SC2034
ALERT_SCRIPT_2_EVENTS='5h:50'
# shellcheck disable=SC2034
ALERT_SCRIPT_3="$HOOK_ONE"
# shellcheck disable=SC2034
ALERT_SCRIPT_3_EVENTS='5h:50'
validate_config
send_alert() { return 0; }
check_thresholds 80 100 later unknown "$((now + 300))" '' "$now"
OUTPUT_LOG="${TEST_ROOT}/script-output.log"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 1))" >"$OUTPUT_LOG" 2>&1
assert_contains "$(<"$OUTPUT_LOG")" 'failed with exit code 7' "script failure warning missing"
assert_contains "$(<"$OUTPUT_LOG")" 'timed out after 1s' "script timeout warning missing"
assert_contains "$(<"$HOOK_LOG")" 'fail|50|1' "failing script did not run"
assert_contains "$(<"$HOOK_LOG")" '50|5h|threshold|3|' "script after failures did not run"
before_retry="$(wc -l < "$HOOK_LOG")"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 2))" >/dev/null
assert_eq "$before_retry" "$(wc -l < "$HOOK_LOG")" "failed script action was retried"

# Version 2 state migrates without replaying a threshold already below baseline.
reset_case
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$HOOK_ONE"
# shellcheck disable=SC2034
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
printf 'state_version=2\nprev_5h_pct=40\nprev_weekly_pct=100\n' > "$STATE_FILE"
check_thresholds 40 100 later unknown '' '' "$now"
[[ ! -e "$HOOK_LOG" ]] || fail "state migration replayed a historical threshold"
assert_eq 4 "$(state_value state_version)" "alert state was not upgraded to version 4"
assert_eq 1 "$(state_value script_tracking_initialized)" "script tracking was not initialized"

printf 'PASS: monitor alert script tests\n'
