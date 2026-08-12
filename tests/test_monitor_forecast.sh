#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test_helper.sh"
# shellcheck source=local/monitor.sh
source "$MONITOR_PATH"
use_test_runtime
monitor_defaults
CODEX_FORECAST_ENABLED=1

FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_BIN"
ln -s "${ROOT_DIR}/tests/fixtures/fake-curl.sh" "${FAKE_BIN}/curl"
export PATH="${FAKE_BIN}:$PATH"
export FAKE_CURL_LOG="${TEST_ROOT}/curl.log"
export FAKE_CURL_STATUS=200 FAKE_CURL_EXIT=0
export FAKE_CURL_BODY='{"chanceToday":0.755,"chanceSoon":0.098,"generatedAt":"2026-08-12T17:17:44.634Z"}'

forecast="$(fetch_codex_forecast)"
assert_eq 76 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["chance_24h_pct"])' <<<"$forecast")" "24-hour chance was not rounded"
assert_eq 10 "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["chance_6h_pct"])' <<<"$forecast")" "6-hour chance was not rounded"
assert_eq '2026-08-12T17:17:44Z' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["generated_at"])' <<<"$forecast")" "forecast timestamp was not normalized"

snapshot='{"five_h_pct":80,"weekly_pct":60,"five_h_reset":"later","weekly_reset":"later","scraped_at":"2026-08-12T17:15:00Z","sample_interval_seconds":900,"history_window_hours":192,"limit_id":"test"}'
enriched="$(enrich_snapshot_with_codex_forecast "$snapshot")"
write_local_snapshot "$enriched" 900 >/dev/null
assert_eq 76 "$(json_field "$DATA_FILE" codex_forecast.chance_24h_pct)" "forecast missing from data.json"
assert_eq false "$(python3 -c 'import json,sys; print(str("codex_forecast" in json.load(open(sys.argv[1], encoding="utf-8"))[0]).lower())' "$HISTORY_FILE")" "forecast leaked into history.json"

export FAKE_CURL_BODY='{invalid'
fetch_codex_forecast >/dev/null 2>&1 && fail "invalid forecast JSON was accepted"
export FAKE_CURL_BODY='{"chanceToday":1.01,"chanceSoon":0.1,"generatedAt":"2026-08-12T17:17:44Z"}'
fetch_codex_forecast >/dev/null 2>&1 && fail "out-of-range forecast probability was accepted"
export FAKE_CURL_STATUS=503 FAKE_CURL_BODY='{}'
fetch_codex_forecast >/dev/null 2>&1 && fail "unavailable forecast endpoint was accepted"

archive_argument="${TEST_ROOT}/archive-argument.json"
local_argument="${TEST_ROOT}/local-argument.json"
gist_argument="${TEST_ROOT}/gist-argument.json"
fetch_status_json() { printf '%s\n' "$snapshot"; }
enrich_snapshot_with_codex_forecast() {
  python3 - "$1" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
value["codex_forecast"] = {"chance_24h_pct": 76, "chance_6h_pct": 10, "generated_at": "2026-08-12T17:17:44Z"}
print(json.dumps(value))
PY
}
archive_snapshot() { printf '%s\n' "$1" > "$archive_argument"; }
write_local_snapshot() { printf '%s\n' "$1" > "$local_argument"; }
sync_gist() { printf '%s\n' "$1" > "$gist_argument"; }
check_thresholds() { return 0; }
collect_token_usage() { return 0; }
run_cycle 900 >/dev/null || fail "valid forecast made the monitor cycle fail"
assert_eq false "$(python3 -c 'import json,sys; print(str("codex_forecast" in json.load(open(sys.argv[1], encoding="utf-8"))).lower())' "$archive_argument")" "forecast leaked into SQLite input"
assert_eq true "$(python3 -c 'import json,sys; print(str("codex_forecast" in json.load(open(sys.argv[1], encoding="utf-8"))).lower())' "$local_argument")" "forecast missing from public snapshot input"
assert_eq true "$(python3 -c 'import json,sys; print(str("codex_forecast" in json.load(open(sys.argv[1], encoding="utf-8"))).lower())' "$gist_argument")" "forecast missing from Gist snapshot input"

enrich_snapshot_with_codex_forecast() { return 1; }
run_cycle 900 >/dev/null || fail "forecast failure propagated to the monitor cycle"

printf 'PASS: Codex Forecast collection tests\n'
