#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

README="${ROOT_DIR}/README.md"
ROADMAP="${ROOT_DIR}/ROADMAP.md"
ENV_EXAMPLE="${ROOT_DIR}/local/.env.example"

assert_file "${README}"

readme_text="$(<"${README}")"
roadmap_text="$(<"${ROADMAP}")"

assert_contains "$readme_text" "https://github.com/AlexandreDor/ai-usage-monitor.git" "canonical clone URL missing"
if [[ "$readme_text" == *"https://github.com/<your-account>/codex-usage-monitor"* ]]; then
  fail "obsolete generic clone URL remains"
fi
assert_contains "$readme_text" "ai-usage-monitor/local" "current local path missing"

for required in \
  "## Deployment" \
  "### LXC Ubuntu/Debian" \
  "### systemd (manual units)" \
  "### GitHub Pages and Gist (static external dashboard)" \
  "## Backup/Restore SQLite" \
  "sqlite3.Connection.backup" \
  "PRAGMA quick_check" \
  "usage-history.sqlite3" \
  "PRAGMA journal_mode=DELETE" \
  "-wal" \
  "-shm" \
  "chmod 600" \
  "monitor.sh --loop" \
  "serve.sh" \
  "network-online.target" \
  "Restart=on-failure" \
  "systemctl status" \
  "journalctl" \
  "/(root)" \
  "/docs" \
  "index.html" \
  "assets/" \
  "images/favicon.png" \
  "let GIST_ID" \
  "LOCAL" \
  "EXTERNAL" \
  "FRESH" \
  "STALE" \
  "unknown" \
  "disabled" \
  "unavailable" \
  "error" \
  "P1.7" \
  "usage-history.sqlite3.corrupt.*" \
  "git clone https://github.com/<github-account>/<pages-repository>.git pages-copy" \
  "cp local/dashboard.html ../pages-copy/docs/dashboard.html" \
  "cp local/analytics.html ../pages-copy/docs/analytics.html" \
  "git add docs" \
  "git commit -m 'Publish Codex usage dashboard'" \
  "git push" \
  "\${EDITOR:-vi} docs/assets/dashboard.js" \
  "DASHBOARD_PRICING_FILE" \
  "pricing catalog: \`DASHBOARD_PRICING_FILE\` (process)" \
  "TOKEN_PRICING_FILE\` in \`local/.env\`" \
  'DASHBOARD_ANALYTICS_DATABASE` (process only)' \
  "CODEX_BIN=/absolute/path/to/codex" \
  "command -v codex" \
  "set -euo pipefail" \
  "mkdir -m 700 -- \"\$SAFETY_DIR\"" \
  "RESTORE_INSTALLED=1" \
  "ROLLBACK_REQUIRED=0" \
  "trap restore_cleanup EXIT" \
  "STORAGE=/path/to/ai-usage-monitor/local/storage.py" \
  "\${DB_NAME}.restore-safety.\${STAMP}" \
  "mv -- \"\$DB\"" \
  "# BEGIN SQLITE_BACKUP_SHELL_EXAMPLE" \
  "# END SQLITE_BACKUP_SHELL_EXAMPLE" \
  "# BEGIN SQLITE_BACKUP_EXAMPLE" \
  "# END SQLITE_BACKUP_EXAMPLE" \
  "# BEGIN SQLITE_RESTORE_EXAMPLE" \
  "# END SQLITE_RESTORE_EXAMPLE" \
  "# BEGIN SQLITE_RESTORE_CLEANUP_EXAMPLE" \
  "# END SQLITE_RESTORE_CLEANUP_EXAMPLE"; do
  assert_contains "$readme_text" "$required" "documentation invariant missing: $required"
done

environment_file_name='EnvironmentFile'
environment_file_equals='='
if [[ "$readme_text" == *"${environment_file_name}${environment_file_equals}"* ]]; then
  fail "systemd documentation delegates .env parsing to systemd"
fi
if [[ "$readme_text" == *"Select that repository's branch and /local"* ]]; then
  fail "GitHub Pages documentation selects the invalid /local source"
fi
# shellcheck disable=SC2016
if grep -Eq 'install .*BACKUP|BACKUP\$suffix' "$README"; then
  fail "restore documentation installs or associates backup sidecars"
fi

# Every key that can be placed in .env.example, including the commented alert
# script examples and optional path overrides, must be discoverable in README.
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  assert_contains "$readme_text" "$key" "configuration key missing from README: $key"
done < <(sed -nE 's/^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$ENV_EXAMPLE" | sort -u)

assert_contains "$(<"${ROOT_DIR}/local/assets/dashboard.js")" "let GIST_ID = ''" "dashboard GIST_ID declaration is not mutable"
if [[ "$readme_text" == *"const GIST_ID"* ]]; then
  fail "README still documents const GIST_ID"
fi

if [[ "$roadmap_text" == *"P2.15"* || "$roadmap_text" == *"### 15."* ]]; then
  fail "completed P2.15 remains in ROADMAP.md"
fi
assert_contains "$roadmap_text" "### 16. Préparer le packaging et les releases" "P2.16 was removed from roadmap"

python3 - "$README" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("`serve.sh` has a separate, narrow priority chain:")
end = text.index("There is deliberately no `local/config.py` yet.", start)
section = re.sub(r"\s+", " ", text[start:end])
expected = (
    "`DASHBOARD_PRICING_FILE` (process) → `TOKEN_PRICING_FILE` (process) "
    "→ `TOKEN_PRICING_FILE` in `local/.env` → `local/pricing.json`"
)
if expected not in section:
    raise SystemExit("serve.sh pricing priority chain is incomplete or reordered")

pages_start = text.index("git clone https://github.com/<github-account>/<pages-repository>.git pages-copy")
pages_end = text.index("Select that repository's branch and `/docs` directory", pages_start)
pages_section = text[pages_start:pages_end]
if pages_section.index("${EDITOR:-vi} docs/assets/dashboard.js") > pages_section.index("git add docs"):
    raise SystemExit("Pages GIST_ID edit occurs after git add")
if "cp local/dashboard.html ../pages-copy/docs/index.html" not in pages_section:
    raise SystemExit("Pages publication omits index.html")
if "cp local/dashboard.html ../pages-copy/docs/dashboard.html" not in pages_section:
    raise SystemExit("Pages publication omits dashboard.html required by Analytics")

restore_start = text.index("DB=/path/to/ai-usage-monitor/local/runtime/usage-history.sqlite3")
restore_end = text.index("The restore script never installs", restore_start)
restore_section = text[restore_start:restore_end]
reservation = restore_section.index('mkdir -m 700 -- "$SAFETY_DIR"')
candidate = restore_section.index('python3 - "$BACKUP" "$RESTORE_TEMP" "$STORAGE"')
if reservation > candidate:
    raise SystemExit("restore creates a candidate before reserving the safety directory")
if reservation > restore_section.index("systemctl stop"):
    raise SystemExit("restore stops services before reserving the safety directory")
if restore_section.index("trap restore_cleanup EXIT") > restore_section.index(
    "\nsudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service\n"
):
    raise SystemExit("restore stops services before installing its cleanup trap")
if restore_section.index("ROLLBACK_REQUIRED=0") < restore_section.index("systemctl status"):
    raise SystemExit("restore disables rollback before service status checks")
PY

extract_example() {
  local begin="$1" end="$2" output="$3"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { inside = 1; found_begin = 1; next }
    $0 == end { inside = 0; found_end = 1; exit }
    inside { print }
    END {
      if (!found_begin || !found_end) exit 1
    }
  ' "$README" > "$output" || fail "could not extract documentation example: $begin"
}

BACKUP_EXAMPLE="${TEST_ROOT}/sqlite-backup-example.py"
BACKUP_SHELL_EXAMPLE="${TEST_ROOT}/sqlite-backup-example.sh"
RESTORE_EXAMPLE="${TEST_ROOT}/sqlite-restore-example.py"
RESTORE_CLEANUP_EXAMPLE="${TEST_ROOT}/sqlite-restore-cleanup-example.sh"
RESTORE_SAFETY_EXAMPLE="${TEST_ROOT}/sqlite-restore-safety-example.sh"
extract_example '# BEGIN SQLITE_BACKUP_EXAMPLE' '# END SQLITE_BACKUP_EXAMPLE' "$BACKUP_EXAMPLE"
extract_example '# BEGIN SQLITE_BACKUP_SHELL_EXAMPLE' '# END SQLITE_BACKUP_SHELL_EXAMPLE' "$BACKUP_SHELL_EXAMPLE"
extract_example '# BEGIN SQLITE_RESTORE_EXAMPLE' '# END SQLITE_RESTORE_EXAMPLE' "$RESTORE_EXAMPLE"
extract_example '# BEGIN SQLITE_RESTORE_CLEANUP_EXAMPLE' '# END SQLITE_RESTORE_CLEANUP_EXAMPLE' "$RESTORE_CLEANUP_EXAMPLE"

extract_restore_safety_example() {
  local output="$1"
  awk '
    $0 == "if [[ -e \"$DB\" || -L \"$DB\" ]]; then" { inside = 1 }
    inside { print }
    inside && $0 == "done" { exit }
  ' "$README" > "$output"
  [[ -s "$output" ]] || fail "could not extract documented restore safety commands"
}

extract_restore_safety_example "$RESTORE_SAFETY_EXAMPLE"

run_restore_safety() {
  local database="$1" safety_dir="$2"
  {
    printf "mkdir -m 700 -- \"\$SAFETY_DIR\"\n"
    cat "$RESTORE_SAFETY_EXAMPLE"
  } | DB="$database" \
    DB_NAME="$(basename -- "$database")" \
    SAFETY_DIR="$safety_dir" \
    bash -euo pipefail 2>/dev/null
}

run_backup_wrapper() {
  local source_database="$1" existing_backup="$2" run_script="${TEST_ROOT}/sqlite-backup-wrapper.sh"
  {
    printf 'cd %q\n' "$ROOT_DIR"
    printf 'DB=%q\n' "$source_database"
    printf 'BACKUP=%q\n' "$existing_backup"
    sed \
      -e '/^cd \/path\/to\/ai-usage-monitor$/d' \
      -e '/^DB=local\/runtime\/usage-history\.sqlite3$/d' \
      -e '/^BACKUP=/d' \
      "$BACKUP_SHELL_EXAMPLE"
  } > "$run_script"
  bash "$run_script"
}

make_sqlite_fixture() {
  python3 - "$ROOT_DIR" "$1" "$2" <<'PY'
from pathlib import Path
import sqlite3
import sys

root, database, journal_mode = sys.argv[1:]
sys.path.insert(0, str(Path(root) / "local"))
from storage import connect_database

with connect_database(Path(database)) as connection:
    connection.execute(
        "INSERT OR REPLACE INTO metadata(key, value) VALUES('test_fixture', ?)",
        (journal_mode,),
    )
    connection.commit()
with sqlite3.connect(database) as connection:
    connection.execute(f"PRAGMA journal_mode={journal_mode}")
    connection.execute("PRAGMA wal_autocheckpoint=0")
    connection.commit()
PY
}

verify_sqlite_artifact() {
  python3 - "$1" "$2" <<'PY'
import sqlite3
import sys

database, expected = sys.argv[1:]
with sqlite3.connect(database) as connection:
    result = connection.execute("PRAGMA quick_check").fetchone()
    assert result == ("ok",), result
    assert connection.execute("PRAGMA user_version").fetchone() == (4,)
    value = connection.execute(
        "SELECT value FROM metadata WHERE key = 'test_fixture'"
    ).fetchone()
    assert value == (expected,), value
PY
}

for journal_mode in DELETE WAL; do
  source_database="${TEST_ROOT}/source-${journal_mode}.sqlite3"
  backup_database="${TEST_ROOT}/backup-${journal_mode}.sqlite3"
  restore_database="${TEST_ROOT}/restore-${journal_mode}.sqlite3"
  corrupt_database="${TEST_ROOT}/corrupt-${journal_mode}.sqlite3"
  corrupt_restore="${TEST_ROOT}/corrupt-restore-${journal_mode}.sqlite3"
  make_sqlite_fixture "$source_database" "$journal_mode"

  python3 "$BACKUP_EXAMPLE" "$source_database" "$backup_database"
  verify_sqlite_artifact "$backup_database" "$journal_mode"
  assert_eq 600 "$(stat -c '%a' "$backup_database")" "backup mode for ${journal_mode}"
  [[ ! -e "${backup_database}-wal" && ! -e "${backup_database}-shm" ]] \
    || fail "backup ${journal_mode} retained non-autonomous sidecars"

  python3 "$RESTORE_EXAMPLE" "$backup_database" "$restore_database" "$ROOT_DIR/local/storage.py"
  verify_sqlite_artifact "$restore_database" "$journal_mode"
  assert_eq 600 "$(stat -c '%a' "$restore_database")" "restore mode for ${journal_mode}"
  [[ ! -e "${restore_database}-wal" && ! -e "${restore_database}-shm" ]] \
    || fail "restore ${journal_mode} retained non-autonomous sidecars"

  existing_backup="${TEST_ROOT}/existing-${journal_mode}.sqlite3"
  printf 'do-not-overwrite\n' > "$existing_backup"
  existing_backup_mode="$(stat -c '%a' "$existing_backup")"
  if run_backup_wrapper "$source_database" "$existing_backup" >/dev/null 2>&1; then
    fail "backup shell wrapper accepted an existing ${journal_mode} destination"
  fi
  assert_eq 'do-not-overwrite' "$(<"$existing_backup")" \
    "existing ${journal_mode} backup changed through shell wrapper"
  assert_eq "$existing_backup_mode" "$(stat -c '%a' "$existing_backup")" \
    "existing ${journal_mode} backup mode changed through shell wrapper"
  if python3 "$BACKUP_EXAMPLE" "$source_database" "$existing_backup" >/dev/null 2>&1; then
    fail "backup example overwrote an existing ${journal_mode} destination"
  fi
  assert_eq 'do-not-overwrite' "$(<"$existing_backup")" "existing ${journal_mode} backup changed"

  existing_restore="${TEST_ROOT}/existing-restore-${journal_mode}.sqlite3"
  printf 'do-not-overwrite\n' > "$existing_restore"
  if python3 "$RESTORE_EXAMPLE" "$backup_database" "$existing_restore" "$ROOT_DIR/local/storage.py" >/dev/null 2>&1; then
    fail "restore example overwrote an existing ${journal_mode} destination"
  fi
  assert_eq 'do-not-overwrite' "$(<"$existing_restore")" \
    "existing ${journal_mode} restore destination changed"

  race_backup="${TEST_ROOT}/race-${journal_mode}.sqlite3"
  python3 "$BACKUP_EXAMPLE" "$source_database" "$race_backup" >/dev/null 2>&1 &
  first_pid=$!
  python3 "$BACKUP_EXAMPLE" "$source_database" "$race_backup" >/dev/null 2>&1 &
  second_pid=$!
  race_successes=0
  if wait "$first_pid"; then
    race_successes=$((race_successes + 1))
  fi
  if wait "$second_pid"; then
    race_successes=$((race_successes + 1))
  fi
  assert_eq 1 "$race_successes" "concurrent ${journal_mode} backups did not enforce no-clobber"
  verify_sqlite_artifact "$race_backup" "$journal_mode"

  printf 'not a sqlite database\n' > "$corrupt_database"
  if python3 "$RESTORE_EXAMPLE" "$corrupt_database" "$corrupt_restore" "$ROOT_DIR/local/storage.py" >/dev/null 2>&1; then
    fail "restore example accepted corrupt ${journal_mode} candidate"
  fi
  [[ ! -e "$corrupt_restore" ]] || fail "corrupt ${journal_mode} candidate created a destination"

  unrelated_database="${TEST_ROOT}/unrelated-${journal_mode}.sqlite3"
  unrelated_restore="${TEST_ROOT}/unrelated-restore-${journal_mode}.sqlite3"
  python3 - "$unrelated_database" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("CREATE TABLE unrelated(value TEXT)")
PY
  if python3 "$RESTORE_EXAMPLE" "$unrelated_database" "$unrelated_restore" "$ROOT_DIR/local/storage.py" >/dev/null 2>&1; then
    fail "restore example accepted unrelated ${journal_mode} SQLite database"
  fi
  [[ ! -e "$unrelated_restore" ]] || fail "unrelated ${journal_mode} database created a destination"

  obsolete_database="${TEST_ROOT}/obsolete-${journal_mode}.sqlite3"
  obsolete_restore="${TEST_ROOT}/obsolete-restore-${journal_mode}.sqlite3"
  python3 - "$obsolete_database" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("PRAGMA user_version = 2")
    connection.commit()
PY
  if python3 "$RESTORE_EXAMPLE" "$obsolete_database" "$obsolete_restore" "$ROOT_DIR/local/storage.py" >/dev/null 2>&1; then
    fail "restore example accepted obsolete schema ${journal_mode} candidate"
  fi
  [[ ! -e "$obsolete_restore" ]] || fail "obsolete ${journal_mode} candidate created a destination"

  unsupported_database="${TEST_ROOT}/unsupported-${journal_mode}.sqlite3"
  unsupported_restore="${TEST_ROOT}/unsupported-restore-${journal_mode}.sqlite3"
  python3 - "$unsupported_database" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute("PRAGMA user_version = 5")
    connection.commit()
PY
  if python3 "$RESTORE_EXAMPLE" "$unsupported_database" "$unsupported_restore" "$ROOT_DIR/local/storage.py" >/dev/null 2>&1; then
    fail "restore example accepted unsupported schema ${journal_mode} candidate"
  fi
  [[ ! -e "$unsupported_restore" ]] || fail "unsupported ${journal_mode} candidate created a destination"

  safety_parent="${TEST_ROOT}/restore safety ${journal_mode}"
  mkdir -p "$safety_parent"
  active_database="${safety_parent}/active database ${journal_mode}.sqlite3"
  safety_dir="${safety_parent}/active database ${journal_mode}.sqlite3.restore-safety.fixed"
  printf 'original active %s\n' "$journal_mode" > "$active_database"
  printf 'original wal %s\n' "$journal_mode" > "$active_database-wal"
  printf 'original shm %s\n' "$journal_mode" > "$active_database-shm"

  run_restore_safety "$active_database" "$safety_dir"
  assert_eq 700 "$(stat -c '%a' "$safety_dir")" "restore safety mode for ${journal_mode}"
  assert_eq "original active ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database")")" \
    "initial safety copy for ${journal_mode}"
  assert_eq "original wal ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database-wal")")" \
    "initial WAL safety copy for ${journal_mode}"
  assert_eq "original shm ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database-shm")")" \
    "initial SHM safety copy for ${journal_mode}"
  [[ ! -e "$active_database" && ! -e "$active_database-wal" && ! -e "$active_database-shm" ]] \
    || fail "restore safety example did not move ${journal_mode} active files"

  printf 'replacement active %s\n' "$journal_mode" > "$active_database"
  printf 'replacement wal %s\n' "$journal_mode" > "$active_database-wal"
  printf 'replacement shm %s\n' "$journal_mode" > "$active_database-shm"
  if run_restore_safety "$active_database" "$safety_dir"; then
    fail "restore safety example accepted an existing directory for ${journal_mode}"
  fi
  assert_eq "original active ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database")")" \
    "existing safety copy for ${journal_mode} changed after collision"
  assert_eq "original wal ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database-wal")")" \
    "existing WAL safety copy for ${journal_mode} changed after collision"
  assert_eq "original shm ${journal_mode}" \
    "$(<"$safety_dir/$(basename -- "$active_database-shm")")" \
    "existing SHM safety copy for ${journal_mode} changed after collision"
  assert_eq "replacement active ${journal_mode}" "$(<"$active_database")" \
    "active ${journal_mode} database moved despite safety collision"
  assert_eq "replacement wal ${journal_mode}" "$(<"$active_database-wal")" \
    "active ${journal_mode} WAL moved despite safety collision"
  assert_eq "replacement shm ${journal_mode}" "$(<"$active_database-shm")" \
    "active ${journal_mode} SHM moved despite safety collision"

  safety_file="${safety_parent}/safety target file"
  printf 'do-not-overwrite\n' > "$safety_file"
  if run_restore_safety "$active_database" "$safety_file"; then
    fail "restore safety example accepted a file collision for ${journal_mode}"
  fi
  assert_eq 'do-not-overwrite' "$(<"$safety_file")" \
    "safety target file changed for ${journal_mode}"
  assert_eq "replacement active ${journal_mode}" "$(<"$active_database")" \
    "active ${journal_mode} database moved for file collision"
done

reservation_example="${TEST_ROOT}/restore-reservation-example.sh"
awk '
  $0 == "mkdir -m 700 -- \"$SAFETY_DIR\"" { inside = 1 }
  inside { print }
  inside && $0 == "MONITOR_WAS_ACTIVE=0" { exit }
' "$README" > "$reservation_example"
[[ -s "$reservation_example" ]] || fail "could not extract safety reservation commands"
reservation_dir="${TEST_ROOT}/already-reserved"
reservation_log="${TEST_ROOT}/reservation-services.log"
reservation_active="${TEST_ROOT}/reserved-active.sqlite3"
reservation_temp="${TEST_ROOT}/reserved-restore-temp.sqlite3"
mkdir -m 700 "$reservation_dir"
printf 'active database must remain\n' > "$reservation_active"
reservation_script="${TEST_ROOT}/run-reservation-collision.sh"
{
  printf '%s\n' 'set -euo pipefail'
  printf 'DB=%q\n' "$reservation_active"
  printf 'BACKUP=%q\n' "$backup_database"
  printf 'STORAGE=%q\n' "$ROOT_DIR/local/storage.py"
  printf 'RESTORE_TEMP=%q\n' "$reservation_temp"
  printf 'DB_DIR=%q\n' "$(dirname -- "$reservation_active")"
  printf 'DB_NAME=%q\n' "$(basename -- "$reservation_active")"
  printf 'SAFETY_DIR=%q\n' "$reservation_dir"
  printf 'systemctl() { printf "%%s\\n" "$*" >> %q; }\n' "$reservation_log"
  printf '%s\n' 'sudo() { "$@"; }'
  cat "$reservation_example"
} > "$reservation_script"
if bash "$reservation_script" >/dev/null 2>&1; then
  fail "safety directory collision was accepted before stopping services"
fi
[[ ! -e "$reservation_temp" ]] || fail "safety collision created a restore candidate"
assert_eq 'active database must remain' "$(<"$reservation_active")" \
  "safety collision changed the active database"
[[ ! -e "$reservation_log" ]] || fail "service inspection ran before safety directory reservation"

cleanup_database="${TEST_ROOT}/cleanup-active.sqlite3"
cleanup_safety="${TEST_ROOT}/cleanup-safety"
cleanup_log="${TEST_ROOT}/cleanup-services.log"
cleanup_temp="${TEST_ROOT}/cleanup-restore-temp.sqlite3"
mkdir -m 700 "$cleanup_safety"
printf 'old database\n' > "$cleanup_database"
printf 'old wal\n' > "$cleanup_database-wal"
printf 'old shm\n' > "$cleanup_database-shm"
printf 'validated candidate\n' > "$cleanup_temp"
cleanup_script="${TEST_ROOT}/run-restore-cleanup.sh"
{
  printf '%s\n' 'set -euo pipefail'
  printf 'DB=%q\n' "$cleanup_database"
  printf 'DB_DIR=%q\n' "$(dirname -- "$cleanup_database")"
  printf 'DB_NAME=%q\n' "$(basename -- "$cleanup_database")"
  printf 'SAFETY_DIR=%q\n' "$cleanup_safety"
  printf 'RESTORE_TEMP=%q\n' "$cleanup_temp"
  printf 'MONITOR_WAS_ACTIVE=1\nDASHBOARD_WAS_ACTIVE=1\nRESTORE_INSTALLED=0\nRESTORE_ID=\x27\x27\nROLLBACK_REQUIRED=1\n'
  printf 'systemctl() {\n'
  printf '  printf "%%s\\n" "$*" >> %q\n' "$cleanup_log"
  printf "  if [[ \"\$1\" == status ]]; then return 1; fi\n"
  printf '}\n'
  printf '%s\n' 'sudo() { "$@"; }'
  cat "$RESTORE_CLEANUP_EXAMPLE"
  printf '%s\n' 'trap restore_cleanup EXIT'
  awk '
    $0 == "sudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service" { inside = 1 }
    inside { print }
    inside && $0 == "trap - EXIT" { exit }
  ' "$README"
} > "$cleanup_script"
if bash "$cleanup_script" >/dev/null 2>&1; then
  fail "restore cleanup hid a service status failure"
fi
assert_eq 'old database' "$(<"$cleanup_database")" \
  "restore cleanup did not restore active database"
assert_eq 'old wal' "$(<"$cleanup_database-wal")" \
  "restore cleanup did not restore WAL sidecar"
assert_eq 'old shm' "$(<"$cleanup_database-shm")" \
  "restore cleanup did not restore SHM sidecar"
[[ ! -e "$cleanup_temp" ]] || fail "restore cleanup retained temporary candidate"
cleanup_log_text="$(<"$cleanup_log")"
assert_contains "$cleanup_log_text" "stop codex-usage-monitor.service codex-usage-dashboard.service" \
  "rollback did not stop database-using services"
assert_contains "$cleanup_log_text" "start codex-usage-monitor.service" \
  "initially active monitor service was not restarted"
assert_contains "$cleanup_log_text" "start codex-usage-dashboard.service" \
  "initially active dashboard service was not restarted"
python3 - "$cleanup_log" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
status = next(i for i, line in enumerate(lines) if line.startswith("status "))
rollback_stop = next(
    i for i, line in enumerate(lines[status + 1 :], status + 1)
    if line.startswith("stop ")
)
monitor_restart = next(
    i for i, line in enumerate(lines[rollback_stop + 1 :], rollback_stop + 1)
    if line == "start codex-usage-monitor.service"
)
if not rollback_stop < monitor_restart:
    raise SystemExit("rollback restarted a service before stopping it")
PY

printf 'PASS: documentation consistency tests\n'
