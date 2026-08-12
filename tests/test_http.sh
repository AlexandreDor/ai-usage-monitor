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

for path in /monitor.sh /runtime/.alert_state /runtime/alert-deliveries.json /runtime/usage-history.sqlite3 '/%2e%2e%2fmonitor.sh' '/%252e%252e%252fmonitor.sh'; do
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
mkdir -p "$serve_fixture"
cp "$SERVE" "$ROOT_DIR/local/analytics.py" "$ROOT_DIR/local/storage.py" "$ROOT_DIR/local/token_usage.py" "$serve_fixture/"
printf "TOKEN_PRICING_FILE='%s'\n" "$custom_pricing" > "${serve_fixture}/.env"
env_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
DASHBOARD_ANALYTICS_DATABASE="$analytics_database" \
  bash "${serve_fixture}/serve.sh" --port "$env_port" >"${TEST_ROOT}/env-server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
  curl --silent --fail "http://127.0.0.1:${env_port}/api/analytics?range=24h" -o "${TEST_ROOT}/env-analytics" && break
  sleep 0.05
done
kill -0 "$server_pid" 2>/dev/null || fail "HTTP server using .env pricing did not start"
assert_eq 123.0 "$(json_field "${TEST_ROOT}/env-analytics" tokens.summary.estimated_cost_usd)" "pricing catalog from .env was ignored"

printf 'PASS: local HTTP server tests\n'
