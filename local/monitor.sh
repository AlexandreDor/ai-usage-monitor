#!/usr/bin/env bash
# ============================================================================
# Codex Usage Monitor — Local Scraper & Alert Script
# ============================================================================
# Runs on the machine where OpenAI Codex CLI is installed and authenticated.
# Scrapes `codex /status`, parses usage percentages, writes data.json locally,
# fires Discord/Telegram alerts via direct curl (no server needed), and
# optionally syncs data to a GitHub Gist for external dashboard access.
#
# Usage:
#   ./monitor.sh              # run once
#   ./monitor.sh --loop 900   # run every 900 seconds (15 min)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
STATE_FILE="${SCRIPT_DIR}/.alert_state"
DATA_FILE="${SCRIPT_DIR}/data.json"
HISTORY_FILE="${SCRIPT_DIR}/history.json"
DEFAULT_INTERVAL_SECONDS=900

# Load .env if present
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

# Defaults
ALERT_THRESHOLDS="${ALERT_THRESHOLDS:-75,50,25,10,5}"
HISTORY_RETENTION_HOURS="${HISTORY_RETENTION_HOURS:-24}"

# ============================================================================
# Validation
# ============================================================================
check_requirements() {
  local missing=0

  if ! command -v codex &>/dev/null; then
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

  if ! grep -oP '1' <<<"1" &>/dev/null; then
    echo "[ERROR] This script requires grep with PCRE support (-P)."
    echo "        On macOS, install GNU grep and add it to PATH."
    missing=1
  fi

  if [[ -n "${GITHUB_PAT:-}" && -z "${GITHUB_GIST_ID:-}" ]]; then
    echo "[WARN] GITHUB_PAT is set but GITHUB_GIST_ID is missing. Gist sync disabled."
  fi

  if [[ $missing -eq 1 ]]; then
    exit 1
  fi
}

run_status_command() {
  local codex_cmd
  codex_cmd="${CODEX_BIN:-codex}"

  python3 - "$codex_cmd" "${CODEX_STATUS_TIMEOUT_SECONDS:-20}" <<'PYEOF'
import os
import re
import select
import signal
import subprocess
import sys
import time

codex_cmd = sys.argv[1]
timeout_seconds = max(5, int(sys.argv[2]))
trust_ack_sent = False
deadline = time.monotonic() + timeout_seconds
next_status_attempt = time.monotonic() + 4
status_attempts = 0
max_status_attempts = 4
buffer = []

master_fd, slave_fd = os.openpty()

try:
    proc = subprocess.Popen(
        [codex_cmd, "--no-alt-screen"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
finally:
    os.close(slave_fd)

try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master_fd], [], [], 0.2)
        if ready:
            chunk = os.read(master_fd, 65536)
            if not chunk:
                break
            text = chunk.decode("utf-8", errors="ignore")
            buffer.append(text)
            joined = "".join(buffer)
            normalized = joined.replace("\r", "\n")

            if (
                not trust_ack_sent
                and (
                    "Do you trust the contents of this directory" in normalized
                    or "Press enter to continue" in normalized
                    or "prompt injection" in normalized
                )
            ):
                os.write(master_fd, b"1\r")
                trust_ack_sent = True
                next_status_attempt = time.monotonic() + 3
                continue

            if (
                status_attempts < max_status_attempts
                and time.monotonic() >= next_status_attempt
            ):
                os.write(master_fd, b"/status\r")
                status_attempts += 1
                next_status_attempt = time.monotonic() + 2

            if re.search(r"5h limit", normalized, re.IGNORECASE) and re.search(r"weekly limit", normalized, re.IGNORECASE):
                time.sleep(0.5)
                break
        elif (
            status_attempts < max_status_attempts
            and time.monotonic() >= next_status_attempt
        ):
            os.write(master_fd, b"/status\r")
            status_attempts += 1
            next_status_attempt = time.monotonic() + 2

    try:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=2)
    except Exception:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()
            proc.wait(timeout=2)
finally:
    os.close(master_fd)

output = "".join(buffer)
if not output.strip():
    sys.stderr.write("[ERROR] codex status capture returned empty output\n")
    sys.exit(1)

debug_path = os.environ.get("CODEX_STATUS_DEBUG_FILE")
if debug_path:
    with open(debug_path, "w", encoding="utf-8") as fh:
        fh.write(output)

sys.stdout.write(output)
PYEOF
}

normalize_status_output() {
  python3 -c "import re, sys; data = sys.stdin.read(); data = data.replace('\r\n', '\n').replace('\r', '\n').replace('\u2502', '|'); data = re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\\\)|[@-_])', '', data); data = ''.join(ch for ch in data if ch in '\n\t' or ord(ch) >= 32); print(data, end='')"
}

build_status_json() {
  python3 - "$@" <<'PYEOF'
import json
import sys

payload = {
    "five_h_pct": int(sys.argv[1]),
    "five_h_reset": sys.argv[2],
    "weekly_pct": int(sys.argv[3]),
    "weekly_reset": sys.argv[4],
    "account": sys.argv[5],
    "scraped_at": sys.argv[6],
    "sample_interval_seconds": int(sys.argv[7]),
    "history_window_hours": float(sys.argv[8]),
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
if isinstance(value, float) and value.is_integer():
    value = int(value)
print(value)
PYEOF
}

parse_status_from_raw() {
  local raw="$1"
  local interval_seconds="$2"
  local cleaned five_h_pct five_h_reset weekly_pct weekly_reset account scraped_at

  cleaned="$(printf '%s' "$raw" | sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[[0-9;]*[a-zA-Z]//g' | normalize_status_output)"

  if [[ -z "$cleaned" ]]; then
    echo "[ERROR] codex /status returned empty output" >&2
    return 1
  fi

  five_h_pct=$(printf '%s\n' "$cleaned" | grep -i "5h limit" | grep -oP '\d+(?=% left)' || true)
  five_h_reset=$(printf '%s\n' "$cleaned" | grep -i "5h limit" | grep -oP '(?<=resets ).*?(?=\)|\s*\||$)' | head -n 1 | sed 's/[[:space:]]*$//' || true)
  weekly_pct=$(printf '%s\n' "$cleaned" | grep -i "weekly limit" | grep -oP '\d+(?=% left)' || true)
  weekly_reset=$(printf '%s\n' "$cleaned" | grep -i "weekly limit" | grep -oP '(?<=resets ).*?(?=\)|\s*\||$)' | head -n 1 | sed 's/[[:space:]]*$//' || true)
  account=$(printf '%s\n' "$cleaned" | grep -iE '^[[:space:]]*Account:' | tail -n 1 | sed 's/.*Account:[[:space:]]*//' | sed 's/[[:space:]]*|.*$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)

  if [[ -z "$five_h_pct" && -z "$weekly_pct" ]]; then
    echo "[ERROR] Could not parse usage percentages from codex output." >&2
    echo "[DEBUG] Raw output:" >&2
    printf '%s\n' "$cleaned" >&2
    return 1
  fi

  five_h_pct="${five_h_pct:-0}"
  weekly_pct="${weekly_pct:-0}"
  five_h_reset="${five_h_reset:-unknown}"
  weekly_reset="${weekly_reset:-unknown}"
  account="${account:-}"
  scraped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  build_status_json \
    "$five_h_pct" \
    "$five_h_reset" \
    "$weekly_pct" \
    "$weekly_reset" \
    "$account" \
    "$scraped_at" \
    "$interval_seconds" \
    "$HISTORY_RETENTION_HOURS"
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
import pathlib
import sys

history_path = pathlib.Path(sys.argv[1])
data_path = pathlib.Path(sys.argv[2])
new_entry = json.loads(sys.argv[3])
max_entries = int(sys.argv[4])

history = []
if history_path.exists():
    try:
        history = json.loads(history_path.read_text(encoding="utf-8"))
        if not isinstance(history, list):
            history = []
    except Exception:
        history = []

history.insert(0, new_entry)
history = history[:max_entries]

history_path.write_text(json.dumps(history, indent=2) + "\n", encoding="utf-8")
data_path.write_text(json.dumps(new_entry, indent=2) + "\n", encoding="utf-8")
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
# Scrape and parse codex /status
# ============================================================================
scrape_status() {
  # Capture raw output, strip ANSI escape codes
  local raw
  raw=$(codex /status 2>&1 | sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[[0-9;]*[a-zA-Z]//g')

  if [[ -z "$raw" ]]; then
    echo "[ERROR] codex /status returned empty output" >&2
    return 1
  fi

  # Parse 5h limit
  local five_h_pct five_h_reset weekly_pct weekly_reset model account

  five_h_pct=$(echo "$raw" | grep -i "5h limit" | grep -oP '\d+(?=% left)' || echo "")
  five_h_reset=$(echo "$raw" | grep -i "5h limit" | grep -oP '(?<=resets )\S+' || echo "")

  weekly_pct=$(echo "$raw" | grep -i "weekly limit" | grep -oP '\d+(?=% left)' || echo "")
  weekly_reset=$(echo "$raw" | grep -i "weekly limit" | grep -oP '(?<=resets ).*?(?=\s*[│\|]|$)' | sed 's/[[:space:]]*$//' || echo "")

  model=$(echo "$raw" | grep -i "Model:" | sed 's/.*Model:\s*//' | sed 's/\s*│.*$//' | xargs || echo "unknown")
  account=$(echo "$raw" | grep -i "Account:" | sed 's/.*Account:\s*//' | sed 's/\s*│.*$//' | xargs || echo "unknown")

  # Validate we got something
  if [[ -z "$five_h_pct" && -z "$weekly_pct" ]]; then
    echo "[ERROR] Could not parse usage percentages from codex output." >&2
    echo "[DEBUG] Raw output:" >&2
    echo "$raw" >&2
    return 1
  fi

  # Default to 0 if one is missing
  five_h_pct="${five_h_pct:-0}"
  weekly_pct="${weekly_pct:-0}"

  # Build JSON
  cat <<EOF
{
  "five_h_pct": ${five_h_pct},
  "five_h_reset": "${five_h_reset}",
  "weekly_pct": ${weekly_pct},
  "weekly_reset": "${weekly_reset}",
  "model": "${model}",
  "account": "${account}",
  "scraped_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# ============================================================================
# Write data to local disk
# ============================================================================
write_local() {
  local json="$1"

  # Append to history array (keep last 96 entries = 24h at 15-min intervals)
  local history_file="${SCRIPT_DIR}/history.json"
  local now_entry
  now_entry="$json"

  if [[ -f "$history_file" ]]; then
    # Read existing history, prepend new entry, trim to 96
    local existing
    existing=$(cat "$history_file")
    # Use python3 for reliable JSON array manipulation
    python3 - <<PYEOF
import json, sys

new_entry = json.loads('''${json}''')
try:
    history = json.loads('''${existing}''')
    if not isinstance(history, list):
        history = []
except Exception:
    history = []

history.insert(0, new_entry)
history = history[:96]  # keep 24h of 15-min samples
print(json.dumps(history, indent=2))
PYEOF
  else
    echo "[${json}]"
  fi > "$history_file"

  # Write latest snapshot
  echo "$json" > "$DATA_FILE"
  echo "[OK] Data written to ${DATA_FILE}"
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
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PATCH "https://api.github.com/gists/${GITHUB_GIST_ID}" \
    -H "Authorization: token ${GITHUB_PAT}" \
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

  curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return; fi

  curl -s -o /dev/null -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}"
}

send_alert() {
  local message="$1"
  echo "[ALERT] $message"
  send_discord "$message"
  send_telegram "$message"
}

check_thresholds() {
  local five_h_pct="$1"
  local weekly_pct="$2"
  local five_h_reset="$3"
  local weekly_reset="$4"

  # Load previous alert state
  local prev_5h_pct=100
  local prev_weekly_pct=100
  local thresholds
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi

  mapfile -t thresholds < <(load_thresholds)

  # Check 5h limit (sort descending so we catch the highest crossed threshold first)
  for t in "${thresholds[@]}"; do
    if (( five_h_pct <= t && prev_5h_pct > t )); then
      send_alert "⚠️ *Codex 5h limit at ${five_h_pct}% remaining* (crossed ${t}% threshold). Resets at ${five_h_reset}"
      break
    fi
  done

  # Check weekly limit
  for t in "${thresholds[@]}"; do
    if (( weekly_pct <= t && prev_weekly_pct > t )); then
      send_alert "⚠️ *Codex weekly limit at ${weekly_pct}% remaining* (crossed ${t}% threshold). Resets ${weekly_reset}"
      break
    fi
  done

  # Save state
  cat > "$STATE_FILE" <<EOF
prev_5h_pct=${five_h_pct}
prev_weekly_pct=${weekly_pct}
EOF
}

# ============================================================================
# Main
# ============================================================================
run_once() {
  local interval_seconds="$1"
  echo "[$(date -u +%H:%M:%SZ)] Scraping codex status..."

  local json
  json=$(parse_status_from_raw "$(run_status_command)" "$interval_seconds") || return 1

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
  local five_h weekly five_h_reset weekly_reset
  five_h=$(json_get_field "$json" "five_h_pct")
  weekly=$(json_get_field "$json" "weekly_pct")
  five_h_reset=$(json_get_field "$json" "five_h_reset")
  weekly_reset=$(json_get_field "$json" "weekly_reset")

  check_thresholds "$five_h" "$weekly" "$five_h_reset" "$weekly_reset"
}

main() {
  local interval="${LOOP_INTERVAL:-$DEFAULT_INTERVAL_SECONDS}"
  check_requirements

  if [[ "${1:-}" == "--loop" ]]; then
    interval="${2:-$interval}"
    echo "Starting monitor loop (interval: ${interval}s). Press Ctrl+C to stop."
    while true; do
      run_once "$interval" || echo "[WARN] Scrape cycle failed, will retry next interval"
      echo "[$(date -u +%H:%M:%SZ)] Next check in ${interval}s..."
      sleep "$interval"
    done
  else
    run_once "$interval"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
