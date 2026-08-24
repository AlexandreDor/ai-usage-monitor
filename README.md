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
- Rolling history chart generated from local quota and Forecast snapshots.
- Accessible quota gauges expose localized names and value text for the 5-hour
  and weekly remaining windows.
- Mouse and touch exploration by nearest time slice, with a vertical cursor and
  one tooltip for every visible quota series at that time.
- Automatic refresh based on the monitor collection interval.
- Local and optional Gist-backed external modes.
- Independent source, freshness, and refresh-error indicators. The last valid
  values stay visible when collection or publication is delayed.
- English and French interfaces.
- EUR and USD display preferences shared across both pages.
- Optional global 24-hour and 6-hour reset probabilities from
  [Codex Forecast](https://codex.lunarwerx.com/).
- No direct third-party request from the browser: the monitor fetches Forecast
  data, stores valid observations locally, and publishes them with rolling
  history when Gist mode is enabled.

### Advanced Analytics

The local Analytics page provides:

- quota history, ideal weekly pace, and Forecast probabilities for 24 hours, 7,
  30, or 90 days, one year, all retained data, or a custom date range;
- detected 5-hour and weekly reset history, including scheduled and early
  weekly resets, with the last Forecast probabilities observed less than 45
  minutes before each reset when available;
- local token consumption from Codex, OpenCode, and Hermes;
- uncached input, cache read, cache write, output, reasoning, and total token
  counters;
- filtering by application and model, with GPT-5.6 models selected by default
  when available;
- quota, token, and API-equivalent cost charts;
- implicit weekly-limit value estimates from all locally collected
  API-equivalent token-event costs (Codex, OpenCode, and Hermes) in a rolling
  twelve-hour window, shown at one point per fixed six-hour UTC bucket. The
  latest snapshot in the current bucket is retained so the current estimate
  remains visible. The estimator converts the observed quota drop from
  percentage points to a fraction (for example, 2 % → 0.02), then uses
  `observed all-source cost / consumed fraction`; it is independent of the
  source and model filters used by the token charts;
- a short median of the current and two previous valid values for the trend,
  with `good`, `low confidence`, and `volatile` quality states. Windows outside
  11 h 45 min–12 h 15 min, quota resets or limit/deadline transitions,
  increases or sub-0.5-point drops, stale/incomplete observations, missing
  positive prices, invalid counters, and zero cost are shown as unavailable
  with a reason rather than silently extrapolated;
- weekly reset rows include `Estimated cycle cost ($)` for the complete
  observable all-source cycle and `Extrapolated 100% value ($)` when quota
  remained.
  Five-hour resets are explicitly `N/A`; a first/partial or ambiguous cycle,
  missing prices, stale reset boundaries, and a fully consumed cycle (where
  extrapolation does not apply) retain an explanatory unavailable status. A
  reset boundary is accepted only when both nearby snapshots are within
  `max(3600, 2 * sample_interval_seconds)`;
- the current weekly-value estimate is also qualified as `stale_data` when the
  latest limit snapshot is older than `max(2 * sample_interval_seconds,
  sample_interval_seconds + 60)`. Historical points remain in the series, while
  the dashboard explicitly announces that the current estimate is unavailable;
- mouse and touch exploration by nearest time slice, grouping visible series
  while preserving percentage, token, and currency units;
- cost allocation by application, provider, and model;
- server-side pagination of the application, provider, and model breakdown in
  fixed groups of 50 rows;
- USD estimates from the local pricing catalog and optional EUR display
  conversion;
- collector freshness, warnings, and accessible text/table alternatives for
  Analytics charts.

Analytics data stays in the local SQLite archive and is not synchronized to the
Gist. Cost values are estimates, not billing statements. Reasoning tokens are a
subset of output tokens and are not counted twice. Models without a catalog
price remain visible and are valued at zero with a warning. Their tokens are
never added to the estimated cost; breakdown pagination does not change the
period-wide token or cost totals.

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
- A zero-byte `local/runtime/dashboard-heartbeat` records recent visible local
  dashboard activity without storing identity or navigation data.
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

While a locally served dashboard tab is visible, loop mode also refreshes the
current quota snapshot and evaluates alerts at `DASHBOARD_ACTIVE_INTERVAL_SECONDS`
(300 seconds by default). These
live checks do not write `history.json`, SQLite, Forecast or token samples, or
the optional Gist. Hiding or closing every dashboard tab restores the regular
cadence after at most 90 seconds. A regular `LOOP_INTERVAL` shorter than or
equal to the active interval keeps its existing complete-cycle behavior.

The live dashboard calculates snapshot freshness directly from `scraped_at` and
`sample_interval_seconds`. It marks data stale once its age exceeds the greater
of two collection intervals or one interval plus 60 seconds. The source remains
`LOCAL` or `EXTERNAL`, while refresh failures appear separately and preserve the
last valid values. The accessible status reports both total data age and, when
stale, time past the expected update threshold. A valid fetch clears a refresh
error; only a sufficiently recent snapshot clears the stale state. This
browser-side check needs no Analytics API or additional endpoint; in external
mode it can therefore also identify an interrupted Gist publication.

## Reproducible quality checks

The CI runtime versions are pinned in `.python-version` (Python 3.12.8) and
`.node-version` (Node.js 22.14.0). The application still supports Python 3.9
and newer; the pinned Python version only makes CI results reproducible. The
coverage tool is a CI/development dependency in `requirements-ci.txt` and is
not used at runtime.

From the repository root, run the same quality controls locally:

```bash
python3 -m pip install --requirement requirements-ci.txt
python3 -m compileall -q local tests
python3 -m unittest tests.test_migrations
python3 -m coverage run --branch --rcfile=.coveragerc -m unittest \
  tests.test_alerts tests.test_anomalies tests.test_history tests.test_config \
  tests.test_storage_durability
python3 -m coverage report --rcfile=.coveragerc
tests/run.sh
npm ci
npm audit --audit-level=low
npx playwright install --with-deps chromium
npm run test:browser
shellcheck -x local/*.sh tests/*.sh tests/lib/*.sh tests/fixtures/*.sh
```

Coverage enables branch measurement for the exercised Python modules and fails
below the combined 60% line-and-branch threshold. The threshold is deliberately
below the current measured baseline (66%) so it blocks regressions without
pretending that unexercised browser-facing subprocess paths are covered.
`npm audit --audit-level=low` is also blocking: every vulnerability reported at
low severity or above fails the CI job, while `package-lock.json` remains the
reproducible installation source. Migration tests cover fresh archives,
supported v1–v3 archives upgrading to v4, data/integrity preservation, and
rejection of future or partial schemas. `systemd-analyze verify` is deferred
until the real packaged units planned for P2.16 exist.

## Freshness and availability states

The live dashboard keeps three concerns independent:

- `LOCAL` or `EXTERNAL` identifies the source of the last valid snapshot; it is
  not a freshness state.
- A valid snapshot is `FRESH`/`À JOUR` until its age is greater than
  `max(2 * sample_interval, sample_interval + 60)` seconds, then it is
  `STALE`/`PÉRIMÉ`. Before the first valid value, data is unavailable rather
  than fresh or stale.
- A refresh error is reported separately. Existing valid values remain visible
  while the error is present. A valid fetch clears the refresh error; only a
  sufficiently recent snapshot changes `STALE` back to `FRESH`.

Analytics reports limits freshness separately from each local token collector.
For either one, `unknown` means that no valid sample exists yet; otherwise the
same age rule yields `fresh` or `stale`. A collector can additionally report
the business status `disabled`, `unavailable`, or `error` when applicable.
These statuses describe the collector and do not change the limits status.
Forecast has its own availability: a failed or stale Forecast value is hidden
or shown as unavailable, without making quota limits or Analytics unavailable.

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
| `./monitor.sh -h` or `./monitor.sh --help` | Show the integrated command reference without loading configuration or contacting Codex. |

The mode options `--once`, `--loop`, `--check`, and `--status-json` are mutually
exclusive. `--fail-fast` is accepted only with `--loop`. An explicit loop
interval must be from `1` to `86400` seconds and overrides `LOOP_INTERVAL`,
which defaults to `900`. Help and successful commands return `0`, configuration
or runtime failures return `1`, and invalid command-line usage returns `2` with
the help text on standard error.

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
not serve `.env`, SQLite, health data, the dashboard heartbeat, delivery
journals, locks, or directory listings. The local dashboard sends a bodyless
`POST /api/dashboard-heartbeat`; the server records activity but never launches
the separate monitor process.

## Configuration

Create `local/.env` from `local/.env.example`. The file is parsed as data and is
never executed as shell code. Keep it owned by the current user and restricted
to mode `600`:

```bash
cp local/.env.example local/.env
chmod 600 local/.env
```

`local/config.py` parses and validates the monitor and server configuration as
data. It never evaluates shell syntax, expands variables, follows a `.env`
symlink, or exposes secret values in diagnostics. Existing files are secured
to mode `600` and must be regular files owned by the current user. Blank
optional values disable their integration; a blank required value is invalid
and does not silently fall back to a default. Unsupported keys are ignored
with a warning, while invalid values for supported keys are rejected.

For every shared option the priority is CLI option → process environment →
`local/.env` → default. The monitor's `--loop SECONDS` is the CLI override for
`LOOP_INTERVAL`; `serve.sh --bind` and `--port` are the corresponding network
options. The shared pricing catalog and dashboard active interval use the same
reader and validators in both programs. The process-only aliases are:

- `CODEX_BIN_OVERRIDE` for the monitor's `CODEX_BIN`;
- `DASHBOARD_PRICING_FILE` for the server's pricing catalog;
- `DASHBOARD_ANALYTICS_DATABASE` for the server's SQLite path.

The server's pricing chain is therefore:

- pricing catalog: `DASHBOARD_PRICING_FILE` (process) → `TOKEN_PRICING_FILE`
  (process) → `TOKEN_PRICING_FILE` in `local/.env` → `local/pricing.json`;
- Analytics database: `DASHBOARD_ANALYTICS_DATABASE` (process only) →
  `local/runtime/usage-history.sqlite3`;
- active refresh interval: `DASHBOARD_ACTIVE_INTERVAL_SECONDS` (process) →
  the same key in `local/.env` → `300`.

`DASHBOARD_ANALYTICS_DATABASE` has no `.env` fallback, and
`DASHBOARD_PRICING_FILE` is process-only. `DASHBOARD_ACTIVE_INTERVAL_SECONDS`
is shared and may be supplied by either process environment or `.env`.

### Minimal configuration

No integration is required. This is enough for local quota monitoring and
automatically detected Analytics sources:

```dotenv
ALERTS_ENABLED=1
ALERT_THRESHOLDS=75,50,25,10,5
HISTORY_RETENTION_HOURS=192
ARCHIVE_RETENTION_DAYS=365
TOKEN_USAGE_SOURCES=auto
LOOP_INTERVAL=900
DASHBOARD_ACTIVE_INTERVAL_SECONDS=300
CODEX_FORECAST_ENABLED=1
```

### Notifications

| Variable | Default | Accepted values | Description |
|---|---:|---|---|
| `ALERTS_ENABLED` | `1` | `0` or `1` | Global alert switch. `0` suppresses Discord, Telegram, and configured local alert scripts while quota collection, anomaly detection, SQLite persistence, and alert-state maintenance continue. |
| `DISCORD_WEBHOOK` | empty | Official Discord HTTPS webhook URL | Enables Discord alerts. |
| `TELEGRAM_BOT_TOKEN` | empty | Telegram bot token | Enables Telegram when `TELEGRAM_CHAT_ID` is also set. |
| `TELEGRAM_CHAT_ID` | empty | Non-zero integer; negative group IDs are valid | Required with `TELEGRAM_BOT_TOKEN`. |
| `ALERT_THRESHOLDS` | `75,50,25,10,5` | Non-empty comma-separated integers from `0` to `100` | Remaining-quota thresholds monitored independently for 5-hour and weekly limits. |

Discord and Telegram maintain separate delivery progress. Temporary failures
such as timeouts, HTTP 408, 429, or 5xx remain pending. Successful channels are
not replayed because another channel failed.

Set `ALERTS_ENABLED=0` to pause outbound alerting. New threshold, reset, and
anomaly events observed while disabled are acknowledged locally: they advance
threshold/reset baselines, script tracking, and anomaly detector state, and
durable anomaly rows are retained as journaled local evidence rather than
queued for later delivery. Configured alert scripts are tracked without being
executed. Deliveries that were already pending before the pause remain pending
in `local/runtime/alert-deliveries.json`; they are not transmitted or marked as
unconfigured while disabled and resume independently when `ALERTS_ENABLED=1`.
Even if their expiry deadline passes during the pause, the first re-enabled
cycle attempts those pre-existing deliveries before normal expiry handling is
restored; later stale deliveries follow the usual expiration rules.

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
| `DASHBOARD_ACTIVE_INTERVAL_SECONDS` | `300` | Integer from `30` to `86400` seconds | Quota and alert cadence while a locally served dashboard tab is visible; live checks update only the current snapshot. |
| `HISTORY_RETENTION_HOURS` | `192` | Number from `0.25` to `8760` | Age-based rolling window for `history.json`; defensive limits of 10,000 entries and 16 MiB also apply. |
| `ARCHIVE_RETENTION_DAYS` | `365` | Integer from `0` to `36500` | SQLite retention; `0` keeps data indefinitely. |
| `CODEX_STATUS_TIMEOUT_SECONDS` | `20` | Integer from `5` to `300` | Timeout for the Codex app-server status request. |
| `CODEX_BIN` | `codex` | Executable name or path | Codex CLI command used by the monitor. |
| `MONITOR_DEBUG` | `0` | `0` or `1` | Enables bounded sanitized Codex and HTTP diagnostics. |

The SQLite archive retains detailed quota, Forecast, reset, anomaly, and token
data for Analytics. Existing schema v1, v2, and v3 archives migrate
transactionally to v4 on their next writable monitor cycle; `--check` does not
open or migrate the archive.
The detector tolerates quota noise up to 5 percentage points and reset-date
movement up to 30 minutes; a disappeared reset date is confirmed after two
valid observations. Planned deadline crossings and the recognized weekly
refill pattern are excluded. Anomaly rows remain local even when no channel is
configured, and an interrupted journal registration is retried on a later
cycle. Journaled anomaly records and inactive detector state follow
`ARCHIVE_RETENTION_DAYS`; an anomaly still awaiting journal registration is
retained until it can be delivered.
The rolling JSON history is separate and retains samples according to their
actual timestamps. Changing the collection interval does not change the time
span requested by `HISTORY_RETENTION_HOURS`; only the defensive entry and size
limits can shorten it. Dashboard-triggered live checks update only `data.json`,
so they never increase graph or archive density. Alerts use every successful
live observation, while Forecast and token collection remain on full cycles.

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
the supported schema and USD rates per million tokens. Schema version 1 keeps
one timeless rate set per entry; schema version 2 uses a strictly ordered
`periods` array, where every period has an `effective_from` UTC timestamp and
the four complete rate fields (`input_per_million`, `cache_read_per_million`,
`cache_write_per_million`, and `output_per_million`). The first period starts
at `1970-01-01T00:00:00Z` in the default catalog, so events before a later
boundary retain their historical price. Analytics segments SQL aggregations at
those boundaries and then merges the public rows; aliases and identifiers use
the same periods. Unknown models are kept in reports and assigned zero
estimated cost. The default Standard short-context rates are sourced from the
[OpenAI API pricing page](https://developers.openai.com/api/docs/pricing) and
its [API changelog](https://developers.openai.com/api/docs/changelog).

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
| `CODEX_FORECAST_24H_HIGHLIGHT_THRESHOLD` | `50` | Integer from `0` to `100` | Highlights the current 24-hour probability at or above this value. |
| `CODEX_FORECAST_6H_HIGHLIGHT_THRESHOLD` | `25` | Integer from `0` to `100` | Highlights the current 6-hour probability at or above this value. |

Forecast failures never fail quota collection and never create placeholder
observations. Valid values are written to `data.json`, rolling `history.json`,
the optional Gist history, and the local SQLite archive. Both dashboard graphs
show the 24-hour and 6-hour series; stale current values remain hidden in the
Forecast banner.

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
Gist receives the current sanitized quota/Forecast snapshot and rolling
quota/Forecast history.
It never receives SQLite Analytics data, token usage, credentials, account
identity, alert state, or health data.

The static dashboard reads a configured Gist ID from `GIST_ID` near the top of
`local/assets/dashboard.js`:

```javascript
let GIST_ID = 'your-gist-id';
```

Leave `GIST_ID` empty for local mode. Hosting the static files is intentionally
separate from running the monitor; the machine running `monitor.sh` must keep
updating the Gist.

### Advanced and test overrides

These variables are normally unnecessary:

| Variable | Default | Description |
|---|---:|---|
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Telegram-compatible HTTP(S) API base URL, mainly for tests. |
| `DASHBOARD_ANALYTICS_DATABASE` | `local/runtime/usage-history.sqlite3` | Process-only absolute database path override for `serve.sh`; no `.env` fallback. |
| `DASHBOARD_PRICING_FILE` | See the priority chain above | Process-only absolute pricing path override for `serve.sh`. |
| `CODEX_BIN_OVERRIDE` | empty | Environment-only override that takes precedence over `CODEX_BIN` during monitor initialization. |

`DASHBOARD_ANALYTICS_DATABASE`, `DASHBOARD_PRICING_FILE`, and
`CODEX_BIN_OVERRIDE` are process-only overrides and are not read from
`local/.env`. `TELEGRAM_API_URL` remains an application key that can be read
from `.env`. `GIST_ID` is a mutable static client variable in
`local/assets/dashboard.js`, while `serve.sh --port` and `--bind` are
command-line options rather than `.env` keys.

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

The monitor and dashboard server are deliberately separate processes. The
server records recent visible-dashboard activity, and a monitor already running
in `--loop` mode reacts to it; `serve.sh` never starts a collection itself. The
examples below are manual deployment recipes, not the packaged systemd units
planned for P2.16.

### LXC Ubuntu/Debian

Any current Ubuntu or Debian LXC works; no particular Proxmox template name is
part of this project. Create an unprivileged container according to your host's
policy, give it a stable LAN address if needed, and install the dependencies
inside it:

```bash
apt update
apt install -y bash ca-certificates curl git python3 tzdata util-linux

git clone https://github.com/AlexandreDor/ai-usage-monitor.git
cd ai-usage-monitor/local
cp .env.example .env
chmod 600 .env
```

Install the Codex CLI using its current upstream instructions and authenticate
as the same Unix account that will run the monitor. Verify that account's
authentication with `codex login status` and `codex /status`; authentication in
the host or in another account is not implicitly available inside the LXC. Once
Codex is installed and authenticated, run `./monitor.sh --check` from the
`ai-usage-monitor/local` directory.
Keep the working tree and the runtime archive at
`/path/to/ai-usage-monitor/local/runtime/`, whose default SQLite archive is
`usage-history.sqlite3`.

The built-in server has no authentication or TLS. Keep its default
`127.0.0.1` bind for local-only access. For a trusted LAN, choose an explicit
container address, for example `./serve.sh --bind 192.0.2.20 --port 8080`, and
allow TCP 8080 only from the trusted subnet in both the container/host firewall
and any Proxmox network policy. Never forward it directly to the internet.
Run `./monitor.sh --loop` and `./serve.sh` under the same account, for example
with the systemd recipe below.

### systemd (manual units)

Create two separate units so collection and HTTP serving can be restarted and
diagnosed independently. Replace `codex-monitor` and the home path with the
actual account; the `User`, `HOME`, and `WorkingDirectory` values below all
refer to that same account and checkout. Do not ask systemd to interpret
`.env`: the application parses it as data and validates its permissions.

```ini
# /etc/systemd/system/codex-usage-monitor.service
[Unit]
Description=Codex Usage Monitor collection loop
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=codex-monitor
Environment=HOME=/home/codex-monitor
WorkingDirectory=/home/codex-monitor/ai-usage-monitor/local
ExecStart=/usr/bin/env bash /home/codex-monitor/ai-usage-monitor/local/monitor.sh --loop
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/codex-usage-dashboard.service
[Unit]
Description=Codex Usage Monitor dashboard server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=codex-monitor
Environment=HOME=/home/codex-monitor
WorkingDirectory=/home/codex-monitor/ai-usage-monitor/local
ExecStart=/usr/bin/env bash /home/codex-monitor/ai-usage-monitor/local/serve.sh --port 8080
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
```

The dashboard unit above stays on `127.0.0.1`. If LAN access is intentional,
make it explicit in that unit, for example by changing only its command to
`ExecStart=/usr/bin/env bash /home/codex-monitor/ai-usage-monitor/local/serve.sh --bind 192.0.2.20 --port 8080`,
then restrict port 8080 with the host firewall. Do not use an unauthenticated
`0.0.0.0` bind without that firewall decision.

Install, start, and inspect both units as follows:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now codex-usage-monitor.service codex-usage-dashboard.service
sudo systemctl status codex-usage-monitor.service codex-usage-dashboard.service
sudo journalctl -u codex-usage-monitor.service -f
sudo journalctl -u codex-usage-dashboard.service -f

# After a checkout or configuration update:
sudo systemctl restart codex-usage-monitor.service codex-usage-dashboard.service
sudo systemctl status codex-usage-monitor.service codex-usage-dashboard.service
```

Use `./monitor.sh --check` as the service account when diagnosing
authentication, paths, or Analytics sources. Keep `local/.env` owned by that
account and mode `600`; a systemd unit must not duplicate its values in a
second environment file.

If Codex was installed in a user-only directory that is not in systemd's
`PATH`, obtain its absolute path as the service account and put that value in
`local/.env`:

```bash
sudo -u codex-monitor -H bash -lc 'command -v codex'
# If the command printed /absolute/path/to/codex, set this in local/.env:
CODEX_BIN=/absolute/path/to/codex
```

Alternatively install the CLI globally in a directory present in the service
account's `PATH`. Do not add a user-specific package-manager path to the
generic unit above.

### GitHub Pages and Gist (static external dashboard)

The monitor can publish only the sanitized live snapshot and rolling quota /
Forecast history to a GitHub Gist. Create a Gist containing `data.json` and
`history.json`, put its real hexadecimal ID in `GITHUB_GIST_ID`, and set the
matching `GITHUB_PAT` in `local/.env`. Keep the monitor running locally so the
Gist continues to receive updates. Analytics SQLite data, token data,
credentials, and health state are never published.

GitHub Pages accepts a branch source of `/(root)` or `/docs`; it does not accept
`/local`. Use a separate publication copy or a `/docs` tree in a Pages
repository, rather than publishing the working `local/` directory in place.
For a separate Pages checkout, clone the Pages repository first, then create
the publication copy. The placeholder below is for your Pages repository, not
the monitor project:

```bash
cd /path/to
git clone https://github.com/<github-account>/<pages-repository>.git pages-copy
cd /path/to/ai-usage-monitor
mkdir -p ../pages-copy/docs/assets ../pages-copy/docs/images
cp local/dashboard.html ../pages-copy/docs/index.html
cp local/dashboard.html ../pages-copy/docs/dashboard.html
cp local/analytics.html ../pages-copy/docs/analytics.html
cp -R local/assets/. ../pages-copy/docs/assets/
cp local/images/favicon.png ../pages-copy/docs/images/favicon.png

cd ../pages-copy
# Edit docs/assets/dashboard.js now and set the real Gist ID before staging:
# let GIST_ID = '0123456789abcdef0123456789abcdef';
${EDITOR:-vi} docs/assets/dashboard.js
git add docs
git commit -m 'Publish Codex usage dashboard'
git push
```

Select that repository's branch and `/docs` directory in Settings → Pages.
The published copy must retain `index.html`, `dashboard.html`, the complete
`assets/` directory, and `images/favicon.png`. Keeping both dashboard filenames
ensures that the Analytics back link resolves, even though Analytics data itself
remains unavailable without the local server. The editor step above must leave
this mutable value near the top of the copied file:

```javascript
let GIST_ID = '0123456789abcdef0123456789abcdef';
```

Do not commit a personal token. Only the static live quota page works in this
external mode: Advanced Analytics requires the local `serve.sh` API and the
local SQLite archive. A Pages browser cannot provide Analytics merely by
having access to the Gist.

## Backup/Restore SQLite

The default archive is
`local/runtime/usage-history.sqlite3`. It is private local state, not an
off-machine backup. Current monitor and Analytics connections use
`PRAGMA journal_mode=WAL`, so a read-only Analytics connection can continue
querying while a monitor transaction is writing. Archives created by older
releases used `PRAGMA journal_mode=DELETE`; opening a recognized v1, v2, or v3
archive first creates a unique adjacent `*.pre-migration.*` backup, verifies it
with `PRAGMA quick_check`, and only then migrates the active archive. A failed
backup aborts migration and leaves the legacy schema untouched. If activation
or a later migration step fails after WAL activation, SQLite may already have
changed the journal mode while the schema migration has not been committed;
the pre-migration backup remains the recovery point.

The archive directory and its adjacent backups must be a real directory owned
by the current user with no group/other write bit; the monitor runtime is
created with mode `700`. Writable storage and corruption recovery reject an
unsafe parent before creating or moving any database artifact.

This is the SQLite durability and concurrency work tracked as P1.7.

Busy/locked archive writes use a bounded retry policy (five attempts, a
250-ms busy timeout per attempt, and short exponential backoff; about two
seconds worst case). Corruption, schema, and other operational errors are not
retried. Individual `execute`/`commit` calls are retryable; scripts are not
automatically replayed because they may be partially applied, and production
paths do not depend on that behavior. WAL maintenance is explicit: use the
checkpoint helper before
treating sidecars as disposable, and preserve `-wal` and `-shm` as a pair
during recovery. The procedure below is written for both journal modes.

For a controlled maintenance checkpoint, stop writers and run:

```bash
# BEGIN SQLITE_CHECKPOINT_SHELL_EXAMPLE
set -euo pipefail

cd /path/to/ai-usage-monitor
DB=local/runtime/usage-history.sqlite3
python3 - "$DB" <<'PY'
import sys
from pathlib import Path
from local.storage import checkpoint_database

status = checkpoint_database(Path(sys.argv[1]), mode="TRUNCATE")
print("WAL checkpoint:", status)
PY
# END SQLITE_CHECKPOINT_SHELL_EXAMPLE
```

The status tuple is `(busy, log_frames, checkpointed_frames)`. A non-zero
`busy` value means that another connection is still active; keep both sidecars
and retry after all writers/readers have closed.

### Create a coherent backup

Use Python's standard-library `sqlite3.Connection.backup()` API rather than
copying the main file while another process writes. `backup()` reads a source
correctly even when it is in WAL mode and creates an autonomous destination
database; the destination does not need the source's `-wal` or `-shm` sidecars.
The example refuses to overwrite an existing `BACKUP` path, checks the
temporary destination, and installs it with mode `600`:

```bash
# BEGIN SQLITE_BACKUP_SHELL_EXAMPLE
set -euo pipefail

cd /path/to/ai-usage-monitor
DB=local/runtime/usage-history.sqlite3
BACKUP=/secure/off-machine/codex-usage-history-$(date -u +%Y%m%dT%H%M%SZ).sqlite3
python3 - "$DB" "$BACKUP" <<'PY'
# BEGIN SQLITE_BACKUP_EXAMPLE
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

source_path, destination_path = map(Path, sys.argv[1:])
if not source_path.is_file() or source_path.is_symlink():
    raise SystemExit(f"archive is not a regular file: {source_path}")
if destination_path.exists() or destination_path.is_symlink():
    raise SystemExit(f"backup destination already exists: {destination_path}")
destination_path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary_name = tempfile.mkstemp(
    prefix=f".{destination_path.name}.", suffix=".tmp",
    dir=destination_path.parent,
)
os.close(fd)
temporary_path = Path(temporary_name)
try:
    source_uri = source_path.resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(source_uri, uri=True) as source, sqlite3.connect(temporary_path) as target:
        source.execute("PRAGMA query_only = ON")
        source.backup(target)
        result = target.execute("PRAGMA quick_check").fetchone()
        if not result or result[0] != "ok":
            raise SystemExit(f"backup quick_check failed: {result!r}")
        target.commit()
    os.chmod(temporary_path, 0o600)
    try:
        os.link(temporary_path, destination_path)
    except FileExistsError:
        raise SystemExit(f"backup destination already exists: {destination_path}")
    temporary_path.unlink()
finally:
    temporary_path.unlink(missing_ok=True)
# END SQLITE_BACKUP_EXAMPLE
PY
chmod 600 "$BACKUP"
# END SQLITE_BACKUP_SHELL_EXAMPLE
```

Run `PRAGMA quick_check` on any restored or transferred artifact before using
it. Do not transfer or retain source sidecars alongside this backup artifact:
the `backup()` destination is autonomous.

### Restore safely

The restore is fail-fast. It first reserves a new mode-`700` safety directory,
before creating and verifying an autonomous schema v4 archive next to the
active database. A safety-directory collision therefore creates no candidate;
a corrupt, unrelated, or obsolete-schema candidate also leaves the active
database intact. Once the candidate is valid, stop at least both services and
ensure no other process has the archive open. The procedure preserves the
services' previous active state and keeps an exit trap armed until every
required start and status check succeeds:

```bash
set -euo pipefail

DB=/path/to/ai-usage-monitor/local/runtime/usage-history.sqlite3
BACKUP=/secure/off-machine/codex-usage-history-20260819T120000Z.sqlite3
STORAGE=/path/to/ai-usage-monitor/local/storage.py
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RESTORE_TEMP="${DB}.restore.${STAMP}"
DB_DIR=$(dirname -- "$DB")
DB_NAME=$(basename -- "$DB")
SAFETY_DIR="${DB_DIR}/${DB_NAME}.restore-safety.${STAMP}"

mkdir -m 700 -- "$SAFETY_DIR"

python3 - "$BACKUP" "$RESTORE_TEMP" "$STORAGE" <<'PY'
# BEGIN SQLITE_RESTORE_EXAMPLE
import importlib.util
import sqlite3
import sys
import os
import tempfile
from pathlib import Path

backup_path, destination_path, storage_path = map(Path, sys.argv[1:])
if not backup_path.is_file() or backup_path.is_symlink():
    raise SystemExit(f"backup is not a regular file: {backup_path}")
if destination_path.exists() or destination_path.is_symlink():
    raise SystemExit(f"restore destination already exists: {destination_path}")
if not storage_path.is_file() or storage_path.is_symlink():
    raise SystemExit(f"storage module is not a regular file: {storage_path}")
destination_path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary_name = tempfile.mkstemp(
    prefix=f".{destination_path.name}.", suffix=".tmp",
    dir=destination_path.parent,
)
os.close(fd)
temporary_path = Path(temporary_name)
try:
    source_uri = backup_path.resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(source_uri, uri=True) as source, sqlite3.connect(temporary_path) as target:
        source.execute("PRAGMA query_only = ON")
        source.backup(target)
        result = target.execute("PRAGMA quick_check").fetchone()
        if not result or result[0] != "ok":
            raise SystemExit(f"restore quick_check failed: {result!r}")
        target.commit()
    spec = importlib.util.spec_from_file_location("codex_usage_storage", storage_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"could not load storage module: {storage_path}")
    storage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(storage)
    with storage.connect_database(temporary_path, read_only=True):
        pass
    os.chmod(temporary_path, 0o600)
    try:
        os.link(temporary_path, destination_path)
    except FileExistsError:
        raise SystemExit(f"restore destination already exists: {destination_path}")
    temporary_path.unlink()
finally:
    temporary_path.unlink(missing_ok=True)
# END SQLITE_RESTORE_EXAMPLE
PY

MONITOR_WAS_ACTIVE=0
DASHBOARD_WAS_ACTIVE=0
if sudo systemctl is-active --quiet codex-usage-monitor.service; then
  MONITOR_WAS_ACTIVE=1
fi
if sudo systemctl is-active --quiet codex-usage-dashboard.service; then
  DASHBOARD_WAS_ACTIVE=1
fi
RESTORE_INSTALLED=0
RESTORE_ID=''
ROLLBACK_REQUIRED=1

# BEGIN SQLITE_RESTORE_CLEANUP_EXAMPLE
restore_cleanup() {
  local result=$?
  local current_id
  trap - EXIT
  if (( result != 0 && ROLLBACK_REQUIRED == 1 )); then
    # Stop every database-using service before removing the replacement or
    # putting the old database back. This also covers a partial restart.
    sudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service || result=1
    if (( RESTORE_INSTALLED == 1 )); then
      if [[ -L "$DB" ]]; then
        result=1
      elif [[ -e "$DB" ]]; then
        current_id=$(stat -c '%d:%i' -- "$DB" 2>/dev/null) || current_id=''
        if [[ -n "$RESTORE_ID" && "$current_id" == "$RESTORE_ID" ]]; then
          rm -f -- "$DB" || result=1
        else
          result=1
        fi
      fi
    fi
    rm -f -- "$RESTORE_TEMP" || result=1
    for name in "$DB_NAME" "$DB_NAME-wal" "$DB_NAME-shm"; do
      safety_path="$SAFETY_DIR/$name"
      target_path="$DB_DIR/$name"
      if [[ -e "$safety_path" || -L "$safety_path" ]]; then
        if [[ -e "$target_path" || -L "$target_path" ]]; then
          # Never overwrite a path that appeared outside this procedure.
          result=1
        else
          mv -- "$safety_path" "$target_path" || result=1
        fi
      fi
    done
  else
    rm -f -- "$RESTORE_TEMP" || result=1
  fi
  if (( MONITOR_WAS_ACTIVE == 1 )); then
    sudo systemctl start codex-usage-monitor.service || result=1
  fi
  if (( DASHBOARD_WAS_ACTIVE == 1 )); then
    sudo systemctl start codex-usage-dashboard.service || result=1
  fi
  exit "$result"
}
# END SQLITE_RESTORE_CLEANUP_EXAMPLE
trap restore_cleanup EXIT

sudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service
if [[ -e "$DB" || -L "$DB" ]]; then
  mv -- "$DB" "$SAFETY_DIR/$DB_NAME"
fi
for sidecar in "$DB-wal" "$DB-shm"; do
  if [[ -e "$sidecar" || -L "$sidecar" ]]; then
    mv -- "$sidecar" "$SAFETY_DIR/$(basename -- "$sidecar")"
  fi
done
if ! ln -- "$RESTORE_TEMP" "$DB"; then
  exit 1
fi
RESTORE_INSTALLED=1
RESTORE_ID=$(stat -c '%d:%i' -- "$DB")
rm -- "$RESTORE_TEMP"
chmod 600 "$DB"
if (( MONITOR_WAS_ACTIVE == 1 )); then
  sudo systemctl start codex-usage-monitor.service
  sudo systemctl status codex-usage-monitor.service
fi
if (( DASHBOARD_WAS_ACTIVE == 1 )); then
  sudo systemctl start codex-usage-dashboard.service
  sudo systemctl status codex-usage-dashboard.service
fi
ROLLBACK_REQUIRED=0
trap - EXIT
```

The restore script never installs `BACKUP-wal` or `BACKUP-shm`: the validated
artifact is autonomous, and only sidecars belonging to the old active database
are moved into the safety directory. Keep that mode-`700` directory until a
successful monitor collection and Analytics query have validated the restore.
If any command fails, the exit trap first stops both services, removes only the
replacement it installed, restores old database files only into absent paths,
and restarts exactly the services that were active before the restore. An
unexpected path collision remains a manual recovery condition rather than
being overwritten. The mode-`700` safety directory is retained after success
for manual validation. Automatic recovery may rename a corrupt archive to
`usage-history.sqlite3.corrupt.*` before rebuilding it from rolling history.
Those files are forensic recovery copies on the same machine, not a scheduled
or off-machine backup; retain a separate backup set for disaster recovery and
migration rollback.

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
- `npm run test:browser`: Playwright and axe-core browser tests, excluding the
  dedicated performance benchmarks.
- `npm run test:performance`: Chromium idle-rendering budgets for the live
  dashboard and Analytics page. Each page is sampled three times for two seconds
  after a short warm-up; the median is checked for paint and raster work,
  compositor draws, and renderer task time, while any infinite animation fails
  the test. A JSON summary with every sample is stored with the Playwright test
  artifacts under `test-results/`. These metrics detect continuous client
  rendering, but do not represent a hardware-specific GPU utilization
  percentage.

Runtime files are private local state under `local/runtime/` and are ignored by
Git. The SQLite archive is not an off-machine backup; back it up separately if
its history is important.

## License

MIT
