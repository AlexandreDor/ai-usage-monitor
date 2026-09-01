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
  rm -f "$STATE_FILE" "$STATE_FILE.interrupted" "$ALERT_DELIVERIES_FILE" \
    "$HOOK_LOG" "$NOTIFICATION_LOG"
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
# Keep this observed-refill fixture before the planned deadline; crossed
# deadlines are scheduled crossings and are covered by the focused cases.
old_five_deadline=$((now + 1800))
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
crash_old_five_deadline=$((now + 1800))
crash_new_five_deadline=$((crash_old_five_deadline + 900))
check_thresholds 100 100 later later "$crash_old_five_deadline" '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
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

# The same autonomous pending context must recover a weekly observed reset even
# after the weekly arm was acknowledged and cleared before the hook launch.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='weekly:reset'
validate_config
crash_old_weekly_deadline=$((now + 4 * 24 * 60 * 60))
crash_new_weekly_deadline=$((crash_old_weekly_deadline + 3 * 24 * 60 * 60))
check_thresholds 100 28 unknown later '' "$crash_old_weekly_deadline" "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 100 100 unknown later '' "$crash_new_weekly_deadline" "$((now + 900))" group-a
) >/dev/null 2>&1 || true
weekly_crash_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
assert_eq "$weekly_crash_action_id" "$(state_value pending_script_weekly_reset_actions)" \
  "weekly crash did not preserve a pending local hook intent"
assert_eq "" "$(state_value attempted_script_weekly_reset_actions)" \
  "weekly crash marked the local hook completed before execution"
assert_eq "$((now + 900))" "$(state_value weekly_armed_reset_at)" \
  "weekly crash did not retain the reset anchor for hook recovery"
[[ ! -e "$HOOK_LOG" ]] || fail "weekly crash window executed the local hook before restart"
check_thresholds 100 100 unknown later '' "$crash_new_weekly_deadline" "$((now + 901))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "weekly restart did not retry the pending local hook"
assert_eq "" "$(state_value pending_script_weekly_reset_actions)" \
  "successful weekly local hook remained pending"
assert_eq "$weekly_crash_action_id" "$(state_value attempted_script_weekly_reset_actions)" \
  "successful weekly local hook was not marked completed"
check_thresholds 100 100 unknown later '' "$crash_new_weekly_deadline" "$((now + 1800))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "completed weekly local hook was replayed"

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

# A successful hook whose completion journal write fails remains pending and is
# retried from its autonomous context; the completion retry is idempotent by
# action ID and does not create another threshold action.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
check_thresholds 80 100 later unknown "$((now + 300))" '' "$now"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_completion_original /')"
eval "$(declare -f run_alert_script | sed '1s/^run_alert_script /run_alert_script_completion_original /')"
completion_failure_marker="${TEST_ROOT}/completion-failure.marker"
# shellcheck disable=SC2034
persist_alert_state() {
  if [[ -e "$completion_failure_marker" ]]; then
    rm -f "$completion_failure_marker"
    return 1
  fi
  persist_alert_state_completion_original
}
# shellcheck disable=SC2317,SC2329
run_alert_script() {
  run_alert_script_completion_original "$@"
  : > "$completion_failure_marker"
}
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 1))" >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_completion_original | sed '1s/^persist_alert_state_completion_original /persist_alert_state /')"
eval "$(declare -f run_alert_script_completion_original | sed '1s/^run_alert_script_completion_original /run_alert_script /')"
assert_eq 1 "$(wc -l < "$HOOK_LOG")" "completion failure did not execute the hook"
assert_eq "" "$(state_value attempted_script_5h_actions)" \
  "completion failure acknowledged the hook prematurely"
assert_eq "${ALERT_SCRIPT_RULE_IDS[0]}" "$(state_value pending_script_5h_actions)" \
  "completion failure did not retain the pending hook"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 2))"
assert_eq 2 "$(wc -l < "$HOOK_LOG")" "completion failure was not retried"
assert_eq "" "$(state_value pending_script_5h_actions)" \
  "completion retry remained pending"
assert_eq "${ALERT_SCRIPT_RULE_IDS[0]}" "$(state_value attempted_script_5h_actions)" \
  "completion retry was not acknowledged"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 3))"
assert_eq 2 "$(wc -l < "$HOOK_LOG")" "completed threshold hook was replayed"

# An owner switch must tombstone a pending local hook before clearing the
# in-memory action. Simulate the critical state write after that tombstone:
# the old owner intent remains on disk, but its return must acknowledge it as
# interrupted without invoking the hook or a notification transport.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
check_thresholds 80 100 later unknown "$((now + 300))" '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 1))" group-a
) >/dev/null 2>&1 || true
owner_switch_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
assert_eq "$owner_switch_action_id" "$(state_value pending_script_5h_actions)" \
  "owner switch setup did not leave a pending hook"
owner_switch_tombstone_marker="${TEST_ROOT}/owner-switch-tombstone.marker"
owner_switch_failure_marker="${TEST_ROOT}/owner-switch-failure.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_owner_switch_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  # The first write with an interruption tombstone is allowed through and
  # records that the next critical write must fail. This leaves the durable
  # tombstone alongside the old pending intent at the crash boundary.
  if [[ -n "${interrupted_script_contexts:-}" \
    && ! -e "$owner_switch_tombstone_marker" ]]; then
    persist_alert_state_owner_switch_original
    : > "$owner_switch_tombstone_marker"
    return 0
  fi
  if [[ -e "$owner_switch_tombstone_marker" ]]; then
    : > "$owner_switch_failure_marker"
    return 1
  fi
  if [[ -e "$owner_switch_failure_marker" ]]; then
    return 1
  fi
  persist_alert_state_owner_switch_original
}
check_thresholds 80 100 later unknown "$((now + 300))" '' "$((now + 2))" group-b \
  >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_owner_switch_original | sed '1s/^persist_alert_state_owner_switch_original /persist_alert_state /')"
assert_contains "$(state_value interrupted_script_contexts)" "$owner_switch_action_id:" \
  "owner switch tombstone was not durable after the critical write failure"
assert_contains "$(state_value interrupted_script_identities)" "$owner_switch_action_id:" \
  "owner switch stable identity was not durable after the critical write failure"
assert_eq "$owner_switch_action_id" "$(state_value pending_script_5h_actions)" \
  "failure boundary did not preserve the old pending hook intent"
check_thresholds 40 100 later unknown "$((now + 300))" '' "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "interrupted owner hook was replayed after owner return"
assert_eq "" "$(state_value pending_script_5h_actions)" \
  "interrupted owner hook remained pending after acknowledgement"
assert_eq "$owner_switch_action_id" "$(state_value suppressed_script_5h_actions)" \
  "interrupted owner hook was not durably suppressed"
assert_eq 0 "$(count_file_lines "$NOTIFICATION_LOG")" \
  "owner switch recovery emitted an unexpected notification"

# If the initial interrupted-hook marker write fails, the old pending state is
# still durable. A separate fail-safe tombstone must make the return to A
# acknowledge the old action without replaying it.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
initial_marker_failure_deadline=$((now + 300))
check_thresholds 80 100 later unknown "$initial_marker_failure_deadline" '' \
  "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$initial_marker_failure_deadline" '' \
    "$((now + 1))" group-a
) >/dev/null 2>&1 || true
initial_marker_failure_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
initial_marker_failure_marker="${TEST_ROOT}/initial-marker-failure.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_initial_marker_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  if [[ -n "${interrupted_script_identities:-}" ]]; then
    : > "$initial_marker_failure_marker"
    return 1
  fi
  persist_alert_state_initial_marker_original
}
check_thresholds 80 100 later unknown "$initial_marker_failure_deadline" '' \
  "$((now + 2))" group-b >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_initial_marker_original | sed '1s/^persist_alert_state_initial_marker_original /persist_alert_state /')"
assert_eq "$initial_marker_failure_action_id" "$(state_value pending_script_5h_actions)" \
  "initial marker failure did not preserve the old pending action"
[[ -f "$STATE_FILE.interrupted" ]] || fail "initial marker failure did not create a fail-safe tombstone"
check_thresholds 40 100 later unknown "$initial_marker_failure_deadline" '' \
  "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "initial marker persistence failure replayed the old hook"
assert_eq "$initial_marker_failure_action_id" "$(state_value suppressed_script_5h_actions)" \
  "initial marker failure did not suppress the old hook"
[[ ! -e "$STATE_FILE.interrupted" ]] || fail "fail-safe tombstone was not retired after durable acknowledgement"

# A second interruption of the same stable action ID must replace the older
# interrupted context in the fail-safe journal.  Otherwise restart merges the
# stale state marker, misses the newer owner/cycle identity, and replays the
# pending hook.  After that acknowledgement, a different owner/cycle remains
# a legitimate execution of the same configured rule.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
same_action_old_deadline=$((now + 2400))
same_action_new_deadline=$((same_action_old_deadline + 900))
check_thresholds 80 100 later unknown "$same_action_old_deadline" '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$same_action_old_deadline" '' \
    "$((now + 1))" group-a
) >/dev/null 2>&1 || true
same_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
check_thresholds 80 100 unknown unknown '' '' "$((now + 2))" group-b
same_action_first_contexts="$(state_value interrupted_script_contexts)"
same_action_first_identities="$(state_value interrupted_script_identities)"
assert_contains "$same_action_first_contexts" "$same_action_id:" \
  "first same-action interruption context was not retained"
assert_contains "$same_action_first_identities" "$same_action_id:" \
  "first same-action interruption identity was not retained"
check_thresholds 40 100 later unknown "$same_action_old_deadline" '' \
  "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "first same-action interruption was replayed"

# Establish a distinct A cycle and leave the same action pending again.
check_thresholds 80 100 later unknown "$same_action_new_deadline" '' \
  "$((now + 4))" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$same_action_new_deadline" '' \
    "$((now + 5))" group-a
) >/dev/null 2>&1 || true
same_action_second_contexts="$(state_value pending_script_contexts)"
same_action_second_context_entry="${same_action_second_contexts%%,*}"
same_action_second_context_encoded="${same_action_second_context_entry#*:}"
same_action_second_identity_encoded="$(alert_script_identity_from_context \
  "$same_action_second_context_encoded")"
same_action_second_identities="${same_action_id}:${same_action_second_identity_encoded}"
assert_contains "$same_action_second_contexts" "$same_action_id:" \
  "second same-action interruption setup lost its pending context"

same_action_marker="${TEST_ROOT}/same-action-marker.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_same_action_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  # Allow writes before the new marker is installed, then force the marker and
  # subsequent state writes to use the separate fail-safe journal.
  if [[ -n "${interrupted_script_contexts:-}" \
    && "$interrupted_script_contexts" != "$same_action_first_contexts" ]]; then
    : > "$same_action_marker"
    return 1
  fi
  if [[ -e "$same_action_marker" ]]; then
    return 1
  fi
  persist_alert_state_same_action_original
}
check_thresholds 80 100 unknown unknown '' '' "$((now + 6))" group-b \
  >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_same_action_original | sed '1s/^persist_alert_state_same_action_original /persist_alert_state /')"
same_action_failsafe_contexts="$(awk -F= '$1 == "interrupted_script_contexts" {print substr($0, index($0, "=") + 1)}' "$STATE_FILE.interrupted")"
same_action_failsafe_identities="$(awk -F= '$1 == "interrupted_script_identities" {print substr($0, index($0, "=") + 1)}' "$STATE_FILE.interrupted")"
assert_eq "$same_action_second_contexts" "$same_action_failsafe_contexts" \
  "second same-action interruption did not replace the fail-safe context"
assert_eq "$same_action_second_identities" "$same_action_failsafe_identities" \
  "second same-action interruption did not replace the fail-safe identity"
assert_eq "$same_action_first_contexts" "$(state_value interrupted_script_contexts)" \
  "state marker changed despite the forced second interruption write failure"

# Restart must acknowledge the newer pending context without running it.
check_thresholds 40 100 later unknown "$same_action_new_deadline" '' \
  "$((now + 7))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "newer same-action interruption was replayed after restart"
assert_eq "" "$(state_value pending_script_5h_actions)" \
  "newer same-action interruption remained pending after acknowledgement"
assert_eq "$same_action_id" "$(state_value suppressed_script_5h_actions)" \
  "newer same-action interruption was not suppressed after acknowledgement"
[[ ! -e "$STATE_FILE.interrupted" ]] || fail "same-action fail-safe marker was not retired"

# Clearing the old owner ledger on a real owner switch releases the stable rule
# ID for its distinct cycle; this invocation is legitimate and must execute.
check_thresholds 80 100 later unknown "$same_action_new_deadline" '' \
  "$((now + 8))" group-c
check_thresholds 40 100 later unknown "$same_action_new_deadline" '' \
  "$((now + 9))" group-c
assert_eq 1 "$(wc -l < "$HOOK_LOG")" \
  "legitimate distinct same-action cycle did not execute exactly once"
assert_contains "$(tail -n 1 "$HOOK_LOG")" "|$same_action_id" \
  "legitimate distinct cycle changed the stable action ID"

# A rich pending intent must retain its immutable identity even when a
# restored arm has lost its owner. Change only the mutable invocation fields
# at the crash boundary; returning to A must still suppress the old action.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
ownerless_context_old_deadline=$((now + 900))
check_thresholds 80 100 later unknown "$ownerless_context_old_deadline" '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$ownerless_context_old_deadline" '' \
    "$((now + 1))" group-a
) >/dev/null 2>&1 || true
ownerless_context_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
python3 - "$STATE_FILE" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["five_h_armed_limit_id"] = ""
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
ownerless_context_tombstone_marker="${TEST_ROOT}/ownerless-context-tombstone.marker"
ownerless_context_failure_marker="${TEST_ROOT}/ownerless-context-failure.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_ownerless_context_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  if [[ -n "${interrupted_script_identities:-}" \
    && ! -e "$ownerless_context_tombstone_marker" ]]; then
    persist_alert_state_ownerless_context_original
    : > "$ownerless_context_tombstone_marker"
    return 0
  fi
  if [[ -e "$ownerless_context_tombstone_marker" ]]; then
    : > "$ownerless_context_failure_marker"
    return 1
  fi
  persist_alert_state_ownerless_context_original
}
check_thresholds 80 100 later unknown "$ownerless_context_old_deadline" '' \
  "$((now + 2))" group-b >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_ownerless_context_original | sed '1s/^persist_alert_state_ownerless_context_original /persist_alert_state /')"
assert_contains "$(state_value interrupted_script_identities)" \
  "$ownerless_context_action_id:" \
  "ownerless rich context did not persist its stable identity"
assert_eq "$ownerless_context_action_id" "$(state_value pending_script_5h_actions)" \
  "ownerless rich context did not preserve the crash-boundary intent"

python3 - "$STATE_FILE" "$ownerless_context_action_id" \
  "$(canonicalize_alert_limit_id group-a)" \
  "limit:$(canonicalize_alert_limit_id group-a)|reset:${ownerless_context_old_deadline}" <<'PYEOF'
import base64
import json
import pathlib
import sys

path, action_id, limit_id, cycle_key = sys.argv[1:]
values = {}
for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value

result = []
for entry in values.get("pending_script_contexts", "").split(","):
    if not entry:
        continue
    item, encoded = entry.split(":", 1)
    padding = "=" * ((-len(encoded)) % 4)
    context = json.loads(base64.b64decode(encoded + padding).decode("utf-8"))
    if item == action_id:
        context.update(
            scraped_at=int(context["scraped_at"]) + 1000,
            remaining_pct="41",
            reset_label="changed after recovery",
            message="changed after recovery",
        )
        encoded = base64.b64encode(
            json.dumps(context, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        ).decode("ascii").rstrip("=")
    result.append(f"{item}:{encoded}")
values["pending_script_contexts"] = ",".join(result)

identity_entries = values.get("interrupted_script_identities", "").split(",")
identity = next(
    entry.split(":", 1)[1] for entry in identity_entries
    if entry.startswith(action_id + ":")
)
padding = "=" * ((-len(identity)) % 4)
decoded_identity = json.loads(base64.b64decode(identity + padding).decode("utf-8"))
assert decoded_identity == {"limit_id": limit_id, "cycle_key": cycle_key}, decoded_identity
# Avoid re-entering the ownerless-arm clearing branch on return; the durable
# identity is the recovery authority for the still-pending action.
values["five_h_armed_reset_at"] = "0"
values["five_h_armed_limit_id"] = ""
pathlib.Path(path).write_text(
    "".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8",
)
PYEOF
check_thresholds 40 100 later unknown "$ownerless_context_old_deadline" '' \
  "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "ownerless rich interrupted hook was replayed after mutable context changes"
assert_eq "" "$(state_value pending_script_5h_actions)" \
  "ownerless rich interrupted hook remained pending after acknowledgement"
assert_eq "$ownerless_context_action_id" "$(state_value suppressed_script_5h_actions)" \
  "ownerless rich interrupted hook was not suppressed"

# A legacy ID-only interruption is fail-closed only until its old pending list
# is acknowledged/retired. Its marker is consumed at that boundary, so the
# same action ID can execute in a new reset cycle.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
legacy_id_only_old_deadline=$((now + 1200))
check_thresholds 80 100 later unknown "$legacy_id_only_old_deadline" '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown "$legacy_id_only_old_deadline" '' \
    "$((now + 1))" group-a
) >/dev/null 2>&1 || true
legacy_id_only_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
python3 - "$STATE_FILE" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["pending_script_contexts"] = ""
values["five_h_armed_limit_id"] = ""
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
legacy_id_only_tombstone_marker="${TEST_ROOT}/legacy-id-only-tombstone.marker"
legacy_id_only_failure_marker="${TEST_ROOT}/legacy-id-only-failure.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_legacy_id_only_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  if [[ -n "${interrupted_script_actions:-}" \
    && ! -e "$legacy_id_only_tombstone_marker" ]]; then
    persist_alert_state_legacy_id_only_original
    : > "$legacy_id_only_tombstone_marker"
    return 0
  fi
  if [[ -e "$legacy_id_only_tombstone_marker" ]]; then
    : > "$legacy_id_only_failure_marker"
    return 1
  fi
  persist_alert_state_legacy_id_only_original
}
check_thresholds 80 100 later unknown "$legacy_id_only_old_deadline" '' \
  "$((now + 2))" group-b >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_legacy_id_only_original | sed '1s/^persist_alert_state_legacy_id_only_original /persist_alert_state /')"
assert_eq "$legacy_id_only_action_id" "$(state_value interrupted_script_actions)" \
  "legacy ID-only interruption did not persist its temporary quarantine"
assert_eq "$legacy_id_only_action_id" "$(state_value pending_script_5h_actions)" \
  "legacy ID-only crash boundary lost the pending intent"
python3 - "$STATE_FILE" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        values[key] = value
values["five_h_armed_reset_at"] = "0"
values["five_h_armed_limit_id"] = ""
path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
PYEOF
check_thresholds 40 100 later unknown '' '' \
  "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "legacy ID-only interrupted hook was replayed"
assert_eq "" "$(state_value interrupted_script_actions)" \
  "legacy ID-only quarantine was not consumed at the old-intent boundary"
assert_eq "$legacy_id_only_action_id" "$(state_value suppressed_script_5h_actions)" \
  "legacy ID-only interrupted hook was not suppressed"
legacy_id_only_new_deadline=$((now + 600))
check_thresholds 80 100 later unknown "$legacy_id_only_new_deadline" '' \
  "$((now + 4))" group-a
check_thresholds 100 100 unknown unknown '' '' \
  "$((legacy_id_only_new_deadline + 1))" group-a
check_thresholds 40 100 later unknown "$((legacy_id_only_new_deadline + 900))" '' \
  "$((legacy_id_only_new_deadline + 2))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" \
  "legacy ID-only quarantine blocked a legitimate new cycle"

# An unarmed threshold uses the owner/unarmed identity rather than a reset
# deadline. The old intent is suppressed after the switch, while a later reset
# cycle with a new deadline remains a legitimate, executable action.
reset_case
ALERT_SCRIPT_1="$HOOK_ONE"
ALERT_SCRIPT_1_EVENTS='5h:50'
validate_config
check_thresholds 80 100 later unknown '' '' "$now" group-a
(
  # shellcheck disable=SC2317,SC2329
  run_alert_script() {
    local crash_exit=99
    exit "$crash_exit"
  }
  check_thresholds 40 100 later unknown '' '' "$((now + 1))" group-a
) >/dev/null 2>&1 || true
unarmed_switch_action_id="${ALERT_SCRIPT_RULE_IDS[0]}"
assert_eq "$unarmed_switch_action_id" "$(state_value pending_script_5h_actions)" \
  "unarmed owner switch setup did not leave a pending hook"
unarmed_switch_tombstone_marker="${TEST_ROOT}/unarmed-switch-tombstone.marker"
unarmed_switch_failure_marker="${TEST_ROOT}/unarmed-switch-failure.marker"
eval "$(declare -f persist_alert_state | sed '1s/^persist_alert_state /persist_alert_state_unarmed_switch_original /')"
# shellcheck disable=SC2034
persist_alert_state() {
  if [[ -n "${interrupted_script_identities:-}" \
    && ! -e "$unarmed_switch_tombstone_marker" ]]; then
    persist_alert_state_unarmed_switch_original
    : > "$unarmed_switch_tombstone_marker"
    return 0
  fi
  if [[ -e "$unarmed_switch_tombstone_marker" ]]; then
    : > "$unarmed_switch_failure_marker"
    return 1
  fi
  if [[ -e "$unarmed_switch_failure_marker" ]]; then
    return 1
  fi
  persist_alert_state_unarmed_switch_original
}
check_thresholds 80 100 later unknown '' '' "$((now + 2))" group-b \
  >/dev/null 2>&1 || true
eval "$(declare -f persist_alert_state_unarmed_switch_original | sed '1s/^persist_alert_state_unarmed_switch_original /persist_alert_state /')"
assert_contains "$(state_value interrupted_script_identities)" "$unarmed_switch_action_id:" \
  "unarmed owner switch identity was not durable"
check_thresholds 40 100 later unknown '' '' "$((now + 3))" group-a
[[ ! -e "$HOOK_LOG" ]] || fail "unarmed interrupted owner hook was replayed"
assert_eq "$unarmed_switch_action_id" "$(state_value suppressed_script_5h_actions)" \
  "unarmed interrupted owner hook was not suppressed"

unarmed_new_cycle_deadline=$((now + 600))
check_thresholds 80 100 later unknown "$unarmed_new_cycle_deadline" '' "$((now + 4))" group-a
check_thresholds 100 100 unknown unknown '' '' "$((unarmed_new_cycle_deadline + 1))" group-a
check_thresholds 40 100 later unknown "$((unarmed_new_cycle_deadline + 900))" '' \
  "$((unarmed_new_cycle_deadline + 2))" group-a
assert_eq 1 "$(wc -l < "$HOOK_LOG")" \
  "new reset cycle was blocked by the old unarmed tombstone"
assert_contains "$(tail -n 1 "$HOOK_LOG")" \
  "|$((unarmed_new_cycle_deadline + 900))|" \
  "new reset cycle did not carry its own reset identity"

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
assert_eq 6 "$(state_value state_version)" "alert state was not upgraded to version 6"
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
old_five_deadline=$((now + 1800))
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
