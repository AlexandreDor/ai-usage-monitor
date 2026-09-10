# Changelog

All notable changes to Codex Usage Monitor are documented here. The project
follows [Semantic Versioning](https://semver.org/): releases use a `vX.Y.Z`
Git tag and the value in `VERSION` is the single source of truth.

## [Unreleased]

### Added

- Estimate weekly limit value separately for each observed GPT model in
  Analytics, using exclusive-model windows and explaining unavailable mixed
  windows. Compare the aggregate and GPT-5.6 Luna, Terra, Sol and GPT-6 Astra
  on one chart by default, with individual toggles localized in English and
  French.

## [0.1.1] - 2026-09-09

### Added

- Detect full five-hour resets that remain at 100→100 with a later deadline,
  run local hooks, and emit no network notifications.
- Add GPT-6 Astra and GPT-5.6 Sol, Terra, and Luna to the model selector.
- Add Astra Standard short-context pricing for input, cache-read,
  cache-write, and output, including provider identifiers.

### Changed

- Harden the owner-scoped alert journal and state, recovery/retries/hooks, and
  expiration of stale alerts.
- Keep archive and anomaly records consistent.
- Set UI defaults with the five-hour card visible, five-hour series/markers/
  statistics hidden by default, and weekly reset analytics selected by
  default.

## [0.1.0] - 2026-08-28

### Added

- First packaged release of the local Codex quota monitor and dashboard.
- Separate systemd units for the monitor loop and dashboard server.
- Reproducible release archives with SHA-256 checksums.
- Documented installation, upgrades, rollback, and removal procedures.
