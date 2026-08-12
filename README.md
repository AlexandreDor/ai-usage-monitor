# Codex Usage Monitor

Codex Usage Monitor is a local dashboard and alerting tool for OpenAI Codex CLI
usage limits. It tracks the active 5-hour and weekly quota windows, keeps a
rolling history, stores long-term analytics locally, and can notify you before
available quota runs low.

The core monitor runs with Bash, Python, `curl`, and the authenticated Codex CLI.
No hosted backend is required. Optional integrations can send notifications,
publish the current dashboard data through a GitHub Gist, or display global
reset probabilities from the independent Codex Forecast service.

## Features

### Live quota dashboard

- Current remaining quota for the active 5-hour and weekly windows.
- Reset dates and weekly pace compared with ideal consumption.
- Rolling history chart generated from local snapshots.
- Mouse and touch exploration by nearest time slice, with a vertical cursor and
  one tooltip for every visible quota series at that time.
- Automatic refresh based on the monitor collection interval.
- Local and optional Gist-backed external modes.
- English and French interfaces.
- EUR and USD display preferences shared across both pages.
- Optional global 24-hour and 6-hour reset probabilities from
  [Codex Forecast](https://codex.lunarwerx.com/).
- No direct third-party request from the browser: the monitor fetches Forecast
  data and publishes only the current probabilities.

### Advanced Analytics

The local Analytics page provides:

- quota history and ideal weekly pace for 24 hours, 7, 30, or 90 days, one year,
  all retained data, or a custom date range;
- detected 5-hour and weekly reset history, including scheduled and early
  weekly resets;
- local token consumption from Codex, OpenCode, and Hermes;
- uncached input, cache read, cache write, output, reasoning, and total token
  counters;
- filtering by application and model, with GPT-5.6 models selected by default
  when available;
- quota, token, and API-equivalent cost charts;
- mouse and touch exploration by nearest time slice, grouping visible series
  while preserving percentage, token, and currency units;
- cost allocation by application, provider, and model;
- USD estimates from the local pricing catalog and optional EUR display
  conversion;
- collector freshness, warnings, and accessible text/table alternatives for
  Analytics charts.

Analytics data stays in the local SQLite archive and is not synchronized to the
Gist. Cost values are estimates, not billing statements. Reasoning tokens are a
subset of output tokens and are not counted twice. Models without a catalog
price remain visible and are valued at zero with a warning.

### Alerts

- Configurable low-quota thresholds for the 5-hour and weekly windows.
- One alert for the most critical threshold when several levels are crossed in
  a single collection.
- Automatic notifications for scheduled 5-hour and weekly resets.
- Detection of conservative early weekly refills.
- Discord and Telegram delivery with independent durable state per channel.
- Bounded retries for temporary network errors without replaying a channel that
  already succeeded.
- Optional trusted local scripts for threshold and reset events.
- No notification or Gist credential is passed to local alert scripts or the
  Codex subprocess.

### Local storage and diagnostics

- Current snapshot in `local/runtime/data.json`.
- Rolling dashboard history in `local/runtime/history.json`.
- Long-term quota, reset, and token archive in
  `local/runtime/usage-history.sqlite3`.
- Cycle health information in `local/runtime/health.json`.
- A process lock prevents concurrent monitor cycles.
- Atomic writes and private runtime permissions.
- Configuration, dependencies, Codex authentication, and analytics source
  validation through `./monitor.sh --check`.

## Requirements

- Linux or WSL. Native Windows execution is not supported.
- Bash.
- Python 3.9 or newer with `Europe/Paris` timezone data.
- `curl`.
- `flock`.
- OpenAI Codex CLI installed and authenticated.
- `timeout` only when local alert scripts are configured.

Verify Codex before starting:

```bash
codex login status
codex /status
```

## Quick Start

```bash
git clone https://github.com/AlexandreDor/ai-usage-monitor.git
cd ai-usage-monitor/local

cp .env.example .env
chmod 600 .env

./monitor.sh --check
./monitor.sh --loop
```

In a second terminal:

```bash
cd ai-usage-monitor/local
./serve.sh
```

Open:

- live dashboard: <http://127.0.0.1:8080/dashboard.html>
- advanced analytics: <http://127.0.0.1:8080/analytics.html>

`monitor.sh` performs one collection immediately before entering loop mode. At
the default 900-second interval, later runs align with `:00`, `:15`, `:30`, and
`:45` instead of drifting from the previous execution time.

## Monitor Commands

| Command | Behavior |
|---|---|
| `./monitor.sh` | Run one complete collection cycle. |
| `./monitor.sh --once` | Explicit form of a single collection cycle. |
| `./monitor.sh --loop` | Run immediately, then continue at `LOOP_INTERVAL`. |
| `./monitor.sh --loop 300` | Override the loop interval for this process. |
| `./monitor.sh --loop --fail-fast` | Stop loop mode after the first failed cycle. |
| `./monitor.sh --check` | Validate configuration, dependencies, paths, Codex authentication, and analytics sources without collecting data. |
| `./monitor.sh --status-json` | Print the current sanitized Codex quota snapshot as JSON without storing it. |

`--fail-fast` only affects loop mode. The monitor does not currently provide a
`--help` option.

## Dashboard Server Commands

```bash
./serve.sh
./serve.sh --port 9090
./serve.sh --bind 0.0.0.0 --port 8080
./serve.sh --help
```

The default bind address is `127.0.0.1`. The server has no authentication or
TLS; only bind it to a trusted network. It exposes an explicit allowlist of
dashboard assets, sanitized JSON files, and the read-only Analytics API. It does
not serve `.env`, SQLite, health data, delivery journals, locks, or directory
listings.

## Configuration

Create `local/.env` from `local/.env.example`. The file is parsed as data and is
never executed as shell code. Keep it owned by the current user and restricted
to mode `600`:

```bash
cp local/.env.example local/.env
chmod 600 local/.env
```

Blank optional values disable the corresponding integration. Unsupported keys
are ignored with a warning, while invalid values for supported keys are
rejected. Environment variables can also provide values; values loaded from
`local/.env` take precedence in the current monitor implementation.

### Minimal configuration

No integration is required. This is enough for local quota monitoring and
automatically detected Analytics sources:

```dotenv
ALERT_THRESHOLDS=75,50,25,10,5
HISTORY_RETENTION_HOURS=192
ARCHIVE_RETENTION_DAYS=365
TOKEN_USAGE_SOURCES=auto
LOOP_INTERVAL=900
CODEX_FORECAST_ENABLED=1
```

### Notifications

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `DISCORD_WEBHOOK` | empty | Official Discord HTTPS webhook URL | Enables Discord alerts. |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token | Enables Telegram when `TELEGRAM_CHAT_ID` is also set. |
| `TELEGRAM_CHAT_ID` | empty | Non-zero integer; negative group IDs are valid | Required with `TELEGRAM_BOT_TOKEN`. |
| `ALERT_THRESHOLDS` | `75,50,25,10,5` | Non-empty comma-separated integers from `0` to `100` | Remaining-quota thresholds monitored independently for 5-hour and weekly limits. |

Discord and Telegram maintain separate delivery progress. Temporary failures
such as timeouts, HTTP 408, 429, or 5xx remain pending. Successful channels are
not replayed because another channel failed.

Example:

```dotenv
DISCORD_WEBHOOK=https://discord.com/api/webhooks/123456789/replace-me

TELEGRAM_BOT_TOKEN=123456789:replace-me
TELEGRAM_CHAT_ID=-1001234567890

ALERT_THRESHOLDS=50,25,10,5
```

The Discord webhook may also use the legacy `discordapp.com` hostname. Telegram
token and chat ID must either both be set or both remain empty.

### Local alert scripts

Local scripts are configured with numbered variable pairs from 1 through 99:

```dotenv
ALERT_SCRIPT_TIMEOUT_SECONDS=30

ALERT_SCRIPT_1=/home/user/ai-usage-monitor/local/scripts/reset-worker.sh
ALERT_SCRIPT_1_EVENTS=5h:reset,weekly:reset

ALERT_SCRIPT_2=/home/user/ai-usage-monitor/local/scripts/reduce-load.sh
ALERT_SCRIPT_2_EVENTS=5h:50,5h:25,weekly:20
```

| Variable | Default | Rules |
|---|---:|---|
| `ALERT_SCRIPT_TIMEOUT_SECONDS` | `30` | Integer from `1` to `1800`. |
| `ALERT_SCRIPT_<N>` | empty | Absolute path to an executable regular file. Arguments are not parsed; use a wrapper script. |
| `ALERT_SCRIPT_<N>_EVENTS` | empty | Comma-separated `5h:reset`, `weekly:reset`, `5h:<0..100>`, or `weekly:<0..100>` selectors. |

Indices may be sparse. Several scripts can handle the same event, and one
script can handle several events. A configured script action is attempted once;
failure or timeout is logged but not retried and does not stop later scripts.
Personal scripts can be stored under `local/scripts/`, whose contents are
ignored by Git except for `.gitkeep`.

Scripts receive:

| Variable | Content |
|---|---|
| `CODEX_ALERT_EVENT` | `threshold` or `reset` |
| `CODEX_ALERT_WINDOW` | `5h` or `weekly` |
| `CODEX_ALERT_THRESHOLD` | Crossed threshold, empty for a reset |
| `CODEX_ALERT_REMAINING_PCT` | Remaining percentage |
| `CODEX_ALERT_RESET_AT` | Reset Unix timestamp when known |
| `CODEX_ALERT_RESET_LABEL` | Human-readable reset date when known |
| `CODEX_ALERT_SCRAPED_AT` | Observation Unix timestamp |
| `CODEX_ALERT_MESSAGE` | Human-readable alert text |
| `CODEX_ALERT_RULE_INDEX` | Matching rule number |

### History and collection

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `LOOP_INTERVAL` | `900` | Integer from `1` to `86400` seconds | Collection cadence used by `--loop`. |
| `HISTORY_RETENTION_HOURS` | `192` | Number from `0.25` to `8760` | Age-based rolling window for `history.json`; defensive limits of 10,000 entries and 16 MiB also apply. |
| `ARCHIVE_RETENTION_DAYS` | `365` | Integer from `0` to `36500` | SQLite retention; `0` keeps data indefinitely. |
| `CODEX_STATUS_TIMEOUT_SECONDS` | `20` | Integer from `5` to `300` | Timeout for the Codex app-server status request. |
| `CODEX_BIN` | `codex` | Executable name or path | Codex CLI command used by the monitor. |
| `MONITOR_DEBUG` | `0` | `0` or `1` | Enables bounded sanitized Codex and HTTP diagnostics. |

The SQLite archive retains detailed quota, reset, and token data for Analytics.
The rolling JSON history is separate and retains samples according to their
actual timestamps. Changing the collection interval does not change the time
span requested by `HISTORY_RETENTION_HOURS`; only the defensive entry and size
limits can shorten it.

### Token Analytics

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `TOKEN_USAGE_SOURCES` | `auto` | `auto`, `none`, or a comma-separated subset of `codex,opencode,hermes` | Selects local token collectors. |
| `TOKEN_PRICING_FILE` | `local/pricing.json` | Absolute path to a readable regular file that is not a symlink | Versioned pricing catalog used by the monitor and Analytics server. |
| `CODEX_DATA_DIR` | `~/.codex` | Absolute path | Codex rollout/session data directory. |
| `OPENCODE_DB_PATH` | `$XDG_DATA_HOME/opencode/opencode.db` or `~/.local/share/opencode/opencode.db` | Absolute path | OpenCode SQLite database. |
| `HERMES_DB_PATH` | `~/.hermes/state.db` | Absolute path | Hermes state database. |

`auto` enables detected sources and ignores missing or empty optional sources.
An explicitly selected source that cannot be read makes the collection cycle
degraded. `none` disables token collection while quota monitoring continues.

The default pricing catalog is `local/pricing.json`. Custom catalogs must use
the supported schema and USD rates per million tokens. Unknown models are kept
in reports and assigned zero estimated cost.

Example with Codex and OpenCode only:

```dotenv
TOKEN_USAGE_SOURCES=codex,opencode
TOKEN_PRICING_FILE=/home/user/ai-usage-monitor/local/pricing.json
CODEX_DATA_DIR=/home/user/.codex
OPENCODE_DB_PATH=/home/user/.local/share/opencode/opencode.db
```

### Codex Forecast

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `CODEX_FORECAST_ENABLED` | `1` | `0` or `1` | Fetches third-party global reset probabilities once per collection cycle. |

Forecast failures never fail quota collection. Forecast values are included only
in the current `data.json` snapshot and optional Gist payload. They are excluded
from `history.json` and SQLite, and stale values are hidden by the dashboard.

Disable all Forecast requests with:

```dotenv
CODEX_FORECAST_ENABLED=0
```

### HTTP behavior

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `CURL_CONNECT_TIMEOUT_SECONDS` | `5` | Integer from `1` to `60` | Connection timeout. |
| `CURL_MAX_TIME_SECONDS` | `20` | Integer from `1` to `600` | Total request timeout; cannot be lower than the connection timeout. |
| `CURL_RETRIES` | `2` | Integer from `0` to `5` | Number of retries for supported temporary failures. |
| `CURL_RETRY_DELAY_SECONDS` | `1` | Integer from `0` to `60` | Initial retry delay; backoff doubles after each attempt. |

These values apply to the monitor's configurable HTTP integrations. The optional
Forecast request uses its own short fixed bounds so that a third-party outage
cannot delay the monitor for long.

### External dashboard through GitHub Gist

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `GITHUB_PAT` | empty | GitHub classic token with Gist access | Enables Gist synchronization when `GITHUB_GIST_ID` is also set. |
| `GITHUB_GIST_ID` | empty | Hexadecimal Gist ID | Target Gist. |
| `GITHUB_API_URL` | `https://api.github.com` | HTTP(S) base URL without credentials or query string | Primarily available for testing or compatible API endpoints. |

`GITHUB_PAT` and `GITHUB_GIST_ID` must both be configured or both be empty. The
Gist receives the current sanitized quota snapshot and rolling quota history.
It never receives SQLite Analytics data, token usage, credentials, account
identity, alert state, or health data.

The static dashboard reads a configured Gist ID from `GIST_ID` near the top of
`local/assets/dashboard.js`:

```javascript
const GIST_ID = 'your-gist-id';
```

Leave `GIST_ID` empty for local mode. Hosting the static files is intentionally
separate from running the monitor; the machine running `monitor.sh` must keep
updating the Gist.

### Advanced and test overrides

These variables are normally unnecessary:

| Variable | Default | Description |
|---|---:|---|
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Telegram-compatible HTTP(S) API base URL, mainly for tests. |
| `DASHBOARD_ANALYTICS_DATABASE` | `local/runtime/usage-history.sqlite3` | Environment-only absolute database path override for `serve.sh`. |
| `DASHBOARD_PRICING_FILE` | `TOKEN_PRICING_FILE`, then `local/pricing.json` | Environment-only absolute pricing path override for `serve.sh`. |

HTTP endpoint overrides must not contain credentials, query strings, or control
characters. Use HTTPS for real services.

## Common Configurations

### Local dashboard without notifications

```dotenv
TOKEN_USAGE_SOURCES=auto
LOOP_INTERVAL=900
CODEX_FORECAST_ENABLED=1
```

### Private local-only mode with no optional network requests

```dotenv
DISCORD_WEBHOOK=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
GITHUB_PAT=
GITHUB_GIST_ID=
CODEX_FORECAST_ENABLED=0
TOKEN_USAGE_SOURCES=auto
```

### Alerts without external dashboard

```dotenv
DISCORD_WEBHOOK=https://discord.com/api/webhooks/123456789/replace-me
ALERT_THRESHOLDS=25,10,5
GITHUB_PAT=
GITHUB_GIST_ID=
```

### Quota monitoring without token Analytics collection

```dotenv
TOKEN_USAGE_SOURCES=none
```

### Unlimited long-term SQLite retention

```dotenv
ARCHIVE_RETENTION_DAYS=0
```

## Troubleshooting

### `codex` is not found or authentication fails

```bash
which codex
codex login status
codex /status
```

Set `CODEX_BIN` if the executable is outside the normal `PATH`. Increase
`CODEX_STATUS_TIMEOUT_SECONDS` if the local app-server starts slowly.

### The dashboard has no data

Run a collection before starting or refreshing the server:

```bash
cd local
./monitor.sh --once
./serve.sh
```

Do not open `dashboard.html` directly with a `file://` URL.

### Analytics reports that the archive is unavailable

Run `./monitor.sh --once` to initialize the SQLite archive, then reload
`analytics.html`. Use `./monitor.sh --check` to validate configured sources and
the pricing catalog.

### A Gist update returns 401 or 404

- HTTP 401: verify `GITHUB_PAT` and its Gist permission.
- HTTP 404: verify `GITHUB_GIST_ID` and access to the target Gist.

## Deployment

For persistent use, run these two processes under a supervisor such as systemd,
tmux, or another process manager:

```bash
./local/monitor.sh --loop 900
./local/serve.sh
```

The monitor and dashboard server are intentionally separate. The server does
not trigger collections. Use `--bind 0.0.0.0` only behind a trusted firewall or
proper reverse proxy because the built-in server has no authentication or TLS.

For a static external dashboard, publish `local/dashboard.html`, `local/assets/`,
and `local/images/favicon.png`, configure `GIST_ID`, and keep the local monitor
running with Gist credentials.

## Project Internals

- `local/monitor.sh`: collection loop, snapshot publication, integrations, and
  alert orchestration.
- `local/serve.sh`: allowlisted local HTTP server and read-only Analytics API.
- `local/storage.py`, `archive.py`, and `analytics.py`: SQLite storage and query
  logic.
- `local/token_usage.py`: Codex, OpenCode, and Hermes token collectors.
- `local/alerts.py`: durable network delivery journal.
- `local/assets/`: dashboard and Analytics frontend.
- `tests/run.sh`: dependency-free shell, Python, and Node test suite.
- `npm run test:browser`: Playwright and axe-core browser tests.

Runtime files are private local state under `local/runtime/` and are ignored by
Git. The SQLite archive is not an off-machine backup; back it up separately if
its history is important.

## License

MIT
