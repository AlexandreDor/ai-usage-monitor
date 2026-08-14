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
ALERT_DELIVERIES_FILE="${RUNTIME_DIR}/alert-deliveries.json"
ALERTS_PY="${SCRIPT_DIR}/alerts.py"
HISTORY_PY="${SCRIPT_DIR}/history.py"
DATA_FILE="${RUNTIME_DIR}/data.json"
HISTORY_FILE="${RUNTIME_DIR}/history.json"
ARCHIVE_FILE="${RUNTIME_DIR}/usage-history.sqlite3"
HEALTH_FILE="${RUNTIME_DIR}/health.json"
HEARTBEAT_FILE="${RUNTIME_DIR}/dashboard-heartbeat"
LOCK_FILE="${RUNTIME_DIR}/.monitor.lock"
DEFAULT_INTERVAL_SECONDS=900
DEFAULT_DASHBOARD_ACTIVE_INTERVAL_SECONDS=300
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

load_config() {
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" != *=* ]]; then
      echo "[WARN] Ignoring malformed configuration line." >&2
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "[WARN] Ignoring invalid configuration key." >&2
      continue
    fi

    case "$key" in
      ALERT_THRESHOLDS|ALERT_SCRIPT_TIMEOUT_SECONDS|ARCHIVE_RETENTION_DAYS|CODEX_BIN|CODEX_DATA_DIR|CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD|CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD|CODEX_FORECAST_ENABLED|CODEX_STATUS_TIMEOUT_SECONDS|CURL_CONNECT_TIMEOUT_SECONDS|CURL_MAX_TIME_SECONDS|CURL_RETRIES|CURL_RETRY_DELAY_SECONDS|DASHBOARD_ACTIVE_INTERVAL_SECONDS|DISCORD_WEBHOOK|GITHUB_API_URL|GITHUB_GIST_ID|GITHUB_PAT|HERMES_DB_PATH|HISTORY_RETENTION_HOURS|LOOP_INTERVAL|MONITOR_DEBUG|OPENCODE_DB_PATH|TELEGRAM_API_URL|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TOKEN_PRICING_FILE|TOKEN_USAGE_SOURCES)
        if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
          value="${value:1:${#value}-2}"
        fi
        printf -v "$key" '%s' "$value"
        ;;
      *)
        if [[ "$key" =~ ^ALERT_SCRIPT_([1-9]|[1-9][0-9])(_EVENTS)?$ ]]; then
          if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
            value="${value:1:${#value}-2}"
          fi
          printf -v "$key" '%s' "$value"
        else
          echo "[WARN] Ignoring unsupported configuration key: $key" >&2
          [[ "$key" == ALERT_SCRIPT_* ]] && INVALID_ALERT_SCRIPT_CONFIG=1
        fi
        ;;
    esac
  done < "$ENV_FILE"
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
  validate_integer DASHBOARD_ACTIVE_INTERVAL_SECONDS "$DASHBOARD_ACTIVE_INTERVAL_SECONDS" 30 86400 || invalid=1
  validate_integer CODEX_STATUS_TIMEOUT_SECONDS "$CODEX_STATUS_TIMEOUT_SECONDS" 5 300 || invalid=1
  validate_integer ARCHIVE_RETENTION_DAYS "$ARCHIVE_RETENTION_DAYS" 0 36500 || invalid=1
  validate_number HISTORY_RETENTION_HOURS "$HISTORY_RETENTION_HOURS" 0.25 8760 || invalid=1
  validate_integer CURL_CONNECT_TIMEOUT_SECONDS "$CURL_CONNECT_TIMEOUT_SECONDS" 1 60 || invalid=1
  validate_integer CURL_MAX_TIME_SECONDS "$CURL_MAX_TIME_SECONDS" 1 600 || invalid=1
  validate_integer CURL_RETRIES "$CURL_RETRIES" 0 5 || invalid=1
  validate_integer CURL_RETRY_DELAY_SECONDS "$CURL_RETRY_DELAY_SECONDS" 0 60 || invalid=1
  validate_integer CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD "$CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD" 0 100 || invalid=1
  validate_integer CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD "$CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD" 0 100 || invalid=1
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
  [[ "$CODEX_FORECAST_ENABLED" == 0 || "$CODEX_FORECAST_ENABLED" == 1 ]] || { config_error "CODEX_FORECAST_ENABLED must be 0 or 1." || true; invalid=1; }
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
  if [[ -f "$ENV_FILE" ]]; then
    if [[ -L "$ENV_FILE" || ! -O "$ENV_FILE" ]]; then
      config_error ".env must be a regular file owned by the current user."
      return 1
    fi
    chmod 600 "$ENV_FILE"
    load_config
  fi

  if [[ -n "$codex_bin_override" ]]; then
    CODEX_BIN="$codex_bin_override"
  fi

  ALERT_THRESHOLDS="${ALERT_THRESHOLDS:-75,50,25,10,5}"
  ALERT_SCRIPT_TIMEOUT_SECONDS="${ALERT_SCRIPT_TIMEOUT_SECONDS:-30}"
  ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-365}"
  HISTORY_RETENTION_HOURS="${HISTORY_RETENTION_HOURS:-192}"
  LOOP_INTERVAL="${LOOP_INTERVAL:-$DEFAULT_INTERVAL_SECONDS}"
  DASHBOARD_ACTIVE_INTERVAL_SECONDS="${DASHBOARD_ACTIVE_INTERVAL_SECONDS:-$DEFAULT_DASHBOARD_ACTIVE_INTERVAL_SECONDS}"
  CODEX_STATUS_TIMEOUT_SECONDS="${CODEX_STATUS_TIMEOUT_SECONDS:-20}"
  CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-5}"
  CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"
  CURL_RETRIES="${CURL_RETRIES:-2}"
  CURL_RETRY_DELAY_SECONDS="${CURL_RETRY_DELAY_SECONDS:-1}"
  MONITOR_DEBUG="${MONITOR_DEBUG:-0}"
  CODEX_FORECAST_ENABLED="${CODEX_FORECAST_ENABLED:-1}"
  CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD="${CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD:-50}"
  CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD="${CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD:-25}"
  DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  GITHUB_PAT="${GITHUB_PAT:-}"
  GITHUB_GIST_ID="${GITHUB_GIST_ID:-}"
  GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
  TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"
  TOKEN_USAGE_SOURCES="${TOKEN_USAGE_SOURCES:-auto}"
  TOKEN_PRICING_FILE="${TOKEN_PRICING_FILE:-${SCRIPT_DIR}/pricing.json}"
  CODEX_DATA_DIR="${CODEX_DATA_DIR:-${HOME}/.codex}"
  OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/opencode.db}"
  HERMES_DB_PATH="${HERMES_DB_PATH:-${HOME}/.hermes/state.db}"

  check_requirements || return 1
  validate_config || return 1
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  [[ -w "$RUNTIME_DIR" ]] || { config_error "Runtime directory is not writable: $RUNTIME_DIR"; return 1; }
}

fetch_status_json() {
  local interval_seconds="$1"
  local codex_cmd="${CODEX_BIN:-codex}"

  python3 - "$codex_cmd" "${CODEX_STATUS_TIMEOUT_SECONDS:-20}" "$interval_seconds" "$HISTORY_RETENTION_HOURS" "${MONITOR_DEBUG:-0}" <<'PYEOF'
import datetime
import json
import math
import os
import select
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

codex_cmd = sys.argv[1]
timeout_seconds = max(5, int(sys.argv[2]))
interval_seconds = max(1, int(sys.argv[3]))
history_window_hours = float(sys.argv[4])
debug = sys.argv[5] == "1"
paris_timezone = ZoneInfo("Europe/Paris")

# Do not pass notification or storage credentials to the Codex subprocess.
codex_environment = os.environ.copy()
for secret_name in ("DISCORD_WEBHOOK", "GITHUB_PAT", "TELEGRAM_BOT_TOKEN"):
    codex_environment.pop(secret_name, None)

process = subprocess.Popen(
    [codex_cmd, "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    close_fds=True,
    env=codex_environment,
)


def send(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def stop_process():
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


send({
    "id": 1,
    "method": "initialize",
    "params": {
        "clientInfo": {"name": "codex-usage-monitor", "version": "1.0.0"},
        "capabilities": {"experimentalApi": True},
    },
})

deadline = time.monotonic() + timeout_seconds
result = None
rate_limit_requested = False
diagnostic = bytearray()


def clean_diagnostic(raw):
    text = raw.decode("utf-8", "replace")
    return "".join(char if char in "\n\t" or ord(char) >= 32 else "?" for char in text).strip()[:4096]

try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout, process.stderr], [], [], 0.5)
        if not ready:
            if process.poll() is not None:
                break
            continue

        if process.stderr in ready:
            chunk = os.read(process.stderr.fileno(), 1024)
            if len(diagnostic) < 4096:
                diagnostic.extend(chunk[: 4096 - len(diagnostic)])
            ready.remove(process.stderr)
        if process.stdout not in ready:
            continue
        line = process.stdout.readline()
        if not line:
            break
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        if message.get("id") == 1 and not rate_limit_requested:
            if message.get("error"):
                break
            send({"method": "initialized"})
            send({"id": 2, "method": "account/rateLimits/read", "params": None})
            rate_limit_requested = True
        elif message.get("id") == 2:
            result = message.get("result")
            break
finally:
    stop_process()

if not isinstance(result, dict):
    sys.stderr.write("[ERROR] Codex app-server did not return usage limits.\n")
    if debug and diagnostic:
        sys.stderr.write(f"[DEBUG] Codex diagnostic: {clean_diagnostic(diagnostic)}\n")
    raise SystemExit(1)

snapshots_by_id = result.get("rateLimitsByLimitId")
if isinstance(snapshots_by_id, dict) and snapshots_by_id:
    snapshots = [(str(limit_id), snapshot) for limit_id, snapshot in snapshots_by_id.items()]
else:
    flat = result.get("rateLimits")
    snapshots = [(str(flat.get("limitId", "default")), flat)] if isinstance(flat, dict) else []


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def classify_windows(snapshot):
    short = weekly = None
    for name in ("primary", "secondary"):
        window = snapshot.get(name)
        if not isinstance(window, dict):
            continue
        duration = window.get("windowDurationMins")
        used = window.get("usedPercent")
        if not finite_number(duration) or duration <= 0:
            continue
        if not finite_number(used) or not 0 <= used <= 100:
            continue
        if 1 <= duration <= 360 and short is None:
            short = window
        elif 7 * 24 * 60 <= duration <= 8 * 24 * 60 and weekly is None:
            weekly = window
    return short, weekly


# Select one coherent limit group; never combine windows from different IDs.
candidates = []
for limit_id, snapshot in snapshots:
    if isinstance(snapshot, dict):
        short, weekly = classify_windows(snapshot)
        if short is not None or weekly is not None:
            candidates.append((int(short is not None) + int(weekly is not None), limit_id, short, weekly))

if not candidates:
    sys.stderr.write("[ERROR] Codex returned no valid recognized usage window.\n")
    if debug and diagnostic:
        sys.stderr.write(f"[DEBUG] Codex diagnostic: {clean_diagnostic(diagnostic)}\n")
    raise SystemExit(1)

candidates.sort(key=lambda item: item[0], reverse=True)
_, selected_limit_id, five_hour_window, weekly_window = candidates[0]
if five_hour_window is None or weekly_window is None:
    missing = "short" if five_hour_window is None else "weekly"
    sys.stderr.write(
        f"[WARN] Codex returned a partial limit group '{selected_limit_id}'; "
        f"the {missing} usage window is unavailable.\n"
    )


def remaining_percent(window):
    if not window:
        return None
    used = window.get("usedPercent")
    if not finite_number(used) or not 0 <= used <= 100:
        return None
    remaining = 100 - used
    return int(remaining) if float(remaining).is_integer() else remaining


def reset_time(window):
    if not window:
        return "unknown"
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp):
        return "unknown"
    try:
        reset = datetime.datetime.fromtimestamp(timestamp, paris_timezone)
    except (OverflowError, OSError, ValueError):
        return "unknown"
    return reset.strftime("%d/%m/%Y %H:%M")


def reset_timestamp(window):
    if not window:
        return None
    timestamp = window.get("resetsAt")
    if not finite_number(timestamp) or timestamp <= 0:
        return None
    return int(timestamp)

payload = {
    "five_h_pct": remaining_percent(five_hour_window),
    "five_h_reset": reset_time(five_hour_window),
    "five_h_reset_at": reset_timestamp(five_hour_window),
    "weekly_pct": remaining_percent(weekly_window),
    "weekly_reset": reset_time(weekly_window),
    "weekly_reset_at": reset_timestamp(weekly_window),
    "limit_id": selected_limit_id,
    "scraped_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sample_interval_seconds": interval_seconds,
    "history_window_hours": history_window_hours,
}
print(json.dumps(payload, indent=2))
PYEOF
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

  printf '%s\n' "$json" | python3 "$HISTORY_PY" \
    --history "$HISTORY_FILE" \
    --data "$DATA_FILE" \
    --retention-hours "$HISTORY_RETENTION_HOURS"

  echo "[OK] Snapshot storage processed at ${DATA_FILE}"
}

write_current_snapshot() {
  local json="$1"

  printf '%s\n' "$json" | python3 "$HISTORY_PY" \
    --data "$DATA_FILE" \
    --data-only

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

register_network_alert() {
  local kind="$1" window="$2" selector="$3" cycle_key="$4" message="$5"
  local event_data="$6" created_at="$7" expires_at="$8" replace="${9:-false}" expire_cycle="${10:-}"
  local channels request
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

deliver_due_alerts() {
  local now="$1" configured due_file alert_id channel message attempt cycle_limit
  local classification outcome error_class retryable retry_delay next_attempt used_retry_after record_payload
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

csv_contains() {
  local list="$1" wanted="$2"
  [[ ",${list}," == *",${wanted},"* ]]
}

persist_alert_state() {
  local state_tmp
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' \
    'state_version=4' \
    "prev_5h_pct=${prev_5h_pct}" \
    "prev_weekly_pct=${prev_weekly_pct}" \
    "observed_weekly_pct=${observed_weekly_pct}" \
    "observed_weekly_reset_at=${observed_weekly_reset_at}" \
    "observed_weekly_limit_id=${observed_weekly_limit_id}" \
    "five_h_armed_reset_at=${five_h_armed_reset_at}" \
    "weekly_armed_reset_at=${weekly_armed_reset_at}" \
    "weekly_armed_limit_id=${weekly_armed_limit_id}" \
    "last_notified_5h_reset_at=${last_notified_5h_reset_at}" \
    "last_notified_weekly_reset_at=${last_notified_weekly_reset_at}" \
    "notified_5h_thresholds=${notified_5h_thresholds}" \
    "notified_weekly_thresholds=${notified_weekly_thresholds}" \
    "pending_5h_threshold=${pending_5h_threshold}" \
    "pending_weekly_threshold=${pending_weekly_threshold}" \
    "script_tracking_initialized=${script_tracking_initialized}" \
    "script_prev_5h_pct=${script_prev_5h_pct}" \
    "script_prev_weekly_pct=${script_prev_weekly_pct}" \
    "attempted_script_5h_actions=${attempted_script_5h_actions}" \
    "attempted_script_weekly_actions=${attempted_script_weekly_actions}" \
    "script_5h_reset_attempted_at=${script_5h_reset_attempted_at}" \
    "script_weekly_reset_attempted_at=${script_weekly_reset_attempted_at}" \
    "attempted_script_5h_reset_actions=${attempted_script_5h_reset_actions}" \
    "attempted_script_weekly_reset_actions=${attempted_script_weekly_reset_actions}" > "$state_tmp"; then
    rm -f "$state_tmp"
    return 1
  fi
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

reconcile_alert_deliveries() {
  local now="$1" terminal_file line alert_id kind window reason selector remaining reset_epoch covered threshold ack_id
  local -a ack_ids=()
  terminal_file="$(mktemp "${RUNTIME_DIR}/.alerts-terminal.XXXXXX")" || return 1
  if ! python3 "$ALERTS_PY" terminal-unacknowledged "$ALERT_DELIVERIES_FILE" > "$terminal_file"; then
    rm -f "$terminal_file"
    return 1
  fi
  # A non-whitespace separator preserves the empty threshold-only/reset-only
  # fields that Bash would otherwise collapse when parsing tab-separated rows.
  while IFS=$'\x1f' read -r alert_id kind window reason selector remaining reset_epoch covered; do
    [[ -n "$alert_id" ]] || continue
    ack_ids+=("$alert_id")
    if [[ "$kind" == threshold ]]; then
      if [[ "$reason" == superseded || "$reason" == expired_after_reset ]]; then
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
    elif [[ "$window" == 5h ]]; then
      last_notified_5h_reset_at="$reset_epoch"
      if [[ "$five_h_armed_reset_at" == "$reset_epoch" ]]; then
        five_h_armed_reset_at=0
        notified_5h_thresholds=""
        pending_5h_threshold=""
        prev_5h_pct=100
      fi
    else
      last_notified_weekly_reset_at="$reset_epoch"
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
          item["selector"], event.get("remaining_pct", ""), event.get("reset_epoch", 0), covered, sep="\x1f")
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
  local five_h_reset="$6" weekly_reset="$7" channels thresholds_csv payload
  if (( five_h_armed_reset_at > 0 && now > five_h_armed_reset_at + 5 * 60 * 60 )); then
    last_notified_5h_reset_at="$five_h_armed_reset_at"
    five_h_armed_reset_at=0
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
    if [[ -n "$pending_5h_threshold" && ! "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      echo "[ERROR] Historical 5h pending alert cannot be reconstructed from the current observation." >&2
      return 1
    fi
    if [[ -n "$pending_weekly_threshold" && ! "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
      echo "[ERROR] Historical weekly pending alert cannot be reconstructed from the current observation." >&2
      return 1
    fi
  else
    if [[ -n "$pending_5h_threshold" ]]; then
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
    if [[ -n "$pending_weekly_threshold" ]]; then
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
    python3 - "$state_version" "$now" "$limit_id" "$channels" "$thresholds_csv" \
      "$pending_5h_threshold" "$pending_weekly_threshold" "$prev_5h_pct" "$prev_weekly_pct" \
      "$five_h_pct" "$weekly_pct" "$five_h_armed_reset_at" "$weekly_armed_reset_at" \
      "$last_notified_5h_reset_at" "$last_notified_weekly_reset_at" "$weekly_armed_limit_id" <<'PYEOF'
import json
import os
import sys

(version, now, limit_id, channels_raw, thresholds_raw, pending_five, pending_weekly,
 previous_five, previous_weekly, five_pct, weekly_pct, five_reset, weekly_reset,
 last_five_reset, last_weekly_reset, weekly_limit_id) = sys.argv[1:]
version, now, five_reset, weekly_reset, last_five_reset, last_weekly_reset = map(
    int, (version, now, five_reset, weekly_reset, last_five_reset, last_weekly_reset))
channels = json.loads(channels_raw)
thresholds = [int(value) for value in thresholds_raw.split(",") if value]
alerts = []

def threshold(window, selector, previous, remaining, reset, message):
    if not selector or not channels:
        return
    critical = int(selector)
    cycle = f"legacy-v{version}|limit:{limit_id}|" + (f"reset:{reset}" if reset else "unarmed")
    alerts.append({
        "kind": "threshold", "window": window, "selector": selector,
        "cycle_key": cycle, "id_namespace": f"legacy-v{version}", "message": message,
        "event_data": {"limit_id": limit_id, "remaining_pct": float(remaining),
                       "reset_epoch": reset,
                       "covered_thresholds": [value for value in thresholds if critical <= value < float(previous)]},
        "created_at": min(now, reset) if reset else now,
        "expires_at": reset, "channels": channels,
        "replace_pending_thresholds": True, "expire_threshold_cycle": None,
    })

def reset(window, reset_at, last_reset, validity, event_limit_id, message):
    if not channels or not reset_at or reset_at > now or reset_at == last_reset or now > reset_at + validity:
        return
    cycle = f"legacy-v{version}|limit:{event_limit_id}|reset:{reset_at}"
    alerts.append({
        "kind": "reset", "window": window, "selector": "reset",
        "cycle_key": cycle, "id_namespace": f"legacy-v{version}", "message": message,
        "event_data": {"limit_id": event_limit_id, "reset_epoch": reset_at},
        "created_at": reset_at, "expires_at": reset_at + validity, "channels": channels,
        "replace_pending_thresholds": False, "expire_threshold_cycle": cycle,
    })

threshold("5h", pending_five, previous_five, five_pct, five_reset, os.environ["MIGRATION_FIVE_MESSAGE"])
threshold("weekly", pending_weekly, previous_weekly, weekly_pct, weekly_reset, os.environ["MIGRATION_WEEKLY_MESSAGE"])
reset("5h", five_reset, last_five_reset, 5 * 60 * 60, limit_id,
      "*Codex 5h limit reset.* A new usage cycle is available.")
reset("weekly", weekly_reset, last_weekly_reset, 7 * 24 * 60 * 60,
      weekly_limit_id or limit_id, "*Codex weekly limit reset.* A new usage cycle is available.")
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

  local state_version=1
  local prev_5h_pct=100
  local prev_weekly_pct=100
  local observed_weekly_pct=""
  local observed_weekly_reset_at=0
  local observed_weekly_limit_id=""
  local five_h_armed_reset_at=0
  local weekly_armed_reset_at=0
  local weekly_armed_limit_id=""
  local last_notified_5h_reset_at=0
  local last_notified_weekly_reset_at=0
  local notified_5h_thresholds=""
  local notified_weekly_thresholds=""
  local pending_5h_threshold=""
  local pending_weekly_threshold=""
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
  local original_pending cycle_key covered_json registration_status
  local due_5h_reset_at=0 due_weekly_reset_at=0 script_state_error=0 initialize_script_baseline=0
  local observed_weekly_reset=0 weekly_observation_valid=0 process_weekly_sample=1 state_loaded=0
  local -a script_thresholds=()
  ALERT_PROCESSING_ERROR=""
  if [[ -f "$STATE_FILE" ]]; then
    state_loaded=1
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
        state_version)
          [[ "$state_value" =~ ^[0-9]+$ ]] || { ALERT_PROCESSING_ERROR="invalid alert state version"; return 1; }
          state_version="$state_value"
          ;;
        prev_5h_pct|prev_weekly_pct|observed_weekly_pct|script_prev_5h_pct|script_prev_weekly_pct)
          if [[ "$state_value" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
        observed_weekly_reset_at|five_h_armed_reset_at|weekly_armed_reset_at|last_notified_5h_reset_at|last_notified_weekly_reset_at)
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
        observed_weekly_limit_id|weekly_armed_limit_id)
          printf -v "$state_key" '%s' "$state_value"
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

  if (( state_version > 4 )); then
    echo "[ERROR] Unsupported future alert state version ${state_version}; alerts are disabled." >&2
    ALERT_PROCESSING_ERROR="unsupported future alert state version"
    return 1
  fi
  if (( state_version < 1 || state_version > 4 )); then
    echo "[ERROR] Unsupported alert state version ${state_version}." >&2
    ALERT_PROCESSING_ERROR="invalid alert state version"
    return 1
  fi

  mapfile -t thresholds < <(load_thresholds)
  pace="$(weekly_pace_vs_ideal "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch")"
  pace_suffix=""
  [[ -n "$pace" ]] && pace_suffix=$'\n'"*Pace vs ideal:* ${pace}"
  if [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$weekly_reset_at" =~ ^[0-9]+$ ]]; then
    weekly_observation_valid=1
  fi


  if [[ ! -e "$ALERT_DELIVERIES_FILE" ]]; then
    if ! initialize_alert_delivery_journal "$state_version" "$scraped_at_epoch" "$limit_id" \
      "$five_h_pct" "$weekly_pct" "$five_h_reset" "$weekly_reset"; then
      ALERT_PROCESSING_ERROR="alert journal initialization failed"
      return 1
    fi
  elif ! python3 "$ALERTS_PY" validate "$ALERT_DELIVERIES_FILE"; then
    echo "[ERROR] Alert delivery journal is invalid; no notification was sent." >&2
    ALERT_PROCESSING_ERROR="invalid alert delivery journal"
    return 1
  fi

  if ! reconcile_alert_deliveries "$scraped_at_epoch"; then
    ALERT_PROCESSING_ERROR="alert reconciliation failed"
    return 1
  fi
  if ! python3 "$ALERTS_PY" expire "$ALERT_DELIVERIES_FILE" --now "$scraped_at_epoch" \
    || ! reconcile_alert_deliveries "$scraped_at_epoch"; then
    ALERT_PROCESSING_ERROR="alert expiration failed"
    return 1
  fi

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

  # Alert state belongs to one coherent limit group. A complete observation of
  # another group starts a fresh baseline instead of crossing group boundaries.
  if (( state_loaded == 1 )) && [[ -z "$observed_weekly_limit_id" ]]; then
    if (( weekly_observation_valid == 1 )); then
      prev_weekly_pct="$weekly_pct"
      notified_weekly_thresholds=""
      pending_weekly_threshold=""
      script_prev_weekly_pct="$weekly_pct"
      attempted_script_weekly_actions=""
      observed_weekly_pct="$weekly_pct"
      observed_weekly_reset_at="$weekly_reset_at"
      observed_weekly_limit_id="$limit_id"
    else
      process_weekly_sample=0
    fi
  elif (( weekly_observation_valid == 1 )) \
    && [[ -n "$observed_weekly_limit_id" && "$limit_id" != "$observed_weekly_limit_id" ]]; then
    prev_weekly_pct="$weekly_pct"
    notified_weekly_thresholds=""
    pending_weekly_threshold=""
    script_prev_weekly_pct="$weekly_pct"
    attempted_script_weekly_actions=""
    observed_weekly_pct="$weekly_pct"
    observed_weekly_reset_at="$weekly_reset_at"
    observed_weekly_limit_id="$limit_id"
    if [[ "$weekly_armed_limit_id" != "$limit_id" ]]; then
      weekly_armed_reset_at=0
      weekly_armed_limit_id=""
      script_weekly_reset_attempted_at=0
      attempted_script_weekly_reset_actions=""
    fi
  elif [[ -n "$observed_weekly_limit_id" && "$limit_id" != "$observed_weekly_limit_id" ]]; then
    process_weekly_sample=0
  fi
  if (( weekly_armed_reset_at > 0 )) && [[ -z "$weekly_armed_limit_id" ]]; then
    weekly_armed_reset_at=0
    script_weekly_reset_attempted_at=0
    attempted_script_weekly_reset_actions=""
  fi

  # Codex can refill the weekly window before its previously announced
  # deadline. Match the archive's conservative detection rule so alerts and
  # reset history agree: require both a quota refill and a materially later
  # deadline. Anchor the event to this first post-reset observation because the
  # exact reset instant is unknown.
  if (( observed_weekly_reset_at > 0 )) \
    && [[ "$limit_id" == "$observed_weekly_limit_id" ]] \
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
  fi

  # Reset delivery is retried while the reset still belongs to a plausible cycle.
  if (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at )); then
    due_5h_reset_at="$five_h_armed_reset_at"
    reset_age=$(( scraped_at_epoch - five_h_armed_reset_at ))
    if (( reset_age <= 5 * 60 * 60 && last_notified_5h_reset_at != five_h_armed_reset_at )); then
      cycle_key="limit:${limit_id}|reset:${five_h_armed_reset_at}"
      if journal_has_pending_alert reset 5h reset "$cycle_key"; then
        :
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

  if (( weekly_armed_reset_at > 0 && scraped_at_epoch >= weekly_armed_reset_at )) \
    && [[ "$weekly_armed_limit_id" == "$limit_id" ]]; then
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
        :
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
    if (( script_weekly_reset_attempted_at != due_weekly_reset_at )); then
      script_weekly_reset_attempted_at="$due_weekly_reset_at"
      attempted_script_weekly_reset_actions=""
      attempted_script_weekly_actions=""
      if (( observed_weekly_reset == 1 )); then
        script_prev_weekly_pct="$weekly_pct"
      else
        script_prev_weekly_pct=100
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
  fi

  if (( weekly_armed_reset_at == 0 )) \
    && [[ "$weekly_pct" =~ ^([0-9]+([.][0-9]+)?)$ && "$weekly_reset_at" =~ ^[0-9]+$ ]] \
    && percentage_below_full "$weekly_pct" \
    && (( weekly_reset_at > scraped_at_epoch && weekly_reset_at <= scraped_at_epoch + 8 * 24 * 60 * 60 )); then
    weekly_armed_reset_at="$weekly_reset_at"
    weekly_armed_limit_id="$limit_id"
  fi

  # The first observation uses 100% as its baseline. A multi-threshold drop emits
  # one alert for the most critical crossed threshold and marks all crossed levels.
  if [[ "$five_h_pct" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
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
      if ! deliver_due_alerts "$scraped_at_epoch"; then
        NETWORK_DELIVERY_ERROR=1
      fi
      if ! reconcile_alert_deliveries "$scraped_at_epoch"; then
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

  local json public_json gist_json status=0 history_json="[]"
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
        append_cycle_error "Long-term archive update failed"
      fi
      if write_local_snapshot "$public_json"; then
        [[ -f "$HISTORY_FILE" ]] && history_json="$(<"$HISTORY_FILE")"
      else
        status=1
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
      sync_gist "$gist_json" "$history_json" || { status=1; append_cycle_error "GitHub Gist sync failed"; }
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

  initialize || return 1
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
