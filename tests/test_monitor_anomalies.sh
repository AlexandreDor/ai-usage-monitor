#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
ALERT_THRESHOLDS=0
ALERT_LOG="${TEST_ROOT}/anomaly-alerts.log"
ANOMALY_SEND_STATUS=1

# No-channel registration remains a durable local seam, but a failed seam must
# leave the SQLite row pending for the next cycle.
send_alert() {
  printf '%s\n' "$1" >> "$ALERT_LOG"
  return "$ANOMALY_SEND_STATUS"
}

iso_at() {
  python3 - "$1" <<'PYEOF'
import datetime
import sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
}

snapshot() {
  local epoch="$1" five="$2" weekly="$3"
  printf '{"scraped_at":"%s","five_h_pct":%s,"weekly_pct":%s,"five_h_reset_at":%s,"weekly_reset_at":%s,"limit_id":"group-a"}\n' \
    "$(iso_at "$epoch")" "$five" "$weekly" "$((epoch + 10000))" "$((epoch + 10000))"
}

now=2000000000
observe_quota_anomalies "$(snapshot "$now" 50 50)"
observe_quota_anomalies "$(snapshot "$((now + 900))" 60 60)"
check_thresholds 60 60 later later "$((now + 10900))" "$((now + 10900))" "$((now + 900))" group-a || true

assert_eq 2 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM quota_anomalies WHERE journaled_at IS NULL").fetchone()[0])
PYEOF
)" "failed anomaly registration was incorrectly acknowledged"

ANOMALY_SEND_STATUS=0
check_thresholds 60 60 later later "$((now + 10900))" "$((now + 10900))" "$((now + 900))" group-a
assert_eq 0 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM quota_anomalies WHERE journaled_at IS NULL").fetchone()[0])
PYEOF
)" "pending anomaly was not resumed"
assert_eq 3 "$(wc -l < "$ALERT_LOG")" "anomaly seam did not retry pending windows"

printf 'PASS: monitor quota anomaly tests\n'
