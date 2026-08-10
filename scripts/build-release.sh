#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-release.sh [--output DIRECTORY] [--require-clean]

Build a deterministic release archive from paths listed by git ls-files.
SOURCE_DATE_EPOCH must be set to a non-negative integer.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/dist"
REQUIRE_CLEAN=0

while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || { printf 'ERROR: --output requires a value\n' >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --require-clean)
      REQUIRE_CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
  printf 'ERROR: SOURCE_DATE_EPOCH must be a non-negative integer\n' >&2
  exit 2
}

for command_name in git gzip python3 sha256sum sort tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

cd "$ROOT_DIR"
git rev-parse --is-inside-work-tree >/dev/null
if [[ "$REQUIRE_CLEAN" == 1 ]] && [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  printf 'ERROR: --require-clean requires a clean worktree and index\n' >&2
  exit 1
fi
git ls-files --error-unmatch VERSION >/dev/null 2>&1 || {
  printf 'ERROR: VERSION must be tracked by git\n' >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
TEMP_DIR="$(mktemp -d "${OUTPUT_DIR}/.release.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

git ls-files -z | LC_ALL=C sort -z > "${TEMP_DIR}/files"
[[ -s "${TEMP_DIR}/files" ]] || { printf 'ERROR: git ls-files returned no paths\n' >&2; exit 1; }

mkdir "${TEMP_DIR}/index"
git checkout-index --all --prefix="${TEMP_DIR}/index/"
# Validate and name the archive from the packaged index, not the worktree.
# shellcheck source=scripts/semver.sh
source "${TEMP_DIR}/index/scripts/semver.sh"
# shellcheck source=scripts/archive-limits.sh
source "${TEMP_DIR}/index/scripts/archive-limits.sh"
VERSION="$(<"${TEMP_DIR}/index/VERSION")"
semver_valid "$VERSION" || {
  printf 'ERROR: invalid SemVer in VERSION: %s\n' "$VERSION" >&2
  exit 1
}
ARCHIVE_NAME="codex-usage-monitor-${VERSION}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
while IFS= read -r -d '' path; do
  [[ -f "${TEMP_DIR}/index/${path}" && ! -L "${TEMP_DIR}/index/${path}" ]] || {
    printf 'ERROR: release path must be a non-symlink regular file: %s\n' "$path" >&2
    exit 1
  }
done < "${TEMP_DIR}/files"

tar --create --directory="${TEMP_DIR}/index" --null --files-from="${TEMP_DIR}/files" \
  --hard-dereference \
  --format=posix --sort=name --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
  --pax-option=delete=atime,delete=ctime \
  --transform="s,^,codex-usage-monitor-${VERSION}/," \
  --file="${TEMP_DIR}/release.tar"
gzip --no-name --best < "${TEMP_DIR}/release.tar" > "${TEMP_DIR}/${ARCHIVE_NAME}"
python3 "${TEMP_DIR}/index/scripts/validate-archive.py" release \
  "${TEMP_DIR}/${ARCHIVE_NAME}" \
  "$RELEASE_ARCHIVE_MAX_BYTES" "$RELEASE_ARCHIVE_MAX_MEMBERS" \
  "$RELEASE_ARCHIVE_MAX_MEMBER_BYTES" "$RELEASE_ARCHIVE_MAX_TOTAL_BYTES" >/dev/null
mv -f "${TEMP_DIR}/${ARCHIVE_NAME}" "$ARCHIVE_PATH"

(
  cd "$OUTPUT_DIR"
  sha256sum "$ARCHIVE_NAME" > SHA256SUMS
)

printf 'Built %s\n' "$ARCHIVE_PATH"
