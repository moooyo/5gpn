# Project memory

This file records durable project-owner decisions that future work must
preserve. It does not replace [`AGENTS.md`](AGENTS.md) or the current architecture
in [`docs/architecture.md`](docs/architecture.md). A section marked **Pending**
describes required future behavior, not behavior that is already implemented.
Update the status and the normative documentation when an implementation lands.

## Monolith failure and process recovery

**Status: Implemented. Recorded 2026-08-05.**

- mihomo is the sole long-running process and one deliberate failure domain.
  Do not add an in-process subsystem supervisor or restart DNS and interception
  independently.
- Expected extension exceptions, timeouts, denied network operations, and
  rejected writes fail only their current operation. A critical DNS listener
  ending, an escaped panic, or another unrecoverable runtime invariant exits the
  process rather than leaving a partially live gateway.
- systemd owns process replacement. The shipped `5gpn-mihomo.service` unit
  runs `/opt/5gpn/bin/5gpn-mihomo` as the sole managed `fivegpn` user and group,
  and uses `Restart=always`,
  `RestartSec=3`, `StartLimitIntervalSec=60`, `StartLimitBurst=10`, and
  `StartLimitAction=none`. An
  explicit `systemctl stop` remains stopped.
- Restart is crash recovery, not configuration repair or a general liveness
  detector. Persistent startup errors reach the start limit, and a process that
  remains alive without making progress requires an independent external DoT
  and HTTPS pull probe. The persisted `DNS_HEARTBEAT_*` fields are currently
  inert and are not evidence of health.
- The installed runtime naming is uniformly 5gpn-prefixed. Documents live in
  `/etc/5gpn/mihomo/5gpn`, and authenticated routes use `/5gpn/*`. Exact old
  names are migration inputs only. The installer atomically renames old-only
  state, refuses two populated state trees, and removes safe idle legacy
  identities only with project provenance. The current `fivegpn` identity is
  installer-owned and is recreated non-interactively when its exclusive IDs
  are safe to retain; aliased IDs fail closed.

## Native interception extensions

**Status: Implemented. Recorded 2026-07-19, extended with operator capture-DNS
bindings on 2026-07-22, and superseded in place by the single-process mihomo
contract and explicit HTTP/3 refusal on 2026-08-05.**

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
  order, and are compiled into the same immutable in-process policy snapshot as
  capture and egress authorization. One enable confirmation lists the exact
  normalized rules and authorizes them together with the extension; there is no
  second routing-only confirmation. Reordering requires its own review because
  it can change global first-match behavior.
- Native scripts define `transform(context)`. They receive structured
  request/response data, typed settings, console logging, optional bounded
  storage, bounded action-scoped timers, and—only when explicitly declared and
  operator-confirmed—synchronous and promise-based network calls. That
  capability is a single un-parameterised grant naming no destinations: an
  earlier arrangement restricted it to a
  declared list of exact HTTP(S) origins, and no component implements that any
  more. They
  still have no filesystem, process, module-loader, socket, or ambient network
  API. A permitted script can deliberately send any data visible to it
  to any host it can reach, and every management surface must say so plainly
  before enable — as unrestricted, not as a reviewed destination set.
- Plugin engine observability is memory-only. The mihomo process retains a
  bounded 1000-entry ring of structured script-console and action lifecycle
  events and exposes snapshots only through the authenticated
  `/5gpn/interception/logs` controller route. Script console text and detailed
  action errors are not persisted to journald or another file. The Console owns
  the virtualized `/plugin-logs` view, local filters, pause snapshot, and clear
  watermark.
- Compiled JavaScript Programs and decoded settings belong to immutable config
  snapshots, but every action still executes in a fresh goja VM. Main upstream
  transports are reused only within one config generation, and explicit script
  network transports only within one action and exact origin. Pooled transports
  retain only narrow immutable transport and host-authorization projections,
  never the complete config, Programs, or settings.
  This reuse must never retain JS globals or stale permissions across requests.
- `bodyMode` limits only an action's input projection, not its possible result.
  Every matching request action therefore reserves bounded body admission
  before execution, including for a bodyless request. Fixed-length,
  identity-coded H1/H2 requests whose matching actions all use `none` may
  release that reservation and stream after ordered actions produce no URL or
  body mutation. Synthetic responses and aborts do not materialize or forward
  the input body; replacement bodies boundedly drain it to retain late
  trailers; URL rewrites retain the complete decoded-body contract. Replacement
  and synthetic result bodies are
  bounded by both action and process-wide limits. Response actions remain
  buffered because final trailers are part of their projection.
- The same network permission authorizes a request-phase URL rewrite to a
  canonical absolute HTTP(S) URL. It is not narrowed to a declared origin set,
  because the grant declares none.
  Userinfo and fragments are forbidden, HTTPS cannot downgrade to HTTP, and
  same-origin rewrites from the captured origin remain inside the extension's
  capture-host boundary.
  The rewritten request sends its complete method, decoded body, and end-to-end
  headers, potentially including `Cookie` or `Authorization`; framing and
  hop-by-hop fields remain runtime-owned. The single enable review states this
  disclosure explicitly, and all resulting traffic returns through mihomo's
  in-process inner dialer and current rule evaluation.
- Extensions cannot name, inspect, or change arbitrary application egress
  groups. A manifest may require an operator egress binding; the operator
  selects an existing mihomo group, and the in-process traffic policy passes
  that group as the inner dialer's explicit target. A separately reviewed
  typed routing rule may bypass the normal operator target with `DIRECT`, but
  cannot choose any other target. Missing or removed bindings fail closed
  without a default fallback. The explicit extension execution order determines
  action composition, the first binding that wins for an overlapping
  destination, and global routing first-match precedence.
- Native interception supports plain HTTP and TLS/H1/H2 only. `mitm.http3=true`
  is invalid and every management write attempting it fails without changing
  state. Fresh and explicitly reset mihomo seeds contain one fixed global
  UDP/443 `REJECT` that product management cannot disable. A fallback-capable
  client may retry over TCP and enter capture; an H3-only client fails. The
  guard does not disable ordinary UDP or QUIC sniffing on other configured
  ports.
- Every installed extension has an operator-owned `capture_dns` binding with
  the exact values `trust` and `china`; imported extensions default to `trust`.
  The binding is mutable state outside the immutable snapshot digest and is
  preserved across update checks and applies. Mihomo still resolves only
  through `127.0.0.1:5354`: an active captured hostname uses the first enabled
  declaring extension in execution order, `china` forces the live China group
  with its current ECS, and `trust` forces the live trust group. Non-extension
  hostnames default to trust. Client DNS policy and chnroute arbitration do not
  select this egress resolver, and URL paths cannot participate in DNS choice.
- Extension `enabled` is durable operator authorization, while runtime
  readiness is derived and never persisted. The complete enabled capture-host
  union remains claimed at the gateway while its fenced root-issued certificate
  is pending or failed; HTTP/TLS traffic is rejected before ordinary routing
  until the final certificate result, keypair hashes, validity and SAN set all
  match. The request and root result carry a target digest plus random attempt,
  stale signing attempts cannot publish, and TLS SNI, resumption and every
  request on an existing connection repeat the same immutable-plan admission.
  Certificate readiness changes neither the interception revision nor
  operator-owned mihomo YAML and does not require a process restart.
- Typed extension settings are exposed through the Console and are replaced as
  one complete revision-protected map, never a sequence of per-key writes. An
  enabled extension may apply a reviewed update without first being disabled:
  the refetched digest-verified candidate is fully validated and compiled, then
  one immutable Config swap lets in-flight requests finish on the old snapshot
  while later requests see only the new one. Execution order, bindings and
  type-compatible values survive; missing new required values or egress state
  reject the update before persistence rather than silently disabling it.
- One extension, one action host matcher, and the enabled interception
  certificate set are each bounded to 512 capture-host patterns. The routing
  and action/upstream-mapping declaration limits remain independently bounded
  at 256.
- URL install and local add are separate actions. URL install accepts one HTTPS
  manifest and may snapshot relative HTTPS scripts. Local add accepts one
  pasted or uploaded manifest and uses inline or absolute HTTPS scripts.
- First-party extension source, including Apple WLOC, is maintained in the
  separate `moooyo/5gpn-extensions` repository. The core repository does not
  vendor, seed, or release extension manifests or scripts. Its target
  coordinates still use the generic `location` setting and map editor available
  to any native extension.
- The extensions repository publishes a deterministic
  `5gpn.io/marketplace/v1` index through GitHub Pages. Operators explicitly add
  marketplace URLs through the authenticated Console; successful refreshes
  retain a complete bounded index snapshot and failures preserve the prior
  snapshot.
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
- The monolith Telegram bot is read-only and alert-only. It may report status,
  resolve a name, and send transition alerts to allowlisted administrators. It
  cannot mutate extension,
  catalog, policy, or mihomo configuration. Extension installation, review,
  enablement, settings, location, egress binding, capture-DNS binding, update,
  and ordering remain exclusively on the authenticated Console surface.

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
- A release bundle stamps `RELEASE_TAG` to its exact tag. Unpinned source
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
- A normal channel transition uses the selected release's complete verified
  installer bundle. It preserves a valid current mihomo config byte-for-byte.
  Moving from the retired multi-process design to the monolith is a separate,
  explicit checked migration: legacy anchors and the old interception inbound
  are removed from a candidate, panel rules are rewritten to exclude `INNER`,
  the fixed UDP/443 guard is present, and the candidate passes pinned
  `5gpn-mihomo -t` before atomic publication.
- The installer still accepts only the one current `dns.env` key schema. The
  retired `DNS_EGRESS_RESOLVER` key is not ignored or migrated. Every pre-v5
  deployment, including `0.0.19`, `test-env`, and `kfchost`, must first use its
  old v4 control plane to snapshot active state, disable MITM, remove the old
  managed rules, and retain a separate clean post-disable baseline. A fixed
  explicit rebuild then preserves the listener, SOCKS credentials, TLS paths,
  upstream proxy, and protocol booleans in a checked, atomically published,
  disabled empty v5 document. Historical sidecar and DNS routing checks must
  both pass against the clean mihomo file before the legacy config and env
  candidates publish with rollback copies. Never delete v4 and accept randomized credentials against a preserved
  mihomo file. Extensions are re-imported and reviewed; this is not a lossless
  automatic migration.
- `--beta upgrade-reset-mihomo` is the only installer upgrade mode authorized to
  replace the full operator mihomo config. It requires an existing installation,
  a pinned beta bundle, and an interactive TTY confirmation. It must back up the
  old bytes, validate the complete current seed with pinned `5gpn-mihomo -t`, publish
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
