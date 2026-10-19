# Changelog

All notable changes to Codex Usage Monitor are documented here. The project
follows [Semantic Versioning](https://semver.org/): releases use a `vX.Y.Z`
Git tag and the value in `VERSION` is the single source of truth.

## [Unreleased]

### Fixed

- Preserve observed 5-hour reset notifications when registration recovery uses
  a synthetic arm for the same event. Partial retries now deliver the original
  notification once instead of an internal suppression message, and retain
  existing delivery attempts and retry deadlines.

## [0.2.1] - 2026-10-18

### Changed

- Use compact single-line Discord and Telegram quota notifications, with the
  remaining balance for threshold alerts and distinct scheduled, observed
  5-hour, and confirmed full-quota weekly reset messages. Next reset dates use
  `DD/MM/YYYY HH:MM` in `Europe/Paris`; missing or elapsed deadlines are shown
  as `unknown`. Notifications already queued retain their original text.

### Fixed

- Show `unknown` for an observed 5-hour refill whose next deadline has already
  elapsed at the original observation, including during registration recovery.
  A deadline that was future at that observation retains its original label
  across delayed retries.
- Hide the dashboard data age while snapshots are fresh. Stale snapshots still
  show their age and collection delay, and unavailable data keeps its explicit
  status in both local and external modes.

This release keeps SQLite schema v5 and the existing configuration format.
Upgrading from 0.2.0 does not require an archive migration.

## [0.2.0] - 2026-10-17

### Added

- Local dashboard button to collect fresh Codex quotas, plus automatic live
  collections 30 seconds after announced 5-hour and weekly resets, including
  when the dashboard is closed.
- Account reset credit balances and expiration countdowns in the dashboard
  and Analytics, with historical observations, an accessible table, and quota
  CSV columns. Missing credit details remain unknown, and private credit
  identifiers and descriptions are never published.
- Progressive Analytics loading, previous-period comparisons, remembered filters
  and locally shareable views, complete filtered CSV downloads, and sanitized
  monitor/archive/anomaly diagnostics.
- Shared IANA timezone, user-set EUR conversion rate and optional rate date.
- Verified atomic live-WAL backups with safe retention and an opt-in daily
  systemd timer.
- Dense-history loading and rendering performance budgets in CI and release
  validation, alongside the existing idle benchmarks.
- Prototype a compact Analytics model explorer with searchable model cards, family
  filters, selected-model chips and explicit Apply/Cancel for batch changes.
  The explorer starts collapsed and expands without internal scrolling.
  Date range, application and model filters share a unified row layout and
  selection styling.
  English and French controls support keyboard navigation and mobile layouts.
- Select GPT-6.1 Sol by default in Analytics and the GPT quick selection,
  with its own weekly-limit value curve and Standard API reference prices.

### Performance

- Reuse model identities, pricing checks and regression sensitivity solves while
  preserving all estimator checks and complete chart data.
- Bound and coalesce reusable analytics work, invalidate caches after archive or
  pricing changes, and preserve live stale-data transitions.
- Populate closed chart tables on demand and reuse locale-aware formatters.
- Serve compressed text responses and revalidate unchanged static assets with
  ETags while keeping local usage responses uncacheable.

### Fixed

- Reset Analytics allocation and reset-history pages when changing the timezone
  of a custom date range, preventing empty pages after its UTC boundaries move.
- Preserve SQLite reader locks during archive-path validation so diagnostics
  cannot leave Analytics attached to deleted WAL files after collection.
- Preserve requested allocation and reset pages when a collection changes the
  archive revision and Analytics reloads a coherent snapshot; failed recovery
  or a failed reset replacement retries from the displayed page without
  skipping it, including overlapping pagination requests in different tables.
- Restore Python 3.9 backup compatibility with non-following path metadata
  reads, and require the backup suite on Python 3.9.25 in CI.
- Confirm weekly 100% → 100% deadline advances consistently in alerts, anomaly
  detection and reset history, with durable hook deduplication and distinct
  full-quota evidence instead of an unsupported refill claim.
- Preserve confirmed full-quota weekly cycles and their original observation
  times across live/full collection, restarts and archive compaction, without
  reconstructing canceled candidates or duplicating superseded reset events.
- Provide a maintained, bounded weekly starter that validates cycle evidence
  instead of declaring success from any future reset date.
- Disable persistent Analytics caching under replaceable or symlinked ancestors
  before SQLite opens a path, while preserving calculations and trusted sticky
  directories.
- Reject replaceable source/destination ancestry before SQLite backup opens,
  publish only the reserved, verified nonempty backup inode, and preserve source
  archives even when their paths use aliases.
- Export allocations above the JSON response limit from one paginated snapshot;
  limit and token CSV exports no longer depend on allocation-table size.
- Preserve special characters in read-only SQLite archive URIs.
- Give Analytics charts translated accessible names.

### Changed

- Upgrade the local SQLite archive to schema v5 for reset credit observations,
  preserving existing quota history and creating a verified backup before
  migrating older archives. Credit history starts with new collections.
  Returning to an older release requires restoring an archive backup supported
  by that release; see [the upgrade and rollback guide](docs/INSTALL.md#upgrade).
- Show unstable but identifiable positive model estimates with high-uncertainty
  markers and sensitivity ranges, including explicit unbounded upper ranges.

- Combine provider aliases of the same model into one weekly-value predictor,
  curve, and toggle while retaining provider-specific event pricing.
- Infer low-confidence per-model weekly values for eligible mixed-model usage
  from adaptive, non-overlapping observations retained across completed weekly
  cycles for up to 28 days.
  Full-rank, conditioning, fit, and positive-coefficient checks keep
  unsolvable attributions unavailable, while the aggregate
  continues to include every locally collected source.
- Carry the last accepted direct or inferred per-model value for up to seven
  days across ordinary gaps and weekly resets, with its source date, age,
  method, and low-confidence styling. Contradictions, malformed data, stale
  samples, and limit changes clear the carried value.

## [0.1.2] - 2026-09-10

### Added

- Estimate weekly limit value separately for each observed GPT model in
  Analytics, using exclusive-model windows and explaining unavailable mixed
  windows. Compare GPT-5.6 Luna, Terra, Sol and GPT-6 Astra
  on one chart by default, with individual toggles localized in English and
  French. The aggregate curve is available but hidden by default.

### Fixed

- Scope release publication to this repository.

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
