# Codex Usage Monitor

Monitor OpenAI Codex CLI limits locally, retain usage and token history, display
accessible dashboards, and optionally send alerts or publish the public snapshot
through a GitHub Gist.

![Codex Limits dashboard](local/images/hero.png)

The monitor talks to the authenticated local Codex app-server. Account identity,
credentials, the SQLite archive, and analytics are not sent to the Gist. Discord,
Telegram, and Gist integration are optional; the local monitor and dashboard do
not require a cloud service.

## Contents

- [Requirements](#requirements)
- [Quick start from a checkout](#quick-start-from-a-checkout)
- [Command reference](#command-reference)
- [Configuration](#configuration)
- [Storage and retention](#storage-and-retention)
- [Dashboards and analytics](#dashboards-and-analytics)
- [Alerts](#alerts)
- [External dashboard with Gist](#external-dashboard-with-gist)
- [Versioned installation](#versioned-installation)
- [Linux, WSL, and systemd](#linux-wsl-and-systemd)
- [Project structure](#project-structure)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

## Requirements

The supported runtime is a Linux environment, including WSL. Native Windows
shells are not supported.

| Requirement | Purpose | Check |
|---|---|---|
| Bash | monitor, server, installer | `bash --version` |
| Python 3.9+ and `Europe/Paris` tzdata | status parsing, storage, HTTP server | `python3 --version` |
| OpenAI Codex CLI | limit source | `codex --version` |
| curl | Discord, Telegram, and Gist | `curl --version` |
| `flock` | single-cycle locking | `flock --version` |
| GNU coreutils | monitor and distribution tools | `date --version` |

Install and authenticate Codex before running the monitor:

```bash
npm install --global @openai/codex
codex
codex login status
```

The monitor is non-interactive. It cannot complete a login or approve a
repository trust prompt. Run Codex manually first if either is pending.

## Quick start from a checkout

These commands keep configuration and generated state in the checkout. This is
the simplest development and evaluation setup.

```bash
git clone https://github.com/AlexandreDor/ai-usage-monitor.git
cd ai-usage-monitor/local
cp .env.example .env
chmod 600 .env
./monitor.sh --check
./monitor.sh --once
```

The `.env` file is configuration data, not shell code. Let the application parse
it; do not execute it with a shell. Discord, Telegram, and Gist values may remain
empty.

A successful default cycle includes the parsed JSON and messages in this form:

```text
[DD/MM/YYYY HH:MM] Scraping codex status...
{
    "five_h_pct": 80,
    ...
}
[OK] Snapshot storage processed at /absolute/path/ai-usage-monitor/local/runtime/data.json
[OK] Cycle completed in 1234ms.
```

Values, duration, and the absolute state path vary. Start continuous collection
and the local server in two terminals:

```bash
# Terminal 1, from ai-usage-monitor/local
./monitor.sh --loop 900

# Terminal 2, from ai-usage-monitor/local
./serve.sh
```

Open `http://localhost:8080/dashboard.html` for current limits and
`http://localhost:8080/analytics.html` for long-term analytics.

## Command reference

### Monitor

Run `./monitor.sh --help` in a checkout or `codex-usage-monitor --help` after
installation. Help does not read configuration, check dependencies, or contact
Codex.

```text
./monitor.sh [MODE] [OPTIONS]
```

| Argument | Behavior |
|---|---|
| `--help` | Print help without contacting Codex. |
| `--once` | Run one complete cycle; this is the default. |
| `--loop [SECONDS]` | Run immediately, then at epoch-aligned boundaries. Without `SECONDS`, use `LOOP_INTERVAL`; range `1..86400`. |
| `--check` | Validate configuration, dependencies, permissions, tzdata, Codex access, token sources, and pricing without collecting analytics. |
| `--status-json` | Print only the current normalized Codex limit JSON. It reads only Codex/status timing settings, checks Codex/Python/tzdata, and never creates or changes state. |
| `--fail-fast` | With `--loop`, exit after the first failed cycle instead of waiting for the next boundary. |
| `--config FILE` | Require and read this configuration file. |
| `--state-dir DIRECTORY` | Override the state directory for this process. The path must be absolute. |

Examples:

```bash
./monitor.sh
./monitor.sh --loop
./monitor.sh --loop 60 --fail-fast
./monitor.sh --status-json
./monitor.sh --config "$HOME/codex-monitor.env" --state-dir "$HOME/codex-monitor-state" --check
```

Only one cycle writes a state directory at a time. A concurrent invocation exits
successfully after logging exactly:

```text
[INFO] Another monitor cycle is active; this cycle was skipped.
```

### Dashboard server

Run `./serve.sh --help` or `codex-usage-dashboard --help`.

| Argument | Behavior |
|---|---|
| `--port PORT` | Listen on port `1..65535`; default `8080`. A positional port remains accepted. |
| `--bind ADDRESS` | Listen on an IPv4 or IPv6 address; default `127.0.0.1`. |
| `--config FILE` | Require and read this configuration file. |
| `--state-dir DIR` | Read `data.json`, `history.json`, and the default archive from this state directory. |
| `--help` | Print help. |

Examples:

```bash
./serve.sh --port 8080
./serve.sh --config "$HOME/codex-monitor.env" --state-dir "$HOME/codex-monitor-state"
./serve.sh --bind 0.0.0.0 --port 8080
```

The last command deliberately permits LAN access. The server has no
authentication and no TLS. Use the default loopback bind unless every client on
the reachable network is trusted, or place it behind an authenticated TLS
reverse proxy. Never forward the bare server directly to the Internet.

The server exposes only `/`, `dashboard.html`, `analytics.html`, listed assets,
`data.json`, `history.json`, and the read-only `/api/analytics` endpoint. It does
not expose the configuration, SQLite files, health data, alert journal, lock,
logs, or directory listings. Serving does not collect data; the monitor must run
separately.

## Configuration

`local/config.py` is the central resolver shared by the monitor and dashboard
server. Every resolved value follows this priority, from highest to lowest:

1. CLI override, currently `--state-dir` and the optional `SECONDS` passed to `--loop`.
2. Process environment.
3. Selected `.env` file.
4. Built-in default.

`--config FILE` selects the file. `CODEX_USAGE_MONITOR_CONFIG` selects it through
the environment. In a source checkout the default is `local/.env`; an installed
command uses `${XDG_CONFIG_HOME:-$HOME/.config}/codex-usage-monitor/.env`.
`CODEX_USAGE_MONITOR_STATE_DIR` is the preferred environment override for
`STATE_DIR`.

### File format and permissions

- Use UTF-8 `KEY=VALUE`, one assignment per line.
- Keys use uppercase ASCII letters, digits, and underscores and start with a letter.
- Blank lines and lines whose first non-space character is `#` are ignored.
- Single or double quotes may surround a complete value; the parser removes only those outer quotes.
- Spaces inside quoted values are preserved. Substitutions, variable expansion, command execution, and backslash escapes are not performed.
- Values must fit on one line and must satisfy their field validation.
- The file must be a regular, non-symlink file owned by the current user, with mode `0600` or stricter.
- State and configuration directories are mode `0700`; generated private files are mode `0600`.

Create a source-checkout file with:

```bash
cd ai-usage-monitor/local
cp .env.example .env
chmod 600 .env
```

### Variables

| Variable | Default | Description |
|---|---|---|
| `STATE_DIR` | checkout: `local/runtime`; installed: XDG state path | Private generated state; absolute path. |
| `LOOP_INTERVAL` | `900` | Aligned collection interval, `1..86400` seconds. |
| `HISTORY_RETENTION_HOURS` | `192` | Age-based JSON history window, `0.25..8760` hours. |
| `ARCHIVE_RETENTION_DAYS` | `365` | SQLite retention, `0..36500`; `0` is unlimited. |
| `CODEX_BIN` | `codex` | Codex executable name or path. |
| `CODEX_STATUS_TIMEOUT_SECONDS` | `20` | Codex app-server timeout, `5..300`. |
| `TOKEN_USAGE_SOURCES` | `auto` | `auto`, `none`, or a comma-separated subset of `codex,opencode,hermes`. |
| `TOKEN_PRICING_FILE` | release/checkout `local/pricing.json` | Absolute path to a readable, non-symlink pricing catalog. |
| `CODEX_DATA_DIR` | `$HOME/.codex` | Absolute Codex session directory. |
| `OPENCODE_DB_PATH` | `${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db` | Absolute OpenCode database path. |
| `HERMES_DB_PATH` | `$HOME/.hermes/state.db` | Absolute Hermes database path. |
| `ALERT_THRESHOLDS` | `75,50,25,10,5` | Remaining-percentage notification thresholds. |
| `ALERT_SCRIPT_TIMEOUT_SECONDS` | `30` | Per-hook timeout, `1..1800` seconds. |
| `ALERT_SCRIPT_<N>` | empty | Absolute executable, user-owned, non-symlink hook for index `1..99`; group/world-writable files are rejected. |
| `ALERT_SCRIPT_<N>_EVENTS` | empty | Matching comma-separated threshold/reset selectors. |
| `DISCORD_WEBHOOK` | empty | Official Discord HTTPS webhook URL. |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token; configure with chat ID. |
| `TELEGRAM_CHAT_ID` | empty | Non-zero Telegram chat ID; negative group IDs are valid. |
| `GITHUB_PAT` | empty | Classic token with only the `gist` scope. |
| `GITHUB_GIST_ID` | empty | Hexadecimal Gist ID; configure with PAT. |
| `CURL_CONNECT_TIMEOUT_SECONDS` | `5` | HTTP connect timeout, `1..60`. |
| `CURL_MAX_TIME_SECONDS` | `20` | Total HTTP timeout, `1..600`, not below connect timeout. |
| `CURL_RETRIES` | `2` | Additional transient HTTP attempts, `0..5`. |
| `CURL_RETRY_DELAY_SECONDS` | `1` | Initial exponential backoff, `0..60` seconds. |
| `MONITOR_DEBUG` | `0` | Set to `1` for bounded, credential-cleaned diagnostics. |
| `GITHUB_API_URL` | `https://api.github.com` | HTTPS API base override; HTTP is accepted only for an explicit loopback host in tests. Userinfo, queries, and fragments are rejected. |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | HTTPS API base override; HTTP is accepted only for an explicit loopback host in tests. Userinfo, queries, and fragments are rejected. |
| `DASHBOARD_ANALYTICS_DATABASE` | `<STATE_DIR>/usage-history.sqlite3` | Server-only archive override; absolute non-symlink path. |

Credential pairs must be complete. In `auto` token mode, absent or empty sources
are disabled without failing the cycle. An explicitly requested unavailable
source makes the token collection fail and marks the cycle degraded.

## Storage and retention

The state directory contains:

| File | Purpose |
|---|---|
| `data.json` | Latest public quota snapshot. |
| `history.json` | Recent public snapshots, newest first. |
| `usage-history.sqlite3` plus SQLite WAL files | Private long-term limits, reset, token, collector, and migration data. |
| `health.json` | Last cycle result and duration. |
| `.alert_state` | Alert state schema v4, per-channel delivery status, and script journal. |
| `.monitor.lock` | Non-blocking cycle lock. |

In a checkout this is `local/runtime`. After installation it is
`${XDG_STATE_HOME:-$HOME/.local/state}/codex-usage-monitor`; do not look for
persistent runtime data beside the active installed release.

### Rolling JSON history

`HISTORY_RETENTION_HOURS` is temporal: snapshots older than `now - retention`
are removed regardless of polling interval. Timestamps are deduplicated and
sorted newest first. A new snapshot more than 300 seconds in the future is
rejected without writes; pre-existing entries beyond that tolerance are ignored.
An older valid sample may enter history but cannot replace a newer `data.json`.

Defensive ceilings are 10,000 entries and 16 MiB. If either ceiling shortens the
requested time window, the monitor emits a warning. Invalid `history.json` bytes
are first preserved in a unique mode-0600
`history.json.corrupt.<timestamp>` sibling, then valid entries are reconstructed.

### SQLite archive

Limit samples are kept at full resolution for 24 hours, compacted to the latest
sample per 30-minute bucket from 24 hours through 7 days, and to the latest
sample per hour beyond 7 days. The configured day cutoff then applies; `0` keeps
the archive indefinitely. Token events and reconstructed resets use the same day
retention without limit-series compaction.

SQLite schema v2 uses WAL so the analytics server can read while the monitor
writes. Connections use a short busy timeout and bounded lock retries. Integrity
and schema are checked before use. Migration from recognized schema v1 creates
and verifies a one-time mode-0600 `usage-history.sqlite3.v1.bak` before changing
the database. Unknown or partial schemas are rejected. A corrupt database is
moved to a unique `usage-history.sqlite3.corrupt.<timestamp>` backup and rebuilt
from rolling history when possible.

These historical files protect migration/recovery, but they are not off-machine
backups. Use the distribution backup command or another backup system for disk
loss protection.

## Dashboards and analytics

The live dashboard displays 5-hour and weekly quota, reset deadlines, weekly
pace, and rolling history. It refreshes at the sample interval, labels a sample
stale at two intervals old, keeps the last known quotas after a refresh error,
and recovers automatically. Status uses visible text and an ARIA live region;
quota bars expose accessible values, and chart data is also available as a text
summary/table.

Advanced analytics is local-only because it queries the private SQLite archive.
It provides:

- 24-hour, 7/30/90-day, one-year, all-data, and Paris-calendar custom ranges;
- limit series and detected 5-hour/weekly reset markers;
- reset history paginated 50 rows at a time;
- input, cache-read, cache-write, output, reasoning, total, and assumed-zero tokens;
- token series and cost estimates by application, provider, and model;
- token breakdown pagination, 50 rows at a time in the UI;
- collector freshness, last attempt/success/error, and Hermes pre-monitor baselines;
- English/French and USD/EUR display preferences;
- accessible summaries, tables, controls, focus behavior, and chart alternatives.

Analytics responses remain schema version 1. The API bounds series, reset
markers, model lists, and breakdown groups; clients can request breakdown pages
with paired `breakdown_offset`/`breakdown_limit` parameters. Each response
includes `pricing.sha256`, calculated from the exact catalog bytes used for that
response, so clients can identify pricing changes across pages. Reset pagination
uses `reset_offset`/`reset_limit` and reports total, offset, and limit.
Unknown-price groups contribute to the global assumed-zero totals but produce one
warning with a group count and at most 20 example identifiers. An absent model
filter means all models; explicit model filters contain at most 50 names.

Display buckets are 15 minutes through 48 hours, 30 minutes through 30 days, and
one hour afterward. Extremely long unlimited ranges are coarsened further to
remain bounded. Cost is an API-equivalent estimate, not a bill: reasoning is
already part of output and is not counted twice; unknown models stay visible at
assumed-zero cost. EUR is a display conversion using the rate shown by the UI.

## Alerts

Discord and Telegram are direct HTTPS requests from the monitor. Configure one
or both in `.env`. Thresholds fire when remaining quota crosses downward; one
drop across several levels sends only the most critical crossed threshold. The
first observation uses 100% as its notification baseline.

Alert state schema v4 tracks stable alert IDs and each channel independently. A
successful channel is not called again when another channel failed. curl/network
failures, HTTP 408, HTTP 429, and HTTP 5xx are transient; they use bounded
exponential retries, with `Retry-After` taking precedence and capped at 60
seconds. Other HTTP 4xx failures are permanent and are not retried on later
cycles. Telegram HTTP 200 is accepted only when its JSON body confirms
`"ok": true`. Pending reset notifications remain eligible only for one full
window: 5 hours or 7 days.

Local hooks are independent of notification thresholds:

```bash
ALERT_SCRIPT_1=/absolute/path/to/reset-worker
ALERT_SCRIPT_1_EVENTS=5h:reset,weekly:reset
ALERT_SCRIPT_2=/absolute/path/to/reduce-load
ALERT_SCRIPT_2_EVENTS=5h:50,5h:25,weekly:20
ALERT_SCRIPT_TIMEOUT_SECONDS=30
```

Selectors are `5h:reset`, `weekly:reset`, `5h:<0..100>`, and
`weekly:<0..100>`. Paths must be absolute executable regular files; use a wrapper
when arguments are needed. Hooks run synchronously, from their own directory,
without stdin. Each action is journaled before execution and attempted once;
failure or timeout is logged but never retried. Credentials are removed from the
hook environment, but hooks are trusted local code and are not sandboxed.

The hook receives `CODEX_ALERT_EVENT`, `CODEX_ALERT_WINDOW`,
`CODEX_ALERT_THRESHOLD`, `CODEX_ALERT_REMAINING_PCT`, `CODEX_ALERT_RESET_AT`,
`CODEX_ALERT_RESET_LABEL`, `CODEX_ALERT_SCRAPED_AT`, `CODEX_ALERT_MESSAGE`,
`CODEX_ALERT_CODEX_BIN`, and `CODEX_ALERT_RULE_INDEX`.

## External dashboard with Gist

A Gist can hold only the public `data.json` and `history.json` used by the static
live dashboard. It never receives the SQLite archive or advanced analytics.

1. Create a **secret** Gist at <https://gist.github.com> with a `data.json` file containing `{}`.
2. Create a classic personal access token at <https://github.com/settings/tokens> with only the `gist` scope.
3. Put `GITHUB_PAT` and `GITHUB_GIST_ID` in the monitor configuration.
4. Run `./monitor.sh --once` from `ai-usage-monitor/local`.

GitHub calls a Gist “secret” when it is unlisted: it is omitted from discovery
and profile listings, but it is **not private**. Anyone who obtains the URL or ID
can read it. The snapshot omits account identity and credentials, but it exposes
quota percentages, reset times, and history. Rotate the Gist ID if its URL leaks,
and never put credentials in Gist files.

With the default retry count, a successful sync logs exactly:

```text
[INFO] GitHub Gist: delivery attempt 1/3.
[OK] GitHub Gist: delivered (HTTP 200).
```

A failed attempt uses the current structured form, for example:

```text
[WARN] GitHub Gist: curl=0, HTTP=500, attempt=1/3, retry_delay=1s.
```

To use the static dashboard, set `GIST_ID` in `local/assets/dashboard.js`, then
publish `dashboard.html`, `assets/`, and `images/favicon.png` from your own static
site. The browser reads `https://api.github.com/gists/<GIST_ID>`. GitHub Pages
setup and the public site URL depend on the repository/account chosen for that
site; no Pages deployment is created by this project.

## Versioned installation

The worktree declares version `0.1.0`. Versions follow Semantic Versioning and a
release tag, when one exists, is `v<VERSION>`. This documentation does **not**
claim that tag `v0.1.0` or its GitHub Release has been published.

Install the current checkout for one user:

```bash
git clone https://github.com/AlexandreDor/ai-usage-monitor.git
cd ai-usage-monitor
scripts/install.sh install --source .
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/codex-usage-monitor/.env"
"$HOME/.local/bin/codex-usage-monitor" --check
```

Default installed paths are:

| Content | Path |
|---|---|
| Versioned releases | `$HOME/.local/lib/codex-usage-monitor/releases/<version>` |
| Active/previous links | `$HOME/.local/lib/codex-usage-monitor/current` and `previous` |
| Commands | `$HOME/.local/bin/codex-usage-monitor`, `codex-usage-dashboard`, `codex-usage-monitor-manage` |
| Authoritative configuration | `${XDG_CONFIG_HOME:-$HOME/.config}/codex-usage-monitor/.env` |
| Persistent state | `${XDG_STATE_HOME:-$HOME/.local/state}/codex-usage-monitor` |
| User units | `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user` |

The launchers export the authoritative XDG configuration and state paths before
executing the active release. Configuration, generated state, and credentials
are never copied into versioned releases.

Install or update from a downloaded release archive only when both files exist:

```bash
sha256sum --check SHA256SUMS
"$HOME/.local/bin/codex-usage-monitor-manage" update \
  --archive "$PWD/codex-usage-monitor-0.1.0.tar.gz" \
  --checksum "$PWD/SHA256SUMS"
```

The installer also verifies that `SHA256SUMS` covers the selected archive. An
update is staged under its SemVer version and activated atomically; configuration
and state are retained. A failed staging operation does not change `current`.

Maintenance commands:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" rollback
"$HOME/.local/bin/codex-usage-monitor-manage" rollback 0.1.0
"$HOME/.local/bin/codex-usage-monitor-manage" backup \
  --output "$HOME/codex-usage-monitor-backup.tar.gz"
"$HOME/.local/bin/codex-usage-monitor-manage" restore \
  --backup "$HOME/codex-usage-monitor-backup.tar.gz"
"$HOME/.local/bin/codex-usage-monitor-manage" uninstall
```

Backup and restore acquire the monitor cycle lock before stopping the active
user services, copying, or replacing configuration and state. A manually running
cycle therefore makes maintenance fail safely, including with `--no-systemd`;
previously active services must restart successfully. Backups are mode `0600`
and are bounded by the archive limits documented in
[docs/RELEASE.md](docs/RELEASE.md). `uninstall` requires a valid owned release
root, stopped services, and refuses HOME or ancestor paths; it removes releases,
commands, and units but preserves configuration and state. `uninstall --purge`
deletes those persistent files too.

Release archives are built only from `git ls-files` and are deterministic for
identical tracked files and the same mandatory `SOURCE_DATE_EPOCH`:

```bash
cd ai-usage-monitor
SOURCE_DATE_EPOCH=1720000000 scripts/build-release.sh --output dist
cd dist
sha256sum --check SHA256SUMS
```

The builder normalizes ordering, ownership, modes, timestamps, POSIX tar
metadata, and gzip metadata. `--require-clean` additionally rejects any index,
worktree, or untracked change. The tag-triggered release workflow depends on the
complete reusable CI, verifies `v<VERSION>` and ancestry from `main`, builds
twice, transfers the exact validated assets to a write-permission publication
job, then verifies a draft before making it public. It never creates or pushes a
tag.

See [docs/RELEASE.md](docs/RELEASE.md) for path overrides and the full lifecycle.

## Linux, WSL, and systemd

The installer writes **systemd user units**, not system-wide units. On a Linux
desktop or server with a working user manager:

```bash
systemctl --user daemon-reload
systemctl --user enable --now codex-usage-monitor.service
systemctl --user enable --now codex-usage-dashboard.service
systemctl --user status codex-usage-monitor.service
journalctl --user -u codex-usage-monitor.service -f
```

User services normally start with the user's manager. On a headless Linux host,
an administrator may enable lingering if services must run while the user is
logged out:

```bash
sudo loginctl enable-linger "$USER"
```

systemd availability is environment-specific. WSL requires systemd to be
enabled in WSL and a usable user session; containers may not run a user manager
at all. In those environments install with `--no-systemd`, then use two terminal
sessions or `tmux`:

The user units keep `NoNewPrivileges`, private devices, and private temporary
storage. They intentionally omit `ProtectSystem` and `ProtectHome` so the
generated launcher can write XDG configuration/state and the monitor can read
the authenticated Codex data under `$HOME/.codex`. The `.env` file remains
application-parsed configuration rather than a systemd `EnvironmentFile`.

```bash
tmux new-session -s codex-monitor './monitor.sh --loop 900'
tmux new-session -s codex-dashboard './serve.sh'
```

Run those checkout commands from `ai-usage-monitor/local`. WSL normally exposes
a loopback server to the Windows browser at
`http://localhost:8080/dashboard.html`, but enterprise networking/firewall
policy can prevent that forwarding. Native Windows execution remains unsupported.

## Project structure

```text
ai-usage-monitor/
|-- .github/workflows/
|   |-- ci.yml                         # syntax, suite, browser, ShellCheck CI
|   `-- release.yml                    # validated deterministic tag release
|-- docs/
|   `-- RELEASE.md                     # distribution lifecycle and policy
|-- local/
|   |-- monitor.sh                     # CLI, cycle, alerts, Gist synchronization
|   |-- serve.sh                       # allowlisted local HTTP/API server
|   |-- config.py                      # centralized secure configuration resolver
|   |-- codex_status.py                # Codex app-server protocol/status parser
|   |-- monitor_utils.py               # monitor validation/JSON helpers
|   |-- history.py                     # temporal JSON history and recovery
|   |-- storage.py                     # SQLite schema, WAL, migration, integrity
|   |-- archive.py                     # quota archive, compaction, reset derivation
|   |-- token_usage.py                 # Codex/OpenCode/Hermes token collectors
|   |-- analytics.py                   # read-only analytics API aggregation
|   |-- alerts.py                      # stable alert IDs and retry policy
|   |-- dashboard.html                 # live dashboard
|   |-- analytics.html                 # advanced local dashboard
|   |-- pricing.json                   # versioned API-equivalent price catalog
|   |-- .env.example                   # configuration template
|   |-- assets/
|   |   |-- dashboard.js / dashboard.css
|   |   |-- analytics.js / analytics.css
|   |   |-- preferences.js
|   |   `-- chart.umd.min.js
|   |-- images/
|   |   |-- hero.png / framework.png / discord.png
|   |   `-- logo.png / favicon.png
|   |-- scripts/.gitkeep               # ignored location for checkout-local hooks
|   `-- runtime/                       # generated checkout state, not tracked
|-- scripts/
|   |-- install.sh                     # install/update/rollback/backup lifecycle
|   `-- build-release.sh               # deterministic archive and SHA256SUMS
|-- systemd/
|   |-- codex-usage-monitor.service    # systemd user monitor unit
|   `-- codex-usage-dashboard.service  # systemd user dashboard unit
|-- tests/
|   |-- browser/dashboard.spec.js      # Playwright and axe-core browser coverage
|   |-- fixtures/
|   |   |-- fake-codex.sh / fake-curl.sh
|   |   `-- codex/                     # multi-ID, partial, and unknown payloads
|   |-- lib/test_helper.sh             # isolated shell-test harness
|   |-- run.sh                         # dependency-light Python/shell/Node suite
|   |-- test_analytics.sh
|   |-- test_analytics_read_race.py
|   |-- test_archive.py
|   |-- test_backend_analytics.sh
|   |-- test_codex_read_race.py
|   |-- test_codex_status.py
|   |-- test_config.py
|   |-- test_dashboard.js
|   |-- test_distribution.sh
|   |-- test_history.py
|   |-- test_http.sh
|   |-- test_monitor_alerts.sh
|   |-- test_monitor_archive.sh
|   |-- test_monitor_archive_failure.sh
|   |-- test_monitor_codex.sh
|   |-- test_monitor_config.sh
|   |-- test_monitor_network.sh
|   |-- test_monitor_runtime.sh
|   |-- test_monitor_schedule.sh
|   |-- test_monitor_scripts.sh
|   |-- test_monitor_thresholds.sh
|   |-- test_monitor_token_cycle.sh
|   |-- test_monitor_utils.py
|   |-- test_preferences.js
|   |-- test_storage.py
|   `-- test_token_usage.sh
|-- package.json / package-lock.json    # Playwright/axe-core test dependencies
|-- playwright.config.js
|-- public/favicon.png
|-- .gitignore
|-- VERSION                            # current SemVer, 0.1.0
|-- CHANGELOG.md
|-- ROADMAP.md
|-- LICENSE
`-- README.md
```

## Testing

Run the complete dependency-light suite, then browser accessibility tests:

```bash
tests/run.sh
npm ci
npm run test:browser
```

CI additionally runs Bash syntax checks, ShellCheck, and branch coverage across
all local Python modules with an 80% gate. Distribution tests cover
install, update, rollback, backup/restore, uninstall, checksum rejection,
deterministic archives, archive contents, and systemd unit verification when
`systemd-analyze` is available.

## Troubleshooting

### Codex command or access fails

```bash
command -v codex
codex login status
./monitor.sh --check
./monitor.sh --status-json
```

Update the Codex CLI or increase `CODEX_STATUS_TIMEOUT_SECONDS` if its local
app-server starts slowly.

### Dashboard has no data

From `ai-usage-monitor/local` in a checkout:

```bash
./monitor.sh --once
./serve.sh
```

Do not open the HTML with a `file://` URL. After installation, use
`codex-usage-monitor --once` and `codex-usage-dashboard`; generated state is in
the XDG state directory, not the release directory.

### Analytics archive is unavailable

Run one successful monitor cycle, then reload `analytics.html`. `--check` does
not initialize analytics. If a custom `--state-dir` is used for the monitor, pass
the same path to the server.

### Gist returns HTTP 401 or 404

HTTP 401 normally means the PAT is expired or lacks `gist` scope. HTTP 404
normally means the Gist ID is wrong or the token cannot access it. Both are
permanent client errors and are not retried in the same request.

## License

MIT
