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

future_database="${TEST_ROOT}/future.sqlite3"
if printf '{"schema_version":2,"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$future_database" --history "$HISTORY_FILE" --retention-days 0; then
  fail "archive accepted a future snapshot schema"
fi
[[ ! -e "$future_database" ]] || fail "future snapshot created or modified a SQLite archive"

future_existing_database="$TEST_ROOT/future-existing.sqlite3"
printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$future_existing_database" --history "$HISTORY_FILE" --retention-days 0
future_history="$TEST_ROOT/future-history.json"
printf '[{"schema_version":2,"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:21Z"}]\n' >"$future_history"
future_before="$(python3 - "$future_existing_database" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
PYEOF
)"
if printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:22Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$future_existing_database" --history "$future_history" --retention-days 0 \
  >"$TEST_ROOT/future-existing.out" 2>"$TEST_ROOT/future-existing.err"; then
  fail "archive accepted a future schema in existing history"
fi
future_after="$(python3 - "$future_existing_database" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
PYEOF
)"
assert_eq "$future_before" "$future_after" "future history changed an existing archive"
[[ "$(( $(grep -c Traceback "$TEST_ROOT/future-existing.err" || true) ))" -eq 0 ]] || fail "future history leaked traceback"

epoch_database="$TEST_ROOT/epoch-range.sqlite3"
if printf '{"five_h_pct":80,"weekly_pct":60,"five_h_reset_at":1e308,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$epoch_database" --history "$HISTORY_FILE" --retention-days 0 \
  >"$TEST_ROOT/epoch-range.out" 2>"$TEST_ROOT/epoch-range.err"; then
  fail "out-of-range reset epoch was accepted"
fi
[[ ! -e "$epoch_database" ]] || fail "out-of-range reset epoch created a database"
[[ "$(<"$TEST_ROOT/epoch-range.err")" != *Traceback* ]] || fail "epoch range failure leaked traceback"

fractional_database="$TEST_ROOT/fractional-epoch.sqlite3"
if printf '{"five_h_pct":80,"weekly_pct":60,"five_h_reset_at":1.5,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$fractional_database" --history "$HISTORY_FILE" --retention-days 0 \
  >"$TEST_ROOT/fractional-epoch.out" 2>"$TEST_ROOT/fractional-epoch.err"; then
  fail "fractional reset epoch was accepted"
fi
[[ ! -e "$fractional_database" ]] || fail "fractional reset epoch created a database"
[[ "$(<"$TEST_ROOT/fractional-epoch.err")" != *Traceback* ]] || fail "fractional epoch failure leaked traceback"
integral_database="$TEST_ROOT/integral-float-epoch.sqlite3"
if ! printf '{"five_h_pct":80,"weekly_pct":60,"five_h_reset_at":1.0,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$integral_database" --history "$HISTORY_FILE" --retention-days 0; then
  fail "integral float reset epoch was rejected"
fi
fractional_history="$TEST_ROOT/fractional-history.json"
printf '[{"five_h_pct":80,"weekly_pct":60,"five_h_reset_at":1.5,"scraped_at":"2033-05-18T03:33:19Z"}]\n' >"$fractional_history"
fractional_before="$(python3 - "$integral_database" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
PYEOF
)"
if printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:21Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$integral_database" --history "$fractional_history" --retention-days 0 \
  >"$TEST_ROOT/fractional-history.out" 2>"$TEST_ROOT/fractional-history.err"; then
  fail "fractional reset epoch in history was accepted"
fi
fractional_after="$(python3 - "$integral_database" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0])
PYEOF
)"
assert_eq "$fractional_before" "$fractional_after" "fractional history changed the archive"
[[ "$(<"$TEST_ROOT/fractional-history.err")" != *Traceback* ]] || fail "fractional history leaked traceback"

huge_snapshot_database="$TEST_ROOT/huge-snapshot.sqlite3"
if python3 - <<'PYEOF' \
  | python3 "$ARCHIVE_SCRIPT" --database "$huge_snapshot_database" --history "$HISTORY_FILE" --retention-days 0 \
  >"$TEST_ROOT/huge-snapshot.out" 2>"$TEST_ROOT/huge-snapshot.err"; then
print('{"five_h_pct":' + ('9' * 5000) + ',"weekly_pct":60,"scraped_at":"2033-05-18T03:33:20Z"}')
PYEOF
  fail "oversized JSON integer on archive stdin was accepted"
fi
[[ ! -e "$huge_snapshot_database" ]] || fail "oversized JSON integer created a database"
[[ "$(<"$TEST_ROOT/huge-snapshot.err")" != *Traceback* ]] || fail "oversized JSON integer leaked traceback"

huge_retention="$(python3 -c 'print("9" * 5000)')"
retention_database="$TEST_ROOT/retention-range.sqlite3"
if printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:20Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$retention_database" --history "$HISTORY_FILE" --retention-days "$huge_retention" \
  >"$TEST_ROOT/retention-range.out" 2>"$TEST_ROOT/retention-range.err"; then
  fail "oversized archive retention was accepted"
fi
[[ ! -e "$retention_database" ]] || fail "oversized archive retention created a database"
[[ "$(<"$TEST_ROOT/retention-range.err")" != *Traceback* ]] || fail "retention failure leaked traceback"

huge_history="$TEST_ROOT/huge-history.json"
python3 - "$huge_history" <<'PYEOF'
import json
import sys
path = sys.argv[1]
pathlib = __import__('pathlib')
pathlib.Path(path).write_text(
    '[{"five_h_pct":' + ('9' * 5000) + ',"scraped_at":"2033-05-18T03:33:20Z"}]',
    encoding='utf-8',
)
PYEOF
history_recovery_database="$TEST_ROOT/history-recovery.sqlite3"
if ! printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"2033-05-18T03:33:21Z"}\n' \
  | python3 "$ARCHIVE_SCRIPT" --database "$history_recovery_database" --history "$huge_history" --retention-days 0 \
  >"$TEST_ROOT/history-recovery.out" 2>"$TEST_ROOT/history-recovery.err"; then
  fail "archive did not recover from an oversized existing history file"
fi
[[ "$(<"$TEST_ROOT/history-recovery.err")" != *Traceback* ]] || fail "history recovery leaked traceback"

forecast_archive_at() {
  local epoch="$1" chance_24h="${2:-50}" chance_6h="${3:-25}" retention="${4:-0}"
  printf '{"five_h_pct":80,"weekly_pct":60,"scraped_at":"%s","codex_forecast":{"chance_24h_pct":%s,"chance_6h_pct":%s,"generated_at":"%s"}}\n' \
    "$(iso_at "$epoch")" "$chance_24h" "$chance_6h" "$(iso_at "$((epoch - 10))")" \
    | python3 "$ARCHIVE_SCRIPT" --database "$ARCHIVE_FILE" \
      --history "$HISTORY_FILE" --retention-days "$retention"
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
expected_test_limit="$(python3 -c 'import hashlib; print("limit-" + hashlib.sha256(b"test").hexdigest())')"
assert_eq "$expected_test_limit" "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(
        "SELECT limit_id FROM snapshots WHERE scraped_at_epoch = ?", (2000000000,)
    ).fetchone()[0])
PYEOF
)" "archive persisted an opaque limit_id"
archive_at "$BASE"
assert_eq 2 "$(count_rows)" "re-ingesting a timestamp created a duplicate"
assert_eq 1 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(int(connection.execute("SELECT value FROM metadata WHERE key = 'history_json_migrated'").fetchone()[0] == "1"))
PYEOF
)" "migration marker missing"
assert_eq 4 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("PRAGMA user_version").fetchone()[0])
PYEOF
)" "archive schema was not migrated to v4"

# Forecast samples from rolling history are imported without persisting display
# thresholds, and quota-only cycles do not fabricate Forecast observations.
rm -f "$ARCHIVE_FILE"
printf '[{"five_h_pct":80,"scraped_at":"%s","codex_forecast":{"chance_24h_pct":51,"chance_6h_pct":26,"generated_at":"%s","highlight_threshold_24h_pct":50}}]\n' \
  "$(iso_at "$((BASE - 100))")" "$(iso_at "$((BASE - 120))")" > "$HISTORY_FILE"
archive_at "$BASE"
assert_eq '1:51:26' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT COUNT(*), MAX(chance_24h_pct), MAX(chance_6h_pct) FROM forecast_samples"
    ).fetchone()
print(":".join(map(str, row)))
PYEOF
)" "rolling Forecast history was not imported"
archive_at "$((BASE + 100))"
assert_eq 1 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM forecast_samples").fetchone()[0])
PYEOF
)" "quota-only cycle fabricated a Forecast sample"

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

# Forecast compaction is independent from the quota row selected for a bucket.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"
forecast_archive_at "$medium_one" 40 15
forecast_archive_at "$medium_two" 60 35
archive_at "$((medium_two + 100))"
archive_at "$BASE"
assert_eq "${medium_two}:60:35" "$(python3 - "$ARCHIVE_FILE" "$medium_bucket" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT scraped_at_epoch, chance_24h_pct, chance_6h_pct "
        "FROM forecast_samples WHERE scraped_at_epoch >= ? AND scraped_at_epoch < ?",
        (int(sys.argv[2]), int(sys.argv[2]) + 1800),
    ).fetchone()
print(":".join(map(str, row)))
PYEOF
)" "Forecast compaction did not keep its own latest bucket sample"

# The default one-year retention removes older data while zero is unlimited.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"
archive_at "$((BASE - 366 * 86400))" 365
archive_at "$BASE" 365
assert_eq no "$(has_epoch "$((BASE - 366 * 86400))")" "default retention kept data beyond one year"

rm -f "$ARCHIVE_FILE"
forecast_archive_at "$((BASE - 366 * 86400))" 80 40 365
archive_at "$BASE" 365
assert_eq 0 "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM forecast_samples").fetchone()[0])
PYEOF
)" "disabled Forecast did not expire old observations from the quota anchor"

rm -f "$ARCHIVE_FILE"
archive_at "$((BASE - 366 * 86400))" 0
archive_at "$BASE" 0
assert_eq yes "$(has_epoch "$((BASE - 366 * 86400))")" "unlimited retention removed old data"

# A corrupted database is preserved and rebuilt from the rolling history.
printf 'not a sqlite database\n' > "$ARCHIVE_FILE"
archive_at "$BASE"
compgen -G "${ARCHIVE_FILE}.corrupt.*" >/dev/null || fail "corrupt archive backup missing"
assert_eq yes "$(has_epoch "$BASE")" "archive was not rebuilt after corruption"

# Reset events are deterministically derived from retained adjacent snapshots.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"
before=$((BASE - 100))
reset_at=$((BASE - 50))
printf '{"five_h_pct":5,"weekly_pct":7,"five_h_reset_at":%s,"weekly_reset_at":%s,"limit_id":"test","scraped_at":"%s"}\n' \
  "$reset_at" "$reset_at" "$(iso_at "$before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
snapshot_at "$BASE" 100 100 | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '2' "$(python3 - "$ARCHIVE_FILE" "$reset_at" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    rows = connection.execute(
        "SELECT window, before_pct, after_pct FROM reset_events "
        "WHERE reset_at_epoch = ? ORDER BY window", (int(sys.argv[2]),)
    ).fetchall()
assert rows == [("5h", 5.0, 100.0), ("weekly", 7.0, 100.0)], rows
print(len(rows))
PYEOF
)" "reset events were not derived from the crossing"
archive_at "$BASE"
assert_eq '2' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "reset event reconstruction created duplicates"

# A reset deadline inside a long observation gap is not evidence of an
# observed reset; reconstruction must not invent missed events.
rm -f "$ARCHIVE_FILE"
printf '[]\n' > "$HISTORY_FILE"
long_gap_before=$((BASE - 3 * 3600))
long_gap_reset=$((BASE - 2 * 3600))
printf '{"five_h_pct":5,"five_h_reset_at":%s,"scraped_at":"%s"}\n' \
  "$long_gap_reset" "$(iso_at "$long_gap_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
snapshot_at "$BASE" 100 100 | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '0' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "long observation gap invented a reset"

# A complete 100% -> 100% 5-hour observation with a later deadline is retained
# as an observed reset and remains idempotent when the archive is rebuilt.
rm -f "$ARCHIVE_FILE"
five_observed_before=$((BASE - 900))
five_observed_previous_deadline=$((BASE + 4 * 3600))
five_observed_current_deadline=$((five_observed_previous_deadline + 900))
printf '{"five_h_pct":100,"five_h_reset_at":%s,"scraped_at":"%s","limit_id":"test"}\n' \
  "$five_observed_previous_deadline" "$(iso_at "$five_observed_before")" \
  | python3 "$ARCHIVE_SCRIPT" --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"five_h_pct":100,"five_h_reset_at":%s,"scraped_at":"%s","limit_id":"test"}\n' \
  "$five_observed_current_deadline" "$(iso_at "$BASE")" \
  | python3 "$ARCHIVE_SCRIPT" --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" "$BASE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT detection_method, before_pct, after_pct FROM reset_events "
        "WHERE window = '5h' AND reset_at_epoch = ?", (int(sys.argv[2]),)
    ).fetchone()
assert row == ("observed_refill", 100.0, 100.0), row
print(1)
PYEOF
)" "full 5h observed reset was not derived"
printf '{"five_h_pct":100,"five_h_reset_at":%s,"scraped_at":"%s","limit_id":"test"}\n' \
  "$five_observed_current_deadline" "$(iso_at "$BASE")" \
  | python3 "$ARCHIVE_SCRIPT" --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events WHERE window = '5h'").fetchone()[0])
PYEOF
)" "observed 5h reset reconstruction created duplicates"

# An early weekly refill with a materially advanced deadline is classified as
# a random reset rather than a scheduled end-of-week reset.
rm -f "$ARCHIVE_FILE"
random_before=$((BASE - 900))
random_previous_deadline=$((BASE + 4 * 86400))
random_current_deadline=$((random_previous_deadline + 3 * 86400))
printf '{"weekly_pct":28,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$random_previous_deadline" "$(iso_at "$random_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":100,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$random_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" "$BASE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT detection_method, before_pct, after_pct FROM reset_events WHERE reset_at_epoch = ?",
        (int(sys.argv[2]),),
    ).fetchone()
assert row == ("random_observed", 28.0, 100.0), row
print(1)
PYEOF
)" "random weekly reset was not derived"

# Reaching exactly 98% is a random reset even when only one point was refilled,
# provided the deadline advances by exactly 30 minutes.
rm -f "$ARCHIVE_FILE"
small_refill_before=$((BASE - 900))
small_refill_previous_deadline=$((BASE + 4 * 86400))
small_refill_current_deadline=$((small_refill_previous_deadline + 30 * 60))
printf '{"weekly_pct":97,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$small_refill_previous_deadline" "$(iso_at "$small_refill_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":98,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$small_refill_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" "$BASE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT detection_method, before_pct, after_pct FROM reset_events WHERE reset_at_epoch = ?",
        (int(sys.argv[2]),),
    ).fetchone()
assert row == ("random_observed", 97.0, 98.0), row
print(1)
PYEOF
)" "small weekly refill to 98% was not derived as a random reset"

# Strong refill evidence remains valid across a long gap and partial samples.
rm -f "$ARCHIVE_FILE"
long_refill_before=$((BASE - 3 * 3600))
long_refill_previous_deadline=$((BASE + 4 * 86400))
long_refill_current_deadline=$((long_refill_previous_deadline + 30 * 60))
printf '{"weekly_pct":40,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$long_refill_previous_deadline" "$(iso_at "$long_refill_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"five_h_pct":50,"scraped_at":"%s"}\n' "$(iso_at "$((BASE - 3600))")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":60,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$long_refill_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" "$BASE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        "SELECT detection_method, before_pct, after_pct FROM reset_events WHERE reset_at_epoch = ?",
        (int(sys.argv[2]),),
    ).fetchone()
assert row == ("random_observed", 40.0, 60.0), row
print(1)
PYEOF
)" "long-gap weekly refill was not derived as a random reset"

# A partial row before the old deadline cannot suppress the later strong reset
# evidence, while a partial row after it must not create a duplicate event.
rm -f "$ARCHIVE_FILE"
partial_before=$((BASE - 100))
partial_deadline=$((BASE - 50))
partial_current_deadline=$((BASE + 7 * 86400))
printf '{"weekly_pct":40,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$partial_deadline" "$(iso_at "$partial_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"five_h_pct":50,"scraped_at":"%s"}\n' "$(iso_at "$((BASE - 75))")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":100,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$partial_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "partial sample before deadline suppressed strong reset evidence"

rm -f "$ARCHIVE_FILE"
printf '{"weekly_pct":40,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$partial_deadline" "$(iso_at "$partial_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"five_h_pct":50,"scraped_at":"%s"}\n' "$(iso_at "$((BASE - 25))")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":100,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$partial_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '1' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "partial sample after deadline duplicated the reset event"

# Scheduled reconstruction never combines observations from different groups.
rm -f "$ARCHIVE_FILE"
printf '{"weekly_pct":40,"weekly_reset_at":%s,"limit_id":"group-a","scraped_at":"%s"}\n' \
  "$partial_deadline" "$(iso_at "$partial_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":100,"weekly_reset_at":%s,"limit_id":"group-b","scraped_at":"%s"}\n' \
  "$partial_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '0' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "scheduled reset crossed limit groups"

# A deadline jump without any refill remains insufficient evidence of a reset.
rm -f "$ARCHIVE_FILE"
printf '{"weekly_pct":97,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$small_refill_previous_deadline" "$(iso_at "$small_refill_before")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
printf '{"weekly_pct":97,"weekly_reset_at":%s,"scraped_at":"%s"}\n' \
  "$small_refill_current_deadline" "$(iso_at "$BASE")" | python3 "$ARCHIVE_SCRIPT" \
  --database "$ARCHIVE_FILE" --history "$HISTORY_FILE" --retention-days 365
assert_eq '0' "$(python3 - "$ARCHIVE_FILE" <<'PYEOF'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute("SELECT COUNT(*) FROM reset_events").fetchone()[0])
PYEOF
)" "deadline jump without a refill was classified as a random reset"

mode="$(stat -c '%a' "$ARCHIVE_FILE")"
assert_eq 600 "$mode" "archive permissions are not private"

printf 'PASS: monitor archive tests\n'
