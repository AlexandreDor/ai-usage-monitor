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
#
# Environment variables (set in .env or export):
#   DISCORD_WEBHOOK     — Discord webhook URL (optional)
#   TELEGRAM_BOT_TOKEN  — Telegram bot token from BotFather (optional)
#   TELEGRAM_CHAT_ID    — Telegram numeric chat ID (optional)
#   ALERT_THRESHOLDS    — comma-separated thresholds, default: 75,50,25,10,5
#   GITHUB_PAT          — GitHub Personal Access Token with gist scope (optional)
#   GITHUB_GIST_ID      — ID of the GitHub Gist to update (optional)
# ============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
STATE_FILE="${RUNTIME_DIR}/.alert_state"
DATA_FILE="${RUNTIME_DIR}/data.json"
HISTORY_FILE="${RUNTIME_DIR}/history.json"
DEFAULT_INTERVAL_SECONDS=900

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

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
      ALERT_THRESHOLDS|CODEX_BIN|CODEX_STATUS_TIMEOUT_SECONDS|DISCORD_WEBHOOK|GITHUB_GIST_ID|GITHUB_PAT|HISTORY_RETENTION_HOURS|LOOP_INTERVAL|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID)
        if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; }; then
          value="${value:1:${#value}-2}"
        fi
        printf -v "$key" '%s' "$value"
        ;;
      *)
        echo "[WARN] Ignoring unsupported configuration key: $key" >&2
        ;;
    esac
  done < "$ENV_FILE"
}

# Parse configuration as data; never execute .env as shell code.
if [[ -f "$ENV_FILE" ]]; then
  if [[ -L "$ENV_FILE" || ! -O "$ENV_FILE" ]]; then
    echo "[ERROR] .env must be a regular file owned by the current user." >&2
    exit 1
  fi
  chmod 600 "$ENV_FILE"
  load_config
fi

# Defaults
ALERT_THRESHOLDS="${ALERT_THRESHOLDS:-75,50,25,10,5}"
HISTORY_RETENTION_HOURS="${HISTORY_RETENTION_HOURS:-192}"

# ============================================================================
# Validation
# ============================================================================
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
  fi

  if [[ -n "${GITHUB_PAT:-}" && -z "${GITHUB_GIST_ID:-}" ]]; then
    echo "[WARN] GITHUB_PAT is set but GITHUB_GIST_ID is missing. Gist sync disabled."
  fi

  if [[ -n "${GITHUB_GIST_ID:-}" && ! "$GITHUB_GIST_ID" =~ ^[A-Fa-f0-9]+$ ]]; then
    echo "[ERROR] GITHUB_GIST_ID has an invalid format."
    missing=1
  fi

  if [[ -n "${DISCORD_WEBHOOK:-}" && ! "$DISCORD_WEBHOOK" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$ ]]; then
    echo "[ERROR] DISCORD_WEBHOOK must be an official Discord HTTPS webhook URL."
    missing=1
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    echo "[ERROR] TELEGRAM_BOT_TOKEN has an invalid format."
    missing=1
  fi

  if [[ $missing -eq 1 ]]; then
    exit 1
  fi
}

fetch_status_json() {
  local interval_seconds="$1"
  local codex_cmd="${CODEX_BIN:-codex}"

  python3 - "$codex_cmd" "${CODEX_STATUS_TIMEOUT_SECONDS:-20}" "$interval_seconds" "$HISTORY_RETENTION_HOURS" <<'PYEOF'
import datetime
import json
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
paris_timezone = ZoneInfo("Europe/Paris")

# Do not pass notification or storage credentials to the Codex subprocess.
codex_environment = os.environ.copy()
for secret_name in ("DISCORD_WEBHOOK", "GITHUB_PAT", "TELEGRAM_BOT_TOKEN"):
    codex_environment.pop(secret_name, None)

process = subprocess.Popen(
    [codex_cmd, "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
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

try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], 0.5)
        if not ready:
            if process.poll() is not None:
                break
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
    raise SystemExit(1)

snapshots_by_id = result.get("rateLimitsByLimitId")
if isinstance(snapshots_by_id, dict) and snapshots_by_id:
    snapshots = list(snapshots_by_id.values())
else:
    snapshots = [result.get("rateLimits")]

windows = []
for snapshot in snapshots:
    if not isinstance(snapshot, dict):
        continue
    for window_name in ("primary", "secondary"):
        window = snapshot.get(window_name)
        if isinstance(window, dict):
            windows.append(window)


def window_with_duration(minimum, maximum):
    for window in windows:
        duration = window.get("windowDurationMins")
        if isinstance(duration, int) and minimum <= duration <= maximum:
            return window
    return None


def remaining_percent(window):
    if not window:
        return None
    used = window.get("usedPercent")
    if not isinstance(used, int) or not 0 <= used <= 100:
        return None
    return 100 - used


def reset_time(window):
    if not window:
        return "unknown"
    timestamp = window.get("resetsAt")
    if not isinstance(timestamp, int):
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
    return timestamp if isinstance(timestamp, int) and timestamp > 0 else None


five_hour_window = window_with_duration(1, 360)
weekly_window = window_with_duration(7 * 24 * 60, 8 * 24 * 60)

if five_hour_window is None and weekly_window is None:
    sys.stderr.write("[ERROR] Codex returned no recognized usage windows.\n")
    raise SystemExit(1)

payload = {
    "five_h_pct": remaining_percent(five_hour_window),
    "five_h_reset": reset_time(five_hour_window),
    "five_h_reset_at": reset_timestamp(five_hour_window),
    "weekly_pct": remaining_percent(weekly_window),
    "weekly_reset": reset_time(weekly_window),
    "weekly_reset_at": reset_timestamp(weekly_window),
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
import fcntl
import os
import pathlib
import sys
import tempfile

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
}


def sanitize_entry(entry):
    if not isinstance(entry, dict):
        return None
    sanitized = {key: entry[key] for key in public_fields if key in entry}
    for key in ("five_h_reset", "weekly_reset"):
        value = sanitized.get(key)
        if not isinstance(value, str) or len(value) > 100 or "@" in value:
            sanitized[key] = "unknown"
    for key in ("five_h_reset_at", "weekly_reset_at"):
        value = sanitized.get(key)
        if value is not None and (not isinstance(value, int) or value <= 0):
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


lock_path = history_path.parent / ".monitor.lock"
with lock_path.open("a+", encoding="utf-8") as lock_file:
    os.chmod(lock_path, 0o600)
    fcntl.flock(lock_file, fcntl.LOCK_EX)

    history = []
    if history_path.exists():
        try:
            history = json.loads(history_path.read_text(encoding="utf-8"))
            if not isinstance(history, list):
                history = []
        except Exception:
            history = []

    history = [entry for item in history if (entry := sanitize_entry(item)) is not None]
    history.insert(0, new_entry)
    history = history[:max_entries]

    atomic_write(history_path, json.dumps(history, indent=2) + "\n")
    atomic_write(data_path, json.dumps(new_entry, indent=2) + "\n")
PYEOF

  echo "[OK] Data written to ${DATA_FILE}"
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
sync_gist() {
  local json="$1"
  local history_json="$2"

  if [[ -z "${GITHUB_PAT:-}" || -z "${GITHUB_GIST_ID:-}" ]]; then
    return 0  # silently skip if not configured
  fi

  # Escape JSON for embedding in PATCH payload
  local latest_escaped history_escaped
  latest_escaped=$(echo "$json" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
  history_escaped=$(echo "$history_json" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")

  local payload
  payload=$(cat <<EOF
{
  "files": {
    "data.json": { "content": ${latest_escaped} },
    "history.json": { "content": ${history_escaped} }
  }
}
EOF
)

  local http_code
  http_code=$(printf 'header = "Authorization: token %s"\n' "$GITHUB_PAT" | curl --config - -s -o /dev/null -w "%{http_code}" \
    -X PATCH "https://api.github.com/gists/${GITHUB_GIST_ID}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$http_code" == "200" ]]; then
    echo "[OK] Gist updated (ID: ${GITHUB_GIST_ID})"
  else
    echo "[WARN] Gist sync failed with HTTP $http_code"
  fi
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

  printf 'url = "%s"\n' "$DISCORD_WEBHOOK" | curl --config - -s -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -d "$payload"
}

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return; fi

  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" | curl --config - -s -o /dev/null -X POST \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}"
}

send_alert() {
  local message="$1"
  echo "[ALERT] $message"
  send_discord "$message"
  send_telegram "$message"
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

check_thresholds() {
  local five_h_pct="$1"
  local weekly_pct="$2"
  local five_h_reset="$3"
  local weekly_reset="$4"
  local five_h_reset_at="$5"
  local weekly_reset_at="$6"
  local scraped_at_epoch="$7"

  # Load previous alert state
  local prev_5h_pct=100
  local prev_weekly_pct=100
  local five_h_armed_reset_at=0
  local weekly_armed_reset_at=0
  local last_notified_5h_reset_at=0
  local last_notified_weekly_reset_at=0
  local thresholds state_key state_value saved_5h_pct saved_weekly_pct pace pace_suffix
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r state_key state_value; do
      case "$state_key" in
        prev_5h_pct|prev_weekly_pct)
          if [[ "$state_value" =~ ^[0-9]+$ ]] && (( state_value <= 100 )); then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
        five_h_armed_reset_at|weekly_armed_reset_at|last_notified_5h_reset_at|last_notified_weekly_reset_at)
          if [[ "$state_value" =~ ^[0-9]+$ ]]; then
            printf -v "$state_key" '%s' "$state_value"
          fi
          ;;
      esac
    done < "$STATE_FILE"
  fi

  mapfile -t thresholds < <(load_thresholds)
  pace="$(weekly_pace_vs_ideal "$weekly_pct" "$weekly_reset_at" "$scraped_at_epoch")"
  pace_suffix=""
  [[ -n "$pace" ]] && pace_suffix=$'\n'"*Pace vs ideal:* ${pace}"

  # A consumed cycle is armed until its known deadline passes. This also
  # detects resets that happened while the monitor was stopped.
  local reset_age
  if (( five_h_armed_reset_at > 0 && scraped_at_epoch >= five_h_armed_reset_at )); then
    reset_age=$(( scraped_at_epoch - five_h_armed_reset_at ))
    if (( reset_age <= 5 * 60 * 60 && last_notified_5h_reset_at != five_h_armed_reset_at )); then
      send_alert "*Codex 5h limit reset.* A new usage cycle is available."
      last_notified_5h_reset_at="$five_h_armed_reset_at"
    fi
    five_h_armed_reset_at=0
  fi

  if (( weekly_armed_reset_at > 0 && scraped_at_epoch >= weekly_armed_reset_at )); then
    reset_age=$(( scraped_at_epoch - weekly_armed_reset_at ))
    if (( reset_age <= 7 * 24 * 60 * 60 && last_notified_weekly_reset_at != weekly_armed_reset_at )); then
      send_alert "*Codex weekly limit reset.* A new usage cycle is available."
      last_notified_weekly_reset_at="$weekly_armed_reset_at"
    fi
    weekly_armed_reset_at=0
  fi

  # Ignore shifting reset estimates while a cycle is armed. Once it has reset,
  # arm the next plausible deadline only after some quota has been consumed.
  if (( five_h_armed_reset_at == 0 )) \
    && [[ "$five_h_pct" =~ ^[0-9]+$ && "$five_h_reset_at" =~ ^[0-9]+$ ]] \
    && (( five_h_pct < 100 && five_h_reset_at > scraped_at_epoch && five_h_reset_at <= scraped_at_epoch + 6 * 60 * 60 )); then
    five_h_armed_reset_at="$five_h_reset_at"
  fi

  if (( weekly_armed_reset_at == 0 )) \
    && [[ "$weekly_pct" =~ ^[0-9]+$ && "$weekly_reset_at" =~ ^[0-9]+$ ]] \
    && (( weekly_pct < 100 && weekly_reset_at > scraped_at_epoch && weekly_reset_at <= scraped_at_epoch + 8 * 24 * 60 * 60 )); then
    weekly_armed_reset_at="$weekly_reset_at"
  fi

  # Check 5h limit (sort descending so we catch the highest crossed threshold first)
  if [[ "$five_h_pct" =~ ^[0-9]+$ ]]; then
    for t in "${thresholds[@]}"; do
      if (( five_h_pct <= t && prev_5h_pct > t )); then
        send_alert "⚠️ *Codex 5h limit at ${five_h_pct}% remaining* (crossed ${t}% threshold). Resets at ${five_h_reset}${pace_suffix}"
        break
      fi
    done
  fi

  # Check weekly limit
  if [[ "$weekly_pct" =~ ^[0-9]+$ ]]; then
    for t in "${thresholds[@]}"; do
      if (( weekly_pct <= t && prev_weekly_pct > t )); then
        send_alert "⚠️ *Codex weekly limit at ${weekly_pct}% remaining* (crossed ${t}% threshold). Resets ${weekly_reset}${pace_suffix}"
        break
      fi
    done
  fi

  # Save state
  saved_5h_pct="$prev_5h_pct"
  saved_weekly_pct="$prev_weekly_pct"
  [[ "$five_h_pct" =~ ^[0-9]+$ ]] && saved_5h_pct="$five_h_pct"
  [[ "$weekly_pct" =~ ^[0-9]+$ ]] && saved_weekly_pct="$weekly_pct"
  local state_tmp
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  printf '%s\n' \
    'state_version=2' \
    "prev_5h_pct=${saved_5h_pct}" \
    "prev_weekly_pct=${saved_weekly_pct}" \
    "five_h_armed_reset_at=${five_h_armed_reset_at}" \
    "weekly_armed_reset_at=${weekly_armed_reset_at}" \
    "last_notified_5h_reset_at=${last_notified_5h_reset_at}" \
    "last_notified_weekly_reset_at=${last_notified_weekly_reset_at}" > "$state_tmp"
  mv -f "$state_tmp" "$STATE_FILE"
}

# ============================================================================
# Main
# ============================================================================
run_once() {
  local interval_seconds="$1"
  echo "[$(date -u +%H:%M:%SZ)] Scraping codex status..."

  local json
  json=$(fetch_status_json "$interval_seconds") || return 1

  # Pretty-print to terminal
  echo "$json" | python3 -m json.tool 2>/dev/null || echo "$json"

  # Write locally
  write_local_snapshot "$json" "$interval_seconds"

  # Read history for gist sync
  local history_json="[]"
  if [[ -f "$HISTORY_FILE" ]]; then
    history_json=$(cat "$HISTORY_FILE")
  fi

  # Optionally sync to GitHub Gist
  sync_gist "$json" "$history_json"

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
    "$five_h_reset_at" "$weekly_reset_at" "$scraped_at_epoch"
}

validate_interval() {
  local interval="$1"
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] Loop interval must be a positive integer number of seconds." >&2
    return 1
  fi
}

seconds_until_next_interval() {
  local now_epoch="$1"
  local interval="$2"
  printf '%s\n' "$((interval - now_epoch % interval))"
}

main() {
  local interval="${LOOP_INTERVAL:-$DEFAULT_INTERVAL_SECONDS}"
  local now_epoch delay next_epoch next_check
  check_requirements

  if [[ "${1:-}" == "--loop" ]]; then
    interval="${2:-$interval}"
    validate_interval "$interval" || exit 1
    echo "Starting monitor loop (aligned interval: ${interval}s). Press Ctrl+C to stop."
    while true; do
      run_once "$interval" || echo "[WARN] Scrape cycle failed, will retry at the next scheduled check"
      now_epoch="$(date -u +%s)"
      delay="$(seconds_until_next_interval "$now_epoch" "$interval")"
      next_epoch="$((now_epoch + delay))"
      next_check="$(date -u -d "@${next_epoch}" +%H:%M:%SZ)"
      echo "[$(date -u +%H:%M:%SZ)] Next check at ${next_check} (in ${delay}s)..."
      sleep "$delay"
    done
  else
    validate_interval "$interval" || exit 1
    run_once "$interval"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
