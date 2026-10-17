#!/usr/bin/env bash
# Numbered hook configuration is consumed indirectly by monitor validation.
# shellcheck disable=SC2034
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
ALERT_THRESHOLDS=0

send_alert() { printf '%s\n' "$1" >> "$TEST_ROOT/notifications.log"; }
cat > "$TEST_ROOT/hook.sh" <<'HOOK'
#!/usr/bin/env bash
if [[ -e "$(dirname "$0")/fail-hook" ]]; then
  rm -f "$(dirname "$0")/fail-hook"
  exit 7
fi
printf '%s|%s|%s\n' "$CODEX_ALERT_WINDOW" "$CODEX_ALERT_RESET_AT" "$CODEX_ALERT_SCRAPED_AT" >> "$(dirname "$0")/hooks.log"
HOOK
chmod 700 "$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1="$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1_EVENTS=weekly:reset
validate_config

sample() {
  check_thresholds 50 "${3:-100}" later later 1792056609 "$2" "$1" "${4:-group-a}"
}

# Replay the incident across separate check_thresholds invocations (all state
# is loaded from disk each time). The first advanced deadline is provisional.
sample 1792044001 1792473311
sample 1792044901 1792649701
[[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'unconfirmed full cycle ran its hook'
[[ ! -e "$TEST_ROOT/notifications.log" ]] || fail 'unconfirmed full cycle sent an alert'
sample 1792045801 1792649711
assert_eq 'weekly|1792044901|1792045801' "$(cat "$TEST_ROOT/hooks.log")" 'confirmed cycle hook context'
assert_contains "$(cat "$TEST_ROOT/notifications.log")" 'Cycle renewed' 'full cycle was presented as a measured refill'
sample 1792046701 1792649712
assert_eq 1 "$(wc -l < "$TEST_ROOT/hooks.log")" 'confirmed full cycle hook replayed'
assert_eq 1 "$(grep -c 'Cycle renewed' "$TEST_ROOT/notifications.log")" 'full cycle notification replayed'

# Failure after the hook intent is durable retries the original full-cycle
# action, including after a partial observation, without another reset alert.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
sample 1792044001 1792473311
sample 1792044901 1792649701
touch "$TEST_ROOT/fail-hook"
sample 1792045801 1792649711 >/dev/null 2>&1 || true
[[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'failed hook was recorded as successful'
sample 1792046701 ''
assert_contains "$(cat "$TEST_ROOT/hooks.log")" 'weekly|1792044901|' 'pending hook lost its full-cycle anchor'
sample 1792047601 1792649711
assert_eq 1 "$(wc -l < "$TEST_ROOT/hooks.log")" 'recovered full cycle hook replayed'

# Paused alerts acknowledge a confirmed full cycle instead of replaying its
# network delivery or hook when alerts resume.
rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
ALERTS_ENABLED=0
sample 1792044001 1792473311
sample 1792044901 1792649701
sample 1792045801 1792649711
ALERTS_ENABLED=1
sample 1792046701 1792649711
[[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'paused full cycle hook replayed'
[[ ! -e "$TEST_ROOT/notifications.log" ]] || fail 'paused full cycle notice replayed'

# A partial or foreign observation cancels an outstanding candidate.
for interruption in partial foreign stale reverted; do
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
  sample 1792044001 1792473311
  sample 1792044901 1792649701
  case "$interruption" in
    partial) sample 1792045201 '' ;;
    foreign) sample 1792045201 1792649701 100 group-b ;;
    stale) sample 1792048902 1792649701 ;;
    reverted) sample 1792045201 1792473311 ;;
  esac
  sample 1792049802 1792649701
  [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail "$interruption candidate ran a hook"
done

printf 'PASS: confirmed weekly full-quota renewals\n'
