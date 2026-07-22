# Project memory

This file records durable project-owner decisions that future work must
preserve. It does not replace [`AGENTS.md`](AGENTS.md) or the current architecture
in [`docs/architecture.md`](docs/architecture.md). A section marked **Pending**
describes required future behavior, not behavior that is already implemented.
Update the status and the normative documentation when an implementation lands.

## Native interception extensions

**Status: Implemented. Recorded 2026-07-19 and superseded in place by the
current pre-release contract, including trusted Telegram management and
operator capture-DNS bindings, on 2026-07-22.**

- The extension system accepts only strict `5gpn.io/v1` native YAML manifests.
  It does not parse or emulate third-party proxy-client plugin formats.
- `traffic.captureHosts` is the sole traffic-acquisition permission. Action
  matchers and upstream mappings must be subsets of the same extension's
  capture hosts, and runtime checks repeat that ownership boundary.
- `traffic.routingRules` is a separate, bounded, reviewable mihomo capability.
  A rule may select one canonical exact domain, domain suffix, IPv4/IPv6 CIDR,
  or bounded any/all domain-keyword expression, with optional TCP/UDP and
  destination-port constraints. Its action is exactly `reject` or `direct`; it
  cannot name a proxy group. Each extension may declare at most 256 rules and
  enabled extensions may declare at most 2048 in total. Rules exist only while
  both the extension and MITM master are enabled, follow explicit extension
  order, and are published in the same rollback-safe mihomo transaction as the
  capture block. One enable confirmation lists the exact normalized rules and
  authorizes them together with the extension; there is no second routing-only
  confirmation. Reordering requires its own review because it can change global
  first-match behavior.
- Native scripts define `transform(context)`. They receive structured
  request/response data, typed settings, console logging, optional bounded
  storage, and—only when explicitly declared and operator-confirmed—a
  synchronous network capability restricted to exact HTTP(S) origins. They
  still have no filesystem, process, timer, module-loader, socket, or ambient
  network API. A permitted script can deliberately send any data visible to it
  to those origins, and every management surface must say so plainly before
  enable.
- The same exact-origin network permission authorizes a bounded request-phase
  URL rewrite to a canonical absolute HTTP(S) URL at a declared origin.
  Userinfo and fragments are forbidden, HTTPS cannot downgrade to HTTP, and
  same-origin rewrites from the captured origin remain inside the extension's
  capture-host boundary. After an authorized cross-origin rewrite, a later
  action may execute against or rewrite within that current external origin
  only when its own extension declares the same exact origin.
  The rewritten request sends its complete method, decoded body, and end-to-end
  headers, potentially including `Cookie` or `Authorization`; framing and
  hop-by-hop fields remain runtime-owned. The single enable review names every
  origin, states this disclosure explicitly, and all resulting traffic returns
  through authenticated mihomo SOCKS5.
- Extensions cannot name, inspect, or change arbitrary application egress
  groups. A manifest may require an operator egress binding; the operator
  selects an existing mihomo group, and ordered domain/port rules on the shared
  authenticated `intercept-egress` listener enforce it. A separately reviewed
  typed routing rule may bypass the normal operator target with `DIRECT`, but
  cannot choose any other target. Missing or removed bindings fail closed
  without a default fallback. The explicit extension execution order determines
  action composition, the first binding that wins for an overlapping
  destination, and global routing first-match precedence.
- Every installed extension has an operator-owned `capture_dns` binding with
  the exact values `trust` and `china`; imported extensions default to `trust`.
  The binding is mutable state outside the immutable snapshot digest and is
  preserved across update checks and applies. Mihomo still resolves only
  through `127.0.0.1:5354`: an active captured hostname uses the first enabled
  declaring extension in execution order, `china` forces the live China group
  with its current ECS, and `trust` forces the live trust group. Non-extension
  hostnames default to trust. Client DNS policy and chnroute arbitration do not
  select this egress resolver, and URL paths cannot participate in DNS choice.
- One extension, one action host matcher, and the enabled interception
  certificate set are each bounded to 512 capture-host patterns. The routing
  and action/upstream-mapping declaration limits remain independently bounded
  at 256.
- URL install and local add are separate actions. URL install accepts one HTTPS
  manifest and may snapshot relative HTTPS scripts. Local add accepts one
  pasted or uploaded manifest and uses inline or absolute HTTPS scripts. The
  Telegram local-add flow accepts pasted text rather than claiming an embedded
  file or Web form.
- First-party extension source, including Apple WLOC, is maintained in the
  separate `moooyo/5gpn-extensions` repository. The core repository does not
  vendor, seed, or release extension manifests or scripts. Its target
  coordinates still use the generic `location` setting and map editor available
  to any native extension.
- The extensions repository publishes a deterministic
  `5gpn.io/marketplace/v1` index through GitHub Pages. Operators explicitly add
  marketplace URLs through the authenticated Console or the trusted Telegram
  administrator private-chat surface; successful refreshes retain a complete
  bounded index snapshot and failures preserve the prior snapshot.
  Marketplace data is discovery metadata, never an execution or trust root.
  Selecting an entry refetches one manifest through the native parser, verifies
  the listed manifest/script digests and derived capability summary, and stores
  the normal disabled immutable snapshot. There is no automatic install,
  enable, update, crawling, remote artwork, or source mirroring.
- In the Web Console, marketplace discovery is a top-level `/marketplace`
  route. Installed snapshot configuration and execution remain on
  `/extensions`, with host audit on `/extensions/hosts`; the
  installed-extensions page has no decorative traffic rail or embedded
  marketplace tab. Optional marketplace display names are local labels and
  never publisher identity.
- The Telegram bot is a trusted plugin-management endpoint only for configured
  administrators in private chats. It supports marketplace source management
  and browsing, marketplace/URL/pasted-text installation, uninstall,
  enable/disable, all typed settings, `location`, egress binding, execution
  order, and update checks/applies through the same managers and state as the
  Console. Install and update apply always leave the extension disabled.
- Every Telegram mutation has a complete review followed by a short-lived,
  one-use confirmation bound to the administrator, exact private chat,
  operation payload, current revision, and exact extension snapshot or
  marketplace index digest. Stale, replayed, cross-user, cross-chat, or
  digest-mismatched confirmations fail closed. Enable reviews list every exact
  normalized routing rule. Reviews also list every declared network origin and
  explicitly warn that the script can send any visible decrypted request,
  response, setting, or storage data there.
- Telegram `location` editing accepts the client's native location message or
  explicit longitude, latitude, and accuracy. The bot warns that coordinates
  pass through Telegram. City search, the draggable OpenStreetMap point, and
  accuracy visualization remain in the Console.

## Stable and beta release channels

**Status: Implemented. Recorded 2026-07-19 and extended with the explicit
stable-to-beta upgrade contract on 2026-07-21.**

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
- The current repository revision contains the cross-channel compatibility
  check and `upgrade-reset-mihomo` flow, but a new beta prerelease must publish
  this revision before the public `--beta` selector can deploy that behavior.
  An older published beta must not be represented as equivalent to the current
  repository state.

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
- A stable release that includes the upgrade mechanism stores the verified
  quick installer from its own release bundle. An explicit `--beta` invocation
  of that installed stable script delegates the complete operation to the quick
  installer; it never uses stable templates with beta binaries. Stable releases
  that predate this mechanism still require the remote verified quick installer.
- A normal stable-to-beta install accepts the common persisted JSON schemas,
  creates beta-only interception state separately, and treats a missing
  marketplace document as an empty source list. It validates
  and preserves a valid legacy mihomo config byte-for-byte, then structurally
  checks the required interception listener, node, fail-closed rule, and
  credentials. If interception is inactive and that boundary is not ready, the
  core install may complete only with an explicit Extensions-unavailable result.
  It must not claim a complete interception upgrade or patch the YAML.
- The installer still accepts only the one current `dns.env` key schema. The
  retired `DNS_EGRESS_RESOLVER` key is not ignored or migrated. Every pre-v5
  deployment, including `0.0.19`, `test-env`, and `kfchost`, must first use its
  old v4 control plane to snapshot active state, disable MITM, remove the old
  managed rules, and retain a separate clean post-disable baseline. A fixed
  explicit rebuild then preserves the listener, SOCKS credentials, TLS paths,
  upstream proxy, and protocol booleans in a checked, atomically published,
  disabled empty v5 document. The current sidecar check and current DNS routing
  check must both pass against the clean mihomo file before config and env
  candidates publish with rollback copies. Never delete v4 and accept randomized credentials against a preserved
  mihomo file. Extensions are re-imported and reviewed; this is not a lossless
  automatic migration.
- `--beta upgrade-reset-mihomo` is the only installer upgrade mode authorized to
  replace the full operator mihomo config. It requires an existing installation,
  a pinned beta bundle, and an interactive TTY confirmation. It must back up the
  old bytes, validate the complete current seed with pinned `mihomo -t`, publish
  atomically inside the install transaction, and state that custom proxies,
  providers, groups, and rules require manual restoration. Normal install,
  reinstall, and `configure` never choose this reset.
- A successful stable-to-beta upgrade does not define or promise a direct
  beta-to-stable downgrade. Operators who need reversal retain a pre-upgrade
  system snapshot; automatic installer rollback covers failure before commit.
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
  releases, exact-tag pinning, checksum enforcement, and a frozen raw `0.0.13`
  fixture whose test performs the explicit checked rebuild before covering both
  core-preserve and explicit-reset paths plus rollback of newly created
  CA/state roots and service accounts;
- `README.md` installation and release documentation; and
- `docs/architecture.md` and this durable decision record.
