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
  and HTTPS pull probe. Retired `DNS_HEARTBEAT_*` keys are unsupported legacy
  footprints and make installer preflight fail before publication.
- The installed runtime naming is uniformly 5gpn-prefixed. Documents live in
  `/etc/5gpn/mihomo/5gpn`, and authenticated routes use `/5gpn/*`. Exact old
  names are unsupported footprints. Compatibility preflight reports them
  before publication without stopping, renaming, deleting, rewriting, adopting,
  or changing permissions on them. Only a fresh host or a current-schema
  deployment is supported.

## Managed component updates and Console cache

**Status: Implemented. Recorded 2026-08-06.**

- Mihomo and Zashboard are maintained forks and move only through the 5gpn
  installer, which records independent release tags and SHA-256 pins for each
  upstream artifact. A 5gpn release does not rebuild or republish either
  component. The controller returns HTTP 403 for
  `/upgrade` and `/upgrade/ui`; Zashboard exposes no manual, automatic, or
  update-check path for either component. Updating GEO data remains separate.
- Zashboard remains installable as a PWA, but its worker is network-only. It
  precaches no UI or font assets, removes caches left by earlier workers when
  it activates, and reloads their controlled windows once. Mihomo serves all
  `/ui/*` responses with `Cache-Control: no-store`. Offline Console operation
  is not a supported property because the gateway API is unavailable offline.
- Upstream synchronization is branch-explicit and uses merge commits on the
  published maintenance lines. Mihomo tracks canonical
  `MetaCubeX/mihomo:Alpha`; its fork `main` has unrelated ancestry and must not
  be used. Zashboard tracks `Zephyruso/zashboard:main`. Every sync verifies the
  merge-base first, fast-forwards the matching fork baseline, and then merges
  that baseline without rebasing already tagged downstream history.

## Cross-repository development baselines

**Status: Implemented. Recorded 2026-08-07.**

- `moooyo/5gpn` develops from `main`. The long-lived `beta` branch is only for
  test features that are intentionally not ready for the official line; it is
  not the normal development baseline.
- `moooyo/mihomo` develops 5gpn product changes on
  `feat/5gpn-monolith`. Its canonical upstream synchronization baseline is
  `MetaCubeX/mihomo:Alpha`; neither the fork's default branch nor its `main`
  branch defines the 5gpn baseline.
- `moooyo/zashboard` develops 5gpn Console changes on
  `feat/5gpn-console`. Its canonical upstream synchronization baseline is
  `Zephyruso/zashboard:main`; the upstream branch is merged into the
  maintenance branch and is not itself the 5gpn product development line.
- `moooyo/5gpn-extensions` develops, integrates, and publishes from `main`.
  Topic branches target `main`; whichever topic branch a working tree happens
  to have checked out does not redefine the repository baseline.
- New cross-repository work starts from these named maintenance or integration
  branches. Before editing, verify the checked-out branch and use the matching
  linked worktree when one already exists. Live commit tips are observations,
  not durable replacements for this branch contract.

## Installer state and certificate publication

**Status: Implemented. Recorded 2026-08-06.**

- `dns.env` contains installation-owned host coordinates only. Live policy,
  upstreams, subscriptions, resolver tuning, statistics, and health monitoring
  are not mirrored from `dns.json`. Unknown and retired keys are rejected; no
  older schema is rewritten into the current one.
- A missing `dns.json` receives the exact pinned-core defaults, including the
  ChinaMax `direct` and GFW `proxy` subscription rules. Their caches live under
  the monolith state directory; `/etc/5gpn/rules` is an unsupported legacy
  footprint.
- Standalone-resolver files, old cache trees, a sidecar `config.json`, and any
  document using a retired schema are unsupported footprints. Installer
  preflight reports them read-only and the mihomo service account never receives
  access to them. The current interception document is
  `<mihomo-home>/5gpn/intercept.json`.
- Existing `dns.json`, `intercept.json`, and `bot.json` files are validated
  read-only before publication by the staged, digest-pinned Core using its
  `5gpn-state validate --owner-uid <proven-uid>` one-shot mode. Missing
  documents remain valid seed inputs and are not created by validation. A
  present file must be a no-follow regular file owned by that UID, mode `0600`,
  and singly linked. A group-only recovery journal is usable only when all three
  documents are absent; a present document requires a proven current or
  journaled UID. The installer does not carry a second shell decoder or
  validator for existing runtime documents; it may still render the defined
  seed for a missing document.
- A generic `mihomo` user or group and every retired unit definition are hard
  pre-publication conflicts regardless of whether their bytes carry a 5gpn
  marker. Detection is read-only; the installer does not stop or adopt them.
- An incompatible `fivegpn` identity is repairable only as current installation
  recovery. A safe current ownership marker or the marked current main-unit
  definition must prove provenance, each existing UID/GID must be a system ID
  used exclusively by that identity, and the installer must durably journal the
  old numeric IDs before removing anything. Preflight only grants in-memory
  authorization; journal publication and account deletion are forbidden until
  the declared publication phase. The journal survives interruption and is
  completed only after recreated ownership is reconciled. In the
  account-absent crash window, recovery still requires safe current marker/unit
  provenance, a valid current journal, system-range recorded IDs, and proof
  that no other identity claimed them; an exact surviving `fivegpn` group may
  retain its recorded GID. The journal alone authorizes nothing. A same-named
  identity without current provenance is foreign and is rejected unchanged.
- The only current public certificate roles are `dot` and `console`. A `web`
  role is an unsupported legacy footprint. Both public iOS profiles are
  generated transactionally directly in `/opt/5gpn/ui`; `/opt/5gpn/www` is
  unsupported.
- Only explicit current gateway runtime helper scripts are copied into
  `/opt/5gpn/scripts`. Development helpers remain in the source repository and
  are excluded from the release bundle and installed tree.

## Mihomo proxy selection

**Status: Implemented. Recorded 2026-08-06.**

- The supported runtime mode is `rule`. The seed's terminal
  `MATCH,Proxies` uses the operator-defined `Proxies` selector, which initially
  contains only `DIRECT`.
- `GLOBAL` is mihomo's virtual selector for global mode, not rule-mode egress.
  Global and direct modes bypass the rule list, including the private-address
  and UDP/443 guards, and therefore withdraw the extension client boundary.
- Proxy nodes and providers persist only in the fully operator-owned
  `/etc/5gpn/mihomo/config.yaml`. `PUT /configs` can hot-apply a complete path or
  payload but never writes that file; the Console is not a node database.
- The root management TUI may explicitly add or remove static node snapshots.
  Its short-lived `5gpn-mihomo 5gpn-nodes` command accepts Mihomo/Clash proxy
  YAML and mihomo-supported share-link or standard-Base64 exports, rejects a
  partially parsed batch, revision-checks the raw operator file, validates the
  complete candidate under the service's exact `SAFE_PATHS`, and atomically
  edits only `proxies` plus membership in the existing `Proxies` selector. It
  keeps one previous-file backup, then the TUI
  hot-applies the complete path; a failed hot apply falls back to a full service
  restart against the validated new file, not an automatic rollback. There is
  no node/selector controller API, second database, generated YAML region, or
  continuing proxy subscription service.

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
  groups. Every installed extension has an explicit operator egress binding
  and new imports default to `DIRECT`; empty/unbound is not a valid state. A
  manifest may retain its egress-required flag as review metadata, while the
  operator can select `DIRECT` or an existing mihomo group and the in-process
  traffic policy passes that value as the inner dialer's explicit target. A
  separately reviewed typed routing rule may bypass the normal operator target
  with `DIRECT`, but
  cannot choose any other target. A selected group that disappears remains
  visible but fails closed without a default fallback. The explicit extension
  execution order determines action composition, the first binding that wins
  for an overlapping destination, and global routing first-match precedence.
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
  the listed manifest digest and derived capability summary, and either stores
  a new disabled immutable snapshot or atomically updates the already installed
  snapshot while retaining operator state. External script resources are
  fetched live without comparing catalog resource digests. There is no
  automatic install, enable, update, crawling, remote artwork, or source
  mirroring.
  Installed extensions have no source-URL check/update controller route or
  Console button; an operator-reviewed Marketplace entry is the only update
  path, while pasted URL/local review is install-only.
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

**Status: Implemented. Recorded 2026-07-19 and extended with the explicit beta
channel-switch and anti-downgrade contract on 2026-08-06.**

### Current repository state

- `main` and `beta` are independent source lines for official and beta releases.
- `.github/workflows/release.yml` classifies strict official and beta tags,
  verifies reachability from the required branch, and runs the shared
  `.github/workflows/checks.yml` gate before building either channel.
- Official releases remain normal latest-eligible GitHub releases. Beta releases
  are prereleases with `make_latest=false`.
- `quick-install.sh` and source `install.sh` default to the latest official
  release. `--beta` selects the latest verified beta only when its base version
  is newer than the latest official release; an older beta line is refused.
- A release bundle stamps `RELEASE_TAG` to its exact tag. Unpinned source
  installs delegate to that verified bundle, and packaged or installed scripts
  retain the stamped tag. The 5gpn release publishes exactly
  `5gpn-installer.tar.gz`, `checksums.txt`, and `THIRD_PARTY_NOTICES.md`; the
  bundle contains installer inputs, not mihomo binaries or zashboard assets.
  Mihomo and zashboard are fetched from their own repositories using the
  independent release tags and SHA-256 pins embedded in that installer.
- The current repository revision contains the cross-channel and current-schema
  compatibility checks, but a new beta prerelease must publish this revision
  before the public `--beta` selector can deploy that behavior. An older
  published beta must not be represented as equivalent to the current
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
- `--beta` is the explicit, non-interactive opt-in for a newer beta line. It
  must fail when the latest beta base is not newer than latest official. Do not
  add a TUI prompt or menu choice for release channels, and do not use the
  caller's environment as channel input.
- The quick-install path must honor the same contract. For example:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
  ```

- Channel selection must happen before `quick-install.sh` downloads the
  installer bundle, and `install.sh` must also understand the selected channel.
  The two layers must never select different releases.
- Resolve the 5gpn release tag exactly once per installation and validate it
  against the selected channel. Verify its installer bundle against
  `checksums.txt`, then use the independent mihomo and zashboard release tags
  and SHA-256 pins recorded by that bundle. Keep checksum verification,
  fail-before-publish checks, staging, and the no-branch-fallback guarantee for
  both channels. A failure before project publication leaves 5gpn-managed
  services, accounts, units, and live files untouched; dependency installation
  may already have changed shared distribution package state. A failure during
  publication is reported as a partial installation and is not rolled back
  automatically.
- Official resolution must ignore prereleases. Beta resolution must select only
  valid `X.Y.Z-beta.N` prereleases whose base version is newer than latest
  official. It must not silently fall back or downgrade when no such beta
  exists.
- A packaged installer remains stamped to its own exact 5gpn tag. It must use
  the scripts, templates, and independent component pins from that bundle; a
  mihomo or zashboard tag is not required to equal the 5gpn tag.
- A stable release that includes the upgrade mechanism stores the verified
  quick installer from its own release bundle. An explicit `--beta` invocation
  of that installed stable script delegates the complete operation to the quick
  installer; it never uses stable templates with beta binaries. Stable releases
  that predate this mechanism still require the remote verified quick installer.
- A normal channel transition uses the selected release's complete verified
  installer bundle and supports only a deployment that already conforms to the
  current identity, path, key, and document schemas. It preserves a valid
  current mihomo config byte-for-byte.
- Compatibility preflight finishes before any managed 5gpn service stop or
  project publication. A retired unit, account, group, binary, state path,
  environment key, document, certificate role, or mihomo construct is a hard
  error. The check is read-only: the installer reports the footprint but never
  stops, renames, deletes, rewrites, imports, adopts, or changes permissions on
  it.
- Exact non-sensitive installation roots may claim a safe populated directory
  when no marker exists. This fixed-path claim is not legacy adoption: known
  legacy children are still scanned and rejected before publication, invalid or
  retired markers are never replaced, and canonical-path, metadata, symlink,
  hardlink, special-entry, nested-mount, current-marker, and recursive-deletion
  checks remain mandatory. Certificate roots, the interception CA, UI trees,
  and temporary paths remain strict.
- The installer provides no in-place legacy migration, retired-component
  teardown, state salvage, schema conversion, or compatibility alias. Reusing a
  host with such a footprint requires explicit operator decommissioning or a
  rebuild outside the installer, followed by a fresh installation.
- Explicit `mihomo-reset` may replace the full operator mihomo config only on a
  current-schema deployment. It backs up the old bytes, validates the complete
  current seed with pinned `5gpn-mihomo -t`, publishes atomically, and states
  that custom proxies, providers, groups, and rules require manual restoration.
  It is not a legacy conversion path; normal install, reinstall, and `configure`
  never choose this reset.
- A successful beta channel switch does not define or promise a direct switch
  back to the official channel. Operators who need reversal retain a pre-switch
  system snapshot. Pre-publication failure leaves 5gpn-managed services,
  accounts, units, and live files untouched but does not roll back shared
  dependency package changes; once publication begins, a failure is reported as
  partial and no automatic installer rollback is claimed.
- The channel option affects only 5gpn's first-party release. Existing explicit
  third-party version pins remain independent.

### CI and publication contract

- Keep one shared verification gate for day-to-day CI and publication. Both
  `main` and `beta` must pass the same repository checks before release assets
  are built.
- Publication automation must distinguish official tags from beta tags and
  verify their branch provenance before publishing.
- Both channels package installer inputs from the tagged commit and stamp the
  exact 5gpn tag into the installer bundle. They publish only
  `5gpn-installer.tar.gz`, `checksums.txt`, and `THIRD_PARTY_NOTICES.md`. CI
  verifies the independently pinned mihomo binary and zashboard asset without
  republishing them.
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
  explicit beta selection, older-beta downgrade refusal, malformed or cross-channel tags, missing beta
  releases, exact-tag pinning, checksum enforcement, current-schema reinstall,
  explicit reset, unsupported-legacy fail-before-publication behavior, and the
  partial-publication boundaries for newly created CA/state roots and service
  accounts;
- `README.md` installation and release documentation; and
- `docs/architecture.md` and this durable decision record.
