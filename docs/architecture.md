# 5gpn current architecture

This document is the normative description of the current 5gpn system. It
describes the deployed architecture and the invariants that new changes must
preserve. Design proposals and archived migration notes are not sources of
current behavior.

## System boundary

5gpn is an IPv4 DNS-steering gateway with two runtime components:

- `5gpn-dns` is the DNS decision engine and control-plane process.
- mihomo is the application-layer forwarding data plane.

The DNS answer determines whether a client connects directly to an origin or
connects to the gateway. When the gateway address is returned, mihomo sniffs
the original hostname and owns every subsequent egress choice. DNS policy does
not choose a mihomo node, proxy group, selector, or transport.

```text
client
  | DoT :853
  v
5gpn-dns -- ordered DNS policy and deterministic CN arbitration
  |                         |
  | real origin address     | gateway address
  v                         v
client direct          mihomo :80/:443 -- operator-defined application egress
```

This is not a host router or VPN. The project does not install or manage TUN,
TProxy, WireGuard, fwmarks, policy-routing tables, NAT, or a host firewall. It
does not contain Xray, sing-box, smartdns, or chinadns-ng in the live
architecture.

## Listeners and network ownership

| Owner | Default listener | Purpose and exposure |
| --- | --- | --- |
| `5gpn-dns` | `:853/tcp` | The only client DNS ingress, DNS over TLS. |
| `5gpn-dns` | `127.0.0.1:5353/udp` | Local debugging only; it must remain loopback. |
| `5gpn-dns` | `127.0.0.1:5354/udp` and `/tcp` | Egress DNS broker used by mihomo after hostname sniffing. |
| `5gpn-dns` | `127.0.0.1:443/tcp` | Public HTTPS console assets and iOS profile download, plus the bearer-authenticated API. |
| `5gpn-dns` | `127.0.0.2:443/tcp` | HTTPS zashboard static files and its controller proxy. |
| mihomo | configured local IPv4 addresses on `:80/tcp` and `:443/tcp+udp` | SNI/HTTP/QUIC ingress for traffic steered to the gateway. |
| mihomo | `127.0.0.1:9090/tcp` | TLS-only external controller. |

There is no public DoH listener and no client-facing plain DNS listener on
`:53`. Those transports must not be reintroduced. The debug DNS and egress
broker addresses must reject non-loopback or non-IPv4 configuration.

The `5gpn-dns` systemd unit is softly ordered after mihomo (`Wants`/`After`),
not coupled with `Requires` or `BindsTo`: a controller or data-plane failure
must not prevent the DNS engine and the rest of its control plane from
starting.

## DNS policy and resolution

`/etc/5gpn/policy.json` is the operator policy model. It contains one ordered
list of enabled rules and one fallback. Rules have a name matcher and exactly
one DNS intent:

- `block`: return NXDOMAIN;
- `direct`: resolve and return the adopted real address;
- `proxy`: synthesize the configured gateway address.

Rules are evaluated once, in global list order, with first match winning across
all intents. The policy compiler may maintain rule-cache files and policy-owned
subscriptions, but policy apply is DNS-only. It must never render, patch, or
apply mihomo configuration. There are no policy drafts, generations,
policy-v2 objects, structured egress targets, node APIs, or selector APIs.

An unmatched name uses one of three fallbacks:

- `auto`: query the China and trust groups concurrently, adopt the China reply
  only when it contains a `chnroute` IPv4 address, otherwise adopt the trust
  reply; keep CN addresses and rewrite foreign A records to the gateway;
- `direct`: use the same arbitration but return the adopted real addresses;
- `gateway`: return the gateway address without querying an upstream.

The China/trust decision is deterministic and never selects whichever reply
arrives first. Within either upstream group, members are attempted
sequentially in configured order. Each attempt receives a fair slice of the
remaining caller deadline so one failed member cannot starve later members.
Caller cancellation is not recorded as an upstream breaker failure; an
individual attempt deadline may fall through to the next member.

Query-type behavior is intentionally IPv4-oriented:

- A follows the ordered policy and fallback above.
- AAAA returns synthetic NODATA with authority information.
- HTTPS and SVCB return synthetic NODATA so address hints or ECH cannot bypass
  A-record steering and hostname sniffing.
- Other types are forwarded through the trust group.

Rewrites must preserve the upstream Rcode and authority section. In particular,
NXDOMAIN and SERVFAIL must never become NOERROR merely because an answer name
or address is rewritten.

Rule or upstream swaps atomically replace live snapshots and flush response
cache state. A query captures the cache epoch before its rule snapshot; a
query that began under an old generation cannot repopulate the newly flushed
cache after a swap.

Subscription refresh is fail-safe. Network, redirect, parse, scan, or
too-small/partial-result failure keeps the last complete cache. URL resolution,
every redirect, and the final dial target are subject to SSRF protections.

Name-based blocking of encrypted-DNS services cannot stop a client that uses a
hard-coded resolver IP and can route around the gateway. The product and UI
must state that limitation rather than implying network-level enforcement.

## Mihomo data plane and configuration ownership

`/etc/5gpn/mihomo/config.yaml` is a complete, operator-owned mihomo
configuration. The initial seed provides listeners, hostname sniffing, the
loopback egress broker, panel routing, anti-loop rules, and a `Proxies` group
whose initial choice is `DIRECT`. After publication there is no generated or
daemon-managed region.

Normal install, reinstall, upgrade, and ordinary `change-*` operations must
validate and preserve an existing valid file byte-for-byte. They must not
silently migrate it. Only an explicit `mihomo-reset` may replace it, and reset
must:

1. render a complete candidate outside the live path;
2. validate the candidate with the pinned `mihomo -t`;
3. back up the current file;
4. publish the candidate with an atomic rename.

The raw console editor follows the same validation and atomic-publication
rules. Required infrastructure invariants cannot be edited away: the plaintext
controller remains disabled, the TLS controller stays on loopback, the shared
zash certificate paths remain fixed, and the egress DNS broker remains
loopback.

New seeds use mihomo's native TLS controller only:

```yaml
external-controller: ""
external-controller-tls: 127.0.0.1:9090
tls:
  certificate: /etc/5gpn/cert/zash/fullchain.pem
  private-key: /etc/5gpn/cert/zash/privkey.pem
```

Both the daemon's mihomo client and the zashboard reverse proxy dial the
loopback controller with verified HTTPS, use `zash.<base>` as TLS identity,
and trust the zash role certificate in addition to system roots. They require
TLS 1.2 or newer, never use `InsecureSkipVerify`, and never fall back to HTTP.
If this verified client cannot be constructed, mihomo health, config, and proxy
operations return unavailable/503 while DNS and unrelated control-plane
features continue running.

## Service hostnames and control-plane isolation

One base domain derives three single-label service names:

| Name | Role | Access boundary |
| --- | --- | --- |
| `dot.<base>` | DoT identity on `:853` | Public DNS service. |
| `console.<base>` | Public React SPA, `/ios/ios-dot.mobileconfig`, and `/api/*` | SPA assets and profile download are public; every API endpoint requires the console bearer token. |
| `zash.<base>` | zashboard | Separate mihomo source-IP allowlist route and a dedicated controller pass-through. |

Mihomo sends public console traffic to `127.0.0.1:443` and allowlisted
zashboard traffic to `127.0.0.2:443`. Non-allowlisted zashboard sources are
dropped before reaching its HTTP server.

`console.<base>` must have an externally usable A record to the public or
otherwise client-routable gateway address before installation can declare the
bootstrap path ready. In Cloudflare DNS-01 mode, `zash.<base>` may remain
synthetic and visible only after clients use 5gpn DNS. Android Private DNS
discovery likewise requires `dot.<base>` to resolve through the client's
pre-existing resolver.

HTTP-01 has a stricter public-DNS contract because all three service names are
ACME challenge targets. `console.<base>`, `zash.<base>`, and `dot.<base>` must
each have exactly one public A answer, that answer must be `DNS_PUBLIC_IP`, and
none may have an AAAA answer. The installer and configuration TUI show these
required records and require explicit operator confirmation, then wait for the
same result through the fixed independent resolver `1.1.1.1` before issuance.
The renewal path repeats the resolver check before every due HTTP-01 renewal.

The console SNI deliberately bypasses the zashboard allowlist so a new client
can download `/ios/ios-dot.mobileconfig` and load the SPA. iOS and Android
instructions, the profile QR code, and the download link live in the console's
`/setup-guide` route; there is no separately maintained install page. This does
not weaken API authentication:
all `/api/*` routes still require the bearer token, and console log WebSockets
still require one-use tickets.

The console does not expose the full mihomo controller. Authenticated REST
handlers provide narrow health and config operations. Live logs use a
cryptographically random, short-lived, one-use ticket minted by
`POST /api/mihomo/log-ticket`; that ticket authorizes exactly one
`/proxy/logs` WebSocket upgrade and is consumed before proxying. Zashboard's
separate `/proxy/` is the only general controller pass-through and forwards the
browser-supplied controller authorization.

The Telegram bot runs inside `5gpn-dns` and calls the same in-process
`Controller` used by the HTTP API. `/id` provides the caller's numeric user ID;
all status, log, and operator actions require both an authorized user ID and a
private chat. The bot explicitly subscribes to message and callback-query
updates and owns a configured token's long-polling mode rather than exposing a
webhook listener.

The bot is a compact operations surface, not a second full console. Its menu
covers status and refresh, DNS diagnosis, recent logs, upstream visibility,
rule reload, confirmed mihomo restart and certificate renewal, iOS bootstrap,
and a link to the console. Complex ordered-policy editing, subscriptions, and
the complete operator-owned mihomo YAML stay in the Web console. Privileged
operations do not weaken the daemon sandbox: narrowly scoped system-service and
certificate jobs are delegated to systemd. Destructive or disruptive actions
use expiring one-use confirmations and process-wide single-flight exclusion.

`TGBOT_PROXY_URL` optionally routes only Telegram Bot API traffic through an
HTTP/HTTPS CONNECT proxy. It is a daemon-startup setting in `dns.env`, not part
of the token/admin runtime override. 5gpn never creates a proxy listener or
changes the operator-owned mihomo configuration; an operator who points this at
local mihomo must provide and secure the required HTTP or mixed listener.

`TGBOT_ALERTS` is a default-off daemon-startup switch for transition-based
certificate, mihomo, and upstream-health notifications. Alerts are protected
private messages sent to every configured administrator who has already opened
the bot chat. They are not a liveness substitute: the alert monitor dies with
`5gpn-dns`, so process or host disappearance is detected only by an external
dead-man's switch configured with `DNS_HEARTBEAT_URL`.

## Persistent configuration

`/etc/5gpn/dns.env` is the persistent source of truth for installer-owned
deployment identity and daemon knobs. systemd reads it with
`EnvironmentFile=` and presents its keys to `5gpn-dns`; that launch mechanism
does not make the caller's ambient shell an installer configuration interface.
The installer clears recognized configuration variables before dispatch.

- On a first install, the attached-terminal TUI collects required values,
  validates them, and atomically writes the resulting configuration files.
- On reinstall, the installer reads and validates the existing
  `/etc/5gpn/dns.env` and never consults caller environment values.
- A first install without an interactive TTY fails closed. Headless shell
  variables are not an escape hatch for the TUI.
- Management TUI operations validate the complete candidate, including any
  required public-DNS gate, before atomically publishing the persisted file and
  performing the required reload or restart.
- `CERT_MODE` is exactly `cloudflare`, `http-01`, or `debug`. Installation and
  mode changes are TUI decisions; HTTP-01 additionally requires the displayed
  public DNS records to be confirmed before its resolver gate begins.
- Cloudflare mode requires its credential for both issuance and unattended
  renewal, including when the current certificate is reusable. It is entered only through the TUI,
  then stored in `/etc/5gpn/acme/cloudflare.ini` with root-only permissions. It
  is never accepted from caller environment, persisted to `dns.env`, or echoed
  in logs; HTTP-01 does not relax those rules or require that credential.

Operator-facing scripts use Gum when available and plain output otherwise.
Every Gum input, choice, or confirmation is gated on a TTY, cancellation is
safe under `set -e`, and `install.sh` attaches `/dev/tty` before prompting so
`curl | sudo bash` remains interactive. Sub-scripts detect Gum but never
install it.

Specialized live state remains in purpose-specific, atomically written files:

- `policy.json` is the ordered DNS policy;
- `subscriptions.json` and `/etc/5gpn/rules/` contain subscription definitions
  and complete caches;
- `upstreams.json`, `ecs.json`, and `tgbot.json` are control-API-managed runtime
  overrides. `tgbot.json` contains the validated token/admin set, is written
  atomically with mode `0600`, and overrides the `dns.env` bootstrap defaults.
  A present but unreadable/malformed bot override disables the bot fail-closed
  instead of restoring a possibly revoked bootstrap administrator;
- `mihomo/config.yaml` and `mihomo/whitelist.txt` are operator data-plane state.

Adding a daemon knob requires config parsing, installer persistence, the
`dns.env.example` entry, and tests in the same change. SIGHUP reloads rule files
and chnroute only; ordinary `dns.env` changes require a service restart. TLS
certificates are loaded from their files on change without making SIGHUP a
certificate-reload API.

## Certificate model and lifecycle

Both production modes use exactly one Let's Encrypt lineage with Certbot name
`<base>`. Its SAN set and ACME authenticator are mode-specific:

- `cloudflare` uses Cloudflare DNS-01 and requests exactly the apex `<base>` and
  wildcard `*.<base>`. The wildcard covers `dot`, `console`, and `zash` because
  each is exactly one label below the base; it does not cover nested names such
  as `x.console.<base>`.
- `http-01` uses Certbot's standalone HTTP challenge and requests exactly
  `console.<base>`, `zash.<base>`, and `dot.<base>`. It deliberately contains
  neither the apex nor a wildcard SAN.
- `debug` is self-signed test material, not a Certbot lineage.

The same certificate is deployed into three role directories:

- `/etc/5gpn/cert/dot` for DoT and iOS profile signing;
- `/etc/5gpn/cert/web` for console HTTPS and its public iOS profile download;
- `/etc/5gpn/cert/zash` for zashboard HTTPS and the mihomo controller.

Reinstall must prefer safe reuse over issuance. Before reusing material, it
verifies the configured mode/provenance, validity window, the exact SAN shape
required by that mode, certificate/private-key match, and (for production) a
trusted issuer chain. A legacy lineage without provenance may be adopted only
when its exact live/archive paths, authenticator parameters, and absence of
persistent per-lineage hooks form the strict expected 5gpn fingerprint; the
installer then writes provenance. Provenance records the selected mode and
whether the Certbot lineage was created by 5gpn, reused from an existing
operator lineage, or is currently missing. Cloudflare reuse requires the apex
and wildcard, while HTTP-01 reuse requires the three exact service SANs and no
apex or wildcard. A debug self-signed certificate can never satisfy production
reuse. Debug mode stores its source only below `/etc/5gpn/debug-cert`, and
repeated debug installs reuse a still-valid matching debug keypair instead of
generating a new one each time. When the canonical lineage is entirely absent,
a valid mode-matching preserved role copy may recover service without issuing a
new certificate; renewal automation stays disabled until the lineage is repaired
or reissued.

Only missing, expiring, mismatched, or invalid material causes issuance. Role
copies are staged completely before replacement. Production renewal is scoped
to `--cert-name <base>`; a 5gpn timer must not run an unscoped renewal over
every lineage on the host. Both the timer and the confirmed Telegram bot action
invoke the same mode-aware renewal helper. It returns without disruption when
the lineage is not due only after validating the Let's Encrypt production
server, authenticator, hook-free scoped renewal config, trusted live chain, and
all three deployed role copies. A stale role copy is repaired through the owned
deploy hook. The helper runs Cloudflare DNS-01 without stopping mihomo, and for
a due HTTP-01 renewal first repeats the `1.1.1.1` A/AAAA gate, then briefly
stops mihomo to release TCP `:80` for Certbot's standalone listener. The helper
restores mihomo after either success or failure; an initial HTTP-01 issuance
uses the same stop-and-restore discipline.

Install/configure, the timer, the bot action, and decommission serialize on one
root-owned private runtime lock. Installer rollback restores the exact prior
live/archive/renewal state and the timer's enabled/active state after a failed
mode change; it never consumes an unscoped or partial Certbot lineage.

The deploy hook verifies that the renewed lineage matches `DNS_BASE_DOMAIN`,
updates only the three role directories, and re-signs the iOS profile. It never
restarts mihomo merely to load certificate files: mihomo hot-loads the updated
zash role. Cloudflare renewal therefore has no data-plane interruption; the
brief HTTP-01 interruption exists only to release `:80` for ACME.

Normal uninstall preserves the 5gpn certificate lineage, role copies, debug
source, and ACME credential so a later reinstall can reuse them. Domain
decommissioning is a separate explicit operation: it must name the exact 5gpn
lineage and must never delete another Certbot lineage. `certbot delete` is
permitted only when strict path/authenticator validation passes and provenance
proves that 5gpn created the lineage. Reused or legacy/unknown lineages remain
for manual review. If such a preserved Cloudflare lineage still references the
5gpn credential, that credential is preserved so decommissioning cannot break
its future renewal.

## Installer publication and host safety

An install or upgrade is staged before it mutates the working deployment:

1. validate persisted configuration and prerequisites;
2. download version-pinned release artifacts and verify their published
   checksums;
3. render and validate candidates, including `mihomo -t` where applicable;
4. take any required backups;
5. atomically publish files and units, then restart and probe services.

A failed preflight, download, checksum, certificate, render, or validation must
leave the previously runnable binaries, units, renewal hook, and operator
configuration in place. Third-party tools are prebuilt and version-pinned; no
compiler toolchain is installed on the gateway. Gum bootstrap failure is
non-fatal and falls back to plain output.

Replacement or removal of the current `5gpn-dns`, mihomo, and certificate-
renewal service/timer units is gated by an explicit 5gpn ownership fingerprint.

Root-owned recursive deletion requires all of the following:

- an absolute canonical path;
- rejection of empty paths, `/`, and system roots;
- a non-symlink 5gpn ownership marker with exact expected contents;
- deletion constrained to the validated owned directory.

The quick-installer source marker follows the same rules. It cannot be supplied
through a symlink, forged by merely placing any file with the marker name, or
used to authorize clearing a pre-existing non-empty directory.

Uninstall removes only resources proven to be owned by this installation. It
must not stop, disable, overwrite, or delete similarly named third-party
services, binaries, configuration, or data. In particular:

- a pre-existing `/swapfile` and its fstab entry are untouched unless an
  installation ownership record proves 5gpn created that exact file;
- global `mihomo`, Gum, Xray, smartdns, sniproxy, sing-box, and Certbot assets
  are untouched unless a 5gpn marker or exact unit fingerprint proves ownership;
- legacy teardown may remove an old artifact only after that same ownership
  proof;
- unrelated systemd units, Certbot lineages/hooks, `/etc/fstab` entries,
  sysctls, modules, and directories are not modified;
- no nftables ruleset is flushed, no host firewall configuration is replaced,
  and only an unambiguously identified legacy 5gpn table may be deleted.

`--purge` can remove additional 5gpn-owned state, but it does not weaken path,
marker, lineage, or ownership checks. Certificate deletion remains separate so
purge cannot accidentally defeat reinstall reuse or remove another domain's
key material.

## Runtime hardening and failure boundaries

Both services run under hardened systemd units. `5gpn-dns` receives only IPv4
and Unix socket families and narrowly scoped writable paths. mihomo additionally
needs IPv6 and netlink for its own direct egress and route lookup, while writes
remain confined to `/etc/5gpn/mihomo`. `SAFE_PATHS` grants mihomo read access
only to the zash certificate role and does not broaden filesystem writes.
Neither runtime-service sandbox can access `/etc/5gpn/acme`; only the
out-of-sandbox, scoped renewal helper may read the Cloudflare Zone:DNS:Edit
credential.

The control API is disabled when no bearer token is configured; it is never
served unauthenticated. Certificate or TLS identity errors fail closed. A bad
non-security runtime override is logged and ignored in favor of the last valid
or persisted configuration rather than crashing the sole resolver. The
Telegram token/admin override is the deliberate exception: a present but
invalid file disables that remote control path so revoked authority cannot be
restored from stale bootstrap defaults.

The repository contains no Python. The Go module has exactly two direct
dependencies, `github.com/miekg/dns` and `github.com/go-telegram/bot`; adding a
third requires an explicit architecture decision.

## Web console constraints

The console is a React/DaisyUI SPA with the five-theme catalog, `light`
default, and MiSans stack. DaisyUI remains below the zds cascade layer while
direct utility classes can still win. Sidebar active state is CSS-only. Theme
controls live in the top-bar profile menu and Settings appearance.

Logs remain virtualized, polling remains single-flight and cancellable, and
mobile uses card rows with a drawer sidebar. Route metadata is centralized in
`web/src/app/navigation.ts`. The built `web/dist` directory is a release
artifact, not committed source; PWA, initial asset, lazy-route, and font budgets
remain enforced.

## Verification boundary

Changes are tested in proportion to their surface. The complete local gates
are the repository shell tests, Go formatting/vet/race tests, Web typecheck and
Vitest/build/bundle checks, and Playwright tests. CI also renders the mihomo
seed and validates it with the digest-pinned mihomo version. Real gateway
behavior is accepted with `tests/integration-smoke.md`.
