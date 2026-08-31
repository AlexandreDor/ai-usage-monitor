#!/usr/bin/env bash
# ============================================================================
# Codex Usage Monitor — Local Scraper & Alert Script
# ============================================================================
# Runs on the machine where OpenAI Codex CLI is installed and authenticated.
# Reads limits through the local Codex app-server, writes data.json locally,
# fires Discord/Telegram alerts via direct curl (no server needed), and
# optionally syncs data to a GitHub Gist for external dashboard access.
#
# Usage:
#   ./monitor.sh              # run once
#   ./monitor.sh --loop 900   # run now, then at :00, :15, :30, and :45
#   ./monitor.sh --check      # validate config, runtime and Codex authentication
#   ./monitor.sh --loop --fail-fast  # exit after the first failed cycle
#
# Environment variables (set in .env or export):
#   ALERTS_ENABLED      — global outbound alert switch, default: 1
#   DISCORD_WEBHOOK     — Discord webhook URL (optional)
#   TELEGRAM_BOT_TOKEN  — Telegram bot token from BotFather (optional)
#   TELEGRAM_CHAT_ID    — Telegram numeric chat ID (optional)
#   ALERT_THRESHOLDS    — comma-separated thresholds, default: 75,50,25,10,5
#   ALERT_SCRIPT_N      — absolute path to executable alert hook N (optional)
#   ALERT_SCRIPT_N_EVENTS — events for hook N, e.g. 5h:50,weekly:reset
#   ALERT_SCRIPT_TIMEOUT_SECONDS — per-hook timeout, default: 30, maximum: 1800
#   GITHUB_PAT          — GitHub Personal Access Token with gist scope (optional)
#   GITHUB_GIST_ID      — ID of the GitHub Gist to update (optional)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Packaged installations keep mutable configuration and state outside the
# versioned release tree. These process-only paths are deliberately separate
# from dotenv keys: config.py still parses .env as data and validates it.
ENV_FILE="${CODEX_MONITOR_ENV_FILE:-${SCRIPT_DIR}/.env}"
CONFIG_PY="${SCRIPT_DIR}/config.py"
RUNTIME_DIR="${CODEX_MONITOR_RUNTIME_DIR:-${SCRIPT_DIR}/runtime}"
STATE_FILE="${RUNTIME_DIR}/.alert_state"
ALERT_DELIVERIES_FILE="${RUNTIME_DIR}/alert-deliveries.json"
ALERTS_PY="${SCRIPT_DIR}/alerts.py"
ANOMALIES_PY="${SCRIPT_DIR}/anomalies.py"
HISTORY_PY="${SCRIPT_DIR}/history.py"
CODEX_CLIENT_PY="${SCRIPT_DIR}/codex_client.py"
DATA_FILE="${RUNTIME_DIR}/data.json"
HISTORY_FILE="${RUNTIME_DIR}/history.json"
ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
HEALTH_FILE="${RUNTIME_DIR}/health.json"
HEARTBEAT_FILE="${RUNTIME_DIR}/dashboard-heartbeat"
LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
DEFAULT_INTERVAL_SECONDS=900
DASHBOARD_HEARTBEAT_MAX_AGE_SECONDS=90
DASHBOARD_HEARTBEAT_POLL_SECONDS=5
INVALID_ALERT_SCRIPT_CONFIG=0
RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT=20
RANDOM_WEEKLY_RESET_FULL_REFILL_PCT=98
RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS=$((30 * 60))

usage() {
  cat <<EOF
Usage: ./monitor.sh [--once]
       ./monitor.sh --loop [SECONDS] [--fail-fast]
       ./monitor.sh --check
       ./monitor.sh --status-json
       ./monitor.sh (-h | --help)

Collect and monitor local Codex usage limits.

Modes:
  --once             Run one complete collection cycle (default mode)
  --loop [SECONDS]   Run immediately, then continue on aligned intervals
  --check            Validate configuration, dependencies, Codex access, and analytics sources
  --status-json      Print a sanitized Codex quota snapshot without storing it

Options:
  --fail-fast        Stop loop mode after the first failed collection cycle
  -h, --help         Show this help without loading configuration or contacting Codex

SECONDS must be an integer from 1 to 86400. It overrides LOOP_INTERVAL for
this process. When neither is set, the loop interval defaults to
${DEFAULT_INTERVAL_SECONDS} seconds.

The mode options --once, --loop, --check, and --status-json are mutually
exclusive. --fail-fast can only be used with --loop.

Exit status:
  0  Success or help displayed
  1  Configuration or runtime failure
  2  Invalid command-line usage
EOF
}

cli_error() {
  printf '[ERROR] %s\n\n' "$1" >&2
  usage >&2
  return 2
}


# ============================================================================
# Shared configuration transport
# ============================================================================
config_error() {
  printf '[ERROR] %s\n' "$1" >&2
  return 1
}



ALERT_SCRIPT_RULE_INDICES=()
ALERT_SCRIPT_RULE_PATHS=()
ALERT_SCRIPT_RULE_EVENTS=()
ALERT_SCRIPT_RULE_IDS=()

alert_scripts_configured() {
  local index path_name
  for (( index = 1; index <= 99; index++ )); do
    path_name="ALERT_SCRIPT_${index}"
    [[ -n "${!path_name:-}" ]] && return 0
  done
  return 1
}



# Compatibility seams used by sourced-script tests and local integrations.  A
# real monitor initialization uses the resolved transport in initialize();
# these wrappers deliberately call the same Python parser and validator rather
# than maintaining a second policy in Bash.
load_config() {
  local transport_file warning_file record key encoded value transport_error=0
  [[ -f "$ENV_FILE" ]] || return 0
  transport_file="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-env.XXXXXX")" || {
    config_error "Unable to create a private configuration transport."
    return 1
  }
  warning_file="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-warning.XXXXXX")" || {
    rm -f -- "$transport_file"
    config_error "Unable to create a private configuration transport."
    return 1
  }
  if ! python3 "$CONFIG_PY" --profile monitor --parse-env --env-file "$ENV_FILE" \
      >"$transport_file" 2>"$warning_file"; then
    cat "$warning_file" >&2
    rm -f -- "$transport_file" "$warning_file"
    return 1
  fi
  cat "$warning_file" >&2
  if grep -Fq 'ALERT_SCRIPT_' "$warning_file"; then
    INVALID_ALERT_SCRIPT_CONFIG=1
  fi
  while IFS= read -r -d '' record; do
    key="${record%%$'\t'*}"
    encoded="${record#*$'\t'}"
    value="$(printf '%s' "$encoded" | base64 --decode)" || {
      transport_error=1
      break
    }
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    printf -v "$key" '%s' "$value"
  done <"$transport_file"
  rm -f -- "$transport_file" "$warning_file"
  if (( transport_error )); then
    config_error "Invalid configuration transport."
    return 1
  fi
}

validate_config() {
  local key variable_name transport_file record encoded value rule_index transport_error=0
  if [[ "${INVALID_ALERT_SCRIPT_CONFIG:-0}" == 1 ]]; then
    config_error "Alert script indices must be integers from 1 to 99."
    return 1
  fi
  while IFS= read -r variable_name; do
    case "$variable_name" in
      ALERT_SCRIPT_TIMEOUT_SECONDS|ALERT_SCRIPT_RULE_*) ;;
      ALERT_SCRIPT_[1-9]|ALERT_SCRIPT_[1-9][0-9]|ALERT_SCRIPT_[1-9]_EVENTS|ALERT_SCRIPT_[1-9][0-9]_EVENTS) ;;
      ALERT_SCRIPT_*)
        config_error "Alert script indices must be integers from 1 to 99."
        return 1
        ;;
    esac
  done < <(compgen -A variable ALERT_SCRIPT_ || true)
  local -a config_keys=(
    ALERTS_ENABLED ALERT_THRESHOLDS ALERT_SCRIPT_TIMEOUT_SECONDS ARCHIVE_RETENTION_DAYS
    CODEX_BIN CODEX_DATA_DIR CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD
    CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD CODEX_FORECAST_ENABLED CODEX_STATUS_TIMEOUT_SECONDS
    CURL_CONNECT_TIMEOUT_SECONDS CURL_MAX_TIME_SECONDS CURL_RETRIES CURL_RETRY_DELAY_SECONDS
    DASHBOARD_ACTIVE_INTERVAL_SECONDS DISCORD_WEBHOOK GITHUB_API_URL GITHUB_GIST_ID GITHUB_PAT
    HERMES_DB_PATH HISTORY_RETENTION_HOURS LOOP_INTERVAL MONITOR_DEBUG OPENCODE_DB_PATH
    TELEGRAM_API_URL TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TOKEN_PRICING_FILE TOKEN_USAGE_SOURCES
  )
  transport_file="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-validated.XXXXXX")" || {
    config_error "Unable to create a private configuration transport."
    return 1
  }
  if ! {
    for key in "${config_keys[@]}"; do
      if [[ -v "$key" ]]; then
        printf '%s' "${!key}" | base64 | tr -d '\n' | {
          IFS= read -r encoded || true
          printf '%s\t%s\0' "$key" "$encoded"
        }
      fi
    done
    while IFS= read -r variable_name; do
      if [[ "$variable_name" =~ ^ALERT_SCRIPT_([1-9]|[1-9][0-9])(_EVENTS)?$ ]]; then
        printf '%s' "${!variable_name}" | base64 | tr -d '\n' | {
          IFS= read -r encoded || true
          printf '%s\t%s\0' "$variable_name" "$encoded"
        }
      fi
    done < <(compgen -A variable ALERT_SCRIPT_ || true)
  } | python3 "$CONFIG_PY" --profile monitor --validate-nul --script-dir "$SCRIPT_DIR" >"$transport_file"; then
    rm -f -- "$transport_file"
    return 1
  fi
  ALERT_SCRIPT_RULE_INDICES=()
  ALERT_SCRIPT_RULE_PATHS=()
  ALERT_SCRIPT_RULE_EVENTS=()
  ALERT_SCRIPT_RULE_IDS=()
  while IFS= read -r -d '' record; do
    key="${record%%$'\t'*}"
    encoded="${record#*$'\t'}"
    value="$(printf '%s' "$encoded" | base64 --decode)" || {
      transport_error=1
      break
    }
    case "$key" in
      ALERT_SCRIPT_RULE_INDEX_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_INDICES[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_PATH_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_PATHS[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_EVENT_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_EVENTS[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_ID_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_IDS[rule_index]="$value"
        ;;
    esac
  done <"$transport_file"
  rm -f -- "$transport_file"
  if (( transport_error )); then
    config_error "Invalid configuration transport."
    return 1
  fi
}

check_requirements() {
  local missing=0
  local codex_command="${CODEX_BIN:-codex}"

  if ! command -v "$codex_command" &>/dev/null; then
    echo "[ERROR] 'codex' command not found. Is OpenAI Codex CLI installed and in PATH?"
    echo "        Try: which codex   or   codex /status"
    missing=1
  fi

  if ! command -v curl &>/dev/null; then
    echo "[ERROR] 'curl' is required but not found."
    missing=1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "[ERROR] 'python3' is required but not found."
    missing=1
  elif ! python3 - <<'PYEOF'
import sys
if sys.version_info < (3, 9):
    raise SystemExit(1)
try:
    from zoneinfo import ZoneInfo
    ZoneInfo("Europe/Paris")
except Exception:
    raise SystemExit(2)
PYEOF
  then
    echo "[ERROR] Python >= 3.9 with Europe/Paris tzdata is required." >&2
    missing=1
  fi

  if ! command -v flock &>/dev/null; then
    echo "[ERROR] 'flock' is required but not found."
    missing=1
  fi

  if [[ "${ALERTS_ENABLED:-1}" == 1 ]] && alert_scripts_configured \
    && ! command -v timeout &>/dev/null; then
    echo "[ERROR] 'timeout' is required when alert scripts are configured." >&2
    missing=1
  fi

  (( missing == 0 ))
}

initialize() {
  local interval_override="${1:-}" transport_file record key encoded value rule_index transport_error=0
  umask 077
  transport_file="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-config.XXXXXX")" || {
    config_error "Unable to create a private configuration transport."
    return 1
  }
  local -a config_args=(--profile monitor --env-file "$ENV_FILE" --script-dir "$SCRIPT_DIR")
  if [[ -n "$interval_override" ]]; then
    config_args+=(--loop "$interval_override")
  fi
  if ! python3 "$CONFIG_PY" "${config_args[@]}" >"$transport_file"; then
    rm -f -- "$transport_file"
    return 1
  fi
  ALERT_SCRIPT_RULE_INDICES=()
  ALERT_SCRIPT_RULE_PATHS=()
  ALERT_SCRIPT_RULE_EVENTS=()
  ALERT_SCRIPT_RULE_IDS=()
  while IFS= read -r -d '' record; do
    key="${record%%$'\t'*}"
    encoded="${record#*$'\t'}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$|^ALERT_SCRIPT_RULE_(INDEX|PATH|EVENT|ID)_[0-9]+$ ]] || continue
    value="$(printf '%s' "$encoded" | base64 --decode)" || {
      transport_error=1
      break
    }
    case "$key" in
      ALERT_SCRIPT_RULE_INDEX_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_INDICES[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_PATH_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_PATHS[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_EVENT_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_EVENTS[rule_index]="$value"
        ;;
      ALERT_SCRIPT_RULE_ID_*)
        rule_index="${key##*_}"
        ALERT_SCRIPT_RULE_IDS[rule_index]="$value"
        ;;
      *) printf -v "$key" '%s' "$value" ;;
    esac
  done <"$transport_file"
  rm -f -- "$transport_file"
  if (( transport_error )); then
    config_error "Invalid configuration transport."
    return 1
  fi

  check_requirements || return 1
  if [[ "$RUNTIME_DIR" != /* ]]; then
    config_error "Runtime directory must be an absolute path: $RUNTIME_DIR"
    return 1
  fi
  if [[ -L "$RUNTIME_DIR" ]]; then
    config_error "Runtime directory must not be a symbolic link: $RUNTIME_DIR"
    return 1
  fi
  mkdir -p -- "$RUNTIME_DIR" || {
    config_error "Unable to create runtime directory: $RUNTIME_DIR"
    return 1
  }
  if [[ -L "$RUNTIME_DIR" || ! -d "$RUNTIME_DIR" || ! -O "$RUNTIME_DIR" ]]; then
    config_error "Runtime directory must be a directory owned by the current user: $RUNTIME_DIR"
    return 1
  fi
  chmod 700 -- "$RUNTIME_DIR" || {
    config_error "Unable to secure runtime directory: $RUNTIME_DIR"
    return 1
  }
  [[ -w "$RUNTIME_DIR" ]] || { config_error "Runtime directory is not writable: $RUNTIME_DIR"; return 1; }
}

fetch_status_json() {
  local interval_seconds="$1"
  local codex_cmd="${CODEX_BIN:-codex}"
  local debug_args=()
  [[ "${MONITOR_DEBUG:-0}" == 1 ]] && debug_args+=(--debug)

  python3 "$CODEX_CLIENT_PY" \
    --codex-bin "$codex_cmd" \
    --timeout "${CODEX_STATUS_TIMEOUT_SECONDS:-20}" \
    --interval "$interval_seconds" \
    --history-window-hours "$HISTORY_RETENTION_HOURS" \
    "${debug_args[@]}"
}

json_get_field() {
  local json="$1"
  local field="$2"

  python3 - "$json" "$field" <<'PYEOF'
import json
import sys

data = json.loads(sys.argv[1])
value = data.get(sys.argv[2], "")
if value is None:
    value = ""
if isinstance(value, float) and value.is_integer():
    value = int(value)
print(value)
PYEOF
}

fetch_codex_forecast() {
  local bucket response_file response_bytes status curl_status=0
  bucket=$(( $(date -u +%s) / 300 ))
  response_file="$(mktemp "${RUNTIME_DIR}/.forecast-response.XXXXXX")"
  status="$(curl --silent --show-error --connect-timeout 3 --max-time 8 --max-filesize 65536 \
    --output "$response_file" --write-out '%{http_code}' \
    "https://codex.lunarwerx.com/cnx/aireset/summary/t/${bucket}" 2>/dev/null)" || curl_status=$?
  if (( curl_status != 0 )) || [[ "$status" != 200 ]]; then
    rm -f "$response_file"
    echo "[WARN] Codex Forecast is unavailable; continuing without global reset probabilities." >&2
    return 1
  fi
  response_bytes="$(wc -c < "$response_file")"
  if [[ ! "$response_bytes" =~ ^[0-9]+$ ]] || (( response_bytes > 65536 )); then
    rm -f "$response_file"
    echo "[WARN] Codex Forecast returned an oversized response; continuing without global reset probabilities." >&2
    return 1
  fi

  if ! python3 - "$response_file" <<'PYEOF'
import datetime
import json
import math
import pathlib
import sys

try:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

if not isinstance(payload, dict):
    raise SystemExit(1)


def probability(name):
    value = payload.get(name)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not 0 <= value <= 1:
        raise SystemExit(1)
    return math.floor(value * 100 + 0.5)


generated_at = payload.get("generatedAt")
if not isinstance(generated_at, str) or not generated_at or len(generated_at) > 100:
    raise SystemExit(1)
try:
    generated = datetime.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except (OverflowError, ValueError):
    raise SystemExit(1)
if generated.tzinfo is None:
    raise SystemExit(1)
generated = generated.astimezone(datetime.timezone.utc)
if generated > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5):
    raise SystemExit(1)

forecast = {
    "chance_24h_pct": probability("chanceToday"),
    "chance_6h_pct": probability("chanceSoon"),
    "generated_at": generated.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
print(json.dumps(forecast, separators=(",", ":")))
PYEOF
  then
    rm -f "$response_file"
    echo "[WARN] Codex Forecast returned invalid data; continuing without global reset probabilities." >&2
    return 1
  fi
  rm -f "$response_file"
}

enrich_snapshot_with_codex_forecast() {
  local json="$1" forecast
  forecast="$(fetch_codex_forecast)" || return 1
  python3 - "$json" "$forecast" \
    "${CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD:-50}" \
    "${CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD:-25}" <<'PYEOF'
import json
import sys

snapshot = json.loads(sys.argv[1])
forecast = json.loads(sys.argv[2])
if not isinstance(snapshot, dict) or not isinstance(forecast, dict):
    raise SystemExit(1)
forecast["highlight_threshold_24h_pct"] = int(sys.argv[3])
forecast["highlight_threshold_6h_pct"] = int(sys.argv[4])
snapshot["codex_forecast"] = forecast
print(json.dumps(snapshot, indent=2))
PYEOF
}

timestamp_to_epoch() {
  local timestamp="$1"

  python3 - "$timestamp" <<'PYEOF'
import datetime
import sys

try:
    value = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    print(int(value.timestamp()))
except (ValueError, OverflowError):
    raise SystemExit(1)
PYEOF
}

format_paris_now() {
  TZ=Europe/Paris date '+%d/%m/%Y %H:%M'
}

format_paris_timestamp() {
  local epoch="$1"
  TZ=Europe/Paris date -d "@${epoch}" '+%d/%m/%Y %H:%M'
}

write_local_snapshot() {
  local json="$1"

  if ! printf '%s\n' "$json" | python3 "$HISTORY_PY" \
    --history "$HISTORY_FILE" \
    --data "$DATA_FILE" \
    --retention-hours "$HISTORY_RETENTION_HOURS"; then
    return 1
  fi

  echo "[OK] Snapshot storage processed at ${DATA_FILE}"
}

write_current_snapshot() {
  local json="$1"

  if ! printf '%s\n' "$json" | python3 "$HISTORY_PY" \
      --data "$DATA_FILE" \
      --data-only; then
    return 1
  fi

  echo "[OK] Current snapshot updated at ${DATA_FILE}"
}

snapshot_with_interval() {
  local json="$1" interval_seconds="$2"
  python3 - "$json" "$interval_seconds" <<'PYEOF'
import json
import sys

snapshot = json.loads(sys.argv[1])
snapshot["sample_interval_seconds"] = int(sys.argv[2])
print(json.dumps(snapshot, indent=2))
PYEOF
}

load_thresholds() {
  python3 - "$ALERT_THRESHOLDS" <<'PYEOF'
import sys

values = []
for part in sys.argv[1].split(","):
    part = part.strip()
    if not part:
        continue
    try:
        value = int(part)
    except ValueError:
        continue
    if 0 <= value <= 100:
        values.append(value)

for value in sorted(set(values), reverse=True):
    print(value)
PYEOF
}

# ============================================================================
# Optional: sync to GitHub Gist (Tier 2, external dashboard)
# ============================================================================
http_request() {
  local service="$1" expected_status="$2" curl_config="$3" method="$4" output_file="$5"
  shift 5
  local attempt=1 max_attempts=$((CURL_RETRIES + 1)) status="000" curl_status=0 delay error_file
  error_file="$(mktemp "${RUNTIME_DIR}/.curl-error.XXXXXX")"

  while (( attempt <= max_attempts )); do
    echo "[INFO] ${service}: delivery attempt ${attempt}/${max_attempts}."
    : > "$output_file"
    : > "$error_file"
    curl_status=0
    status="$(printf '%s\n' "$curl_config" | curl --config - --silent --show-error \
      --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" \
      --request "$method" --output "$output_file" --write-out '%{http_code}' "$@" 2>"$error_file")" || curl_status=$?
    if (( curl_status == 0 )) && [[ "$status" == "$expected_status" ]]; then
      if [[ "$service" != Telegram ]] || python3 - "$output_file" <<'PYEOF'
import json
import pathlib
import sys
try:
    response = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(response, dict) and response.get("ok") is True else 1)
PYEOF
      then
        echo "[OK] ${service}: delivered (HTTP ${status})."
        rm -f "$error_file"
        return 0
      fi
    fi
    if [[ "${MONITOR_DEBUG:-0}" == 1 && -s "$error_file" ]]; then
      python3 - "$service" "$error_file" <<'PYEOF'
import pathlib
import sys

text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")[:2048]
text = "".join(char if char in "\n\t" or ord(char) >= 32 else "?" for char in text).strip()
if text:
    sys.stderr.write(f"[DEBUG] {sys.argv[1]} curl: {text}\n")
PYEOF
    fi
    echo "[WARN] ${service}: attempt failed (curl=${curl_status}, HTTP ${status})." >&2
    if (( attempt < max_attempts )); then
      delay=$((CURL_RETRY_DELAY_SECONDS * (2 ** (attempt - 1))))
      (( delay > 0 )) && sleep "$delay"
    fi
    ((attempt += 1))
  done
  rm -f "$error_file"
  return 1
}

sync_gist() {
  local json="$1"
  local history_json="$2"

  if [[ -z "${GITHUB_PAT:-}" || -z "${GITHUB_GIST_ID:-}" ]]; then
    return 0  # silently skip if not configured
  fi

  local payload response_file
  payload="$(python3 - "$json" "$history_json" <<'PYEOF'
import json
import sys
print(json.dumps({"files": {"data.json": {"content": sys.argv[1]}, "history.json": {"content": sys.argv[2]}}}))
PYEOF
)"
  response_file="$(mktemp "${RUNTIME_DIR}/.gist-response.XXXXXX")"
  if http_request "GitHub Gist" 200 \
    "url = \"${GITHUB_API_URL}/gists/${GITHUB_GIST_ID}\""$'\n'"header = \"Authorization: token ${GITHUB_PAT}\"" \
    PATCH "$response_file" -H "Content-Type: application/json" --data "$payload"; then
    rm -f "$response_file"
    return 0
  fi
  rm -f "$response_file"
  return 1
}

# ============================================================================
# Alerting — direct curl to Discord/Telegram, no server needed
# ============================================================================
send_discord() {
  local message="$1"
  local payload
  [[ "${ALERTS_ENABLED:-1}" == 1 ]] || return 0
  if [[ -z "${DISCORD_WEBHOOK:-}" ]]; then return; fi

  payload="$(python3 - "$message" <<'PYEOF'
import json
import sys

print(json.dumps({"content": sys.argv[1]}))
PYEOF
)"

  local response_file
  response_file="$(mktemp "${RUNTIME_DIR}/.discord-response.XXXXXX")"
  if http_request Discord 204 "url = \"${DISCORD_WEBHOOK}\"" POST "$response_file" \
    -H "Content-Type: application/json" --data "$payload"; then
    rm -f "$response_file"
    return 0
  fi
  rm -f "$response_file"
  return 1
}

send_telegram() {
  local message="$1"
  [[ "${ALERTS_ENABLED:-1}" == 1 ]] || return 0
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return; fi

  local response_file
  response_file="$(mktemp "${RUNTIME_DIR}/.telegram-response.XXXXXX")"
  if http_request Telegram 200 "url = \"${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" \
    POST "$response_file" --data "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}"; then
    rm -f "$response_file"
    return 0
  fi
  echo "[WARN] Telegram: HTTP response did not confirm delivery." >&2
  rm -f "$response_file"
  return 1
}

send_alert() {
  local message="$1"
  local configured=0 delivered=0
  if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
    echo "[INFO] Alert suppressed while ALERTS_ENABLED=0."
    return 0
  fi
  echo "[ALERT] Detected: $message"
  if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    ((configured += 1))
    if send_discord "$message"; then
      ((delivered += 1))
    fi
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    ((configured += 1))
    if send_telegram "$message"; then
      ((delivered += 1))
    fi
  fi
  if (( configured == 0 )); then
    echo "[INFO] No alert channel configured; alert acknowledged locally."
    return 0
  fi
  (( delivered > 0 ))
}

# Perform exactly one notification request. The durable retry orchestrator below
# records the result before deciding whether another attempt is allowed.
alert_http_attempt() {
  local channel="$1" message="$2" response_file headers_file error_file payload status="000" curl_status=0
  [[ "${ALERTS_ENABLED:-1}" == 1 ]] || return 1
  response_file="$(mktemp "${RUNTIME_DIR}/.${channel}-response.XXXXXX")" || return 1
  headers_file="$(mktemp "${RUNTIME_DIR}/.${channel}-headers.XXXXXX")" || { rm -f "$response_file"; return 1; }
  error_file="$(mktemp "${RUNTIME_DIR}/.${channel}-error.XXXXXX")" || { rm -f "$response_file" "$headers_file"; return 1; }
  chmod 600 "$response_file" "$headers_file" "$error_file"
  HTTP_LAST_RESPONSE_FILE="$response_file"
  HTTP_LAST_HEADERS_FILE="$headers_file"
  HTTP_LAST_ERROR_FILE="$error_file"

  if [[ "$channel" == discord ]]; then
    payload="$(python3 - "$message" <<'PYEOF'
import json
import sys
print(json.dumps({"content": sys.argv[1]}))
PYEOF
)"
    status="$(printf '%s\n' "url = \"${DISCORD_WEBHOOK}\"" | curl --config - --silent --show-error \
      --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" \
      --request POST --output "$response_file" --dump-header "$headers_file" --write-out '%{http_code}' \
      -H "Content-Type: application/json" --data "$payload" 2>"$error_file")" || curl_status=$?
  else
    status="$(printf '%s\n' "url = \"${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" | curl --config - --silent --show-error \
      --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" \
      --request POST --output "$response_file" --dump-header "$headers_file" --write-out '%{http_code}' \
      --data "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" 2>"$error_file")" || curl_status=$?
  fi
  [[ "$status" =~ ^[0-9]{3}$ ]] || status=0
  HTTP_LAST_CURL_CODE="$curl_status"
  HTTP_LAST_STATUS="$((10#$status))"
  return 0
}

cleanup_alert_http_attempt() {
  rm -f "${HTTP_LAST_RESPONSE_FILE:-}" "${HTTP_LAST_HEADERS_FILE:-}" "${HTTP_LAST_ERROR_FILE:-}"
  HTTP_LAST_RESPONSE_FILE=""
  HTTP_LAST_HEADERS_FILE=""
  HTTP_LAST_ERROR_FILE=""
}

configured_alert_channels_json() {
  if [[ -n "${DISCORD_WEBHOOK:-}" && -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf '["discord","telegram"]\n'
  elif [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    printf '["discord"]\n'
  elif [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf '["telegram"]\n'
  else
    printf '[]\n'
  fi
}

network_reset_request_json() {
  local window="$1" limit_id="$2" reset_epoch="$3" created_at="$4"
  local channels message
  channels="$(configured_alert_channels_json)" || return 1
  if [[ "$window" == 5h ]]; then
    message="*Codex 5h limit reset.* A new usage cycle is available."
  else
    message="*Codex weekly limit reset.* A new usage cycle is available."
  fi
  ALERT_REGISTER_MESSAGE="$message" python3 - "$window" "$limit_id" \
    "$reset_epoch" "$created_at" "$channels" <<'PYEOF'
import json
import os
import sys

window, limit_id, reset_epoch, created_at, channels = sys.argv[1:]
reset_epoch = int(reset_epoch)
created_at = int(created_at)
print(json.dumps({
    "kind": "reset", "window": window, "selector": "reset",
    "cycle_key": f"limit:{limit_id}|reset:{reset_epoch}",
    "message": os.environ["ALERT_REGISTER_MESSAGE"],
    "event_data": {"limit_id": limit_id, "reset_epoch": reset_epoch},
    "created_at": created_at,
    "expires_at": reset_epoch + (5 * 60 * 60 if window == "5h" else 7 * 24 * 60 * 60),
    "channels": json.loads(channels),
    "replace_pending_thresholds": False,
    "expire_threshold_cycle": None,
}))
PYEOF
}

register_network_alert() {
  local kind="$1" window="$2" selector="$3" cycle_key="$4" message="$5"
  local event_data="$6" created_at="$7" expires_at="$8" replace="${9:-false}" expire_cycle="${10:-}"
  local channels request
  if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
    echo "[INFO] Alert suppressed while ALERTS_ENABLED=0: $message"
    return 2
  fi
  channels="$(configured_alert_channels_json)" || return 1
  if [[ "$channels" == "[]" ]]; then
    # send_alert is retained as a no-channel compatibility seam for embedders
    # and tests; its production implementation performs no network request here.
    if send_alert "$message"; then return 2; else return 1; fi
  fi
  request="$(ALERT_REGISTER_MESSAGE="$message" python3 - "$kind" "$window" "$selector" "$cycle_key" \
    "$event_data" "$created_at" "$expires_at" "$channels" "$replace" "$expire_cycle" <<'PYEOF'
import json
import os
import sys
kind, window, selector, cycle_key, event_data, created, expires, channels, replace, expire = sys.argv[1:]
print(json.dumps({
    "kind": kind, "window": window, "selector": selector, "cycle_key": cycle_key,
    "message": os.environ["ALERT_REGISTER_MESSAGE"], "event_data": json.loads(event_data),
    "created_at": int(created), "expires_at": int(expires), "channels": json.loads(channels),
    "replace_pending_thresholds": replace == "true",
    "expire_threshold_cycle": expire or None,
}))
PYEOF
)" || return 1
  if ! printf '%s\n' "$request" | python3 "$ALERTS_PY" register "$ALERT_DELIVERIES_FILE" >/dev/null; then
    echo "[ERROR] Could not journal network alert; no request was started." >&2
    return 1
  fi
  echo "[ALERT] Detected: $message"
}

# Register anomaly rows that were durably written by the detector.  The
# SQLite journal is acknowledged only after alerts.py has accepted the
# occurrence (or after the existing no-channel compatibility seam succeeds).
journal_quota_anomalies() {
  local now="$1" pending_file anomaly_id anomaly_type window limit_id detected
  local before_pct after_pct before_reset after_reset message event_data registration_status
  pending_file="$(mktemp "${RUNTIME_DIR}/.anomalies-pending.XXXXXX")" || return 1
  if ! python3 "$ANOMALIES_PY" pending --database "$ARCHIVE_FILE" > "$pending_file"; then
    rm -f "$pending_file"
    return 1
  fi
  while IFS=$'\x1f' read -r anomaly_id anomaly_type window limit_id detected before_pct after_pct before_reset after_reset message; do
    [[ -n "$anomaly_id" ]] || continue
    message="$(printf '%s' "$message" | base64 --decode)" || { rm -f "$pending_file"; return 1; }
    event_data="$(python3 - "$limit_id" "$after_reset" "$before_pct" "$after_pct" \
      "$before_reset" "$detected" <<'PYEOF'
import json
import sys
limit_id, reset_epoch, before, after, before_reset, detected = sys.argv[1:]
print(json.dumps({
    "limit_id": limit_id,
    "reset_epoch": int(reset_epoch or 0),
    "before_pct": float(before), "after_pct": float(after),
    "before_reset_at": int(before_reset or 0),
    "after_reset_at": int(reset_epoch or 0),
    "detected_at_epoch": int(detected),
}, separators=(",", ":")))
PYEOF
    )" || { rm -f "$pending_file"; return 1; }
    registration_status=0
    register_network_alert anomaly "$window" "$anomaly_type" \
      "limit:${limit_id}|anomaly:${anomaly_id}" "$message" "$event_data" \
      "$detected" 0 false "" || registration_status=$?
    if (( registration_status == 0 || registration_status == 2 )); then
      if ! python3 "$ANOMALIES_PY" journal --database "$ARCHIVE_FILE" \
        "$anomaly_id" --at "$now"; then
        rm -f "$pending_file"
        return 1
      fi
    else
      rm -f "$pending_file"
      return 1
    fi
  done < <(python3 - "$pending_file" <<'PYEOF'
import base64
import json
import pathlib
import sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)
    print(*(
        item["anomaly_id"], item["anomaly_type"], item["window"], item["limit_id"],
        item["detected_at_epoch"], item["before_pct"], item["after_pct"],
        item["before_reset_at"] or 0, item["after_reset_at"] or 0,
        base64.b64encode(item["message"].encode()).decode(),
    ), sep="\x1f")
PYEOF
  )
  rm -f "$pending_file"
}

deliver_due_alerts() {
  local now="$1" configured due_file alert_id channel message attempt cycle_limit
  local classification outcome error_class retryable retry_delay next_attempt used_retry_after record_payload
  [[ "${ALERTS_ENABLED:-1}" == 1 ]] || return 0
  due_file="$(mktemp "${RUNTIME_DIR}/.alerts-due.XXXXXX")" || return 1
  configured="$(configured_alert_channels_json)" || { rm -f "$due_file"; return 1; }
  if ! printf '{"configured_channels":%s}\n' "$configured" \
      | python3 "$ALERTS_PY" due "$ALERT_DELIVERIES_FILE" --now "$now" > "$due_file"; then
    rm -f "$due_file"
    return 1
  fi
  cycle_limit=$((CURL_RETRIES + 1))
  while IFS=$'\t' read -r alert_id channel message; do
    [[ -n "$alert_id" ]] || continue
    message="$(printf '%s' "$message" | base64 --decode)" || { NETWORK_DELIVERY_ERROR=1; continue; }
    attempt=1
    while (( attempt <= cycle_limit )); do
      echo "[INFO] ${channel}: alert ${alert_id} attempt ${attempt}/${cycle_limit}."
      if ! alert_http_attempt "$channel" "$message"; then
        NETWORK_DELIVERY_ERROR=1
        cleanup_alert_http_attempt
        break
      fi
      classification="$(python3 "$ALERTS_PY" classify "$HTTP_LAST_CURL_CODE" "$HTTP_LAST_STATUS" \
        "$attempt" "$CURL_RETRY_DELAY_SECONDS" "$HTTP_LAST_HEADERS_FILE" --now "$now")" \
        || { NETWORK_DELIVERY_ERROR=1; cleanup_alert_http_attempt; break; }
      IFS=$'\t' read -r outcome error_class retryable retry_delay next_attempt used_retry_after < <(
        printf '%s' "$classification" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["outcome"], d["error_class"] or "-", int(d["retryable"]), d["retry_delay"], d["next_attempt_at"], int(d["used_retry_after"]), sep="\t")'
      )
      [[ "$error_class" == - ]] && error_class=""
      if (( HTTP_LAST_CURL_CODE == 0 )) && [[ "$outcome" == delivered ]]; then
        if [[ "$channel" == discord && "$HTTP_LAST_STATUS" != 204 ]]; then
          outcome=failed error_class=invalid_response retryable=0 retry_delay=0 next_attempt=0
        elif [[ "$channel" == telegram ]]; then
          if [[ "$HTTP_LAST_STATUS" != 200 ]] \
            || ! python3 "$ALERTS_PY" telegram-delivered "$HTTP_LAST_RESPONSE_FILE"; then
            outcome=failed error_class=invalid_response retryable=0 retry_delay=0 next_attempt=0
          fi
        fi
      fi
      if [[ "$outcome" == pending && "$attempt" == "$cycle_limit" && "$used_retry_after" == 0 ]]; then
        next_attempt=0
      fi
      record_payload="$(python3 - "$alert_id" "$channel" "$outcome" "$error_class" "$now" \
        "$next_attempt" "$HTTP_LAST_STATUS" "$HTTP_LAST_CURL_CODE" <<'PYEOF'
import json
import sys
alert_id, channel, status, error, attempted, next_attempt, http, curl = sys.argv[1:]
print(json.dumps({"alert_id": alert_id, "channel": channel, "status": status,
                  "error_class": error or None, "attempted_at": int(attempted),
                  "next_attempt_at": int(next_attempt), "http_status": int(http),
                  "curl_code": int(curl)}))
PYEOF
)"
      if ! printf '%s\n' "$record_payload" | python3 "$ALERTS_PY" record "$ALERT_DELIVERIES_FILE" >/dev/null; then
        NETWORK_DELIVERY_ERROR=1
        cleanup_alert_http_attempt
        break
      fi
      if [[ "$outcome" == delivered ]]; then
        echo "[OK] ${channel}: alert ${alert_id} delivered (HTTP ${HTTP_LAST_STATUS})."
        cleanup_alert_http_attempt
        break
      fi
      echo "[WARN] ${channel}: alert ${alert_id} failed (curl=${HTTP_LAST_CURL_CODE}, HTTP ${HTTP_LAST_STATUS}, class=${error_class})." >&2
      NETWORK_DELIVERY_ERROR=1
      cleanup_alert_http_attempt
      if [[ "$outcome" != pending || "$retryable" != 1 || "$retry_delay" -gt 60 || "$attempt" == "$cycle_limit" ]]; then
        break
      fi
      (( retry_delay > 0 )) && sleep "$retry_delay"
      ((attempt += 1))
    done
  done < <(python3 - "$due_file" <<'PYEOF'
import base64
import json
import pathlib
import sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)
    message = base64.b64encode(item["message"].encode()).decode()
    print(item["alert_id"], item["channel"], message, sep="\t")
PYEOF
)
  if python3 "$ALERTS_PY" terminal-unacknowledged "$ALERT_DELIVERIES_FILE" \
    | python3 -c 'import json,sys; raise SystemExit(0 if any(json.loads(line).get("terminal_reason") == "channel_unconfigured" for line in sys.stdin if line.strip()) else 1)'; then
    NETWORK_DELIVERY_ERROR=1
  fi
  rm -f "$due_file"
  return 0
}

journal_has_pending_alert() {
  local kind="$1" window="$2" selector="$3" cycle_key="$4"
  python3 - "$ALERT_DELIVERIES_FILE" "$kind" "$window" "$selector" "$cycle_key" <<'PYEOF'
import json
import pathlib
import sys
path, kind, window, selector, cycle = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))

def same_cycle(value):
    return value == cycle or (value.startswith("legacy-v") and "|" in value and value.split("|", 1)[1] == cycle)
raise SystemExit(0 if any(item["kind"] == kind and item["window"] == window
                          and item["selector"] == selector and same_cycle(item["cycle_key"])
                          and item["status"] == "pending" for item in document["alerts"]) else 1)
PYEOF
}

journal_has_terminal_alert() {
  local kind="$1" window="$2" selector="$3" cycle_key="$4"
  python3 - "$ALERT_DELIVERIES_FILE" "$kind" "$window" "$selector" "$cycle_key" <<'PYEOF'
import json
import pathlib
import sys
path, kind, window, selector, cycle = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))

def same_cycle(value):
    return value == cycle or (value.startswith("legacy-v") and "|" in value and value.split("|", 1)[1] == cycle)
raise SystemExit(0 if any(item["kind"] == kind and item["window"] == window
                          and item["selector"] == selector and same_cycle(item["cycle_key"])
                          and item["status"] != "pending" for item in document["alerts"]) else 1)
PYEOF
}

journal_has_local_observed_reset() {
  local window="$1" cycle_key="$2" limit_id="$3"
  python3 - "$ALERT_DELIVERIES_FILE" "$window" "$cycle_key" "$limit_id" <<'PYEOF'
import json
import pathlib
import sys
path, window, cycle, limit_id = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))

def same_cycle(value):
    return value == cycle or (value.startswith("legacy-v") and "|" in value
                              and value.split("|", 1)[1] == cycle)

raise SystemExit(0 if any(item["kind"] == "reset" and item["window"] == window
                          and item["selector"] == "reset"
                          and item["event_data"].get("limit_id") == limit_id
                          and same_cycle(item["cycle_key"])
                          and item["status"] != "pending"
                          and item["terminal_reason"] == "local_observed"
                          for item in document["alerts"]) else 1)
PYEOF
}

journal_has_network_reset_occurrence() {
  local window="$1" cycle_key="$2" limit_id="$3" reset_epoch="$4"
  [[ -f "$ALERT_DELIVERIES_FILE" ]] || return 1
  python3 - "$ALERT_DELIVERIES_FILE" "$window" "$cycle_key" "$limit_id" "$reset_epoch" <<'PYEOF'
import json
import pathlib
import sys

path, window, cycle, limit_id, reset_epoch = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
reset_epoch = int(reset_epoch)

def same_cycle(value):
    return value == cycle or (value.startswith("legacy-v") and "|" in value
                              and value.split("|", 1)[1] == cycle)

raise SystemExit(0 if any(
    item["kind"] == "reset"
    and item["window"] == window
    and item["selector"] == "reset"
    and item["event_data"].get("limit_id") == limit_id
    and item["event_data"].get("reset_epoch") == reset_epoch
    and same_cycle(item["cycle_key"])
    and item["terminal_reason"] != "local_observed"
    for item in document["alerts"]
) else 1)
PYEOF
}

journal_has_owner_interrupted_reset() {
  local window="$1" cycle_key="$2" limit_id="$3"
  python3 - "$ALERT_DELIVERIES_FILE" "$window" "$cycle_key" "$limit_id" <<'PYEOF'
import json
import pathlib
import sys
path, window, cycle, limit_id = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))

def same_cycle(value):
    return value == cycle or (value.startswith("legacy-v") and "|" in value
                              and value.split("|", 1)[1] == cycle)

raise SystemExit(0 if any(item["kind"] == "reset" and item["window"] == window
                          and item["selector"] == "reset"
                          and item["event_data"].get("limit_id") == limit_id
                          and same_cycle(item["cycle_key"])
                          and item["status"] != "pending"
                          and item["terminal_reason"] == "owner_interrupted"
                          for item in document["alerts"]) else 1)
PYEOF
}

journal_has_pending_selector() {
  local kind="$1" window="$2" selector="$3"
  python3 - "$ALERT_DELIVERIES_FILE" "$kind" "$window" "$selector" <<'PYEOF'
import json
import pathlib
import sys
path, kind, window, selector = sys.argv[1:]
document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
raise SystemExit(0 if any(item["kind"] == kind and item["window"] == window
                          and item["selector"] == selector and item["status"] == "pending"
                          for item in document["alerts"]) else 1)
PYEOF
}

invalidate_pending_thresholds() {
  local window="$1" cycle_key="$2" limit_id="$3" now="$4"
  python3 "$ALERTS_PY" expire-thresholds "$ALERT_DELIVERIES_FILE" \
    "$window" "$cycle_key" "$limit_id" --now "$now"
}

invalidate_pending_thresholds_for_owner() {
  local window="$1" limit_id="$2" now="$3"
  python3 "$ALERTS_PY" expire-owner-thresholds "$ALERT_DELIVERIES_FILE" \
    "$window" "$limit_id" --now "$now"
}

expire_owner_thresholds_and_suppress_reset() {
  local window="$1" limit_id="$2" reset_epoch="$3" now="$4"
  python3 "$ALERTS_PY" expire-owner-thresholds-and-reset "$ALERT_DELIVERIES_FILE" \
    "$window" "$limit_id" "$reset_epoch" --now "$now"
}

expire_observed_owner_cycle() {
  local window="$1" limit_id="$2" now="$3" superseded_epoch="${4:-0}"
  local preserve_cycle="${5:-}" request_json="${6:-}"
  [[ -n "$request_json" ]] || request_json='{}'
  if [[ -n "$preserve_cycle" ]]; then
    printf '%s\n' "$request_json" \
      | python3 "$ALERTS_PY" expire-observed-owner "$ALERT_DELIVERIES_FILE" \
        "$window" "$limit_id" --superseded-reset-epoch "$superseded_epoch" \
        --preserve-cycle "$preserve_cycle" --now "$now"
  else
    printf '%s\n' "$request_json" \
      | python3 "$ALERTS_PY" expire-observed-owner "$ALERT_DELIVERIES_FILE" \
        "$window" "$limit_id" --superseded-reset-epoch "$superseded_epoch" \
        --now "$now"
  fi
}

interrupt_pending_owner() {
  local limit_id="$1" now="$2"
  python3 "$ALERTS_PY" interrupt-owner "$ALERT_DELIVERIES_FILE" \
    "$limit_id" --now "$now"
}

interrupt_pending_other_owners() {
  local current_limit_id="$1" now="$2"
  python3 "$ALERTS_PY" interrupt-other-owners "$ALERT_DELIVERIES_FILE" \
    "$current_limit_id" --now "$now"
}

suppress_local_reset_cycle() {
  local window="$1" limit_id="$2" reset_epoch="$3" now="$4"
  python3 "$ALERTS_PY" suppress-local-reset "$ALERT_DELIVERIES_FILE" \
    "$window" "$limit_id" "$reset_epoch" --now "$now"
}

interrupt_reset_cycle() {
  local window="$1" limit_id="$2" reset_epoch="$3" now="$4"
  python3 "$ALERTS_PY" interrupt-reset-cycle "$ALERT_DELIVERIES_FILE" \
    "$window" "$limit_id" "$reset_epoch" --now "$now"
}

weekly_pace_vs_ideal() {
  local weekly_pct="$1"
  local weekly_reset_at="$2"
  local scraped_at_epoch="$3"

  python3 - "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch" <<'PYEOF'
import sys

try:
    actual = float(sys.argv[1])
    reset_at = int(sys.argv[2])
    sampled_at = int(sys.argv[3])
except (TypeError, ValueError):
    raise SystemExit(0)

weekly_window = 7 * 24 * 60 * 60
remaining = reset_at - sampled_at
if not 0 <= actual <= 100 or not 0 <= remaining <= weekly_window:
    raise SystemExit(0)

ideal = round(100 * remaining / weekly_window, 1)
difference = round(actual - ideal, 1)
direction = "on pace" if difference == 0 else "above" if difference > 0 else "below"
sign = "+" if difference > 0 else ""

if ideal > 0:
    relative = round(abs(actual - ideal) / ideal * 100, 1)
    print(f"{sign}{difference:.1f} pts · {relative:.1f}% {direction}")
else:
    print(f"{sign}{difference:.1f} pts")
PYEOF
}

percentage_below_full() {
  python3 - "$1" <<'PYEOF'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if math.isfinite(value) and 0 <= value < 100 else 1)
PYEOF
}

is_random_weekly_reset() {
  local previous_pct="$1"
  local current_pct="$2"
  local previous_reset_at="$3"
  local current_reset_at="$4"

  python3 - "$previous_pct" "$current_pct" "$previous_reset_at" "$current_reset_at" \
    "$RANDOM_WEEKLY_RESET_MIN_CHANGE_PCT" \
    "$RANDOM_WEEKLY_RESET_FULL_REFILL_PCT" \
    "$RANDOM_WEEKLY_RESET_MIN_DEADLINE_ADVANCE_SECONDS" <<'PYEOF'
import math
import sys

try:
    previous_pct, current_pct = map(float, sys.argv[1:3])
    previous_reset_at, current_reset_at = map(int, sys.argv[3:5])
    minimum_change, full_refill = map(float, sys.argv[5:7])
    minimum_deadline_advance = int(sys.argv[7])
except (TypeError, ValueError):
    raise SystemExit(1)

refill_change = current_pct - previous_pct
detected = (
    math.isfinite(previous_pct)
    and math.isfinite(current_pct)
    and current_reset_at >= previous_reset_at + minimum_deadline_advance
    and refill_change > 0
    and (refill_change >= minimum_change or current_pct >= full_refill)
)
raise SystemExit(0 if detected else 1)
PYEOF
}

# A 5-hour reset can be observed even when the quota was never consumed.  In
# that case the only positive evidence is two complete observations at 100%
# with the same limit group and a strictly later reset deadline.  The first
# observation carrying the new deadline is used as the event anchor because
# the exact reset instant is not observable.
is_observed_5h_reset() {
  local previous_pct="$1"
  local current_pct="$2"
  local previous_reset_at="$3"
  local current_reset_at="$4"

  python3 - "$previous_pct" "$current_pct" "$previous_reset_at" "$current_reset_at" <<'PYEOF'
import sys

try:
    previous_pct, current_pct = map(float, sys.argv[1:3])
    previous_reset_at, current_reset_at = map(int, sys.argv[3:5])
except (TypeError, ValueError):
    raise SystemExit(1)

detected = (
    previous_pct == 100
    and current_pct == 100
    and previous_reset_at > 0
    and current_reset_at > previous_reset_at
)
raise SystemExit(0 if detected else 1)
PYEOF
}

csv_contains() {
  local list="$1" wanted="$2"
  [[ ",${list}," == *",${wanted},"* ]]
}

csv_without() {
  local list="$1" unwanted="$2" item result=""
  local -a items=()
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    [[ -n "$item" && "$item" != "$unwanted" ]] || continue
    result="${result:+${result},}${item}"
  done
  printf '%s' "$result"
}

encode_alert_script_context() {
  local event_kind="$1" window="$2" threshold="$3" remaining_pct="$4"
  local reset_at="$5" reset_label="$6" scraped_at="$7" message="$8"
  local owner_limit_id="$9" cycle_key="${10}"
  python3 - "$event_kind" "$window" "$threshold" "$remaining_pct" \
    "$reset_at" "$reset_label" "$scraped_at" "$message" \
    "$owner_limit_id" "$cycle_key" <<'PYEOF'
import base64
import json
import sys

event_kind, window, threshold, remaining_pct, reset_at, reset_label, scraped_at, message, limit_id, cycle_key = sys.argv[1:]
reset_epoch = int(reset_at) if reset_at else 0
context = {
    "event_kind": event_kind,
    "window": window,
    "threshold": threshold,
    "remaining_pct": remaining_pct,
    "reset_epoch": reset_epoch,
    "reset_label": reset_label,
    "scraped_at": int(scraped_at),
    "message": message,
    "limit_id": limit_id,
    "cycle_key": cycle_key,
}

encoded = base64.b64encode(
    json.dumps(context, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
).decode("ascii").rstrip("=")
print(encoded)
PYEOF
}

decode_alert_script_context() {
  local encoded="$1"
  python3 - "$encoded" <<'PYEOF'
import base64
import binascii
import json
import sys

encoded = sys.argv[1]
try:
    if len(encoded) % 4 == 1:
        raise ValueError("invalid base64 length")
    padded = encoded + "=" * ((-len(encoded)) % 4)
    decoded = base64.b64decode(padded, validate=True)
    context = json.loads(decoded.decode("utf-8"))
except (binascii.Error, UnicodeDecodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(context, dict):
    raise SystemExit(1)
required = {
    "event_kind", "window", "threshold", "remaining_pct", "reset_epoch",
    "reset_label", "scraped_at", "message", "limit_id", "cycle_key",
}
if set(context) != required:
    raise SystemExit(1)
if not isinstance(context["message"], str):
    raise SystemExit(1)
print(json.dumps(context, separators=(",", ":"), ensure_ascii=False))
PYEOF
}

decode_alert_script_message() {
  local encoded="$1"
  python3 - "$encoded" <<'PYEOF'
import base64
import binascii
import sys

try:
    encoded = sys.argv[1]
    if len(encoded) % 4 == 1:
        raise ValueError("invalid base64 length")
    padded = encoded + "=" * ((-len(encoded)) % 4)
    print(base64.b64decode(padded, validate=True).decode("utf-8"), end="")
except (binascii.Error, UnicodeDecodeError, ValueError):
    raise SystemExit(1)
PYEOF
}

pending_script_context_has() {
  local contexts="$1" wanted="$2" expected="${3:-}" entry encoded
  local -a entries=()
  [[ -n "$contexts" ]] || return 1
  IFS=',' read -r -a entries <<< "$contexts"
  for entry in "${entries[@]}"; do
    encoded="${entry#*:}"
    [[ "$entry" == *:* && -n "$encoded" \
      && "${entry%%:*}" == "$wanted" \
      && ( -z "$expected" || "$encoded" == "$expected" ) ]] && return 0
  done
  return 1
}

pending_script_context_entry() {
  local contexts="$1" wanted="$2" entry encoded
  local -a entries=()
  [[ -n "$contexts" ]] || return 1
  IFS=',' read -r -a entries <<< "$contexts"
  for entry in "${entries[@]}"; do
    encoded="${entry#*:}"
    if [[ "$entry" == *:* && -n "$encoded" \
      && "${entry%%:*}" == "$wanted" ]]; then
      printf '%s' "$entry"
      return 0
    fi
  done
  return 1
}

pending_script_context_set() {
  local contexts="$1" wanted="$2" encoded="$3" entry result="" replaced=0
  local -a entries=()
  if [[ -n "$contexts" ]]; then
    IFS=',' read -r -a entries <<< "$contexts"
  fi
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    if [[ "${entry%%:*}" == "$wanted" ]]; then
      entry="${wanted}:${encoded}"
      replaced=1
    fi
    result="${result:+${result},}${entry}"
  done
  (( replaced == 1 )) || result="${result:+${result},}${wanted}:${encoded}"
  printf '%s' "$result"
}

pending_script_context_remove() {
  local contexts="$1" unwanted="$2" entry result=""
  local -a entries=()
  [[ -n "$contexts" ]] || return 0
  IFS=',' read -r -a entries <<< "$contexts"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" && "${entry%%:*}" != "$unwanted" ]] || continue
    result="${result:+${result},}${entry}"
  done
  printf '%s' "$result"
}

encode_alert_script_identity() {
  local limit_id="$1" cycle_key="$2"
  python3 - "$limit_id" "$cycle_key" <<'PYEOF'
import base64
import json
import sys

payload = json.dumps(
    {"limit_id": sys.argv[1], "cycle_key": sys.argv[2]},
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")
print(base64.b64encode(payload).decode("ascii"), end="")
PYEOF
}

interrupted_script_identity_has() {
  local identities="$1" wanted="$2" limit_id="$3" cycle_key="$4"
  local encoded
  encoded="$(encode_alert_script_identity "$limit_id" "$cycle_key")" || return 1
  pending_script_context_has "$identities" "$wanted" "$encoded"
}

mark_interrupted_script_list() {
  local list="$1" owner_id="$2" reset_epoch="$3"
  local item entry encoded identity_encoded cycle_key
  local -a items=()
  [[ -n "$list" ]] || return 0
  cycle_key="limit:${owner_id}|unarmed"
  if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( reset_epoch > 0 )); then
    cycle_key="limit:${owner_id}|reset:${reset_epoch}"
  fi
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    if entry="$(pending_script_context_entry "$pending_script_contexts" "$item")"; then
      encoded="${entry#*:}"
      interrupted_script_contexts="$(pending_script_context_set \
        "$interrupted_script_contexts" "$item" "$encoded")"
      if [[ -n "$owner_id" ]]; then
        if ! identity_encoded="$(encode_alert_script_identity "$owner_id" "$cycle_key")"; then
          return 1
        fi
        interrupted_script_identities="$(pending_script_context_set \
          "$interrupted_script_identities" "$item" "$identity_encoded")"
      fi
    elif [[ -n "$owner_id" ]]; then
      if ! identity_encoded="$(encode_alert_script_identity "$owner_id" "$cycle_key")"; then
        return 1
      fi
      interrupted_script_identities="$(pending_script_context_set \
        "$interrupted_script_identities" "$item" "$identity_encoded")"
    else
      # A pre-v5 ID-only intent has no recoverable owner/cycle identity.  Do
      # not risk replaying it after an interruption; a future, context-rich
      # cycle can still use its distinct context once this tombstone is kept.
      interrupted_script_actions="${interrupted_script_actions:+${interrupted_script_actions},}${item}"
    fi
  done
}

mark_interrupted_script_window() {
  local window="$1" owner_id="$2" reset_epoch="$3"
  local previous_contexts="$interrupted_script_contexts"
  local previous_identities="$interrupted_script_identities"
  local previous_actions="$interrupted_script_actions"
  case "$window" in
    5h)
      if ! mark_interrupted_script_list "$pending_script_5h_actions" "$owner_id" "$reset_epoch" \
        || ! mark_interrupted_script_list "$pending_script_5h_reset_actions" "$owner_id" "$reset_epoch"; then
        interrupted_script_contexts="$previous_contexts"
        interrupted_script_identities="$previous_identities"
        interrupted_script_actions="$previous_actions"
        return 1
      fi
      ;;
    weekly)
      if ! mark_interrupted_script_list "$pending_script_weekly_actions" "$owner_id" "$reset_epoch" \
        || ! mark_interrupted_script_list "$pending_script_weekly_reset_actions" "$owner_id" "$reset_epoch"; then
        interrupted_script_contexts="$previous_contexts"
        interrupted_script_identities="$previous_identities"
        interrupted_script_actions="$previous_actions"
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
  # The per-list helper intentionally only mutates memory.  Persist once for
  # the selected window, and roll back all of its marker changes if that write
  # fails so callers can fail closed before clearing the pending intent.
  if [[ "$interrupted_script_contexts" == "$previous_contexts" \
    && "$interrupted_script_identities" == "$previous_identities" \
    && "$interrupted_script_actions" == "$previous_actions" ]]; then
    return 0
  fi
  if ! persist_alert_state; then
    interrupted_script_contexts="$previous_contexts"
    interrupted_script_identities="$previous_identities"
    interrupted_script_actions="$previous_actions"
    ALERT_PROCESSING_ERROR="interrupted alert script tombstone persistence failed"
    echo "[ERROR] Could not journal interrupted alert script actions." >&2
    return 1
  fi
}

remove_pending_script_contexts_for_list() {
  local list="$1" item
  local -a items=()
  [[ -n "$list" ]] || return 0
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    pending_script_contexts="$(pending_script_context_remove "$pending_script_contexts" "$item")"
  done
}

# These helpers use Bash's dynamic function scope: they are called only while
# check_thresholds owns the corresponding local state variables. Keeping the
# four lifecycle lists together prevents an owner/cycle reset from leaving a
# stale pending or suppressed action behind.
clear_5h_script_actions() {
  remove_pending_script_contexts_for_list "$pending_script_5h_actions"
  attempted_script_5h_actions=""
  pending_script_5h_actions=""
  suppressed_script_5h_actions=""
}

clear_weekly_script_actions() {
  remove_pending_script_contexts_for_list "$pending_script_weekly_actions"
  attempted_script_weekly_actions=""
  pending_script_weekly_actions=""
  suppressed_script_weekly_actions=""
}

clear_5h_reset_script_actions() {
  remove_pending_script_contexts_for_list "$pending_script_5h_reset_actions"
  attempted_script_5h_reset_actions=""
  pending_script_5h_reset_actions=""
  suppressed_script_5h_reset_actions=""
}

clear_weekly_reset_script_actions() {
  remove_pending_script_contexts_for_list "$pending_script_weekly_reset_actions"
  attempted_script_weekly_reset_actions=""
  pending_script_weekly_reset_actions=""
  suppressed_script_weekly_reset_actions=""
}

has_unfinished_reset_script_actions() {
  local window="$1" rule_position action_id event completed_name suppressed_name
  for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_IDS[@]}; rule_position++ )); do
    event="${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}"
    [[ "$event" == "${window}:reset" ]] || continue
    action_id="${ALERT_SCRIPT_RULE_IDS[$rule_position]}"
    if [[ "$window" == 5h ]]; then
      completed_name=attempted_script_5h_reset_actions
      suppressed_name=suppressed_script_5h_reset_actions
    else
      completed_name=attempted_script_weekly_reset_actions
      suppressed_name=suppressed_script_weekly_reset_actions
    fi
    csv_contains "${!completed_name}" "$action_id" && continue
    csv_contains "${!suppressed_name}" "$action_id" && continue
    return 0
  done
  return 1
}

canonicalize_alert_limit_id() {
  python3 - "$1" <<'PYEOF'
import hashlib
import re
import sys

value = sys.argv[1]
if re.fullmatch(r"limit-[0-9a-f]{64}", value):
    print(value)
else:
    print("limit-" + hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest())
PYEOF
}

migrate_alert_state_file() {
  [[ -f "$STATE_FILE" ]] || return 0
  python3 - "$STATE_FILE" <<'PYEOF'
import hashlib
import os
import pathlib
import re
import stat
import tempfile
import sys

path = pathlib.Path(sys.argv[1])
try:
    raw = path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"cannot read alert state: {exc}")

values = {}
lines = raw.splitlines()
for line_number, line in enumerate(lines, 1):
    if not line:
        continue
    key, separator, value = line.partition("=")
    if not separator or not key or key in values:
        raise SystemExit(f"invalid alert state line {line_number}")
    values[key] = value

version_text = values.get("state_version", "0")
if not re.fullmatch(r"[0-9]+", version_text):
    raise SystemExit("invalid alert state version")
version = int(version_text)
if version > 5:
    raise SystemExit(f"unsupported future alert state version {version}")
if version < 0:
    raise SystemExit("invalid alert state version")

marker = values.get("limit_id_contract_version")
if marker is not None:
    if marker != "1" or version < 5:
        raise SystemExit("invalid alert state limit ID contract marker")
    for key in ("observed_5h_limit_id", "observed_weekly_limit_id",
                "five_h_armed_limit_id", "weekly_armed_limit_id",
                "pending_observed_weekly_reset_limit_id"):
        value = values.get(key, "")
        if value and not re.fullmatch(r"limit-[0-9a-f]{64}", value):
            raise SystemExit(f"marked alert state contains a raw {key}")
    raise SystemExit(0)

if version not in range(0, 5):
    raise SystemExit(f"unsupported alert state version {version}")

def opaque(value):
    if not value:
        return value
    return "limit-" + hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()

for key in ("observed_5h_limit_id", "observed_weekly_limit_id",
            "five_h_armed_limit_id", "weekly_armed_limit_id",
            "pending_observed_weekly_reset_limit_id"):
    if key in values:
        values[key] = opaque(values[key])

output = ["state_version=5", "limit_id_contract_version=1"]
for line in lines:
    if not line:
        continue
    key, _, value = line.partition("=")
    if key in {"state_version", "limit_id_contract_version"}:
        continue
    if key in {"observed_5h_limit_id", "observed_weekly_limit_id",
               "five_h_armed_limit_id", "weekly_armed_limit_id",
               "pending_observed_weekly_reset_limit_id"}:
        value = values[key]
    output.append(f"{key}={value}")
encoded = ("\n".join(output) + "\n").encode("utf-8")

try:
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode or (stat.S_IRUSR | stat.S_IWUSR))
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
except OSError as exc:
    raise SystemExit(f"cannot atomically migrate alert state: {exc}")
PYEOF
}

persist_alert_state_file() {
  local state_tmp="$1"
  if ! python3 - "$state_tmp" "$STATE_FILE" <<'PYEOF'
import os
import pathlib
import sys

temporary, destination = map(pathlib.Path, sys.argv[1:])
with temporary.open("rb") as handle:
    os.fsync(handle.fileno())
os.replace(temporary, destination)
directory_fd = os.open(destination.parent, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PYEOF
  then
    rm -f "$state_tmp"
    return 1
  fi
}

persist_alert_state() {
  local state_tmp
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' \
    'state_version=5' \
    'limit_id_contract_version=1' \
    "prev_5h_pct=${prev_5h_pct}" \
    "prev_weekly_pct=${prev_weekly_pct}" \
    "observed_5h_pct=${observed_5h_pct}" \
    "observed_5h_reset_at=${observed_5h_reset_at}" \
    "observed_5h_limit_id=${observed_5h_limit_id}" \
    "observed_weekly_pct=${observed_weekly_pct}" \
    "observed_weekly_reset_at=${observed_weekly_reset_at}" \
    "observed_weekly_limit_id=${observed_weekly_limit_id}" \
    "five_h_armed_reset_at=${five_h_armed_reset_at}" \
    "five_h_armed_limit_id=${five_h_armed_limit_id}" \
    "weekly_armed_reset_at=${weekly_armed_reset_at}" \
    "weekly_armed_limit_id=${weekly_armed_limit_id}" \
    "last_notified_5h_reset_at=${last_notified_5h_reset_at}" \
    "last_notified_weekly_reset_at=${last_notified_weekly_reset_at}" \
    "local_observed_5h_reset_at=${local_observed_5h_reset_at}" \
    "local_observed_weekly_reset_at=${local_observed_weekly_reset_at}" \
    "pending_observed_weekly_reset_at=${pending_observed_weekly_reset_at}" \
    "pending_observed_weekly_reset_limit_id=${pending_observed_weekly_reset_limit_id}" \
    "notified_5h_thresholds=${notified_5h_thresholds}" \
    "notified_weekly_thresholds=${notified_weekly_thresholds}" \
    "pending_5h_threshold=${pending_5h_threshold}" \
    "pending_weekly_threshold=${pending_weekly_threshold}" \
    "alerts_disabled_since=${alerts_disabled_since}" \
    "script_tracking_initialized=${script_tracking_initialized}" \
    "script_prev_5h_pct=${script_prev_5h_pct}" \
    "script_prev_weekly_pct=${script_prev_weekly_pct}" \
    "attempted_script_5h_actions=${attempted_script_5h_actions}" \
    "attempted_script_weekly_actions=${attempted_script_weekly_actions}" \
    "pending_script_5h_actions=${pending_script_5h_actions}" \
    "pending_script_weekly_actions=${pending_script_weekly_actions}" \
    "pending_script_contexts=${pending_script_contexts}" \
    "interrupted_script_contexts=${interrupted_script_contexts}" \
    "interrupted_script_identities=${interrupted_script_identities}" \
    "interrupted_script_actions=${interrupted_script_actions}" \
    "suppressed_script_5h_actions=${suppressed_script_5h_actions}" \
    "suppressed_script_weekly_actions=${suppressed_script_weekly_actions}" \
    "script_5h_reset_attempted_at=${script_5h_reset_attempted_at}" \
    "script_weekly_reset_attempted_at=${script_weekly_reset_attempted_at}" \
    "attempted_script_5h_reset_actions=${attempted_script_5h_reset_actions}" \
    "attempted_script_weekly_reset_actions=${attempted_script_weekly_reset_actions}" \
    "pending_script_5h_reset_actions=${pending_script_5h_reset_actions}" \
    "pending_script_weekly_reset_actions=${pending_script_weekly_reset_actions}" \
    "suppressed_script_5h_reset_actions=${suppressed_script_5h_reset_actions}" \
    "suppressed_script_weekly_reset_actions=${suppressed_script_weekly_reset_actions}" > "$state_tmp"; then
    rm -f "$state_tmp"
    return 1
  fi
  persist_alert_state_file "$state_tmp"
}

persist_observed_5h_intent() {
  local reset_epoch="$1"
  local previous_last="$last_notified_5h_reset_at"
  local previous_marker="$local_observed_5h_reset_at"
  local previous_arm="$five_h_armed_reset_at"
  local previous_owner="$five_h_armed_limit_id"
  (( reset_epoch > 0 )) || return 1
  if (( five_h_armed_reset_at == reset_epoch )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]]; then
    last_notified_5h_reset_at="$reset_epoch"
  fi
  local_observed_5h_reset_at="$reset_epoch"
  # A transient state-write failure must not discard the only observation that
  # proves a local reset.  Retry the complete intent once while all of its
  # fields are still in memory; a persistent failure remains fail-closed.
  if persist_alert_state || persist_alert_state; then return 0; fi
  last_notified_5h_reset_at="$previous_last"
  local_observed_5h_reset_at="$previous_marker"
  five_h_armed_reset_at="$previous_arm"
  five_h_armed_limit_id="$previous_owner"
  return 1
}

run_alert_script() {
  local rule_position="$1" event_kind="$2" window="$3" threshold="$4" remaining_pct="$5"
  local reset_at="$6" reset_label="$7" scraped_at="$8" message="$9"
  local rule_index="${ALERT_SCRIPT_RULE_INDICES[$rule_position]}"
  local action_id="${ALERT_SCRIPT_RULE_IDS[$rule_position]}"
  local path="${ALERT_SCRIPT_RULE_PATHS[$rule_position]}" working_directory exit_code=0 event_label
  working_directory="$(dirname "$path")"
  event_label="${window}:${threshold:-reset}"
  if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
    echo "[INFO] Script rule ${rule_index} for ${event_label} suppressed while ALERTS_ENABLED=0."
    return 0
  fi
  echo "[ACTION] Script rule ${rule_index} for ${event_label}: ${path}"
  (
    cd "$working_directory" || exit 125
    timeout --signal=TERM --kill-after=5s "$ALERT_SCRIPT_TIMEOUT_SECONDS" \
      env -u DISCORD_WEBHOOK -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID \
          -u GITHUB_PAT -u GITHUB_GIST_ID \
          "CODEX_ALERT_EVENT=${event_kind}" \
          "CODEX_ALERT_WINDOW=${window}" \
          "CODEX_ALERT_THRESHOLD=${threshold}" \
          "CODEX_ALERT_REMAINING_PCT=${remaining_pct}" \
          "CODEX_ALERT_RESET_AT=${reset_at}" \
          "CODEX_ALERT_RESET_LABEL=${reset_label}" \
          "CODEX_ALERT_SCRAPED_AT=${scraped_at}" \
          "CODEX_ALERT_MESSAGE=${message}" \
          "CODEX_ALERT_CODEX_BIN=${CODEX_BIN:-codex}" \
          "CODEX_ALERT_ACTION_ID=${action_id}" \
          "CODEX_ALERT_RULE_INDEX=${rule_index}" \
          "$path" </dev/null
  ) || exit_code=$?

  if (( exit_code == 0 )); then
    echo "[OK] Script rule ${rule_index} completed."
  elif (( exit_code == 124 || exit_code == 137 )); then
    echo "[WARN] Script rule ${rule_index} timed out after ${ALERT_SCRIPT_TIMEOUT_SECONDS}s; action remains pending and will be retried." >&2
  else
    echo "[WARN] Script rule ${rule_index} failed with exit code ${exit_code}; action remains pending and will be retried." >&2
  fi
  return "$exit_code"
}

attempt_alert_script() {
  local rule_position="$1" completed_list_name="$2" pending_list_name="$3" suppressed_list_name="$4"
  shift 4
  local event_kind="$1" window="$2" threshold="$3" remaining_pct="$4"
  local reset_at="$5" reset_label="$6" scraped_at="$7" message="$8"
  local action_id="${ALERT_SCRIPT_RULE_IDS[$rule_position]}"
  local previous_completed="${!completed_list_name}"
  local previous_pending="${!pending_list_name}"
  local previous_suppressed="${!suppressed_list_name}"
  local previous_contexts="$pending_script_contexts"
  local updated_list cycle_key context_encoded

  cycle_key="limit:${limit_id}|unarmed"
  if [[ "$reset_at" =~ ^[0-9]+$ ]] && (( reset_at > 0 )); then
    cycle_key="limit:${limit_id}|reset:${reset_at}"
  fi
  if ! context_encoded="$(encode_alert_script_context "$event_kind" "$window" \
      "$threshold" "$remaining_pct" "$reset_at" "$reset_label" "$scraped_at" \
      "$message" "$limit_id" "$cycle_key")"; then
    ALERT_PROCESSING_ERROR="alert script context encoding failed"
    return 1
  fi

  # Existing attempted_script_* values are the backward-compatible completed
  # ledger. Pending intent is separate: a crash after its write must not be
  # mistaken for a completed hook.
  csv_contains "$previous_completed" "$action_id" && return 0
  csv_contains "$previous_suppressed" "$action_id" && return 0
  csv_contains "$script_actions_started" "$action_id" && return 0

  # An interrupted intent is a durable tombstone, not a retryable pending
  # action.  Match the immutable context first; the identity fallback is only
  # for pre-context ID-only state.  New cycles retain their action IDs but use
  # a different owner/cycle identity and therefore remain executable.
  if pending_script_context_has "$interrupted_script_contexts" "$action_id" \
      "$context_encoded" \
    || interrupted_script_identity_has "$interrupted_script_identities" \
      "$action_id" "$limit_id" "$cycle_key" \
    || csv_contains "$interrupted_script_actions" "$action_id"; then
    updated_list="$(csv_without "$previous_pending" "$action_id")"
    printf -v "$pending_list_name" '%s' "$updated_list"
    printf -v "$suppressed_list_name" '%s' "${previous_suppressed:+${previous_suppressed},}${action_id}"
    pending_script_contexts="$(pending_script_context_remove "$pending_script_contexts" "$action_id")"
    if ! persist_alert_state; then
      printf -v "$pending_list_name" '%s' "$previous_pending"
      printf -v "$suppressed_list_name" '%s' "$previous_suppressed"
      pending_script_contexts="$previous_contexts"
      ALERT_PROCESSING_ERROR="interrupted alert script tombstone acknowledgement failed"
      echo "[ERROR] Could not acknowledge interrupted alert script action." >&2
      return 1
    fi
    return 0
  fi

  if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
    # Suppression is an explicit operator decision, not a successful hook.
    # Keep it separate so a pending enabled action remains retryable after a
    # temporary disable, while a newly observed disabled action is not replayed
    # when alerts are enabled again.
    if csv_contains "$previous_pending" "$action_id"; then
      ALERT_PROCESSING_ERROR="alert script action is pending while alerts are disabled"
      return 1
    fi
    printf -v "$suppressed_list_name" '%s' "${previous_suppressed:+${previous_suppressed},}${action_id}"
    if ! persist_alert_state; then
      printf -v "$suppressed_list_name" '%s' "$previous_suppressed"
      ALERT_PROCESSING_ERROR="alert script suppression persistence failed"
      echo "[ERROR] Could not journal suppressed alert script action." >&2
      return 1
    fi
    return 0
  fi

  if ! csv_contains "$previous_pending" "$action_id"; then
    printf -v "$pending_list_name" '%s' "${previous_pending:+${previous_pending},}${action_id}"
    pending_script_contexts="$(pending_script_context_set "$pending_script_contexts" \
      "$action_id" "$context_encoded")"
    if ! persist_alert_state; then
      printf -v "$pending_list_name" '%s' "$previous_pending"
      pending_script_contexts="$previous_contexts"
      echo "[ERROR] Could not journal alert script intent; script was not started." >&2
      ALERT_PROCESSING_ERROR="alert script intent persistence failed"
      return 1
    fi
  elif ! pending_script_context_has "$pending_script_contexts" "$action_id"; then
    # Upgrade a legacy ID-only pending marker before running it.  The context
    # then remains autonomous even if this poll clears its detector arm.
    pending_script_contexts="$(pending_script_context_set "$pending_script_contexts" \
      "$action_id" "$context_encoded")"
    if ! persist_alert_state; then
      pending_script_contexts="$previous_contexts"
      ALERT_PROCESSING_ERROR="alert script context persistence failed"
      return 1
    fi
  fi

  # The pending intent is durable before this call. If the process dies here,
  # the next poll sees the pending ID and retries. A successful hook is only
  # considered complete after the following atomic state write.
  script_actions_started="${script_actions_started:+${script_actions_started},}${action_id}"
  if ! run_alert_script "$rule_position" "$@"; then
    ALERT_PROCESSING_ERROR="alert script action failed; pending retry"
    SCRIPT_HOOK_FAILED=1
    # A hook failure is an expected, retryable delivery outcome. Keep the
    # monitor cycle alive and leave the pending intent durable; callers use the
    # flag to avoid advancing the corresponding script baseline.
    return 0
  fi

  updated_list="$(csv_without "${!pending_list_name}" "$action_id")"
  printf -v "$pending_list_name" '%s' "$updated_list"
  printf -v "$completed_list_name" '%s' "${previous_completed:+${previous_completed},}${action_id}"
  pending_script_contexts="$(pending_script_context_remove "$pending_script_contexts" "$action_id")"
  if ! persist_alert_state; then
    # Do not acknowledge a hook until its completion is durable. The pending
    # marker remains the recovery source and a crash/failure in this write may
    # replay a hook that already took effect; hooks should use the stable action
    # ID when they can provide their own idempotence.
    printf -v "$pending_list_name" '%s' "${previous_pending:-${action_id}}"
    printf -v "$completed_list_name" '%s' "$previous_completed"
    pending_script_contexts="$previous_contexts"
    ALERT_PROCESSING_ERROR="alert script completion persistence failed; pending retry"
    echo "[ERROR] Could not journal completed alert script action; action remains pending." >&2
    return 1
  fi
}

find_alert_script_rule_position() {
  local wanted="$1" rule_position
  for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_IDS[@]}; rule_position++ )); do
    if [[ "${ALERT_SCRIPT_RULE_IDS[$rule_position]}" == "$wanted" ]]; then
      printf '%s' "$rule_position"
      return 0
    fi
  done
  return 1
}

resume_legacy_pending_alert_scripts() {
  local rule_position action_id event_kind event_name window selector pending_name
  local completed_name suppressed_name pending_value threshold remaining_pct
  local reset_at reset_label message owner_id
  for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_IDS[@]}; rule_position++ )); do
    action_id="${ALERT_SCRIPT_RULE_IDS[$rule_position]}"
    window="${ALERT_SCRIPT_RULE_EVENTS[$rule_position]%%:*}"
    event_name="${ALERT_SCRIPT_RULE_EVENTS[$rule_position]#*:}"
    if [[ "$event_name" == reset ]]; then
      event_kind=reset
      selector=reset
    else
      event_kind=threshold
      selector="$event_name"
    fi
    case "${event_kind}:${window}" in
      reset:5h)
        pending_name=pending_script_5h_reset_actions
        completed_name=attempted_script_5h_reset_actions
        suppressed_name=suppressed_script_5h_reset_actions
        owner_id="$five_h_armed_limit_id"
        [[ "$owner_id" == "$limit_id" || "$observed_5h_limit_id" == "$limit_id" ]] || continue
        reset_at="$script_5h_reset_attempted_at"
        if ! [[ "$reset_at" =~ ^[0-9]+$ ]] || ! (( reset_at > 0 )); then
          reset_at="$five_h_armed_reset_at"
        fi
        if ! [[ "$reset_at" =~ ^[0-9]+$ ]] || ! (( reset_at > 0 )); then
          continue
        fi
        threshold=""
        remaining_pct="$five_h_pct"
        [[ "$remaining_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] || remaining_pct="$observed_5h_pct"
        reset_label="$five_h_reset"
        message="Codex 5h limit reset. A new usage cycle is available."
        ;;
      reset:weekly)
        pending_name=pending_script_weekly_reset_actions
        completed_name=attempted_script_weekly_reset_actions
        suppressed_name=suppressed_script_weekly_reset_actions
        owner_id="$weekly_armed_limit_id"
        [[ "$owner_id" == "$limit_id" || "$observed_weekly_limit_id" == "$limit_id" ]] || continue
        reset_at="$script_weekly_reset_attempted_at"
        if ! [[ "$reset_at" =~ ^[0-9]+$ ]] || ! (( reset_at > 0 )); then
          reset_at="$weekly_armed_reset_at"
        fi
        if ! [[ "$reset_at" =~ ^[0-9]+$ ]] || ! (( reset_at > 0 )); then
          continue
        fi
        threshold=""
        remaining_pct="$weekly_pct"
        [[ "$remaining_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] || remaining_pct="$observed_weekly_pct"
        reset_label="$weekly_reset"
        message="Codex weekly limit reset. A new usage cycle is available."
        ;;
      threshold:5h|threshold:weekly)
        if [[ "$window" == 5h ]]; then
          pending_name=pending_script_5h_actions
          completed_name=attempted_script_5h_actions
          suppressed_name=suppressed_script_5h_actions
          owner_id="$observed_5h_limit_id"
          remaining_pct="$five_h_pct"
          reset_at="$five_h_reset_at"
          reset_label="$five_h_reset"
          [[ "$remaining_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] || remaining_pct="$observed_5h_pct"
        else
          pending_name=pending_script_weekly_actions
          completed_name=attempted_script_weekly_actions
          suppressed_name=suppressed_script_weekly_actions
          owner_id="$observed_weekly_limit_id"
          remaining_pct="$weekly_pct"
          reset_at="$weekly_reset_at"
          reset_label="$weekly_reset"
          [[ "$remaining_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] || remaining_pct="$observed_weekly_pct"
        fi
        [[ "$owner_id" == "$limit_id" ]] || continue
        threshold="$selector"
        message="Codex ${window} limit at ${remaining_pct}% remaining (crossed ${threshold}% threshold)."
        ;;
      *)
        continue
        ;;
    esac
    pending_value="${!pending_name}"
    csv_contains "$pending_value" "$action_id" || continue
    pending_script_context_has "$pending_script_contexts" "$action_id" && continue
    # The pre-context state format stored only the action ID.  Reconstruct from
    # the durable detector anchor when one exists, then immediately upgrade the
    # marker to the autonomous context before invoking the hook.
    attempt_alert_script "$rule_position" "$completed_name" "$pending_name" \
      "$suppressed_name" "$event_kind" "$window" "$threshold" "$remaining_pct" \
      "$reset_at" "$reset_label" "$scraped_at_epoch" "$message" || return 1
  done
}

resume_pending_alert_scripts() {
  local entry action_id encoded context_json rule_position
  local event_kind window threshold remaining_pct reset_at reset_label scraped_at
  local message_encoded context_limit_id cycle_key message completed_name pending_name suppressed_name
  local -a entries=()
  [[ "${ALERTS_ENABLED:-1}" == 1 ]] || return 0
  if [[ -n "$pending_script_contexts" ]]; then
    IFS=',' read -r -a entries <<< "$pending_script_contexts"
  fi
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    action_id="${entry%%:*}"
    if [[ "$entry" != *:* ]]; then
      # State versions before autonomous contexts only recorded the action ID.
      # There is no safe way to reconstruct its immutable invocation here, so
      # retain the marker for the detector path to upgrade deterministically.
      continue
    fi
    encoded="${entry#*:}"
    rule_position="$(find_alert_script_rule_position "$action_id")" || continue
    context_json="$(decode_alert_script_context "$encoded")" || {
      ALERT_PROCESSING_ERROR="alert script context decoding failed"
      return 1
    }
    IFS=$'\x1f' read -r event_kind window threshold remaining_pct reset_at reset_label \
      scraped_at message_encoded context_limit_id cycle_key < <(
      python3 - "$context_json" <<'PYEOF'
import base64
import json
import sys

context = json.loads(sys.argv[1])
print(
    context["event_kind"], context["window"], context["threshold"],
    context["remaining_pct"], context["reset_epoch"], context["reset_label"],
    context["scraped_at"],
    base64.b64encode(context["message"].encode("utf-8")).decode("ascii"),
    context["limit_id"], context["cycle_key"], sep="\x1f",
)
PYEOF
    )
    message="$(decode_alert_script_message "$message_encoded")" || {
      ALERT_PROCESSING_ERROR="alert script message decoding failed"
      return 1
    }
    [[ "$event_kind" == threshold && "$reset_at" == 0 ]] && reset_at=""
    [[ "$context_limit_id" == "$limit_id" ]] || continue
    [[ "$cycle_key" == "limit:${context_limit_id}|"* ]] || continue
    case "${event_kind}:${window}" in
      reset:5h)
        completed_name=attempted_script_5h_reset_actions
        pending_name=pending_script_5h_reset_actions
        suppressed_name=suppressed_script_5h_reset_actions
        ;;
      reset:weekly)
        completed_name=attempted_script_weekly_reset_actions
        pending_name=pending_script_weekly_reset_actions
        suppressed_name=suppressed_script_weekly_reset_actions
        ;;
      threshold:5h)
        completed_name=attempted_script_5h_actions
        pending_name=pending_script_5h_actions
        suppressed_name=suppressed_script_5h_actions
        ;;
      threshold:weekly)
        completed_name=attempted_script_weekly_actions
        pending_name=pending_script_weekly_actions
        suppressed_name=suppressed_script_weekly_actions
        ;;
      *)
        continue
        ;;
    esac
    attempt_alert_script "$rule_position" "$completed_name" "$pending_name" \
      "$suppressed_name" "$event_kind" "$window" "$threshold" "$remaining_pct" \
      "$reset_at" "$reset_label" "$scraped_at" "$message" || return 1
  done
  resume_legacy_pending_alert_scripts
}

reconcile_alert_deliveries() {
  local now="$1" current_limit_id="${2:-}" discard_other="${3:-0}"
  local terminal_file alert_id kind window reason event_limit_id selector remaining reset_epoch covered threshold ack_id
  local -a ack_ids=()
  terminal_file="$(mktemp "${RUNTIME_DIR}/.alerts-terminal.XXXXXX")" || return 1
  if ! python3 "$ALERTS_PY" terminal-unacknowledged "$ALERT_DELIVERIES_FILE" > "$terminal_file"; then
    rm -f "$terminal_file"
    return 1
  fi
  # A non-whitespace separator preserves the empty threshold-only/reset-only
  # fields that Bash would otherwise collapse when parsing tab-separated rows.
  while IFS=$'\x1f' read -r alert_id kind window reason event_limit_id selector remaining reset_epoch covered; do
    [[ -n "$alert_id" ]] || continue
    if [[ "$reason" == owner_interrupted || "$reason" == local_observed \
          || "$reason" == superseded || "$reason" == expired_after_reset ]]; then
      # An interrupted owner's occurrence is intentionally terminal and must
      # never apply its remaining percentage or reset marker to a later group.
      # Duplicate/superseded reset rows are likewise bookkeeping-only; the
      # surviving equivalent occurrence owns detector state.
      ack_ids+=("$alert_id")
      continue
    fi
    if [[ ( "$kind" == threshold || "$kind" == reset ) \
          && -n "$current_limit_id" && "$event_limit_id" != "$current_limit_id" ]]; then
      if [[ "$discard_other" == 1 ]]; then
        # A complete group switch makes the previous detector state obsolete.
        # The owner-interruption path also uses this mode after terminalizing
        # all old pending events, so their payload never pollutes the current
        # group's baseline.
        ack_ids+=("$alert_id")
        continue
      fi
      continue
    fi
    ack_ids+=("$alert_id")
    if [[ "$kind" == threshold ]]; then
      if [[ "$reason" == superseded || "$reason" == expired_after_reset \
            || "$reason" == local_observed ]]; then
        continue
      fi
      if [[ "$window" == 5h ]]; then
        IFS=',' read -r -a covered_values <<< "$covered"
        for threshold in "${covered_values[@]}"; do
          if [[ -n "$threshold" ]] && ! csv_contains "$notified_5h_thresholds" "$threshold"; then
            notified_5h_thresholds="${notified_5h_thresholds:+${notified_5h_thresholds},}${threshold}"
          fi
        done
        [[ "$pending_5h_threshold" == "$selector" ]] && pending_5h_threshold=""
        [[ -n "$remaining" ]] && prev_5h_pct="$remaining"
      else
        IFS=',' read -r -a covered_values <<< "$covered"
        for threshold in "${covered_values[@]}"; do
          if [[ -n "$threshold" ]] && ! csv_contains "$notified_weekly_thresholds" "$threshold"; then
            notified_weekly_thresholds="${notified_weekly_thresholds:+${notified_weekly_thresholds},}${threshold}"
          fi
        done
        [[ "$pending_weekly_threshold" == "$selector" ]] && pending_weekly_threshold=""
        [[ -n "$remaining" ]] && prev_weekly_pct="$remaining"
      fi
    elif [[ "$kind" == anomaly ]]; then
      # Detector state is durable in SQLite and was acknowledged at journal
      # registration time; anomaly delivery has no threshold/reset baseline.
      continue
    elif [[ "$window" == 5h ]]; then
      last_notified_5h_reset_at="$reset_epoch"
      [[ "$local_observed_5h_reset_at" == "$reset_epoch" ]] \
        && local_observed_5h_reset_at=0
      if [[ "$five_h_armed_reset_at" == "$reset_epoch" ]]; then
        five_h_armed_reset_at=0
        five_h_armed_limit_id=""
        notified_5h_thresholds=""
        pending_5h_threshold=""
        prev_5h_pct=100
      fi
    else
      last_notified_weekly_reset_at="$reset_epoch"
      [[ "$local_observed_weekly_reset_at" == "$reset_epoch" ]] \
        && local_observed_weekly_reset_at=0
      if [[ "$weekly_armed_reset_at" == "$reset_epoch" ]]; then
        weekly_armed_reset_at=0
        weekly_armed_limit_id=""
        notified_weekly_thresholds=""
        pending_weekly_threshold=""
        if (( observed_weekly_reset == 1 )); then prev_weekly_pct="$weekly_pct"; else prev_weekly_pct=100; fi
      fi
    fi
  done < <(python3 - "$terminal_file" <<'PYEOF'
import json
import pathlib
import sys
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    item = json.loads(line)
    event = item["event_data"]
    covered = ",".join(str(value) for value in event.get("covered_thresholds", []))
    print(item["alert_id"], item["kind"], item["window"], item["terminal_reason"],
          event.get("limit_id", ""), item["selector"], event.get("remaining_pct", ""),
          event.get("reset_epoch", 0), covered, sep="\x1f")
PYEOF
)
  rm -f "$terminal_file"
  (( ${#ack_ids[@]} == 0 )) && return 0
  if ! persist_alert_state; then
    echo "[ERROR] Could not persist reconciled alert state." >&2
    return 1
  fi
  for ack_id in "${ack_ids[@]}"; do
    if ! python3 "$ALERTS_PY" acknowledge "$ALERT_DELIVERIES_FILE" "$ack_id" --at "$now"; then
      return 1
    fi
  done
}

initialize_alert_delivery_journal() {
  local state_version="$1" now="$2" limit_id="$3" five_h_pct="$4" weekly_pct="$5"
  local five_h_reset="$6" weekly_reset="$7" skip_five_h_observed="${8:-0}"
  local observed_five_owner="${9:-}" armed_five_owner="${10:-}"
  local observed_weekly_owner="${11:-}" armed_weekly_owner="${12:-}"
  local five_h_owner="" weekly_owner="" allow_five_threshold=0 allow_weekly_threshold=0
  local five_h_reconstruct_reset=0 weekly_reconstruct_reset=0
  local channels thresholds_csv payload
  if [[ -n "$armed_five_owner" && ( -z "$observed_five_owner" || "$armed_five_owner" == "$observed_five_owner" ) ]]; then
    five_h_owner="$armed_five_owner"
  elif [[ -n "$observed_five_owner" && -z "$armed_five_owner" ]]; then
    five_h_owner="$observed_five_owner"
  fi
  if [[ -n "$armed_weekly_owner" && ( -z "$observed_weekly_owner" || "$armed_weekly_owner" == "$observed_weekly_owner" ) ]]; then
    weekly_owner="$armed_weekly_owner"
  elif [[ -n "$observed_weekly_owner" && -z "$armed_weekly_owner" ]]; then
    weekly_owner="$observed_weekly_owner"
  fi
  [[ "$five_h_owner" == "$limit_id" ]] && allow_five_threshold=1
  [[ "$weekly_owner" == "$limit_id" ]] && allow_weekly_threshold=1
  if [[ "$five_h_owner" == "$limit_id" && "$five_h_armed_reset_at" =~ ^[0-9]+$ ]] \
    && (( five_h_armed_reset_at > 0 )); then
    five_h_reconstruct_reset="$five_h_armed_reset_at"
  fi
  if [[ "$weekly_owner" == "$limit_id" && "$weekly_armed_reset_at" =~ ^[0-9]+$ ]] \
    && (( weekly_armed_reset_at > 0 )); then
    weekly_reconstruct_reset="$weekly_armed_reset_at"
  fi
  if [[ "$skip_five_h_observed" == 1 ]]; then
    # This sample is itself the observed local reset.  Do not reconstruct the
    # old 5h threshold or reset occurrence from the state snapshot while the
    # delivery journal is being initialized.
    pending_5h_threshold=""
  fi
  # A detector marker without a durable owner cannot safely be reconstructed:
  # using the current sample's group would manufacture a cross-group event.
  [[ -n "$five_h_owner" ]] || pending_5h_threshold=""
  [[ -n "$weekly_owner" ]] || pending_weekly_threshold=""
  if (( five_h_armed_reset_at > 0 && now > five_h_armed_reset_at + 5 * 60 * 60 )); then
    last_notified_5h_reset_at="$five_h_armed_reset_at"
    five_h_armed_reset_at=0
    five_h_armed_limit_id=""
    notified_5h_thresholds=""
    pending_5h_threshold=""
    prev_5h_pct=100
  fi
  if (( weekly_armed_reset_at > 0 && now > weekly_armed_reset_at + 7 * 24 * 60 * 60 )); then
    last_notified_weekly_reset_at="$weekly_armed_reset_at"
    weekly_armed_reset_at=0
    weekly_armed_limit_id=""
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    prev_weekly_pct=100
  fi
  channels="$(configured_alert_channels_json)" || return 1
  thresholds_csv="$(load_thresholds | paste -sd, -)"
  if [[ "$channels" != "[]" ]]; then
    if [[ -n "$pending_5h_threshold" && "$allow_five_threshold" == 1 \
          && ! "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      echo "[ERROR] Historical 5h pending alert cannot be reconstructed from the current observation." >&2
      return 1
    fi
    if [[ -n "$pending_weekly_threshold" && "$allow_weekly_threshold" == 1 \
          && ! "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      echo "[ERROR] Historical weekly pending alert cannot be reconstructed from the current observation." >&2
      return 1
    fi
  else
    if [[ -n "$pending_5h_threshold" && "$allow_five_threshold" == 1 ]]; then
      for threshold in $(load_thresholds); do
        if python3 - "$prev_5h_pct" "$pending_5h_threshold" "$threshold" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
        then
          csv_contains "$notified_5h_thresholds" "$threshold" \
            || notified_5h_thresholds="${notified_5h_thresholds:+${notified_5h_thresholds},}${threshold}"
        fi
      done
      pending_5h_threshold=""
      [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && prev_5h_pct="$five_h_pct"
    fi
    if [[ -n "$pending_weekly_threshold" && "$allow_weekly_threshold" == 1 ]]; then
      for threshold in $(load_thresholds); do
        if python3 - "$prev_weekly_pct" "$pending_weekly_threshold" "$threshold" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
        then
          csv_contains "$notified_weekly_thresholds" "$threshold" \
            || notified_weekly_thresholds="${notified_weekly_thresholds:+${notified_weekly_thresholds},}${threshold}"
        fi
      done
      pending_weekly_threshold=""
      [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && prev_weekly_pct="$weekly_pct"
    fi
  fi
  payload="$(MIGRATION_FIVE_MESSAGE="*Codex 5h limit at ${five_h_pct}% remaining* (crossed ${pending_5h_threshold}% threshold). Resets at ${five_h_reset}" \
    MIGRATION_WEEKLY_MESSAGE="*Codex weekly limit at ${weekly_pct}% remaining* (crossed ${pending_weekly_threshold}% threshold). Resets ${weekly_reset}" \
    python3 - "$state_version" "$now" "$five_h_owner" "$weekly_owner" "$channels" "$thresholds_csv" \
      "$pending_5h_threshold" "$pending_weekly_threshold" "$prev_5h_pct" "$prev_weekly_pct" \
      "$five_h_pct" "$weekly_pct" "$five_h_reconstruct_reset" "$weekly_reconstruct_reset" \
      "$last_notified_5h_reset_at" "$last_notified_weekly_reset_at" \
      "$skip_five_h_observed" "$allow_five_threshold" "$allow_weekly_threshold" <<'PYEOF'
import json
import os
import sys

(version, now, five_limit_id, weekly_limit_id, channels_raw, thresholds_raw, pending_five, pending_weekly,
 previous_five, previous_weekly, five_pct, weekly_pct, five_reset, weekly_reset,
 last_five_reset, last_weekly_reset, skip_five, allow_five, allow_weekly) = sys.argv[1:]
version, now, five_reset, weekly_reset, last_five_reset, last_weekly_reset = map(
    int, (version, now, five_reset, weekly_reset, last_five_reset, last_weekly_reset))
skip_five = int(skip_five)
allow_five = int(allow_five)
allow_weekly = int(allow_weekly)
channels = json.loads(channels_raw)
thresholds = [int(value) for value in thresholds_raw.split(",") if value]
alerts = []

def threshold(window, selector, previous, remaining, reset, message, event_limit_id):
    allow = allow_five if window == "5h" else allow_weekly
    if not selector or not channels or not event_limit_id or not allow \
            or (window == "5h" and skip_five):
        return
    critical = int(selector)
    cycle = f"legacy-v{version}|limit:{event_limit_id}|" + (f"reset:{reset}" if reset else "unarmed")
    alerts.append({
        "kind": "threshold", "window": window, "selector": selector,
        "cycle_key": cycle, "id_namespace": f"legacy-v{version}", "message": message,
        "event_data": {"limit_id": event_limit_id, "remaining_pct": float(remaining),
                       "reset_epoch": reset,
                       "covered_thresholds": [value for value in thresholds if critical <= value < float(previous)]},
        "created_at": min(now, reset) if reset else now,
        "expires_at": reset, "channels": channels,
        "replace_pending_thresholds": True, "expire_threshold_cycle": None,
    })

def reset(window, reset_at, last_reset, validity, event_limit_id, message, allow):
    if (not channels or not event_limit_id or not allow or not reset_at or reset_at > now or reset_at == last_reset
            or now > reset_at + validity or (window == "5h" and skip_five)):
        return
    cycle = f"legacy-v{version}|limit:{event_limit_id}|reset:{reset_at}"
    alerts.append({
        "kind": "reset", "window": window, "selector": "reset",
        "cycle_key": cycle, "id_namespace": f"legacy-v{version}", "message": message,
        "event_data": {"limit_id": event_limit_id, "reset_epoch": reset_at},
        "created_at": reset_at, "expires_at": reset_at + validity, "channels": channels,
        "replace_pending_thresholds": False, "expire_threshold_cycle": cycle,
    })

threshold("5h", pending_five, previous_five, five_pct, five_reset, os.environ["MIGRATION_FIVE_MESSAGE"], five_limit_id)
threshold("weekly", pending_weekly, previous_weekly, weekly_pct, weekly_reset, os.environ["MIGRATION_WEEKLY_MESSAGE"], weekly_limit_id)
reset("5h", five_reset, last_five_reset, 5 * 60 * 60, five_limit_id,
      "*Codex 5h limit reset.* A new usage cycle is available.", allow_five)
reset("weekly", weekly_reset, last_weekly_reset, 7 * 24 * 60 * 60,
      weekly_limit_id, "*Codex weekly limit reset.* A new usage cycle is available.", allow_weekly)
print(json.dumps({"completed_at": now, "alerts": alerts}))
PYEOF
)" || return 1
  printf '%s\n' "$payload" | python3 "$ALERTS_PY" init "$ALERT_DELIVERIES_FILE" --source-state-version "$state_version"
}

check_thresholds() {
  local five_h_pct="$1"
  local weekly_pct="$2"
  local five_h_reset="$3"
  local weekly_reset="$4"
  local five_h_reset_at="$5"
  local weekly_reset_at="$6"
  local scraped_at_epoch="$7"
  local limit_id="${8:-default}"
  if ! limit_id="$(canonicalize_alert_limit_id "$limit_id")"; then
    ALERT_PROCESSING_ERROR="invalid alert limit ID"
    return 1
  fi

  local state_version=1
  local prev_5h_pct=100
  local prev_weekly_pct=100
  local observed_5h_pct=""
  local observed_5h_reset_at=0
  local observed_5h_limit_id=""
  local observed_weekly_pct=""
  local observed_weekly_reset_at=0
  local observed_weekly_limit_id=""
  local five_h_armed_reset_at=0
  local five_h_armed_limit_id=""
  local weekly_armed_reset_at=0
  local weekly_armed_limit_id=""
  local last_notified_5h_reset_at=0
  local last_notified_weekly_reset_at=0
  local local_observed_5h_reset_at=0
  local local_observed_weekly_reset_at=0
  local pending_observed_weekly_reset_at=0
  local pending_observed_weekly_reset_limit_id=""
  local notified_5h_thresholds=""
  local notified_weekly_thresholds=""
  local pending_5h_threshold=""
  local pending_weekly_threshold=""
  local alerts_disabled_since=0
  local script_tracking_initialized=0
  local script_prev_5h_pct=100
  local script_prev_weekly_pct=100
  local attempted_script_5h_actions=""
  local attempted_script_weekly_actions=""
  local pending_script_5h_actions=""
  local pending_script_weekly_actions=""
  local suppressed_script_5h_actions=""
  local suppressed_script_weekly_actions=""
  local script_5h_reset_attempted_at=0
  local script_weekly_reset_attempted_at=0
  local attempted_script_5h_reset_actions=""
  local attempted_script_weekly_reset_actions=""
  local pending_script_5h_reset_actions=""
  local pending_script_weekly_reset_actions=""
  local suppressed_script_5h_reset_actions=""
  local suppressed_script_weekly_reset_actions=""
  local pending_script_contexts=""
  local interrupted_script_contexts=""
  local interrupted_script_identities=""
  local interrupted_script_actions=""
  local thresholds state_key state_value pace pace_suffix t critical status=0 reset_age rule_position script_threshold
  local original_pending cycle_key covered_json registration_status disabled_notified transaction_epoch
  local weekly_cycle_key weekly_request_json
  local due_5h_reset_at=0 due_weekly_reset_at=0 script_state_error=0 script_hook_error=0 initialize_script_baseline=0
  local weekly_network_request=0 script_actions_started=""
  local observed_weekly_reset=0 five_h_observation_valid=0 weekly_observation_valid=0
  local process_5h_sample=1 process_weekly_sample=1 state_loaded=0
  local initialize_5h_baseline=0 observed_5h_reset=0 observed_5h_reset_candidate=0
  local observed_5h_scheduled_due=0
  local observed_5h_superseded_reset_at=0 observed_5h_local_tombstone=0
  local observed_5h_reset_recovery=0 observed_5h_atomic_done=0
  local observed_5h_initial_no_arm=0
  local observed_weekly_reset_recovery=0 weekly_intent_succeeded=1
  local observed_weekly_scheduled_due=0 weekly_atomic_done=0
  local interrupted_5h_owner="" interrupted_5h_reset_at=0
  local interrupted_weekly_owner="" interrupted_weekly_reset_at=0
  local previous_local_observed_weekly_reset_at=0
  local discard_other_group_terminal=0
  local resumed_after_disabled=0 resume_delivery_attempted=0
  local journal_source_state_version=1 raw_source_state_version
  local -a script_thresholds=()
  ALERT_PROCESSING_ERROR=""
  SCRIPT_HOOK_FAILED=0
  if [[ -f "$STATE_FILE" ]]; then
    raw_source_state_version="$(awk -F= '$1 == "state_version" {print $2; exit}' "$STATE_FILE")"
    if [[ "$raw_source_state_version" =~ ^[0-9]+$ ]]; then
      journal_source_state_version="$raw_source_state_version"
    fi
    if ! migrate_alert_state_file; then
      echo "[ERROR] Alert state migration failed; alerts are disabled." >&2
      ALERT_PROCESSING_ERROR="alert state migration failed"
      return 1
    fi
    state_loaded=1
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
        state_version)
          [[ "$state_value" =~ ^[0-9]+$ ]] || { ALERT_PROCESSING_ERROR="invalid alert state version"; return 1; }
          state_version="$state_value"
          ;;
        prev_5h_pct|prev_weekly_pct|observed_5h_pct|observed_weekly_pct|script_prev_5h_pct|script_prev_weekly_pct)
          if [[ "$state_value" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
        observed_5h_reset_at|observed_weekly_reset_at|five_h_armed_reset_at|weekly_armed_reset_at|last_notified_5h_reset_at|last_notified_weekly_reset_at|local_observed_5h_reset_at|local_observed_weekly_reset_at|pending_observed_weekly_reset_at)
          if [[ "$state_value" =~ ^[0-9]+$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
        notified_5h_thresholds|notified_weekly_thresholds)
          [[ "$state_value" =~ ^([0-9]+,)*[0-9]*$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        pending_5h_threshold|pending_weekly_threshold)
          [[ -z "$state_value" || "$state_value" =~ ^[0-9]+$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        alerts_disabled_since)
          [[ "$state_value" =~ ^[0-9]+$ ]] && alerts_disabled_since="$state_value"
          ;;
        observed_5h_limit_id|observed_weekly_limit_id|five_h_armed_limit_id|weekly_armed_limit_id|pending_observed_weekly_reset_limit_id)
          printf -v "$state_key" '%s' "$state_value"
          ;;
        script_tracking_initialized)
          [[ "$state_value" == 0 || "$state_value" == 1 ]] && script_tracking_initialized="$state_value"
          ;;
        attempted_script_5h_actions|attempted_script_weekly_actions|attempted_script_5h_reset_actions|attempted_script_weekly_reset_actions)
          [[ "$state_value" =~ ^([a-f0-9]{24},)*[a-f0-9]{0,24}$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        pending_script_5h_actions|pending_script_weekly_actions|pending_script_5h_reset_actions|pending_script_weekly_reset_actions|suppressed_script_5h_actions|suppressed_script_weekly_actions|suppressed_script_5h_reset_actions|suppressed_script_weekly_reset_actions)
          [[ "$state_value" =~ ^([a-f0-9]{24},)*[a-f0-9]{0,24}$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        pending_script_contexts|interrupted_script_contexts|interrupted_script_identities)
          [[ -z "$state_value" || "$state_value" =~ ^([a-f0-9]{24}:[A-Za-z0-9+/=]+,)*[a-f0-9]{24}:[A-Za-z0-9+/=]+$ ]] \
            && printf -v "$state_key" '%s' "$state_value"
          ;;
        interrupted_script_actions)
          [[ "$state_value" =~ ^([a-f0-9]{24},)*[a-f0-9]{0,24}$ ]] \
            && printf -v "$state_key" '%s' "$state_value"
          ;;
        script_5h_reset_attempted_at|script_weekly_reset_attempted_at)
          [[ "$state_value" =~ ^[0-9]+$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
      esac
    done < "$STATE_FILE"
  fi

  if (( state_version > 5 )); then
    echo "[ERROR] Unsupported future alert state version ${state_version}; alerts are disabled." >&2
    ALERT_PROCESSING_ERROR="unsupported future alert state version"
    return 1
  fi
  if (( state_version < 1 || state_version > 5 )); then
    echo "[ERROR] Unsupported alert state version ${state_version}." >&2
    ALERT_PROCESSING_ERROR="invalid alert state version"
    return 1
  fi
  if [[ "${ALERTS_ENABLED:-1}" == 0 ]]; then
    (( alerts_disabled_since > 0 )) || alerts_disabled_since="$scraped_at_epoch"
  elif (( alerts_disabled_since > 0 )); then
    resumed_after_disabled=1
  fi

  mapfile -t thresholds < <(load_thresholds)
  pace="$(weekly_pace_vs_ideal "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch")"
  pace_suffix=""
  [[ -n "$pace" ]] && pace_suffix=$'\n'"*Pace vs ideal:* ${pace}"
  if [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$weekly_reset_at" =~ ^[0-9]+$ ]]; then
    weekly_observation_valid=1
  fi
  if [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$five_h_reset_at" =~ ^[0-9]+$ ]] \
    && (( five_h_reset_at > 0 )); then
    five_h_observation_valid=1
  fi

  # Armed cycles are owner-scoped. Resolve restored arms before any delivery
  # journal initialization or migration can consume them. An absent owner is
  # not evidence that the arm belongs to this sample; only an explicit,
  # current owner is safe to preserve. Reset script markers with the arm so a
  # later cycle cannot replay actions from an interrupted group.
  if (( five_h_armed_reset_at > 0 )) \
    && [[ -z "$five_h_armed_limit_id" ]]; then
    if ! mark_interrupted_script_window 5h "" "$five_h_armed_reset_at"; then
      return 1
    fi
    [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]] \
      && local_observed_5h_reset_at=0
    five_h_armed_reset_at=0
    script_5h_reset_attempted_at=0
    clear_5h_reset_script_actions
    clear_5h_script_actions
  elif (( five_h_armed_reset_at > 0 )) \
    && [[ "$five_h_armed_limit_id" != "$limit_id" ]]; then
    interrupted_5h_owner="$five_h_armed_limit_id"
    interrupted_5h_reset_at="$five_h_armed_reset_at"
    if ! mark_interrupted_script_window 5h "$five_h_armed_limit_id" "$five_h_armed_reset_at"; then
      return 1
    fi
    [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]] \
      && local_observed_5h_reset_at=0
    five_h_armed_reset_at=0
    five_h_armed_limit_id=""
    script_5h_reset_attempted_at=0
    clear_5h_reset_script_actions
    clear_5h_script_actions
  fi
  if (( weekly_armed_reset_at > 0 )) \
    && [[ -z "$weekly_armed_limit_id" ]]; then
    if ! mark_interrupted_script_window weekly "" "$weekly_armed_reset_at"; then
      return 1
    fi
    [[ "$local_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
      && local_observed_weekly_reset_at=0
    weekly_armed_reset_at=0
    script_weekly_reset_attempted_at=0
    clear_weekly_reset_script_actions
    clear_weekly_script_actions
  elif (( weekly_armed_reset_at > 0 )) \
    && [[ "$weekly_armed_limit_id" != "$limit_id" ]]; then
    interrupted_weekly_owner="$weekly_armed_limit_id"
    interrupted_weekly_reset_at="$weekly_armed_reset_at"
    if ! mark_interrupted_script_window weekly "$weekly_armed_limit_id" "$weekly_armed_reset_at"; then
      return 1
    fi
    [[ "$local_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
      && local_observed_weekly_reset_at=0
    weekly_armed_reset_at=0
    weekly_armed_limit_id=""
    script_weekly_reset_attempted_at=0
    clear_weekly_reset_script_actions
    clear_weekly_script_actions
  fi

  # Detect this candidate before a missing delivery journal is reconstructed.
  # Otherwise migration can turn the very sample that proves a local observed
  # reset into a stale network reset (and threshold) occurrence.
  if (( five_h_observation_valid == 1 )) \
    && [[ -n "$observed_5h_limit_id" && "$limit_id" == "$observed_5h_limit_id" ]] \
    && is_observed_5h_reset "$observed_5h_pct" "$five_h_pct" \
      "$observed_5h_reset_at" "$five_h_reset_at"; then
    observed_5h_reset_candidate=1
    if (( five_h_armed_reset_at > 0 )) \
     && [[ "$five_h_armed_limit_id" == "$limit_id" ]]; then
      # A due, explicitly-owned arm owns this reset.  Observed evidence must
      # not silently convert it into a local-only event; expire only the stale
      # threshold rows and let the normal scheduled reset delivery proceed.
      if (( scraped_at_epoch >= five_h_armed_reset_at )) \
        && [[ "$local_observed_5h_reset_at" != "$five_h_armed_reset_at" ]]; then
        observed_5h_scheduled_due=1
        observed_5h_reset_candidate=0
      else
        # Only a not-yet-due arm is superseded by local observed evidence.
        observed_5h_superseded_reset_at="$five_h_armed_reset_at"
      fi
    else
      if (( local_observed_5h_reset_at > 0 )) \
        && [[ "$local_observed_5h_reset_at" == "$observed_5h_reset_at" ]]; then
        # The arm was retired after its hook completed, but the old observed
        # baseline is still on disk because the recovery poll had no deadline.
        # Reuse its tombstone instead of treating the next complete sample as
        # a second reset.
        observed_5h_reset_candidate=0
        observed_5h_reset_recovery=1
        observed_5h_superseded_reset_at="$local_observed_5h_reset_at"
      else
        # No trustworthy arm identifies the consumed cycle.  The observed
        # baseline deadline is the only durable pre-reset anchor available; the
        # transaction below will close that owner cycle before any journal
        # reconstruction or delivery can occur.
        observed_5h_initial_no_arm=1
      fi
    fi
  fi
  # Establish the local-only write-ahead intent before touching the delivery
  # journal.  This is deliberately the first durable action after an observed
  # candidate is classified (scheduled-due candidates were excluded above):
  # a crash cannot leave an observed reset looking like a scheduled reset while
  # journal initialization/migration is still in progress.  The synthetic arm
  # supplies a durable hook anchor when the restored state had no arm.
  if (( observed_5h_reset_candidate == 1 )); then
    if (( observed_5h_initial_no_arm == 1 )); then
      five_h_armed_reset_at="$scraped_at_epoch"
      five_h_armed_limit_id="$limit_id"
      last_notified_5h_reset_at="$scraped_at_epoch"
      local_observed_5h_reset_at="$scraped_at_epoch"
      observed_5h_local_tombstone=1
      observed_5h_reset=1
      transaction_epoch=0
      if ! persist_observed_5h_intent "$scraped_at_epoch"; then
        ALERT_PROCESSING_ERROR="local reset intent persistence failed"
        return 1
      fi
    else
      observed_5h_superseded_reset_at="$five_h_armed_reset_at"
      transaction_epoch="$observed_5h_superseded_reset_at"
      if ! persist_observed_5h_intent "$observed_5h_superseded_reset_at"; then
        ALERT_PROCESSING_ERROR="local reset intent persistence failed"
        return 1
      fi
    fi
  fi
  # The due path must perform the owner-scoped threshold expiry on every poll,
  # not only when this sample still proves an observed refill.  A changed or
  # partial retry after an expiry failure must not deliver the stale threshold
  # before the scheduled reset itself.  A durable local marker remains the
  # exception and is resolved below from the local-observed journal row.
  if (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" \
          && "$local_observed_5h_reset_at" != "$five_h_armed_reset_at" ]]; then
    observed_5h_scheduled_due=1
    observed_5h_reset_candidate=0
    observed_5h_superseded_reset_at=0
  fi
  # A durable local-observed intent is also evidence after a crash that
  # interrupted the full sample before its final state write.  Re-run the
  # atomic journal operation on every same-owner sample before any due or
  # threshold processing; a complete sample may continue through the normal
  # detector after the superseded cycle is closed, while a partial sample is
  # held at its baseline.
  if (( local_observed_5h_reset_at > 0 )) \
    && [[ "$observed_5h_limit_id" == "$limit_id" ]] \
    && ( (( five_h_armed_reset_at == 0 )) \
         || { (( five_h_armed_reset_at > 0 )) \
              && [[ "$five_h_armed_limit_id" == "$limit_id" \
                    && "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]]; } ); then
    observed_5h_reset_recovery=1
    observed_5h_superseded_reset_at="$local_observed_5h_reset_at"
    (( five_h_observation_valid == 0 )) && process_5h_sample=0
  fi
  # A weekly observed reset that was enabled with a configured network channel
  # gets a write-ahead identity before the delivery journal is touched.  It is
  # the recovery source if the journal write or the following state write is
  # interrupted; unlike the local marker below, it is allowed to create the
  # missing network occurrence with the original immutable cycle key.
  if (( pending_observed_weekly_reset_at > 0 )); then
    if [[ "$pending_observed_weekly_reset_limit_id" == "$limit_id" ]]; then
      observed_weekly_reset_recovery=1
      weekly_armed_reset_at="$pending_observed_weekly_reset_at"
      weekly_armed_limit_id="$limit_id"
      observed_weekly_reset=1
      (( weekly_observation_valid == 0 )) && process_weekly_sample=0
    else
      # A pending intent belongs to its recorded owner.  Never attach it to a
      # different limit group after an owner switch; the journal reconciliation
      # below handles any already-created occurrence independently.
      pending_observed_weekly_reset_at=0
      pending_observed_weekly_reset_limit_id=""
    fi
  elif (( local_observed_weekly_reset_at > 0 )) \
    && [[ "$observed_weekly_limit_id" == "$limit_id" ]]; then
    # A local marker without a matching network occurrence is an explicit
    # suppression (not an invitation to reconstruct a reset after a pause).
    # Only a corresponding non-local journal row may be recovered here.
    weekly_cycle_key="limit:${limit_id}|reset:${local_observed_weekly_reset_at}"
    if journal_has_network_reset_occurrence weekly "$weekly_cycle_key" "$limit_id" \
      "$local_observed_weekly_reset_at"; then
      observed_weekly_reset_recovery=1
      if (( weekly_armed_reset_at == 0 )); then
        weekly_armed_reset_at="$local_observed_weekly_reset_at"
        weekly_armed_limit_id="$limit_id"
      fi
      observed_weekly_reset=1
      (( weekly_observation_valid == 0 )) && process_weekly_sample=0
    else
      [[ "$weekly_armed_reset_at" == "$local_observed_weekly_reset_at" ]] \
        && { weekly_armed_reset_at=0; weekly_armed_limit_id=""; }
      local_observed_weekly_reset_at=0
    fi
  fi
  # As with 5h, a due same-owner weekly arm must expire stale thresholds on
  # every poll before the scheduled reset can be delivered.  This is kept
  # separate from observed weekly reset detection so a changed/partial retry
  # cannot bypass the owner-scoped expiry transaction.
  if (( weekly_armed_reset_at > 0 && scraped_at_epoch >= weekly_armed_reset_at )) \
    && [[ "$weekly_armed_limit_id" == "$limit_id" ]]; then
    observed_weekly_scheduled_due=1
  fi
  # Terminal events from a different owner are deferred for partial samples.
  # A complete sample that starts a new group may acknowledge those events,
  # but must never apply their remaining percentage or reset marker to the new
  # group's detector state.
  if (( five_h_observation_valid == 1 )) && [[ "$observed_5h_limit_id" != "$limit_id" ]]; then
    discard_other_group_terminal=1
  elif (( weekly_observation_valid == 1 )) && [[ "$observed_weekly_limit_id" != "$limit_id" ]]; then
    discard_other_group_terminal=1
  fi
  if [[ ! -e "$ALERT_DELIVERIES_FILE" ]]; then
    if ! initialize_alert_delivery_journal "$journal_source_state_version" "$scraped_at_epoch" "$limit_id" \
      "$five_h_pct" "$weekly_pct" "$five_h_reset" "$weekly_reset" "$observed_5h_reset_candidate" \
      "$observed_5h_limit_id" "$five_h_armed_limit_id" \
      "$observed_weekly_limit_id" "$weekly_armed_limit_id"; then
      ALERT_PROCESSING_ERROR="alert journal initialization failed"
      return 1
    fi
  elif ! python3 "$ALERTS_PY" migrate "$ALERT_DELIVERIES_FILE" --at "$scraped_at_epoch" \
    || ! python3 "$ALERTS_PY" validate "$ALERT_DELIVERIES_FILE"; then
    echo "[ERROR] Alert delivery journal is invalid; no notification was sent." >&2
    ALERT_PROCESSING_ERROR="invalid alert delivery journal"
    return 1
  fi

  # Close an observed 5-hour cycle immediately after the journal is known to
  # exist, before interruption reconciliation or any detector work can
  # persist.  A restored arm is authoritative when it is explicitly owned by
  # this sample; otherwise the observed baseline deadline is the conservative
  # pre-reset anchor.  In the no-arm case, install and persist a synthetic
  # local arm right after the write-ahead transaction so a later restart can
  # still execute the local hook exactly once without registering a network
  # reset.
  if (( observed_5h_reset_candidate == 1 )); then
    if ! expire_observed_owner_cycle 5h "$limit_id" "$scraped_at_epoch" \
      "$transaction_epoch"; then
      ALERT_PROCESSING_ERROR="local reset threshold transaction failed"
      return 1
    fi
    observed_5h_atomic_done=1
  fi

  # Write interruption tombstones before reconciliation or detector-state
  # writes. A synthetic reset row is required even when only a threshold was
  # pending: after a crash, returning to the interrupted owner must clear its
  # arm without creating a reset notification or hook.
  if (( interrupted_5h_reset_at > 0 )); then
    if ! interrupt_reset_cycle 5h "$interrupted_5h_owner" "$interrupted_5h_reset_at" "$scraped_at_epoch"; then
      ALERT_PROCESSING_ERROR="5h owner interruption failed"
      return 1
    fi
  fi
  if (( interrupted_weekly_reset_at > 0 )); then
    if ! interrupt_reset_cycle weekly "$interrupted_weekly_owner" "$interrupted_weekly_reset_at" "$scraped_at_epoch"; then
      ALERT_PROCESSING_ERROR="weekly owner interruption failed"
      return 1
    fi
  fi

  # An interruption tombstone is authoritative even before its reset epoch is
  # due.  A process can crash after writing the tombstone but before clearing
  # its in-memory arm; clear the restored arm now so a low sample cannot attach
  # a new threshold or hook to the interrupted cycle.
  if (( five_h_armed_reset_at > 0 )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]] \
    && journal_has_owner_interrupted_reset 5h \
      "limit:${limit_id}|reset:${five_h_armed_reset_at}" "$limit_id"; then
    observed_5h_scheduled_due=0
    [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]] \
      && local_observed_5h_reset_at=0
    five_h_armed_reset_at=0
    five_h_armed_limit_id=""
    due_5h_reset_at=0
    notified_5h_thresholds=""
    pending_5h_threshold=""
    prev_5h_pct=100
    script_5h_reset_attempted_at=0
    clear_5h_reset_script_actions
    clear_5h_script_actions
    script_prev_5h_pct=100
  fi
  if (( weekly_armed_reset_at > 0 )) \
    && [[ "$weekly_armed_limit_id" == "$limit_id" ]] \
    && journal_has_owner_interrupted_reset weekly \
      "limit:${limit_id}|reset:${weekly_armed_reset_at}" "$limit_id"; then
    observed_weekly_scheduled_due=0
    weekly_armed_reset_at=0
    weekly_armed_limit_id=""
    due_weekly_reset_at=0
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    prev_weekly_pct=100
    script_weekly_reset_attempted_at=0
    clear_weekly_reset_script_actions
    clear_weekly_script_actions
    script_prev_weekly_pct=100
  fi

  # The journal tombstone is the durable source of truth if the process died
  # after the observed-reset transaction but before the state intent/final
  # state write.  Consult it on every same-owner sample (not only when the
  # arm is due) so a changed full sample cannot reuse the old scheduled cycle.
  if (( five_h_armed_reset_at > 0 )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]] \
    && journal_has_local_observed_reset 5h \
      "limit:${limit_id}|reset:${five_h_armed_reset_at}" "$limit_id"; then
    observed_5h_scheduled_due=0
    observed_5h_local_tombstone=1
    observed_5h_reset_recovery=1
    observed_5h_superseded_reset_at="$five_h_armed_reset_at"
    observed_5h_reset=1
    (( five_h_observation_valid == 0 )) && process_5h_sample=0
  fi

  # Expire thresholds and write the local-observed tombstone in one journal
  # atomic write before any state intent write.  This ordering means a state
  # persistence failure cannot leave a stale pending threshold deliverable on
  # the next changed sample. With no arm, reset_epoch=0 still expires the
  # owner-scoped thresholds and old reset rows without fabricating a reset
  # occurrence when no trustworthy arm exists.
  if (( observed_5h_reset_candidate == 1 || observed_5h_reset_recovery == 1 )); then
    if ! expire_observed_owner_cycle 5h "$limit_id" "$scraped_at_epoch" \
      "${observed_5h_superseded_reset_at:-0}"; then
      # The two durable stores are independent.  If the journal write failed,
      # leave a state recovery intent behind so a later changed sample retries
      # before delivery; if this complementary write also fails, fail closed
      # with no detector or delivery advancement.
      if (( observed_5h_superseded_reset_at == 0 )); then
        if (( five_h_armed_reset_at > 0 )); then
          observed_5h_superseded_reset_at="$five_h_armed_reset_at"
        else
          observed_5h_superseded_reset_at="$observed_5h_reset_at"
        fi
      fi
      if (( observed_5h_superseded_reset_at > 0 )); then
        persist_observed_5h_intent "$observed_5h_superseded_reset_at" || :
      fi
      ALERT_PROCESSING_ERROR="local reset threshold transaction failed"
      return 1
    fi
    observed_5h_atomic_done=1
    # A baseline-only intent has no arm from which a local hook can be
    # scheduled.  Once its owner-scoped transaction is durable, retire that
    # recovery marker in the same final state write; an armed cycle keeps the
    # marker until its local hook opportunity is reconciled.
    if (( five_h_armed_reset_at == 0 )); then
      local_observed_5h_reset_at=0
    fi
  fi

  # A due same-owner arm has priority over a newly observed refill.  The
  # threshold rows are still stale and must be expired before delivery, but no
  # local-observed tombstone is written: the scheduled reset remains a normal
  # network event.  This also keeps missing-journal reconstruction eligible to
  # recreate the durable reset occurrence from its persisted arm.
  if (( observed_5h_scheduled_due == 1 )) \
    && [[ "${ALERTS_ENABLED:-1}" == 1 ]]; then
    if ! expire_owner_thresholds_and_suppress_reset 5h "$limit_id" 0 \
      "$scraped_at_epoch"; then
      ALERT_PROCESSING_ERROR="scheduled reset threshold expiration failed"
      return 1
    fi
    observed_5h_atomic_done=1
  fi

  if (( observed_weekly_scheduled_due == 1 )) \
    && [[ "${ALERTS_ENABLED:-1}" == 1 ]]; then
    if ! expire_owner_thresholds_and_suppress_reset weekly "$limit_id" 0 \
      "$scraped_at_epoch"; then
      ALERT_PROCESSING_ERROR="scheduled weekly reset threshold expiration failed"
      return 1
    fi
  fi

  # Persist the old arm as a local-only intent after the journal write-ahead
  # transaction.  If this state write fails, the already durable terminal
  # journal row still prevents stale delivery; a later poll can recover the
  # local hook from that row and the restored arm.
  if (( observed_5h_scheduled_due == 0 \
        && observed_5h_superseded_reset_at > 0 \
        && five_h_armed_reset_at == observed_5h_superseded_reset_at )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]] \
    && { [[ "$last_notified_5h_reset_at" != "$observed_5h_superseded_reset_at" ]] \
         || [[ "$local_observed_5h_reset_at" != "$observed_5h_superseded_reset_at" ]]; }; then
    if ! persist_observed_5h_intent "$observed_5h_superseded_reset_at"; then
      ALERT_PROCESSING_ERROR="local reset intent persistence failed"
      return 1
    fi
  fi
  # On restart after the write-ahead tombstone, an old arm may now be due on
  # disk. Treat the durable local marker as evidence that the due arm is still
  # the observed reset, so its local hook can run without a network reset.
  if (( observed_5h_reset_candidate == 1 && five_h_armed_reset_at > 0 )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]] \
    && (( scraped_at_epoch >= five_h_armed_reset_at )); then
    if journal_has_local_observed_reset 5h \
      "limit:${limit_id}|reset:${five_h_armed_reset_at}" "$limit_id"; then
      observed_5h_local_tombstone=1
    fi
  fi

  if ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" "$discard_other_group_terminal"; then
    ALERT_PROCESSING_ERROR="alert reconciliation failed"
    return 1
  fi
  if [[ "${ALERTS_ENABLED:-1}" == 1 && "$resumed_after_disabled" == 0 ]]; then
    if ! python3 "$ALERTS_PY" expire "$ALERT_DELIVERIES_FILE" --now "$scraped_at_epoch" \
      || ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" "$discard_other_group_terminal"; then
      ALERT_PROCESSING_ERROR="alert expiration failed"
      return 1
    fi
  fi

  # The state file may have lost its owner fields while the delivery journal
  # still contains pending events.  Interrupt every threshold/reset owner
  # other than this current sample's owner before any detector mutation or due
  # delivery; this is one atomic journal operation and is safe to repeat.
  if ! interrupt_pending_other_owners "$limit_id" "$scraped_at_epoch" \
    || ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" 1; then
    ALERT_PROCESSING_ERROR="alert owner interruption failed"
    return 1
  fi

  # Full cycles have already processed this row while archiving; live cycles
  # use the same idempotent detector command without adding a snapshot row.
  if ! journal_quota_anomalies "$scraped_at_epoch"; then
    status=1
    ALERT_PROCESSING_ERROR="quota anomaly journal registration failed"
  fi

  if (( ${#ALERT_SCRIPT_RULE_INDICES[@]} == 0 )); then
    script_tracking_initialized=0
    clear_5h_script_actions
    clear_weekly_script_actions
    clear_5h_reset_script_actions
    clear_weekly_reset_script_actions
  elif (( script_tracking_initialized == 0 )); then
    initialize_script_baseline=1
    [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_5h_pct="$five_h_pct"
    [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_weekly_pct="$weekly_pct"
    script_tracking_initialized=1
  fi

  # Alert state belongs to one coherent limit group. A complete observation of
  # another group starts a fresh baseline instead of crossing group boundaries.
  if (( state_loaded == 1 )) && [[ -z "$observed_weekly_limit_id" ]]; then
    if (( weekly_observation_valid == 1 )); then
      if ! mark_interrupted_script_window weekly "$weekly_armed_limit_id" "$weekly_armed_reset_at"; then
        return 1
      fi
      prev_weekly_pct="$weekly_pct"
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
      script_prev_weekly_pct="$weekly_pct"
      clear_weekly_script_actions
      observed_weekly_pct="$weekly_pct"
      observed_weekly_reset_at="$weekly_reset_at"
      observed_weekly_limit_id="$limit_id"
      local_observed_weekly_reset_at=0
      clear_weekly_reset_script_actions
    else
      process_weekly_sample=0
    fi
  elif (( weekly_observation_valid == 1 )) \
    && [[ -n "$observed_weekly_limit_id" && "$limit_id" != "$observed_weekly_limit_id" ]]; then
    if ! mark_interrupted_script_window weekly "$observed_weekly_limit_id" "$weekly_armed_reset_at"; then
      return 1
    fi
    prev_weekly_pct="$weekly_pct"
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    script_prev_weekly_pct="$weekly_pct"
    clear_weekly_script_actions
    observed_weekly_pct="$weekly_pct"
    observed_weekly_reset_at="$weekly_reset_at"
    observed_weekly_limit_id="$limit_id"
    local_observed_weekly_reset_at=0
    if [[ "$weekly_armed_limit_id" != "$limit_id" ]]; then
      weekly_armed_reset_at=0
      weekly_armed_limit_id=""
      script_weekly_reset_attempted_at=0
      clear_weekly_reset_script_actions
    fi
  elif [[ -n "$observed_weekly_limit_id" && "$limit_id" != "$observed_weekly_limit_id" ]]; then
    # A partial row from another owner breaks continuity just as a complete
    # group switch does.  Keeping the old baseline would let a later return
    # to that owner look like a reset and cross its scheduled detector state.
    if ! mark_interrupted_script_window weekly "$observed_weekly_limit_id" "$weekly_armed_reset_at"; then
      return 1
    fi
    process_weekly_sample=0
    observed_weekly_pct=""
    observed_weekly_reset_at=0
    observed_weekly_limit_id=""
    local_observed_weekly_reset_at=0
    weekly_armed_reset_at=0
    weekly_armed_limit_id=""
    prev_weekly_pct=100
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    script_prev_weekly_pct=100
    clear_weekly_script_actions
    script_weekly_reset_attempted_at=0
    clear_weekly_reset_script_actions
  fi
  # Keep a durable complete 5-hour observation so a refill that leaves the
  # quota at 100% can still be recognized. A missing deadline, a first
  # observation, or a different limit group only establishes a new baseline;
  # none of those situations is evidence of a reset.
  if (( five_h_observation_valid == 1 )); then
    if [[ -z "$observed_5h_limit_id" ]]; then
      observed_5h_pct="$five_h_pct"
      observed_5h_reset_at="$five_h_reset_at"
      observed_5h_limit_id="$limit_id"
      local_observed_5h_reset_at=0
      initialize_5h_baseline=1
      if (( state_loaded == 1 )); then
        # State from before the owner-aware format has no trustworthy 5h
        # baseline.  Establish this complete sample as the baseline without
        # crossing its old percentage or firing a hook for it.
        process_5h_sample=0
        prev_5h_pct="$five_h_pct"
        notified_5h_thresholds=""
        pending_5h_threshold=""
        script_prev_5h_pct="$five_h_pct"
        if ! mark_interrupted_script_window 5h "$five_h_armed_limit_id" "$five_h_armed_reset_at"; then
          return 1
        fi
        clear_5h_script_actions
        clear_5h_reset_script_actions
      fi
    elif [[ "$observed_5h_limit_id" != "$limit_id" ]]; then
      if ! mark_interrupted_script_window 5h "$observed_5h_limit_id" "$five_h_armed_reset_at"; then
        return 1
      fi
      observed_5h_pct="$five_h_pct"
      observed_5h_reset_at="$five_h_reset_at"
      observed_5h_limit_id="$limit_id"
      local_observed_5h_reset_at=0
      initialize_5h_baseline=1
      process_5h_sample=0
      # A complete sample from a new limit group is a fresh baseline.  Clear
      # all threshold/hook state that belonged to the previous owner before
      # the sample can reach either detector.
      prev_5h_pct="$five_h_pct"
      notified_5h_thresholds=""
      pending_5h_threshold=""
      script_prev_5h_pct="$five_h_pct"
      clear_5h_script_actions
      # A scheduled cycle belongs to its original group. Do not deliver it
      # while processing a complete observation from another group.
      if [[ "$five_h_armed_limit_id" != "$limit_id" ]]; then
        five_h_armed_reset_at=0
        five_h_armed_limit_id=""
        script_5h_reset_attempted_at=0
        clear_5h_reset_script_actions
      fi
    fi
  elif [[ -n "$observed_5h_limit_id" && "$limit_id" != "$observed_5h_limit_id" ]]; then
    # A partial row from another group has no reset deadline to establish a
    # coherent observation.  Break the old baseline so a later return to that
    # owner starts fresh rather than looking like a reset.  Clear all detector
    # state that could otherwise cross the interruption, while preserving the
    # same-owner partial-sample behavior above.
    if ! mark_interrupted_script_window 5h "$observed_5h_limit_id" "$five_h_armed_reset_at"; then
      return 1
    fi
    process_5h_sample=0
    observed_5h_pct=""
    observed_5h_reset_at=0
    observed_5h_limit_id=""
    local_observed_5h_reset_at=0
    five_h_armed_reset_at=0
    five_h_armed_limit_id=""
    prev_5h_pct=100
    notified_5h_thresholds=""
    pending_5h_threshold=""
    script_prev_5h_pct=100
    clear_5h_script_actions
    script_5h_reset_attempted_at=0
    clear_5h_reset_script_actions
  elif (( state_loaded == 1 )) && [[ -z "$observed_5h_limit_id" ]]; then
    # Legacy state has no complete owner-aware observation yet.  A partial row
    # cannot establish which group's baseline it belongs to, so defer all 5h
    # threshold and hook processing until a complete sample arrives.
    process_5h_sample=0
  elif (( state_loaded == 0 )) && [[ -z "$observed_5h_limit_id" \
        && "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
    # A brand-new detector may legitimately start from partial 5h samples. Bind
    # that threshold baseline to the sample's owner immediately so later
    # partial samples can be compared safely without looking like legacy state.
    observed_5h_limit_id="$limit_id"
  fi

  # A recovery marker is useful only while its weekly reset occurrence could
  # still be delivered.  If the marker survived a failed transaction but the
  # seven-day delivery window is already gone, do not rebuild an invalid
  # request (reset_epoch + 7d is before this poll).  With no journal row there
  # is nothing to retry; establish this sample as a fresh baseline and clear
  # the marker so later polls are not blocked forever.  Existing rows are left
  # for the normal expiration/reconciliation pass, which keeps their durable
  # retry/terminal history authoritative.
  if (( observed_weekly_reset_recovery == 1 && weekly_armed_reset_at > 0 \
        && scraped_at_epoch > weekly_armed_reset_at + 7 * 24 * 60 * 60 )); then
    weekly_cycle_key="limit:${limit_id}|reset:${weekly_armed_reset_at}"
    if ! journal_has_pending_alert reset weekly reset "$weekly_cycle_key" \
      && ! journal_has_terminal_alert reset weekly reset "$weekly_cycle_key"; then
      observed_weekly_reset_recovery=0
      observed_weekly_reset=0
      local_observed_weekly_reset_at=0
      weekly_armed_reset_at=0
      weekly_armed_limit_id=""
      due_weekly_reset_at=0
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
      script_weekly_reset_attempted_at=0
      clear_weekly_reset_script_actions
      clear_weekly_script_actions
      if (( weekly_observation_valid == 1 )); then
        process_weekly_sample=0
        prev_weekly_pct="$weekly_pct"
        script_prev_weekly_pct="$weekly_pct"
        observed_weekly_pct="$weekly_pct"
        observed_weekly_reset_at="$weekly_reset_at"
        observed_weekly_limit_id="$limit_id"
      else
        process_weekly_sample=0
        prev_weekly_pct=100
        script_prev_weekly_pct=100
        observed_weekly_pct=""
        observed_weekly_reset_at=0
        observed_weekly_limit_id=""
      fi
    fi
  fi

  # Codex can refill the weekly window before its previously announced
  # deadline. Match the archive's conservative detection rule so alerts and
  # reset history agree: require both a quota refill and a materially later
  # deadline. Anchor the event to this first post-reset observation because the
  # exact reset instant is unknown.
  if (( observed_weekly_reset_at > 0 )) \
    && [[ "$limit_id" == "$observed_weekly_limit_id" ]] \
    && (( observed_weekly_reset_recovery == 0 )) \
    && (( observed_weekly_scheduled_due == 0 )) \
    && is_random_weekly_reset "$observed_weekly_pct" "$weekly_pct" \
      "$observed_weekly_reset_at" "$weekly_reset_at"; then
    weekly_armed_reset_at="$scraped_at_epoch"
    weekly_armed_limit_id="$limit_id"
    observed_weekly_reset=1
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    prev_weekly_pct="$weekly_pct"
    observed_weekly_pct="$weekly_pct"
    observed_weekly_reset_at="$weekly_reset_at"
    observed_weekly_limit_id="$limit_id"
    if [[ "${ALERTS_ENABLED:-1}" == 1 ]] \
      && [[ "$(configured_alert_channels_json)" != "[]" ]]; then
      pending_observed_weekly_reset_at="$weekly_armed_reset_at"
      pending_observed_weekly_reset_limit_id="$limit_id"
      if ! persist_alert_state && ! persist_alert_state; then
        ALERT_PROCESSING_ERROR="weekly reset intent persistence failed"
        return 1
      fi
    fi
  fi

  # A random weekly refill is also reset evidence for the threshold detector.
  # The reset notification remains a legitimate network event, but every
  # pending threshold/reset for this owner/window belongs to the consumed
  # cycle and must be terminalized before the new reset or any due delivery.
  if (( observed_weekly_reset == 1 || observed_weekly_reset_recovery == 1 )); then
    weekly_cycle_key="limit:${limit_id}|reset:${weekly_armed_reset_at}"
    weekly_request_json='{}'
    weekly_network_request=0
    if [[ "${ALERTS_ENABLED:-1}" == 1 ]] \
      && [[ "$(configured_alert_channels_json)" != "[]" ]]; then
      weekly_network_request=1
      if ! weekly_request_json="$(network_reset_request_json weekly "$limit_id" \
          "$weekly_armed_reset_at" "$scraped_at_epoch")"; then
        ALERT_PROCESSING_ERROR="weekly reset request construction failed"
        return 1
      fi
    fi
    # Journal the old-cycle closure and the new weekly reset in one atomic
    # operation before persisting the detector intent.  If the state write
    # fails afterwards, the pending new reset and terminal old rows still give
    # the next poll a durable, owner-scoped recovery path.
    if (( weekly_atomic_done == 0 )) \
      && ! expire_observed_owner_cycle weekly "$limit_id" "$scraped_at_epoch" \
        0 "$weekly_cycle_key" "$weekly_request_json"; then
      # Keep a recovery marker when the journal transaction itself failed; this
      # lets a changed sample retry before any delivery.  If its complementary
      # state write fails too, return without advancing detector state.
      if (( weekly_armed_reset_at > 0 )) \
        && [[ "$local_observed_weekly_reset_at" != "$weekly_armed_reset_at" ]]; then
        previous_local_observed_weekly_reset_at="$local_observed_weekly_reset_at"
        local_observed_weekly_reset_at="$weekly_armed_reset_at"
        if ! persist_alert_state && ! persist_alert_state; then
          local_observed_weekly_reset_at="$previous_local_observed_weekly_reset_at"
          weekly_intent_succeeded=0
        fi
      fi
      ALERT_PROCESSING_ERROR="weekly threshold transaction failed"
      return 1
    fi
    weekly_atomic_done=1
    if (( weekly_network_request == 1 )) \
      && [[ "$pending_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
      && [[ "$pending_observed_weekly_reset_limit_id" == "$limit_id" ]]; then
      # The journal now owns the immutable network occurrence.  Clearing the
      # write-ahead identity is safe because the final state write below keeps
      # the observed marker and the journal can still suppress any duplicate.
      pending_observed_weekly_reset_at=0
      pending_observed_weekly_reset_limit_id=""
    fi
    # Persist the observed anchor only after the journal write-ahead row.  A
    # failure is still fail-closed; the journal already prevents stale replay.
    if (( weekly_armed_reset_at > 0 )) \
      && [[ "$local_observed_weekly_reset_at" != "$weekly_armed_reset_at" ]]; then
      previous_local_observed_weekly_reset_at="$local_observed_weekly_reset_at"
      local_observed_weekly_reset_at="$weekly_armed_reset_at"
      if ! persist_alert_state && ! persist_alert_state; then
        local_observed_weekly_reset_at="$previous_local_observed_weekly_reset_at"
        weekly_intent_succeeded=0
      fi
    fi
    if (( weekly_intent_succeeded == 0 )); then
      ALERT_PROCESSING_ERROR="weekly reset intent persistence failed"
      return 1
    fi
    if ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" "$discard_other_group_terminal"; then
      ALERT_PROCESSING_ERROR="weekly threshold reconciliation failed"
      return 1
    fi
    pending_weekly_threshold=""
    notified_weekly_thresholds=""
  fi

  # A complete 100% -> 100% observation with a later deadline is an observed
  # 5-hour reset. If an already armed scheduled cycle crossed in this sample,
  # let that normal path own the event so history and notifications cannot
  # double count the same reset.
  if (( initialize_5h_baseline == 0 && five_h_observation_valid == 1 )) \
    && [[ "$limit_id" == "$observed_5h_limit_id" ]] \
    && is_observed_5h_reset "$observed_5h_pct" "$five_h_pct" \
      "$observed_5h_reset_at" "$five_h_reset_at" \
    && ! ( (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at \
             && observed_5h_local_tombstone == 0 )) \
           && [[ "$five_h_armed_limit_id" == "$limit_id" ]] ); then
    five_h_armed_reset_at="$scraped_at_epoch"
    five_h_armed_limit_id="$limit_id"
    # Persist the local-only classification before expiration reconciliation
    # can persist detector state. A restart after that intermediate write must
    # not reinterpret this observed reset as a scheduled network reset; the
    # arm remains available for the one-shot local hook.
    last_notified_5h_reset_at="$five_h_armed_reset_at"
    local_observed_5h_reset_at="$five_h_armed_reset_at"
    observed_5h_reset=1
  fi

  # Observed 5h resets are local evidence: invalidate any stale threshold
  # occurrence first, but never register a network reset occurrence.  Keeping
  # this operation ahead of due delivery makes a journal failure fail closed.
  if (( observed_5h_reset == 1 )); then
    if (( observed_5h_atomic_done == 0 )) \
      && ! invalidate_pending_thresholds_for_owner 5h "$limit_id" "$scraped_at_epoch"; then
      ALERT_PROCESSING_ERROR="alert threshold invalidation failed"
      # Do not clear the observed arm or persist any detector advancement when
      # expiry/reconciliation fails.  The same observed proof must retry on the
      # next poll before any due delivery or local hook can run.
      return 1
    fi
    if ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" "$discard_other_group_terminal"; then
      ALERT_PROCESSING_ERROR="alert threshold reconciliation failed"
      return 1
    fi
    pending_5h_threshold=""
    notified_5h_thresholds=""
  fi

  # Reset delivery is retried while the reset still belongs to a plausible cycle.
  if (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]]; then
    cycle_key="limit:${limit_id}|reset:${five_h_armed_reset_at}"
    if journal_has_owner_interrupted_reset 5h "$cycle_key" "$limit_id"; then
      # An interrupted owner has a durable reset tombstone. Clear the
      # restored arm and script state without assigning a due reset or hook.
      [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]] \
        && local_observed_5h_reset_at=0
      five_h_armed_reset_at=0
      five_h_armed_limit_id=""
      due_5h_reset_at=0
      notified_5h_thresholds=""
      pending_5h_threshold=""
      prev_5h_pct=100
      script_5h_reset_attempted_at=0
      clear_5h_reset_script_actions
      clear_5h_script_actions
      script_prev_5h_pct=100
    else
    due_5h_reset_at="$five_h_armed_reset_at"
    reset_age=$(( scraped_at_epoch - five_h_armed_reset_at ))
    if (( reset_age <= 5 * 60 * 60 && last_notified_5h_reset_at != five_h_armed_reset_at )); then
      cycle_key="limit:${limit_id}|reset:${five_h_armed_reset_at}"
      if (( observed_5h_reset == 1 )); then
        # A full 5-hour window can be observed without any quota movement.
        # This is useful local reset evidence and still drives hooks, but it
        # must remain silent on the network and must not create a delivery
        # occurrence that could be replayed later.
        last_notified_5h_reset_at="$five_h_armed_reset_at"
      elif journal_has_pending_alert reset 5h reset "$cycle_key"; then
        if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
          # Keep the queued delivery intact, but advance local detector state
          # while notifications are disabled.  Re-enabling must not replay a
          # reset that was observed during the disabled interval.
          last_notified_5h_reset_at="$five_h_armed_reset_at"
        fi
      elif journal_has_terminal_alert reset 5h reset "$cycle_key"; then
        # The delivery journal is authoritative if detector state was restored
        # from an older copy after the terminal occurrence was acknowledged.
        last_notified_5h_reset_at="$five_h_armed_reset_at"
      elif register_network_alert reset 5h reset \
        "$cycle_key" \
        "*Codex 5h limit reset.* A new usage cycle is available." \
        "{\"limit_id\":\"${limit_id}\",\"reset_epoch\":${five_h_armed_reset_at}}" \
        "$five_h_armed_reset_at" "$((five_h_armed_reset_at + 5 * 60 * 60))" false \
        "$cycle_key"; then
        :
      elif [[ "$?" == 2 ]]; then
        last_notified_5h_reset_at="$five_h_armed_reset_at"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert journal registration failed"
      fi
    fi
    if (( reset_age > 5 * 60 * 60 )); then
      last_notified_5h_reset_at="$five_h_armed_reset_at"
    fi
    # Keep an observed local reset arm durable until its hook opportunity has
    # completed.  The detector-state write before hooks may be the last durable
    # write if the final persist fails; retaining the arm lets a restart derive
    # the pending local hook from the durable observation+tombstone without
    # ever registering a scheduled network reset.  Scheduled resets retain the
    # historical clear-on-ack behavior.
    if (( reset_age > 5 * 60 * 60 )) \
      || (( last_notified_5h_reset_at == five_h_armed_reset_at && observed_5h_reset == 0 )); then
      # Keep the arm until every configured reset hook is durably completed or
      # explicitly suppressed.  The arm is the recovery anchor for a crash or
      # failed intent write between network acknowledgement and hook launch.
      if ! has_unfinished_reset_script_actions 5h; then
        [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" ]] \
          && local_observed_5h_reset_at=0
        five_h_armed_reset_at=0
        five_h_armed_limit_id=""
        notified_5h_thresholds=""
        pending_5h_threshold=""
        prev_5h_pct=100
      fi
    fi
    if (( script_5h_reset_attempted_at != due_5h_reset_at )); then
      script_5h_reset_attempted_at="$due_5h_reset_at"
      clear_5h_reset_script_actions
      clear_5h_script_actions
      script_prev_5h_pct=100
    fi
  fi

    fi
  if (( weekly_armed_reset_at > 0 && scraped_at_epoch >= weekly_armed_reset_at )) \
    && [[ "$weekly_armed_limit_id" == "$limit_id" ]]; then
    cycle_key="limit:${limit_id}|reset:${weekly_armed_reset_at}"
    if journal_has_owner_interrupted_reset weekly "$cycle_key" "$limit_id"; then
      [[ "$local_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
        && local_observed_weekly_reset_at=0
      weekly_armed_reset_at=0
      weekly_armed_limit_id=""
      due_weekly_reset_at=0
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
      prev_weekly_pct=100
      script_weekly_reset_attempted_at=0
      clear_weekly_reset_script_actions
      clear_weekly_script_actions
      script_prev_weekly_pct=100
    else
    due_weekly_reset_at="$weekly_armed_reset_at"
    if (( observed_weekly_reset == 0 )); then
      if (( weekly_observation_valid == 1 )); then
        observed_weekly_pct="$weekly_pct"
        observed_weekly_reset_at="$weekly_reset_at"
      else
        observed_weekly_pct=""
        observed_weekly_reset_at=0
      fi
      observed_weekly_limit_id="$limit_id"
    fi
    reset_age=$(( scraped_at_epoch - weekly_armed_reset_at ))
    if (( reset_age <= 7 * 24 * 60 * 60 && last_notified_weekly_reset_at != weekly_armed_reset_at )); then
      cycle_key="limit:${limit_id}|reset:${weekly_armed_reset_at}"
      if journal_has_pending_alert reset weekly reset "$cycle_key"; then
        if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
          # See the 5-hour path: retain the old pending delivery, while
          # acknowledging its reset locally for detector-state purposes.
          last_notified_weekly_reset_at="$weekly_armed_reset_at"
        fi
      elif journal_has_terminal_alert reset weekly reset "$cycle_key"; then
        # Recover from detector/journal divergence without replaying a reset or
        # keeping its expired deadline attached to the next threshold cycle.
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
      elif register_network_alert reset weekly reset \
        "$cycle_key" \
        "*Codex weekly limit reset.* A new usage cycle is available." \
        "{\"limit_id\":\"${limit_id}\",\"reset_epoch\":${weekly_armed_reset_at}}" \
        "$weekly_armed_reset_at" "$((weekly_armed_reset_at + 7 * 24 * 60 * 60))" false \
        "$cycle_key"; then
        :
      elif [[ "$?" == 2 ]]; then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert journal registration failed"
      fi
    fi
    if (( reset_age > 7 * 24 * 60 * 60 )); then
      last_notified_weekly_reset_at="$weekly_armed_reset_at"
    fi
    if (( reset_age > 7 * 24 * 60 * 60 || last_notified_weekly_reset_at == weekly_armed_reset_at )); then
      if ! has_unfinished_reset_script_actions weekly; then
        [[ "$local_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
          && local_observed_weekly_reset_at=0
        weekly_armed_reset_at=0
        weekly_armed_limit_id=""
        notified_weekly_thresholds=""
        pending_weekly_threshold=""
        if (( observed_weekly_reset == 1 )); then
          prev_weekly_pct="$weekly_pct"
        else
          prev_weekly_pct=100
        fi
      fi
    fi
    if (( script_weekly_reset_attempted_at != due_weekly_reset_at )); then
      script_weekly_reset_attempted_at="$due_weekly_reset_at"
      clear_weekly_reset_script_actions
      clear_weekly_script_actions
      if (( observed_weekly_reset == 1 )); then
        script_prev_weekly_pct="$weekly_pct"
      else
        script_prev_weekly_pct=100
      fi
    fi
  fi

    fi
  # Ignore shifting reset estimates while a cycle is armed. Once it has reset,
  # arm the next plausible deadline only after some quota has been consumed.
  if (( five_h_armed_reset_at == 0 )) \
    && [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$five_h_reset_at" =~ ^[0-9]+$ ]] \
    && percentage_below_full "$five_h_pct" \
    && (( five_h_reset_at > scraped_at_epoch && five_h_reset_at <= scraped_at_epoch + 6 * 60 * 60 )); then
    five_h_armed_reset_at="$five_h_reset_at"
    five_h_armed_limit_id="$limit_id"
  fi

  if (( weekly_armed_reset_at == 0 )) \
    && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$weekly_reset_at" =~ ^[0-9]+$ ]] \
    && percentage_below_full "$weekly_pct" \
    && (( weekly_reset_at > scraped_at_epoch && weekly_reset_at <= scraped_at_epoch + 8 * 24 * 60 * 60 )); then
    weekly_armed_reset_at="$weekly_reset_at"
    weekly_armed_limit_id="$limit_id"
  fi

  # Suppressed observations still advance detector state.  This acknowledges
  # every threshold crossed during the pause without creating a journal entry;
  # any delivery that was already pending in the journal remains untouched.
  if [[ "${ALERTS_ENABLED:-1}" != 1 ]]; then
    if (( process_5h_sample == 1 )) \
      && [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      disabled_notified="${notified_5h_thresholds}"
      for t in "${thresholds[@]}"; do
        if python3 - "$prev_5h_pct" "$five_h_pct" "$t" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
        then
          csv_contains "$disabled_notified" "$t" \
            || disabled_notified="${disabled_notified:+${disabled_notified},}${t}"
        fi
      done
      notified_5h_thresholds="$disabled_notified"
      pending_5h_threshold=""
      prev_5h_pct="$five_h_pct"
    fi
    if (( process_weekly_sample == 1 )) \
      && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      disabled_notified="${notified_weekly_thresholds}"
      for t in "${thresholds[@]}"; do
        if python3 - "$prev_weekly_pct" "$weekly_pct" "$t" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
        then
          csv_contains "$disabled_notified" "$t" \
            || disabled_notified="${disabled_notified:+${disabled_notified},}${t}"
        fi
      done
      notified_weekly_thresholds="$disabled_notified"
      pending_weekly_threshold=""
      prev_weekly_pct="$weekly_pct"
    fi
  fi

  # The first observation uses 100% as its baseline. A multi-threshold drop emits
  # one alert for the most critical crossed threshold and marks all crossed levels.
  if (( process_5h_sample == 1 )) \
    && [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
    original_pending="$pending_5h_threshold"
    critical="$pending_5h_threshold"
    for t in "${thresholds[@]}"; do
      if python3 - "$five_h_pct" "$prev_5h_pct" "$t" "$notified_5h_thresholds" <<'PYEOF'
import sys
current, previous, threshold = map(float, sys.argv[1:4])
notified = {item for item in sys.argv[4].split(",") if item}
raise SystemExit(0 if current <= threshold < previous and str(int(threshold)) not in notified else 1)
PYEOF
      then
        [[ -z "$critical" || t -lt critical ]] && critical="$t"
      fi
    done
    if [[ -n "$critical" ]]; then
      pending_5h_threshold="$critical"
      cycle_key="limit:${limit_id}|${five_h_armed_reset_at:+reset:${five_h_armed_reset_at}}"
      [[ "$five_h_armed_reset_at" == 0 ]] && cycle_key="limit:${limit_id}|unarmed"
      if [[ "$critical" == "$original_pending" ]] \
        && journal_has_pending_selector threshold 5h "$critical"; then
        : # The detector marker still has a durable occurrence to reconcile.
      elif [[ "$critical" == "$original_pending" && "$due_5h_reset_at" != 0 ]]; then
        : # The due reset will expire and reconcile this threshold occurrence.
      elif journal_has_pending_alert threshold 5h "$critical" "$cycle_key"; then
        : # The immutable occurrence is already in the delivery journal.
      else
        # A pending detector marker without a matching journal occurrence can
        # remain after a registration failure followed by a script-state write.
        # Recreate the durable occurrence instead of suppressing it forever.
        covered_json="$(python3 - "$prev_5h_pct" "$critical" "${thresholds[@]}" <<'PYEOF'
import json
import sys
previous, critical = map(float, sys.argv[1:3])
print(json.dumps([int(value) for value in sys.argv[3:] if critical <= float(value) < previous]))
PYEOF
)"
        registration_status=0
        register_network_alert threshold 5h "$critical" "$cycle_key" \
          "*Codex 5h limit at ${five_h_pct}% remaining* (crossed ${critical}% threshold). Resets at ${five_h_reset}${pace_suffix}" \
          "{\"limit_id\":\"${limit_id}\",\"remaining_pct\":${five_h_pct},\"reset_epoch\":${five_h_armed_reset_at},\"covered_thresholds\":${covered_json}}" \
          "$scraped_at_epoch" "$five_h_armed_reset_at" true || registration_status=$?
        if (( registration_status == 2 )); then
          local notified="${notified_5h_thresholds}"
          for t in "${thresholds[@]}"; do
            if python3 - "$prev_5h_pct" "$critical" "$t" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
            then
              [[ ",${notified}," == *",${t},"* ]] || notified="${notified:+${notified},}${t}"
            fi
          done
          notified_5h_thresholds="$notified"
          pending_5h_threshold=""
          prev_5h_pct="$five_h_pct"
        elif (( registration_status != 0 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert journal registration failed"
        fi
      fi
    else
      prev_5h_pct="$five_h_pct"
    fi
  fi

  if (( process_weekly_sample == 1 )) && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
    original_pending="$pending_weekly_threshold"
    critical="$pending_weekly_threshold"
    for t in "${thresholds[@]}"; do
      if python3 - "$weekly_pct" "$prev_weekly_pct" "$t" "$notified_weekly_thresholds" <<'PYEOF'
import sys
current, previous, threshold = map(float, sys.argv[1:4])
notified = {item for item in sys.argv[4].split(",") if item}
raise SystemExit(0 if current <= threshold < previous and str(int(threshold)) not in notified else 1)
PYEOF
      then
        [[ -z "$critical" || t -lt critical ]] && critical="$t"
      fi
    done
    if [[ -n "$critical" ]]; then
      pending_weekly_threshold="$critical"
      cycle_key="limit:${limit_id}|${weekly_armed_reset_at:+reset:${weekly_armed_reset_at}}"
      [[ "$weekly_armed_reset_at" == 0 ]] && cycle_key="limit:${limit_id}|unarmed"
      if [[ "$critical" == "$original_pending" ]] \
        && journal_has_pending_selector threshold weekly "$critical"; then
        : # The detector marker still has a durable occurrence to reconcile.
      elif [[ "$critical" == "$original_pending" && "$due_weekly_reset_at" != 0 ]]; then
        : # The due reset will expire and reconcile this threshold occurrence.
      elif journal_has_pending_alert threshold weekly "$critical" "$cycle_key"; then
        :
      else
        # See the 5h path above: detector state alone is not proof that the
        # immutable network occurrence was successfully published.
        covered_json="$(python3 - "$prev_weekly_pct" "$critical" "${thresholds[@]}" <<'PYEOF'
import json
import sys
previous, critical = map(float, sys.argv[1:3])
print(json.dumps([int(value) for value in sys.argv[3:] if critical <= float(value) < previous]))
PYEOF
)"
        registration_status=0
        register_network_alert threshold weekly "$critical" "$cycle_key" \
          "*Codex weekly limit at ${weekly_pct}% remaining* (crossed ${critical}% threshold). Resets ${weekly_reset}${pace_suffix}" \
          "{\"limit_id\":\"${limit_id}\",\"remaining_pct\":${weekly_pct},\"reset_epoch\":${weekly_armed_reset_at},\"covered_thresholds\":${covered_json}}" \
          "$scraped_at_epoch" "$weekly_armed_reset_at" true || registration_status=$?
        if (( registration_status == 2 )); then
          local notified="${notified_weekly_thresholds}"
          for t in "${thresholds[@]}"; do
            if python3 - "$prev_weekly_pct" "$critical" "$t" <<'PYEOF'
import sys
raise SystemExit(0 if float(sys.argv[2]) <= float(sys.argv[3]) < float(sys.argv[1]) else 1)
PYEOF
            then
              [[ ",${notified}," == *",${t},"* ]] || notified="${notified:+${notified},}${t}"
            fi
          done
          notified_weekly_thresholds="$notified"
          pending_weekly_threshold=""
          prev_weekly_pct="$weekly_pct"
        elif (( registration_status != 0 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert journal registration failed"
        fi
      fi
    else
      prev_weekly_pct="$weekly_pct"
    fi
  fi

  # Journal a complete observation before any hook can persist or act on this
  # cycle. Notification retry state remains independent in prev_weekly_pct.
  if (( five_h_observation_valid == 1 )); then
    observed_5h_pct="$five_h_pct"
    observed_5h_reset_at="$five_h_reset_at"
    observed_5h_limit_id="$limit_id"
  fi
  if (( weekly_observation_valid == 1 )); then
    observed_weekly_pct="$weekly_pct"
    observed_weekly_reset_at="$weekly_reset_at"
    observed_weekly_limit_id="$limit_id"
  fi

  # Network occurrences are durable before this point. Delivery is independent
  # per channel and every attempt is persisted before the next channel starts.
  NETWORK_DELIVERY_ERROR=0
  if (( status == 0 )); then
    if ! persist_alert_state; then
      NETWORK_DELIVERY_ERROR=1
      ALERT_PROCESSING_ERROR="alert state persistence failed"
    else
      (( resumed_after_disabled == 1 )) && resume_delivery_attempted=1
      if ! deliver_due_alerts "$scraped_at_epoch"; then
        NETWORK_DELIVERY_ERROR=1
      fi
      if ! reconcile_alert_deliveries "$scraped_at_epoch" "$limit_id" "$discard_other_group_terminal"; then
        NETWORK_DELIVERY_ERROR=1
        ALERT_PROCESSING_ERROR="alert reconciliation failed"
      fi
    fi
  fi
  if (( NETWORK_DELIVERY_ERROR != 0 )); then
    status=1
    [[ -n "$ALERT_PROCESSING_ERROR" ]] || ALERT_PROCESSING_ERROR="alert delivery pending"
  fi

  # Notifications above are always attempted before local scripts. Script actions
  # have their own journal and never inherit transport retry semantics.
  if (( ${#ALERT_SCRIPT_RULE_INDICES[@]} > 0 )); then
    # Pending hook intents carry their complete invocation context.  Re-enumerate
    # them before consulting detector due state, because an observed reset may
    # have acknowledged and cleared its arm before the process crashed.
    if ! resume_pending_alert_scripts; then
      script_state_error=1
      status=1
    fi
    # A reset can be detected during the activation sample. Preserve the sample
    # itself as the baseline so already-consumed quota is not replayed later.
    if (( initialize_script_baseline == 1 )); then
      [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_5h_pct="$five_h_pct"
      [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_weekly_pct="$weekly_pct"
    fi
    if (( script_state_error == 0 && due_5h_reset_at > 0 )); then
      for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
        if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "5h:reset" ]]; then
          attempt_alert_script "$rule_position" attempted_script_5h_reset_actions \
            pending_script_5h_reset_actions suppressed_script_5h_reset_actions \
            reset 5h "" "$five_h_pct" "$due_5h_reset_at" "$five_h_reset" "$scraped_at_epoch" \
            "Codex 5h limit reset. A new usage cycle is available." \
            || { script_state_error=1; status=1; [[ -n "$ALERT_PROCESSING_ERROR" ]] \
              || ALERT_PROCESSING_ERROR="alert script action failed; pending retry"; break; }
          if (( SCRIPT_HOOK_FAILED == 1 )); then
            script_hook_error=1
          fi
        fi
      done
    fi
    if (( script_state_error == 0 && due_weekly_reset_at > 0 )); then
      for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
        if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "weekly:reset" ]]; then
          attempt_alert_script "$rule_position" attempted_script_weekly_reset_actions \
            pending_script_weekly_reset_actions suppressed_script_weekly_reset_actions \
            reset weekly "" "$weekly_pct" "$due_weekly_reset_at" "$weekly_reset" "$scraped_at_epoch" \
            "Codex weekly limit reset. A new usage cycle is available." \
            || { script_state_error=1; status=1; [[ -n "$ALERT_PROCESSING_ERROR" ]] \
              || ALERT_PROCESSING_ERROR="alert script action failed; pending retry"; break; }
          if (( SCRIPT_HOOK_FAILED == 1 )); then
            script_hook_error=1
          fi
        fi
      done
    fi

    if (( script_state_error == 0 && initialize_script_baseline == 0 \
          && initialize_5h_baseline == 0 && process_5h_sample == 1 )) \
      && [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      mapfile -t script_thresholds < <(
        printf '%s\n' "${ALERT_SCRIPT_RULE_EVENTS[@]}" \
          | awk -F: '$1 == "5h" && $2 ~ /^[0-9]+$/ {print $2}' \
          | sort -nr -u
      )
      for script_threshold in "${script_thresholds[@]}"; do
        if python3 - "$five_h_pct" "$script_prev_5h_pct" "$script_threshold" <<'PYEOF'
import sys
current, previous, threshold = map(float, sys.argv[1:])
raise SystemExit(0 if current <= threshold < previous else 1)
PYEOF
        then
          for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
            if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "5h:${script_threshold}" ]]; then
              attempt_alert_script "$rule_position" attempted_script_5h_actions \
                pending_script_5h_actions suppressed_script_5h_actions \
                threshold 5h "$script_threshold" "$five_h_pct" "$five_h_reset_at" "$five_h_reset" "$scraped_at_epoch" \
                "Codex 5h limit at ${five_h_pct}% remaining (crossed ${script_threshold}% threshold)." \
                || { script_state_error=1; status=1; [[ -n "$ALERT_PROCESSING_ERROR" ]] \
                  || ALERT_PROCESSING_ERROR="alert script action failed; pending retry"; break 2; }
              if (( SCRIPT_HOOK_FAILED == 1 )); then
                script_hook_error=1
              fi
            fi
          done
        fi
      done
      (( script_state_error == 0 && script_hook_error == 0 )) && script_prev_5h_pct="$five_h_pct"
    fi

    if (( script_state_error == 0 && initialize_script_baseline == 0 && process_weekly_sample == 1 )) \
      && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      mapfile -t script_thresholds < <(
        printf '%s\n' "${ALERT_SCRIPT_RULE_EVENTS[@]}" \
          | awk -F: '$1 == "weekly" && $2 ~ /^[0-9]+$/ {print $2}' \
          | sort -nr -u
      )
      for script_threshold in "${script_thresholds[@]}"; do
        if python3 - "$weekly_pct" "$script_prev_weekly_pct" "$script_threshold" <<'PYEOF'
import sys
current, previous, threshold = map(float, sys.argv[1:])
raise SystemExit(0 if current <= threshold < previous else 1)
PYEOF
        then
          for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
            if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "weekly:${script_threshold}" ]]; then
              attempt_alert_script "$rule_position" attempted_script_weekly_actions \
                pending_script_weekly_actions suppressed_script_weekly_actions \
                threshold weekly "$script_threshold" "$weekly_pct" "$weekly_reset_at" "$weekly_reset" "$scraped_at_epoch" \
                "Codex weekly limit at ${weekly_pct}% remaining (crossed ${script_threshold}% threshold)." \
                || { script_state_error=1; status=1; [[ -n "$ALERT_PROCESSING_ERROR" ]] \
                  || ALERT_PROCESSING_ERROR="alert script action failed; pending retry"; break 2; }
              if (( SCRIPT_HOOK_FAILED == 1 )); then
                script_hook_error=1
              fi
            fi
          done
        fi
      done
      (( script_state_error == 0 && script_hook_error == 0 )) && script_prev_weekly_pct="$weekly_pct"
    fi
  fi

  # A reset arm is deliberately retained through the pre-hook state write so a
  # crash cannot lose the hook opportunity.  Once all matching hooks are
  # durably completed (or suppressed while disabled), retire that recovery
  # anchor in this same cycle instead of waiting for a later poll.
  if (( five_h_armed_reset_at > 0 && due_5h_reset_at == five_h_armed_reset_at )) \
    && [[ "$five_h_armed_limit_id" == "$limit_id" ]] \
    && (( last_notified_5h_reset_at == five_h_armed_reset_at )) \
    && ! has_unfinished_reset_script_actions 5h; then
    # Keep an old observed baseline marker until a complete post-recovery
    # sample replaces it; otherwise a missing-deadline retry followed by the
    # next full sample could manufacture a second local tombstone.  A synthetic
    # no-arm marker is not such a baseline and can be retired immediately.
    if [[ "$local_observed_5h_reset_at" == "$five_h_armed_reset_at" \
          && "$observed_5h_reset_at" != "$five_h_armed_reset_at" ]]; then
      local_observed_5h_reset_at=0
    fi
    five_h_armed_reset_at=0
    five_h_armed_limit_id=""
    notified_5h_thresholds=""
    pending_5h_threshold=""
    prev_5h_pct=100
  fi
  if (( weekly_armed_reset_at > 0 && due_weekly_reset_at == weekly_armed_reset_at )) \
    && [[ "$weekly_armed_limit_id" == "$limit_id" ]] \
    && (( last_notified_weekly_reset_at == weekly_armed_reset_at )) \
    && ! has_unfinished_reset_script_actions weekly; then
    [[ "$local_observed_weekly_reset_at" == "$weekly_armed_reset_at" ]] \
      && local_observed_weekly_reset_at=0
    weekly_armed_reset_at=0
    weekly_armed_limit_id=""
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    if (( observed_weekly_reset == 1 )); then
      prev_weekly_pct="$weekly_pct"
    else
      prev_weekly_pct=100
    fi
  fi

  if (( resumed_after_disabled == 1 && resume_delivery_attempted == 1 )); then
    # The first resumed cycle has had its chance to deliver old pending
    # entries.  Subsequent cycles return to normal expire-before-deliver order.
    alerts_disabled_since=0
  fi
  if ! persist_alert_state; then
    echo "[ERROR] Could not persist alert state." >&2
    status=1
    ALERT_PROCESSING_ERROR="alert state persistence failed"
  elif ! python3 "$ALERTS_PY" prune "$ALERT_DELIVERIES_FILE" --now "$scraped_at_epoch"; then
    status=1
    ALERT_PROCESSING_ERROR="alert journal pruning failed"
  fi
  return "$status"
}

# ============================================================================
# Main
# ============================================================================
update_health() {
  local result="$1" detail="$2" duration_ms="$3" cycle_mode="${4:-full}" interval_seconds="${5:-$LOOP_INTERVAL}"
  python3 - "$HEALTH_FILE" "$result" "$detail" "$duration_ms" "$cycle_mode" "$interval_seconds" <<'PYEOF'
import datetime
import json
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
result, detail, duration, cycle_mode, interval = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], int(sys.argv[6])
try:
    health = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except (OSError, ValueError):
    health = {}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
health["last_cycle"] = now
health["last_cycle_duration_ms"] = duration
health["last_cycle_result"] = result
health["last_cycle_mode"] = cycle_mode
health["last_cycle_interval_seconds"] = interval
if result == "success":
    health["last_success"] = now
    health["consecutive_failures"] = 0
else:
    health["last_error"] = {"at": now, "message": detail[:500]}
    health["consecutive_failures"] = int(health.get("consecutive_failures", 0)) + 1

fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", text=True)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(health, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PYEOF
}

append_cycle_error() {
  local message="$1"
  if [[ -n "${CYCLE_ERROR:-}" ]]; then
    CYCLE_ERROR="${CYCLE_ERROR}; ${message}"
  else
    CYCLE_ERROR="$message"
  fi
}

archive_snapshot() {
  local json="$1"
  printf '%s\n' "$json" | python3 "$SCRIPT_DIR/archive.py" \
    --database "$ARCHIVE_FILE" \
    --history "$HISTORY_FILE" \
    --retention-days "$ARCHIVE_RETENTION_DAYS"
}

observe_quota_anomalies() {
  local json="$1"
  printf '%s\n' "$json" | python3 "$ANOMALIES_PY" observe --database "$ARCHIVE_FILE"
}

collect_token_usage() {
  python3 "$SCRIPT_DIR/token_usage.py" \
    --database "$ARCHIVE_FILE" \
    --pricing "$TOKEN_PRICING_FILE" \
    --sources "$TOKEN_USAGE_SOURCES" \
    --retention-days "$ARCHIVE_RETENTION_DAYS" \
    --codex-data-dir "$CODEX_DATA_DIR" \
    --opencode-db "$OPENCODE_DB_PATH" \
    --hermes-db "$HERMES_DB_PATH"
}

check_token_usage() {
  python3 "$SCRIPT_DIR/token_usage.py" \
    --check \
    --database "$ARCHIVE_FILE" \
    --pricing "$TOKEN_PRICING_FILE" \
    --sources "$TOKEN_USAGE_SOURCES" \
    --codex-data-dir "$CODEX_DATA_DIR" \
    --opencode-db "$OPENCODE_DB_PATH" \
    --hermes-db "$HERMES_DB_PATH"
}

run_cycle() {
  local interval_seconds="$1"
  local cycle_mode="${2:-full}" regular_interval
  regular_interval="${3:-$interval_seconds}"
  if [[ "$cycle_mode" != full && "$cycle_mode" != live ]]; then
    echo "[ERROR] Unsupported cycle mode: ${cycle_mode}." >&2
    return 2
  fi
  echo "[$(format_paris_now)] Scraping codex status (${cycle_mode} cycle)..."

  local json public_json gist_json status=0 history_json="[]" storage_ok=1
  CYCLE_ERROR=""
  if json=$(fetch_status_json "$interval_seconds"); then
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
    public_json="$json"
    if [[ "$cycle_mode" == full && "$CODEX_FORECAST_ENABLED" == 1 ]]; then
      if ! public_json="$(enrich_snapshot_with_codex_forecast "$json")"; then
        public_json="$json"
      fi
    fi
    if [[ "$cycle_mode" == full ]]; then
      if ! archive_snapshot "$public_json"; then
        status=1
        storage_ok=0
        append_cycle_error "Long-term archive update failed"
      fi
      if write_local_snapshot "$public_json"; then
        if [[ -f "$HISTORY_FILE" ]]; then
          history_json="$(<"$HISTORY_FILE")"
        fi
      else
        status=1
        storage_ok=0
        append_cycle_error "Local snapshot write failed"
      fi
      gist_json="$public_json"
      if (( interval_seconds != regular_interval )); then
        if ! gist_json="$(snapshot_with_interval "$public_json" "$regular_interval")"; then
          gist_json="$public_json"
          status=1
          append_cycle_error "External snapshot cadence update failed"
        fi
      fi
      if (( storage_ok )); then
        sync_gist "$gist_json" "$history_json" || { status=1; append_cycle_error "GitHub Gist sync failed"; }
      else
        echo "[WARN] Skipping GitHub Gist sync because local storage failed." >&2
      fi
    else
      write_current_snapshot "$public_json" || { status=1; append_cycle_error "Current snapshot write failed"; }
    fi

    local five_h weekly five_h_reset weekly_reset five_h_reset_at weekly_reset_at limit_id scraped_at scraped_at_epoch
    five_h=$(json_get_field "$json" "five_h_pct")
    weekly=$(json_get_field "$json" "weekly_pct")
    five_h_reset=$(json_get_field "$json" "five_h_reset")
    weekly_reset=$(json_get_field "$json" "weekly_reset")
    five_h_reset_at=$(json_get_field "$json" "five_h_reset_at")
    weekly_reset_at=$(json_get_field "$json" "weekly_reset_at")
    limit_id=$(json_get_field "$json" "limit_id")
    scraped_at=$(json_get_field "$json" "scraped_at")
    scraped_at_epoch=$(timestamp_to_epoch "$scraped_at") || scraped_at_epoch=$(date -u +%s)
    if ! observe_quota_anomalies "$public_json"; then
      status=1
      append_cycle_error "Quota anomaly detector failed"
    fi
    check_thresholds "$five_h" "$weekly" "$five_h_reset" "$weekly_reset" \
      "$five_h_reset_at" "$weekly_reset_at" "$scraped_at_epoch" "$limit_id" \
      || { status=1; append_cycle_error "${ALERT_PROCESSING_ERROR:-alert processing failed}"; }
  else
    status=1
    append_cycle_error "Codex limit collection failed"
  fi

  if [[ "$cycle_mode" == full ]]; then
    collect_token_usage || { status=1; append_cycle_error "Local token usage collection failed"; }
  fi
  return "$status"
}

monotonic_milliseconds() {
  python3 - <<'PYEOF'
import time
print(time.monotonic_ns() // 1_000_000)
PYEOF
}

run_once() {
  local interval_seconds="$1" cycle_mode="${2:-full}" regular_interval
  regular_interval="${3:-$interval_seconds}"
  local lock_fd start_ms end_ms duration_ms status=0
  exec {lock_fd}>"$LOCK_FILE"
  chmod 600 "$LOCK_FILE"
  if ! flock -n "$lock_fd"; then
    echo "[INFO] Another monitor cycle is active; this cycle was skipped."
    exec {lock_fd}>&-
    return 0
  fi

  start_ms="$(monotonic_milliseconds)"
  if run_cycle "$interval_seconds" "$cycle_mode" "$regular_interval"; then
    status=0
  else
    status=$?
  fi
  end_ms="$(monotonic_milliseconds)"
  duration_ms=$((end_ms - start_ms))
  if (( status == 0 )); then
    update_health success "" "$duration_ms" "$cycle_mode" "$interval_seconds"
    echo "[OK] Cycle completed in ${duration_ms}ms."
  else
    update_health failure "${CYCLE_ERROR:-Collection or delivery failed}" "$duration_ms" "$cycle_mode" "$interval_seconds"
    echo "[WARN] Cycle failed in ${duration_ms}ms." >&2
  fi
  exec {lock_fd}>&-
  return "$status"
}

validate_interval() {
  local interval="$1"
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ || ${#interval} -gt 5 ]] || (( 10#$interval > 86400 )); then
    echo "[ERROR] Loop interval must be an integer from 1 to 86400 seconds." >&2
    return 1
  fi
}

seconds_until_next_interval() {
  local now_epoch="$1"
  local interval="$2"
  printf '%s\n' "$((interval - now_epoch % interval))"
}

dashboard_activity_recent() {
  local now_epoch="${1:-}" metadata owner size modified
  [[ -n "$now_epoch" ]] || now_epoch="$(date -u +%s)"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  [[ -f "$HEARTBEAT_FILE" && ! -L "$HEARTBEAT_FILE" ]] || return 1
  metadata="$(stat -c '%u %s %Y' -- "$HEARTBEAT_FILE" 2>/dev/null)" || return 1
  read -r owner size modified <<< "$metadata"
  [[ "$owner" =~ ^[0-9]+$ && "$size" == 0 && "$modified" =~ ^[0-9]+$ ]] || return 1
  [[ "$owner" == "$(id -u)" ]] || return 1
  (( modified <= now_epoch && now_epoch - modified <= DASHBOARD_HEARTBEAT_MAX_AGE_SECONDS ))
}

effective_collection_interval() {
  local regular_interval="$1" now_epoch="$2"
  if (( regular_interval > DASHBOARD_ACTIVE_INTERVAL_SECONDS )) && dashboard_activity_recent "$now_epoch"; then
    printf '%s\n' "$DASHBOARD_ACTIVE_INTERVAL_SECONDS"
  else
    printf '%s\n' "$regular_interval"
  fi
}

run_loop() {
  local interval="$1" fail_fast="$2"
  local now_epoch completed_at next_regular last_attempt delay effective cycle_status=0 live_due

  now_epoch="$(date -u +%s)"
  effective="$(effective_collection_interval "$interval" "$now_epoch")"
  last_attempt="$now_epoch"
  run_once "$effective" full "$interval" || cycle_status=$?
  if (( cycle_status != 0 )); then
    echo "[WARN] Scrape cycle failed, will retry at the next scheduled check"
    (( fail_fast == 1 )) && return "$cycle_status"
  fi
  completed_at="$(date -u +%s)"
  delay="$(seconds_until_next_interval "$completed_at" "$interval")"
  next_regular=$((completed_at + delay))
  echo "[$(format_paris_now)] Next regular check at $(format_paris_timestamp "$next_regular") (in ${delay}s)..."

  while true; do
    now_epoch="$(date -u +%s)"
    cycle_status=0
    if (( now_epoch >= next_regular )); then
      effective="$(effective_collection_interval "$interval" "$now_epoch")"
      last_attempt="$now_epoch"
      run_once "$effective" full "$interval" || cycle_status=$?
      completed_at="$(date -u +%s)"
      delay="$(seconds_until_next_interval "$completed_at" "$interval")"
      next_regular=$((completed_at + delay))
      echo "[$(format_paris_now)] Next regular check at $(format_paris_timestamp "$next_regular") (in ${delay}s)..."
    elif (( interval > DASHBOARD_ACTIVE_INTERVAL_SECONDS )) \
      && dashboard_activity_recent "$now_epoch" \
      && (( now_epoch - last_attempt >= DASHBOARD_ACTIVE_INTERVAL_SECONDS )); then
      last_attempt="$now_epoch"
      run_once "$DASHBOARD_ACTIVE_INTERVAL_SECONDS" live "$interval" || cycle_status=$?
      echo "[$(format_paris_now)] Dashboard active; next live check is eligible in ${DASHBOARD_ACTIVE_INTERVAL_SECONDS}s."
    else
      delay=$((next_regular - now_epoch))
      if (( interval > DASHBOARD_ACTIVE_INTERVAL_SECONDS && delay > DASHBOARD_HEARTBEAT_POLL_SECONDS )); then
        delay="$DASHBOARD_HEARTBEAT_POLL_SECONDS"
      fi
      if (( interval > DASHBOARD_ACTIVE_INTERVAL_SECONDS )) && dashboard_activity_recent "$now_epoch"; then
        live_due=$((last_attempt + DASHBOARD_ACTIVE_INTERVAL_SECONDS))
        if (( live_due > now_epoch && live_due - now_epoch < delay )); then
          delay=$((live_due - now_epoch))
        fi
      fi
      (( delay > 0 )) || delay=1
      sleep "$delay"
      continue
    fi

    if (( cycle_status != 0 )); then
      echo "[WARN] Scrape cycle failed, will retry at the next scheduled check"
      (( fail_fast == 1 )) && return "$cycle_status"
    fi
  done
}

main() {
  local argument interval interval_override="" interval_was_set=0 mode="" fail_fast=0

  for argument in "$@"; do
    case "$argument" in
      -h|--help)
        usage
        return 0
        ;;
    esac
  done

  while (( $# > 0 )); do
    case "$1" in
      --loop)
        if [[ -n "$mode" ]]; then
          cli_error "Only one of --once, --loop, --check, or --status-json may be specified." || return $?
        fi
        mode=loop
        if (( $# >= 2 )) && [[ "$2" != -* ]]; then
          interval_override="$2"
          interval_was_set=1
          shift
        fi
        ;;
      --status-json)
        if [[ -n "$mode" ]]; then
          cli_error "Only one of --once, --loop, --check, or --status-json may be specified." || return $?
        fi
        mode=status_json
        ;;
      --check)
        if [[ -n "$mode" ]]; then
          cli_error "Only one of --once, --loop, --check, or --status-json may be specified." || return $?
        fi
        mode=check
        ;;
      --fail-fast) fail_fast=1 ;;
      --once)
        if [[ -n "$mode" ]]; then
          cli_error "Only one of --once, --loop, --check, or --status-json may be specified." || return $?
        fi
        mode=once
        ;;
      -*) cli_error "Unknown option: $1" || return $? ;;
      *) cli_error "Unexpected positional argument: $1" || return $? ;;
    esac
    shift
  done

  mode="${mode:-once}"
  if (( fail_fast == 1 )) && [[ "$mode" != loop ]]; then
    cli_error "--fail-fast can only be used with --loop." || return $?
  fi
  if (( interval_was_set == 1 )) && ! validate_interval "$interval_override"; then
    usage >&2
    return 2
  fi

  initialize "$interval_override" || return 1
  if (( interval_was_set == 1 )); then
    interval="$interval_override"
  else
    interval="$LOOP_INTERVAL"
  fi
  validate_interval "$interval" || return 1
  if [[ "$mode" == status_json ]]; then
    fetch_status_json "$interval"
    return $?
  fi
  if [[ "$mode" == check ]]; then
    echo "[INFO] Checking Codex authentication and app-server response..."
    fetch_status_json "$interval" >/dev/null || return 1
    echo "[INFO] Checking local token analytics sources and pricing..."
    check_token_usage || return 1
    echo "[OK] Configuration, dependencies, permissions, tzdata, Codex authentication and token analytics are valid."
    return 0
  fi

  if [[ "$mode" == loop ]]; then
    echo "Starting monitor loop (aligned interval: ${interval}s). Press Ctrl+C to stop."
    run_loop "$interval" "$fail_fast"
  else
    run_once "$interval"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
