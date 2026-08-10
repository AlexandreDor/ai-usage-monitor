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
analytics_database="${TEST_ROOT}/usage-history.sqlite3"
custom_pricing="${TEST_ROOT}/custom-pricing.json"
python3 - "$ROOT_DIR" "$analytics_database" "$custom_pricing" <<'PY'
import json
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
pricing_path = Path(sys.argv[3])
catalog = json.loads((root / "local" / "pricing.json").read_text(encoding="utf-8"))
for entry in catalog["entries"]:
    if entry["provider"] == "openai" and entry["model"] == "gpt-5.6-sol":
        entry["input_per_million"] = 123.0
        break
else:
    raise AssertionError("fixture pricing entry not found")
pricing_path.write_text(json.dumps(catalog), encoding="utf-8")

sys.path.insert(0, str(root / "local"))
from storage import connect_database

connection = connect_database(Path(sys.argv[2]))
connection.execute(
    """INSERT INTO token_usage_events(
         occurred_at_epoch, source, provider, model, input_tokens,
         cache_read_tokens, cache_write_tokens, output_tokens,
         reasoning_tokens, external_id
       ) VALUES (?, 'codex', 'openai', 'gpt-5.6-sol', 1000000, 0, 0, 0, 0, ?)""",
    (int(time.time()) - 60, "http-custom-pricing"),
)
connection.execute(
    """INSERT INTO collector_runs(
         source, enabled, status, last_attempt_at_epoch,
         last_success_at_epoch, last_error, source_schema
       ) VALUES ('opencode', 1, 'error', ?, NULL,
                 'source path not found: /tmp/private/opencode.db', NULL)""",
    (int(time.time()) - 60,),
)
connection.commit()
connection.close()
PY
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

bash "$SERVE" --port 0 >/dev/null 2>&1 && fail "port zero accepted"
bash "$SERVE" --bind localhost --port 8080 >/dev/null 2>&1 && fail "hostname bind accepted"
bash "$SERVE" --unknown >/dev/null 2>&1 && fail "unknown CLI option accepted"
assert_contains "$(bash "$SERVE" --help)" 'default: 127.0.0.1' "help omits localhost default"

TOKEN_PRICING_FILE="$custom_pricing" DASHBOARD_ANALYTICS_DATABASE="$analytics_database" \
  bash "$SERVE" --port "$port" >"${TEST_ROOT}/server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
  curl --silent --fail "http://127.0.0.1:${port}/dashboard.html" -o "${TEST_ROOT}/dashboard" && break
  sleep 0.05
done
kill -0 "$server_pid" 2>/dev/null || fail "HTTP server did not start"
assert_contains "$(<"${TEST_ROOT}/server.log")" "127.0.0.1:${port}" "default bind was not localhost"
assert_contains "$(<"${TEST_ROOT}/dashboard")" 'Codex Limits' "dashboard asset content"

for path in / /analytics.html /assets/dashboard.js /assets/dashboard.css /assets/preferences.js /assets/analytics.js /assets/analytics.css /assets/chart.umd.min.js /images/favicon.png; do
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}${path}")"
  assert_eq 200 "$code" "allowlisted asset $path"
done

headers="$(curl --silent --dump-header - --output /dev/null "http://127.0.0.1:${port}/dashboard.html")"
assert_contains "$headers" 'Content-Security-Policy:' "CSP header missing"
assert_contains "$headers" 'X-Content-Type-Options: nosniff' "nosniff header missing"
assert_contains "$headers" 'X-Frame-Options: DENY' "frame protection missing"
assert_contains "$headers" 'Cache-Control: no-store' "cache header missing"

for hostile_host in "attacker.example:${port}" "127.0.0.1:1" ''; do
  hostile_code="$(curl --silent -H "Host: ${hostile_host}" --output "${TEST_ROOT}/host-error" \
    --write-out '%{http_code}' "http://127.0.0.1:${port}/dashboard.html")"
  assert_eq 400 "$hostile_code" "hostile or incomplete Host accepted: ${hostile_host:-<empty>}"
  [[ "$(wc -c < "${TEST_ROOT}/host-error")" -le 64 ]] || fail "Host error response was not bounded"
done

python3 - "$port" <<'PY' || fail "saturated HTTP server did not reject immediately"
import socket
import sys
import time

port = int(sys.argv[1])
slow_clients = []
try:
    for _ in range(16):
        client = socket.create_connection(("127.0.0.1", port), timeout=2)
        client.sendall(f"GET /dashboard.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n".encode())
        slow_clients.append(client)
    time.sleep(0.2)
    with socket.create_connection(("127.0.0.1", port), timeout=2) as rejected:
        rejected.sendall(f"GET /dashboard.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
        response = rejected.recv(128)
    if not response.startswith(b"HTTP/1.1 503 "):
        raise AssertionError(response)
finally:
    for client in slow_clients:
        client.close()
PY

for path in /monitor.sh /runtime/.alert_state /runtime/usage-history.sqlite3 '/%2e%2e%2fmonitor.sh' '/%252e%252e%252fmonitor.sh'; do
  code="$(curl --path-as-is --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}${path}")"
  assert_eq 404 "$code" "non-allowlisted path exposed: $path"
done

analytics_code="$(curl --silent --output "${TEST_ROOT}/analytics-error" --write-out '%{http_code}' "http://127.0.0.1:${port}/api/analytics?range=24h")"
assert_eq 200 "$analytics_code" "analytics API response"
assert_eq 1 "$(json_field "${TEST_ROOT}/analytics-error" schema_version)" "analytics schema version"
assert_eq 123.0 "$(json_field "${TEST_ROOT}/analytics-error" tokens.summary.estimated_cost_usd)" "custom pricing catalog was ignored"
assert_contains "$(<"${TEST_ROOT}/analytics-error")" '<local path>' "collector error was not redacted"
if grep -Fq '/tmp/private' "${TEST_ROOT}/analytics-error"; then
  fail "analytics API exposed a local collector path"
fi
bad_query_code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/api/analytics?range=bad")"
assert_eq 400 "$bad_query_code" "invalid analytics query response"
repeated_breakdown_offset_code="$(curl --silent --output "${TEST_ROOT}/repeated-breakdown-offset-error" --write-out '%{http_code}' \
  "http://127.0.0.1:${port}/api/analytics?range=24h&breakdown_offset=0&breakdown_offset=1&breakdown_limit=50")"
assert_eq 400 "$repeated_breakdown_offset_code" "repeated breakdown_offset accepted"
assert_eq 'query parameters must not be repeated' "$(json_field "${TEST_ROOT}/repeated-breakdown-offset-error" error)" "repeated breakdown_offset error"
for bad_pagination_query in \
  'reset_offset=1&reset_offset=2' \
  'breakdown_offset=0' \
  'reset_limit=101' \
  'breakdown_offset=0&breakdown_limit=101' \
  'reset_offset=1000001' \
  'breakdown_offset=1000001&breakdown_limit=1' \
  'reset_offset=999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999'; do
  pagination_code="$(curl --silent --output "${TEST_ROOT}/pagination-error" --write-out '%{http_code}' \
    "http://127.0.0.1:${port}/api/analytics?range=24h&${bad_pagination_query}")"
  assert_eq 400 "$pagination_code" "invalid analytics pagination accepted: $bad_pagination_query"
  [[ "$(wc -c < "${TEST_ROOT}/pagination-error")" -le 256 ]] || fail "pagination error response was not bounded"
done
for boundary_pagination_query in \
  'reset_offset=1000000&reset_limit=1' \
  'breakdown_offset=1000000&breakdown_limit=1'; do
  pagination_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:${port}/api/analytics?range=24h&${boundary_pagination_query}")"
  assert_eq 200 "$pagination_code" "analytics pagination boundary rejected: $boundary_pagination_query"
done
extreme_date_code="$(curl --silent --output "${TEST_ROOT}/extreme-date-error" --write-out '%{http_code}' "http://127.0.0.1:${port}/api/analytics?from_date=9999-12-31&to_date=9999-12-31")"
assert_eq 400 "$extreme_date_code" "out-of-range analytics date response"
assert_eq 'dates must use YYYY-MM-DD' "$(json_field "${TEST_ROOT}/extreme-date-error" error)" "out-of-range analytics date body"
kill -0 "$server_pid" 2>/dev/null || fail "HTTP server stopped after invalid analytics date"

valid_pricing="${TEST_ROOT}/valid-pricing.json"
cp "$custom_pricing" "$valid_pricing"
printf '{invalid\n' > "$custom_pricing"
pricing_error_code="$(curl --silent --output "${TEST_ROOT}/pricing-error" --write-out '%{http_code}' "http://127.0.0.1:${port}/api/analytics?range=24h")"
assert_eq 503 "$pricing_error_code" "invalid pricing catalog response"
assert_eq 'pricing catalog cannot be read' "$(json_field "${TEST_ROOT}/pricing-error" error)" "invalid pricing catalog body"
cp "$valid_pricing" "$custom_pricing"

# Exercise serve.sh's non-executable .env parser in an isolated fixture so
# the developer's real local/.env is never read or modified by the test.
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
serve_fixture="${TEST_ROOT}/serve-fixture"
serve_state="${TEST_ROOT}/serve state with spaces"
mkdir -p "$serve_fixture"
mkdir -p "$serve_state"
cp "$SERVE" "$ROOT_DIR/local/config.py" "$ROOT_DIR/local/analytics.py" "$ROOT_DIR/local/storage.py" "$ROOT_DIR/local/token_usage.py" "$serve_fixture/"
printf "TOKEN_PRICING_FILE='%s'\n" "$custom_pricing" > "${serve_fixture}/.env"
chmod 600 "${serve_fixture}/.env"
printf '{"state":"explicit"}\n' > "${serve_state}/data.json"
env_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
DASHBOARD_ANALYTICS_DATABASE="$analytics_database" \
  bash "${serve_fixture}/serve.sh" --config "${serve_fixture}/.env" --state-dir "$serve_state" --port "$env_port" >"${TEST_ROOT}/env-server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
  curl --silent --fail "http://127.0.0.1:${env_port}/api/analytics?range=24h" -o "${TEST_ROOT}/env-analytics" && break
  sleep 0.05
done
kill -0 "$server_pid" 2>/dev/null || fail "HTTP server using .env pricing did not start"
assert_eq 123.0 "$(json_field "${TEST_ROOT}/env-analytics" tokens.summary.estimated_cost_usd)" "pricing catalog from .env was ignored"
curl --silent --fail "http://127.0.0.1:${env_port}/data.json" -o "${TEST_ROOT}/env-data"
assert_eq explicit "$(json_field "${TEST_ROOT}/env-data" state)" "explicit server state directory was ignored"

secret_file="${TEST_ROOT}/server-secret"
printf 'must-not-be-served\n' > "$secret_file"
for public_name in data.json history.json; do
  rm -f "${serve_state}/${public_name}"
  ln -s "$secret_file" "${serve_state}/${public_name}"
  symlink_code="$(curl --silent --output "${TEST_ROOT}/symlink-response" --write-out '%{http_code}' \
    "http://127.0.0.1:${env_port}/${public_name}")"
  assert_eq 404 "$symlink_code" "symlink ${public_name} was served"
  if grep -Fq 'must-not-be-served' "${TEST_ROOT}/symlink-response"; then
    fail "symlink ${public_name} disclosed its target"
  fi
done

if grep -Fq 'Traceback' "${TEST_ROOT}/server.log" "${TEST_ROOT}/env-server.log"; then
  fail "HTTP errors emitted a traceback"
fi

printf 'PASS: local HTTP server tests\n'
