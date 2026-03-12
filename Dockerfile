# ============================================================================
# Dockerfile — Codex Usage Monitor (local container)
# ============================================================================
# Runs monitor.sh on a schedule AND serves the dashboard on port 8080.
# Mount your .env file and a volume for persisted data.
#
# Build:   docker build -t codex-monitor .
# Run:     docker run -d --env-file local/.env -p 8080:8080 \
#            -v "$(pwd)/local":/data --name codex-monitor codex-monitor
# Or use:  docker compose up -d
# ============================================================================

FROM alpine:3.19

# Install bash, curl, python3 (for HTTP server + JSON manipulation)
RUN apk add --no-cache bash curl python3 grep pcre2-tools

# Install OpenAI Codex CLI (requires Node.js)
RUN apk add --no-cache nodejs npm && \
    npm install -g @openai/codex

WORKDIR /app

# Copy the local monitor files
COPY local/monitor.sh ./monitor.sh
COPY local/dashboard.html ./dashboard.html
COPY local/serve.sh ./serve.sh

RUN chmod +x monitor.sh serve.sh

# Data volume — mount local/ from host for persistent data.json / history.json
VOLUME ["/app"]

# Entrypoint: run monitor on a loop AND serve the dashboard
# LOOP_INTERVAL env var controls poll frequency (default 900 = 15 min)
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint.sh"]
