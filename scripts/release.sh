#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
OUTPUT_DIR="${ROOT_DIR}/dist"
RELEASE_VERSION=""
FORCE=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [OPTIONS]

Build a source archive and a SHA-256 checksum from the current working tree.

Options:
  --version VERSION  Override VERSION for this archive (does not edit VERSION).
  --output-dir DIR   Write the archive and checksum to DIR (default: dist/).
  --force            Replace an archive/checksum with the same name.
  --check            Verify release metadata and systemd units only.
  -h, --help         Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --version)
      (($# >= 2)) || { echo "[ERROR] --version requires a value." >&2; exit 2; }
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || { echo "[ERROR] --output-dir requires a value." >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$RELEASE_VERSION" ]]; then
  RELEASE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "[ERROR] Release version must follow SemVer (for example 1.2.3)." >&2
  exit 2
fi

required_files=(
  VERSION CHANGELOG.md
  systemd/codex-usage-monitor@.service
  systemd/codex-usage-dashboard@.service
  local/monitor.sh local/serve.sh local/config.py local/history.py
)
for required_file in "${required_files[@]}"; do
  [[ -f "${ROOT_DIR}/${required_file}" ]] || {
    echo "[ERROR] Missing release file: ${required_file}" >&2
    exit 1
  }
done

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify \
    "${ROOT_DIR}/systemd/codex-usage-monitor@.service" \
    "${ROOT_DIR}/systemd/codex-usage-dashboard@.service"
elif (( CHECK_ONLY == 1 )); then
  echo "[WARN] systemd-analyze is unavailable; unit verification was skipped." >&2
fi

if (( CHECK_ONLY == 1 )); then
  echo "[OK] Release metadata and systemd units are valid for ${RELEASE_VERSION}."
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE_NAME="ai-usage-monitor-${RELEASE_VERSION}.tar.gz"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${OUTPUT_DIR}/${CHECKSUM_NAME}"
if (( FORCE == 0 )) && [[ -e "$ARCHIVE_PATH" || -e "$CHECKSUM_PATH" ]]; then
  echo "[ERROR] ${ARCHIVE_NAME} already exists; use --force to replace it." >&2
  exit 1
fi

export TZ=UTC
tar \
  --sort=name \
  --mtime='UTC 1970-01-01' \
  --owner=0 --group=0 --numeric-owner \
  --exclude='./.git' \
  --exclude='./.git/*' \
  --exclude='./.pytest_cache' \
  --exclude='./.pytest_cache/*' \
  --exclude='./node_modules' \
  --exclude='./node_modules/*' \
  --exclude='./test-results' \
  --exclude='./test-results/*' \
  --exclude='./playwright-report' \
  --exclude='./playwright-report/*' \
  --exclude='./coverage' \
  --exclude='./coverage/*' \
  --exclude='./dist' \
  --exclude='./dist/*' \
  --exclude='./local/.env' \
  --exclude='./local/runtime' \
  --exclude='./local/runtime/*' \
  --exclude='./local/.alert_state' \
  --exclude='./local/.monitor.lock' \
  -czf "$ARCHIVE_PATH" -C "$ROOT_DIR" .

(cd "$OUTPUT_DIR" && sha256sum "$ARCHIVE_NAME" > "$CHECKSUM_NAME")
echo "[OK] Created ${ARCHIVE_PATH}"
echo "[OK] Created ${CHECKSUM_PATH}"
