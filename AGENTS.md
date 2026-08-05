# AGENTS.md

Project guidance for this repository. Read `docs/architecture.md` before making
architectural changes; it is the sole current-architecture document. Read
`MEMORY.md` for durable owner decisions and pending contracts, taking care not
to treat its explicitly pending requirements as current behavior. Historical
plans, design handoffs, and git history are context only.

## Non-negotiable architecture

- The `moooyo/mihomo` fork is the sole long-running process. It owns DoT DNS
  decisions, application-layer forwarding, native-extension interception, the
  Telegram control plane, and the authenticated controller API. Client DNS
  ingress is DoT `:853` only; public DoH and plain `:53` must not be
  reintroduced. `127.0.0.1:5353/udp` is debug-only.
- The monolith is one deliberate failure domain. Expected extension script
  errors, timeouts, denied network calls, and rejected configuration writes
  fail only their current operation. A critical DNS listener ending, an
  escaped panic, or another unrecoverable runtime invariant terminates the
  process instead of leaving a partially live gateway. Recovery belongs only
  to systemd: the shipped unit has `Restart=always`, `RestartSec=3`,
  `StartLimitIntervalSec=60`, `StartLimitBurst=10`, and
  `StartLimitAction=none`. Do not add an in-process
  subsystem supervisor. A deliberate `systemctl stop` remains stopped, and
  restart does not claim to repair deterministic configuration or host errors.
  The DNS document's listener and certificate-path fields are installation-owned
  and must be round-tripped unchanged by `/5gpn/dns` writes; changing them is
  rejected before persistence so an occupied port cannot become a restart loop.
- Native-extension interception is limited to plain HTTP and TLS/H1/H2 on
  explicitly enabled capture hosts. HTTP/3 interception is unsupported:
  `mitm.http3=true` is rejected, fresh and explicitly reset seeds contain one
  fixed global UDP/443 `REJECT`, and product management cannot disable that
  guard. A client that supports protocol fallback may retry over TCP and enter
  the normal HTTP/H1/H2 capture path; an H3-only client fails. Native
  `5gpn.io/v1` scripts execute from immutable local snapshots
  in a no-filesystem goja sandbox. A script receives bounded synchronous and
  promise-based network calls only when its manifest declares
  `permissions.network: true` and the operator confirms it. That grant names no
  destinations: a script holding it may
  reach any host it can resolve, and the manifest cannot narrow that. Every such
  request returns through mihomo's in-process inner dialer, and the URL
  canonicalization, IP-literal and unsafe-host refusals still apply. Do not
  crawl or mirror module stores. First-party extension source lives exclusively
  in `moooyo/5gpn-extensions`; do not add an `extensions/` source tree back to
  this core repository.
  Do not add Xray, sing-box,
  smartdns, chinadns-ng, TUN/TProxy, WireGuard, fwmark, policy-routing tables,
  or host firewall management.
- DNS policy is an ordered first-match list with block/direct/proxy intents and
  auto/direct/gateway fallback. It is DNS-only. The only pre-policy overlay is
  the active interception-host set published by the same certificate/mihomo
  transaction; it cannot select DNS egress. Separately, a reviewed native
  manifest may declare bounded typed mihomo `REJECT` or `DIRECT` rules. Those
  rules cannot name a proxy group, are shown exactly in the single enable
  confirmation, and exist only while both the extension and MITM master are
  enabled. An extension may also require an operator-selected mihomo egress
  group, but the manifest and script cannot name or change that group. The
  Console exposes only the narrow group list needed for this binding; do not
  recreate policy-v2, drafts/generations, node/selector APIs, or a generated
  mihomo config region.
- The installed runtime identity is intentionally uniform: the only managed
  Unix user and group are `fivegpn`, the main unit is
  `5gpn-mihomo.service`, and its executable is
  `/opt/5gpn/bin/5gpn-mihomo`. Runtime documents live under
  `/etc/5gpn/mihomo/5gpn`. Old `gpn-*` accounts, the unprefixed `mihomo`
  account/unit/binary, and the old `gpn` state directory are legacy migration
  inputs only; they are never current names or compatibility aliases.
- `/etc/5gpn/mihomo/config.yaml` is fully operator-owned. Normal install,
  reinstall, and `configure` operations preserve a valid existing file. Only
  explicit reset may replace it, after `5gpn-mihomo -t`, backup, and atomic
  rename.
  The fixed UDP/443 guard is part of fresh/reset seeds and the live readiness
  boundary, but it is not an installer-owned generated region. An operator may
  edit the complete YAML manually; if the guard is missing or disabled,
  interception readiness fails closed.
- Interception capture hosts, typed `REJECT`/`DIRECT` rules, and egress bindings
  are immutable in-memory projections of the current extension document. The
  tunnel and inner dialer consume those projections directly. Do not restore a
  sidecar, runtime-overlay socket, YAML anchors, generated mihomo rule block, or
  loopback SOCKS hop.
- The installer does not roll back. A failure before publication leaves the host
  untouched; a failure during publication leaves it partially installed and says
  so. Do not reintroduce snapshot/restore/quarantine machinery — its failure
  amplification (one unrecoverable unit disabling every healthy one) is why it
  was removed. Keep fail-before-publish checks, the locks, and staging.
- `console.<base>` is the single public bootstrap and panel SNI. `/ui/*` and its
  iOS profiles are public, while `/5gpn/*` and the ordinary controller routes
  require the mihomo controller secret. Do not restore a separate bootstrap,
  Console API, panel hostname, source allowlist, or handoff session.
- The mihomo controller secret protects `/5gpn/*` and the ordinary authenticated
  controller routes. `/ui/*` remains public for bootstrap and profile delivery.
  Plugin logs remain in mihomo's bounded in-memory ring and are read through the
  authenticated interception API; do not persist script console output or add a
  second credential, listener, or controller origin.
- There is no Python, Go module, or Web source tree in this repository. Runtime
  source belongs in `moooyo/mihomo`, Console source belongs in
  `moooyo/zashboard`, and first-party extension source belongs in
  `moooyo/5gpn-extensions`. This repository installs digest-pinned release
  artifacts from those repositories.

## Shell TUI policy: Gum

All operator-facing shell scripts use the established gum-or-echo pattern.

- `install.sh` owns `install_gum()` and the canonical helpers
  (`info`, `ok`, `warn`, `err`, `ask_*`, `gum_spin`, `card`, `phase`, `banner`).
  Gum is downloaded as a prebuilt binary and verified. Bootstrap failure must be
  non-fatal under `set -euo pipefail`: leave `_HAVE_GUM=0`, return success, and
  use plain output.
- `install_gum` must run **before** `resolve_install_configuration`. Every
  prompt lives in that stage, so bootstrapping later makes every interactive
  helper silently take its `read -p` fallback — the TUI is then never used at
  all. The gum policy suite pins the ordering.
- `UI_ACCENT` is the single accent colour for every framed or emphasised
  surface: `card` borders, `phase` headings, and the `gum choose` cursor. Do not
  hardcode a colour at a call site.
- `phase` both prints the stage heading and sets the `INSTALL_PHASE` that
  failure reporting quotes, so the operator reads the same words on screen and
  in the error. Keep them in one call.
- Sub-scripts have a small self-contained gum-or-echo preamble. They only
  detect Gum; they never install it. `quick-install.sh` runs before bootstrap,
  so it is Gum-aware-if-present with an ANSI fallback.
- Every Gum interaction (`input`, `choose`, `confirm`) is gated on `[[ -t 0 ]]`.
  `main()` must call `attach_tty` first so `curl | sudo bash` can reattach
  `/dev/tty`; first install without a TTY fails closed, while reinstall may use
  an already persisted valid `dns.env`. Caller environment is never config input.
- Prompt captures must tolerate cancel under `set -e`, for example
  `value="$(ask_text '…' || true)"`.
- `gum_spin` wraps opaque waits only, never commands whose output the operator
  needs to read.
- Do not introduce raw `read`, `whiptail`, or `dialog` as the primary UI path.
  Plain `echo`/`printf` remains the mandatory fallback.

## Installer and filesystem safety

- `/etc/5gpn/dns.env` is the installer environment source of truth. New daemon
  knobs need config parsing, installer persistence, the example env file, and
  tests together.
- Never execute a broad `nft flush ruleset`, overwrite the host's nftables
  configuration, disable its firewall service, or assume ownership of unrelated
  tables. 5gpn does not create, migrate, or remove host firewall rules.
- The project is pre-release: persist and accept only the current configuration
  keys, file schemas, commands, and callback formats. Do not add compatibility
  aliases, schema migrations, or retired-component teardown paths.
- `CERT_MODE` is exactly `cloudflare`, `http-01`, or `debug`. Both production
  modes use one scoped `<base>` Certbot lineage. HTTP-01 requires exact
  console/dot A records, no AAAA, and may stop mihomo only for the bounded
  standalone challenge; Cloudflare credentials are used only by DNS-01.
- Any root recursive deletion must use a canonical, validated path plus a 5gpn
  ownership marker. Refuse `/`, system directories, empty paths, and unowned
  custom directories.
- Debug certificates belong under `/etc/5gpn/debug-cert`, never anywhere below
  `/etc/letsencrypt/live` or `archive`.
- Third-party tools are prebuilt; no toolchain is installed on the gateway.
  Release binaries are built in CI. Keep version pins and checksum behavior
  explicit.

## DNS invariants

- Members inside one upstream group are attempted sequentially in configured
  order with fair slices of the remaining context budget. China and trust
  groups remain concurrent in auto arbitration.
- Caller cancellation is not an upstream breaker failure. Attempt deadline
  expiry may fall through to the next member.
- Rule or upstream swaps flush response cache state. Cache writes use the epoch
  captured before the rule snapshot so an in-flight old decision cannot refill
  a newly flushed cache.
- Name rewrites preserve upstream Rcode and authority data. Do not turn
  NXDOMAIN/SERVFAIL into NOERROR.
- Subscription fetches keep old cache on network, parse, or scan failure and
  reject unsafe redirect/dial targets. A partial parse must never replace a
  complete cache.
- Name-based encrypted-DNS blocking cannot stop hard-coded resolver IPs when
  client traffic bypasses the gateway. Document this limitation honestly.

## Web console conventions

- Keep the current React/DaisyUI design language, five-theme catalog, `light`
  default, and MiSans stack.
- Scale comes from tokens, never literals. `styles/theme.css` owns seven type
  steps (nothing below 11px), five radius steps, five control heights
  (32/36/40/44/48px) and the two translucent tints. `styles/scale.test.ts`
  fails a bare `text-[Npx]`/`rounded-[Npx]` and an off-4px-grid
  padding/margin/gap literal anywhere in `src/**`, plus a bare control-range
  height inside `components/ds` — the primitives are where a bypass reaches
  every page at once, and a feature-level `h-12 w-12` is usually a decorative
  circle rather than a control. A height that steps down does so at `md`, not
  `sm`: pages branch their mobile layout at 767px while Tailwind's `sm` starts
  at 640px, so an `sm:` step shrank controls inside a still-mobile layout.
  Padding and card gaps step the same way and get SMALLER on mobile. The steps
  are named, so `lib/cn.ts` must keep tailwind-merge taught about them —
  otherwise an unknown `text-<word>` is read as a colour and strips the real
  colour out of the class list.
- Colour means one thing at a time. Telling N peer entities apart uses the
  categorical `--color-chart-1..5` slots in a fixed assignment; semantic roles
  are for state only, because several themes give them identical values. The
  five decisions have one wording, the top-level `decision.*` namespace.
- Any state the operator has to act on gets a persistent, page-level surface —
  not a toast that leaves, and not one of a dozen same-shaped badges. Saved and
  live are different things and the UI has to say which is which (policy
  rules), and a control that changes what happens to data has to say what it
  changes (pause).
- `web/src/styles/index.css` cascade layering is load-bearing:
  DaisyUI is below the zds layer, while direct utility classes remain able to
  win. Do not move design-system CSS back into a losing `components` layer or
  unlayer it.
- Sidebar active state is pure CSS. Do not reintroduce JS rect measurement or a
  sliding indicator.
- Theme controls live in the top bar profile menu and Settings appearance only.
- Plugin modules live on the dedicated `/extensions` route. Keep immutable
  digests, typed settings, the network grant, operator egress
  bindings, explicit execution order, capture-host allowlists, exact typed
  routing rules, and the snapshot/trust/traffic transaction visible. Enabling
  an extension uses one confirmation that includes every declared routing rule
  and, when the network grant is present, states that all data visible to the
  script can be sent to any host it can reach. The grant is a single boolean
  that names no destinations, so a review must not present it as a reviewed
  origin list. It must also state that a
  cross-origin URL rewrite forwards the complete request method, decoded body,
  and end-to-end headers, potentially including `Cookie` or `Authorization`.
  Reordering also requires review
  because it changes action, egress, and global routing first-match precedence.
  `/extensions/hosts` owns searchable, per-plugin capture-host and egress-winner
  auditing; do not move plugin management back into Settings.
- Marketplace discovery lives on the separate top-level `/marketplace` route,
  never inside the installed-plugin page. Source aliases are local display text,
  not publisher identity. Do not fabricate popularity, author, health, or update
  metadata that the authenticated marketplace API does not provide.
- Logs remain virtualized, polling is single-flight/cancellable, and mobile
  uses card rows plus a drawer sidebar. `ds/LogSurface` owns the shared log
  chrome and the one height policy; `ds/LiveToggle` is the one pause control
  and its paused label must say what pausing does to the data. On mobile,
  filters live in a sheet and applied ones come back as chips. A settings card
  reports load state through `ds/CardState` and shows a skeleton rather than
  controls bound to `undefined`; a disabled control explains itself in
  persistent text, never a tooltip. Plugin engine logs live on the
  dedicated `/plugin-logs` route in the Plugin navigation group; DNS policy
  rules remain in Parse. Pausing the plugin stream freezes only the view while
  its bounded memory ring continues ingesting, and clearing changes only the
  browser watermark — which is why it offers an undo rather than a
  confirmation. Pausing the mihomo stream buffers and reports the count; it
  must not discard.
- Do not commit `web/dist`. Fonts are runtime-cached by the PWA; keep PWA,
  initial JS/CSS, lazy-route, and font budgets green.

## Tests and delivery

Run checks proportional to the touched surface:

```bash
for t in tests/test_*.sh; do bash "$t"; done
tests/verify-artifact-pins.sh
```

CI also renders the seed and validates it with digest-pinned mihomo. For real
deployment behavior follow `tests/integration-smoke.md`.

Preserve unrelated dirty-worktree changes. Use `rg` for discovery and
`apply_patch` for edits. Until a release policy says otherwise, change stale
pre-release contracts directly instead of preserving or migrating them.
