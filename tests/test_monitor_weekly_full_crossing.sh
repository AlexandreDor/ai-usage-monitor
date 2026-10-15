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
printf '%s\n' "$CODEX_ALERT_RESET_AT" >> "$(dirname "$0")/hooks.log"
HOOK
chmod 700 "$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1="$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1_EVENTS=weekly:reset
validate_config
sample() {
  check_thresholds "$five_pct" "${3:-100}" later later "${4:-25000}" "$2" "$1" group-a
}

for scenario in full consumed paused failed interrupted; do
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
  ALERTS_ENABLED=1
  five_pct=50
  [[ "$scenario" == paused ]] && ALERTS_ENABLED=0
  [[ "$scenario" == interrupted ]] && five_pct=100
  # Consumption arms the old deadline, then rounding leaves quota at 100%.
  sample 10000 14000 99
  sample 10900 14000
  sample 13600 20000
  [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'provisional renewal ran a hook'
  confirmation_pct=100
  [[ "$scenario" == consumed ]] && confirmation_pct=99
  [[ "$scenario" == failed ]] && touch "$TEST_ROOT/fail-hook"
  if [[ "$scenario" == interrupted ]]; then
    eval "$(declare -f persist_observed_5h_intent | sed '1s/^persist_observed_5h_intent /original_five_intent /')"
    persist_observed_5h_intent() { original_five_intent "$@"; return 1; }
    if sample 14500 20010 100 29000; then
      fail 'simulated 5h interruption was not reached'
    fi
    eval "$(declare -f original_five_intent | sed '1s/^original_five_intent /persist_observed_5h_intent /')"
  else
    sample 14500 20010 "$confirmation_pct"
  fi
  ALERTS_ENABLED=1
  sample 15400 20011 "$confirmation_pct" 29000
  sample 16300 20012 "$confirmation_pct" 29000
  if [[ "$scenario" == paused ]]; then
    [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'paused renewal replayed a hook'
    [[ ! -e "$TEST_ROOT/notifications.log" ]] || fail 'paused renewal replayed an alert'
  else
    assert_eq 13600 "$(cat "$TEST_ROOT/hooks.log")" "$scenario renewal must run only the original observation's hook"
    assert_eq 1 "$(grep -c 'Cycle renewed' "$TEST_ROOT/notifications.log")" "$scenario renewal must notify once"
    [[ "$(cat "$TEST_ROOT/notifications.log")" != *'A new usage cycle is available.'* ]] \
      || fail "$scenario renewal also delivered the superseded scheduled reset"
  fi
done

printf 'PASS: weekly confirmation supersedes a crossed scheduled deadline\n'
