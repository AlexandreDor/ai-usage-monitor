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
printf '%s\n' "$CODEX_ALERT_RESET_AT" >> "$(dirname "$0")/hooks.log"
HOOK
chmod 700 "$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1="$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1_EVENTS=weekly:reset
validate_config
sample() {
  # Real cycles persist history before alert detection. Retain partial rows,
  # including polls that the legacy complete-only timestamps cannot reveal.
  PYTHONPATH="$ROOT_DIR/local${PYTHONPATH:+:$PYTHONPATH}" python3 - "$HISTORY_FILE" "$1" "$2" "${3:-group-a}" "${4-20000}" "${5-100}" <<'PY'
import datetime as dt
import json
from pathlib import Path
import sys
from history import canonicalize_limit_id
path = Path(sys.argv[1])
entries = json.loads(path.read_text()) if path.exists() else []
entries.append({"schema_version": 1,
                "scraped_at": dt.datetime.fromtimestamp(int(sys.argv[2]), dt.timezone.utc).isoformat(),
                "weekly_reset_at": int(sys.argv[3]) if sys.argv[3] else None,
                "limit_id": canonicalize_limit_id(sys.argv[4]),
                "five_h_reset_at": int(sys.argv[5]) if sys.argv[5] else None,
                "five_h_pct": 50, "weekly_pct": float(sys.argv[6]) if sys.argv[6] else None})
path.write_text(json.dumps(entries))
PY
  check_thresholds 50 "${5-100}" later later "${4-20000}" "$2" "$1" "${3:-group-a}"
}

for baseline in legacy canceled partial pct_missing no_deadlines no_history foreign stale; do
  rm -f "$STATE_FILE" "$ALERT_DELIVERIES_FILE" "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log" "$HISTORY_FILE"
  sample 100 10000
  if [[ "$baseline" == partial ]]; then sample 500 ''; fi
  if [[ "$baseline" == pct_missing ]]; then sample 500 '' group-a '' ''; fi
  if [[ "$baseline" == no_deadlines ]]; then sample 500 '' group-a ''; fi
  if [[ "$baseline" == no_history ]]; then rm -f "$HISTORY_FILE"; fi
  if [[ "$baseline" == canceled ]]; then
    sed -i 's/^full_weekly_reset_state=.*/full_weekly_reset_state=/' "$STATE_FILE"
  else
    # These keys did not exist before the full-weekly classifier was added.
    sed -i '/^full_weekly_reset_state=/d; /^confirmed_full_weekly_reset_at=/d' "$STATE_FILE"
  fi
  owner=group-a
  advanced_at=1000
  [[ "$baseline" == foreign ]] && owner=group-b
  [[ "$baseline" == stale ]] && advanced_at=5000
  sample "$advanced_at" 13000 "$owner"
  [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail "$baseline migration ran an unconfirmed hook"
  sample "$((advanced_at + 900))" 13010 "$owner"
  sample "$((advanced_at + 1800))" 13011 "$owner"
  if [[ "$baseline" == legacy ]]; then
    assert_eq 1000 "$(cat "$TEST_ROOT/hooks.log")" 'legacy baseline did not recover one original reset anchor'
    assert_eq 1 "$(grep -c 'Cycle renewed' "$TEST_ROOT/notifications.log")" 'migrated renewal must notify once'
  else
    [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail "$baseline migration resurrected an invalid chain"
    [[ ! -e "$TEST_ROOT/notifications.log" ]] || fail "$baseline migration notified an invalid chain"
  fi
done

printf 'PASS: weekly full-quota state migration preserves valid baselines and cancellation\n'
