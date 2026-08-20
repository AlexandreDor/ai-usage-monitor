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
  "\${DB_NAME}.restore-safety.\${STAMP}" \
  "mv -- \"\$DB\"" \
  "# BEGIN SQLITE_BACKUP_SHELL_EXAMPLE" \
  "# END SQLITE_BACKUP_SHELL_EXAMPLE" \
  "# BEGIN SQLITE_BACKUP_EXAMPLE" \
  "# END SQLITE_BACKUP_EXAMPLE" \
  "# BEGIN SQLITE_RESTORE_EXAMPLE" \
  "# END SQLITE_RESTORE_EXAMPLE"; do
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
RESTORE_SAFETY_EXAMPLE="${TEST_ROOT}/sqlite-restore-safety-example.sh"
extract_example '# BEGIN SQLITE_BACKUP_EXAMPLE' '# END SQLITE_BACKUP_EXAMPLE' "$BACKUP_EXAMPLE"
extract_example '# BEGIN SQLITE_BACKUP_SHELL_EXAMPLE' '# END SQLITE_BACKUP_SHELL_EXAMPLE' "$BACKUP_SHELL_EXAMPLE"
extract_example '# BEGIN SQLITE_RESTORE_EXAMPLE' '# END SQLITE_RESTORE_EXAMPLE' "$RESTORE_EXAMPLE"

extract_restore_safety_example() {
  local output="$1"
  local start_pattern="^mkdir -m 700 -- \"\\\$SAFETY_DIR\"\$"
  sed -n "/${start_pattern}/,/^done$/p" "$README" > "$output"
  [[ -s "$output" ]] || fail "could not extract documented restore safety commands"
}

extract_restore_safety_example "$RESTORE_SAFETY_EXAMPLE"

run_restore_safety() {
  local database="$1" safety_dir="$2"
  DB="$database" \
    DB_NAME="$(basename -- "$database")" \
    SAFETY_DIR="$safety_dir" \
    bash -euo pipefail "$RESTORE_SAFETY_EXAMPLE"
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
  python3 - "$1" "$2" <<'PY'
import sqlite3
import sys

database, journal_mode = sys.argv[1:]
with sqlite3.connect(database) as connection:
    connection.execute(f"PRAGMA journal_mode={journal_mode}")
    connection.execute("PRAGMA wal_autocheckpoint=0")
    connection.execute("CREATE TABLE sample(value TEXT NOT NULL)")
    connection.executemany("INSERT INTO sample(value) VALUES (?)", [(f"{journal_mode}-value",), ("shared-value",)])
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
    values = [row[0] for row in connection.execute("SELECT value FROM sample ORDER BY rowid")]
    assert values == [f"{expected}-value", "shared-value"], values
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

  python3 "$RESTORE_EXAMPLE" "$backup_database" "$restore_database"
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

  printf 'not a sqlite database\n' > "$corrupt_database"
  if python3 "$RESTORE_EXAMPLE" "$corrupt_database" "$corrupt_restore" >/dev/null 2>&1; then
    fail "restore example accepted corrupt ${journal_mode} candidate"
  fi
  [[ ! -e "$corrupt_restore" ]] || fail "corrupt ${journal_mode} candidate created a destination"

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

printf 'PASS: documentation consistency tests\n'
