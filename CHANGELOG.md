# Changelog

All notable changes are documented in this file.

This project follows [Semantic Versioning 2.0.0](https://semver.org/):

- MAJOR versions contain incompatible behavior or configuration changes.
- MINOR versions add backward-compatible functionality.
- PATCH versions contain backward-compatible fixes.
- Pre-release versions use the SemVer suffix syntax, for example `0.2.0-rc.1`.

While the major version is `0`, incompatible changes may occur in a MINOR
release and will be called out explicitly in this changelog. The `VERSION` file
is the single source of truth for the release version. Release tags use the
same version prefixed with `v`.

## [Unreleased]

### Added

- Versioned, atomic per-user installation and update support.
- Rollback, backup, restore, and data-preserving uninstall commands.
- Reproducible release archives with SHA-256 checksums.
- Versioned systemd user services for the monitor and dashboard.
