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
    'grep -Eq "^(attempted|pending|suppressed)_script_(5h|weekly).*[=,][a-f0-9]{24}" "$STATE_FILE_FOR_HOOK" && journal_state=present' \
    'secret_state="${DISCORD_WEBHOOK-unset}:${TELEGRAM_BOT_TOKEN-unset}:${TELEGRAM_CHAT_ID-unset}:${GITHUB_PAT-unset}:${GITHUB_GIST_ID-unset}"' \
    'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$CODEX_ALERT_THRESHOLD" "$CODEX_ALERT_WINDOW" "$CODEX_ALERT_EVENT" "$CODEX_ALERT_RULE_INDEX" "$PWD" "$secret_state" "$stdin_state" "$journal_state" "$CODEX_ALERT_REMAINING_PCT" "$CODEX_ALERT_RESET_AT" "$CODEX_ALERT_RESET_LABEL" "$CODEX_ALERT_SCRAPED_AT" "$CODEX_ALERT_MESSAGE" "$CODEX_ALERT_ACTION_ID" >> "$HOOK_LOG"' \
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
assert_contains "$first_line" '|threshold|' "first hook event was not recorded"
[[ "$(awk -F'|' '{print $14}' <<<"$first_line")" =~ ^[a-f0-9]{24}$ ]] \
  || fail "stable hook action ID was not exposed"

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

# A 100% -> 100% deadline advance is an observed 5-hour reset and runs the
# reset hook once with the observation as its event anchor.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
old_five_deadline=$((now + 300))
new_five_deadline=$((old_five_deadline + 15 * 60))
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 900))" group-a
check_thresholds 100 100 later later "$new_five_deadline" '' "$((now + 1800))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "observed 5h reset script was replayed"
assert_contains "$(head -n 1 "$HOOK_LOG")" '|5h|reset|1|' "observed 5h reset event contract"
assert_contains "$(head -n 1 "$HOOK_LOG")" "|eof|present|100|$((now + 900))|later|$((now + 900))|" "observed reset hook context"
assert_contains "$(head -n 1 "$HOOK_LOG")" "|$((now + 900))|" "observed reset was not anchored to its observation"

# A crash after the durable pending intent but before run_alert_script must
# leave the action non-terminal. The restart retries the same local-only reset
# hook; it must not create a network reset occurrence. The stable rule ID is
# exposed so a hook can deduplicate an effect if it crashed after doing work
# but before the completion state was persisted.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
crash_old_five_deadline=$((now + 300))
crash_new_five_deadline=$((crash_old_five_deadline + 900))
check_thresholds 100 100 later later "$crash_old_five_deadline" '' "$now" group-a
(
  # shellcheck disable=SC2329
  run_alert_script() { exit 99; }
  check_thresholds 100 100 later later "$crash_new_five_deadline" '' "$((now + 900))" group-a
) >/dev/null 2>&1 || true
crash_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
assert_eq "$crash_action_id" "$(state_value pending_script_5h_reset_actions)" \
  "crash window did not preserve a pending local hook intent"
assert_eq "" "$(state_value attempted_script_5h_reset_actions)" \
  "crash window marked the local hook completed before execution"
[[ ! -e "$HOOK_LOG" ]] || fail "crash window executed the local hook before restart"
python3 - "$ALERT_DELIVERIES_FILE" <<'PYEOF'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))["alerts"]
assert not any(item["kind"] == "reset" and item["status"] == "pending" for item in items), items
PYEOF
check_thresholds 100 100 later later "$crash_new_five_deadline" '' "$((now + 901))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "restart did not retry the pending local hook"
assert_eq "" "$(state_value pending_script_5h_reset_actions)" \
  "successful local hook remained pending"
assert_eq "$crash_action_id" "$(state_value attempted_script_5h_reset_actions)" \
  "successful local hook was not marked completed"
check_thresholds 100 100 later later "$crash_new_five_deadline" '' "$((now + 1800))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "completed local hook was replayed"

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

# Expiry failures must not consume the observed 5h proof or run its hook.  The
# next identical observation retries the invalidation and then executes the
# one-shot hook exactly once.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
retry_old_five_deadline=$((now + 3600))
retry_new_five_deadline=$((retry_old_five_deadline + 900))
check_thresholds 100 100 later unknown "$retry_old_five_deadline" '' "$now" group-a
# Inject failure at the atomic observed-reset transaction actually used by
# monitor.sh.  The old invalidate_pending_thresholds_for_owner hook is no
# longer on this path.
# shellcheck disable=SC2317,SC2329,SC2001
eval "$(declare -f expire_observed_owner_cycle | sed '1s/^expire_observed_owner_cycle /expire_observed_owner_cycle_original /')"
expire_observed_owner_cycle() { return 1; }
if check_thresholds 100 100 later unknown "$retry_new_five_deadline" '' "$((now + 900))" group-a >/dev/null 2>&1; then
  fail "failed observed reset invalidation was accepted"
fi
[[ ! -e "$HOOK_LOG" ]] || fail "failed observed reset invalidation ran a hook"
assert_eq "$retry_old_five_deadline" "$(state_value observed_5h_reset_at)" \
  "failed observed reset advanced the baseline"
eval "$(declare -f expire_observed_owner_cycle_original | sed '1s/^expire_observed_owner_cycle_original /expire_observed_owner_cycle /')"
check_thresholds 100 100 later unknown "$retry_new_five_deadline" '' "$((now + 901))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "successful observed reset hook did not execute"
check_thresholds 100 100 later unknown "$retry_new_five_deadline" '' "$((now + 1800))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "successful observed reset hook was replayed"

# Partial data from another group cannot cross script thresholds.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='weekly:50'
validate_config
check_thresholds 100 80 unknown later '' "$old_weekly_deadline" "$now" group-a
check_thresholds 100 40 unknown unknown '' '' "$((now + 1))" group-b
[[ ! -e "$HOOK_LOG" ]] || fail "partial observation crossed limit groups"

# A partial 5h row from another group cannot cross network or script
# thresholds, because it has no complete reset identity to compare.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
check_thresholds 100 100 later later "$old_five_deadline" '' "$now" group-a
check_thresholds 40 100 unknown unknown '' '' "$((now + 1))" group-b
[[ ! -e "$HOOK_LOG" ]] || fail "partial 5h observation crossed limit groups"

# A complete A -> partial B -> complete A sequence starts a fresh live
# baseline for both windows; neither observed reset hook may cross the gap.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:reset,weekly:reset'
validate_config
continuity_old_reset=$((now + 3600))
continuity_new_reset=$((continuity_old_reset + 900))
check_thresholds 100 100 later later "$continuity_old_reset" "$continuity_old_reset" "$now" group-a
check_thresholds 80 80 unknown unknown '' '' "$((now + 1))" group-b
check_thresholds 100 100 later later "$continuity_new_reset" "$continuity_new_reset" "$((now + 2))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "live partial owner switch ran a reset hook"
[[ ! -e "$NOTIFICATION_LOG" ]] || fail "live partial owner switch sent a reset notification"

# A loaded ownerless legacy state must also suppress local 5h hooks for a
# partial sample; there is no durable group identity to compare yet.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
ALERT_THRESHOLDS=50
printf '%s\n' \
  'state_version=4' 'prev_5h_pct=100' 'prev_weekly_pct=100' \
  'five_h_armed_reset_at=0' 'weekly_armed_reset_at=0' \
  'pending_5h_threshold=' 'pending_weekly_threshold=' > "$STATE_FILE"
check_thresholds 40 100 unknown unknown '' '' "$((now + 2))" group-b
[[ ! -e "$HOOK_LOG" ]] || fail "ownerless legacy partial observation ran a 5h hook"

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

# Script failures and timeouts remain pending for retry, do not prevent later
# actions for the same threshold, and successful actions are not replayed.
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
assert_eq "$((before_retry + 1))" "$(wc -l < "$HOOK_LOG")" "failed script action was not retried"

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
assert_eq 5 "$(state_value state_version)" "alert state was not upgraded to version 5"
assert_eq 1 "$(state_value script_tracking_initialized)" "script tracking was not initialized"

# ALERTS_ENABLED=0 journals script actions and advances their baseline without
# executing the configured hook or replaying the disabled crossing later.
reset_case
ALERTS_ENABLED=0
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$HOOK_ONE"
# shellcheck disable=SC2034
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
check_thresholds 80 100 later unknown "$((now + 300))" '' "$now"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 1))"
[[ ! -e "$HOOK_LOG" ]] || fail "disabled alert script executed"
assert_eq 40 "$(state_value script_prev_5h_pct)" "disabled script baseline did not advance"
ALERTS_ENABLED=1
check_thresholds 30 100 later unknown "$((now + 300))" '' "$((now + 2))"
[[ ! -e "$HOOK_LOG" ]] || fail "disabled-period script action replayed after re-enable"

# An observed 100% -> 100% 5-hour reset is acknowledged while alerts are
# disabled: the hook action is journaled but not executed, and re-enabling
# alerts must not replay that action.
reset_case
ALERTS_ENABLED=0
# shellcheck disable=SC2034
ALERT_SCRIPT_1="$HOOK_ONE"
# shellcheck disable=SC2034
ALERT_SCRIPT_1_EVENTS='5h:reset'
validate_config
old_five_deadline=$((now + 300))
new_five_deadline=$((old_five_deadline + 900))
check_thresholds 100 100 later unknown "$old_five_deadline" '' "$now" group-a
check_thresholds 100 100 later unknown "$new_five_deadline" '' "$((now + 900))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "disabled observed 5h reset executed its hook"
[[ -n "$(state_value suppressed_script_5h_reset_actions)" ]] || fail "disabled observed 5h reset action was not recorded as suppressed"
assert_eq "$((now + 900))" "$(state_value script_5h_reset_attempted_at)" "disabled observed reset anchor was not persisted"
ALERTS_ENABLED=1
check_thresholds 100 100 later unknown "$new_five_deadline" '' "$((now + 1800))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "re-enabled alerts replayed the disabled observed 5h reset hook"

printf 'PASS: monitor alert script tests\n'
