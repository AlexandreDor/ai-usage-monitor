# Distribution and release

The current worktree version is `0.1.0`. `VERSION` follows Semantic Versioning
2.0.0, and release tags use `v<VERSION>`. This document describes the release
mechanism; it does not assert that `v0.1.0` or a corresponding GitHub Release is
published.

## Requirements

Installation and maintenance require Bash, GNU coreutils, GNU tar, gzip, and
`sha256sum`. Building also requires Git because the release manifest comes from
`git ls-files`.

Runtime requirements are Bash, Python 3.9 or newer with `Europe/Paris` timezone
data, curl, `flock`, and an installed/authenticated Codex CLI. GNU `timeout` is
also required when local alert hooks are configured.

The Codex app-server `initialize.clientInfo.version` is read from the release's
`VERSION` file; it is the application version, not an independent protocol
version.

systemd is optional. The installer writes user units and calls
`systemctl --user` when available; it never installs a system service. Pass
`--no-systemd` on WSL without systemd, in a container without a user manager, or
on another non-systemd environment.

## Install 0.1.0 from the current source

```bash
git clone https://github.com/AlexandreDor/ai-usage-monitor.git
cd ai-usage-monitor
scripts/install.sh install --source .
chmod 600 "${XDG_CONFIG_HOME:-$HOME/.config}/codex-usage-monitor/.env"
"$HOME/.local/bin/codex-usage-monitor" --check
```

The installer creates the configuration from `local/.env.example` only when no
authoritative XDG `.env` exists. Edit that XDG file before starting unattended
services. It is parsed as data and must not be executed by a shell.

An extracted release can install itself. Its tracked `scripts/release-files.txt`
is the exclusive installation manifest:

```bash
scripts/install.sh install
```

To install an archive, keep the archive and its release-provided `SHA256SUMS` in
the current directory:

```bash
sha256sum --check SHA256SUMS
scripts/install.sh install \
  --archive "$PWD/codex-usage-monitor-0.1.0.tar.gz" \
  --checksum "$PWD/SHA256SUMS"
```

`--checksum` is mandatory with `--archive`. The installer independently checks
that the checksum file validates and explicitly covers the selected archive.

## Installed layout

Defaults are:

- releases: `$HOME/.local/lib/codex-usage-monitor/releases/<version>`;
- active and previous links: `$HOME/.local/lib/codex-usage-monitor/current` and `previous`;
- launchers: `$HOME/.local/bin`;
- authoritative configuration: `${XDG_CONFIG_HOME:-$HOME/.config}/codex-usage-monitor/.env`;
- persistent state: `${XDG_STATE_HOME:-$HOME/.local/state}/codex-usage-monitor`;
- user units: `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`.

Installed runtime state and configuration are never co-located with or copied
into a release. Launchers export `CODEX_USAGE_MONITOR_CONFIG`,
`CODEX_USAGE_MONITOR_STATE_DIR`, `XDG_CONFIG_HOME`, and `XDG_STATE_HOME` before
executing the active command. The management launcher preserves every selected
installation path for later maintenance commands.

Configuration directories and state directories are mode `0700`; configuration,
state files, and backups containing user data are mode `0600`.

For isolated installations and tests, path options are `--home`,
`--xdg-config-home`, `--xdg-state-home`, `--lib-root`, `--bin-dir`, and
`--systemd-dir`. Equivalent environment overrides are `CUM_HOME`,
`XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `CUM_LIB_ROOT`, `CUM_BIN_DIR`, and
`CUM_SYSTEMD_DIR`. Explicit CLI path options take precedence for the installer.
Selected paths must be absolute and canonicalizable. The filesystem root and
overlaps among release, configuration, state, launcher, and unit trees are
rejected. `LIB_ROOT` may be below HOME but cannot equal or contain HOME. The
installer marks an empty release root as application-owned and refuses recursive
uninstall when that marker is absent or invalid. Uninstall also rejects any
release/configuration/state path that is HOME or an ancestor of HOME, and first
requires all managed services to be stopped.

## Update and rollback

Update from another extracted release:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" update \
  --source "$HOME/Downloads/codex-usage-monitor-0.2.0"
```

Update from a release archive:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" update \
  --archive "$HOME/Downloads/codex-usage-monitor-0.2.0.tar.gz" \
  --checksum "$HOME/Downloads/SHA256SUMS"
```

The release is validated and copied to a version-specific staging directory
before `current` changes atomically. The prior target is recorded as `previous`.
Configuration and state are outside releases and survive updates. Repeating the
same update is safe when installed files are identical; a same-version content
collision is rejected.

Rollback by swapping current and previous, or name an already installed SemVer:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" rollback
"$HOME/.local/bin/codex-usage-monitor-manage" rollback 0.1.0
```

Units are refreshed from the target release and each currently running service
must restart successfully after update or rollback, or activation is rolled back.

## Backup and restore

Back up both persistent trees:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" backup \
  --output "$HOME/codex-usage-monitor-backup.tar.gz"
```

If `--output` is omitted, the destination is a timestamped archive under
`$HOME`. The destination must be outside the configuration and state trees. The
backup command acquires the same non-blocking `.monitor.lock` used by collection
cycles before stopping the active user services. This prevents a manual cycle
from starting in the stop/discovery gap and gives a coherent copy of SQLite and
its WAL files before those same services are required to start again. A held
manual lock makes backup fail explicitly rather than race, including under
`--no-systemd`. The atomically replaced archive is mode `0600` and contains
`config/` and `state/`.

Restore a backup:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" restore \
  --backup "$HOME/codex-usage-monitor-backup.tar.gz"
```

Restore copies and validates the archive before stopping services. Only regular
files and directories below exactly `config/` and `state/` are accepted;
absolute/traversal paths, links, devices, and FIFOs are rejected. It stages both
trees on their destination filesystems and rolls both back if activation or
service restart fails. Treat backups as secrets because they can contain
notification and Gist credentials.

Restore also acquires `.monitor.lock` after staging but before stopping services,
and keeps the same locked inode in the replacement state tree. Existing manual
cycles are rejected. Once acquired, the lock covers replacement and service
restart.

Release archives are limited to 128 MiB compressed, 10,000 members, 64 MiB per
file, and 256 MiB total payload. Backups are limited to 8 GiB compressed,
100,000 members, 8 GiB per file, and 32 GiB total payload. Inputs are copied to a
private temporary directory before checksum verification, validation, or
extraction, eliminating replacement races on downloaded files.

SQLite's automatic `.v1.bak` and `.corrupt.<timestamp>` files are migration and
recovery aids inside state; they do not replace this off-machine backup.

## Uninstall

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" uninstall
```

The default disables/removes user units, launchers, and all installed releases,
but preserves XDG configuration and state. Delete those too only when intended:

```bash
"$HOME/.local/bin/codex-usage-monitor-manage" uninstall --purge
```

## systemd user services

The installer copies:

- `codex-usage-monitor.service`, running `codex-usage-monitor --loop --fail-fast`;
- `codex-usage-dashboard.service`, running `codex-usage-dashboard`.

The units retain process hardening such as `NoNewPrivileges`, private devices
and private temporary storage. They deliberately do not set `ProtectSystem` or
`ProtectHome`: the generated launchers export the authoritative XDG
configuration/state paths, the monitor must write those paths, and it must read
the authenticated Codex data under `$HOME/.codex` (or the configured
`CODEX_DATA_DIR`). The application, not systemd, parses the `.env` file, so the
unit does not use `EnvironmentFile` for credentials.

Enable and inspect them with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now codex-usage-monitor.service
systemctl --user enable --now codex-usage-dashboard.service
systemctl --user status codex-usage-monitor.service
journalctl --user -u codex-usage-monitor.service -f
```

The monitor's default `900` seconds comes from centralized configuration and can
be changed in the XDG `.env`. The dashboard binds only to `127.0.0.1:8080` by
default.

A headless Linux host may require administrator-enabled lingering to keep a user
manager alive after logout:

```bash
sudo loginctl enable-linger "$USER"
```

This is not portable to every WSL/container setup. If `systemctl --user` has no
usable manager, reinstall with `--no-systemd` or manage the two commands with the
environment's own supervisor.

## Deterministic build

`SOURCE_DATE_EPOCH` is mandatory and must be a non-negative integer. The builder
checks out only the active Git index into private staging; ignored, untracked,
and unstaged content is not a release input. Git executable modes are preserved
while tar normalizes order, POSIX ownership, timestamps, PAX and gzip metadata,
and hard links.

Before tagging, require a completely clean checkout explicitly:

```bash
SOURCE_DATE_EPOCH=1720000000 scripts/build-release.sh \
  --require-clean --output /tmp/codex-release-check
```

```bash
cd ai-usage-monitor
SOURCE_DATE_EPOCH=1720000000 scripts/build-release.sh --output dist
cd dist
sha256sum --check SHA256SUMS
```

The output names for version `0.1.0` are
`codex-usage-monitor-0.1.0.tar.gz` and `SHA256SUMS`. Two builds from identical
tracked files and the same epoch must be byte-identical:

```bash
cd ai-usage-monitor
SOURCE_DATE_EPOCH=1720000000 scripts/build-release.sh --output build-one
SOURCE_DATE_EPOCH=1720000000 scripts/build-release.sh --output build-two
cmp build-one/codex-usage-monitor-0.1.0.tar.gz \
  build-two/codex-usage-monitor-0.1.0.tar.gz
cmp build-one/SHA256SUMS build-two/SHA256SUMS
```

Run the distribution lifecycle test with:

```bash
tests/test_distribution.sh
```

It exercises install, update, rollback, backup/restore, shared-lock refusal,
data-preserving uninstall, archive checksum/member/size rejection, exact release
contents including the favicon, clean tracked-build verification, two-build
reproducibility, and systemd unit verification when `systemd-analyze` exists.

## Release policy

The `.github/workflows/release.yml` workflow runs only for pushed `v*` tags. It:

1. Requires the tag name to equal `v$(cat VERSION)`.
2. Requires the tagged commit to be contained in remote `main`.
3. Requires the complete reusable CI, including audit, compilation, coverage,
   shell, distribution, Node, Playwright, and axe validation.
4. Builds twice from a clean checkout using the tagged commit timestamp.
5. Compares both archives and checksum files, then transfers exactly that
   validated archive/checksum pair to the publication job.
6. Creates a draft, uploads and downloads the transferred assets,
   byte/checksum-verifies them, and only then publishes.

The workflow does not create or push Git tags. A maintainer must intentionally
create and push the correctly named tag; documentation must not infer publication
from the presence of `VERSION=0.1.0` in a worktree.
