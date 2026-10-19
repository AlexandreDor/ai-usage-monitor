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
fetch_status_json() { cat "$TEST_ROOT/next.json"; }
sync_gist() { :; }
collect_token_usage() { :; }
cat > "$TEST_ROOT/hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_ALERT_RESET_AT" >> "$(dirname "$0")/hooks.log"
HOOK
chmod 700 "$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1="$TEST_ROOT/hook.sh"
ALERT_SCRIPT_1_EVENTS=weekly:reset
validate_config
base_epoch="$(date -u +%s)"

fixture() {
  PYTHONPATH="$ROOT_DIR/local${PYTHONPATH:+:$PYTHONPATH}" python3 - \
    "$TEST_ROOT/next.json" "$((base_epoch + $1))" "$((base_epoch + $2))" "${3-full}" <<'PY'
import datetime as dt
import json
from pathlib import Path
import sys
from history import canonicalize_limit_id
epoch, deadline = int(sys.argv[2]), int(sys.argv[3])
partial = sys.argv[4] != 'full'
Path(sys.argv[1]).write_text(json.dumps({
    'schema_version': 1, 'scraped_at': dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat(),
    'five_h_pct': 50, 'five_h_reset_at': None if partial else epoch + 10000,
    'weekly_pct': None if sys.argv[4] == 'partial' else 100,
    'weekly_reset_at': None if partial else deadline,
    'limit_id': canonicalize_limit_id('group-a'), 'sample_interval_seconds': 900,
    'history_window_hours': 192,
}))
PY
}

for scenario in valid live_valid live_partial live_missing_dates; do
  rm -rf "$RUNTIME_DIR"
  mkdir -m 700 "$RUNTIME_DIR"
  rm -f "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
  fixture 0 10000
  run_cycle 900 full >/dev/null
  case "$scenario" in
    live_valid) fixture 500 10000; run_cycle 300 live >/dev/null ;;
    live_partial) fixture 500 10000 partial; run_cycle 300 live >/dev/null ;;
    live_missing_dates) fixture 500 10000 missing_dates; run_cycle 300 live >/dev/null ;;
  esac
  # Model the pre-feature state after those observations. The live data.json
  # remains the last actual poll, while history/archive contain only full polls.
  sed -i '/^full_weekly_reset_state=/d; /^confirmed_full_weekly_reset_at=/d' "$STATE_FILE"
  python3 - "$ARCHIVE_FILE" <<'PY'
import json
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    for owner, window, encoded in connection.execute(
            'SELECT limit_id, window, state_json FROM anomaly_detector_state').fetchall():
        state = json.loads(encoded)
        state.pop('full_weekly_reset_state', None)
        state.pop('pending_full_weekly_shift', None)
        connection.execute('UPDATE anomaly_detector_state SET state_json=?, updated_at_epoch=? '
                           'WHERE limit_id=? AND window=?',
                           (json.dumps(state), state['last_epoch'], owner, window))
PY
  fixture 1000 13000
  run_cycle 900 full >/dev/null
  fixture 1900 13010
  run_cycle 900 full >/dev/null
  fixture 2800 13011
  run_cycle 900 full >/dev/null
  anomaly_count="$(python3 - "$ARCHIVE_FILE" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT count(*) FROM quota_anomalies "
                             "WHERE window='weekly' AND anomaly_type='reset_shift'").fetchone()[0])
PY
)"
  if [[ "$scenario" == valid || "$scenario" == live_valid ]]; then
    assert_eq "$((base_epoch + 1000))" "$(cat "$TEST_ROOT/hooks.log")" "$scenario migration must preserve one hook anchor"
    assert_eq 1 "$(grep -c 'Reset from 100% to 100%' "$TEST_ROOT/notifications.log")" "$scenario migration must notify once"
    assert_eq 0 "$anomaly_count" "$scenario migrated renewal became an anomaly"
  else
    [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail "$scenario migration revived a live partial chain"
    [[ "$(cat "$TEST_ROOT/notifications.log")" != *'Reset from 100% to 100%'* ]] || fail "$scenario falsely notified a renewal"
    assert_eq 1 "$anomaly_count" "$scenario lost the original reset-shift anomaly"
  fi
done

printf 'PASS: full/live collection shares pre-overwrite legacy evidence across detectors\n'
