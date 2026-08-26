# Release process

Codex Usage Monitor uses a small, explicit SemVer policy. `VERSION` at the
repository root is the only version source used by packaging and CI. It must
contain one SemVer value of the form `X.Y.Z` or `X.Y.Z-pre.N` (no leading
zeroes in numeric identifiers).
Git tags must be exactly `v` followed by that value, for example `v0.1.0` or
`v0.2.0-rc.1`. Stable releases use `X.Y.Z`; pre-releases are optional and must
not be presented as the latest stable release. Build metadata is not used in
release tags so archive names and GitHub assets remain unambiguous.

`CHANGELOG.md` is updated with every release. The release heading, `VERSION`,
and tag must agree. Version changes follow SemVer: incompatible public changes
increment major, backwards-compatible features increment minor, and fixes or
security corrections increment patch. Until 1.0.0, minor releases may still
contain documented compatibility adjustments appropriate for the evolving local
configuration format.

## Prepare a release

Release work starts on `dev` and must be merged before the first tag is made.
Do not create `v0.1.0` on a feature branch. The initial release is deliberately
prepared here so the tag can be published after this change has merged:

1. Update `VERSION` and add the dated section to `CHANGELOG.md`.
2. Review installation, upgrade, rollback, and removal notes in
   [`docs/INSTALL.md`](INSTALL.md).
3. Run the local checks, including `systemd-analyze verify` and the reproducible
   archive/checksum check described below.
4. Commit the version and changelog update on `dev`, merge it, and inspect the
   merge commit. Do not tag an unmerged feature branch.
5. Create and push the matching annotated tag, for example
   `git tag -a v0.1.0 -m 'Release v0.1.0'` followed by `git push origin v0.1.0`.

The release workflow is triggered by `v`-prefixed tags, then re-checks the tag
and changelog heading against `VERSION`; non-SemVer or mismatched values fail
before publication. It runs the same pinned-runtime, coverage, shell, browser,
systemd, and npm-audit controls as CI, then builds the archive, verifies its
SHA-256 file, and publishes exactly the archive and checksum assets to the
GitHub Release.

## Build and verify locally

```bash
scripts/build-release.sh --version 0.1.0 --tag v0.1.0 --output-dir dist
(cd dist && sha256sum --check codex-usage-monitor-0.1.0.tar.gz.sha256)
tar -tzf dist/codex-usage-monitor-0.1.0.tar.gz | sed -n '1,20p'
```

The builder enumerates only files tracked by Git, writes a versioned archive
root, fixes tar and gzip timestamps from `SOURCE_DATE_EPOCH` (default `0`), and
fails closed if `.env`, SQLite files, or `local/runtime` are tracked. Two builds
from the same tracked tree and epoch therefore have identical archive bytes.
The checksum file uses the conventional `sha256sum --check` format.

## Release safety

Never commit `local/.env`, `local/runtime`, Codex authentication, notification
tokens, Gist credentials, or personal alert scripts. The release workflow has
only `contents: write` permission because it must create the GitHub Release;
pull requests and the normal CI workflow retain read-only contents access. The
first `v0.1.0` tag is intentionally a post-merge action and is not created by
this feature branch.
