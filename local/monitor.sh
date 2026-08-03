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
#   ALERT_SCRIPT_TIMEOUT_SECONDS — per-hook timeout, default: 30
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
DEFAULT_INTERVAL_SECONDS=900
INVALID_ALERT_SCRIPT_CONFIG=0

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
      ALERT_THRESHOLDS|ALERT_SCRIPT_TIMEOUT_SECONDS|ARCHIVE_RETENTION_DAYS|CODEX_BIN|CODEX_STATUS_TIMEOUT_SECONDS|CURL_CONNECT_TIMEOUT_SECONDS|CURL_MAX_TIME_SECONDS|CURL_RETRIES|CURL_RETRY_DELAY_SECONDS|DISCORD_WEBHOOK|GITHUB_API_URL|GITHUB_GIST_ID|GITHUB_PAT|HISTORY_RETENTION_HOURS|LOOP_INTERVAL|MONITOR_DEBUG|TELEGRAM_API_URL|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID)
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

  validate_integer ALERT_SCRIPT_TIMEOUT_SECONDS "$ALERT_SCRIPT_TIMEOUT_SECONDS" 1 300 || invalid=1
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
  local invalid=0 secret
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
  umask 077
  if [[ -f "$ENV_FILE" ]]; then
    if [[ -L "$ENV_FILE" || ! -O "$ENV_FILE" ]]; then
      config_error ".env must be a regular file owned by the current user."
      return 1
    fi
    chmod 600 "$ENV_FILE"
    load_config
  fi

  ALERT_THRESHOLDS="${ALERT_THRESHOLDS:-75,50,25,10,5}"
  ALERT_SCRIPT_TIMEOUT_SECONDS="${ALERT_SCRIPT_TIMEOUT_SECONDS:-30}"
  ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-365}"
  HISTORY_RETENTION_HOURS="${HISTORY_RETENTION_HOURS:-192}"
  LOOP_INTERVAL="${LOOP_INTERVAL:-$DEFAULT_INTERVAL_SECONDS}"
  CODEX_STATUS_TIMEOUT_SECONDS="${CODEX_STATUS_TIMEOUT_SECONDS:-20}"
  CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-5}"
  CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-20}"
  CURL_RETRIES="${CURL_RETRIES:-2}"
  CURL_RETRY_DELAY_SECONDS="${CURL_RETRY_DELAY_SECONDS:-1}"
  MONITOR_DEBUG="${MONITOR_DEBUG:-0}"
  DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  GITHUB_PAT="${GITHUB_PAT:-}"
  GITHUB_GIST_ID="${GITHUB_GIST_ID:-}"
  GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
  TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

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
    return reset.strftime("%d/%m/%Y %H:%M (Paris)")


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

history_max_entries() {
  local interval_seconds="$1"

  python3 - "$interval_seconds" "$HISTORY_RETENTION_HOURS" <<'PYEOF'
import math
import sys

interval_seconds = max(1, int(sys.argv[1]))
hours = float(sys.argv[2])
entries = max(1, math.ceil((hours * 3600) / interval_seconds))
print(entries)
PYEOF
}

write_local_snapshot() {
  local json="$1"
  local interval_seconds="$2"
  local max_entries

  max_entries="$(history_max_entries "$interval_seconds")"

  python3 - "$HISTORY_FILE" "$DATA_FILE" "$json" "$max_entries" <<'PYEOF'
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

history_path = pathlib.Path(sys.argv[1])
data_path = pathlib.Path(sys.argv[2])
new_entry = json.loads(sys.argv[3])
max_entries = int(sys.argv[4])
public_fields = {
    "five_h_pct",
    "five_h_reset",
    "five_h_reset_at",
    "weekly_pct",
    "weekly_reset",
    "weekly_reset_at",
    "scraped_at",
    "sample_interval_seconds",
    "history_window_hours",
    "limit_id",
}


def sanitize_entry(entry):
    if not isinstance(entry, dict):
        return None
    sanitized = {key: entry[key] for key in public_fields if key in entry}
    for key in ("five_h_reset", "weekly_reset"):
        value = sanitized.get(key)
        if not isinstance(value, str) or len(value) > 100 or "@" in value:
            sanitized[key] = "unknown"
    value = sanitized.get("limit_id")
    if value is not None and (not isinstance(value, str) or len(value) > 100 or any(ord(char) < 32 for char in value)):
        sanitized.pop("limit_id", None)
    for key in ("five_h_reset_at", "weekly_reset_at"):
        value = sanitized.get(key)
        if value is not None and (
            not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0
        ):
            sanitized[key] = None
    return sanitized


new_entry = sanitize_entry(new_entry)
if new_entry is None:
    raise SystemExit("invalid usage snapshot")

def atomic_write(path, content):
    fd, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", text=True
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as temporary_file:
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


history = []
if history_path.exists():
    try:
        history = json.loads(history_path.read_text(encoding="utf-8"))
        if not isinstance(history, list):
            raise ValueError("history root is not an array")
    except Exception as error:
        backup = history_path.with_name(f"{history_path.name}.corrupt.{int(time.time())}")
        shutil.copy2(history_path, backup)
        sys.stderr.write(f"[WARN] Corrupt history copied to {backup} before reconstruction: {error}\n")
        history = []

history = [entry for item in history if (entry := sanitize_entry(item)) is not None]
new_timestamp = new_entry.get("scraped_at", "")
existing_timestamps = {entry.get("scraped_at") for entry in history}
if new_timestamp not in existing_timestamps:
    history.append(new_entry)
history.sort(key=lambda entry: entry.get("scraped_at", ""), reverse=True)
history = history[:max_entries]

current = None
if data_path.exists():
    try:
        current = sanitize_entry(json.loads(data_path.read_text(encoding="utf-8")))
    except Exception:
        current = None

atomic_write(history_path, json.dumps(history, indent=2) + "\n")
if current is None or new_timestamp >= current.get("scraped_at", ""):
    atomic_write(data_path, json.dumps(new_entry, indent=2) + "\n")
else:
    sys.stderr.write("[WARN] Older snapshot retained in history but did not replace data.json.\n")
PYEOF

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
  local state_tmp
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' \
    'state_version=3' \
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
  local due_5h_reset_at=0 due_weekly_reset_at=0 script_state_error=0 initialize_script_baseline=0
  local -a script_thresholds=()
  ALERT_PROCESSING_ERROR=""
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
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
      if send_alert "*Codex 5h limit reset.* A new usage cycle is available."; then
        last_notified_5h_reset_at="$five_h_armed_reset_at"
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
      if send_alert "*Codex weekly limit reset.* A new usage cycle is available."; then
        last_notified_weekly_reset_at="$weekly_armed_reset_at"
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
      if send_alert "*Codex 5h limit at ${five_h_pct}% remaining* (crossed ${critical}% threshold). Resets at ${five_h_reset}${pace_suffix}"; then
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
      if send_alert "*Codex weekly limit at ${weekly_pct}% remaining* (crossed ${critical}% threshold). Resets ${weekly_reset}${pace_suffix}"; then
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

run_cycle() {
  local interval_seconds="$1"
  echo "[$(date -u +%H:%M:%SZ)] Scraping codex status..."

  local json status=0
  CYCLE_ERROR=""
  json=$(fetch_status_json "$interval_seconds") || { CYCLE_ERROR="Codex collection failed"; return 1; }

  # Pretty-print to terminal
  echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"

  # Write the long-term archive. Archive failures are reported but must not
  # prevent the current snapshot, Gist sync, or alert processing.
  if ! archive_snapshot "$json"; then
    status=1
    append_cycle_error "Long-term archive update failed"
  fi

  # Write locally
  write_local_snapshot "$json" "$interval_seconds" || { append_cycle_error "Local snapshot write failed"; return 1; }

  # Read history for gist sync
  local history_json="[]"
  if [[ -f "$HISTORY_FILE" ]]; then
    history_json="$(<"$HISTORY_FILE")"
  fi

  sync_gist "$json" "$history_json" || { status=1; append_cycle_error "GitHub Gist sync failed"; }

  # Extract values for threshold check
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

main() {
  local interval mode=once fail_fast=0 now_epoch delay next_epoch next_check
  initialize || return 1
  interval="$LOOP_INTERVAL"

  while (( $# > 0 )); do
    case "$1" in
      --loop)
        mode=loop
        if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
          interval="$2"
          shift
        fi
        ;;
      --check) mode=check ;;
      --fail-fast) fail_fast=1 ;;
      --once) mode=once ;;
      *) config_error "Unknown argument: $1"; return 1 ;;
    esac
    shift
  done

  validate_interval "$interval" || return 1
  if [[ "$mode" == check ]]; then
    echo "[INFO] Checking Codex authentication and app-server response..."
    fetch_status_json "$interval" >/dev/null || return 1
    echo "[OK] Configuration, dependencies, permissions, tzdata and Codex authentication are valid."
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
      next_check="$(date -u -d "@${next_epoch}" +%H:%M:%SZ)"
      echo "[$(date -u +%H:%M:%SZ)] Next check at ${next_check} (in ${delay}s)..."
      sleep "$delay"
    done
  else
    run_once "$interval"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
