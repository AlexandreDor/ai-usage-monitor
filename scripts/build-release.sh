#!/usr/bin/env bash
# Build a deterministic source release from the tracked worktree files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
VERSION_ARG=""
RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
OUTPUT_DIR="${ROOT_DIR}/dist"
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|([0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))(\.((0|[1-9][0-9]*)|([0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)))*)?$'

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh [OPTIONS]

Build codex-usage-monitor-VERSION.tar.gz and its SHA-256 checksum.

Options:
  --version VERSION   Require VERSION to match VERSION (default: VERSION file)
  --tag TAG           Require TAG to be vVERSION (also reads RELEASE_TAG)
  --output-dir DIR    Destination directory (default: ./dist)
  -h, --help          Show this help

SOURCE_DATE_EPOCH defaults to 0 so repeated builds have identical bytes.
Only files tracked by Git are included. The archive never includes .env or
local runtime state.
EOF
}

while (($#)); do
  case "$1" in
    --version)
      (($# >= 2)) || { echo "[ERROR] --version requires a value." >&2; exit 2; }
      VERSION_ARG="$2"
      shift 2
      ;;
    --tag)
      (($# >= 2)) || { echo "[ERROR] --tag requires a value." >&2; exit 2; }
      RELEASE_TAG="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || { echo "[ERROR] --output-dir requires a value." >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$VERSION_ARG" ]]; then
        echo "[ERROR] Unexpected positional argument: $1" >&2
        exit 2
      fi
      VERSION_ARG="$1"
      shift
      ;;
  esac
done

[[ -f "$VERSION_FILE" && ! -L "$VERSION_FILE" ]] || {
  echo "[ERROR] VERSION must be a regular file." >&2
  exit 1
}
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ $SEMVER_RE ]]; then
  echo "[ERROR] VERSION is not a supported SemVer value: $VERSION" >&2
  exit 1
fi
if [[ -n "$VERSION_ARG" && "$VERSION_ARG" != "$VERSION" ]]; then
  echo "[ERROR] requested version $VERSION_ARG does not match VERSION ($VERSION)." >&2
  exit 1
fi
if [[ -n "$RELEASE_TAG" && "$RELEASE_TAG" != "v${VERSION}" ]]; then
  echo "[ERROR] release tag $RELEASE_TAG does not match VERSION ($VERSION)." >&2
  exit 1
fi

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
  echo "[ERROR] SOURCE_DATE_EPOCH must be a non-negative integer." >&2
  exit 1
}

ARCHIVE_BASENAME="codex-usage-monitor-${VERSION}.tar.gz"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_BASENAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
mkdir -p -- "$OUTPUT_DIR"

python3 - "$ROOT_DIR" "$ARCHIVE_PATH" "$VERSION" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import os
import stat
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
archive = Path(sys.argv[2])
version = sys.argv[3]
epoch = int(sys.argv[4])
prefix = f"codex-usage-monitor-{version}"

try:
    listed = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--stage", "-z"], stderr=subprocess.STDOUT
    ).split(b"\0")
except (OSError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"could not enumerate tracked files: {error}") from error

paths: list[tuple[str, int]] = []
for raw in listed:
    if not raw:
        continue
    try:
        index_metadata, raw_path = raw.split(b"\t", 1)
        mode_text = index_metadata.split(b" ", 1)[0].decode("ascii")
        relative = raw_path.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        raise SystemExit(f"tracked path is not UTF-8: {raw!r}") from error
    try:
        mode = int(mode_text, 8)
    except ValueError:
        raise SystemExit(f"tracked path has an unsupported Git mode: {relative}") from None
    if mode not in {0o100644, 0o100755, 0o120000}:
        raise SystemExit(f"tracked path has an unsupported Git mode: {relative}")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise SystemExit(f"unsafe tracked path: {relative}")
    # These files are local secrets/state even if a future change accidentally
    # stages one. Fail closed instead of silently shipping it.
    if (
        pure.name == ".env"
        or "runtime" in pure.parts
        or pure.name in {".alert_state", ".monitor.lock"}
        or pure.suffix in {".sqlite3", ".db", ".sqlite"}
        or pure.name.endswith(("-wal", "-shm", "-journal"))
        or (pure.name.startswith(".env") and pure.name != ".env.example")
    ):
        raise SystemExit(f"refusing to package local state or secrets: {relative}")
    paths.append((relative, mode))

if not any(relative == "VERSION" for relative, _ in paths):
    raise SystemExit("VERSION is not tracked; release builds require committed source files")

entries: set[str] = {prefix}
for relative, _ in paths:
    current = PurePosixPath(prefix) / PurePosixPath(relative)
    entries.update(
        parent.as_posix() for parent in current.parents if parent.as_posix() != "."
    )
    entries.add(current.as_posix())

archive.parent.mkdir(parents=True, exist_ok=True)
temporary = archive.with_name(f".{archive.name}.{os.getpid()}.tmp")
tracked_modes = dict(paths)
try:
    with temporary.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, filename="", mode="wb", mtime=epoch) as gzip_stream:
            with tarfile.TarFile(fileobj=gzip_stream, mode="w", format=tarfile.GNU_FORMAT) as tar:
                root_info = tarfile.TarInfo(prefix)
                root_info.type = tarfile.DIRTYPE
                root_info.mode = 0o755
                root_info.mtime = epoch
                root_info.uid = root_info.gid = 0
                root_info.uname = root_info.gname = ""
                tar.addfile(root_info)
                for entry in sorted(entries):
                    if entry == prefix:
                        continue
                    relative = entry.removeprefix(prefix + "/")
                    source = root / Path(relative)
                    try:
                        metadata = source.lstat()
                    except OSError as error:
                        raise SystemExit(f"tracked file is missing from worktree: {relative}") from error
                    info = tarfile.TarInfo(entry)
                    info.mtime = epoch
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    if stat.S_ISDIR(metadata.st_mode):
                        info.type = tarfile.DIRTYPE
                        info.mode = 0o755
                    elif stat.S_ISLNK(metadata.st_mode):
                        info.type = tarfile.SYMTYPE
                        info.mode = 0o777
                        info.linkname = os.readlink(source)
                    elif stat.S_ISREG(metadata.st_mode):
                        info.mode = 0o755 if tracked_modes[relative] == 0o100755 else 0o644
                        info.size = metadata.st_size
                        with source.open("rb") as content:
                            tar.addfile(info, content)
                        continue
                    else:
                        raise SystemExit(f"unsupported tracked file type: {relative}")
                    tar.addfile(info)
    os.replace(temporary, archive)
except BaseException:
    temporary.unlink(missing_ok=True)
    raise
PY

chmod 0644 -- "$ARCHIVE_PATH"
sha256sum -- "$ARCHIVE_PATH" | sed "s#  .*#  ${ARCHIVE_BASENAME}#" > "$CHECKSUM_PATH"
chmod 0644 -- "$CHECKSUM_PATH"
printf 'Built %s\nChecksum %s\n' "$ARCHIVE_PATH" "$CHECKSUM_PATH"
