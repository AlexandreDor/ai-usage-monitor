#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/scripts/install.sh"
BUILDER="${ROOT_DIR}/scripts/build-release.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1', got '$2'"
}

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  fi
}

make_release() {
  local version="$1" destination="$2" path
  mkdir -p "$destination"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    (cd "$ROOT_DIR" && cp --parents -- "$path" "$destination")
  done < "${ROOT_DIR}/scripts/release-files.txt"
  printf '%s\n' "$version" > "$destination/VERSION"
  # Synthetic commands expose the launcher's selected paths without requiring Codex.
  cat > "$destination/local/monitor.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then exit 0; fi
printf 'monitor %s config=%s state=%s\n' "$(<"$(dirname "$0")/../VERSION")" "$CODEX_USAGE_MONITOR_CONFIG" "$CODEX_USAGE_MONITOR_STATE_DIR"
EOF
  cat > "$destination/local/serve.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then exit 0; fi
printf 'dashboard config=%s state=%s\n' "$CODEX_USAGE_MONITOR_CONFIG" "$CODEX_USAGE_MONITOR_STATE_DIR"
EOF
  chmod 755 "$destination/local/monitor.sh" "$destination/local/serve.sh" "$destination/scripts/"*.sh
}

HOME_DIR="${TEST_ROOT}/home with spaces"
CONFIG_HOME="${TEST_ROOT}/config with spaces"
STATE_HOME="${TEST_ROOT}/state with spaces"
LIB_ROOT="${TEST_ROOT}/lib with spaces/codex-usage-monitor"
BIN_DIR="${TEST_ROOT}/bin with spaces"
SYSTEMD_DIR="${TEST_ROOT}/units with spaces"
RELEASE_ONE="${TEST_ROOT}/release one"
RELEASE_TWO="${TEST_ROOT}/release two"
BACKUP_FILE="${TEST_ROOT}/persistent backup.tar.gz"
mkdir -p "$HOME_DIR"
make_release 0.1.0 "$RELEASE_ONE"
make_release 0.2.0 "$RELEASE_TWO"

COMMON=(--home "$HOME_DIR" --xdg-config-home "$CONFIG_HOME" --xdg-state-home "$STATE_HOME" --lib-root "$LIB_ROOT" --bin-dir "$BIN_DIR" --systemd-dir "$SYSTEMD_DIR" --no-systemd)

"$INSTALLER" install --source "$RELEASE_ONE" "${COMMON[@]}"
assert_eq releases/0.1.0 "$(readlink "$LIB_ROOT/current")"
assert_file "$CONFIG_HOME/codex-usage-monitor/.env"
[[ -d "$STATE_HOME/codex-usage-monitor" ]] || fail "state directory was not created"
assert_file "$LIB_ROOT/.codex-usage-monitor.owned"
assert_file "$LIB_ROOT/releases/0.1.0/local/images/favicon.png"
[[ ! -e "$LIB_ROOT/releases/0.1.0/local/.env" ]] || fail "configuration leaked into a release"
[[ ! -e "$LIB_ROOT/releases/0.1.0/local/runtime" ]] || fail "state link leaked into a release"
expected="monitor 0.1.0 config=$CONFIG_HOME/codex-usage-monitor/.env state=$STATE_HOME/codex-usage-monitor"
assert_eq "$expected" "$("$BIN_DIR/codex-usage-monitor")"

printf '%s\n' 'secret=config' > "$CONFIG_HOME/codex-usage-monitor/.env"
chmod 600 "$CONFIG_HOME/codex-usage-monitor/.env"
printf '%s\n' persistent-state > "$STATE_HOME/codex-usage-monitor/data.txt"
# The generated manager must retain all original path overrides.
"$BIN_DIR/codex-usage-monitor-manage" update --source "$RELEASE_TWO"
assert_eq releases/0.2.0 "$(readlink "$LIB_ROOT/current")"
assert_eq releases/0.1.0 "$(readlink "$LIB_ROOT/previous")"
assert_eq 'secret=config' "$(<"$CONFIG_HOME/codex-usage-monitor/.env")"
assert_eq 'persistent-state' "$(<"$STATE_HOME/codex-usage-monitor/data.txt")"
expected="monitor 0.2.0 config=$CONFIG_HOME/codex-usage-monitor/.env state=$STATE_HOME/codex-usage-monitor"
assert_eq "$expected" "$("$BIN_DIR/codex-usage-monitor")"
"$BIN_DIR/codex-usage-monitor-manage" update --source "$RELEASE_TWO" >/dev/null
assert_eq releases/0.2.0 "$(readlink "$LIB_ROOT/current")"

"$BIN_DIR/codex-usage-monitor-manage" rollback
assert_eq releases/0.1.0 "$(readlink "$LIB_ROOT/current")"

# Updates and rollbacks use the same maintenance lock as backup/restore and
# manual monitor cycles.
exec {release_lock_fd}>>"$STATE_HOME/codex-usage-monitor/.monitor.lock"
flock -n "$release_lock_fd"
assert_fails "update ignored a manually held monitor lock" \
  "$BIN_DIR/codex-usage-monitor-manage" update --source "$RELEASE_TWO"
assert_eq releases/0.1.0 "$(readlink "$LIB_ROOT/current")"
assert_fails "rollback ignored a manually held monitor lock" \
  "$BIN_DIR/codex-usage-monitor-manage" rollback
assert_eq releases/0.1.0 "$(readlink "$LIB_ROOT/current")"
flock -u "$release_lock_fd"
exec {release_lock_fd}>&-

"$BIN_DIR/codex-usage-monitor-manage" backup --output "$BACKUP_FILE"
[[ "$(stat -c %a "$BACKUP_FILE")" == 600 ]] || fail "backup mode is not 0600"
printf '%s\n' changed > "$CONFIG_HOME/codex-usage-monitor/.env"
printf '%s\n' changed > "$STATE_HOME/codex-usage-monitor/data.txt"
"$BIN_DIR/codex-usage-monitor-manage" restore --backup "$BACKUP_FILE"
assert_eq 'secret=config' "$(<"$CONFIG_HOME/codex-usage-monitor/.env")"
assert_eq 'persistent-state' "$(<"$STATE_HOME/codex-usage-monitor/data.txt")"

# Manual/no-systemd collectors hold the same cycle lock and must block maintenance.
exec {held_lock_fd}>>"$STATE_HOME/codex-usage-monitor/.monitor.lock"
flock -n "$held_lock_fd"
assert_fails "backup ignored a manually held monitor lock" \
  "$BIN_DIR/codex-usage-monitor-manage" backup --output "$TEST_ROOT/locked backup.tar.gz"
assert_fails "restore ignored a manually held monitor lock" \
  "$BIN_DIR/codex-usage-monitor-manage" restore --backup "$BACKUP_FILE"
flock -u "$held_lock_fd"
exec {held_lock_fd}>&-

ln -s "$TEST_ROOT/symlink-target" "$TEST_ROOT/backup-link.tar.gz"
assert_fails "backup accepted a symlink destination" \
  "$INSTALLER" backup --output "$TEST_ROOT/backup-link.tar.gz" "${COMMON[@]}"

python3 - "$TEST_ROOT" <<'PY'
import io
import pathlib
import tarfile
import sys

root = pathlib.Path(sys.argv[1])
cases = {
    "traversal.tar.gz": ("../escape", tarfile.REGTYPE),
    "absolute.tar.gz": ("/tmp/escape", tarfile.REGTYPE),
    "symlink.tar.gz": ("config/link", tarfile.SYMTYPE),
    "hardlink.tar.gz": ("state/link", tarfile.LNKTYPE),
    "fifo.tar.gz": ("state/fifo", tarfile.FIFOTYPE),
}
for filename, (name, kind) in cases.items():
    with tarfile.open(root / filename, "w:gz") as stream:
        for directory in ("config", "state"):
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            stream.addfile(info)
        info = tarfile.TarInfo(name)
        info.type = kind
        if kind == tarfile.REGTYPE:
            info.size = 1
            stream.addfile(info, io.BytesIO(b"x"))
        else:
            info.linkname = "config" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
            stream.addfile(info)
PY
for hostile in traversal absolute symlink hardlink fifo; do
  assert_fails "restore accepted hostile ${hostile} archive" \
    "$INSTALLER" restore --backup "$TEST_ROOT/${hostile}.tar.gz" "${COMMON[@]}"
  assert_eq 'secret=config' "$(<"$CONFIG_HOME/codex-usage-monitor/.env")"
done

assert_fails "relative home path was accepted" "$INSTALLER" install --source "$RELEASE_ONE" --home relative --no-systemd
assert_fails "overlapping data and release paths were accepted" "$INSTALLER" install --source "$RELEASE_ONE" \
  --home "$HOME_DIR" --lib-root "$TEST_ROOT/overlap" --xdg-state-home "$TEST_ROOT/overlap" --no-systemd
assert_fails "LIB_ROOT equal to HOME was accepted" "$INSTALLER" install --source "$RELEASE_ONE" \
  --home "$TEST_ROOT/danger home" --lib-root "$TEST_ROOT/danger home" \
  --xdg-config-home "$TEST_ROOT/danger config" --xdg-state-home "$TEST_ROOT/danger state" \
  --bin-dir "$TEST_ROOT/danger bin" --systemd-dir "$TEST_ROOT/danger units" --no-systemd
assert_fails "LIB_ROOT ancestor of HOME was accepted" "$INSTALLER" install --source "$RELEASE_ONE" \
  --home "$TEST_ROOT/danger ancestor/home" --lib-root "$TEST_ROOT/danger ancestor" \
  --xdg-config-home "$TEST_ROOT/ancestor config" --xdg-state-home "$TEST_ROOT/ancestor state" \
  --bin-dir "$TEST_ROOT/ancestor bin" --systemd-dir "$TEST_ROOT/ancestor units" --no-systemd
for invalid in 01.2.3 1.02.3 1.2.03 1.2.3-01 1.2.3-alpha..1 1.2.3+meta..x; do
  cp -a "$RELEASE_ONE" "$TEST_ROOT/invalid-$invalid"
  printf '%s\n' "$invalid" > "$TEST_ROOT/invalid-$invalid/VERSION"
  assert_fails "invalid SemVer accepted: $invalid" "$INSTALLER" update --source "$TEST_ROOT/invalid-$invalid" "${COMMON[@]}"
done

# Exercise installed units and service quiescing with the actual generated commands.
FAKE_SYSTEM_BIN="$TEST_ROOT/fake system bin"
FAKE_SYSTEM_STATE="$TEST_ROOT/fake system state"
FAKE_SYSTEM_LOG="$TEST_ROOT/fake systemctl.log"
SYSTEM_HOME="$TEST_ROOT/system home"
SYSTEM_CONFIG="$TEST_ROOT/system config"
SYSTEM_STATE="$TEST_ROOT/system state"
SYSTEM_LIB="$TEST_ROOT/system lib"
SYSTEM_BIN="$TEST_ROOT/system commands"
SYSTEM_UNITS="$TEST_ROOT/system units"
mkdir -p "$FAKE_SYSTEM_BIN" "$FAKE_SYSTEM_STATE" "$SYSTEM_HOME"
cat > "$FAKE_SYSTEM_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --user ]]
shift
printf '%s\n' "$*" >> "$FAKE_SYSTEM_LOG"
command="$1"
shift
case "$command" in
  is-active)
    [[ "$1" == --quiet ]]
    [[ -e "$FAKE_SYSTEM_STATE/$2" ]] || exit 3
    ;;
  stop)
    if [[ -n "${FAKE_FAIL_STOP:-}" && -e "$FAKE_FAIL_STOP" ]]; then
      exit 1
    fi
    for service in "$@"; do rm -f "$FAKE_SYSTEM_STATE/$service"; done
    ;;
  start|restart)
    if [[ -n "${FAKE_FAIL_START:-}" && -e "$FAKE_FAIL_START" ]]; then
      exit 1
    fi
    for service in "$@"; do
      if [[ "$command" == restart && "${FAKE_FAIL_RESTART_SERVICE:-}" == "$service" ]]; then
        exit 1
      fi
      touch "$FAKE_SYSTEM_STATE/$service"
    done
    ;;
  daemon-reload)
    [[ -z "${FAKE_FAIL_DAEMON_RELOAD:-}" || ! -e "$FAKE_FAIL_DAEMON_RELOAD" ]]
    ;;
  disable)
    [[ -z "${FAKE_FAIL_DISABLE:-}" || ! -e "$FAKE_FAIL_DISABLE" ]]
    ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$FAKE_SYSTEM_BIN/systemctl"
SYSTEM_COMMON=(--home "$SYSTEM_HOME" --xdg-config-home "$SYSTEM_CONFIG" --xdg-state-home "$SYSTEM_STATE" --lib-root "$SYSTEM_LIB" --bin-dir "$SYSTEM_BIN" --systemd-dir "$SYSTEM_UNITS")
PATH="$FAKE_SYSTEM_BIN:$PATH" FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" \
  "$INSTALLER" install --source "$RELEASE_ONE" "${SYSTEM_COMMON[@]}"
grep -Fq "Environment=\"PATH=$SYSTEM_BIN:" "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "installed unit lost custom launcher path"
grep -Fq 'ExecStart=/usr/bin/env codex-usage-monitor --loop --fail-fast' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "monitor unit is not fail-fast"
expected="monitor 0.1.0 config=$SYSTEM_CONFIG/codex-usage-monitor/.env state=$SYSTEM_STATE/codex-usage-monitor"
assert_eq "$expected" "$(PATH="$SYSTEM_BIN:/usr/local/bin:/usr/bin:/bin" codex-usage-monitor --loop --fail-fast)"

SYSTEM_RELEASE_TWO="$TEST_ROOT/system release two"
make_release 0.2.0 "$SYSTEM_RELEASE_TWO"
printf '%s\n' '# release two monitor unit' >> "$SYSTEM_RELEASE_TWO/systemd/codex-usage-monitor.service"
printf '%s\n' '# release two dashboard unit' >> "$SYSTEM_RELEASE_TWO/systemd/codex-usage-dashboard.service"

# Unit replacement and current activation roll back together.
FAIL_RELOAD="$TEST_ROOT/fail daemon reload"
touch "$FAIL_RELOAD"
assert_fails "unit transaction survived daemon-reload failure" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
  FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" FAKE_FAIL_DAEMON_RELOAD="$FAIL_RELOAD" \
  "$INSTALLER" update --source "$SYSTEM_RELEASE_TWO" "${SYSTEM_COMMON[@]}"
assert_eq releases/0.1.0 "$(readlink "$SYSTEM_LIB/current")"
! grep -Fq 'release two monitor unit' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "monitor unit was not rolled back"
! grep -Fq 'release two dashboard unit' "$SYSTEM_UNITS/codex-usage-dashboard.service" || fail "dashboard unit was not rolled back"
rm "$FAIL_RELOAD"

# Either service restart failing must reject and roll back activation.
touch "$FAKE_SYSTEM_STATE/codex-usage-monitor.service" "$FAKE_SYSTEM_STATE/codex-usage-dashboard.service"
for failed_service in codex-usage-monitor.service codex-usage-dashboard.service; do
  : > "$FAKE_SYSTEM_LOG"
  assert_fails "restart failure was masked for $failed_service" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
    FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" \
    FAKE_FAIL_RESTART_SERVICE="$failed_service" \
    "$INSTALLER" update --source "$SYSTEM_RELEASE_TWO" "${SYSTEM_COMMON[@]}"
  assert_eq releases/0.1.0 "$(readlink "$SYSTEM_LIB/current")"
  ! grep -Fq 'release two monitor unit' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "units remained updated after restart failure"
  grep -Fq 'restart codex-usage-monitor.service' "$FAKE_SYSTEM_LOG" || fail "monitor restart was not attempted"
  grep -Fq 'restart codex-usage-dashboard.service' "$FAKE_SYSTEM_LOG" || fail "dashboard restart was not attempted"
done

rm -f "$FAKE_SYSTEM_STATE/codex-usage-dashboard.service"
touch "$FAKE_SYSTEM_STATE/codex-usage-monitor.service"
: > "$FAKE_SYSTEM_LOG"
PATH="$FAKE_SYSTEM_BIN:$PATH" FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" \
  "$INSTALLER" backup --output "$TEST_ROOT/system backup.tar.gz" "${SYSTEM_COMMON[@]}"
grep -Fq 'stop codex-usage-monitor.service' "$FAKE_SYSTEM_LOG" || fail "backup did not stop the active service"
grep -Fq 'start codex-usage-monitor.service' "$FAKE_SYSTEM_LOG" || fail "backup did not restart the active service"
if grep -Fq 'start codex-usage-dashboard.service' "$FAKE_SYSTEM_LOG"; then
  fail "backup started a service that was inactive"
fi

# A backup failure after quiescing must still restart the recorded service.
ln -s "$TEST_ROOT/nonexistent" "$SYSTEM_STATE/codex-usage-monitor/rejected-link"
assert_fails "backup accepted a state symlink" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
  FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" \
  "$INSTALLER" backup --output "$TEST_ROOT/rejected backup.tar.gz" "${SYSTEM_COMMON[@]}"
[[ -e "$FAKE_SYSTEM_STATE/codex-usage-monitor.service" ]] || fail "backup failure left the active service stopped"
rm "$SYSTEM_STATE/codex-usage-monitor/rejected-link"

# A failed post-restore start must restore both pre-restore trees.
printf '%s\n' before-failed-restore > "$SYSTEM_CONFIG/codex-usage-monitor/.env"
printf '%s\n' before-failed-restore > "$SYSTEM_STATE/codex-usage-monitor/data.txt"
FAIL_START="$TEST_ROOT/fail service start"
touch "$FAIL_START"
assert_fails "restore succeeded despite service start failure" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
  FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" FAKE_FAIL_START="$FAIL_START" \
  "$INSTALLER" restore --backup "$TEST_ROOT/system backup.tar.gz" "${SYSTEM_COMMON[@]}"
assert_eq before-failed-restore "$(<"$SYSTEM_CONFIG/codex-usage-monitor/.env")"
assert_eq before-failed-restore "$(<"$SYSTEM_STATE/codex-usage-monitor/data.txt")"
rm "$FAIL_START"
systemd-analyze verify "$SYSTEM_UNITS/codex-usage-monitor.service" "$SYSTEM_UNITS/codex-usage-dashboard.service"
! grep -Fq 'ProtectSystem=strict' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "monitor state was made read-only"
! grep -Eq '^(ProtectSystem|ProtectHome)=' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "monitor paths were made inaccessible"
grep -Fq 'NoNewPrivileges=true' "$SYSTEM_UNITS/codex-usage-monitor.service" || fail "compatible service hardening was lost"

# Build the complete current index without changing the user's real index.
INDEX_FILE="${TEST_ROOT}/git-index"
GIT_INDEX_FILE="$INDEX_FILE" git -C "$ROOT_DIR" read-tree HEAD
GIT_INDEX_FILE="$INDEX_FILE" git -C "$ROOT_DIR" add -A
mkdir -p "$TEST_ROOT/build one" "$TEST_ROOT/build two"
GIT_INDEX_FILE="$INDEX_FILE" SOURCE_DATE_EPOCH=1720000000 "$BUILDER" --output "$TEST_ROOT/build one"
GIT_INDEX_FILE="$INDEX_FILE" SOURCE_DATE_EPOCH=1720000000 "$BUILDER" --output "$TEST_ROOT/build two"
ARCHIVE="codex-usage-monitor-0.1.0.tar.gz"
cmp "$TEST_ROOT/build one/$ARCHIVE" "$TEST_ROOT/build two/$ARCHIVE"
cmp "$TEST_ROOT/build one/SHA256SUMS" "$TEST_ROOT/build two/SHA256SUMS"
(cd "$TEST_ROOT/build one" && sha256sum --check SHA256SUMS)
assert_file "$TEST_ROOT/build one/$ARCHIVE"
tar -tzf "$TEST_ROOT/build one/$ARCHIVE" > "$TEST_ROOT/archive-list"
grep -Fq 'codex-usage-monitor-0.1.0/local/images/favicon.png' "$TEST_ROOT/archive-list" || fail "release archive omitted favicon"

# Every defensive archive bound is enforced by the shared validator.
assert_fails "release compressed-size ceiling was ignored" python3 "$ROOT_DIR/scripts/validate-archive.py" \
  release "$TEST_ROOT/build one/$ARCHIVE" 1 10000 67108864 268435456
assert_fails "release member-count ceiling was ignored" python3 "$ROOT_DIR/scripts/validate-archive.py" \
  release "$TEST_ROOT/build one/$ARCHIVE" 134217728 1 67108864 268435456
assert_fails "release member-size ceiling was ignored" python3 "$ROOT_DIR/scripts/validate-archive.py" \
  release "$TEST_ROOT/build one/$ARCHIVE" 134217728 10000 1 268435456
assert_fails "release total-size ceiling was ignored" python3 "$ROOT_DIR/scripts/validate-archive.py" \
  release "$TEST_ROOT/build one/$ARCHIVE" 134217728 10000 67108864 1
assert_fails "backup compressed-size ceiling was ignored" python3 "$ROOT_DIR/scripts/validate-archive.py" \
  backup "$BACKUP_FILE" 1 100000 8589934592 34359738368

GIT_INDEX_FILE="$INDEX_FILE" git -C "$ROOT_DIR" ls-files | LC_ALL=C sort | while IFS= read -r tracked; do
  printf 'codex-usage-monitor-0.1.0/%s\n' "$tracked"
done > "$TEST_ROOT/expected-files"
tar -tzf "$TEST_ROOT/build one/$ARCHIVE" | LC_ALL=C sort > "$TEST_ROOT/archive-files"
cmp "$TEST_ROOT/expected-files" "$TEST_ROOT/archive-files"

# A second checkout in a different topology has identical bytes and index modes.
SECOND_CHECKOUT="$TEST_ROOT/different topology/deep checkout"
mkdir -p "$SECOND_CHECKOUT"
GIT_INDEX_FILE="$INDEX_FILE" git -C "$ROOT_DIR" checkout-index --all --prefix="$SECOND_CHECKOUT/"
git -C "$SECOND_CHECKOUT" init -q
git -C "$SECOND_CHECKOUT" add -A
git -C "$SECOND_CHECKOUT" -c user.name=Distribution -c user.email=distribution.invalid commit -qm snapshot
printf '%s\n' dirty > "$SECOND_CHECKOUT/VERSION"
assert_fails "--require-clean accepted a tracked worktree change" \
  env SOURCE_DATE_EPOCH=1720000000 "$SECOND_CHECKOUT/scripts/build-release.sh" \
  --require-clean --output "$TEST_ROOT/build rejected"
printf '%s\n' 0.1.0 > "$SECOND_CHECKOUT/VERSION"
mkdir -p "$TEST_ROOT/build clean"
SOURCE_DATE_EPOCH=1720000000 "$SECOND_CHECKOUT/scripts/build-release.sh" --require-clean --output "$TEST_ROOT/build clean"
cmp "$TEST_ROOT/build one/$ARCHIVE" "$TEST_ROOT/build clean/$ARCHIVE"
printf '%s\n' ignored-secret > "$SECOND_CHECKOUT/.env"
chmod -x "$SECOND_CHECKOUT/scripts/install.sh"
chmod +x "$SECOND_CHECKOUT/VERSION"
mkdir -p "$TEST_ROOT/build topology"
SOURCE_DATE_EPOCH=1720000000 "$SECOND_CHECKOUT/scripts/build-release.sh" --output "$TEST_ROOT/build topology"
cmp "$TEST_ROOT/build one/$ARCHIVE" "$TEST_ROOT/build topology/$ARCHIVE"
[[ "$(tar -tvzf "$TEST_ROOT/build topology/$ARCHIVE" "codex-usage-monitor-0.1.0/scripts/install.sh" | cut -c1-10)" == -rwxr-xr-x ]] || fail "Git executable mode was not preserved"
[[ "$(tar -tvzf "$TEST_ROOT/build topology/$ARCHIVE" "codex-usage-monitor-0.1.0/VERSION" | cut -c1-10)" == -rw-r--r-- ]] || fail "worktree mode overrode Git mode"
tar -tzf "$TEST_ROOT/build topology/$ARCHIVE" > "$TEST_ROOT/topology-list"
! grep -q '/.env$' "$TEST_ROOT/topology-list" || fail "untracked secret entered archive"

# Install from the real source checkout through its NUL-safe Git file list.
REAL_HOME="$TEST_ROOT/real source home"
GIT_INDEX_FILE="$INDEX_FILE" "$INSTALLER" install --source "$ROOT_DIR" --home "$REAL_HOME" --no-systemd
assert_file "$REAL_HOME/.local/lib/codex-usage-monitor/releases/0.1.0/local/codex_status.py"
[[ ! -e "$REAL_HOME/.local/lib/codex-usage-monitor/releases/0.1.0/.git" ]] || fail ".git entered source installation"

ARCHIVE_HOME="$TEST_ROOT/archive install home"
"$INSTALLER" install --archive "$TEST_ROOT/build one/$ARCHIVE" \
  --checksum "$TEST_ROOT/build one/SHA256SUMS" --home "$ARCHIVE_HOME" --no-systemd
assert_file "$ARCHIVE_HOME/.local/lib/codex-usage-monitor/releases/0.1.0/local/images/favicon.png"
ln -s "$TEST_ROOT/build one/$ARCHIVE" "$TEST_ROOT/release-archive-link.tar.gz"
assert_fails "release archive symlink was accepted" "$INSTALLER" install \
  --archive "$TEST_ROOT/release-archive-link.tar.gz" \
  --checksum "$TEST_ROOT/build one/SHA256SUMS" --home "$TEST_ROOT/symlink archive home" --no-systemd
ln -s "$TEST_ROOT/build one/SHA256SUMS" "$TEST_ROOT/checksum-link"
assert_fails "checksum symlink was accepted" "$INSTALLER" install \
  --archive "$TEST_ROOT/build one/$ARCHIVE" --checksum "$TEST_ROOT/checksum-link" \
  --home "$TEST_ROOT/symlink checksum home" --no-systemd

# Destructive uninstall requires the marker and a successful service stop/disable.
FAIL_DISABLE="$TEST_ROOT/fail disable"
touch "$FAIL_DISABLE" "$FAKE_SYSTEM_STATE/codex-usage-monitor.service"
assert_fails "uninstall masked systemd disable failure" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
  FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" FAKE_FAIL_DISABLE="$FAIL_DISABLE" \
  "$INSTALLER" uninstall "${SYSTEM_COMMON[@]}"
[[ -d "$SYSTEM_LIB" ]] || fail "failed uninstall removed the owned release tree"
rm "$FAIL_DISABLE"
FAIL_STOP="$TEST_ROOT/fail stop"
touch "$FAIL_STOP" "$FAKE_SYSTEM_STATE/codex-usage-monitor.service"
assert_fails "uninstall proceeded after a failed service stop" env PATH="$FAKE_SYSTEM_BIN:$PATH" \
  FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" FAKE_FAIL_STOP="$FAIL_STOP" \
  "$INSTALLER" uninstall "${SYSTEM_COMMON[@]}"
[[ -d "$SYSTEM_LIB" ]] || fail "failed service stop removed the owned release tree"
rm "$FAIL_STOP"
PATH="$FAKE_SYSTEM_BIN:$PATH" FAKE_SYSTEM_STATE="$FAKE_SYSTEM_STATE" FAKE_SYSTEM_LOG="$FAKE_SYSTEM_LOG" \
  "$INSTALLER" uninstall "${SYSTEM_COMMON[@]}"

MARKER_HOME="$TEST_ROOT/marker home"
"$INSTALLER" install --source "$RELEASE_ONE" --home "$MARKER_HOME" --no-systemd
rm "$MARKER_HOME/.local/lib/codex-usage-monitor/.codex-usage-monitor.owned"
assert_fails "uninstall removed an unowned LIB_ROOT" "$INSTALLER" uninstall --home "$MARKER_HOME" --no-systemd
[[ -d "$MARKER_HOME/.local/lib/codex-usage-monitor" ]] || fail "unowned LIB_ROOT was removed"

exec {uninstall_lock_fd}>>"$STATE_HOME/codex-usage-monitor/.monitor.lock"
flock -n "$uninstall_lock_fd"
assert_fails "uninstall ignored a manually held monitor lock" \
  "$INSTALLER" uninstall "${COMMON[@]}"
[[ -d "$LIB_ROOT" ]] || fail "locked uninstall removed the owned release tree"
flock -u "$uninstall_lock_fd"
exec {uninstall_lock_fd}>&-

"$INSTALLER" uninstall "${COMMON[@]}"
[[ ! -e "$LIB_ROOT" ]] || fail "uninstall retained releases"
assert_file "$CONFIG_HOME/codex-usage-monitor/.env"
assert_file "$STATE_HOME/codex-usage-monitor/data.txt"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "${ROOT_DIR}/systemd/codex-usage-monitor.service" "${ROOT_DIR}/systemd/codex-usage-dashboard.service"
fi

printf 'PASS: distribution lifecycle, safety, launchers and reproducible build\n'
