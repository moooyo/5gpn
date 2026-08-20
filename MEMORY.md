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
  release, whose `release/pins.env` records the independent release tags, asset
  templates, and SHA-256 pins for each upstream artifact. The strict
  `release/pins.sh` parser is the only executable authority. The host installer
  fetches those artifacts; the Docker build copies the same verified artifacts
  into OCI. Neither path rebuilds either component. The controller returns HTTP 403 for
  `/upgrade` and `/upgrade/ui`; Zashboard exposes no manual, automatic, or
  update-check path for either component. Updating GEO data remains separate.
- A shared `5gpn-interception` contract revision is a paired Core/Console
  release even though the two repositories keep independent tags. The 5gpn
  repository updates both tags and SHA-256 values in one commit, stages and
  verifies both artifacts before publication, publishes the binary and Console
  tree before restarting mihomo into the new pair, and does not claim that the
  two filesystem replacements are one atomic operation. A deliberately mixed
  pair is not a supported release state; exact capability matching makes a
  transient or partial mismatch fail closed.
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

## Simplified Docker delivery

**Status: Implemented on the merged root maintenance line; the container-capable
Core and Console pair is published and pinned. Fresh release-mode acceptance and
the resulting `FIVEGPN_CONTAINER_ACCEPTED_*` variables remain pending.
Recorded 2026-08-09, updated 2026-08-21.**

- Docker is a packaging and process-lifecycle variant, not a second runtime
  architecture. One `linux/amd64` image runs as one container and one Compose
  service. Synchronous entrypoint bootstrap ends with `exec 5gpn-mihomo`, so
  mihomo is PID 1 and remains the sole long-running product process. There is no
  sidecar, init, cron daemon, systemd instance, or in-container supervisor.
- The extension worker boundary is unchanged. Fixed identity `10001:10001`
  owns the runc-delegated private cgroup, the existing runtime normalizes itself
  into `/main`, and the real cgroup-FD startup probe remains fatal before
  listeners open. The first supported host is rootful Docker Engine 28 or newer
  with a pure cgroup v2 hierarchy, the systemd cgroup driver, no daemon user namespace
  remapping, Docker's writable-cgroup delegation, and the shipped seccomp
  profile that permits `clone3` without unconfined seccomp or `SYS_ADMIN`.
  Rootless Docker, Docker Desktop, SELinux enforcing, and arm64 are not part of
  the first support contract.
- After the worker probe succeeds, a container-only certificate manager may
  run the fixed trusted public-renewal and interception-reconciliation helpers.
  They are globally serialized, short-lived process groups, are always waited,
  and are terminated before engine shutdown. A container `/restart` request and
  SIGTERM both perform complete orderly shutdown; Docker's
  `restart: unless-stopped` policy replaces the whole failure domain. Compose
  grants that shutdown path 45 seconds before forced termination.
- Docker certificate issuance is Cloudflare DNS-01 only. The Compose
  `cloudflare_api_token` secret becomes a mode-0600 Certbot credential in
  `/run`, one `<base>` lineage covers `<base>` and `*.<base>`, and the `dot` and
  `console` roles are published without restarting the gateway. Docker rejects
  HTTP-01, debug, and every unknown certificate mode. The host installer keeps
  its existing three modes.
- `.5gpn-docker-lineage-ready` is the Docker public-lineage commit fence. Before
  it exists, only marker-owned first-boot partials may be cleaned and ACME
  accounts remain; after it exists, an invalid current lineage restores only a
  validated complete generation or fails closed. Role generation deletion uses
  `.delete.<pid>.<random>` tombstones.
- The owner explicitly accepts weaker key isolation in exchange for a single
  container. The same `fivegpn` container identity can read the Cloudflare
  token, ACME account, public private keys, and interception CA signing key.
  The helpers remain trusted and short-lived, but process, network, or key
  namespace separation is not claimed.
- Persistence is split into exactly two fixed-identity named volumes:
  `fivegpn-data` at `/etc/5gpn` and `fivegpn-ui` at `/opt/5gpn/ui`. The image
  root is read-only and only runtime scratch paths are tmpfs. The numeric
  `fivegpn` UID/GID is therefore part of both volume ABIs. A volume created by
  the retired container-runtime-v1 schema is rejected unchanged; Docker does
  not migrate or adopt it in place.
- Docker follows the current configuration boundaries. Durable `dns.env` has
  exactly the six installation-coordinate keys and never contains the
  controller secret; that secret exists only in operator-owned `config.yaml`.
  Existing Core-owned documents are validated by the pinned Core's
  `5gpn-state validate --owner-uid` mode, the controller projection is checked
  through owner-scoped `5gpn-config inspect-controller --owner-uid` v2, and the
  Console is durably published in `fivegpn-ui` as a complete
  `/opt/5gpn/ui/current` generation rather than a flat tree. The
  current seed has no `:5060` listener or static gateway `IP-CIDR` rule.
- A GitHub Release still contains exactly the installer archive, its checksum,
  and the notice file. The same tag publishes
  `ghcr.io/moooyo/5gpn:<tag>`; stable tags also advance `latest`, while beta
  tags never do. Image assembly downloads and verifies the exact mihomo and
  zashboard coordinates from the tagged `release/pins.env` through the shared
  strict parser; no second Docker pin file exists. The pinned mihomo must
  additionally answer the offline
  `5gpn-container-contract` probe with exactly
  `5gpn-container-runtime-v2`; this prevents a release from packaging an older
  core that has the right version syntax but no container lifecycle.
- The exact GHCR tag is published before the GitHub draft and its resolved OCI
  digest is written into the release body. A retry may reuse an existing exact
  tag only when its image content digest and complete label map equal the local
  candidate, and may reuse only the matching draft or immutable release.
  Stable `latest` moves last, after the GitHub release is immutable; a beta
  never moves it. This ordering makes a partial publication resumable without
  letting `latest` name an unpublished release.
- Hosted CI can prove pin verification, image construction, and static smoke
  only. It must not present those checks as cgroup validation. The release
  readiness gate is a real Docker 28/cgroup-v2 run on a disposable target
  reached through `test-env`, covering the startup probe, extension execution
  and OOM containment, certificate hot publication, recreate, and volume
  persistence. The working gateway's read-only deployment authorization does
  not authorize this mutating acceptance. Release fails closed unless
  `FIVEGPN_CONTAINER_ACCEPTED_COMMIT` and
  `FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256` bind that evidence to the exact
  tag commit and its current pinned core digest, while
  `FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID` must equal the reproducibly rebuilt
  candidate image content digest.
- The acceptance driver verifies that its Git root and `HEAD` identify the
  accepted commit and that every versioned pin-manifest, Compose, seccomp,
  driver, and probe input is tracked and unchanged at that commit. A copied or
  locally weakened harness cannot emit release evidence by repeating the
  expected commit string.
- The older branch passed development-mode acceptance before the current-schema
  installer, container-runtime-v2 contract, centralized pin manifest, durable
  UI volume, and acceptance-safety changes landed. That evidence is historical
  and cannot authorize publication of the merged result. The container-capable
  pair is now recorded in `release/pins.env` — the pinned Core answers the
  runtime-v2 handshake and the pinned Console carries the
  deployment-neutral wording — so publication now waits only on the exact merged
  image passing fresh release-mode acceptance and the three
  `FIVEGPN_CONTAINER_ACCEPTED_*` variables recording that run.

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

- `dns.env` contains exactly six host-specific inputs: base domain,
  public/gateway/listener IPv4 values, certificate mode, and certificate email.
  DoT/debug/origin listeners, controller/UI coordinates, and certificate paths
  are fixed constants. Live policy, upstreams, subscriptions, resolver tuning,
  statistics, health monitoring, and the controller secret are not mirrored.
  Unknown and retired keys, including the wider pre-release schema, are
  rejected; no older schema is rewritten into the current one. Existing bytes
  undergo complete read-only metadata, exact-key, and low-cost value validation
  before Gum or project-root publication, then are revalidated after claim.
- The controller secret has one persistent source: operator-owned
  `config.yaml`. Root management accepts only the pinned Core's root-only
  `5gpn-config inspect-controller` version-2 JSON projection with the exact raw
  revision, secret, TLS controller, UI root, certificate, and private-key paths.
  There is no shell YAML parser, dotenv encoding, single-key sync, or partial
  secret writer. Managed `PUT /configs` secret changes return `409`; rotation
  requires a complete file edit and explicit process restart. Authenticated
  host calls pass the bearer through a fresh inherited descriptor rather than
  curl argv, leaving stdin free for request bodies.
- The gateway coordinate in `dns.json` is installation-owned and read-only
  through `/5gpn/dns`. At startup the Core publishes it to a dynamic anti-loop
  guard limited to private 5gpn system and extension tunnel carriers. Ordinary
  client ingress and generic mihomo `INNER` traffic remain unaffected. The
  installer never writes a gateway-specific `IP-CIDR` rule into operator-owned
  `config.yaml`; a checked gateway change takes effect after a full restart.
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
  seed for a missing document. The state root is normally service-owned `0711`;
  only the otherwise exact inherited-setgid `2711` interruption shape is
  recoverable, and it is sealed and normalized before publication.
- A generic `mihomo` user or group and every retired unit definition are hard
  pre-publication conflicts regardless of whether their bytes carry a 5gpn
  marker. Detection is read-only; the installer does not stop or adopt them.
- Installed `configure` is a narrow current-schema transaction rather than a
  reinstall. It requires the current owned environment, operator YAML, DNS
  document, installed Core, identity, unit, and filesystem boundaries. It does
  not install dependencies, download or publish release artifacts, claim
  roots, create accounts, replace units or scripts, publish Console assets, or
  seed missing state. The complete candidate is confirmed before a Cloudflare
  token is held only in memory; it is written only after the node and
  certificate locks plus final certificate/configuration/DNS revalidation. A
  no-op performs no managed write, creates no node lock, and does not restart.
  External lineages and valid preserved-role recovery do not collect a project
  credential. The operator YAML revision remains pinned across the TUI and a
  concurrent edit is rejected rather than adopted. Changing transactions hold
  the node-writer file lock, validate with Core again before activation, and
  compare the revision after readiness; ordinary restarts use `try-restart` so
  a concurrent operator stop is preserved.
- Configure side effects are field-specific. Email changes only `dns.env`;
  production public-IP changes add the public DNS gate, while debug public or
  gateway IP changes also reissue the IP-bound debug certificate. Gateway
  changes use a revision-checked `dns.json.gateway` update and refresh profiles.
  Because the controller API rejects that installation-owned field, every
  certificate-role publication, gateway CAS, and other runtime-affecting
  configure write quiesces an active Core with one fail-on-conflict systemd
  `TryRestartUnit` job. PID 1
  performs its stop half and the unit's first root-only `ExecStartPre` blocks
  the start half on a private acknowledged nonce; configure never composes a
  separate stop with a later start. The nonce record binds the exact job ID and
  object path, helper control PID, and invocation. A clean TERM requires proof
  that PID 1 now owns this unit's stop job; a bare control-process signal fails
  closed. An operator stop replaces that job in PID 1, terminates either
  pre-start helper cleanly, and remains stopped because
  configure never creates a replacement job. Before a matching release exists,
  stale recovery releases only the same still-blocked job while its
  pre-publication restoration entitlement remains valid; any visible coordinate
  commit revokes that entitlement and stays inactive. A durable matching release
  is the activation commit and may complete only that exact job after current
  inputs, readiness, final active/running process state, and absence of another
  systemd job all revalidate. Failed, timed-out, or deactivating activation is
  cleaned inactive and reported as failure. Cleanup atomically closes the nonce
  record before deleting ACK/job state, so an interrupted close resumes only
  while inactive and a concurrent start cannot create a record-less acknowledgement.
  Every other mutating installer or management entry refuses retained named or
  temporary gate state before publication or systemd mutation and directs the
  operator to the installed `5gpn configure` recovery path; read-only status
  remains available.
  The account is proven process-free, and current state plus the
  exact job are revalidated before CAS. Profiles are prepared before the CAS
  and published only after `dns.json` and `dns.env`; HTTP-01 uses the same
  outer job and never starts or stops Core inside Certbot. Configure may
  release only its original blocked job before any visible certificate or
  coordinate publication. After a visible role/file/profile commit, failure
  leaves Core stopped and never rolls back the publication;
  listener changes require matching operator YAML; base or certificate-mode
  changes traverse the certificate and profile boundary. Restart is permitted
  only when mihomo was stably active and remains active at the final check. A
  deliberate stop stays stopped, while failed or transitioning service state
  rejects the transaction.
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
  role is an unsupported legacy footprint. The public Console and both signed
  iOS profiles are one atomic generation selected by the relative
  `/opt/5gpn/ui/current` symlink. Each root-owned generation carries
  `.zash_version`, disjoint `.zash_primary_files` and `.zash_compat_files`
  digest manifests, the complete Console tree, and both profiles. Install,
  renewal, and manual profile refresh share the
  certificate lock and switch current only after the complete candidate and
  its signing inputs verify. A new generation retains only the immediately
  previous release's missing primary hashed assets so an old index cannot cross
  the switch into a 404; compat files do not become the next generation's
  primary set. Top-level files always come from the new dist. The fixed
  favicon/PWA/manifest/worker URLs exposed by the preceding generation must
  remain present and generation-local, but may contain the new bytes. This is a
  one-release stable-URL assumption, not arbitrary top-level compatibility. A
  deliberate lock-order split keeps certificate writers deadlock-free: public
  renewal uses install lock, retained-gate assertion, then certificate lock;
  the interception-certificate oneshot uses certificate lock then the same
  assertion because full install waits for it while still holding the install
  lock. Configure cannot create a gate across that assertion because it also
  needs the certificate lock. A
  flat `/opt/5gpn/ui` tree and `/opt/5gpn/www` are unsupported.
- Public certificate role validation, staging, pointer commit, and protected
  cleanup have one installed implementation. `cert-role-ctl.sh` consumes the
  shared `publication-fs.sh` mount and durability primitives; the installer,
  deploy hook, renewal checker, and profile signer do not carry independent
  role-tree writers. Dot and console use one immutable source snapshot and
  sequential durable relative-pointer commits. Once either current pointer is
  visible, failure is reported as committed-partial or committed-undurable and
  is never rolled back; a later locked run repairs forward. Cleanup starts only
  after both pointers are durable and uses a current-protected tombstone so an
  interrupted exact-file deletion remains resumable.
- Public-certificate selection and Certbot ownership are independent.
  `.provenance` records only the source currently copied into the role trees;
  `.certbot-ownership` alone retains exact-base renewal and deletion authority.
  Debug selection writes `debug:none` but preserves that ownership proof. A
  return to the same production base reuses an owned lineage without Certbot
  only when the current selection is the same owned mode or same-base debug and
  the live certificate, key, production server, authenticator, credential, and
  live/archive paths all match the requested mode. Source, base, mode, or
  ownership mismatches cannot authorize reuse.
- An external canonical lineage is always read-only and non-owning. Strict
  current certificate and renewal fingerprints may select it, including after
  debug when no ownership record names that exact base; retained ownership of a
  different base is unrelated. 5gpn neither writes ownership nor enables its
  scoped renewal timer. The old currently selected base or production mode is
  not an authorization requirement for a new strictly validated external
  source. External and debug selections do not pause or take over the distro
  Certbot timer. `missing` remains a preserved-role fallback with
  renewal disabled rather than a lineage-history record; repair is classified
  again from the live strict fingerprint and exact-base ownership proof.
- Explicit Certbot lineage decommission validates the complete owned lineage,
  then withdraws current owned-renewal provenance and removes and syncs the
  exact-base ownership entry before invoking Certbot deletion. A crash or
  deletion failure leaves the lineage read-only/external and does not roll
  either withdrawal back, so a future same-named lineage cannot inherit stale
  renewal or deletion rights. An absent lineage is marked missing and its stale
  entry is cleaned without invoking Certbot. Service status requires configured
  base/mode, current provenance, and exact-base ownership to agree before an
  active project timer is shown as healthy; every mismatch is a repair state.
  Decommission retains the installed certificate publication helpers until all
  helper-validated certificate and CA deletion boundaries have completed.
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
bindings on 2026-07-22, superseded in place by the single-process mihomo
contract and explicit HTTP/3 refusal on 2026-08-05, and extended with review
contract 7 on 2026-08-17.**

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
- `5gpn-interception` capability 7 is also the exact operator review contract;
  it does not change native manifest v1, Marketplace v1, or persisted
  `intercept.json` version 6. Every installed detail and install or Marketplace
  candidate carries `review_contract: 7`. Its action list is a structured,
  bounded `ActionReview` projection with matchers, gate, kind, body mode,
  limits, source evidence, declarative parameters, and one deterministic
  `review_digest` per action. Manifest bytes, script or JQ source text, and mock
  body bytes are never returned; hidden code and bodies contribute through
  SHA-256 and byte counts. The Console identifies added, removed, changed, and
  reordered actions by action ID, digest, and sequence rather than displaying a
  raw action or source dump.
- Fresh install apply, Marketplace update apply, complete reorder, and enable
  require `review_contract: 7`; missing, stale, and future values fail with HTTP
  400 before revision or state changes. For disable, a missing, null, or zero
  value is treated as omitted so revocation remains available; nonzero stale
  and future versions are rejected. The
  Console validates returned contracts against its local constant before
  rendering an actionable review and always sends that constant rather than
  echoing the server value. Existing current-schema enabled snapshots are
  grandfathered as durable authorization: loading v7 neither disables them nor
  creates an authorization epoch, while their next protected mutation must use
  v7 and a later re-enable must be reviewed again.
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
- Typed extension `reject` and `direct` rules share that readiness boundary.
  Certificate pending/error or an unavailable fixed client boundary withdraws
  both typed decisions; claimed HTTP(S) capture hosts remain rejected, while
  unrelated traffic returns to the operator-owned routing rules. Restoring
  certificate and boundary readiness restores the same rules from the immutable
  document without a revision change or operator write.
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
  retain the stamped tag. The GitHub Release publishes exactly
  `5gpn-installer.tar.gz`, `checksums.txt`, and `THIRD_PARTY_NOTICES.md`; the
  bundle contains host installer inputs plus the minimal Docker Compose,
  seccomp, bootstrap-example, and runbook launch set, but not mihomo binaries
  or zashboard assets.
  Mihomo and zashboard are fetched from their own repositories using the
  independent release tags and SHA-256 pins embedded in that installer through
  `release/pins.env`. The
  matching GHCR image is an additional registry artifact, not a fourth GitHub
  Release asset.
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
  exact 5gpn tag into the installer bundle. Their GitHub Releases publish only
  `5gpn-installer.tar.gz`, `checksums.txt`, and `THIRD_PARTY_NOTICES.md`. CI
  verifies the independently pinned mihomo binary and zashboard asset without
  rebuilding them. It also assembles the matching GHCR image from those exact
  verified artifacts; stable advances `latest` and beta does not.
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
