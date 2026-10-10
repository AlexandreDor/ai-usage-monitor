#!/usr/bin/env bash
# Serve only explicitly allowlisted dashboard files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PY="${SCRIPT_DIR}/config.py"
ENV_FILE="${CODEX_MONITOR_ENV_FILE:-${SCRIPT_DIR}/.env}"
RUNTIME_DIR="${CODEX_MONITOR_RUNTIME_DIR:-${SCRIPT_DIR}/runtime}"
ANALYTICS_DATABASE_PATH="${DASHBOARD_ANALYTICS_DATABASE:-}"
ANALYTICS_PRICING_PATH="${DASHBOARD_PRICING_FILE:-${TOKEN_PRICING_FILE:-}}"
DASHBOARD_ACTIVE_INTERVAL="${DASHBOARD_ACTIVE_INTERVAL_SECONDS:-}"
PORT=8080
BIND_ADDRESS="127.0.0.1"
POSITIONAL_PORT=""
PORT_WAS_NAMED=false

usage() {
  cat <<'EOF'
Usage: ./serve.sh [--port PORT] [--bind ADDRESS]
       ./serve.sh [PORT]

Serve the local Codex usage dashboard.

Options:
  --port PORT      TCP port (1-65535, default: 8080)
  --bind ADDRESS   IP address to listen on (default: 127.0.0.1)
                   Use --bind 0.0.0.0 explicitly to allow LAN access.
  -h, --help       Show this help

The server provides no authentication and no TLS. Do not expose it to an
untrusted network; use a properly configured reverse proxy if either is needed.

For compatibility, one positional PORT is accepted. Positional bind addresses
are not accepted; network exposure must use --bind explicitly.
EOF
}

while (($#)); do
  case "$1" in
    --port)
      (($# >= 2)) || { echo "[ERROR] --port requires a value." >&2; exit 2; }
      PORT="$2"
      PORT_WAS_NAMED=true
      shift 2
      ;;
    --bind)
      (($# >= 2)) || { echo "[ERROR] --bind requires a value." >&2; exit 2; }
      BIND_ADDRESS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$POSITIONAL_PORT" || "$PORT_WAS_NAMED" == true ]]; then
        echo "[ERROR] Unexpected positional argument: $1" >&2
        usage >&2
        exit 2
      fi
      POSITIONAL_PORT="$1"
      PORT="$1"
      shift
      ;;
  esac
done

# The shared Python resolver is the source of truth for the server.
if ! command -v python3 &>/dev/null; then
  echo "[ERROR] python3 is required to serve the dashboard." >&2
  exit 1
fi
config_transport="$(mktemp "${TMPDIR:-/tmp}/codex-dashboard-config.XXXXXX")" || {
  echo "[ERROR] Unable to create a private configuration transport." >&2
  exit 1
}
config_transport_error=0
if ! python3 "$CONFIG_PY" --profile serve --env-file "$ENV_FILE" \
    --script-dir "$SCRIPT_DIR" --bind "$BIND_ADDRESS" --port "$PORT" >"$config_transport"; then
  rm -f -- "$config_transport"
  exit 2
fi
while IFS= read -r -d '' config_record; do
  config_key="${config_record%%$'\t'*}"
  config_encoded="${config_record#*$'\t'}"
  config_value="$(printf '%s' "$config_encoded" | base64 --decode)" || {
    config_transport_error=1
    break
  }
  case "$config_key" in
    TOKEN_PRICING_FILE) ANALYTICS_PRICING_PATH="$config_value" ;;
    DASHBOARD_ACTIVE_INTERVAL_SECONDS) DASHBOARD_ACTIVE_INTERVAL="$config_value" ;;
    ANALYTICS_DATABASE_PATH|PORT|BIND_ADDRESS) printf -v "$config_key" '%s' "$config_value" ;;
  esac
done <"$config_transport"
rm -f -- "$config_transport"
if (( ${config_transport_error:-0} )); then
  echo "[ERROR] Invalid configuration transport." >&2
  exit 1
fi

DISPLAY_ADDRESS="$BIND_ADDRESS"
if [[ "$BIND_ADDRESS" == *:* ]]; then
  DISPLAY_ADDRESS="[$BIND_ADDRESS]"
fi

echo "Serving dashboard at http://${DISPLAY_ADDRESS}:${PORT}/dashboard.html"
echo "Only allowlisted dashboard assets and usage JSON are exposed. Press Ctrl+C to stop."

exec python3 "$SCRIPT_DIR/http_server.py" "$SCRIPT_DIR" "$PORT" "$BIND_ADDRESS" \
  "$ANALYTICS_DATABASE_PATH" "$ANALYTICS_PRICING_PATH" "$DASHBOARD_ACTIVE_INTERVAL" "$RUNTIME_DIR"
