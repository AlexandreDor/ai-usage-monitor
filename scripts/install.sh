#!/usr/bin/env bash

set -euo pipefail
umask 077

PROGRAM="codex-usage-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/semver.sh
source "${SCRIPT_DIR}/semver.sh"
# shellcheck source=scripts/archive-limits.sh
source "${SCRIPT_DIR}/archive-limits.sh"

SERVICES=(codex-usage-monitor.service codex-usage-dashboard.service)
RUNTIME_FILES=(
  VERSION local/.env.example local/alerts.py local/analytics.html local/analytics.py
  local/archive.py local/assets/analytics.css local/assets/analytics.js
  local/assets/chart.umd.min.js local/assets/dashboard.css local/assets/dashboard.js
  local/assets/preferences.js local/codex_status.py local/config.py local/dashboard.html
  local/history.py local/images/favicon.png local/monitor.sh local/monitor_utils.py
  local/pricing.json local/serve.sh local/storage.py local/token_usage.py
  scripts/archive-limits.sh scripts/install.sh scripts/release-files.txt scripts/semver.sh
  scripts/validate-archive.py systemd/codex-usage-monitor.service
  systemd/codex-usage-dashboard.service
)

usage() {
  cat <<'EOF'
Usage: install.sh COMMAND [OPTIONS]

Commands:
  install                 Install a release (defaults to this extracted tree)
  update                  Install and atomically activate another release
  rollback [VERSION]      Activate VERSION, or swap current and previous
  backup                  Back up persistent configuration and state
  restore                 Restore persistent configuration and state
  uninstall               Remove software while preserving data by default

Release options:
  --source DIRECTORY      Git checkout or extracted release directory
  --archive FILE          .tar.gz release archive
  --checksum FILE         SHA256SUMS file required with --archive

Path options:
  --home DIRECTORY
  --xdg-config-home DIRECTORY
  --xdg-state-home DIRECTORY
  --lib-root DIRECTORY
  --bin-dir DIRECTORY
  --systemd-dir DIRECTORY
  --no-systemd

Backup options:
  --output FILE           Backup destination
  --backup FILE           Backup to restore

Uninstall option:
  --purge                 Also delete configuration and state
EOF
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

reject_control_characters() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] || fail "paths must not contain control characters"
}

canonical_path() {
  local label="$1" value="$2"
  reject_control_characters "$value"
  [[ "$value" == /* ]] || fail "${label} must be an absolute path: ${value}"
  realpath --canonicalize-missing -- "$value"
}

paths_overlap() {
  [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
}

validate_layout() {
  local -a names=(LIB_ROOT CONFIG_DIR STATE_DIR BIN_DIR SYSTEMD_DIR)
  local first second first_name second_name first_value second_value
  for first_name in "${names[@]}"; do
    first_value="${!first_name}"
    [[ "$first_value" != / ]] || fail "${first_name} must not be the filesystem root"
  done
  for ((first = 0; first < ${#names[@]}; first++)); do
    for ((second = first + 1; second < ${#names[@]}; second++)); do
      first_name="${names[first]}"
      second_name="${names[second]}"
      first_value="${!first_name}"
      second_value="${!second_name}"
      paths_overlap "$first_value" "$second_value" && \
        fail "unsafe overlapping paths: ${first_name}=${first_value} and ${second_name}=${second_value}"
    done
  done
  [[ "$LIB_ROOT" != "$HOME_DIR" && "$HOME_DIR" != "$LIB_ROOT"/* ]] || \
    fail "LIB_ROOT must not be HOME or an ancestor of HOME: ${LIB_ROOT}"
}

ensure_owned_lib_root() {
  local marker="${LIB_ROOT}/.${PROGRAM}.owned" entry
  if [[ -e "$LIB_ROOT" ]]; then
    [[ -d "$LIB_ROOT" && ! -L "$LIB_ROOT" ]] || fail "LIB_ROOT must be a non-symlink directory"
  else
    mkdir -p -- "$LIB_ROOT"
  fi
  if [[ -e "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$PROGRAM" ]] || \
      fail "LIB_ROOT ownership marker is invalid: ${marker}"
    return 0
  fi
  for entry in "$LIB_ROOT"/* "$LIB_ROOT"/.[!.]* "$LIB_ROOT"/..?*; do
    [[ ! -e "$entry" && ! -L "$entry" ]] || fail "refusing to claim non-empty LIB_ROOT without ownership marker: ${LIB_ROOT}"
  done
  printf '%s\n' "$PROGRAM" > "$marker"
  chmod 600 "$marker"
}

assert_owned_lib_root() {
  local marker="${LIB_ROOT}/.${PROGRAM}.owned"
  [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$PROGRAM" ]] || \
    fail "refusing destructive operation without a valid LIB_ROOT ownership marker: ${marker}"
}

atomic_symlink() {
  local target="$1" link="$2" temporary
  temporary="${link}.tmp.$$"
  rm -f -- "$temporary"
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
}

systemd_available() {
  [[ "$NO_SYSTEMD" == 0 ]] && command -v systemctl >/dev/null 2>&1
}

systemctl_user() {
  systemd_available || return 0
  systemctl --user "$@"
}

service_is_active() {
  local service="$1" status
  if systemctl --user is-active --quiet "$service"; then
    return 0
  else
    status=$?
  fi
  case "$status" in
    3|4) return 1 ;;
    *) fail "cannot determine service state for ${service}" ;;
  esac
}

SERVICES_STOPPED=0
ACTIVE_SERVICES=()

stop_active_services() {
  local service
  ACTIVE_SERVICES=()
  systemd_available || return 0
  for service in "${SERVICES[@]}"; do
    if service_is_active "$service"; then
      ACTIVE_SERVICES+=("$service")
    fi
  done
  SERVICES_STOPPED=1
  ((${#ACTIVE_SERVICES[@]} == 0)) || systemctl --user stop "${ACTIVE_SERVICES[@]}"
  for service in "${ACTIVE_SERVICES[@]}"; do
    ! service_is_active "$service" || fail "service did not stop: ${service}"
  done
}

resume_active_services() {
  local service status=0
  [[ "$SERVICES_STOPPED" == 1 ]] || return 0
  for service in "${ACTIVE_SERVICES[@]}"; do
    systemctl --user start "$service" || status=1
  done
  ((status == 0)) || return 1
  SERVICES_STOPPED=0
}

RESTART_SERVICES=()
RESTART_ERRORS=()

restart_recorded_services() {
  local service status=0
  RESTART_ERRORS=()
  systemd_available || return 0
  for service in "${RESTART_SERVICES[@]}"; do
    if ! systemctl --user restart "$service"; then
      RESTART_ERRORS+=("$service")
      status=1
    fi
  done
  if ((status != 0)); then
    printf 'ERROR: failed to restart service(s): %s\n' "${RESTART_ERRORS[*]}" >&2
  fi
  ((status == 0))
}

restart_running_services() {
  local service
  RESTART_SERVICES=()
  systemd_available || return 0
  for service in "${SERVICES[@]}"; do
    if service_is_active "$service"; then
      RESTART_SERVICES+=("$service")
    fi
  done
  restart_recorded_services
}

write_application_launcher() {
  local path="$1" executable="$2" temporary
  local quoted_config quoted_state quoted_config_root quoted_state_root
  temporary="${path}.tmp.$$"
  printf -v quoted_config '%q' "${CONFIG_DIR}/.env"
  printf -v quoted_state '%q' "$STATE_DIR"
  printf -v quoted_config_root '%q' "$XDG_CONFIG_ROOT"
  printf -v quoted_state_root '%q' "$XDG_STATE_ROOT"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'umask 077'
    printf 'export CODEX_USAGE_MONITOR_CONFIG=%s\n' "$quoted_config"
    printf 'export CODEX_USAGE_MONITOR_STATE_DIR=%s\n' "$quoted_state"
    printf 'export XDG_CONFIG_HOME=%s\n' "$quoted_config_root"
    printf 'export XDG_STATE_HOME=%s\n' "$quoted_state_root"
    # shellcheck disable=SC2016
    printf 'exec %q "$@"\n' "${LIB_ROOT}/current/local/${executable}"
  } > "$temporary"
  chmod 755 "$temporary"
  mv -f -- "$temporary" "$path"
}

write_manager_launcher() {
  local path="$1" temporary
  temporary="${path}.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'umask 077'
    printf 'export CUM_HOME=%q\n' "$HOME_DIR"
    printf 'export XDG_CONFIG_HOME=%q\n' "$XDG_CONFIG_ROOT"
    printf 'export XDG_STATE_HOME=%q\n' "$XDG_STATE_ROOT"
    printf 'export CUM_LIB_ROOT=%q\n' "$LIB_ROOT"
    printf 'export CUM_BIN_DIR=%q\n' "$BIN_DIR"
    printf 'export CUM_SYSTEMD_DIR=%q\n' "$SYSTEMD_DIR"
    [[ "$NO_SYSTEMD" == 0 ]] || printf '%s\n' 'set -- "$@" --no-systemd'
    # shellcheck disable=SC2016
    printf 'exec %q "$@"\n' "${LIB_ROOT}/current/scripts/install.sh"
  } > "$temporary"
  chmod 755 "$temporary"
  mv -f -- "$temporary" "$path"
}

UNIT_TRANSACTION_DIR=""
UNIT_TRANSACTION_ACTIVE=0

rollback_unit_transaction() {
  local unit destination
  [[ "$UNIT_TRANSACTION_ACTIVE" == 1 ]] || return 0
  for unit in "${SERVICES[@]}"; do
    destination="${SYSTEMD_DIR}/${unit}"
    if [[ -e "${UNIT_TRANSACTION_DIR}/old-present-${unit}" ]]; then
      cp -p -- "${UNIT_TRANSACTION_DIR}/old/${unit}" "$destination" || true
    else
      rm -f -- "$destination"
    fi
  done
  systemctl_user daemon-reload || true
  rm -rf -- "$UNIT_TRANSACTION_DIR"
  UNIT_TRANSACTION_DIR=""
  UNIT_TRANSACTION_ACTIVE=0
}

commit_unit_transaction() {
  [[ "$UNIT_TRANSACTION_ACTIVE" == 1 ]] || return 0
  rm -rf -- "$UNIT_TRANSACTION_DIR"
  UNIT_TRANSACTION_DIR=""
  UNIT_TRANSACTION_ACTIVE=0
}

install_units() {
  local release="$1" unit source_unit destination escaped_bin_dir line
  [[ "$NO_SYSTEMD" == 0 ]] || return 0
  mkdir -p -- "$SYSTEMD_DIR"
  UNIT_TRANSACTION_DIR="$(mktemp -d "${SYSTEMD_DIR}/.${PROGRAM}.units.XXXXXX")"
  mkdir "${UNIT_TRANSACTION_DIR}/new" "${UNIT_TRANSACTION_DIR}/old"
  escaped_bin_dir="${BIN_DIR//\\/\\\\}"
  escaped_bin_dir="${escaped_bin_dir//\"/\\\"}"
  escaped_bin_dir="${escaped_bin_dir//%/%%}"
  for unit in "${SERVICES[@]}"; do
    source_unit="${release}/systemd/${unit}"
    destination="${SYSTEMD_DIR}/${unit}"
    [[ ! -e "$destination" || ( -f "$destination" && ! -L "$destination" ) ]] || {
      rm -rf -- "$UNIT_TRANSACTION_DIR"
      UNIT_TRANSACTION_DIR=""
      fail "installed unit path is unsafe: ${destination}"
    }
    if [[ -f "$destination" ]]; then
      cp -p -- "$destination" "${UNIT_TRANSACTION_DIR}/old/${unit}"
      : > "${UNIT_TRANSACTION_DIR}/old-present-${unit}"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == 'Environment="PATH=%h/.local/bin:'* ]]; then
        printf 'Environment="PATH=%s:/usr/local/bin:/usr/bin:/bin"\n' "$escaped_bin_dir"
      else
        printf '%s\n' "$line"
      fi
    done < "$source_unit" > "${UNIT_TRANSACTION_DIR}/new/${unit}"
    chmod 644 "${UNIT_TRANSACTION_DIR}/new/${unit}"
  done
  UNIT_TRANSACTION_ACTIVE=1
  for unit in "${SERVICES[@]}"; do
    if ! mv -f -- "${UNIT_TRANSACTION_DIR}/new/${unit}" "${SYSTEMD_DIR}/${unit}"; then
      rollback_unit_transaction
      return 1
    fi
  done
  if ! systemctl_user daemon-reload; then
    rollback_unit_transaction
    return 1
  fi
}

verify_checksum() {
  local archive="$1" checksum="$2" archive_dir archive_name checksum_path result line verified=0
  [[ -f "$checksum" && ! -L "$checksum" ]] || fail "checksum file not found or is a symlink: ${checksum}"
  (( $(stat -c %s -- "$checksum") <= CHECKSUM_FILE_MAX_BYTES )) || fail "checksum file is too large"
  archive_dir="$(cd "$(dirname "$archive")" && pwd -P)"
  archive_name="$(basename "$archive")"
  checksum_path="$(cd "$(dirname "$checksum")" && pwd -P)/$(basename "$checksum")"
  result="$(cd "$archive_dir" && sha256sum --check --ignore-missing "$checksum_path")" || \
    fail "archive checksum verification failed"
  while IFS= read -r line; do
    [[ "$line" != "${archive_name}: OK" ]] || verified=1
  done <<< "$result"
  [[ "$verified" == 1 ]] || fail "checksum file does not cover archive: ${archive_name}"
}

validate_release_archive() {
  python3 "$SCRIPT_DIR/validate-archive.py" release "$1" \
    "$RELEASE_ARCHIVE_MAX_BYTES" "$RELEASE_ARCHIVE_MAX_MEMBERS" \
    "$RELEASE_ARCHIVE_MAX_MEMBER_BYTES" "$RELEASE_ARCHIVE_MAX_TOTAL_BYTES"
}

copy_manifest_file() {
  local source_root="$1" destination="$2" path="$3" source_path target_path
  [[ "$path" != /* && "$path" != . && "$path" != .. && "$path" != ../* && "$path" != */../* && "$path" != */.. ]] || \
    fail "unsafe release manifest path: ${path}"
  reject_control_characters "$path"
  source_path="${source_root}/${path}"
  target_path="${destination}/${path}"
  [[ -f "$source_path" && ! -L "$source_path" ]] || fail "release path must be a non-symlink regular file: ${path}"
  mkdir -p -- "$(dirname "$target_path")"
  cp --no-dereference --preserve=mode,timestamps -- "$source_path" "$target_path"
  if [[ -x "$source_path" ]]; then
    chmod 755 "$target_path"
  else
    chmod 644 "$target_path"
  fi
}

stage_source() {
  local source_root="$1" destination="$2" git_root path manifest
  git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" && "$(realpath --canonicalize-existing -- "$git_root")" == "$source_root" ]]; then
    while IFS= read -r -d '' path; do
      copy_manifest_file "$source_root" "$destination" "$path"
    done < <(git -C "$source_root" ls-files -z)
  else
    manifest="${source_root}/scripts/release-files.txt"
    [[ -f "$manifest" && ! -L "$manifest" ]] || fail "extracted release is missing scripts/release-files.txt"
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "$path" && "$path" != \#* ]] || continue
      copy_manifest_file "$source_root" "$destination" "$path"
    done < "$manifest"
  fi
}

validate_release() {
  local release="$1" required version
  for required in "${RUNTIME_FILES[@]}"; do
    [[ -f "${release}/${required}" && ! -L "${release}/${required}" ]] || fail "release is missing non-symlink runtime file ${required}"
  done
  version="$(<"${release}/VERSION")"
  semver_valid "$version" || fail "release VERSION is not valid SemVer: ${version}"
  python3 - "$release" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for directory, names, files in os.walk(root, followlinks=False):
    for name in names + files:
        path = pathlib.Path(directory, name)
        if path.is_symlink() or (not path.is_dir() and not path.is_file()):
            raise SystemExit(f"ERROR: release contains a link or special file: {path.relative_to(root)}")
for directory in (root / "local", root / "scripts"):
    for path in directory.glob("*.py"):
        compile(path.read_bytes(), str(path), "exec")
PY
  [[ -x "${release}/local/monitor.sh" && -x "${release}/local/serve.sh" && -x "${release}/scripts/install.sh" ]] || \
    fail "release scripts must be executable"
  bash -n "${release}/local/monitor.sh" "${release}/local/serve.sh" "${release}/scripts/"*.sh
  "${release}/local/monitor.sh" --help >/dev/null
  "${release}/local/serve.sh" --help >/dev/null
  "${release}/scripts/install.sh" --help >/dev/null
  RELEASE_VERSION="$version"
}

prepare_source() {
  local source="$SOURCE" root_entry input_dir archive_copy checksum_copy
  PREPARE_TEMP="$(mktemp -d)"
  if [[ -n "$ARCHIVE" ]]; then
    [[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || fail "archive not found or is a symlink: ${ARCHIVE}"
    (( $(stat -c %s -- "$ARCHIVE") <= RELEASE_ARCHIVE_MAX_BYTES )) || fail "release archive is too large"
    input_dir="${PREPARE_TEMP}/input"
    mkdir "$input_dir"
    archive_copy="${input_dir}/$(basename "$ARCHIVE")"
    checksum_copy="${input_dir}/SHA256SUMS"
    [[ -f "$CHECKSUM" && ! -L "$CHECKSUM" ]] || fail "checksum file not found or is a symlink: ${CHECKSUM}"
    cp --no-dereference -- "$ARCHIVE" "$archive_copy"
    cp --no-dereference -- "$CHECKSUM" "$checksum_copy"
    [[ -f "$archive_copy" && ! -L "$archive_copy" ]] || fail "archive copy is not a regular non-symlink file"
    [[ -f "$checksum_copy" && ! -L "$checksum_copy" ]] || fail "checksum copy is not a regular non-symlink file"
    chmod 600 "$archive_copy" "$checksum_copy"
    verify_checksum "$archive_copy" "$checksum_copy"
    root_entry="$(validate_release_archive "$archive_copy")"
    tar --extract --gzip --file="$archive_copy" --directory="$PREPARE_TEMP" --no-same-owner --no-same-permissions
    rm -rf -- "$input_dir"
    source="${PREPARE_TEMP}/${root_entry}"
  fi
  [[ -n "$source" && -d "$source" && ! -L "$source" ]] || fail "release source directory not found or is a symlink"
  SOURCE_READY="$(realpath --canonicalize-existing -- "$source")"
}

releases_equal() {
  local left="$1" right="$2" path
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" && "$path" != \#* ]] || continue
    cmp -s -- "${left}/${path}" "${right}/${path}" || return 1
    if [[ -x "${left}/${path}" ]]; then
      [[ -x "${right}/${path}" ]] || return 1
    else
      [[ ! -x "${right}/${path}" ]] || return 1
    fi
  done < "${left}/scripts/release-files.txt"
}

activate_release() {
  local version="$1" old_target=""
  [[ -d "${RELEASES_DIR}/${version}" ]] || fail "release is not installed: ${version}"
  [[ ! -L "$CURRENT_LINK" ]] || old_target="$(readlink "$CURRENT_LINK")"
  install_units "${RELEASES_DIR}/${version}" || fail "could not install user units"
  if ! atomic_symlink "releases/${version}" "$CURRENT_LINK"; then
    rollback_unit_transaction
    fail "could not activate release ${version}"
  fi
  if ! restart_running_services; then
    if [[ -n "$old_target" ]]; then
      atomic_symlink "$old_target" "$CURRENT_LINK"
    else
      rm -f -- "$CURRENT_LINK"
    fi
    rollback_unit_transaction
    restart_recorded_services || true
    fail "service restart failed; activation was rolled back"
  fi
  commit_unit_transaction
  if [[ -n "$old_target" && "$old_target" != "releases/${version}" ]]; then
    atomic_symlink "$old_target" "$PREVIOUS_LINK"
  fi
}

install_release() {
  local destination stage config_example
  prepare_source
  # A fresh install has no state directory yet, so create it before opening
  # the shared maintenance lock.
  mkdir -p -- "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  begin_release_maintenance
  ensure_owned_lib_root
  mkdir -p -- "$RELEASES_DIR" "$BIN_DIR" "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  stage="${RELEASES_DIR}/.${PROGRAM}.stage.$$"
  RELEASE_STAGE="$stage"
  rm -rf -- "$stage"
  mkdir "$stage"
  stage_source "$SOURCE_READY" "$stage"
  validate_release "$stage"
  destination="${RELEASES_DIR}/${RELEASE_VERSION}"

  config_example="${stage}/local/.env.example"
  if [[ ! -e "${CONFIG_DIR}/.env" ]]; then
    cp -- "$config_example" "${CONFIG_DIR}/.env"
    chmod 600 "${CONFIG_DIR}/.env"
  elif [[ -L "${CONFIG_DIR}/.env" || ! -f "${CONFIG_DIR}/.env" ]]; then
    fail "configuration must be a non-symlink regular file: ${CONFIG_DIR}/.env"
  fi

  if [[ -e "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] || fail "release destination is unsafe: ${destination}"
    validate_release "$destination"
    releases_equal "$stage" "$destination" || fail "installed version differs from the requested release: ${RELEASE_VERSION}"
    rm -rf -- "$stage"
    RELEASE_STAGE=""
  else
    mv -- "$stage" "$destination"
    RELEASE_STAGE=""
  fi

  write_application_launcher "${BIN_DIR}/codex-usage-monitor" monitor.sh
  write_application_launcher "${BIN_DIR}/codex-usage-dashboard" serve.sh
  write_manager_launcher "${BIN_DIR}/codex-usage-monitor-manage"
  activate_release "$RELEASE_VERSION"
  release_monitor_lock
  printf 'Activated %s %s\n' "$PROGRAM" "$RELEASE_VERSION"
}

rollback_release() {
  local version="${ROLLBACK_VERSION:-}" target
  mkdir -p -- "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  begin_release_maintenance
  [[ -d "$RELEASES_DIR" ]] || fail "no releases are installed"
  if [[ -z "$version" ]]; then
    [[ -L "$PREVIOUS_LINK" ]] || fail "no previous release is recorded"
    target="$(readlink "$PREVIOUS_LINK")"
    [[ "$target" == releases/* && "$target" != */*/* ]] || fail "previous release link is unsafe"
    version="${target#releases/}"
  fi
  semver_valid "$version" || fail "rollback version is not valid SemVer: ${version}"
  validate_release "${RELEASES_DIR}/${version}"
  activate_release "$version"
  release_monitor_lock
  printf 'Rolled back to %s\n' "$version"
}

MONITOR_LOCK_FD=""
MONITOR_LOCK_HELD=0

acquire_monitor_lock() {
  local lock_path="${STATE_DIR}/.monitor.lock"
  command -v flock >/dev/null 2>&1 || fail "flock is required for this maintenance operation"
  mkdir -p -- "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  [[ ! -e "$lock_path" || ( -f "$lock_path" && ! -L "$lock_path" ) ]] || \
    fail "monitor lock path is unsafe: ${lock_path}"
  exec {MONITOR_LOCK_FD}>>"$lock_path"
  chmod 600 "$lock_path"
  if ! flock -n "$MONITOR_LOCK_FD"; then
    exec {MONITOR_LOCK_FD}>&-
    MONITOR_LOCK_FD=""
    fail "monitor activity detected; maintenance was not started"
  fi
  MONITOR_LOCK_HELD=1
}

release_monitor_lock() {
  [[ "$MONITOR_LOCK_HELD" == 1 ]] || return 0
  flock -u "$MONITOR_LOCK_FD" || true
  exec {MONITOR_LOCK_FD}>&-
  MONITOR_LOCK_FD=""
  MONITOR_LOCK_HELD=0
}

assert_services_stopped() {
  local service
  systemd_available || return 0
  for service in "${SERVICES[@]}"; do
    service_is_active "$service" && fail "service must be stopped before maintenance: ${service}"
  done
  return 0
}

begin_maintenance() {
  # Reserve the cycle inode before stopping services so a manual cycle cannot
  # start in the gap between service discovery and lock acquisition.
  acquire_monitor_lock
  stop_active_services
  assert_services_stopped
}

begin_release_maintenance() {
  # Keep services running: activate_release records and restarts active units.
  # The monitor uses a non-blocking flock, so its restarted cycle skips rather
  # than waiting on this lock and deadlocking activation.
  acquire_monitor_lock
}

backup_data() {
  local output="$BACKUP_OUTPUT" output_dir temporary archive_temp
  [[ -n "$output" ]] || output="${HOME_DIR}/${PROGRAM}-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  reject_control_characters "$output"
  [[ "$output" == /* ]] || fail "backup output must be an absolute path"
  [[ ! -L "$output" ]] || fail "backup destination must not be a symlink"
  output_dir="$(canonical_path 'backup output directory' "$(dirname "$output")")"
  mkdir -p -- "$output_dir"
  output="${output_dir}/$(basename "$output")"
  [[ ! -e "$output" || -f "$output" ]] || fail "backup destination must be a regular file"
  paths_overlap "$output" "$CONFIG_DIR" && fail "backup output must be outside configuration and state directories"
  paths_overlap "$output" "$STATE_DIR" && fail "backup output must be outside configuration and state directories"
  begin_maintenance
  PREPARE_TEMP="$(mktemp -d)"
  temporary="$PREPARE_TEMP"
  mkdir "${temporary}/config" "${temporary}/state"
  [[ ! -d "$CONFIG_DIR" ]] || cp -a -- "${CONFIG_DIR}/." "${temporary}/config/"
  [[ ! -d "$STATE_DIR" ]] || cp -a -- "${STATE_DIR}/." "${temporary}/state/"
  archive_temp="$(mktemp "${output_dir}/.${PROGRAM}.backup.XXXXXX")"
  OUTPUT_TEMP="$archive_temp"
  tar --create --gzip --file="$archive_temp" --directory="$temporary" config state
  chmod 600 "$archive_temp"
  validate_backup_archive "$archive_temp"
  mv -Tf -- "$archive_temp" "$output"
  OUTPUT_TEMP=""
  rm -rf -- "$temporary"
  PREPARE_TEMP=""
  resume_active_services || fail "backup succeeded but a previously active service could not be restarted"
  release_monitor_lock
  printf 'Backup written to %s\n' "$output"
}

validate_backup_archive() {
  python3 "$SCRIPT_DIR/validate-archive.py" backup "$1" \
    "$BACKUP_ARCHIVE_MAX_BYTES" "$BACKUP_ARCHIVE_MAX_MEMBERS" \
    "$BACKUP_ARCHIVE_MAX_MEMBER_BYTES" "$BACKUP_ARCHIVE_MAX_TOTAL_BYTES"
}

RESTORE_IN_PROGRESS=0
CONFIG_HAD_OLD=0
STATE_HAD_OLD=0
CONFIG_ACTIVATED=0
STATE_ACTIVATED=0
CONFIG_STAGE=""
STATE_STAGE=""
CONFIG_OLD=""
STATE_OLD=""

rollback_restore() {
  [[ "$RESTORE_IN_PROGRESS" == 1 ]] || return 0
  if [[ "$STATE_ACTIVATED" == 1 ]]; then rm -rf -- "$STATE_DIR"; fi
  if [[ "$CONFIG_ACTIVATED" == 1 ]]; then rm -rf -- "$CONFIG_DIR"; fi
  if [[ "$STATE_HAD_OLD" == 1 && -e "$STATE_OLD" ]]; then mv -- "$STATE_OLD" "$STATE_DIR"; fi
  if [[ "$CONFIG_HAD_OLD" == 1 && -e "$CONFIG_OLD" ]]; then mv -- "$CONFIG_OLD" "$CONFIG_DIR"; fi
  [[ -z "$STATE_STAGE" ]] || rm -rf -- "$STATE_STAGE"
  [[ -z "$CONFIG_STAGE" ]] || rm -rf -- "$CONFIG_STAGE"
  RESTORE_IN_PROGRESS=0
}

restore_data() {
  local backup_copy extraction
  [[ -f "$BACKUP_FILE" && ! -L "$BACKUP_FILE" ]] || fail "backup file not found, not regular, or is a symlink: ${BACKUP_FILE}"
  (( $(stat -c %s -- "$BACKUP_FILE") <= BACKUP_ARCHIVE_MAX_BYTES )) || fail "backup archive is too large"
  PREPARE_TEMP="$(mktemp -d)"
  backup_copy="${PREPARE_TEMP}/backup.tar.gz"
  cp --no-dereference -- "$BACKUP_FILE" "$backup_copy"
  [[ -f "$backup_copy" && ! -L "$backup_copy" ]] || fail "backup copy is not a regular non-symlink file"
  chmod 600 "$backup_copy"
  validate_backup_archive "$backup_copy"
  extraction="${PREPARE_TEMP}/extracted"
  mkdir "$extraction"
  tar --extract --gzip --file="$backup_copy" --directory="$extraction" --no-same-owner --no-same-permissions
  rm -f -- "$backup_copy"

  mkdir -p -- "$(dirname "$CONFIG_DIR")" "$(dirname "$STATE_DIR")"
  CONFIG_STAGE="${CONFIG_DIR}.restore-stage.$$"
  STATE_STAGE="${STATE_DIR}.restore-stage.$$"
  CONFIG_OLD="${CONFIG_DIR}.before-restore.$$"
  STATE_OLD="${STATE_DIR}.before-restore.$$"
  [[ ! -e "$CONFIG_STAGE" && ! -e "$STATE_STAGE" && ! -e "$CONFIG_OLD" && ! -e "$STATE_OLD" ]] || fail "restore staging path already exists"
  mkdir "$CONFIG_STAGE" "$STATE_STAGE"
  cp -a -- "${extraction}/config/." "$CONFIG_STAGE/"
  cp -a -- "${extraction}/state/." "$STATE_STAGE/"
  chmod 700 "$CONFIG_STAGE" "$STATE_STAGE"
  rm -rf -- "$PREPARE_TEMP"
  PREPARE_TEMP=""

  begin_maintenance
  rm -f -- "${STATE_STAGE}/.monitor.lock"
  ln -- "${STATE_DIR}/.monitor.lock" "${STATE_STAGE}/.monitor.lock"
  chmod 600 "${STATE_STAGE}/.monitor.lock"
  RESTORE_IN_PROGRESS=1
  if [[ -e "$CONFIG_DIR" ]]; then CONFIG_HAD_OLD=1; mv -- "$CONFIG_DIR" "$CONFIG_OLD"; fi
  if [[ -e "$STATE_DIR" ]]; then STATE_HAD_OLD=1; mv -- "$STATE_DIR" "$STATE_OLD"; fi
  CONFIG_ACTIVATED=1
  mv -- "$CONFIG_STAGE" "$CONFIG_DIR"
  STATE_ACTIVATED=1
  mv -- "$STATE_STAGE" "$STATE_DIR"
  if ! resume_active_services; then
    systemd_available && systemctl --user stop "${ACTIVE_SERVICES[@]}" || true
    SERVICES_STOPPED=1
    rollback_restore
    resume_active_services || true
    fail "restored services failed to start; data was rolled back"
  fi
  RESTORE_IN_PROGRESS=0
  rm -rf -- "$CONFIG_OLD" "$STATE_OLD"
  release_monitor_lock
  printf 'Configuration and state restored\n'
}

uninstall_release() {
  local path
  for path in "$LIB_ROOT" "$CONFIG_DIR" "$STATE_DIR"; do
    [[ "$path" != "$HOME_DIR" && "$HOME_DIR" != "$path"/* ]] || \
      fail "refusing uninstall path that is HOME or an ancestor of HOME: ${path}"
  done
  assert_owned_lib_root
  begin_maintenance
  if systemd_available; then
    systemctl --user disable "${SERVICES[@]}"
  fi
  rm -f -- "${SYSTEMD_DIR}/${SERVICES[0]}" "${SYSTEMD_DIR}/${SERVICES[1]}"
  rm -f -- "${BIN_DIR}/codex-usage-monitor" "${BIN_DIR}/codex-usage-dashboard" "${BIN_DIR}/codex-usage-monitor-manage"
  rm -rf -- "$LIB_ROOT"
  systemctl_user daemon-reload
  if [[ "$PURGE" == 1 ]]; then
    rm -rf -- "$CONFIG_DIR" "$STATE_DIR"
    printf 'Uninstalled %s and purged configuration and state\n' "$PROGRAM"
  else
    printf 'Uninstalled %s; configuration and state were preserved\n' "$PROGRAM"
  fi
  ACTIVE_SERVICES=()
  SERVICES_STOPPED=0
  release_monitor_lock
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
if [[ "$1" == -h || "$1" == --help ]]; then
  usage
  exit 0
fi
COMMAND="$1"
shift

HOME_DIR="${CUM_HOME:-${HOME:-}}"
[[ -n "$HOME_DIR" ]] || fail "HOME or CUM_HOME must be set"
XDG_CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}"
XDG_STATE_ROOT="${XDG_STATE_HOME:-${HOME_DIR}/.local/state}"
LIB_ROOT="${CUM_LIB_ROOT:-${HOME_DIR}/.local/lib/${PROGRAM}}"
BIN_DIR="${CUM_BIN_DIR:-${HOME_DIR}/.local/bin}"
SYSTEMD_DIR="${CUM_SYSTEMD_DIR:-${XDG_CONFIG_ROOT}/systemd/user}"
[[ -n "${XDG_CONFIG_HOME:-}" ]] && XDG_CONFIG_EXPLICIT=1 || XDG_CONFIG_EXPLICIT=0
[[ -n "${XDG_STATE_HOME:-}" ]] && XDG_STATE_EXPLICIT=1 || XDG_STATE_EXPLICIT=0
[[ -n "${CUM_LIB_ROOT:-}" ]] && LIB_ROOT_EXPLICIT=1 || LIB_ROOT_EXPLICIT=0
[[ -n "${CUM_BIN_DIR:-}" ]] && BIN_DIR_EXPLICIT=1 || BIN_DIR_EXPLICIT=0
[[ -n "${CUM_SYSTEMD_DIR:-}" ]] && SYSTEMD_DIR_EXPLICIT=1 || SYSTEMD_DIR_EXPLICIT=0
SOURCE=""
ARCHIVE=""
CHECKSUM=""
PREPARE_TEMP=""
OUTPUT_TEMP=""
RELEASE_STAGE=""
BACKUP_OUTPUT=""
BACKUP_FILE=""
NO_SYSTEMD=0
PURGE=0
ROLLBACK_VERSION=""

cleanup() {
  local status=$?
  rollback_restore || true
  rollback_unit_transaction || true
  [[ -z "${UNIT_TRANSACTION_DIR:-}" ]] || rm -rf -- "$UNIT_TRANSACTION_DIR"
  if [[ "$SERVICES_STOPPED" == 1 ]]; then
    resume_active_services || printf 'ERROR: failed to restart one or more previously active services\n' >&2
  fi
  release_monitor_lock
  [[ -z "${PREPARE_TEMP:-}" ]] || rm -rf -- "$PREPARE_TEMP"
  [[ -z "${OUTPUT_TEMP:-}" ]] || rm -f -- "$OUTPUT_TEMP"
  [[ -z "${RELEASE_STAGE:-}" ]] || rm -rf -- "$RELEASE_STAGE"
  [[ -z "${CONFIG_STAGE:-}" ]] || rm -rf -- "$CONFIG_STAGE"
  [[ -z "${STATE_STAGE:-}" ]] || rm -rf -- "$STATE_STAGE"
  return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$COMMAND" == rollback && $# -gt 0 && "$1" != --* ]]; then
  ROLLBACK_VERSION="$1"
  shift
fi

while (($#)); do
  case "$1" in
    --source|--archive|--checksum|--home|--xdg-config-home|--xdg-state-home|--lib-root|--bin-dir|--systemd-dir|--output|--backup)
      (($# >= 2)) || fail "$1 requires a value"
      reject_control_characters "$2"
      case "$1" in
        --source) SOURCE="$2" ;;
        --archive) ARCHIVE="$2" ;;
        --checksum) CHECKSUM="$2" ;;
        --home) HOME_DIR="$2" ;;
        --xdg-config-home) XDG_CONFIG_ROOT="$2"; XDG_CONFIG_EXPLICIT=1 ;;
        --xdg-state-home) XDG_STATE_ROOT="$2"; XDG_STATE_EXPLICIT=1 ;;
        --lib-root) LIB_ROOT="$2"; LIB_ROOT_EXPLICIT=1 ;;
        --bin-dir) BIN_DIR="$2"; BIN_DIR_EXPLICIT=1 ;;
        --systemd-dir) SYSTEMD_DIR="$2"; SYSTEMD_DIR_EXPLICIT=1 ;;
        --output) BACKUP_OUTPUT="$2" ;;
        --backup) BACKUP_FILE="$2" ;;
      esac
      shift 2
      ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$XDG_CONFIG_EXPLICIT" == 1 ]] || XDG_CONFIG_ROOT="${HOME_DIR}/.config"
[[ "$XDG_STATE_EXPLICIT" == 1 ]] || XDG_STATE_ROOT="${HOME_DIR}/.local/state"
[[ "$LIB_ROOT_EXPLICIT" == 1 ]] || LIB_ROOT="${HOME_DIR}/.local/lib/${PROGRAM}"
[[ "$BIN_DIR_EXPLICIT" == 1 ]] || BIN_DIR="${HOME_DIR}/.local/bin"
[[ "$SYSTEMD_DIR_EXPLICIT" == 1 ]] || SYSTEMD_DIR="${XDG_CONFIG_ROOT}/systemd/user"

HOME_DIR="$(canonical_path HOME "$HOME_DIR")"
XDG_CONFIG_ROOT="$(canonical_path XDG_CONFIG_HOME "$XDG_CONFIG_ROOT")"
XDG_STATE_ROOT="$(canonical_path XDG_STATE_HOME "$XDG_STATE_ROOT")"
LIB_ROOT="$(canonical_path LIB_ROOT "$LIB_ROOT")"
BIN_DIR="$(canonical_path BIN_DIR "$BIN_DIR")"
SYSTEMD_DIR="$(canonical_path SYSTEMD_DIR "$SYSTEMD_DIR")"
CONFIG_DIR="$(canonical_path CONFIG_DIR "${XDG_CONFIG_ROOT}/${PROGRAM}")"
STATE_DIR="$(canonical_path STATE_DIR "${XDG_STATE_ROOT}/${PROGRAM}")"
RELEASES_DIR="${LIB_ROOT}/releases"
CURRENT_LINK="${LIB_ROOT}/current"
PREVIOUS_LINK="${LIB_ROOT}/previous"
validate_layout

for input_label in archive checksum backup; do
  case "$input_label" in
    archive) input_value="$ARCHIVE" ;;
    checksum) input_value="$CHECKSUM" ;;
    backup) input_value="$BACKUP_FILE" ;;
  esac
  if [[ -n "$input_value" ]]; then
    [[ -f "$input_value" && ! -L "$input_value" ]] || \
      fail "${input_label} must be an existing non-symlink regular file: ${input_value}"
    input_value="$(canonical_path "$input_label" "$input_value")"
  fi
  case "$input_label" in
    archive) ARCHIVE="$input_value" ;;
    checksum) CHECKSUM="$input_value" ;;
    backup) BACKUP_FILE="$input_value" ;;
  esac
done

case "$COMMAND" in
  install)
    [[ -z "$ARCHIVE" || -z "$SOURCE" ]] || fail "use only one of --source and --archive"
    [[ -z "$ARCHIVE" || -n "$CHECKSUM" ]] || fail "--checksum is required with --archive"
    SOURCE="${SOURCE:-$DEFAULT_SOURCE}"
    install_release
    ;;
  update)
    [[ -n "$ARCHIVE" || -n "$SOURCE" ]] || fail "update requires --archive or --source"
    [[ -z "$ARCHIVE" || -z "$SOURCE" ]] || fail "use only one of --source and --archive"
    [[ -z "$ARCHIVE" || -n "$CHECKSUM" ]] || fail "--checksum is required with --archive"
    install_release
    ;;
  rollback) rollback_release ;;
  backup) backup_data ;;
  restore)
    [[ -n "$BACKUP_FILE" ]] || fail "restore requires --backup"
    restore_data
    ;;
  uninstall) uninstall_release ;;
  *) fail "unknown command: ${COMMAND}" ;;
esac
