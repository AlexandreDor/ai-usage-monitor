#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults

ARCHIVE_SCRIPT="${ROOT_DIR}/local/archive.py"
BASE=2000000000

iso_at() {
  python3 - "$1" <<'PYEOF'
import datetime
import sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
}

snapshot_at() {
  local epoch="$1" five_h="${2:-80}" weekly="${3:-60}"
  printf '{"five_h_pct":%s,"weekly_pct":%s,"five_h_reset":"later","weekly_reset":"later","scraped_at":"%s","sample_interval_seconds":900,"history_window_hours":192,"limit_id":"test"}\n' \
    "$five_h" "$weekly" "$(iso_at "$epoch")"
}

archive_at() {
  local epoch="$1" retention="${2:-0}"
  snapshot_at "$epoch" | python3 "$ARCHIVE_SCRIPT" \
    --database "$ARCHIVE_FILE" \
    --history "$HISTORY_FILE" \
    --retention-days "$retention"
}

count_rows() {
  python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0])
PYEOF
}

has_epoch() {
  local epoch="$1"
  python3 - "$ARCHIVE_FILE" "$epoch" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    found = connection.execute(
        "SELECT 1 FROM snapshots WHERE scraped_at_epoch = ?", (int(sys.argv[2]),)
    ).fetchone()
print("yes" if found else "no")
PYEOF
}

# Migration is automatic and idempotent.
printf '[%s]\n' "$(snapshot_at "$((BASE - 100))")" > "$HISTORY_FILE"
archive_at "$BASE"
assert_eq 2 "$(count_rows)" "history migration did not import the rolling entry"
archive_at "$BASE"
assert_eq 2 "$(count_rows)" "re-ingesting a timestamp created a duplicate"
assert_eq 1 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(int(connection.execute("SELECT value FROM metadata WHERE key = 'history_json_migrated'").fetchone()[0] == "1"))
PYEOF
)" "migration marker missing"

# Rebuild a clean archive for compaction checks.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"

recent_one=$((BASE - 1800))
recent_two=$((BASE - 100))
medium_bucket=$(( (BASE - 25 * 3600) / 1800 * 1800 ))
medium_one=$((medium_bucket + 10))
medium_two=$((medium_bucket + 1000))
old_bucket=$(( (BASE - 8 * 86400) / 3600 * 3600 ))
old_one=$((old_bucket + 10))
old_two=$((old_bucket + 2000))
boundary_recent=$((BASE - 24 * 3600))
boundary_medium=$((BASE - 7 * 86400))
# Leave the 30-minute bucket containing the exact 7-day boundary so this
# verifies the hourly tier rather than the medium-tier deduplication.
boundary_old=$((boundary_medium - 1801))

for epoch in \
  "$recent_one" "$recent_two" \
  "$medium_one" "$medium_two" \
  "$old_one" "$old_two" \
  "$boundary_recent" "$boundary_medium" "$boundary_old"; do
  archive_at "$epoch"
done
archive_at "$BASE"

assert_eq yes "$(has_epoch "$recent_one")" "recent samples were compacted"
assert_eq yes "$(has_epoch "$recent_two")" "recent samples were compacted"
assert_eq no "$(has_epoch "$medium_one")" "older 30-minute bucket kept the wrong point"
assert_eq yes "$(has_epoch "$medium_two")" "latest 30-minute bucket point missing"
assert_eq no "$(has_epoch "$old_one")" "older hourly bucket kept the wrong point"
assert_eq yes "$(has_epoch "$old_two")" "latest hourly bucket point missing"
assert_eq yes "$(has_epoch "$boundary_recent")" "24-hour boundary was compacted incorrectly"
assert_eq yes "$(has_epoch "$boundary_medium")" "7-day boundary was compacted incorrectly"
assert_eq yes "$(has_epoch "$boundary_old")" "point just beyond 7 days was lost"

# The default one-year retention removes older data while zero is unlimited.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"
archive_at "$((BASE - 366 * 86400))" 365
archive_at "$BASE" 365
assert_eq no "$(has_epoch "$((BASE - 366 * 86400))")" "default retention kept data beyond one year"

rm -f "$ARCHIVE_FILE"
archive_at "$((BASE - 366 * 86400))" 0
archive_at "$BASE" 0
assert_eq yes "$(has_epoch "$((BASE - 366 * 86400))")" "unlimited retention removed old data"

# A corrupted database is preserved and rebuilt from the rolling history.
printf 'not a sqlite database\n' > "$ARCHIVE_FILE"
archive_at "$BASE"
compgen -G "${ARCHIVE_FILE}.corrupt.*" >/dev/null || fail "corrupt archive backup missing"
assert_eq yes "$(has_epoch "$BASE")" "archive was not rebuilt after corruption"

mode="$(stat -c '%a' "$ARCHIVE_FILE")"
assert_eq 600 "$mode" "archive permissions are not private"

printf 'PASS: monitor archive tests\n'
