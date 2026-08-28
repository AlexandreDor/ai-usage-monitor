#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

VERSION_FILE="${ROOT_DIR}/VERSION"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build-release.sh"
MONITOR_UNIT="${ROOT_DIR}/packaging/systemd/codex-usage-monitor.service"
DASHBOARD_UNIT="${ROOT_DIR}/packaging/systemd/codex-usage-dashboard.service"
LAN_EXAMPLE="${ROOT_DIR}/packaging/systemd/codex-usage-dashboard.lan.conf.example"

assert_file "$VERSION_FILE"
assert_file "$BUILD_SCRIPT"
assert_file "$MONITOR_UNIT"
assert_file "$DASHBOARD_UNIT"
assert_file "$LAN_EXAMPLE"

version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|([0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))(\.((0|[1-9][0-9]*)|([0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)))*)?$ ]] \
  || fail "VERSION is not a supported SemVer value"
grep -Eq "^## \\[$version\\]( - [0-9]{4}-[0-9]{2}-[0-9]{2})?$" "${ROOT_DIR}/CHANGELOG.md" \
  || fail "CHANGELOG has no heading for VERSION"

assert_contains "$(<"$MONITOR_UNIT")" "User=codex-monitor" "monitor unit runs as the dedicated user"
assert_contains "$(<"$DASHBOARD_UNIT")" "User=codex-monitor" "dashboard unit runs as the dedicated user"
assert_contains "$(<"$MONITOR_UNIT")" "ExecStart=/usr/bin/env bash /opt/codex-usage-monitor/current/local/monitor.sh --loop" "monitor unit path is stable"
assert_contains "$(<"$DASHBOARD_UNIT")" "ExecStart=/usr/bin/env bash /opt/codex-usage-monitor/current/local/serve.sh --bind 127.0.0.1 --port 8080" "dashboard defaults to loopback"
assert_contains "$(<"$MONITOR_UNIT")" "ProtectHome=read-only" "monitor protects home by default"
assert_contains "$(<"$DASHBOARD_UNIT")" "ProtectHome=read-only" "dashboard protects home by default"
assert_eq \
  "ReadWritePaths=/var/lib/codex-usage-monitor /home/codex-monitor/.codex" \
  "$(grep '^ReadWritePaths=' "$MONITOR_UNIT")" \
  "monitor writable paths are limited to runtime state and Codex state"
assert_eq \
  "ReadWritePaths=/var/lib/codex-usage-monitor" \
  "$(grep '^ReadWritePaths=' "$DASHBOARD_UNIT")" \
  "dashboard writable paths exclude Codex state"
if grep -q '^User=root$' "$MONITOR_UNIT" "$DASHBOARD_UNIT"; then
  fail "a packaged unit runs as root"
fi
if grep -q 'EnvironmentFile=' "$MONITOR_UNIT" "$DASHBOARD_UNIT"; then
  fail "units must not delegate dotenv parsing to systemd"
fi
assert_contains "$(<"$LAN_EXAMPLE")" "ExecStart=/usr/bin/env bash /opt/codex-usage-monitor/current/local/serve.sh --bind 192.0.2.20 --port 8080" "LAN override is explicit"

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$MONITOR_UNIT" "$DASHBOARD_UNIT"
else
  printf 'SKIP: systemd-analyze is unavailable; CI installs/has it on Ubuntu.\n'
fi

output_one="$(mktemp -d "${TMPDIR:-/tmp}/codex-release-one.XXXXXX")"
output_two="$(mktemp -d "${TMPDIR:-/tmp}/codex-release-two.XXXXXX")"
trap 'rm -rf -- "$output_one" "$output_two"' EXIT

env -u RELEASE_TAG GITHUB_REF_NAME='52/merge' SOURCE_DATE_EPOCH=0 "$BUILD_SCRIPT" \
  --version "$version" --output-dir "${output_one}/github-ref-name"
SOURCE_DATE_EPOCH=0 "$BUILD_SCRIPT" --version "$version" --tag "v${version}" --output-dir "$output_one"
SOURCE_DATE_EPOCH=0 "$BUILD_SCRIPT" --version "$version" --tag "v${version}" --output-dir "$output_two"
archive_one="${output_one}/codex-usage-monitor-${version}.tar.gz"
archive_two="${output_two}/codex-usage-monitor-${version}.tar.gz"
checksum_one="${archive_one}.sha256"
assert_file "$archive_one"
assert_file "$checksum_one"
cmp "$archive_one" "$archive_two" || fail "release archives are not reproducible"
cmp "$checksum_one" "${archive_two}.sha256" || fail "release checksums are not reproducible"
(cd "$output_one" && sha256sum --check "$(basename -- "$checksum_one")")

# The index, rather than a mutable worktree path, is the release source. A
# directory replaced by an absolute symlink must therefore still archive as
# the staged directory rather than creating an extraction-traversal archive.
builder_fixture="${output_one}/builder-fixture"
git clone --quiet --no-hardlinks "$ROOT_DIR" "$builder_fixture"
cp "$BUILD_SCRIPT" "$builder_fixture/scripts/build-release.sh"
mv "$builder_fixture/local" "$builder_fixture/local.staged"
ln -s "$builder_fixture/local.staged" "$builder_fixture/local"
"$builder_fixture/scripts/build-release.sh" --output-dir "${builder_fixture}/dist"
python3 - "${builder_fixture}/dist/codex-usage-monitor-${version}.tar.gz" "$version" <<'PY'
import tarfile
import sys

archive, version = sys.argv[1:]
prefix = f"codex-usage-monitor-{version}"
with tarfile.open(archive, "r:gz") as handle:
    assert handle.getmember(f"{prefix}/local").isdir()
    assert handle.getmember(f"{prefix}/local/config.py").isfile()
PY

archive_listing="$(tar -tzf "$archive_one")"
assert_contains "$archive_listing" "codex-usage-monitor-${version}/VERSION" "archive has a versioned root"
assert_contains "$archive_listing" "codex-usage-monitor-${version}/packaging/systemd/codex-usage-monitor.service" "archive has monitor unit"
assert_contains "$archive_listing" "codex-usage-monitor-${version}/docs/INSTALL.md" "archive has installation docs"
if grep -Eq '(^|/)(\.env$|runtime/|.*\.sqlite3$|.*\.db$)' <<< "$archive_listing"; then
  fail "release archive contains local secrets or state"
fi
python3 - "$archive_one" "$version" <<'PY'
import stat
import sys
import tarfile

archive, version = sys.argv[1:]
prefix = f"codex-usage-monitor-{version}"
with tarfile.open(archive, "r:gz") as handle:
    assert stat.S_IMODE(handle.getmember(f"{prefix}/README.md").mode) == 0o644
    assert stat.S_IMODE(handle.getmember(f"{prefix}/scripts/build-release.sh").mode) == 0o755
PY

if "$BUILD_SCRIPT" --tag "v999.999.999" --output-dir "$output_one" >/dev/null 2>&1; then
  fail "mismatched release tag was accepted"
fi

release_workflow="${ROOT_DIR}/.github/workflows/release.yml"
assert_contains "$(<"$release_workflow")" "git merge-base --is-ancestor \"\$GITHUB_SHA\" origin/dev" "release workflow permits non-dev tags"
assert_contains "$(<"$release_workflow")" 'prerelease=(--prerelease)' "release workflow publishes pre-releases as stable"

printf 'PASS: packaging and release tests\n'
