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
ENV_FILE="${SCRIPT_DIR}/.env"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
STATE_FILE="${RUNTIME_DIR}/.alert_state"
DATA_FILE="${RUNTIME_DIR}/data.json"
HISTORY_FILE="${RUNTIME_DIR}/history.json"
ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
HEALTH_FILE="${RUNTIME_DIR}/health.json"
LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
INVALID_ALERT_SCRIPT_CONFIG=0
# Retry-After is useful for rate-limited providers, but a remote endpoint must
# never be allowed to stall the monitor indefinitely.
ALERT_RETRY_MAX_DELAY_SECONDS=60

declare -a ALERT_IDS=()
declare -A ALERT_STATUS=()
declare -A ALERT_EVENT=()
declare -A ALERT_CHANNEL_STATUS=()
declare -A ALERT_CHANNEL_RETRYABLE=()
ALERT_DELIVERY_STATE_READY=0
ALERT_DELIVERY_RETRYABLE_FAILURE=0
ALERT_DELIVERY_PERMANENT_FAILURE=0
ALERT_DELIVERY_COMPLETE=0
HTTP_REQUEST_FAILURE_CLASS=retryable

load_config() {
  local config_output key value
  config_output="$(mktemp)" || return 1
  if ! python3 "$SCRIPT_DIR/config.py" \
      --env-file "$ENV_FILE" --base-dir "$SCRIPT_DIR" --lines > "$config_output"; then
    rm -f "$config_output"
    return 1
  fi
  while IFS=$'\t' read -r key value; do
    case "$key" in
      CONFIG_INVALID_ALERT_SCRIPT)
        INVALID_ALERT_SCRIPT_CONFIG=1
        ;;
      '')
        ;;
      *)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$config_output"
  rm -f "$config_output"
}

# ============================================================================
# Validation
# ============================================================================
config_error() {
  printf '[ERROR] %s\n' "$1" >&2
  return 1
}

validate_integer() {
  local name="$1" value="$2" minimum="$3" maximum="$4" normalized
  [[ "$value" =~ ^[0-9]+$ ]] || { config_error "$name must be an integer between $minimum and $maximum."; return 1; }
  normalized="$value"
  while [[ "$normalized" == 0* && ${#normalized} -gt 1 ]]; do normalized="${normalized#0}"; done
  (( ${#normalized} <= ${#maximum} )) || { config_error "$name must be between $minimum and $maximum."; return 1; }
  (( 10#$normalized >= minimum && 10#$normalized <= maximum )) || { config_error "$name must be between $minimum and $maximum."; return 1; }
}

validate_number() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  python3 - "$name" "$value" "$minimum" "$maximum" <<'PYEOF'
import math
import sys

name, raw, minimum, maximum = sys.argv[1:]
try:
    value = float(raw)
except ValueError:
    sys.stderr.write(f"[ERROR] {name} must be a number between {minimum} and {maximum}.\n")
    raise SystemExit(1)
if not math.isfinite(value) or not float(minimum) <= value <= float(maximum):
    sys.stderr.write(f"[ERROR] {name} must be between {minimum} and {maximum}.\n")
    raise SystemExit(1)
PYEOF
}

has_control_characters() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

validate_thresholds() {
  python3 - "$ALERT_THRESHOLDS" <<'PYEOF'
import sys

parts = sys.argv[1].split(",")
if not parts or any(not part.strip() for part in parts):
    sys.stderr.write("[ERROR] ALERT_THRESHOLDS must be a comma-separated list of integers from 0 to 100.\n")
    raise SystemExit(1)
try:
    values = [int(part.strip()) for part in parts]
except ValueError:
    sys.stderr.write("[ERROR] ALERT_THRESHOLDS must contain integers only.\n")
    raise SystemExit(1)
if not values or any(value < 0 or value > 100 for value in values):
    sys.stderr.write("[ERROR] ALERT_THRESHOLDS values must be between 0 and 100.\n")
    raise SystemExit(1)
PYEOF
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

validate_alert_scripts() {
  local invalid=0 index path_name events_name path events raw_event event window selector pair action_id variable_name
  local -A seen_pairs=()
  local -a configured_events=()
  ALERT_SCRIPT_RULE_INDICES=()
  ALERT_SCRIPT_RULE_PATHS=()
  ALERT_SCRIPT_RULE_EVENTS=()
  ALERT_SCRIPT_RULE_IDS=()

  if [[ "${INVALID_ALERT_SCRIPT_CONFIG:-0}" == 1 ]]; then
    config_error "Alert script indices must be integers from 1 to 99." || true
    invalid=1
  fi
  while IFS= read -r variable_name; do
    case "$variable_name" in
      ALERT_SCRIPT_TIMEOUT_SECONDS|ALERT_SCRIPT_RULE_*) ;;
      *)
        if [[ ! "$variable_name" =~ ^ALERT_SCRIPT_([1-9]|[1-9][0-9])(_EVENTS)?$ ]]; then
          config_error "Unsupported alert script variable: ${variable_name}." || true
          invalid=1
        fi
        ;;
    esac
  done < <(compgen -A variable ALERT_SCRIPT_)

  validate_integer ALERT_SCRIPT_TIMEOUT_SECONDS "$ALERT_SCRIPT_TIMEOUT_SECONDS" 1 1800 || invalid=1
  for (( index = 1; index <= 99; index++ )); do
    path_name="ALERT_SCRIPT_${index}"
    events_name="ALERT_SCRIPT_${index}_EVENTS"
    path="${!path_name:-}"
    events="${!events_name:-}"
    if [[ -z "$path" && -z "$events" ]]; then
      continue
    fi
    if [[ -z "$path" || -z "$events" ]]; then
      config_error "${path_name} and ${events_name} must either both be set or both be empty." || true
      invalid=1
      continue
    fi
    if has_control_characters "$path"; then
      config_error "${path_name} must not contain control characters." || true
      invalid=1
      continue
    fi
    if [[ "$path" != /* || ! -f "$path" || ! -x "$path" ]]; then
      config_error "${path_name} must be an absolute path to an executable regular file." || true
      invalid=1
      continue
    fi

    IFS=',' read -r -a configured_events <<< "$events"
    if (( ${#configured_events[@]} == 0 )) || [[ "$events" == ,* || "$events" == *, || "$events" == *,,* ]]; then
      config_error "${events_name} must contain at least one event." || true
      invalid=1
      continue
    fi
    for raw_event in "${configured_events[@]}"; do
      event="${raw_event#"${raw_event%%[![:space:]]*}"}"
      event="${event%"${event##*[![:space:]]}"}"
      if [[ ! "$event" =~ ^(5h|weekly):(reset|[0-9]+)$ ]]; then
        config_error "${events_name} contains an invalid event: ${event:-<empty>}." || true
        invalid=1
        continue
      fi
      window="${event%%:*}"
      selector="${event#*:}"
      if [[ "$selector" != reset ]] && ! validate_integer "${events_name} threshold" "$selector" 0 100; then
        invalid=1
        continue
      fi
      if [[ "$selector" != reset ]]; then
        selector="$((10#$selector))"
        event="${window}:${selector}"
      fi
      pair="${path}"$'\034'"${event}"
      if [[ -n "${seen_pairs[$pair]:-}" ]]; then
        config_error "Duplicate alert script action for ${path} and ${event}." || true
        invalid=1
        continue
      fi
      seen_pairs[$pair]=1
      action_id="$(python3 - "$path" "$event" <<'PYEOF'
import hashlib
import sys
print(hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:24])
PYEOF
)"
      ALERT_SCRIPT_RULE_INDICES+=("$index")
      ALERT_SCRIPT_RULE_PATHS+=("$path")
      ALERT_SCRIPT_RULE_EVENTS+=("$event")
      ALERT_SCRIPT_RULE_IDS+=("$action_id")
    done
  done
  (( invalid == 0 ))
}

validate_config() {
  local invalid=0 secret path_value
  validate_integer LOOP_INTERVAL "$LOOP_INTERVAL" 1 86400 || invalid=1
  validate_integer CODEX_STATUS_TIMEOUT_SECONDS "$CODEX_STATUS_TIMEOUT_SECONDS" 5 300 || invalid=1
  validate_integer ARCHIVE_RETENTION_DAYS "$ARCHIVE_RETENTION_DAYS" 0 36500 || invalid=1
  validate_number HISTORY_RETENTION_HOURS "$HISTORY_RETENTION_HOURS" 0.25 8760 || invalid=1
  validate_integer CURL_CONNECT_TIMEOUT_SECONDS "$CURL_CONNECT_TIMEOUT_SECONDS" 1 60 || invalid=1
  validate_integer CURL_MAX_TIME_SECONDS "$CURL_MAX_TIME_SECONDS" 1 600 || invalid=1
  validate_integer CURL_RETRIES "$CURL_RETRIES" 0 5 || invalid=1
  validate_integer CURL_RETRY_DELAY_SECONDS "$CURL_RETRY_DELAY_SECONDS" 0 60 || invalid=1
  validate_thresholds || invalid=1
  validate_alert_scripts || invalid=1

  if (( CURL_CONNECT_TIMEOUT_SECONDS > CURL_MAX_TIME_SECONDS )); then
    config_error "CURL_CONNECT_TIMEOUT_SECONDS cannot exceed CURL_MAX_TIME_SECONDS." || true
    invalid=1
  fi
  if [[ -n "$GITHUB_PAT" || -n "$GITHUB_GIST_ID" ]] && [[ -z "$GITHUB_PAT" || -z "$GITHUB_GIST_ID" ]]; then
    config_error "GITHUB_PAT and GITHUB_GIST_ID must either both be set or both be empty." || true
    invalid=1
  fi
  if [[ -n "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" ]] && [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    config_error "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must either both be set or both be empty." || true
    invalid=1
  fi
  [[ -z "$GITHUB_GIST_ID" || "$GITHUB_GIST_ID" =~ ^[A-Fa-f0-9]+$ ]] || { config_error "GITHUB_GIST_ID has an invalid format." || true; invalid=1; }
  [[ -z "$DISCORD_WEBHOOK" || "$DISCORD_WEBHOOK" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$ ]] || { config_error "DISCORD_WEBHOOK must be an official Discord HTTPS webhook URL." || true; invalid=1; }
  [[ -z "$TELEGRAM_BOT_TOKEN" || "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { config_error "TELEGRAM_BOT_TOKEN has an invalid format." || true; invalid=1; }
  [[ -z "$TELEGRAM_CHAT_ID" || "$TELEGRAM_CHAT_ID" =~ ^-?[1-9][0-9]*$ ]] || { config_error "TELEGRAM_CHAT_ID must be a non-zero numeric chat ID." || true; invalid=1; }
  [[ "$MONITOR_DEBUG" == 0 || "$MONITOR_DEBUG" == 1 ]] || { config_error "MONITOR_DEBUG must be 0 or 1." || true; invalid=1; }
  [[ "$GITHUB_API_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || { config_error "GITHUB_API_URL is not a valid HTTP(S) base URL." || true; invalid=1; }
  [[ "$TELEGRAM_API_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || { config_error "TELEGRAM_API_URL is not a valid HTTP(S) base URL." || true; invalid=1; }
  [[ "$TOKEN_USAGE_SOURCES" == auto || "$TOKEN_USAGE_SOURCES" == none || "$TOKEN_USAGE_SOURCES" =~ ^(codex|opencode|hermes)(,(codex|opencode|hermes))*$ ]] || { config_error "TOKEN_USAGE_SOURCES must be auto, none, or a comma-separated list of codex,opencode,hermes." || true; invalid=1; }

  for path_value in "$TOKEN_PRICING_FILE" "$CODEX_DATA_DIR" "$OPENCODE_DB_PATH" "$HERMES_DB_PATH"; do
    if [[ "$path_value" != /* ]] || has_control_characters "$path_value"; then
      config_error "Token analytics paths must be absolute and contain no control characters." || true
      invalid=1
      break
    fi
  done
  if [[ ! -f "$TOKEN_PRICING_FILE" || ! -r "$TOKEN_PRICING_FILE" || -L "$TOKEN_PRICING_FILE" ]]; then
    config_error "TOKEN_PRICING_FILE must be a readable regular file, not a symbolic link." || true
    invalid=1
  fi

  for secret in "$GITHUB_PAT" "$DISCORD_WEBHOOK" "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID"; do
    if has_control_characters "$secret"; then
      config_error "Credentials and channel identifiers must not contain control characters." || true
      invalid=1
      break
    fi
  done
  (( invalid == 0 ))
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

  if alert_scripts_configured && ! command -v timeout &>/dev/null; then
    echo "[ERROR] 'timeout' is required when alert scripts are configured." >&2
    missing=1
  fi

  (( missing == 0 ))
}

initialize() {
  local codex_bin_override="${CODEX_BIN_OVERRIDE:-}"
  umask 077
  load_config || return 1

  if [[ -n "$codex_bin_override" ]]; then
    CODEX_BIN="$codex_bin_override"
  fi

  if ! python3 "$SCRIPT_DIR/config.py" \
      --env-file "$ENV_FILE" --base-dir "$SCRIPT_DIR" --set "CODEX_BIN=${CODEX_BIN}" --validate >/dev/null; then
    return 1
  fi
  validate_config || return 1
  check_requirements || return 1
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  [[ -w "$RUNTIME_DIR" ]] || { config_error "Runtime directory is not writable: $RUNTIME_DIR"; return 1; }
}

fetch_status_json() {
  local interval_seconds="$1"
  local codex_cmd="${CODEX_BIN:-codex}"

  local -a debug_args=()
  [[ "${MONITOR_DEBUG:-0}" == 1 ]] && debug_args+=(--debug)
  python3 "$SCRIPT_DIR/codex_status.py" \
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
  printf '%s\n' "$json" | python3 "$SCRIPT_DIR/history.py" \
    --history "$HISTORY_FILE" \
    --data "$DATA_FILE" \
    --retention-hours "$HISTORY_RETENTION_HOURS" \
    --snapshot -

  echo "[OK] Snapshot storage processed at ${DATA_FILE}"
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
retry_after_seconds() {
  local headers_file="$1"
  python3 - "$headers_file" <<'PYEOF'
import email.utils
import math
import pathlib
import sys
import time

try:
    lines = pathlib.Path(sys.argv[1]).read_text(encoding="iso-8859-1").splitlines()
except OSError:
    raise SystemExit(0)

for line in reversed(lines):
    if ":" not in line:
        continue
    name, value = line.split(":", 1)
    if name.strip().lower() != "retry-after":
        continue
    value = value.strip()
    if value.isdigit():
        print(int(value))
        break
    try:
        retry_at = email.utils.parsedate_to_datetime(value).timestamp()
    except (TypeError, ValueError, OverflowError):
        continue
    print(max(0, math.ceil(retry_at - time.time())))
    break
PYEOF
}

http_request() {
  local service="$1" expected_status="$2" curl_config="$3" method="$4" output_file="$5"
  shift 5
  local attempt=1 max_attempts=$((CURL_RETRIES + 1)) status="000" curl_status=0
  local delay retry_after error_file headers_file
  HTTP_REQUEST_FAILURE_CLASS=retryable
  error_file="$(mktemp "${RUNTIME_DIR}/.curl-error.XXXXXX")"
  headers_file="$(mktemp "${RUNTIME_DIR}/.curl-headers.XXXXXX")"

  while (( attempt <= max_attempts )); do
    echo "[INFO] ${service}: delivery attempt ${attempt}/${max_attempts}."
    : > "$output_file"
    : > "$error_file"
    : > "$headers_file"
    curl_status=0
    status="$(printf '%s\n' "$curl_config" | curl --config - --silent --show-error \
      --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" \
      --request "$method" --output "$output_file" --dump-header "$headers_file" \
      --write-out '%{http_code}' "$@" 2>"$error_file")" || curl_status=$?
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
        HTTP_REQUEST_FAILURE_CLASS=none
        rm -f "$error_file" "$headers_file"
        return 0
      fi
    fi
    if (( curl_status == 0 )) \
      && [[ "$status" =~ ^4[0-9]{2}$ ]] \
      && [[ "$status" != 429 ]]; then
      HTTP_REQUEST_FAILURE_CLASS=permanent
    else
      HTTP_REQUEST_FAILURE_CLASS=retryable
    fi
    if [[ "${MONITOR_DEBUG:-0}" == 1 && -s "$error_file" ]]; then
      echo "[DEBUG] ${service}: request failed (curl=${curl_status}, HTTP ${status})." >&2
    fi
    echo "[WARN] ${service}: attempt failed (curl=${curl_status}, HTTP ${status})." >&2
    if [[ "$HTTP_REQUEST_FAILURE_CLASS" == permanent ]]; then
      break
    fi
    if (( attempt < max_attempts )); then
      delay=$((CURL_RETRY_DELAY_SECONDS * (2 ** (attempt - 1))))
      retry_after="$(retry_after_seconds "$headers_file" || true)"
      if [[ "$retry_after" =~ ^[0-9]+$ ]] && (( retry_after > delay )); then
        delay="$retry_after"
      fi
      (( delay > ALERT_RETRY_MAX_DELAY_SECONDS )) && delay="$ALERT_RETRY_MAX_DELAY_SECONDS"
      if (( delay > 0 )); then
        echo "[INFO] ${service}: retrying in ${delay}s."
      fi
      (( delay > 0 )) && sleep "$delay"
    fi
    ((attempt += 1))
  done
  rm -f "$error_file" "$headers_file"
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
  ALERT_CHANNEL_FAILURE_RETRYABLE=1
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
  [[ "${HTTP_REQUEST_FAILURE_CLASS:-retryable}" == permanent ]] && ALERT_CHANNEL_FAILURE_RETRYABLE=0
  rm -f "$response_file"
  return 1
}

send_telegram() {
  local message="$1"
  ALERT_CHANNEL_FAILURE_RETRYABLE=1
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return; fi

  local response_file
  response_file="$(mktemp "${RUNTIME_DIR}/.telegram-response.XXXXXX")"
  if http_request Telegram 200 "url = \"${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" \
    POST "$response_file" --data "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}"; then
    rm -f "$response_file"
    return 0
  fi
  [[ "${HTTP_REQUEST_FAILURE_CLASS:-retryable}" == permanent ]] && ALERT_CHANNEL_FAILURE_RETRYABLE=0
  echo "[WARN] Telegram: HTTP response did not confirm delivery." >&2
  rm -f "$response_file"
  return 1
}

alert_channel_configured() {
  case "$1" in
    discord) [[ -n "${DISCORD_WEBHOOK:-}" ]] ;;
    telegram) [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] ;;
    *) return 1 ;;
  esac
}

alert_channel_key() {
  printf '%s|%s' "$1" "$2"
}

make_alert_id() {
  python3 - "$1" <<'PYEOF'
import hashlib
import sys

print(f"a-{hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest()[:32]}")
PYEOF
}

alert_id_for_reset() {
  make_alert_id "reset|$1|$2"
}

alert_id_for_threshold() {
  make_alert_id "threshold|$1|$2|$3"
}

alert_id_is_valid() {
  [[ "$1" =~ ^a-[a-f0-9]{32}$ ]]
}

reset_alert_delivery_state() {
  ALERT_IDS=()
  ALERT_STATUS=()
  ALERT_EVENT=()
  ALERT_CHANNEL_STATUS=()
  ALERT_CHANNEL_RETRYABLE=()
  ALERT_DELIVERY_STATE_READY=1
}

alert_record_exists() {
  [[ -n "${ALERT_STATUS[$1]+present}" ]]
}

ensure_alert_record() {
  local alert_id="$1" event="${2:-notification}" channel status
  local existing_status
  alert_id_is_valid "$alert_id" || return 1

  if ! alert_record_exists "$alert_id"; then
    ALERT_IDS+=("$alert_id")
    ALERT_STATUS["$alert_id"]="pending"
    ALERT_EVENT["$alert_id"]="$event"
  elif [[ -z "${ALERT_EVENT[$alert_id]:-}" ]]; then
    ALERT_EVENT["$alert_id"]="$event"
  fi

  existing_status="${ALERT_STATUS[$alert_id]:-pending}"
  for channel in discord telegram; do
    alert_channel_configured "$channel" || continue
    local channel_key
    channel_key="$(alert_channel_key "$alert_id" "$channel")"
    if [[ -z "${ALERT_CHANNEL_STATUS[$channel_key]+present}" ]]; then
      case "$existing_status" in
        delivered) status=delivered ;;
        failed) status=failed ;;
        *) status=pending ;;
      esac
      ALERT_CHANNEL_STATUS["$channel_key"]="$status"
      if [[ "$status" == failed ]]; then
        ALERT_CHANNEL_RETRYABLE["$channel_key"]="${ALERT_CHANNEL_RETRYABLE[$channel_key]:-1}"
      else
        ALERT_CHANNEL_RETRYABLE["$channel_key"]="0"
      fi
    fi
  done
}

recompute_alert_status() {
  local alert_id="$1" channel channel_key channel_status configured=0 all_delivered=1
  local has_pending=0 has_retryable_failure=0 has_permanent_failure=0
  for channel in discord telegram; do
    alert_channel_configured "$channel" || continue
    configured=1
    channel_key="$(alert_channel_key "$alert_id" "$channel")"
    channel_status="${ALERT_CHANNEL_STATUS[$channel_key]:-pending}"
    case "$channel_status" in
      delivered) ;;
      pending)
        all_delivered=0
        has_pending=1
        ;;
      failed)
        all_delivered=0
        if [[ "${ALERT_CHANNEL_RETRYABLE[$channel_key]:-1}" == 1 ]]; then
          has_retryable_failure=1
        else
          has_permanent_failure=1
        fi
        ;;
      *)
        all_delivered=0
        has_pending=1
        ;;
    esac
  done

  if (( configured == 0 || all_delivered == 1 )); then
    ALERT_STATUS["$alert_id"]="delivered"
    ALERT_DELIVERY_COMPLETE=1
  elif (( has_pending == 1 || has_retryable_failure == 1 )); then
    ALERT_STATUS["$alert_id"]="pending"
    ALERT_DELIVERY_COMPLETE=0
  else
    ALERT_STATUS["$alert_id"]="failed"
    ALERT_DELIVERY_COMPLETE=0
  fi
  ALERT_DELIVERY_RETRYABLE_FAILURE="$has_retryable_failure"
  ALERT_DELIVERY_PERMANENT_FAILURE="$has_permanent_failure"
}

load_alert_delivery_state() {
  local state_key state_value alert_id field channel_key
  reset_alert_delivery_state
  [[ -f "$STATE_FILE" ]] || return 0

  while IFS='=' read -r state_key state_value; do
    case "$state_key" in
      alert_ids)
        local old_ifs="$IFS"
        IFS=',' read -r -a legacy_alert_ids <<< "$state_value"
        IFS="$old_ifs"
        for alert_id in "${legacy_alert_ids[@]}"; do
          alert_id_is_valid "$alert_id" || continue
          if ! alert_record_exists "$alert_id"; then
            ALERT_IDS+=("$alert_id")
            ALERT_STATUS["$alert_id"]="pending"
          fi
        done
        ;;
      alert_*)
        if [[ "$state_key" =~ ^alert_([a-f0-9-]+)_(discord|telegram|status|event|discord_retryable|telegram_retryable)$ ]]; then
          alert_id="${BASH_REMATCH[1]}"
          field="${BASH_REMATCH[2]}"
          alert_id_is_valid "$alert_id" || continue
          if ! alert_record_exists "$alert_id"; then
            ALERT_IDS+=("$alert_id")
            ALERT_STATUS["$alert_id"]="pending"
          fi
          case "$field" in
            status)
              [[ "$state_value" == pending || "$state_value" == delivered || "$state_value" == failed ]] \
                && ALERT_STATUS["$alert_id"]="$state_value"
              ;;
            event)
              [[ "$state_value" =~ ^[A-Za-z0-9:._-]+$ ]] && ALERT_EVENT["$alert_id"]="$state_value"
              ;;
            discord|telegram)
              [[ "$state_value" == pending || "$state_value" == delivered || "$state_value" == failed ]] \
                && ALERT_CHANNEL_STATUS["$(alert_channel_key "$alert_id" "$field")"]="$state_value"
              ;;
            discord_retryable|telegram_retryable)
              channel="${field%%_*}"
              [[ "$state_value" == 0 || "$state_value" == 1 ]] \
                && ALERT_CHANNEL_RETRYABLE["$(alert_channel_key "$alert_id" "$channel")"]="$state_value"
              ;;
          esac
        fi
        ;;
    esac
  done < "$STATE_FILE"
}

mark_alert_delivered() {
  local alert_id="$1" event="${2:-notification}" channel channel_key
  ensure_alert_record "$alert_id" "$event" || return 1
  for channel in discord telegram; do
    alert_channel_configured "$channel" || continue
    channel_key="$(alert_channel_key "$alert_id" "$channel")"
    ALERT_CHANNEL_STATUS["$channel_key"]="delivered"
    ALERT_CHANNEL_RETRYABLE["$channel_key"]="0"
  done
  ALERT_STATUS["$alert_id"]="delivered"
}

send_alert() {
  local message="$1" alert_id="${2:-}" event="${3:-notification}"
  local channel channel_key channel_status result
  local persist_failed=0

  ALERT_DELIVERY_RETRYABLE_FAILURE=0
  ALERT_DELIVERY_PERMANENT_FAILURE=0
  ALERT_DELIVERY_COMPLETE=0
  [[ "$ALERT_DELIVERY_STATE_READY" == 1 ]] || load_alert_delivery_state
  [[ -n "$alert_id" ]] || alert_id="$(make_alert_id "message|$message")"
  if ! alert_id_is_valid "$alert_id"; then
    echo "[ERROR] Alert delivery could not create a valid alert identifier." >&2
    ALERT_DELIVERY_RETRYABLE_FAILURE=1
    return 1
  fi

  echo "[ALERT] Detected: $message"
  ensure_alert_record "$alert_id" "$event" || {
    echo "[ERROR] Alert delivery state could not be initialized." >&2
    ALERT_DELIVERY_RETRYABLE_FAILURE=1
    return 1
  }

  if ! alert_channel_configured discord && ! alert_channel_configured telegram; then
    echo "[INFO] No alert channel configured; alert acknowledged locally."
    ALERT_STATUS["$alert_id"]="delivered"
    persist_alert_state || return 1
    ALERT_DELIVERY_COMPLETE=1
    return 0
  fi

  for channel in discord telegram; do
    alert_channel_configured "$channel" || continue
    channel_key="$(alert_channel_key "$alert_id" "$channel")"
    channel_status="${ALERT_CHANNEL_STATUS[$channel_key]:-pending}"
    if [[ "$channel_status" == delivered ]]; then
      continue
    fi
    if [[ "$channel_status" == failed && "${ALERT_CHANNEL_RETRYABLE[$channel_key]:-1}" != 1 ]]; then
      continue
    fi

    ALERT_CHANNEL_STATUS["$channel_key"]="pending"
    ALERT_CHANNEL_RETRYABLE["$channel_key"]="0"
    if ! persist_alert_state; then
      echo "[ERROR] Alert delivery state could not be journaled." >&2
      ALERT_DELIVERY_RETRYABLE_FAILURE=1
      persist_failed=1
      break
    fi

    ALERT_CHANNEL_FAILURE_RETRYABLE=1
    if [[ "$channel" == discord ]]; then
      if send_discord "$message"; then result=0; else result=$?; fi
    else
      if send_telegram "$message"; then result=0; else result=$?; fi
    fi
    if (( result == 0 )); then
      ALERT_CHANNEL_STATUS["$channel_key"]="delivered"
      ALERT_CHANNEL_RETRYABLE["$channel_key"]="0"
    else
      ALERT_CHANNEL_STATUS["$channel_key"]="failed"
      ALERT_CHANNEL_RETRYABLE["$channel_key"]="${ALERT_CHANNEL_FAILURE_RETRYABLE:-1}"
    fi
    if ! persist_alert_state; then
      echo "[ERROR] Alert delivery state could not be journaled." >&2
      persist_failed=1
      break
    fi
  done

  (( persist_failed == 0 )) || {
    ALERT_DELIVERY_RETRYABLE_FAILURE=1
    return 1
  }
  recompute_alert_status "$alert_id"
  persist_alert_state || {
    ALERT_DELIVERY_RETRYABLE_FAILURE=1
    return 1
  }
  if (( ALERT_DELIVERY_COMPLETE == 1 )); then
    return 0
  fi
  if (( ALERT_DELIVERY_RETRYABLE_FAILURE == 1 )); then
    return 1
  fi
  if (( ALERT_DELIVERY_PERMANENT_FAILURE == 1 )); then
    return 2
  fi
  return 2
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

csv_contains() {
  local list="$1" wanted="$2"
  [[ ",${list}," == *",${wanted},"* ]]
}

persist_alert_state() {
  local state_tmp alert_id channel channel_key
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' \
    'state_version=4' \
    "prev_5h_pct=${prev_5h_pct:-100}" \
    "prev_weekly_pct=${prev_weekly_pct:-100}" \
    "five_h_armed_reset_at=${five_h_armed_reset_at:-0}" \
    "weekly_armed_reset_at=${weekly_armed_reset_at:-0}" \
    "last_notified_5h_reset_at=${last_notified_5h_reset_at:-0}" \
    "last_notified_weekly_reset_at=${last_notified_weekly_reset_at:-0}" \
    "notified_5h_thresholds=${notified_5h_thresholds:-}" \
    "notified_weekly_thresholds=${notified_weekly_thresholds:-}" \
    "pending_5h_threshold=${pending_5h_threshold:-}" \
    "pending_weekly_threshold=${pending_weekly_threshold:-}" \
    "pending_5h_alert_id=${pending_5h_alert_id:-}" \
    "pending_weekly_alert_id=${pending_weekly_alert_id:-}" \
    "script_tracking_initialized=${script_tracking_initialized:-0}" \
    "script_prev_5h_pct=${script_prev_5h_pct:-100}" \
    "script_prev_weekly_pct=${script_prev_weekly_pct:-100}" \
    "attempted_script_5h_actions=${attempted_script_5h_actions:-}" \
    "attempted_script_weekly_actions=${attempted_script_weekly_actions:-}" \
    "script_5h_reset_attempted_at=${script_5h_reset_attempted_at:-0}" \
    "script_weekly_reset_attempted_at=${script_weekly_reset_attempted_at:-0}" \
    "attempted_script_5h_reset_actions=${attempted_script_5h_reset_actions:-}" \
    "attempted_script_weekly_reset_actions=${attempted_script_weekly_reset_actions:-}" \
    "alert_ids=$(IFS=,; printf '%s' "${ALERT_IDS[*]:-}")" > "$state_tmp"; then
    rm -f "$state_tmp"
    return 1
  fi

  for alert_id in "${ALERT_IDS[@]}"; do
    alert_id_is_valid "$alert_id" || continue
    printf '%s\n' \
      "alert_${alert_id}_event=${ALERT_EVENT[$alert_id]:-notification}" \
      "alert_${alert_id}_status=${ALERT_STATUS[$alert_id]:-pending}" >> "$state_tmp" || {
        rm -f "$state_tmp"
        return 1
      }
    for channel in discord telegram; do
      channel_key="$(alert_channel_key "$alert_id" "$channel")"
      [[ -n "${ALERT_CHANNEL_STATUS[$channel_key]+present}" ]] || continue
      printf '%s\n' \
        "alert_${alert_id}_${channel}=${ALERT_CHANNEL_STATUS[$channel_key]}" \
        "alert_${alert_id}_${channel}_retryable=${ALERT_CHANNEL_RETRYABLE[$channel_key]:-0}" >> "$state_tmp" || {
          rm -f "$state_tmp"
          return 1
        }
    done
  done

  if ! mv -f "$state_tmp" "$STATE_FILE"; then
    rm -f "$state_tmp"
    return 1
  fi
}

run_alert_script() {
  local rule_position="$1" event_kind="$2" window="$3" threshold="$4" remaining_pct="$5"
  local reset_at="$6" reset_label="$7" scraped_at="$8" message="$9"
  local rule_index="${ALERT_SCRIPT_RULE_INDICES[$rule_position]}"
  local path="${ALERT_SCRIPT_RULE_PATHS[$rule_position]}" working_directory exit_code=0 event_label
  working_directory="$(dirname "$path")"
  event_label="${window}:${threshold:-reset}"
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
          "CODEX_ALERT_RULE_INDEX=${rule_index}" \
          "$path" </dev/null
  ) || exit_code=$?

  if (( exit_code == 0 )); then
    echo "[OK] Script rule ${rule_index} completed."
  elif (( exit_code == 124 || exit_code == 137 )); then
    echo "[WARN] Script rule ${rule_index} timed out after ${ALERT_SCRIPT_TIMEOUT_SECONDS}s; action will not be retried." >&2
  else
    echo "[WARN] Script rule ${rule_index} failed with exit code ${exit_code}; action will not be retried." >&2
  fi
  return 0
}

attempt_alert_script() {
  local rule_position="$1" attempted_list_name="$2"
  shift 2
  local action_id="${ALERT_SCRIPT_RULE_IDS[$rule_position]}" previous_list="${!attempted_list_name}"
  csv_contains "$previous_list" "$action_id" && return 0
  printf -v "$attempted_list_name" '%s' "${previous_list:+${previous_list},}${action_id}"
  if ! persist_alert_state; then
    printf -v "$attempted_list_name" '%s' "$previous_list"
    echo "[ERROR] Could not journal alert script action; script was not started." >&2
    return 1
  fi
  run_alert_script "$rule_position" "$@"
}

check_thresholds() {
  local five_h_pct="$1"
  local weekly_pct="$2"
  local five_h_reset="$3"
  local weekly_reset="$4"
  local five_h_reset_at="$5"
  local weekly_reset_at="$6"
  local scraped_at_epoch="$7"

  local prev_5h_pct=100
  local prev_weekly_pct=100
  local five_h_armed_reset_at=0
  local weekly_armed_reset_at=0
  local last_notified_5h_reset_at=0
  local last_notified_weekly_reset_at=0
  local notified_5h_thresholds=""
  local notified_weekly_thresholds=""
  local pending_5h_threshold=""
  local pending_weekly_threshold=""
  local pending_5h_alert_id=""
  local pending_weekly_alert_id=""
  local script_tracking_initialized=0
  local script_prev_5h_pct=100
  local script_prev_weekly_pct=100
  local attempted_script_5h_actions=""
  local attempted_script_weekly_actions=""
  local script_5h_reset_attempted_at=0
  local script_weekly_reset_attempted_at=0
  local attempted_script_5h_reset_actions=""
  local attempted_script_weekly_reset_actions=""
  local thresholds state_key state_value pace pace_suffix t critical status=0 reset_age rule_position script_threshold
  local state_version_seen=1 alert_result cycle_marker alert_id
  local due_5h_reset_at=0 due_weekly_reset_at=0 script_state_error=0 initialize_script_baseline=0
  local -a script_thresholds=()
  ALERT_PROCESSING_ERROR=""
  load_alert_delivery_state
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
        state_version)
          [[ "$state_value" =~ ^[1-9][0-9]*$ ]] && state_version_seen="$state_value"
          ;;
        prev_5h_pct|prev_weekly_pct|script_prev_5h_pct|script_prev_weekly_pct)
          if [[ "$state_value" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
        five_h_armed_reset_at|weekly_armed_reset_at|last_notified_5h_reset_at|last_notified_weekly_reset_at)
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
        pending_5h_alert_id|pending_weekly_alert_id)
          [[ -z "$state_value" || "$state_value" =~ ^a-[a-f0-9]{32}$ ]] \
            && printf -v "$state_key" '%s' "$state_value"
          ;;
        script_tracking_initialized)
          [[ "$state_value" == 0 || "$state_value" == 1 ]] && script_tracking_initialized="$state_value"
          ;;
        attempted_script_5h_actions|attempted_script_weekly_actions|attempted_script_5h_reset_actions|attempted_script_weekly_reset_actions)
          [[ "$state_value" =~ ^([a-f0-9]{24},)*[a-f0-9]{0,24}$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        script_5h_reset_attempted_at|script_weekly_reset_attempted_at)
          [[ "$state_value" =~ ^[0-9]+$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
      esac
    done < "$STATE_FILE"
  fi

  # v1-v3 only had aggregate notification markers. A recorded reset or
  # threshold was already acknowledged by the old monitor, so carry it into
  # the v4 journal as delivered instead of sending it again.
  if (( state_version_seen < 4 )); then
    if (( last_notified_5h_reset_at > 0 )); then
      alert_id="$(alert_id_for_reset 5h "$last_notified_5h_reset_at")"
      mark_alert_delivered "$alert_id" "reset:5h"
    fi
    if (( last_notified_weekly_reset_at > 0 )); then
      alert_id="$(alert_id_for_reset weekly "$last_notified_weekly_reset_at")"
      mark_alert_delivered "$alert_id" "reset:weekly"
    fi
    cycle_marker="$five_h_armed_reset_at"
    [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker=legacy-5h
    IFS=',' read -r -a legacy_thresholds <<< "$notified_5h_thresholds"
    for t in "${legacy_thresholds[@]}"; do
      [[ "$t" =~ ^[0-9]+$ ]] || continue
      alert_id="$(alert_id_for_threshold 5h "$t" "$cycle_marker")"
      mark_alert_delivered "$alert_id" "threshold:5h:${t}"
    done
    cycle_marker="$weekly_armed_reset_at"
    [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker=legacy-weekly
    IFS=',' read -r -a legacy_thresholds <<< "$notified_weekly_thresholds"
    for t in "${legacy_thresholds[@]}"; do
      [[ "$t" =~ ^[0-9]+$ ]] || continue
      alert_id="$(alert_id_for_threshold weekly "$t" "$cycle_marker")"
      mark_alert_delivered "$alert_id" "threshold:weekly:${t}"
    done
  fi

  if [[ -n "$pending_5h_threshold" && -z "$pending_5h_alert_id" ]]; then
    cycle_marker="$five_h_armed_reset_at"
    [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="legacy-5h-${scraped_at_epoch}"
    pending_5h_alert_id="$(alert_id_for_threshold 5h "$pending_5h_threshold" "$cycle_marker")"
  fi
  if [[ -n "$pending_weekly_threshold" && -z "$pending_weekly_alert_id" ]]; then
    cycle_marker="$weekly_armed_reset_at"
    [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="legacy-weekly-${scraped_at_epoch}"
    pending_weekly_alert_id="$(alert_id_for_threshold weekly "$pending_weekly_threshold" "$cycle_marker")"
  fi

  mapfile -t thresholds < <(load_thresholds)
  pace="$(weekly_pace_vs_ideal "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch")"
  pace_suffix=""
  [[ -n "$pace" ]] && pace_suffix=$'\n'"*Pace vs ideal:* ${pace}"

  if (( ${#ALERT_SCRIPT_RULE_INDICES[@]} == 0 )); then
    script_tracking_initialized=0
    attempted_script_5h_actions=""
    attempted_script_weekly_actions=""
  elif (( script_tracking_initialized == 0 )); then
    initialize_script_baseline=1
    [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_5h_pct="$five_h_pct"
    [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_weekly_pct="$weekly_pct"
    script_tracking_initialized=1
  fi

  # Reset delivery is retried while the reset still belongs to a plausible cycle.
  if (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at )); then
    due_5h_reset_at="$five_h_armed_reset_at"
    reset_age=$(( scraped_at_epoch - five_h_armed_reset_at ))
    if (( reset_age <= 5 * 60 * 60 && last_notified_5h_reset_at != five_h_armed_reset_at )); then
      alert_id="$(alert_id_for_reset 5h "$five_h_armed_reset_at")"
      alert_result=0
      send_alert "*Codex 5h limit reset.* A new usage cycle is available." "$alert_id" reset:5h || alert_result=$?
      if (( alert_result == 0 )); then
        last_notified_5h_reset_at="$five_h_armed_reset_at"
      elif (( alert_result == 2 )); then
        # A permanent 4xx is journaled as failed and must not be retried on
        # every collection cycle.
        last_notified_5h_reset_at="$five_h_armed_reset_at"
        status=1
        ALERT_PROCESSING_ERROR="alert delivery failed"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    fi
    if (( reset_age > 5 * 60 * 60 || last_notified_5h_reset_at == five_h_armed_reset_at )); then
      five_h_armed_reset_at=0
      notified_5h_thresholds=""
      pending_5h_threshold=""
      pending_5h_alert_id=""
      prev_5h_pct=100
    fi
    if (( script_5h_reset_attempted_at != due_5h_reset_at )); then
      script_5h_reset_attempted_at="$due_5h_reset_at"
      attempted_script_5h_reset_actions=""
      attempted_script_5h_actions=""
      script_prev_5h_pct=100
    fi
  fi

  if (( weekly_armed_reset_at > 0 && scraped_at_epoch >= weekly_armed_reset_at )); then
    due_weekly_reset_at="$weekly_armed_reset_at"
    reset_age=$(( scraped_at_epoch - weekly_armed_reset_at ))
    if (( reset_age <= 7 * 24 * 60 * 60 && last_notified_weekly_reset_at != weekly_armed_reset_at )); then
      alert_id="$(alert_id_for_reset weekly "$weekly_armed_reset_at")"
      alert_result=0
      send_alert "*Codex weekly limit reset.* A new usage cycle is available." "$alert_id" reset:weekly || alert_result=$?
      if (( alert_result == 0 )); then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
      elif (( alert_result == 2 )); then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
        status=1
        ALERT_PROCESSING_ERROR="alert delivery failed"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    fi
    if (( reset_age > 7 * 24 * 60 * 60 || last_notified_weekly_reset_at == weekly_armed_reset_at )); then
      weekly_armed_reset_at=0
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
      pending_weekly_alert_id=""
      prev_weekly_pct=100
    fi
    if (( script_weekly_reset_attempted_at != due_weekly_reset_at )); then
      script_weekly_reset_attempted_at="$due_weekly_reset_at"
      attempted_script_weekly_reset_actions=""
      attempted_script_weekly_actions=""
      script_prev_weekly_pct=100
    fi
  fi

  # Ignore shifting reset estimates while a cycle is armed. Once it has reset,
  # arm the next plausible deadline only after some quota has been consumed.
  if (( five_h_armed_reset_at == 0 )) \
    && [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$five_h_reset_at" =~ ^[0-9]+$ ]] \
    && percentage_below_full "$five_h_pct" \
    && (( five_h_reset_at > scraped_at_epoch && five_h_reset_at <= scraped_at_epoch + 6 * 60 * 60 )); then
    five_h_armed_reset_at="$five_h_reset_at"
  fi

  if (( weekly_armed_reset_at == 0 )) \
    && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$weekly_reset_at" =~ ^[0-9]+$ ]] \
    && percentage_below_full "$weekly_pct" \
    && (( weekly_reset_at > scraped_at_epoch && weekly_reset_at <= scraped_at_epoch + 8 * 24 * 60 * 60 )); then
    weekly_armed_reset_at="$weekly_reset_at"
  fi

  # The first observation uses 100% as its baseline. A multi-threshold drop emits
  # one alert for the most critical crossed threshold and marks all crossed levels.
  if [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
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
      if [[ -z "$pending_5h_alert_id" ]]; then
        cycle_marker="$five_h_armed_reset_at"
        [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="$five_h_reset_at"
        [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="sample-${scraped_at_epoch}"
        pending_5h_alert_id="$(alert_id_for_threshold 5h "$critical" "$cycle_marker")"
      fi
      alert_result=0
      send_alert "*Codex 5h limit at ${five_h_pct}% remaining* (crossed ${critical}% threshold). Resets at ${five_h_reset}${pace_suffix}" \
        "$pending_5h_alert_id" "threshold:5h:${critical}" || alert_result=$?
      if (( alert_result == 0 || alert_result == 2 )); then
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
        pending_5h_alert_id=""
        prev_5h_pct="$five_h_pct"
        if (( alert_result == 2 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert delivery failed"
        fi
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    else
      prev_5h_pct="$five_h_pct"
    fi
  fi

  if [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
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
      if [[ -z "$pending_weekly_alert_id" ]]; then
        cycle_marker="$weekly_armed_reset_at"
        [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="$weekly_reset_at"
        [[ "$cycle_marker" =~ ^[1-9][0-9]*$ ]] || cycle_marker="sample-${scraped_at_epoch}"
        pending_weekly_alert_id="$(alert_id_for_threshold weekly "$critical" "$cycle_marker")"
      fi
      alert_result=0
      send_alert "*Codex weekly limit at ${weekly_pct}% remaining* (crossed ${critical}% threshold). Resets ${weekly_reset}${pace_suffix}" \
        "$pending_weekly_alert_id" "threshold:weekly:${critical}" || alert_result=$?
      if (( alert_result == 0 || alert_result == 2 )); then
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
        pending_weekly_alert_id=""
        prev_weekly_pct="$weekly_pct"
        if (( alert_result == 2 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert delivery failed"
        fi
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    else
      prev_weekly_pct="$weekly_pct"
    fi
  fi

  # Notifications above are always attempted before local scripts. Script actions
  # have their own journal and never inherit transport retry semantics.
  if (( ${#ALERT_SCRIPT_RULE_INDICES[@]} > 0 )); then
    # A reset can be detected during the activation sample. Preserve the sample
    # itself as the baseline so already-consumed quota is not replayed later.
    if (( initialize_script_baseline == 1 )); then
      [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_5h_pct="$five_h_pct"
      [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]] && script_prev_weekly_pct="$weekly_pct"
    fi
    if (( due_5h_reset_at > 0 && scraped_at_epoch - due_5h_reset_at <= 5 * 60 * 60 )); then
      for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
        if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "5h:reset" ]]; then
          attempt_alert_script "$rule_position" attempted_script_5h_reset_actions \
            reset 5h "" "$five_h_pct" "$due_5h_reset_at" "$five_h_reset" "$scraped_at_epoch" \
            "Codex 5h limit reset. A new usage cycle is available." \
            || { script_state_error=1; status=1; ALERT_PROCESSING_ERROR="alert state persistence failed"; break; }
        fi
      done
    fi
    if (( script_state_error == 0 && due_weekly_reset_at > 0 && scraped_at_epoch - due_weekly_reset_at <= 7 * 24 * 60 * 60 )); then
      for (( rule_position = 0; rule_position < ${#ALERT_SCRIPT_RULE_INDICES[@]}; rule_position++ )); do
        if [[ "${ALERT_SCRIPT_RULE_EVENTS[$rule_position]}" == "weekly:reset" ]]; then
          attempt_alert_script "$rule_position" attempted_script_weekly_reset_actions \
            reset weekly "" "$weekly_pct" "$due_weekly_reset_at" "$weekly_reset" "$scraped_at_epoch" \
            "Codex weekly limit reset. A new usage cycle is available." \
            || { script_state_error=1; status=1; ALERT_PROCESSING_ERROR="alert state persistence failed"; break; }
        fi
      done
    fi

    if (( script_state_error == 0 && initialize_script_baseline == 0 )) \
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
                threshold 5h "$script_threshold" "$five_h_pct" "$five_h_reset_at" "$five_h_reset" "$scraped_at_epoch" \
                "Codex 5h limit at ${five_h_pct}% remaining (crossed ${script_threshold}% threshold)." \
                || { script_state_error=1; status=1; ALERT_PROCESSING_ERROR="alert state persistence failed"; break 2; }
            fi
          done
        fi
      done
      (( script_state_error == 0 )) && script_prev_5h_pct="$five_h_pct"
    fi

    if (( script_state_error == 0 && initialize_script_baseline == 0 )) \
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
                threshold weekly "$script_threshold" "$weekly_pct" "$weekly_reset_at" "$weekly_reset" "$scraped_at_epoch" \
                "Codex weekly limit at ${weekly_pct}% remaining (crossed ${script_threshold}% threshold)." \
                || { script_state_error=1; status=1; ALERT_PROCESSING_ERROR="alert state persistence failed"; break 2; }
            fi
          done
        fi
      done
      (( script_state_error == 0 )) && script_prev_weekly_pct="$weekly_pct"
    fi
  fi

  if ! persist_alert_state; then
    echo "[ERROR] Could not persist alert state." >&2
    status=1
    ALERT_PROCESSING_ERROR="alert state persistence failed"
  fi
  return "$status"
}

# ============================================================================
# Main
# ============================================================================
update_health() {
  local result="$1" detail="$2" duration_ms="$3"
  python3 - "$HEALTH_FILE" "$result" "$detail" "$duration_ms" <<'PYEOF'
import datetime
import json
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
result, detail, duration = sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    health = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except (OSError, ValueError):
    health = {}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
health["last_cycle"] = now
health["last_cycle_duration_ms"] = duration
health["last_cycle_result"] = result
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
  echo "[$(format_paris_now)] Scraping codex status..."

  local json status=0 history_json="[]"
  CYCLE_ERROR=""
  if json=$(fetch_status_json "$interval_seconds"); then
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
    if ! archive_snapshot "$json"; then
      status=1
      append_cycle_error "Long-term archive update failed"
    fi
    if write_local_snapshot "$json" "$interval_seconds"; then
      [[ -f "$HISTORY_FILE" ]] && history_json="$(<"$HISTORY_FILE")"
    else
      status=1
      append_cycle_error "Local snapshot write failed"
    fi
    sync_gist "$json" "$history_json" || { status=1; append_cycle_error "GitHub Gist sync failed"; }

    local five_h weekly five_h_reset weekly_reset five_h_reset_at weekly_reset_at scraped_at scraped_at_epoch
    five_h=$(json_get_field "$json" "five_h_pct")
    weekly=$(json_get_field "$json" "weekly_pct")
    five_h_reset=$(json_get_field "$json" "five_h_reset")
    weekly_reset=$(json_get_field "$json" "weekly_reset")
    five_h_reset_at=$(json_get_field "$json" "five_h_reset_at")
    weekly_reset_at=$(json_get_field "$json" "weekly_reset_at")
    scraped_at=$(json_get_field "$json" "scraped_at")
    scraped_at_epoch=$(timestamp_to_epoch "$scraped_at") || scraped_at_epoch=$(date -u +%s)
    check_thresholds "$five_h" "$weekly" "$five_h_reset" "$weekly_reset" \
      "$five_h_reset_at" "$weekly_reset_at" "$scraped_at_epoch" \
      || { status=1; append_cycle_error "${ALERT_PROCESSING_ERROR:-alert processing failed}"; }
  else
    status=1
    append_cycle_error "Codex limit collection failed"
  fi

  collect_token_usage || { status=1; append_cycle_error "Local token usage collection failed"; }
  return "$status"
}

run_once() {
  local interval_seconds="$1" lock_fd start_ms end_ms duration_ms status=0
  exec {lock_fd}>"$LOCK_FILE"
  chmod 600 "$LOCK_FILE"
  if ! flock -n "$lock_fd"; then
    echo "[INFO] Another monitor cycle is active; this cycle was skipped."
    exec {lock_fd}>&-
    return 0
  fi

  start_ms="$(date -u +%s%3N)"
  if run_cycle "$interval_seconds"; then
    status=0
  else
    status=$?
  fi
  end_ms="$(date -u +%s%3N)"
  duration_ms=$((end_ms - start_ms))
  if (( status == 0 )); then
    update_health success "" "$duration_ms"
    echo "[OK] Cycle completed in ${duration_ms}ms."
  else
    update_health failure "${CYCLE_ERROR:-Collection or delivery failed}" "$duration_ms"
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

monitor_usage() {
  cat <<'EOF'
Usage: ./monitor.sh [OPTION]

Collect Codex limits, update local JSON/SQLite history and deliver alerts.

Options:
  --once                 Run one collection cycle (default).
  --loop [SECONDS]       Run immediately, then at aligned intervals. With no
                         value, use LOOP_INTERVAL from the configuration.
  --check                Validate configuration, dependencies, Codex and token
                         analytics without changing analytics data.
  --status-json          Print one validated Codex status JSON snapshot.
  --fail-fast            In loop mode, exit after the first failed cycle.
  -h, --help             Show this help without requiring Codex authentication.

Configuration is resolved as CLI option, environment, local/.env, then default.
The .env file is parsed as data and is never executed.
EOF
}

main() {
  local interval="" mode=once fail_fast=0 cli_interval=0 now_epoch delay next_epoch next_check

  while (( $# > 0 )); do
    case "$1" in
      --loop)
        mode=loop
        if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
          interval="$2"
          cli_interval=1
          shift
        fi
        ;;
      --status-json) mode=status_json ;;
      --check) mode=check ;;
      --fail-fast) fail_fast=1 ;;
      --once) mode=once ;;
      -h|--help)
        monitor_usage
        return 0
        ;;
      *) config_error "Unknown argument: $1"; return 1 ;;
    esac
    shift
  done

  initialize || return 1
  (( cli_interval == 1 )) || interval="$LOOP_INTERVAL"
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
    while true; do
      if ! run_once "$interval"; then
        echo "[WARN] Scrape cycle failed, will retry at the next scheduled check"
        (( fail_fast == 1 )) && return 1
      fi
      now_epoch="$(date -u +%s)"
      delay="$(seconds_until_next_interval "$now_epoch" "$interval")"
      next_epoch="$((now_epoch + delay))"
      next_check="$(format_paris_timestamp "$next_epoch")"
      echo "[$(format_paris_now)] Next check at ${next_check} (in ${delay}s)..."
      sleep "$delay"
    done
  else
    run_once "$interval"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
