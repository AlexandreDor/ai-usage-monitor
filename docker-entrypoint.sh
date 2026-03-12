#!/usr/bin/env sh
# ============================================================================
# docker-entrypoint.sh
# Fails fast if the monitor cannot start, then keeps the HTTP server and the
# monitor process coupled so the container does not keep serving stale data.
# ============================================================================

set -eu

LOOP_INTERVAL="${LOOP_INTERVAL:-900}"
SERVER_PID=""
MONITOR_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
  fi
}

trap cleanup INT TERM EXIT

echo "=== Codex Usage Monitor Container ==="
echo "Poll interval: ${LOOP_INTERVAL}s"
echo "Dashboard:     http://localhost:8080/dashboard.html"
echo ""

# Load .env if mounted (support docker run --env-file or manual mount)
if [ -f /app/.env ]; then
  set -a
  . /app/.env
  set +a
fi

echo "Running startup scrape..."
/app/monitor.sh

echo "Starting monitor loop..."
/app/monitor.sh --loop "$LOOP_INTERVAL" &
MONITOR_PID="$!"

echo "Starting HTTP server on :8080..."
python3 -m http.server 8080 --directory /app &
SERVER_PID="$!"

while true; do
  if ! kill -0 "$MONITOR_PID" 2>/dev/null; then
    echo "[ERROR] monitor.sh exited; stopping container to avoid serving stale data."
    wait "$MONITOR_PID" || true
    exit 1
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    wait "$SERVER_PID" || true
    exit 1
  fi
  sleep 5
done
