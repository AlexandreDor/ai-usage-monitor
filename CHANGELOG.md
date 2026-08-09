# Changelog

All notable releases use [Semantic Versioning](https://semver.org/):
`MAJOR.MINOR.PATCH`. A major release may change public JSON or CLI contracts;
minor releases add backwards-compatible functionality; patch releases contain
compatible fixes and documentation updates.

## [0.1.0] - 2026-08-09

### Added

- Reliable per-channel alert delivery state with bounded retries.
- Temporal rolling history with validation, corruption recovery and defensive
  size limits.
- WAL-backed SQLite archive with migration backups, integrity checks and
  bounded lock retries.
- Accessible freshness indicators and alternative data tables for both local
  dashboards.
- Shared typed configuration loading, Analytics catalog fingerprints and
  server-side breakdown pagination.
- Versioned systemd templates and checksum-producing release archives.

### Changed

- CI now pins Python and Node versions, compiles Python modules, audits npm
  dependencies and measures coverage for the new Python modules.
