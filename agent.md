# Agent Context: codex-usage-monitor

## Project Purpose

A lightweight, local-first tool to track OpenAI Codex CLI usage limits. Scrapes `codex /status` every 15 minutes, writes JSON to disk, serves a browser dashboard, and fires Discord/Telegram alerts via direct `curl` — no cloud accounts or backend servers required.

## Architecture (Tiered)

### Tier 1 — Local only (default)
```
codex /status → monitor.sh → data.json + history.json → dashboard.html (via serve.sh)
                           → Discord/Telegram alerts (direct curl)
```

### Tier 2 — External dashboard (optional, enabled by setting GITHUB_PAT + GITHUB_GIST_ID)
```
monitor.sh → PATCH GitHub Gist → dashboard/index.html on GitHub Pages reads Gist JSON
```

## Repository Layout

```
codex-usage-monitor/
├── local/
│   ├── monitor.sh          # Main script: scrape → write JSON → alert → [optional gist sync]
│   ├── dashboard.html      # Unified dashboard: local mode by default, Gist mode if GIST_ID set
│   ├── serve.sh            # Starts python3 HTTP server on :8080
│   └── .env.example        # Config template (copy to .env, git-ignored)
├── Dockerfile              # Alpine + bash + curl + python3 + Node/codex
├── docker-compose.yml      # One-command run: monitor loop + HTTP server on :8080
├── docker-entrypoint.sh    # Container startup script
├── .gitignore
├── LICENSE
├── README.md
└── agent.md                # This file
```

## Key Files

- **`local/monitor.sh`** — Core script. Runs `codex /status`, strips ANSI, parses with `grep -P`, writes `data.json` (latest) and `history.json` (rolling 96-entry array). Sends alerts via `curl` to Discord/Telegram on threshold crossings. Optionally PATCHes a GitHub Gist if `GITHUB_PAT` + `GITHUB_GIST_ID` are set. Accepts `--loop <seconds>` flag.
- **`local/dashboard.html`** — Unified dark-themed dashboard. By default reads `data.json` and `history.json` via `fetch()` (local mode). If `GIST_ID` is set at the top of the script block, switches to GitHub Gist API mode for external/GitHub Pages hosting. Must be served via HTTP (not `file://`) — use `serve.sh` or Docker. Auto-refreshes every 60s. Uses Chart.js from CDN.
- **`local/serve.sh`** — Starts `python3 -m http.server 8080` pointing at `local/`. Accepts optional port argument.
- **`Dockerfile` + `docker-compose.yml`** — Runs monitor on a schedule + HTTP server in a single Alpine container. Mounts `local/` as a volume so data persists on the host.

## Configuration Variables (local/.env)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `DISCORD_WEBHOOK` | No | — | Discord webhook URL for alerts |
| `TELEGRAM_BOT_TOKEN` | No | — | Telegram bot token from BotFather |
| `TELEGRAM_CHAT_ID` | No | — | Numeric Telegram chat ID |
| `ALERT_THRESHOLDS` | No | `75,50,25,10,5` | Comma-separated % thresholds |
| `GITHUB_PAT` | No (Tier 2) | — | GitHub PAT with `gist` scope |
| `GITHUB_GIST_ID` | No (Tier 2) | — | ID of Gist to update |
| `LOOP_INTERVAL` | No (Docker) | `900` | Seconds between scrapes |

## Run Options Summary

| Method | Best for | Command |
|---|---|---|
| tmux | Any Linux/macOS | `tmux new -s codex-monitor './monitor.sh --loop 900'` |
| Docker Compose | Windows, always-on | `docker compose up -d` |
| WSL | Windows without Docker | Run bash inside WSL2 |
| LXC | Proxmox homelab | Systemd inside container |
| systemd | Headless Linux server | `systemctl enable --now codex-monitor` |
| cron | Minimal footprint | `*/15 * * * * /path/monitor.sh` |

## Notifications: How They Work

Discord and Telegram alerts are fired with a single `curl` call directly from `monitor.sh`. **No server or backend is needed.** The machine running the script must have internet access.

- Discord: `curl -X POST $DISCORD_WEBHOOK -d '{"content":"..."}'`
- Telegram: `curl -X POST https://api.telegram.org/bot.../sendMessage -d 'chat_id=...&text=...'`

Alert state is persisted in `.alert_state` so each threshold fires only once per crossing.

## Known Limitations

- **`grep -P` required** — macOS default grep lacks Perl regex. Fix: `brew install grep`.
- **Output-format dependency** — parser breaks if OpenAI changes `codex /status` ASCII layout. Parse failures are logged, never silently swallowed.
- **`fetch()` from `file://` blocked by CORS** — always use `serve.sh` or Docker, not direct file open.
- **Single account per instance** — one `.env`, one account. Run multiple instances for multiple accounts.
- **24h rolling history only** — full retention would require date-keyed storage.
