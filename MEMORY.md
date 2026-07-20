# Project memory

This file records durable project-owner decisions that future work must
preserve. It does not replace [`AGENTS.md`](AGENTS.md) or the current architecture
in [`docs/architecture.md`](docs/architecture.md). A section marked **Pending**
describes required future behavior, not behavior that is already implemented.
Update the status and the normative documentation when an implementation lands.

## Native interception extensions

**Status: Implemented. Recorded 2026-07-19 and superseded in place by the
current pre-release contract on 2026-07-20.**

- The extension system accepts only strict `5gpn.io/v1` native YAML manifests.
  It does not parse or emulate third-party proxy-client plugin formats.
- `traffic.captureHosts` is the sole traffic-acquisition permission. Action
  matchers and upstream mappings must be subsets of the same extension's
  capture hosts, and runtime checks repeat that ownership boundary.
- Native scripts define `transform(context)`. They receive structured
  request/response data, typed settings, console logging, optional bounded
  storage, and—only when explicitly declared and operator-confirmed—a
  synchronous network capability restricted to exact HTTP(S) origins. They
  still have no filesystem, process, timer, module-loader, socket, or ambient
  network API. A permitted script can deliberately send any data visible to it
  to those origins, and the Console must say so plainly before enable.
- Extensions cannot name or change application egress. A manifest may require
  an operator egress binding; the operator selects an existing mihomo group,
  and ordered domain/port rules on the shared authenticated
  `intercept-egress` listener enforce it. Missing or removed bindings fail
  closed without a default fallback. The explicit extension execution order
  determines both action composition and the first binding that wins for an
  overlapping destination.
- URL install and local add are separate Console actions. URL install accepts
  one HTTPS manifest and may snapshot relative HTTPS scripts. Local add accepts
  one pasted or uploaded manifest and uses inline or absolute HTTPS scripts.
- First-party extension source, including Apple WLOC, is maintained in the
  separate `moooyo/5gpn-extensions` repository. The core repository does not
  vendor, seed, or release extension manifests or scripts. Its target
  coordinates still use the generic `location` setting and map editor available
  to any native extension.

## Stable and beta release channels

**Status: Implemented. Recorded and implemented 2026-07-19.**

### Current repository state

- `main` and `beta` are independent source lines for official and beta releases.
- `.github/workflows/release.yml` classifies strict official and beta tags,
  verifies reachability from the required branch, and runs the shared
  `.github/workflows/checks.yml` gate before building either channel.
- Official releases remain normal latest-eligible GitHub releases. Beta releases
  are prereleases with `make_latest=false`.
- `quick-install.sh` and source `install.sh` default to the latest official
  release; `--beta` explicitly selects the latest verified beta prerelease.
- A release bundle stamps `DNS_VERSION_DEFAULT` to its exact tag. Unpinned source
  installs delegate to that verified bundle, and packaged or installed scripts
  retain the stamped tag so scripts, daemon binaries, web assets, and checksums
  cannot drift across releases or channels.

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

### Maintenance coverage

Future release-channel changes must update all affected surfaces together:

- `install.sh` and `quick-install.sh` argument parsing, tag validation, release
  discovery, help text, and error messages;
- `.github/workflows/release.yml`, or an explicitly separate beta publication
  workflow, while retaining `.github/workflows/checks.yml` as the common gate;
- installer and quick-installer safety tests, including default-stable behavior,
  explicit beta selection, malformed or cross-channel tags, missing beta
  releases, exact-tag pinning, and checksum enforcement;
- `README.md` installation and release documentation; and
- `docs/architecture.md` and this durable decision record.
