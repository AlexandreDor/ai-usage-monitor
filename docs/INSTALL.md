# Installation and operations

This guide installs a release archive under `/opt` and keeps mutable
configuration and history outside the versioned release. The monitor and the
dashboard remain independent systemd services. Commands below assume Ubuntu or
Debian and a trusted administrator.

## Fresh installation

Install the host prerequisites and create a dedicated, non-root account. The
account needs access to the Codex CLI and its user data, but it does not need a
login shell exposed on the network:

```bash
sudo apt-get update
sudo apt-get install --yes bash ca-certificates curl python3 tar util-linux
sudo useradd --system --create-home --home-dir /home/codex-monitor \
  --shell /bin/bash codex-monitor
```

Install the Codex CLI using its current upstream instructions, then authenticate
as `codex-monitor`. The packaged monitor keeps `ProtectHome=read-only`, with a
write exception only for the real Codex state directory
`/home/codex-monitor/.codex`; the dashboard has no such exception. Prepare that
directory before login and verify that the login process leaves it owned by the
service account. The monitor never receives another user's credentials:

```bash
sudo install -d -o codex-monitor -g codex-monitor -m 0700 /home/codex-monitor/.codex
sudo -u codex-monitor -H codex login
sudo -u codex-monitor -H codex login status
sudo -u codex-monitor -H codex /status
sudo -u codex-monitor -H test -d /home/codex-monitor/.codex
sudo test "$(stat -c '%U:%G' /home/codex-monitor/.codex)" = codex-monitor:codex-monitor
```

Verify the release archive before extracting it. The checksum file must be
obtained from the same trusted release page as the archive:

```bash
sha256sum --check codex-usage-monitor-0.1.0.tar.gz.sha256
```

Install the archive in a versioned directory and point the stable `current`
link at it. Release contents are root-owned and are never used for mutable
runtime state:

```bash
VERSION=0.1.0
sudo install -d -m 0755 /opt/codex-usage-monitor/releases
sudo install -d -m 0755 "/opt/codex-usage-monitor/releases/${VERSION}"
sudo tar --extract --gzip --file "codex-usage-monitor-${VERSION}.tar.gz" \
  --directory "/opt/codex-usage-monitor/releases/${VERSION}" --strip-components=1
sudo chown -R root:root "/opt/codex-usage-monitor/releases/${VERSION}"
sudo ln -sfnT "releases/${VERSION}" /opt/codex-usage-monitor/current
```

Create the service-owned configuration and state directories. The application,
not systemd, parses `monitor.env`; the explicit environment variable only tells
the entry points where that file lives. The file must be owned by the service user
because the safe parser rejects files owned by another account:

```bash
sudo install -d -o codex-monitor -g codex-monitor -m 0700 /etc/codex-usage-monitor
sudo install -o codex-monitor -g codex-monitor -m 0600 \
  /opt/codex-usage-monitor/current/local/.env.example \
  /etc/codex-usage-monitor/monitor.env
sudo install -d -o codex-monitor -g codex-monitor -m 0700 /var/lib/codex-usage-monitor
sudoedit /etc/codex-usage-monitor/monitor.env
```

At minimum, set `CODEX_DATA_DIR` if the Codex data is not under
`/home/codex-monitor/.codex` (an override outside that directory is not covered
by the unit's writable exception), set an absolute `CODEX_BIN` when the CLI is
not on the service account's `PATH`, and keep any notification/Gist secrets in
this mode-600 file. Never put secrets in a unit's `Environment=` lines or in a
release archive.

Install and validate both real unit files:

```bash
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-monitor.service \
  /etc/systemd/system/codex-usage-monitor.service
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-dashboard.service \
  /etc/systemd/system/codex-usage-dashboard.service
sudo systemd-analyze verify \
  /etc/systemd/system/codex-usage-monitor.service \
  /etc/systemd/system/codex-usage-dashboard.service
sudo systemctl daemon-reload
```

Run the same check as the service account before enabling collection:

```bash
sudo -u codex-monitor -H env \
  CODEX_MONITOR_ENV_FILE=/etc/codex-usage-monitor/monitor.env \
  CODEX_MONITOR_RUNTIME_DIR=/var/lib/codex-usage-monitor \
  /opt/codex-usage-monitor/current/local/monitor.sh --check
sudo systemctl enable --now codex-usage-monitor.service codex-usage-dashboard.service
sudo systemctl status codex-usage-monitor.service codex-usage-dashboard.service
```

The monitor performs collection and the dashboard serves HTTP; neither unit
starts the other. Inspect failures independently with
`journalctl -u codex-usage-monitor.service` and
`journalctl -u codex-usage-dashboard.service`.

## Configuration and LAN access

The dashboard binds to `127.0.0.1` by default. It has no authentication or TLS.
For a trusted LAN, install a drop-in and replace `192.0.2.20` with the host's
firewalled address:

```bash
sudo install -d -m 0755 /etc/systemd/system/codex-usage-dashboard.service.d
sudo cp /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-dashboard.lan.conf.example \
  /etc/systemd/system/codex-usage-dashboard.service.d/lan.conf
sudoedit /etc/systemd/system/codex-usage-dashboard.service.d/lan.conf
sudo systemctl daemon-reload
sudo systemctl restart codex-usage-dashboard.service
```

Allow only the trusted subnet in the host firewall. Do not use an unauthenticated
`0.0.0.0` bind or forward port 8080 to the public internet.

## Upgrade

Keep at least one previous release directory until the new one has been
verified. Download the new archive and checksum, verify the checksum and that
the archive root/version are the expected value, then stop both services before
switching the stable link:

```bash
sha256sum --check codex-usage-monitor-0.1.1.tar.gz.sha256
sudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service

VERSION=0.1.1
sudo install -d -m 0755 "/opt/codex-usage-monitor/releases/${VERSION}"
sudo tar --extract --gzip --file "codex-usage-monitor-${VERSION}.tar.gz" \
  --directory "/opt/codex-usage-monitor/releases/${VERSION}" --strip-components=1
test "$(sudo tr -d '[:space:]' < "/opt/codex-usage-monitor/releases/${VERSION}/VERSION")" = "$VERSION"
sudo chown -R root:root "/opt/codex-usage-monitor/releases/${VERSION}"
sudo ln -sfnT "releases/${VERSION}" /opt/codex-usage-monitor/current
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-monitor.service \
  /etc/systemd/system/codex-usage-monitor.service
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-dashboard.service \
  /etc/systemd/system/codex-usage-dashboard.service
sudo systemd-analyze verify /etc/systemd/system/codex-usage-monitor.service /etc/systemd/system/codex-usage-dashboard.service
sudo systemctl daemon-reload
sudo systemctl start codex-usage-monitor.service codex-usage-dashboard.service
sudo systemctl status codex-usage-monitor.service codex-usage-dashboard.service
```

Before an upgrade that changes the archive schema, make a coherent SQLite
backup using the [backup procedure in the README](../README.md#backuprestore-sqlite).
Do not copy a live `usage-history.sqlite3` file while the monitor is writing;
the procedure uses Python's standard-library `sqlite3.Connection.backup()` and
checks `PRAGMA quick_check`.

## Rollback

Rollback changes only the release link; configuration and `/var/lib` history
remain in place. Stop both units, select a previously verified release, verify
its version, then start both units and inspect their status:

```bash
sudo systemctl stop codex-usage-monitor.service codex-usage-dashboard.service
sudo test -f /opt/codex-usage-monitor/releases/0.1.0/VERSION
sudo ln -sfnT releases/0.1.0 /opt/codex-usage-monitor/current
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-monitor.service \
  /etc/systemd/system/codex-usage-monitor.service
sudo install -o root -g root -m 0644 \
  /opt/codex-usage-monitor/current/packaging/systemd/codex-usage-dashboard.service \
  /etc/systemd/system/codex-usage-dashboard.service
sudo systemd-analyze verify /etc/systemd/system/codex-usage-monitor.service /etc/systemd/system/codex-usage-dashboard.service
sudo systemctl daemon-reload
sudo systemctl start codex-usage-monitor.service codex-usage-dashboard.service
sudo systemctl status codex-usage-monitor.service codex-usage-dashboard.service
```

If the failed release changed the archive schema, restore the separately
verified SQLite backup only after stopping both services and following the
README's safety and validation procedure. Never delete the old release or
backup until a successful collection and Analytics request have completed.

## Uninstallation

Back up `/var/lib/codex-usage-monitor` first if history matters. This removes
the services, release files, configuration, and local archive; it does not
remove the Codex CLI or any data in the service user's home directory:

```bash
sudo systemctl disable --now codex-usage-monitor.service codex-usage-dashboard.service || true
sudo rm -f /etc/systemd/system/codex-usage-monitor.service /etc/systemd/system/codex-usage-dashboard.service
sudo rm -rf /etc/systemd/system/codex-usage-dashboard.service.d
sudo systemctl daemon-reload
sudo rm -rf /opt/codex-usage-monitor /etc/codex-usage-monitor /var/lib/codex-usage-monitor
sudo userdel codex-monitor
```

Review the paths before running removal commands. The state and configuration
are not recoverable after deletion unless a separate backup exists.
