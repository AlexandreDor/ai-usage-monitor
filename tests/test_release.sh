#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-release-test.XXXXXX")"
trap 'rm -rf "$release_dir"' EXIT

cd "$ROOT_DIR"
scripts/release.sh --check >/dev/null
scripts/release.sh --output-dir "$release_dir" >/dev/null

version="$(tr -d '[:space:]' < VERSION)"
archive="ai-usage-monitor-${version}.tar.gz"
(cd "$release_dir" && sha256sum -c "${archive}.sha256")

tar_contents="$(tar -tzf "$release_dir/$archive")"
for required in './VERSION' './local/config.py' './local/history.py' './systemd/codex-usage-monitor@.service'; do
  [[ "$tar_contents" == *"$required"* ]] || {
    echo "FAIL: release archive misses $required" >&2
    exit 1
  }
done
if printf '%s\n' "$tar_contents" | rg -q '(^|/)local/\.env$|(^|/)local/runtime(/|$)'; then
  echo "FAIL: release archive contains local secrets or runtime state" >&2
  exit 1
fi

printf 'PASS: release archive and checksum tests\n'
