#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"

SERVE="${ROOT_DIR}/local/serve.sh"
port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
server_pid=""
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

bash "$SERVE" --port 0 >/dev/null 2>&1 && fail "port zero accepted"
bash "$SERVE" --bind localhost --port 8080 >/dev/null 2>&1 && fail "hostname bind accepted"
bash "$SERVE" --unknown >/dev/null 2>&1 && fail "unknown CLI option accepted"
assert_contains "$(bash "$SERVE" --help)" 'default: 127.0.0.1' "help omits localhost default"

bash "$SERVE" --port "$port" >"${TEST_ROOT}/server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
  curl --silent --fail "http://127.0.0.1:${port}/dashboard.html" -o "${TEST_ROOT}/dashboard" && break
  sleep 0.05
done
kill -0 "$server_pid" 2>/dev/null || fail "HTTP server did not start"
assert_contains "$(<"${TEST_ROOT}/server.log")" "127.0.0.1:${port}" "default bind was not localhost"
assert_contains "$(<"${TEST_ROOT}/dashboard")" 'Codex Limits' "dashboard asset content"

for path in / /assets/dashboard.js /assets/dashboard.css /assets/chart.umd.min.js /images/favicon.png; do
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}${path}")"
  assert_eq 200 "$code" "allowlisted asset $path"
done

headers="$(curl --silent --dump-header - --output /dev/null "http://127.0.0.1:${port}/dashboard.html")"
assert_contains "$headers" 'Content-Security-Policy:' "CSP header missing"
assert_contains "$headers" 'X-Content-Type-Options: nosniff' "nosniff header missing"
assert_contains "$headers" 'X-Frame-Options: DENY' "frame protection missing"
assert_contains "$headers" 'Cache-Control: no-store' "cache header missing"

for path in /monitor.sh /runtime/.alert_state /runtime/usage-history.sqlite3 '/%2e%2e%2fmonitor.sh' '/%252e%252e%252fmonitor.sh'; do
  code="$(curl --path-as-is --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}${path}")"
  assert_eq 404 "$code" "non-allowlisted path exposed: $path"
done

printf 'PASS: local HTTP server tests\n'
