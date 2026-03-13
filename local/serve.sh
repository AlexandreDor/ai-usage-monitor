#!/usr/bin/env bash
# ============================================================================
# serve.sh — Start a local HTTP server for the Codex Usage Monitor dashboard
# ============================================================================
# Opens the dashboard at http://localhost:8080/dashboard.html
# Requires python3 (standard on Linux/macOS/WSL) OR python (Windows).
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8080}"

echo "Serving dashboard at http://localhost:${PORT}/dashboard.html"
echo "Press Ctrl+C to stop."
echo ""

if command -v python3 &>/dev/null; then
  python3 -m http.server "$PORT" --directory "$SCRIPT_DIR"
elif command -v python &>/dev/null; then
  cd "$SCRIPT_DIR" && python -m SimpleHTTPServer "$PORT"
else
  echo "[ERROR] python3 or python is required to serve the dashboard."
  echo "        Install Python from https://python.org or use the Docker option."
  exit 1
fi
