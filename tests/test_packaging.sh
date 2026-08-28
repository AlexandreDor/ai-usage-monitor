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
changelog_heading="$(awk -v expected="## [$version]" '
  index($0, expected) != 1 { next }
  {
    suffix = substr($0, length(expected) + 1)
    if (suffix == "" || suffix ~ /^ - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
      print $0
      exit
    }
  }
' "${ROOT_DIR}/CHANGELOG.md")"
[[ -n "$changelog_heading" ]] || fail "CHANGELOG has no heading for VERSION"

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
assert_file "$release_workflow"
release_workflow_text="$(<"$release_workflow")"
assert_contains "$release_workflow_text" "git merge-base --is-ancestor \"\$GITHUB_SHA\" origin/dev" "release workflow rejects tags outside dev"
assert_contains "$release_workflow_text" 'prerelease=(--prerelease)' "release workflow marks pre-releases as such"

job_block() {
  local job="$1"
  awk -v job="$job" '
    $0 == "  " job ":" { inside = 1; next }
    inside && $0 ~ /^  [^[:space:]][^:]*:$/ { exit }
    inside { print }
  ' "$release_workflow"
}

validate_job="$(job_block validate)"
publish_job="$(job_block publish)"
[[ -n "$validate_job" ]] || fail "release workflow has no validate job"
[[ -n "$publish_job" ]] || fail "release workflow has no publish job"
assert_contains "$validate_job" "permissions:" "release validation job declares permissions"
assert_contains "$validate_job" "contents: read" "release validation job is read-only"
assert_contains "$publish_job" "needs: validate" "release publication depends on validation"
assert_contains "$publish_job" "permissions:" "release publication job declares permissions"
assert_contains "$publish_job" "contents: write" "release publication job can create releases"
if grep -Eq '^permissions:[[:space:]]*$' "$release_workflow"; then
  fail "release workflow must not grant permissions globally"
fi
if grep -q 'contents: write' <<< "$validate_job"; then
  fail "release validation job must not have write permission"
fi
if grep -q 'contents: read' <<< "$publish_job"; then
  fail "release publication job must not use read-only permission"
fi
if grep -Eq '^  release:[[:space:]]*$' "$release_workflow"; then
  fail "release workflow must split validation from publication"
fi
assert_contains "$validate_job" "outputs:" "release validation exposes the source version"
assert_contains "$validate_job" "persist-credentials: false" "release checkout does not persist credentials"
if grep -Eq 'persist-credentials:[[:space:]]*true' "$release_workflow"; then
  fail "release checkout must not persist credentials"
fi

action_ref_re='^[[:space:]]*uses:[[:space:]]actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}[[:space:]]+# v[0-9]'
while IFS= read -r action_line; do
  [[ "$action_line" =~ $action_ref_re ]] || fail "release action is not pinned to a commented full SHA: $action_line"
done < <(grep -E '^[[:space:]]*uses:' "$release_workflow")
if grep -Eq '^[[:space:]]*uses:[^#]*@(v[0-9]|main|master)' "$release_workflow"; then
  fail "release workflow contains an unpinned action reference"
fi

assert_contains "$validate_job" "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02" "release assets are transferred by artifact"
assert_contains "$validate_job" "name: release-assets" "release artifact has a stable name"
assert_contains "$validate_job" "if-no-files-found: error" "release artifact fails when an asset is missing"
assert_contains "$publish_job" "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093" "publication downloads the release artifact"
assert_contains "$publish_job" "path: dist" "publication downloads assets into dist"
assert_contains "$publish_job" "gh release create" "publication creates the GitHub release"
version_output="version: \${{ steps.validate_version.outputs.version }}"
assert_contains "$validate_job" "$version_output" "release version output is wired safely"
published_asset_prefix="\"dist/codex-usage-monitor-\${RELEASE_VERSION}"
archive_asset="dist/codex-usage-monitor-\${RELEASE_VERSION}.tar.gz"
checksum_asset="dist/codex-usage-monitor-\${RELEASE_VERSION}.tar.gz.sha256"
assert_contains "$publish_job" "$archive_asset" "publication uploads the archive"
assert_contains "$publish_job" "$checksum_asset" "publication uploads the checksum"
published_asset_count="$(grep -F -c "$published_asset_prefix" <<< "$publish_job" || true)"
assert_eq "2" "$published_asset_count" "publication has exactly two release assets"
uploaded_asset_prefix="dist/codex-usage-monitor-\${{ steps.validate_version.outputs.version }}"
uploaded_asset_count="$(grep -F -c "$uploaded_asset_prefix" <<< "$validate_job" || true)"
assert_eq "2" "$uploaded_asset_count" "artifact contains exactly two release assets"
assert_contains "$validate_job" '.*\.(sqlite3|db|sqlite)$' "release validation excludes database files"
assert_contains "$validate_job" '.*-(wal|shm|journal)$' "release validation excludes SQLite sidecars"

if grep -q 'GH_TOKEN' <<< "$validate_job"; then
  fail "release validation job must not receive GH_TOKEN"
fi
assert_eq "1" "$(grep -c 'GH_TOKEN:' "$release_workflow")" "GH_TOKEN is scoped to publication"
if grep -Eq 'actions/(checkout|setup-python|setup-node)|npm ci|pip install|tests/|scripts/' <<< "$publish_job"; then
  fail "publication job must not execute repository code or tests"
fi

printf 'PASS: packaging and release tests\n'
