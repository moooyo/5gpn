# Project memory

This file records durable project-owner decisions that future work must
preserve. It does not replace [`AGENTS.md`](AGENTS.md) or the current architecture
in [`docs/architecture.md`](docs/architecture.md). A section marked **Pending**
describes required future behavior, not behavior that is already implemented.
Update the status and the normative documentation when an implementation lands.

## Stable and beta release channels

**Status: Pending. Recorded 2026-07-19.**

### Current repository state

- `main` and `beta` both exist. `beta` contains test functionality that is not
  yet on `main`.
- `.github/workflows/release.yml` currently publishes only bare SemVer tags such
  as `0.0.12`.
- `quick-install.sh` currently resolves GitHub's `/releases/latest` endpoint,
  and both installer scripts accept only bare SemVer release tags.
- A release bundle stamps `DNS_VERSION_DEFAULT` to its exact tag so the daemon,
  web UI, installer files, and checksums cannot drift across releases.
- CI already runs the shared `.github/workflows/checks.yml` gate for every
  branch, but no beta release or beta installer selection exists yet.

### Durable branch and release decisions

- `main` is the source of official releases.
- `beta` is the long-lived line for test features that are intentionally not
  ready to publish from `main`.
- `beta` must have an independent beta release line. A beta release is never an
  official release and must never become GitHub's latest stable release.
- Promote a tested feature to the official line by bringing the intended change
  to `main` and releasing it from `main`; do not publish an official release
  directly from a beta-only commit.
- Official tags use `X.Y.Z`. Beta tags use the SemVer prerelease form
  `X.Y.Z-beta.N`, where `N` is a positive, monotonically increasing integer for
  that base version.
- An official tag must identify a commit reachable from `main`. A beta tag must
  identify a commit reachable from `beta`. CI must reject a tag whose channel
  and source branch do not match.
- GitHub releases for beta tags must be marked as prereleases. Official releases
  must not be marked as prereleases.

### Installer contract

- A normal installation with no channel argument installs the latest official
  release. This remains the default.
- `--beta` is the explicit, non-interactive opt-in that installs the latest beta
  release. Do not add a TUI prompt or menu choice for release channels, and do
  not use the caller's environment as channel input.
- The quick-install path must honor the same contract. For example:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
  ```

- Channel selection must happen before `quick-install.sh` downloads the
  installer bundle, and `install.sh` must also understand the selected channel.
  The two layers must never select different releases.
- Resolve a release tag exactly once per installation, validate it against the
  selected channel, and pin every first-party artifact to that exact tag. Keep
  the current checksum verification, staging, rollback, and no-branch-fallback
  guarantees for both channels.
- Official resolution must ignore prereleases. Beta resolution must select only
  valid `X.Y.Z-beta.N` prereleases and must not silently fall back to an official
  release when no beta release exists.
- A packaged installer remains stamped to its own exact tag. It must not mix its
  scripts or templates with daemon or web artifacts from another tag or channel.
- The channel option affects only 5gpn's first-party release. Existing explicit
  third-party version pins remain independent.

### CI and publication contract

- Keep one shared verification gate for day-to-day CI and publication. Both
  `main` and `beta` must pass the same repository checks before release assets
  are built.
- Publication automation must distinguish official tags from beta tags and
  verify their branch provenance before publishing.
- Both channels must build from the tagged commit, stamp the exact tag into the
  daemon and installer bundle, and publish the existing version-matched daemon,
  web, installer, and checksum assets.
- Official publication must preserve the current stable `releases/latest`
  behavior. Beta publication must be a separate prerelease path and must not
  change what a default installation resolves.
- Whether the implementation uses separate workflow files or clearly separated
  jobs in one workflow is an implementation detail; the observable channel,
  provenance, and prerelease boundaries above are mandatory.

### Required implementation and maintenance coverage

When this pending contract is implemented, update all affected surfaces
together:

- `install.sh` and `quick-install.sh` argument parsing, tag validation, release
  discovery, help text, and error messages;
- `.github/workflows/release.yml`, or an explicitly separate beta publication
  workflow, while retaining `.github/workflows/checks.yml` as the common gate;
- installer and quick-installer safety tests, including default-stable behavior,
  explicit beta selection, malformed or cross-channel tags, missing beta
  releases, exact-tag pinning, and checksum enforcement;
- `README.md` installation and release documentation; and
- `docs/architecture.md` once the release-channel behavior is actually current.

After implementation and verification, change this section's status from
**Pending** to **Implemented** and replace the current-state bullets with the
new behavior. Do not leave this file describing completed work as pending.
