# AGENTS.md

Project guidance for this repository. Read `docs/architecture.md` before making
architectural changes; it is the sole current-architecture document. Read
`MEMORY.md` for durable owner decisions and pending contracts, taking care not
to treat its explicitly pending requirements as current behavior. Historical
plans, design handoffs, and git history are context only.

## Non-negotiable architecture

- `5gpn-dns` is the DNS brain. Client ingress is DoT `:853` only; public DoH
  and plain `:53` must not be reintroduced. `127.0.0.1:5353/udp` is debug-only.
- mihomo is the data-plane forwarder. It owns application-layer egress after a
  DNS answer steers traffic to the gateway. `5gpn-intercept` is the sole narrow
  exception for explicitly enabled native-extension capture hosts over plain HTTP,
  TLS/H1/H2, and QUIC/H3; its upstream TCP and UDP return through authenticated mihomo SOCKS5
  listeners. Native `5gpn.io/v1` scripts execute from immutable local snapshots
  in a no-filesystem goja sandbox. A script receives a synchronous network
  capability only when its manifest declares exact HTTP(S) origins and the
  operator confirms that permission; every such request returns through
  authenticated mihomo SOCKS5 and cannot escape the approved origin set. Do not
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
- `/etc/5gpn/mihomo/config.yaml` is fully operator-owned. Normal install,
  reinstall, and `configure` operations preserve a valid existing file. Only
  explicit reset may replace it, after `mihomo -t`, backup, and atomic rename.
- `console.<base>` is the public bootstrap/console SNI: the SPA and `/ios/` are
  public, while every `/api/*` request still requires the console bearer token.
  Do not introduce a separate bootstrap hostname. zashboard remains source-allowlisted.
- `/api/*` requires the console bearer token. Console mihomo logs use a
  short-lived one-use WebSocket ticket. Do not expose the full controller under
  the console `/proxy/`; zashboard has a separate allowlisted pass-through.
- There is no Python in the repository. The `5gpn-dns` Go module has exactly three direct dependencies:
  `github.com/miekg/dns`, `github.com/go-telegram/bot`, and `gopkg.in/yaml.v3`.
  The separate `5gpn-intercept` module has exactly four direct dependencies:
  `github.com/quic-go/quic-go`, `github.com/dop251/goja`,
  `github.com/dlclark/regexp2/v2` (imported only to bound goja's backtracking
  fallback), and `github.com/andybalholm/brotli` for bounded Brotli decoding.
  The YAML dependency is the explicit security boundary for structural mihomo
  invariant validation; do not add another direct dependency without an explicit
  design decision.

## Shell TUI policy: Gum

All operator-facing shell scripts use the established gum-or-echo pattern.

- `install.sh` owns `install_gum()` and the canonical helpers
  (`info`, `ok`, `warn`, `err`, `ask_*`, `gum_spin`, `card`). Gum is downloaded
  as a prebuilt binary and verified. Bootstrap failure must be non-fatal under
  `set -euo pipefail`: leave `_HAVE_GUM=0`, return success, and use plain output.
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
  console/zash/dot A records, no AAAA, and may stop mihomo only for the bounded
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
- `web/src/styles/index.css` cascade layering is load-bearing:
  DaisyUI is below the zds layer, while direct utility classes remain able to
  win. Do not move design-system CSS back into a losing `components` layer or
  unlayer it.
- Sidebar active state is pure CSS. Do not reintroduce JS rect measurement or a
  sliding indicator.
- Theme controls live in the top bar profile menu and Settings appearance only.
- Plugin modules live on the dedicated `/extensions` route. Keep immutable
  digests, typed settings, origin-scoped network permissions, operator egress
  bindings, explicit execution order, capture-host allowlists, exact typed
  routing rules, and the snapshot/trust/traffic transaction visible. Enabling
  an extension uses one confirmation that includes every declared routing rule
  and, when network origins exist, names every origin and states that all data
  visible to the script can be sent there. It must also state that a reviewed
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
  uses card rows plus a drawer sidebar.
- Do not commit `web/dist`. Fonts are runtime-cached by the PWA; keep PWA,
  initial JS/CSS, lazy-route, and font budgets green.

## Tests and delivery

Run checks proportional to the touched surface:

```bash
for t in tests/test_*.sh; do bash "$t"; done
(cd cmd/5gpn-dns && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...)
(cd cmd/5gpn-intercept && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...)
(cd web && npm run typecheck && npx vitest run && npm run build && npm run bundle:check)
(cd web && npx playwright test)
```

CI also renders the seed and validates it with digest-pinned mihomo. For real
deployment behavior follow `tests/integration-smoke.md`.

Preserve unrelated dirty-worktree changes. Use `rg` for discovery and
`apply_patch` for edits. Until a release policy says otherwise, change stale
pre-release contracts directly instead of preserving or migrating them.
