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
SOURCE_ENV_FILE="$ENV_FILE"
SOURCE_RUNTIME_DIR="$RUNTIME_DIR"
STATE_FILE="${RUNTIME_DIR}/.alert_state"
DATA_FILE="${RUNTIME_DIR}/data.json"
HISTORY_FILE="${RUNTIME_DIR}/history.json"
ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
HEALTH_FILE="${RUNTIME_DIR}/health.json"
LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
INVALID_ALERT_SCRIPT_CONFIG=0

CONFIG_VARIABLES=(
  ALERT_THRESHOLDS ALERT_SCRIPT_TIMEOUT_SECONDS ARCHIVE_RETENTION_DAYS
  HISTORY_RETENTION_HOURS LOOP_INTERVAL CODEX_BIN CODEX_STATUS_TIMEOUT_SECONDS
  CURL_CONNECT_TIMEOUT_SECONDS CURL_MAX_TIME_SECONDS CURL_RETRIES
  CURL_RETRY_DELAY_SECONDS MONITOR_DEBUG DISCORD_WEBHOOK TELEGRAM_BOT_TOKEN
  TELEGRAM_CHAT_ID GITHUB_PAT GITHUB_GIST_ID GITHUB_API_URL TELEGRAM_API_URL
  TOKEN_USAGE_SOURCES TOKEN_PRICING_FILE CODEX_DATA_DIR OPENCODE_DB_PATH
  HERMES_DB_PATH STATE_DIR
)

apply_resolved_config() {
  local profile="$1" export_current="$2" output_file key value variable_name status=0 read_error=""
  shift 2
  output_file="$(mktemp)" || { config_error "Could not create a temporary configuration buffer."; return 1; }
  chmod 600 "$output_file"

  (
    if [[ "$export_current" == 1 ]]; then
      for variable_name in "${CONFIG_VARIABLES[@]}"; do
        [[ -v "$variable_name" ]] && export "${variable_name?}"
      done
      while IFS= read -r variable_name; do
        [[ "$variable_name" =~ ^ALERT_SCRIPT_([1-9]|[1-9][0-9])(_EVENTS)?$ ]] && export "${variable_name?}"
      done < <(compgen -A variable ALERT_SCRIPT_)
    fi
    python3 "$SCRIPT_DIR/config.py" --base-dir "$SCRIPT_DIR" --profile "$profile" "$@"
  ) > "$output_file" || status=$?
  if (( status != 0 )); then
    rm -f "$output_file"
    return 1
  fi

  while IFS= read -r -d '' key; do
    if ! IFS= read -r -d '' value; then
      read_error="Configuration resolver returned an incomplete record."
      break
    fi
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      read_error="Configuration resolver returned an invalid key."
      break
    fi
    printf -v "$key" '%s' "$value"
  done < "$output_file"
  rm -f "$output_file"
  [[ -z "$read_error" ]] || { config_error "$read_error"; return 1; }
}

load_config() {
  apply_resolved_config monitor 0 --config "$ENV_FILE" --config-required --file-only
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
  python3 "$SCRIPT_DIR/monitor_utils.py" validate-number "$name" "$value" "$minimum" "$maximum"
}

has_control_characters() {
  [[ "$1" =~ [[:cntrl:]] ]]
}

validate_thresholds() {
  python3 "$SCRIPT_DIR/monitor_utils.py" validate-thresholds "$ALERT_THRESHOLDS"
}

validate_api_url() {
  python3 - "$SCRIPT_DIR" "$1" "$2" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from config import ConfigError, _http_url

try:
    _http_url(sys.argv[2], sys.argv[3])
except ConfigError as error:
    print(f"[ERROR] {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_alert_script_path() {
  local name="$1" path="$2" permissions
  if has_control_characters "$path" || [[ "$path" != /* || -L "$path" || ! -f "$path" || ! -x "$path" || ! -O "$path" ]]; then
    config_error "$name must be an executable, user-owned regular file that is not a symlink or group/world-writable."
    return 1
  fi
  permissions="$(stat -c '%a' -- "$path" 2>/dev/null)" || {
    config_error "$name must be an executable, user-owned regular file that is not a symlink or group/world-writable."
    return 1
  }
  if (( (8#$permissions & 8#022) != 0 )); then
    config_error "$name must be an executable, user-owned regular file that is not a symlink or group/world-writable."
    return 1
  fi
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
    if ! validate_alert_script_path "$path_name" "$path"; then
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
      action_id="$(python3 "$SCRIPT_DIR/monitor_utils.py" action-id "$path" "$event")"
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
  validate_api_url GITHUB_API_URL "$GITHUB_API_URL" || invalid=1
  validate_api_url TELEGRAM_API_URL "$TELEGRAM_API_URL" || invalid=1
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
  elif ! python3 "$SCRIPT_DIR/monitor_utils.py" check-tzdata
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

check_status_requirements() {
  local missing=0 codex_command="${CODEX_BIN:-codex}"
  if ! command -v "$codex_command" &>/dev/null; then
    echo "[ERROR] 'codex' command not found. Is OpenAI Codex CLI installed and in PATH?" >&2
    missing=1
  fi
  if ! command -v python3 &>/dev/null; then
    echo "[ERROR] 'python3' is required but not found." >&2
    missing=1
  elif ! python3 "$SCRIPT_DIR/monitor_utils.py" check-tzdata; then
    echo "[ERROR] Python >= 3.9 with Europe/Paris tzdata is required." >&2
    missing=1
  fi
  (( missing == 0 ))
}

configure_state_paths() {
  RUNTIME_DIR="$1"
  STATE_FILE="${RUNTIME_DIR}/.alert_state"
  DATA_FILE="${RUNTIME_DIR}/data.json"
  HISTORY_FILE="${RUNTIME_DIR}/history.json"
  ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
  HEALTH_FILE="${RUNTIME_DIR}/health.json"
  LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
}

initialize() {
  local config_path="$1" config_required="$2" state_override="$3" interval_override="$4"
  local codex_bin_override="${CODEX_BIN_OVERRIDE:-}" resolver_arguments=()
  umask 077
  if ! command -v python3 &>/dev/null; then
    config_error "python3 is required to load configuration."
    return 1
  fi
  if [[ -n "$config_path" ]]; then
    resolver_arguments+=(--config "$config_path")
    (( config_required == 0 )) || resolver_arguments+=(--config-required)
  fi
  [[ -z "$state_override" ]] || resolver_arguments+=(--set "STATE_DIR=${state_override}")
  [[ -z "$interval_override" ]] || resolver_arguments+=(--set "LOOP_INTERVAL=${interval_override}")
  apply_resolved_config monitor 1 "${resolver_arguments[@]}" || return 1
  if [[ -n "$codex_bin_override" ]]; then
    CODEX_BIN="$codex_bin_override"
  fi
  configure_state_paths "$STATE_DIR"
  check_requirements || return 1
  validate_config || return 1
  if [[ -e "$RUNTIME_DIR" && ( -L "$RUNTIME_DIR" || ! -d "$RUNTIME_DIR" || ! -O "$RUNTIME_DIR" ) ]]; then
    config_error "State directory must be a directory owned by the current user: $RUNTIME_DIR"
    return 1
  fi
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  [[ -w "$RUNTIME_DIR" ]] || { config_error "Runtime directory is not writable: $RUNTIME_DIR"; return 1; }
}

initialize_status() {
  local config_path="$1" config_required="$2" interval_override="$3"
  local codex_bin_override="${CODEX_BIN_OVERRIDE:-}" resolver_arguments=()
  umask 077
  if ! command -v python3 &>/dev/null; then
    config_error "python3 is required to load configuration."
    return 1
  fi
  if [[ -n "$config_path" ]]; then
    resolver_arguments+=(--config "$config_path")
    (( config_required == 0 )) || resolver_arguments+=(--config-required)
  fi
  [[ -z "$interval_override" ]] || resolver_arguments+=(--set "LOOP_INTERVAL=${interval_override}")
  apply_resolved_config status 1 "${resolver_arguments[@]}" || return 1
  if [[ -n "$codex_bin_override" ]]; then
    CODEX_BIN="$codex_bin_override"
  fi
  check_status_requirements
}

fetch_status_json() {
  local interval_seconds="$1"
  local codex_cmd="${CODEX_BIN:-codex}"
  local -a debug_option=()
  [[ "${MONITOR_DEBUG:-0}" == 1 ]] && debug_option+=(--debug)
  python3 "$SCRIPT_DIR/codex_status.py" \
    --codex-bin="$codex_cmd" \
    --timeout "${CODEX_STATUS_TIMEOUT_SECONDS:-20}" \
    --interval "$interval_seconds" \
    --history-window-hours "$HISTORY_RETENTION_HOURS" \
    "${debug_option[@]}"
}

json_get_field() {
  local json="$1"
  local field="$2"

  python3 "$SCRIPT_DIR/monitor_utils.py" json-get-field "$json" "$field"
}

timestamp_to_epoch() {
  local timestamp="$1"

  python3 "$SCRIPT_DIR/monitor_utils.py" timestamp-to-epoch "$timestamp"
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
  local interval_seconds="$2"
  : "$interval_seconds"

  printf '%s\n' "$json" | python3 "$SCRIPT_DIR/history.py" \
    --history "$HISTORY_FILE" \
    --data "$DATA_FILE" \
    --retention-hours "$HISTORY_RETENTION_HOURS"

  echo "[OK] Snapshot storage processed at ${DATA_FILE}"
}

load_thresholds() {
  python3 "$SCRIPT_DIR/monitor_utils.py" load-thresholds "$ALERT_THRESHOLDS"
}

# ============================================================================
# Optional: sync to GitHub Gist (Tier 2, external dashboard)
# ============================================================================
http_request() {
  local service="$1" expected_status="$2" curl_config="$3" method="$4" output_file="$5"
  shift 5
  local attempt=1 max_attempts=$((CURL_RETRIES + 1)) status="000" curl_status=0 delay=0
  local disposition error_file header_file telegram_confirmed=1 max_response_bytes=1048576
  [[ "$service" == "GitHub Gist" ]] && max_response_bytes=67108864
  error_file="$(mktemp "${RUNTIME_DIR}/.curl-error.XXXXXX")"
  header_file="$(mktemp "${RUNTIME_DIR}/.curl-headers.XXXXXX")"
  HTTP_LAST_RETRYABLE=0

  while (( attempt <= max_attempts )); do
    echo "[INFO] ${service}: delivery attempt ${attempt}/${max_attempts}."
    : > "$output_file"
    : > "$error_file"
    : > "$header_file"
    curl_status=0
    status="$(printf '%s\n' "$curl_config" | curl -q --config - --silent --show-error \
      --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" \
      --max-filesize "$max_response_bytes" \
      --request "$method" --output "$output_file" --dump-header "$header_file" \
      --write-out '%{http_code}' "$@" 2>"$error_file")" || curl_status=$?
    [[ "$status" =~ ^[0-9]{3}$ ]] || status=000
    telegram_confirmed=1
    if (( curl_status == 0 )) && [[ "$status" == "$expected_status" && "$service" == Telegram ]] \
      && ! python3 "$SCRIPT_DIR/alerts.py" telegram-delivered "$output_file"; then
      telegram_confirmed=0
    fi
    if (( curl_status == 0 && telegram_confirmed == 1 )) && [[ "$status" == "$expected_status" ]]; then
      echo "[OK] ${service}: delivered (HTTP ${status})."
      rm -f "$error_file" "$header_file"
      return 0
    fi
    read -r disposition delay < <(
      python3 "$SCRIPT_DIR/alerts.py" retry "$curl_status" "$((10#$status))" "$attempt" \
        "$CURL_RETRY_DELAY_SECONDS" 60 "$header_file"
    )
    if (( telegram_confirmed == 0 )); then
      disposition=permanent
      delay=0
    fi
    HTTP_LAST_RETRYABLE=0
    [[ "$disposition" == transient ]] && HTTP_LAST_RETRYABLE=1
    if [[ "$disposition" == transient ]] && (( attempt < max_attempts )); then
      echo "[WARN] ${service}: curl=${curl_status}, HTTP=${status}, attempt=${attempt}/${max_attempts}, retry_delay=${delay}s." >&2
      (( delay > 0 )) && sleep "$delay"
    else
      echo "[WARN] ${service}: curl=${curl_status}, HTTP=${status}, attempt=${attempt}/${max_attempts}, retry_delay=0s." >&2
      break
    fi
    ((attempt += 1))
  done
  rm -f "$error_file" "$header_file"
  return 1
}

sync_gist() {
  if [[ -z "${GITHUB_PAT:-}" || -z "${GITHUB_GIST_ID:-}" ]]; then
    return 0  # silently skip if not configured
  fi

  local payload_file
  payload_file="$(mktemp "${RUNTIME_DIR}/.gist-payload.XXXXXX")" || {
    echo "[ERROR] Could not create private Gist payload file." >&2
    return 1
  }
  if ! chmod 600 "$payload_file"; then
    rm -f "$payload_file"
    echo "[ERROR] Could not secure private Gist payload file." >&2
    return 1
  fi
  if ! python3 "$SCRIPT_DIR/monitor_utils.py" gist-payload-files \
    "$DATA_FILE" "$HISTORY_FILE" "$payload_file"; then
    rm -f "$payload_file"
    return 1
  fi
  if http_request "GitHub Gist" 200 \
    "url = \"${GITHUB_API_URL}/gists/${GITHUB_GIST_ID}\""$'\n'"header = \"Authorization: token ${GITHUB_PAT}\"" \
    PATCH /dev/null -H "Content-Type: application/json" --data-binary "@${payload_file}"; then
    rm -f "$payload_file"
    return 0
  fi
  rm -f "$payload_file"
  return 1
}

# ============================================================================
# Alerting — direct curl to Discord/Telegram, no server needed
# ============================================================================
send_discord() {
  local message="$1"
  local payload
  if [[ -z "${DISCORD_WEBHOOK:-}" ]]; then return; fi

  payload="$(python3 "$SCRIPT_DIR/monitor_utils.py" discord-payload "$message")"

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
  local alert_prefix="${2:-}" configured=0 delivered=0 channel_status channel_retryable
  echo "[ALERT] Detected: $message"
  if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    ((configured += 1))
    if [[ -n "$alert_prefix" ]]; then
      channel_status="${alert_prefix}_discord_status"
      channel_retryable="${alert_prefix}_discord_retryable"
    fi
    if [[ -z "$alert_prefix" || "${!channel_status}" == pending \
      || ( "${!channel_status}" == failed && "${!channel_retryable}" == 1 ) ]]; then
      if send_discord "$message"; then
        ((delivered += 1))
        [[ -z "$alert_prefix" ]] || record_alert_channel "$alert_prefix" discord delivered 0 || return 1
      else
        [[ -z "$alert_prefix" ]] || record_alert_channel "$alert_prefix" discord failed "$HTTP_LAST_RETRYABLE" || return 1
      fi
    elif [[ "${!channel_status}" == delivered ]]; then
      ((delivered += 1))
    fi
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    ((configured += 1))
    if [[ -n "$alert_prefix" ]]; then
      channel_status="${alert_prefix}_telegram_status"
      channel_retryable="${alert_prefix}_telegram_retryable"
    fi
    if [[ -z "$alert_prefix" || "${!channel_status}" == pending \
      || ( "${!channel_status}" == failed && "${!channel_retryable}" == 1 ) ]]; then
      if send_telegram "$message"; then
        ((delivered += 1))
        [[ -z "$alert_prefix" ]] || record_alert_channel "$alert_prefix" telegram delivered 0 || return 1
      else
        [[ -z "$alert_prefix" ]] || record_alert_channel "$alert_prefix" telegram failed "$HTTP_LAST_RETRYABLE" || return 1
      fi
    elif [[ "${!channel_status}" == delivered ]]; then
      ((delivered += 1))
    fi
  fi
  if (( configured == 0 )); then
    echo "[INFO] No alert channel configured; alert acknowledged locally."
    return 0
  fi
  (( delivered == configured ))
}

weekly_pace_vs_ideal() {
  local weekly_pct="$1"
  local weekly_reset_at="$2"
  local scraped_at_epoch="$3"
  python3 "$SCRIPT_DIR/monitor_utils.py" weekly-pace "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch"
}

percentage_below_full() {
  python3 "$SCRIPT_DIR/monitor_utils.py" percentage-below-full "$1"
}

csv_contains() {
  local list="$1" wanted="$2"
  [[ ",${list}," == *",${wanted},"* ]]
}

persist_alert_state() {
  if ! printf '%s\n' \
    'state_version=4' \
    "prev_5h_pct=${prev_5h_pct}" \
    "prev_weekly_pct=${prev_weekly_pct}" \
    "five_h_armed_reset_at=${five_h_armed_reset_at}" \
    "weekly_armed_reset_at=${weekly_armed_reset_at}" \
    "last_notified_5h_reset_at=${last_notified_5h_reset_at}" \
    "last_notified_weekly_reset_at=${last_notified_weekly_reset_at}" \
    "notified_5h_thresholds=${notified_5h_thresholds}" \
    "notified_weekly_thresholds=${notified_weekly_thresholds}" \
    "pending_5h_threshold=${pending_5h_threshold}" \
    "pending_weekly_threshold=${pending_weekly_threshold}" \
    "five_h_threshold_alert_id=${five_h_threshold_alert_id}" \
    "five_h_threshold_status=${five_h_threshold_status}" \
    "five_h_threshold_discord_status=${five_h_threshold_discord_status}" \
    "five_h_threshold_discord_retryable=${five_h_threshold_discord_retryable}" \
    "five_h_threshold_telegram_status=${five_h_threshold_telegram_status}" \
    "five_h_threshold_telegram_retryable=${five_h_threshold_telegram_retryable}" \
    "five_h_threshold_remaining_pct=${five_h_threshold_remaining_pct}" \
    "five_h_threshold_reset_label=${five_h_threshold_reset_label}" \
    "five_h_threshold_pace=${five_h_threshold_pace}" \
    "five_h_threshold_last_terminal_alert_id=${five_h_threshold_last_terminal_alert_id}" \
    "five_h_threshold_last_terminal_status=${five_h_threshold_last_terminal_status}" \
    "five_h_threshold_last_terminal_discord_status=${five_h_threshold_last_terminal_discord_status}" \
    "five_h_threshold_last_terminal_telegram_status=${five_h_threshold_last_terminal_telegram_status}" \
    "weekly_threshold_alert_id=${weekly_threshold_alert_id}" \
    "weekly_threshold_status=${weekly_threshold_status}" \
    "weekly_threshold_discord_status=${weekly_threshold_discord_status}" \
    "weekly_threshold_discord_retryable=${weekly_threshold_discord_retryable}" \
    "weekly_threshold_telegram_status=${weekly_threshold_telegram_status}" \
    "weekly_threshold_telegram_retryable=${weekly_threshold_telegram_retryable}" \
    "weekly_threshold_remaining_pct=${weekly_threshold_remaining_pct}" \
    "weekly_threshold_reset_label=${weekly_threshold_reset_label}" \
    "weekly_threshold_pace=${weekly_threshold_pace}" \
    "weekly_threshold_last_terminal_alert_id=${weekly_threshold_last_terminal_alert_id}" \
    "weekly_threshold_last_terminal_status=${weekly_threshold_last_terminal_status}" \
    "weekly_threshold_last_terminal_discord_status=${weekly_threshold_last_terminal_discord_status}" \
    "weekly_threshold_last_terminal_telegram_status=${weekly_threshold_last_terminal_telegram_status}" \
    "five_h_reset_alert_id=${five_h_reset_alert_id}" \
    "five_h_reset_status=${five_h_reset_status}" \
    "five_h_reset_discord_status=${five_h_reset_discord_status}" \
    "five_h_reset_discord_retryable=${five_h_reset_discord_retryable}" \
    "five_h_reset_telegram_status=${five_h_reset_telegram_status}" \
    "five_h_reset_telegram_retryable=${five_h_reset_telegram_retryable}" \
    "weekly_reset_alert_id=${weekly_reset_alert_id}" \
    "weekly_reset_status=${weekly_reset_status}" \
    "weekly_reset_discord_status=${weekly_reset_discord_status}" \
    "weekly_reset_discord_retryable=${weekly_reset_discord_retryable}" \
    "weekly_reset_telegram_status=${weekly_reset_telegram_status}" \
    "weekly_reset_telegram_retryable=${weekly_reset_telegram_retryable}" \
    "script_tracking_initialized=${script_tracking_initialized}" \
    "script_prev_5h_pct=${script_prev_5h_pct}" \
    "script_prev_weekly_pct=${script_prev_weekly_pct}" \
    "attempted_script_5h_actions=${attempted_script_5h_actions}" \
    "attempted_script_weekly_actions=${attempted_script_weekly_actions}" \
    "script_5h_reset_attempted_at=${script_5h_reset_attempted_at}" \
    "script_weekly_reset_attempted_at=${script_weekly_reset_attempted_at}" \
    "attempted_script_5h_reset_actions=${attempted_script_5h_reset_actions}" \
    "attempted_script_weekly_reset_actions=${attempted_script_weekly_reset_actions}" \
    | python3 "$SCRIPT_DIR/monitor_utils.py" atomic-write "$STATE_FILE"; then
    echo "[ERROR] Could not durably persist alert state at ${STATE_FILE}." >&2
    return 1
  fi
}

refresh_alert_status() {
  local prefix="$1" discord_name="${1}_discord_status" telegram_name="${1}_telegram_status"
  local status_name="${1}_status" next_status=pending
  if [[ "${!discord_name}" == delivered && "${!telegram_name}" == delivered ]]; then
    next_status=delivered
  elif [[ "${!discord_name}" == failed || "${!telegram_name}" == failed ]]; then
    next_status=failed
  fi
  printf -v "$status_name" '%s' "$next_status"
}

record_alert_channel() {
  local prefix="$1" channel="$2" result="$3" retryable="$4"
  printf -v "${prefix}_${channel}_status" '%s' "$result"
  printf -v "${prefix}_${channel}_retryable" '%s' "$retryable"
  refresh_alert_status "$prefix"
  if ! persist_alert_state; then
    echo "[ERROR] Could not persist ${channel} alert delivery state." >&2
    ALERT_PROCESSING_ERROR="alert state persistence failed"
    return 1
  fi
}

prepare_alert_delivery() {
  local prefix="$1" alert_id="$2" id_name="${1}_alert_id"
  if [[ "${!id_name}" == "$alert_id" ]]; then
    return 0
  fi
  printf -v "$id_name" '%s' "$alert_id"
  if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    printf -v "${prefix}_discord_status" '%s' pending
  else
    printf -v "${prefix}_discord_status" '%s' delivered
  fi
  printf -v "${prefix}_discord_retryable" '%s' 1
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf -v "${prefix}_telegram_status" '%s' pending
  else
    printf -v "${prefix}_telegram_status" '%s' delivered
  fi
  printf -v "${prefix}_telegram_retryable" '%s' 1
  refresh_alert_status "$prefix"
  persist_alert_state
}

attempt_alert_notification() {
  local prefix="$1" alert_id="$2" message="$3" status_name="${1}_status"
  prepare_alert_delivery "$prefix" "$alert_id" || return 1
  if send_alert "$message" "$prefix"; then
    # Test and integration overrides of send_alert retain their historical API.
    if [[ "${!status_name}" != delivered ]]; then
      [[ -z "${DISCORD_WEBHOOK:-}" ]] || record_alert_channel "$prefix" discord delivered 0 || return 1
      if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        record_alert_channel "$prefix" telegram delivered 0 || return 1
      fi
      refresh_alert_status "$prefix"
      persist_alert_state || return 1
    fi
    return 0
  fi
  local discord_status_name="${prefix}_discord_status" discord_retryable_name="${prefix}_discord_retryable"
  local telegram_status_name="${prefix}_telegram_status" telegram_retryable_name="${prefix}_telegram_retryable"
  if [[ ( "${!discord_status_name}" == delivered \
      || ( "${!discord_status_name}" == failed && "${!discord_retryable_name}" == 0 ) ) \
    && ( "${!telegram_status_name}" == delivered \
      || ( "${!telegram_status_name}" == failed && "${!telegram_retryable_name}" == 0 ) ) ]]; then
    # Permanent failures terminate this occurrence without claiming delivery.
    # A later threshold or cycle receives a new ID and fresh channel state.
    refresh_alert_status "$prefix"
    persist_alert_state || return 1
    return 2
  fi
  return 1
}

close_active_threshold_alert() {
  local prefix="$1" reason="$2" id_name="${1}_alert_id" status_name="${1}_status"
  local discord_name="${1}_discord_status" telegram_name="${1}_telegram_status"
  [[ -n "${!id_name}" ]] || return 0
  printf -v "$status_name" '%s' failed
  printf -v "${prefix}_last_terminal_alert_id" '%s' "${!id_name}"
  printf -v "${prefix}_last_terminal_status" '%s' failed
  printf -v "${prefix}_last_terminal_discord_status" '%s' "${!discord_name}"
  printf -v "${prefix}_last_terminal_telegram_status" '%s' "${!telegram_name}"
  echo "[WARN] Alert ${!id_name} closed as failed: ${reason}." >&2
  persist_alert_state
}

threshold_alert_message() {
  local prefix="$1" window="$2" threshold="$3"
  local remaining_name="${1}_remaining_pct" reset_name="${1}_reset_label" pace_name="${1}_pace"
  local pace_suffix=""
  [[ -z "${!pace_name}" ]] || pace_suffix=$'\n'"*Pace vs ideal:* ${!pace_name}"
  if [[ "$window" == 5h ]]; then
    printf '*Codex 5h limit at %s%% remaining* (crossed %s%% threshold). Resets at %s%s' \
      "${!remaining_name}" "$threshold" "${!reset_name}" "$pace_suffix"
  else
    printf '*Codex weekly limit at %s%% remaining* (crossed %s%% threshold). Resets %s%s' \
      "${!remaining_name}" "$threshold" "${!reset_name}" "$pace_suffix"
  fi
}

alert_id() {
  python3 "$SCRIPT_DIR/alerts.py" id "$@"
}

migrate_legacy_alert_delivery() {
  local legacy_version="$1" window state_window pending_name notified_name armed_name last_reset_name prefix occurrence migrated_id
  for window in 5h weekly; do
    [[ "$window" == 5h ]] && state_window=five_h || state_window=weekly
    pending_name="pending_${window}_threshold"
    notified_name="notified_${window}_thresholds"
    armed_name="${state_window}_armed_reset_at"
    prefix="${state_window}_threshold"
    if [[ -n "${!pending_name}" ]]; then
      occurrence="legacy-v${legacy_version}:${!armed_name}"
      migrated_id="$(alert_id threshold "$window" "${!pending_name}" "$occurrence")" || return 1
      printf -v "${prefix}_alert_id" '%s' "$migrated_id"
      printf -v "${prefix}_discord_status" '%s' "$([[ -n "${DISCORD_WEBHOOK:-}" ]] && printf pending || printf delivered)"
      printf -v "${prefix}_telegram_status" '%s' "$([[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && printf pending || printf delivered)"
      printf -v "${prefix}_discord_retryable" '%s' 1
      printf -v "${prefix}_telegram_retryable" '%s' 1
      refresh_alert_status "$prefix"
    elif [[ -n "${!notified_name}" ]]; then
      migrated_id="$(alert_id legacy-threshold "$window" "${!notified_name}" "${!armed_name}")" || return 1
      printf -v "${prefix}_alert_id" '%s' "$migrated_id"
      printf -v "${prefix}_status" '%s' delivered
      printf -v "${prefix}_discord_status" '%s' delivered
      printf -v "${prefix}_telegram_status" '%s' delivered
      printf -v "${prefix}_discord_retryable" '%s' 0
      printf -v "${prefix}_telegram_retryable" '%s' 0
    fi

    last_reset_name="last_notified_${window}_reset_at"
    prefix="${state_window}_reset"
    if (( ${!last_reset_name} > 0 )); then
      migrated_id="$(alert_id reset "$window" reset "${!last_reset_name}")" || return 1
      printf -v "${prefix}_alert_id" '%s' "$migrated_id"
      printf -v "${prefix}_status" '%s' delivered
      printf -v "${prefix}_discord_status" '%s' delivered
      printf -v "${prefix}_telegram_status" '%s' delivered
      printf -v "${prefix}_discord_retryable" '%s' 0
      printf -v "${prefix}_telegram_retryable" '%s' 0
    fi
  done
}

migrate_alert_state_v1() { migrate_legacy_alert_delivery 1; }
migrate_alert_state_v2() { migrate_legacy_alert_delivery 2; }
migrate_alert_state_v3() { migrate_legacy_alert_delivery 3; }

repair_v4_pending_threshold() {
  local window="$1" state_window pending_name prefix id_name status_name
  local discord_name telegram_name discord_retryable_name telegram_retryable_name
  local id_seen_name status_seen_name discord_seen_name telegram_seen_name
  local discord_retryable_seen_name telegram_retryable_seen_name
  local discord_configured=0 telegram_configured=0 needs_repair=0 occurrence migrated_id armed_name

  [[ "$window" == 5h ]] && state_window=five_h || state_window=weekly
  pending_name="pending_${window}_threshold"
  prefix="${state_window}_threshold"
  id_name="${prefix}_alert_id"
  status_name="${prefix}_status"
  discord_name="${prefix}_discord_status"
  telegram_name="${prefix}_telegram_status"
  discord_retryable_name="${prefix}_discord_retryable"
  telegram_retryable_name="${prefix}_telegram_retryable"
  id_seen_name="${id_name}_seen"
  status_seen_name="${status_name}_seen"
  discord_seen_name="${discord_name}_seen"
  telegram_seen_name="${telegram_name}_seen"
  discord_retryable_seen_name="${discord_retryable_name}_seen"
  telegram_retryable_seen_name="${telegram_retryable_name}_seen"
  armed_name="${state_window}_armed_reset_at"

  [[ -n "${DISCORD_WEBHOOK:-}" ]] && discord_configured=1
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && telegram_configured=1

  [[ "${!pending_name}" =~ ^[0-9]+$ ]] || return 0
  if [[ "${!id_name}" != "" && "${!id_name}" =~ ^[a-f0-9]{24}$ ]] \
    && (( ${!id_seen_name} == 1 )); then
    :
  else
    needs_repair=1
    occurrence="v4-recovery:${!armed_name}:${!pending_name}"
    migrated_id="$(alert_id threshold "$window" "${!pending_name}" "$occurrence")" \
      || return 1
    printf -v "$id_name" '%s' "$migrated_id"
  fi

  if (( discord_configured == 1 )) \
    && (( ${!discord_seen_name} != 1 || ${!discord_retryable_seen_name} != 1 )); then
    needs_repair=1
  fi
  if (( telegram_configured == 1 )) \
    && (( ${!telegram_seen_name} != 1 || ${!telegram_retryable_seen_name} != 1 )); then
    needs_repair=1
  fi
  if (( discord_configured == 0 )) \
    && [[ "${!discord_name}" != delivered || "${!discord_retryable_name}" != 0 ]]; then
    needs_repair=1
  fi
  if (( telegram_configured == 0 )) \
    && [[ "${!telegram_name}" != delivered || "${!telegram_retryable_name}" != 0 ]]; then
    needs_repair=1
  fi
  (( ${!status_seen_name} != 1 )) && needs_repair=1

  if (( needs_repair == 1 )); then
    if (( discord_configured == 1 )); then
      printf -v "$discord_name" '%s' pending
      printf -v "$discord_retryable_name" '%s' 1
    else
      printf -v "$discord_name" '%s' delivered
      printf -v "$discord_retryable_name" '%s' 0
    fi
    if (( telegram_configured == 1 )); then
      printf -v "$telegram_name" '%s' pending
      printf -v "$telegram_retryable_name" '%s' 1
    else
      printf -v "$telegram_name" '%s' delivered
      printf -v "$telegram_retryable_name" '%s' 0
    fi
    refresh_alert_status "$prefix"
    persist_alert_state || return 1
  fi
}

repair_v4_reset() {
  local window="$1" scraped_at_epoch="$2" state_window prefix id_name status_name
  local discord_name telegram_name discord_retryable_name telegram_retryable_name
  local id_seen_name status_seen_name discord_seen_name telegram_seen_name
  local discord_retryable_seen_name telegram_retryable_seen_name armed_name last_notified_name
  local state_seen_name
  local discord_configured=0 telegram_configured=0 needs_repair=0 occurrence_epoch="" max_age
  local migrated_id

  [[ "$window" == 5h ]] && state_window=five_h || state_window=weekly
  prefix="${state_window}_reset"
  id_name="${prefix}_alert_id"
  status_name="${prefix}_status"
  discord_name="${prefix}_discord_status"
  telegram_name="${prefix}_telegram_status"
  discord_retryable_name="${prefix}_discord_retryable"
  telegram_retryable_name="${prefix}_telegram_retryable"
  id_seen_name="${id_name}_seen"
  status_seen_name="${status_name}_seen"
  discord_seen_name="${discord_name}_seen"
  telegram_seen_name="${telegram_name}_seen"
  discord_retryable_seen_name="${discord_retryable_name}_seen"
  telegram_retryable_seen_name="${telegram_retryable_name}_seen"
  armed_name="${state_window}_armed_reset_at"
  last_notified_name="last_notified_${window}_reset_at"
  state_seen_name="${state_window}_reset_state_seen"

  [[ -n "${DISCORD_WEBHOOK:-}" ]] && discord_configured=1
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && telegram_configured=1
  [[ "$window" == 5h ]] && max_age=$((5 * 60 * 60)) || max_age=$((7 * 24 * 60 * 60))

  # A reset occurrence is recoverable from its stable deadline, its durable
  # last-notified marker, or an existing v4 alert ID.  A blank fresh state is
  # intentionally left alone so it cannot invent a reset notification.
  if [[ "${!armed_name}" =~ ^[0-9]+$ ]] && (( ${!armed_name} > 0 )) \
    && (( scraped_at_epoch >= ${!armed_name} )) \
    && (( scraped_at_epoch - ${!armed_name} <= max_age )) \
    && [[ "${!last_notified_name}" != "${!armed_name}" ]]; then
    occurrence_epoch="${!armed_name}"
  elif [[ "${!last_notified_name}" =~ ^[0-9]+$ ]] && (( ${!last_notified_name} > 0 )); then
    occurrence_epoch="${!last_notified_name}"
  elif (( ${!id_seen_name} == 1 )) && [[ -n "${!id_name}" ]]; then
    needs_repair=1
  elif (( ${!state_seen_name} == 1 )) \
    && (( ${!id_seen_name} != 1 || ${!status_seen_name} != 1 \
      || ${!discord_seen_name} != 1 || ${!telegram_seen_name} != 1 \
      || ${!discord_retryable_seen_name} != 1 || ${!telegram_retryable_seen_name} != 1 )); then
    # There is damaged reset state but no recoverable deadline. Keep the
    # occurrence pending and make its fallback ID stable across retries.
    occurrence_epoch="$scraped_at_epoch"
  else
    return 0
  fi

  if [[ -n "$occurrence_epoch" ]] \
    && ! { (( ${!id_seen_name} == 1 )) && [[ "${!id_name}" =~ ^[a-f0-9]{24}$ ]]; }; then
    migrated_id="$(alert_id reset "$window" reset "$occurrence_epoch")" || return 1
    printf -v "$id_name" '%s' "$migrated_id"
    needs_repair=1
  fi

  if (( discord_configured == 1 )) \
    && (( ${!discord_seen_name} != 1 || ${!discord_retryable_seen_name} != 1 )); then
    needs_repair=1
  fi
  if (( telegram_configured == 1 )) \
    && (( ${!telegram_seen_name} != 1 || ${!telegram_retryable_seen_name} != 1 )); then
    needs_repair=1
  fi
  if (( discord_configured == 0 )) \
    && [[ "${!discord_name}" != delivered || "${!discord_retryable_name}" != 0 ]]; then
    needs_repair=1
  fi
  if (( telegram_configured == 0 )) \
    && [[ "${!telegram_name}" != delivered || "${!telegram_retryable_name}" != 0 ]]; then
    needs_repair=1
  fi
  (( ${!status_seen_name} != 1 )) && needs_repair=1

  if (( needs_repair == 1 )); then
    if (( discord_configured == 1 )); then
      printf -v "$discord_name" '%s' pending
      printf -v "$discord_retryable_name" '%s' 1
    else
      printf -v "$discord_name" '%s' delivered
      printf -v "$discord_retryable_name" '%s' 0
    fi
    if (( telegram_configured == 1 )); then
      printf -v "$telegram_name" '%s' pending
      printf -v "$telegram_retryable_name" '%s' 1
    else
      printf -v "$telegram_name" '%s' delivered
      printf -v "$telegram_retryable_name" '%s' 0
    fi
    refresh_alert_status "$prefix"
    persist_alert_state || return 1
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
  local state_version=1
  local five_h_threshold_alert_id="" five_h_threshold_status=delivered
  local five_h_threshold_discord_status=delivered five_h_threshold_discord_retryable=0
  local five_h_threshold_telegram_status=delivered five_h_threshold_telegram_retryable=0
  # These state-presence flags are read through dynamically built variable names
  # by the v4 repair helpers below.
  # shellcheck disable=SC2034
  local five_h_threshold_alert_id_seen=0 five_h_threshold_status_seen=0
  # shellcheck disable=SC2034
  local five_h_threshold_discord_status_seen=0 five_h_threshold_telegram_status_seen=0
  # shellcheck disable=SC2034
  local five_h_threshold_discord_retryable_seen=0 five_h_threshold_telegram_retryable_seen=0
  local five_h_threshold_remaining_pct="" five_h_threshold_reset_label="" five_h_threshold_pace=""
  local five_h_threshold_last_terminal_alert_id="" five_h_threshold_last_terminal_status=""
  local five_h_threshold_last_terminal_discord_status="" five_h_threshold_last_terminal_telegram_status=""
  local weekly_threshold_alert_id="" weekly_threshold_status=delivered
  local weekly_threshold_discord_status=delivered weekly_threshold_discord_retryable=0
  local weekly_threshold_telegram_status=delivered weekly_threshold_telegram_retryable=0
  # shellcheck disable=SC2034
  local weekly_threshold_alert_id_seen=0 weekly_threshold_status_seen=0
  # shellcheck disable=SC2034
  local weekly_threshold_discord_status_seen=0 weekly_threshold_telegram_status_seen=0
  # shellcheck disable=SC2034
  local weekly_threshold_discord_retryable_seen=0 weekly_threshold_telegram_retryable_seen=0
  local weekly_threshold_remaining_pct="" weekly_threshold_reset_label="" weekly_threshold_pace=""
  local weekly_threshold_last_terminal_alert_id="" weekly_threshold_last_terminal_status=""
  local weekly_threshold_last_terminal_discord_status="" weekly_threshold_last_terminal_telegram_status=""
  local five_h_reset_alert_id="" five_h_reset_status=delivered
  local five_h_reset_discord_status=delivered five_h_reset_discord_retryable=0
  local five_h_reset_telegram_status=delivered five_h_reset_telegram_retryable=0
  # shellcheck disable=SC2034
  local five_h_reset_alert_id_seen=0 five_h_reset_status_seen=0
  # shellcheck disable=SC2034
  local five_h_reset_discord_status_seen=0 five_h_reset_telegram_status_seen=0
  # shellcheck disable=SC2034
  local five_h_reset_discord_retryable_seen=0 five_h_reset_telegram_retryable_seen=0
  # shellcheck disable=SC2034
  local five_h_reset_state_seen=0
  local weekly_reset_alert_id="" weekly_reset_status=delivered
  local weekly_reset_discord_status=delivered weekly_reset_discord_retryable=0
  local weekly_reset_telegram_status=delivered weekly_reset_telegram_retryable=0
  # shellcheck disable=SC2034
  local weekly_reset_alert_id_seen=0 weekly_reset_status_seen=0
  # shellcheck disable=SC2034
  local weekly_reset_discord_status_seen=0 weekly_reset_telegram_status_seen=0
  # shellcheck disable=SC2034
  local weekly_reset_discord_retryable_seen=0 weekly_reset_telegram_retryable_seen=0
  # shellcheck disable=SC2034
  local weekly_reset_state_seen=0
  local script_tracking_initialized=0
  local script_prev_5h_pct=100
  local script_prev_weekly_pct=100
  local attempted_script_5h_actions=""
  local attempted_script_weekly_actions=""
  local script_5h_reset_attempted_at=0
  local script_weekly_reset_attempted_at=0
  local attempted_script_5h_reset_actions=""
  local attempted_script_weekly_reset_actions=""
  local thresholds state_key state_value pace pace_suffix t critical status=0 reset_age rule_position script_threshold current_alert_id
  local alert_result pending_before new_threshold message
  local due_5h_reset_at=0 due_weekly_reset_at=0 script_state_error=0 initialize_script_baseline=0
  local -a script_thresholds=()
  ALERT_PROCESSING_ERROR=""
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
        five_h_reset_alert_id|five_h_reset_status|five_h_reset_discord_status|five_h_reset_discord_retryable|five_h_reset_telegram_status|five_h_reset_telegram_retryable)
          # shellcheck disable=SC2034
          five_h_reset_state_seen=1
          ;;
        weekly_reset_alert_id|weekly_reset_status|weekly_reset_discord_status|weekly_reset_discord_retryable|weekly_reset_telegram_status|weekly_reset_telegram_retryable)
          # shellcheck disable=SC2034
          weekly_reset_state_seen=1
          ;;
      esac
      case "$state_key" in
        state_version)
          [[ "$state_value" =~ ^[1-4]$ ]] && state_version="$state_value"
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
        five_h_threshold_alert_id|weekly_threshold_alert_id|five_h_reset_alert_id|weekly_reset_alert_id)
          if [[ -z "$state_value" || "$state_value" =~ ^[a-f0-9]{24}$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
            case "$state_key" in
              five_h_threshold_alert_id|weekly_threshold_alert_id)
                printf -v "${state_key}_seen" '%s' 1
                ;;
              five_h_reset_alert_id|weekly_reset_alert_id)
                printf -v "${state_key}_seen" '%s' 1
                ;;
            esac
          fi
          ;;
        five_h_threshold_last_terminal_alert_id|weekly_threshold_last_terminal_alert_id)
          [[ -z "$state_value" || "$state_value" =~ ^[a-f0-9]{24}$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        five_h_threshold_status|weekly_threshold_status|five_h_reset_status|weekly_reset_status|five_h_threshold_discord_status|five_h_threshold_telegram_status|weekly_threshold_discord_status|weekly_threshold_telegram_status|five_h_reset_discord_status|five_h_reset_telegram_status|weekly_reset_discord_status|weekly_reset_telegram_status)
          if [[ "$state_value" == pending || "$state_value" == delivered || "$state_value" == failed ]]; then
            printf -v "$state_key" '%s' "$state_value"
            case "$state_key" in
              five_h_threshold_status|weekly_threshold_status|five_h_threshold_discord_status|five_h_threshold_telegram_status|weekly_threshold_discord_status|weekly_threshold_telegram_status)
                printf -v "${state_key}_seen" '%s' 1
                ;;
              five_h_reset_status|weekly_reset_status|five_h_reset_discord_status|five_h_reset_telegram_status|weekly_reset_discord_status|weekly_reset_telegram_status)
                printf -v "${state_key}_seen" '%s' 1
                ;;
            esac
          fi
          ;;
        five_h_threshold_last_terminal_status|weekly_threshold_last_terminal_status|five_h_threshold_last_terminal_discord_status|five_h_threshold_last_terminal_telegram_status|weekly_threshold_last_terminal_discord_status|weekly_threshold_last_terminal_telegram_status)
          [[ -z "$state_value" || "$state_value" == pending || "$state_value" == delivered || "$state_value" == failed ]] \
            && printf -v "$state_key" '%s' "$state_value"
          ;;
        five_h_threshold_remaining_pct|weekly_threshold_remaining_pct)
          [[ -z "$state_value" || "$state_value" =~ ^([0-9]+([.][0-9]+)?)$ ]] && printf -v "$state_key" '%s' "$state_value"
          ;;
        five_h_threshold_reset_label|weekly_threshold_reset_label|five_h_threshold_pace|weekly_threshold_pace)
          printf -v "$state_key" '%s' "$state_value"
          ;;
        five_h_threshold_discord_retryable|five_h_threshold_telegram_retryable|weekly_threshold_discord_retryable|weekly_threshold_telegram_retryable|five_h_reset_discord_retryable|five_h_reset_telegram_retryable|weekly_reset_discord_retryable|weekly_reset_telegram_retryable)
          if [[ "$state_value" == 0 || "$state_value" == 1 ]]; then
            printf -v "$state_key" '%s' "$state_value"
            case "$state_key" in
              five_h_threshold_discord_retryable|five_h_threshold_telegram_retryable|weekly_threshold_discord_retryable|weekly_threshold_telegram_retryable)
                printf -v "${state_key}_seen" '%s' 1
                ;;
              five_h_reset_discord_retryable|five_h_reset_telegram_retryable|weekly_reset_discord_retryable|weekly_reset_telegram_retryable)
                printf -v "${state_key}_seen" '%s' 1
                ;;
            esac
          fi
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

  case "$state_version" in
    1) migrate_alert_state_v1 || return 1 ;;
    2) migrate_alert_state_v2 || return 1 ;;
    3) migrate_alert_state_v3 || return 1 ;;
  esac

  if (( state_version == 4 )); then
    repair_v4_pending_threshold 5h || return 1
    repair_v4_pending_threshold weekly || return 1
    repair_v4_reset 5h "$scraped_at_epoch" || return 1
    repair_v4_reset weekly "$scraped_at_epoch" || return 1
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
      current_alert_id="$(alert_id reset 5h reset "$five_h_armed_reset_at")"
      if attempt_alert_notification five_h_reset "$current_alert_id" \
        "*Codex 5h limit reset.* A new usage cycle is available."; then
        alert_result=0
      else
        alert_result=$?
      fi
      if (( alert_result == 0 )); then
        last_notified_5h_reset_at="$five_h_armed_reset_at"
      elif (( alert_result == 2 )); then
        last_notified_5h_reset_at="$five_h_armed_reset_at"
        status=1
        ALERT_PROCESSING_ERROR="alert delivery failed permanently"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    fi
    if (( reset_age > 5 * 60 * 60 || last_notified_5h_reset_at == five_h_armed_reset_at )); then
      five_h_armed_reset_at=0
      notified_5h_thresholds=""
      pending_5h_threshold=""
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
      current_alert_id="$(alert_id reset weekly reset "$weekly_armed_reset_at")"
      if attempt_alert_notification weekly_reset "$current_alert_id" \
        "*Codex weekly limit reset.* A new usage cycle is available."; then
        alert_result=0
      else
        alert_result=$?
      fi
      if (( alert_result == 0 )); then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
      elif (( alert_result == 2 )); then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
        status=1
        ALERT_PROCESSING_ERROR="alert delivery failed permanently"
      else
        status=1
        ALERT_PROCESSING_ERROR="alert delivery pending"
      fi
    fi
    if (( reset_age > 7 * 24 * 60 * 60 || last_notified_weekly_reset_at == weekly_armed_reset_at )); then
      weekly_armed_reset_at=0
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
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
    pending_before="$pending_5h_threshold"
    critical="$pending_5h_threshold"
    new_threshold=""
    for t in "${thresholds[@]}"; do
      if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-crossed \
        "$five_h_pct" "$prev_5h_pct" "$t" "$notified_5h_thresholds"
      then
        if [[ -z "$critical" || t -lt critical ]]; then
          critical="$t"
          [[ -z "$pending_before" || t -lt pending_before ]] && new_threshold=1
        elif [[ -z "$pending_before" ]]; then
          new_threshold=1
        fi
      fi
    done
    if [[ -n "$critical" ]]; then
      if [[ -n "$new_threshold" ]]; then
        if [[ -n "$five_h_threshold_alert_id" && "$five_h_threshold_status" != delivered ]]; then
          close_active_threshold_alert five_h_threshold "superseded by ${critical}% threshold" || return 1
        fi
        five_h_threshold_remaining_pct="$five_h_pct"
        five_h_threshold_reset_label="$five_h_reset"
        five_h_threshold_pace="$pace"
        current_alert_id="$(alert_id threshold 5h "$critical" "${five_h_armed_reset_at}:${scraped_at_epoch}")"
      else
        current_alert_id="$five_h_threshold_alert_id"
        if [[ -z "$five_h_threshold_remaining_pct" ]]; then
          five_h_threshold_remaining_pct="$five_h_pct"
          five_h_threshold_reset_label="$five_h_reset"
          five_h_threshold_pace="$pace"
        fi
      fi
      pending_5h_threshold="$critical"
      message="$(threshold_alert_message five_h_threshold 5h "$critical")"
      if attempt_alert_notification five_h_threshold "$current_alert_id" "$message"; then
        alert_result=0
      else
        alert_result=$?
      fi
      if (( alert_result == 0 || alert_result == 2 )); then
        local notified="${notified_5h_thresholds}"
        for t in "${thresholds[@]}"; do
          if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-between "$prev_5h_pct" "$critical" "$t"
          then
            [[ ",${notified}," == *",${t},"* ]] || notified="${notified:+${notified},}${t}"
          fi
        done
        notified_5h_thresholds="$notified"
        pending_5h_threshold=""
        prev_5h_pct="$five_h_pct"
        if (( alert_result == 2 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert delivery failed permanently"
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
    pending_before="$pending_weekly_threshold"
    critical="$pending_weekly_threshold"
    new_threshold=""
    for t in "${thresholds[@]}"; do
      if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-crossed \
        "$weekly_pct" "$prev_weekly_pct" "$t" "$notified_weekly_thresholds"
      then
        if [[ -z "$critical" || t -lt critical ]]; then
          critical="$t"
          [[ -z "$pending_before" || t -lt pending_before ]] && new_threshold=1
        elif [[ -z "$pending_before" ]]; then
          new_threshold=1
        fi
      fi
    done
    if [[ -n "$critical" ]]; then
      if [[ -n "$new_threshold" ]]; then
        if [[ -n "$weekly_threshold_alert_id" && "$weekly_threshold_status" != delivered ]]; then
          close_active_threshold_alert weekly_threshold "superseded by ${critical}% threshold" || return 1
        fi
        weekly_threshold_remaining_pct="$weekly_pct"
        weekly_threshold_reset_label="$weekly_reset"
        weekly_threshold_pace="$pace"
        current_alert_id="$(alert_id threshold weekly "$critical" "${weekly_armed_reset_at}:${scraped_at_epoch}")"
      else
        current_alert_id="$weekly_threshold_alert_id"
        if [[ -z "$weekly_threshold_remaining_pct" ]]; then
          weekly_threshold_remaining_pct="$weekly_pct"
          weekly_threshold_reset_label="$weekly_reset"
          weekly_threshold_pace="$pace"
        fi
      fi
      pending_weekly_threshold="$critical"
      message="$(threshold_alert_message weekly_threshold weekly "$critical")"
      if attempt_alert_notification weekly_threshold "$current_alert_id" "$message"; then
        alert_result=0
      else
        alert_result=$?
      fi
      if (( alert_result == 0 || alert_result == 2 )); then
        local notified="${notified_weekly_thresholds}"
        for t in "${thresholds[@]}"; do
          if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-between "$prev_weekly_pct" "$critical" "$t"
          then
            [[ ",${notified}," == *",${t},"* ]] || notified="${notified:+${notified},}${t}"
          fi
        done
        notified_weekly_thresholds="$notified"
        pending_weekly_threshold=""
        prev_weekly_pct="$weekly_pct"
        if (( alert_result == 2 )); then
          status=1
          ALERT_PROCESSING_ERROR="alert delivery failed permanently"
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
        if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-crossed \
          "$five_h_pct" "$script_prev_5h_pct" "$script_threshold"
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
        if python3 "$SCRIPT_DIR/monitor_utils.py" threshold-crossed \
          "$weekly_pct" "$script_prev_weekly_pct" "$script_threshold"
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
  python3 "$SCRIPT_DIR/monitor_utils.py" update-health "$HEALTH_FILE" "$result" "$detail" "$duration_ms"
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

  local json status=0
  CYCLE_ERROR=""
  if json=$(fetch_status_json "$interval_seconds"); then
    echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"
    if ! archive_snapshot "$json"; then
      status=1
      append_cycle_error "Long-term archive update failed"
    fi
    if write_local_snapshot "$json" "$interval_seconds"; then
      sync_gist || { status=1; append_cycle_error "GitHub Gist sync failed"; }
    else
      status=1
      append_cycle_error "Local snapshot write failed"
    fi

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

usage() {
  cat <<'EOF'
Usage: ./monitor.sh [MODE] [OPTIONS]

Collect Codex limits and local token usage.

Modes:
  --once                 Run one collection cycle (default)
  --loop [SECONDS]       Run now, then on aligned intervals
  --check                Validate configuration, runtime and Codex access
  --status-json          Print the Codex limit response as JSON

Options:
  --fail-fast            In loop mode, exit after the first failed cycle
  --config FILE          Read configuration from FILE
  --state-dir DIRECTORY  Store runtime state in DIRECTORY
  -h, --help             Show this help without contacting Codex

Configuration priority is CLI, environment, .env, then defaults. Source
checkouts default to local/.env and local/runtime; installed commands use
XDG_CONFIG_HOME and XDG_STATE_HOME (or their standard user defaults).
EOF
}

seconds_until_next_interval() {
  local now_epoch="$1"
  local interval="$2"
  printf '%s\n' "$((interval - now_epoch % interval))"
}

main() {
  local interval mode=once fail_fast=0 now_epoch delay next_epoch next_check
  local config_path="" config_required=0 state_override="" interval_override=""
  [[ "$ENV_FILE" == "$SOURCE_ENV_FILE" ]] || config_path="$ENV_FILE"
  [[ "$RUNTIME_DIR" == "$SOURCE_RUNTIME_DIR" ]] || state_override="$RUNTIME_DIR"

  while (( $# > 0 )); do
    case "$1" in
      --loop)
        mode=loop
        if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
          interval_override="$2"
          shift
        fi
        ;;
      --status-json) mode=status_json ;;
      --check) mode=check ;;
      --fail-fast) fail_fast=1 ;;
      --once) mode=once ;;
      --config)
        (( $# >= 2 )) || { config_error "--config requires a value."; return 1; }
        config_path="$2"
        config_required=1
        shift
        ;;
      --state-dir)
        (( $# >= 2 )) || { config_error "--state-dir requires a value."; return 1; }
        state_override="$2"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *) config_error "Unknown argument: $1"; return 1 ;;
    esac
    shift
  done

  [[ -z "$interval_override" ]] || validate_interval "$interval_override" || return 1
  if [[ "$mode" == status_json ]]; then
    initialize_status "$config_path" "$config_required" "$interval_override" || return 1
  else
    initialize "$config_path" "$config_required" "$state_override" "$interval_override" || return 1
  fi
  interval="$LOOP_INTERVAL"
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
