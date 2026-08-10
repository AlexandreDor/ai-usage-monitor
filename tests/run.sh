#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

coverage_wrapper=""
if [[ "${COVERAGE_RUN:-0}" == "1" ]]; then
  real_python="$(command -v python3)"
  coverage_wrapper="$(mktemp -d)"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016
    printf 'if [[ "${1:-}" == "-" ]]; then\n'
    printf '  shift\n'
    printf '  exec %q -m coverage run --parallel-mode /dev/stdin "$@"\n' "$real_python"
    printf 'fi\n'
    # shellcheck disable=SC2016
    printf 'if [[ "${1:-}" == "-c" || "${1:-}" == "-m" ]]; then\n'
    printf '  exec %q "$@"\n' "$real_python"
    printf 'fi\n'
    printf 'exec %q -m coverage run --parallel-mode "$@"\n' "$real_python"
  } >"$coverage_wrapper/python3"
  chmod +x "$coverage_wrapper/python3"
  export PATH="$coverage_wrapper:$PATH"
fi

cleanup() {
  [[ -z "$coverage_wrapper" ]] || rm -rf "$coverage_wrapper"
}
trap cleanup EXIT

test_status=0
for test_file in "$TEST_DIR"/test_*.sh; do
  if [[ "${COVERAGE_RUN:-0}" == "1" && "$test_file" == "$TEST_DIR/test_distribution.sh" ]]; then
    continue
  fi
  bash "$test_file" || test_status=1
done

if command -v node >/dev/null 2>&1; then
  node "$TEST_DIR/test_preferences.js" || test_status=1
  node "$TEST_DIR/test_dashboard.js" || test_status=1
else
  printf 'FAIL: node is required for dashboard tests\n' >&2
  test_status=1
fi

for test_file in "$TEST_DIR"/test_*.py; do
  python3 "$test_file" || test_status=1
done
if ((test_status != 0)); then
  exit "$test_status"
fi

printf 'PASS: complete test suite\n'
