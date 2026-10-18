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
    "$TEST_ROOT/next.json" "$((base_epoch + $1))" "$((base_epoch + $2))" "${3-100}" <<'PY'
import datetime as dt
import json
from pathlib import Path
import sys
from history import canonicalize_limit_id
epoch, deadline = int(sys.argv[2]), int(sys.argv[3])
Path(sys.argv[1]).write_text(json.dumps({
    'schema_version': 1, 'scraped_at': dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat(),
    'five_h_pct': 50, 'five_h_reset_at': epoch + 10000,
    'weekly_pct': float(sys.argv[4]) if sys.argv[4] else None,
    'weekly_reset_at': deadline, 'limit_id': canonicalize_limit_id('group-a'),
    'sample_interval_seconds': 900, 'history_window_hours': 192,
}))
PY
}

assert_archive() {
  python3 - "$ARCHIVE_FILE" "$base_epoch" "$1" "$2" <<'PY'
import sqlite3
import sys
base, snapshot_count, confirmed = map(int, sys.argv[2:])
with sqlite3.connect(sys.argv[1]) as connection:
    events = connection.execute(
        "SELECT reset_at_epoch, observed_at_epoch, detection_method FROM reset_events WHERE window='weekly'"
    ).fetchall()
    expected = [(base + 300, base + 600, 'full_observed')] if confirmed else []
    assert events == expected, (events, expected)
    assert connection.execute('SELECT count(*) FROM snapshots').fetchone()[0] == snapshot_count
PY
}

for scenario in consumed scheduled canceled; do
  rm -rf "$RUNTIME_DIR"
  mkdir -m 700 "$RUNTIME_DIR"
  rm -f "$TEST_ROOT/hooks.log" "$TEST_ROOT/notifications.log"
  old_deadline=400000
  first_pct=100
  if [[ "$scenario" == scheduled ]]; then
    old_deadline=400
    first_pct=99
  fi
  fixture 0 "$old_deadline" "$first_pct"
  run_cycle 900 full >/dev/null
  if [[ "$scenario" == scheduled ]]; then
    fixture 100 "$old_deadline"
    run_cycle 300 live >/dev/null
  fi
  fixture 300 600000
  run_cycle 300 live >/dev/null
  if [[ "$scenario" == canceled ]]; then
    fixture 450 600000 ''
    run_cycle 300 live >/dev/null
  fi
  fixture 600 600000
  run_cycle 300 live >/dev/null
  confirmed=1
  [[ "$scenario" == canceled ]] && confirmed=0
  assert_archive 1 "$confirmed"
  # The next full poll has consumed quota, so snapshots alone cannot recover
  # a full-to-full cycle. Its proof and original identity must still survive.
  pct=99
  [[ "$scenario" == canceled ]] && pct=100
  fixture 900 600000 "$pct"
  run_cycle 900 full >/dev/null
  fixture 1800 600000 "$pct"
  run_cycle 900 full >/dev/null
  assert_archive 3 "$confirmed"
  if (( confirmed )); then
    assert_eq "$((base_epoch + 300))" "$(cat "$TEST_ROOT/hooks.log")" "$scenario hook identity changed"
    assert_eq 1 "$(grep -c 'Reset from 100% to 100%' "$TEST_ROOT/notifications.log")" "$scenario notification count changed"
  else
    [[ ! -e "$TEST_ROOT/hooks.log" ]] || fail 'live partial cancellation ran a hook'
    [[ "$(cat "$TEST_ROOT/notifications.log")" != *'Reset from 100% to 100%'* ]] || fail 'live partial cancellation notified a renewal'
  fi
done

printf 'PASS: live weekly proofs preserve reset history without extra snapshots or duplicate cycles\n'
