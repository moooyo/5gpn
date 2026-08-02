# 5gpn current architecture

This document is the normative description of the current 5gpn system. It
describes the deployed architecture and the invariants that new changes must
preserve. Design proposals and archived migration notes are not sources of
current behavior.

## System boundary

5gpn is an IPv4 DNS-steering gateway with three runtime components:

- `5gpn-dns` is the DNS decision engine and control-plane process.
- `5gpn-intercept` is an allowlisted, native-extension-driven TLS and HTTP/3
  transformation sidecar that runs only while the MITM master setting is on.
- mihomo is the application-layer forwarding data plane.

The DNS answer determines whether a client connects directly to an origin or
connects to the gateway. When the gateway address is returned, mihomo sniffs
the original hostname and owns every subsequent egress choice. DNS policy does
not choose a mihomo node, proxy group, selector, or transport.

When mihomo re-resolves a sniffed hostname, it queries the loopback resolver
boundary owned by `5gpn-dns`. That path does not run client DNS policy. An
active extension may have an operator-selected `trust` or `china` capture-DNS
binding; `trust` is the default for every imported extension and for every
hostname not captured by an active extension. A `china` binding forces the
live China upstream group, including the current operator ECS value. Overlaps
use the first enabled extension in explicit execution order. DNS can select
only by hostname, so URL schemes, ports, and paths cannot select a resolver.

```text
client
  | DoT :853
  v
5gpn-dns -- ordered DNS policy and deterministic CN arbitration
  |                         |
  | real origin address     | gateway address
  v                         v
client direct          mihomo :80/:443/:5060/:8080/:8443 -- operator-defined application egress
                              |
                              | enabled extension capture hosts, authenticated SOCKS5 TCP/UDP
                              v
                       5gpn-intercept -- optional TLS/H1/H2 and QUIC v1/v2/H3 termination
                              |
                              | authenticated loopback SOCKS5 TCP/UDP
                              v
                       mihomo intercept-egress -- ordered operator group bindings, then operator egress
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
| `5gpn-dns` | `127.0.0.1:5354/udp` and `/tcp` | Loopback origin resolver used by mihomo after hostname sniffing; active extension bindings select China/trust and all other names use trust. AAAA is answered with synthetic NODATA so egress stays IPv4-only. |
| `5gpn-dns` | `127.0.0.1:443/tcp` | Public HTTPS console assets and iOS profile download, plus the bearer-authenticated API. |
| `5gpn-dns` | `127.0.0.2:443/tcp` | HTTPS zashboard static files and its controller proxy. |
| `5gpn-intercept` | `127.0.0.1:18080/tcp`, only while MITM is enabled | Authenticated SOCKS5 control and plain-HTTP/TLS interception ingress. Each authenticated UDP ASSOCIATE receives a private ephemeral loopback UDP socket. |
| `5gpn-intercept` | `/run/5gpn-intercept/logs.sock`, only while the sidecar is active | Group-restricted, read-only HTTP/1.1 health and plugin-engine log WebSocket for `5gpn-dns`; never exposed directly to browsers. |
| mihomo | configured local IPv4 addresses on TCP `:80`, `:443`, `:5060`, `:8080`, and `:8443`, plus UDP `:443` and `:5060` | HTTP/TLS/QUIC ingress for traffic steered to the gateway. |
| mihomo | `127.0.0.1:9090/tcp` | TLS-only external controller. |
| mihomo | `127.0.0.1:17890/tcp` and UDP associations | Authenticated mixed listener used only for post-transformation egress from `5gpn-intercept`. |

There is no public DoH listener and no client-facing plain DNS listener on
`:53`. Those transports must not be reintroduced. The debug DNS and egress
broker addresses must reject non-loopback or non-IPv4 configuration.

The initial seed's alternate ingress is finite and explicit. TCP `:8080` and
`:8443` are accepted so the HTTP and TLS sniffers can replace the synthetic
gateway destination with the visible Host or SNI while retaining the same
destination port. The default-enabled `speedtest-5060` module adds TCP and UDP
`:5060`; UDP forwarding there still requires recognizable QUIC with visible
SNI. These listeners do not provide arbitrary-port interception, generic raw
UDP forwarding, or routing when no usable hostname is visible. Port-scoped
rejects prevent the public console and zashboard hostnames from exposing
unrelated loopback services on `:80`, `:5060`, `:8080`, or `:8443`.

The authenticated console exposes a finite mihomo-module catalog. Module state
is derived from the complete operator-owned YAML, not from a separate state
file. The first module is `speedtest-5060`, enabled in every fresh or explicitly
reset seed. It adds TCP and UDP `:5060` on every canonical gateway listener
address, targets `console.<base>:5060`, and enables HTTP, TLS, and QUIC sniffing
on that port. The exact console name remains in `sniffer.force-domain`, so
Mihomo bypasses its TCP sniff-failure skip cache for these forced attempts.
Malformed traffic therefore cannot suppress later valid sniffing on `:5060` or
poison the cache keys used by the other default ingress ports. TCP forwarding
still requires a visible HTTP Host or TLS SNI. UDP forwarding still requires
recognizable QUIC with a visible SNI;
Ookla's native UDP protocol, SIP, and other raw UDP cannot recover the original
server after DNS steering and therefore fail closed.

Fresh and explicitly reset seeds also enable the fixed `block-quic-443`
capability. It keeps the UDP `:443` listener bound but places one canonical
`AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` rule after the egress anchor and
fail-closed terminator, and before the client anchor. UDP/443 traffic
that reaches the public gateway therefore fails immediately so clients that
support fallback can retry over TCP/HTTPS, while declared sidecar upstream
traffic is resolved by the egress anchor first. This is a mihomo ingress rule, not a host firewall;
traffic that bypasses the gateway is unaffected. Normal install and configure
operations continue to preserve an existing valid operator config byte-for-byte,
so only fresh/reset configs receive the default implicitly.

Interception routing is published as a typed, generation-versioned document
committed over a machine-only mihomo control socket — never by rewriting the
operator's YAML. The configuration carries exactly two `RUNTIME-OVERLAY,5gpn,*`
anchors that splice the committed generation into rule resolution, and no
interception rule of any kind. This is the only publication path; there is no
YAML renderer behind it, so a configuration without the anchors cannot carry
interception at all.

The data plane is therefore a pinned `moooyo/mihomo` build that implements the
overlay. Artifact staging proves this by validating an anchored candidate with
`mihomo -t` against that exact binary rather than by comparing version strings,
and refuses to install a core that rejects it — while the host is still
untouched. A mihomo upgrade discards the persisted generations, which the daemon
republishes from the sidecar document at its next start.

The rule boundary is exact: eight base panel protocol/port rejects, the two
`:5060` panel rejects, the console and allowlisted zashboard routes, the
zashboard deny-by-default rule, seven anti-loop destination guards, the
`RUNTIME-OVERLAY,5gpn,egress` anchor, the fail-closed
`IN-NAME,intercept-egress,REJECT` terminator, zero or one canonical global
UDP/443 reject, the `RUNTIME-OVERLAY,5gpn,client` anchor, and the terminal
`MATCH`. Anchor placement is a security property rather than formatting, and it
is three constraints, not two: the egress anchor must sit immediately above the
terminator, so traffic the overlay declined reaches the deny rather than falling
through to an operator rule; the client anchor must resolve before the terminal
`MATCH`, so captured traffic never reaches the operator's own routing; and the
client anchor must sit below the terminator. The third was implied by the
ordered list above and proved by nothing, which mattered because
`block-quic-443` derives its insertion point from the terminator alone — a
config with the client anchor above it accepted the capability and then wrote
the fixed global UDP/443 reject below the capture stage, inverting the
precedence this document states. Within the committed generation,
egress bindings and reviewed extension routing rules follow explicit extension
execution order and keep first-match semantics; identical rules are published
once at their first declaration, and capture rules are sorted because they all
steer at the same processor.
The anti-loop guards must follow the panel routes because
mihomo resolves the synthetic console target through `hosts` before matching
rules; moving those guards earlier would reject the legitimate console
fallback as loopback traffic. The module is manageable only with this boundary
and its exact listener/sniffer shape. Its two port-scoped rejects prevent
`:5060` from exposing either loopback panel. Forced sniffing deliberately keeps
trying after malformed traffic instead of activating Mihomo's 600-second
failure-cache skip. Repeated slow, silent, or un-sniffable TCP connections can
still consume connection and sniffing resources, however. The default `:5060`
listener must therefore be source-restricted when broad public exposure is not
intended.

An enabled ingress module creates an unauthenticated public Host/SNI relay on
the selected port. 5gpn does not manage a host firewall, so the operator must
restrict source access with the provider security group or an independently
managed firewall. Fresh install and explicit reset publish `speedtest-5060`
enabled. Reinstall, configure, daemon startup, and reload preserve the current
operator-owned YAML and never reconcile or enable a missing module implicitly.

The interception subsystem is a separate catalog from the fixed mihomo ingress
catalog. Its global master is disabled in a fresh installation. The seed always
contains an authenticated loopback `MODULE-INTERCEPT`
SOCKS5 node declared as the overlay's processor, the matching `intercept-egress`
mixed listener, the two anchors, and an `IN-NAME`
fail-closed terminator. The committed generation of a fresh seed carries no
capture rule and no egress capability. Extensions may be configured and armed while the
master is off, but they publish no DNS overlay and no capture rule until the
master is explicitly enabled; a disabled master is itself a committed generation
with an empty client stage, which is what makes the switch atomic rather than
inferred from an absent overlay. An active native extension derives exact
`domain` and `domain-wildcard` selectors only from its normalized
`traffic.captureHosts` list and combines
each with canonical port 80 and port 443 constraints. Plain HTTP, TCP TLS,
and UDP QUIC on those ports are sent to the sidecar; alternate-port traffic
continues to the operator's normal rule path. A hostname target must match
the active extension set; a pure-IP SOCKS target is accepted only until the TLS or
QUIC handshake supplies an allowlisted SNI. Unknown SNI fails closed.

Because a generation names the outbound it steers at, and the core refuses to
stage one naming an outbound that has not declared
`runtime-overlay-processor: true`, an overlay cannot be made to hand traffic to
an arbitrary proxy by naming it.

The compiler may compact one extension's exact apex plus matching
wildcard pair (`example.com` and `*.example.com`) into one
`domain-suffix` selector when the action, destination port, egress
target, and ordered owner are identical. This is only a data-plane compilation
optimization: the immutable manifest, DNS matcher, capture-host audit, and
certificate SAN set retain both declarations. Exact-only, wildcard-only,
cross-extension pairs, different egress winners, and reviewed routing rules are
never compacted.

Every installed extension also has mutable operator state named `capture_dns`.
It is exactly `trust` or `china`, defaults to `trust`, is excluded from the
immutable extension snapshot digest, and is preserved across extension update
checks and applies. It affects only mihomo's loopback origin re-resolution for
an actively captured hostname. `china` uses the live China group and its ECS;
`trust` uses the live trust group. For overlapping exact or wildcard capture
patterns, the first enabled extension in `execution_order` owns the resolver
binding. Reordering therefore changes action, egress, global routing, and
capture-DNS precedence and remains a reviewed transaction.

An active extension may also publish normalized `traffic.routingRules` into
the reserved mihomo transaction. Each rule has exactly one domain, domain
suffix, IP CIDR, or bounded domain-keyword selector, optionally constrained by
TCP/UDP and destination port. The only actions are `REJECT` and `DIRECT`; a
manifest cannot name a proxy group. These are global gateway data-plane rules,
not DNS policy and not traffic-acquisition permission. A matching `DIRECT` rule
placed before the capture block therefore deliberately bypasses both normal
operator selection and sidecar capture. The fixed global UDP/443 rejection
still precedes extension rules. Each extension is limited to 256 declarations,
and all enabled extensions together are limited to 2048. Hard-coded IP traffic
that never reaches the DNS-steering gateway remains outside their reach.

`captureHosts` remains the sole traffic-acquisition permission. It accepts only
canonical exact domains and constrained `*.example.com` wildcards. Hosts are
never inferred from a URL or path regular expression. Every action carries a
second structured host matcher that must be a subset of its own extension's
`captureHosts`; the sidecar repeats that ownership check at runtime. One
extension therefore cannot execute a broad script or upstream mapping against a
host captured only by another extension. Duplicate host declarations remain
visible for audit and intentionally compose only when each extension declared
the host itself.

One extension may declare at most 512 capture hosts, one action may match at
most 512 hosts, and the enabled certificate set may contain at most 512 unique
host patterns. These matching limits are independent from the existing 256
action/upstream-mapping and 256 routing-rule limits.

The sidecar accepts plain HTTP and terminates TLS. The `http2` setting controls
both client-side HTTP/2 negotiation and upstream HTTP/2 attempts; disabling it
leaves HTTP/1.1 only for new TLS connections. With
`quic_fallback_protection` off, the sidecar terminates QUIC v1/v2 with HTTP/3.
With it on, authenticated UDP associations discard only IETF QUIC v1/v2 traffic
already selected by the active extension-capture rules, allowing a capable client to
retry over TCP/HTTPS. This does not claim legacy GQUIC support, and a client is
permitted to fail instead of falling back. HTTPS upstreams are separately
certificate-verified and every upstream connection, including an explicitly
permitted script network request, returns through mihomo's authenticated
`intercept-egress` SOCKS5 listener. The committed generation carries one egress
capability, keyed to the single credential the processor presents, whose
destination-indexed bindings select an operator-bound group when present and
otherwise the terminal operator target declared by the complete mihomo
configuration. The processor never names a group. Unknown sidecar egress hits
the dedicated REJECT terminator. The HTTP/3
client starts with QUIC v1 and retries v2 only after an authenticated version-
negotiation failure, before request data is sent. There is no direct sidecar
egress.

The sidecar `quic_fallback_protection` setting is narrower than
`block-quic-443`: it affects only QUIC already routed to an enabled capture host.
The data-plane capability rejects all public gateway UDP/443 before those host
rules and is the default compatibility guard while reported QUIC behavior is
unreliable.

Installing the private root is necessary but not sufficient for every app.
Certificate pinning, mutual TLS, an independently provisioned ECH configuration,
or a protocol without an HTTP semantic layer remains unsupported and fails
closed. The DNS engine's existing HTTPS/SVCB NODATA behavior prevents ordinary
DNS-discovered ECH on the steered path, but it cannot remove keys provisioned
inside an application.

5gpn accepts only the strict native `5gpn.io/v1` YAML manifest. There is no
third-party client-format parser, compatibility mode, deep-link alias, or
partial-execution acknowledgement. Unknown fields, duplicate keys, multiple
documents, YAML aliases, anchors, and merge keys are rejected. A manifest
declares stable metadata identity and semantic version, explicit capture hosts,
optional public-domain or public-IPv4 upstream mappings, typed settings,
permissions, an optional unrestricted HTTP(S) network grant, an optional
operator-egress-group requirement, optional bounded typed `REJECT`/`DIRECT`
routing rules, and structured request/response script actions. URL install accepts
one HTTPS manifest; local add accepts one pasted or uploaded manifest. A URL
manifest may reference relative HTTPS script resources, while a local manifest
must use inline script source or an absolute HTTPS resource.

The manifest and every referenced script are fetched once through the
subscription-grade HTTPS/redirect/SSRF dial guard, bounded, hashed, and stored
as an immutable local snapshot. Imported extensions always start disabled.
`text`, `select`, `boolean`, `number`, and `location` settings are structurally
validated; all required settings must be complete before enable. A script action
declares request or response phase, capture-host subset, schemes, methods,
path RE2 expression, optional response statuses, body representation, timeout,
and body limit. Its single `transform(context)` entry point receives only the
bounded request/response projection, typed settings, console logging, and—when
explicitly permitted—a quota-bound per-extension storage object and synchronous
network requests. That permission is a single un-parameterised grant. It names
no addresses: a script holding it may reach any host it can resolve, and the
manifest cannot narrow that. The earlier arrangement, an immutable list of exact
approved origins, no longer exists in any component. The guards that remain are
URL canonicalization, rejection of IP literals, unsafe hosts, userinfo and
fragments, and egress through authenticated mihomo SOCKS5 with certificate
verification. The same permission also authorizes a request-phase URL rewrite to
a canonical absolute HTTP(S) URL; HTTPS cannot be downgraded to HTTP, and a
same-origin rewrite remains inside the extension's capture-host boundary while
the request is still at its captured origin. It has no ambient
network client, filesystem, process, timer, socket, or module-loader access. A
permitted script can deliberately send any data visible to it anywhere it can
reach. This is the one permission whose entire purpose is to state where
decrypted data may go, so every management surface must describe it as
unrestricted rather than as a reviewed set of destinations.
A rewritten captured request sends its complete method, decoded body, and
end-to-end headers, potentially including `Cookie` or `Authorization`; framing
and hop-by-hop fields remain runtime-owned. Every management surface states
that risk before enable. Fixed process-wide
network time, body, call-count, and concurrency limits are runtime safety bounds
rather than manifest knobs.

First-party extension source is maintained independently in the public
`moooyo/5gpn-extensions` repository. That repository publishes the strict,
bounded `5gpn.io/marketplace/v1` JSON index at
`https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json`. The core
repository does not vendor, mirror, seed, or release extension manifests or
scripts. Apple WLOC and every other maintained extension follow this external
source boundary and are never compiled into either Go binary.

An authenticated operator may add an explicit HTTPS marketplace index through
the Console or an authorized private-chat Telegram bot session. The daemon
fetches it through the same redirect and post-resolution
SSRF guard as extension resources, strictly rejects unknown or duplicate JSON
fields, applies finite source, entry, URL, string, and response-size limits, and
atomically retains one complete normalized index snapshot. A failed add or
refresh never replaces an older complete snapshot. Marketplace metadata is a
discovery aid, not a trust root: there is no automatic install, enable, update,
crawl, or script mirroring, and the browser never fetches marketplace content
or remote artwork directly.

Selecting an entry is an explicit install. The daemon refetches exactly one
listed HTTPS manifest through the existing native parser, verifies the listed
manifest and script byte sizes and SHA-256 digests plus the derived identity and
capability summary, and only then commits the same disabled immutable local
snapshot used by direct URL install. Any list/source mismatch fails before the
extension document changes. Local add and direct URL install remain available
as separate flows and do not pass through a marketplace.

URL-sourced plugins may be checked for updates only through an explicit,
authenticated action. A check fetches a bounded candidate through the same
HTTPS, redirect, SSRF, strict-schema, and permission guards as install, then shows
its immutable snapshot digest, capabilities, and capture-host set without mutating the
installed snapshot. The snapshot digest covers the plugin source, every fetched
script digest, and the parsed immutable capability shape. Applying an update
requires the installed plugin to remain disabled, refetches the exact reviewed
snapshot digest, atomically replaces the snapshot, and leaves the replacement
disabled. Update checks and applies never auto-enable a plugin or alter the
interception transaction implicitly.

Native `traffic.upstreamMappings` are extension-scoped upstream overrides, not
a second global DNS policy. Their host must be covered by the same extension's
`captureHosts`. The address and alias forms apply only after that host has been
steered through the sidecar, preserve the original HTTP Host and TLS SNI, and
return through mihomo. The resolver form (`server:…`) names nameservers for the
loopback origin resolver instead of a destination, and the sidecar excludes it
everywhere a mapping becomes a dial target. Every form's dialled IPv4 address —
an address target, or each resolver spec's pinned address — is refused if it is
private, loopback, link-local, CGNAT, or otherwise unsafe; an alias is a name,
so that intent cannot be enforced for it. A
manifest may require an operator egress-group binding but cannot name, inspect,
or change the selected group. The management surfaces expose only existing
proxy-group names plus `DIRECT`; the binding is operator state stored outside
the immutable snapshot. Every transformed TCP or UDP flow returns through authenticated
`intercept-egress`, where the generation's egress bindings apply the first
matching bound extension's group. Missing and removed required bindings fail closed
without fallback.

Routing declarations are immutable snapshot capability, while activation is an
operator decision. Install and update always store the snapshot disabled. The
single enable review lists every normalized routing rule together with the
capture, script, storage, network-origin, and egress impact; confirming enable
authorizes the complete snapshot once, without a second routing-only prompt.
Changing execution order is separately confirmed because it can change action
composition, egress winners, and overlapping global `REJECT`/`DIRECT`
first-match results. Disable, MITM-master disable, or uninstall removes the
published rules through the same structurally validated rollback transaction.

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

Enabled extension capture hosts form a separate system overlay before this
operator list. The overlay is empty after a fresh install and is published only
after an explicit extension transaction has prepared the immutable snapshot and
certificate, validated every required operator group, validated and hot-applied
the ordered egress and capture rules, and committed the sidecar state. A
matching name receives the same gateway action and `force-proxy`
observability reason as an explicit proxy-intent rule — deliberately, so
downstream counters treat the two as one thing. `GET /api/resolve-test`
therefore reports the owning extension (id, display name, and the capture
pattern that matched) alongside the unchanged reason, and reports the
operator rule that won in the other case, because the verdict alone cannot
distinguish them. When the MITM master is off the capture table is built but
inert; the diagnostic still names the declaring extension with `ready: false`,
since the extensions page continues to show it as enabled. Disabling a module
removes its overlay and flushes the response cache. This overlay is not a
second general policy language: it accepts only the normalized host patterns
owned by enabled native extensions. DNS policy still cannot select egress; the
separate operator-confirmed extension binding transaction owns that choice.

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

This client-resolution arbitration is separate from mihomo origin
re-resolution. The loopback origin resolver never evaluates ordered DNS policy
or chnroute arbitration: it forces the operator-selected group for an active
extension capture host and otherwise forces trust. It does, however, share the
AAAA stance below: both resolver boundaries answer AAAA with the same synthetic
NODATA, so neither a client nor mihomo can obtain an IPv6 address from 5gpn.

A member of EITHER group declares its transport by spec form: a bare
`IP[:port]` is plain UDP `:53`, `serverName@IP[:port]` is DoT `:853`, and
`https://host/path@IP[:port]` is DoH over a pooled HTTP/2 connection `:443`.
Transport is a per-member property, so one group may mix all three. The address
after `@` is always the dial target, because resolving the member's own
hostname would have to go through this daemon. DoH reuses its connection across
queries, so a query costs one round trip rather than the three a per-query
TCP+TLS handshake costs; both groups' pools are retired on a grace timer after
an upstream hot-swap so in-flight queries finish against the snapshot they
loaded.

A plain-UDP member has no query-name anti-spoof mechanism. The DNS 0x20
encoding that once protected the china group was removed with the group's
transport restriction: it only ever covered plaintext UDP, its startup
self-probe could not evaluate an encrypted member, and a case-normalising
resolver would have made every query through that member fail the echo check
undetectably. An operator who wants an authenticated path to a domestic
resolver configures DoT or DoH instead — which is what the console's upstream
card recommends.

The upstream groups are configured in `upstreams.json` alone — there is no
`dns.env` counterpart. The installer seeds that file with one plain-UDP member
per group (`223.5.5.5:53` for China and `22.22.22.22:53` for trust) and never
overwrites an existing one; the console rewrites it and hot-applies without a
restart. A missing or malformed file falls back to the compiled-in defaults
with a warning rather than refusing to start, because the console that would
repair it is served by this process. The default China ECS subnet is
`112.96.32.0/24`; an operator may override or disable it explicitly.

`22.22.22.22` is a placeholder for a trusted internal resolver on a clean
path, not a public recursive one. A warn-only startup probe resolves a control
name through the trust group and logs when the answer looks fabricated — an
address inside a member's own `/24`, or a private address for a public name —
because the gateway rewrite replaces any non-CN address with `GatewayIP`
before a client sees it, so a trust leg answering nonsense is otherwise
invisible.

Query-type behavior is intentionally IPv4-oriented:

- A follows the ordered policy and fallback above.
- AAAA returns synthetic NODATA with authority information.
- HTTPS and SVCB return synthetic NODATA so address hints or ECH cannot bypass
  A-record steering and hostname sniffing.
- Other types are forwarded through the trust group, with AAAA, HTTPS, and SVCB
  records removed from every section of the reply before it is cached or
  returned. Refusing those two RRsets only when they are the question would
  leave them reachable under another qtype: `ANY` returns both outright, and an
  MX, NS, SRV, or PTR reply carries the target's AAAA as additional-section
  glue. An address, or an ECH key, is just as effective at bypassing steering
  when it arrives in the additional section of some other lookup.

The AAAA rule is not client-only. The loopback origin resolver on
`127.0.0.1:5354` answers AAAA with the same synthetic NODATA before consulting
any upstream group, and it is the boundary that actually keeps egress on IPv4.
mihomo resolves every sniffed origin there and issues the AAAA query
unconditionally: its `dns.ipv6` setting does not suppress that query, only the
top-level `ipv6` key does, and `/etc/5gpn/mihomo/config.yaml` is operator-owned,
so no seed value can be assumed present in a deployed configuration. Were the
AAAA forwarded, mihomo would learn the origin's real IPv6 addresses and race
them against the IPv4 ones; a winning IPv6 leg completes its TCP dial, which
retires mihomo's dual-stack fallback, and a destination that refuses or
mislocates the gateway's datacenter IPv6 prefix then fails at the application
layer with nothing left to fall back to. Answering NODATA leaves mihomo only
IPv4 candidates. The accepted consequence is that an origin — or an operator
proxy node named by hostname — published only as AAAA is unreachable through the
gateway; an IPv6 answer would not have been dialable on an IPv4-only data plane
either.

Rewrites must preserve the upstream Rcode and authority section. In particular,
NXDOMAIN and SERVFAIL must never become NOERROR merely because an answer name
or address is rewritten.

Rule or upstream swaps atomically replace live snapshots and flush response
cache state. A query captures the cache epoch before its rule snapshot; a
query that began under an old generation cannot repopulate the newly flushed
cache after a swap.

Concurrent cache misses with the same canonical name, type, class, DO, and CD
profile share one timeout-bounded upstream resolution. Policy, rule, upstream,
and cache generations are also part of the internal flight identity, so a hot
swap cannot share an old decision with a new request. A canceled waiter stops
waiting without canceling the shared query or recording a breaker failure. The
distinct-key flight map has a fixed capacity; at capacity, unrelated requests
resolve independently under the normal admission and query deadlines.

Subscription refresh is fail-safe. Network, redirect, parse, scan, or
too-small/partial-result failure keeps the last complete cache. URL resolution,
every redirect, and the final dial target are subject to SSRF protections.

A subscription rule declares the parser for its source: `plain`, `gfwlist`,
`dnsmasq`, `hosts`, or `clash`. `clash` reads a Clash rule-provider document —
a YAML mapping with a `payload` sequence — and reduces each entry to a name,
stripping the `+.` and leading-dot suffix markers and the `DOMAIN,`/
`DOMAIN-SUFFIX,` tokens. Every cached entry is loaded as a domain suffix
regardless of format, so a provider's exact-name rule is deliberately widened to
a suffix, and its keyword, IP-CIDR, GEOIP, and process rules carry no name and
are dropped before normalization rather than counted as malformed. Stripping the
markers is load-bearing rather than cosmetic: a hostname may legally contain
`+`, so an unstripped `+.example.com` would pass name validation and be cached
as a literal entry that label-boundary matching can never match — a subscription
that reports a healthy entry count while matching nothing.

Name-based blocking of encrypted-DNS services cannot stop a client that uses a
hard-coded resolver IP and can route around the gateway. The product and UI
must state that limitation rather than implying network-level enforcement.

The seeded encrypted-DNS bypass blocklist is therefore shipped **disabled**. It
is one subscription rule over a list maintained in this repository at
`etc/block-dns-bypass.txt`, plus the two inline keyword rules that a
suffix-only subscription cannot express. Blocking a vendor's HTTPDNS endpoint
does not fail fast: the application spends its own timeout on the rejected call
before falling back to this resolver, and that delay lands ahead of whatever the
user is waiting on. The set is worth enabling when the operator is actually
steering or blocking something an application would otherwise resolve around,
so it is an operator decision rather than an install-time default.

## Mihomo data plane and configuration ownership

`/etc/5gpn/mihomo/config.yaml` is a complete, operator-owned mihomo
configuration. The initial seed provides listeners, hostname sniffing, the
loopback origin resolver boundary, panel routing, anti-loop rules, a fail-closed sidecar
egress terminator, and a `Proxies` group
whose initial choice is `DIRECT`. After publication there is no generated or
daemon-managed region.

There is exactly one exception to that ownership, and it is narrow. The
credentials on the `intercept-egress` listener and the `MODULE-INTERCEPT` proxy
are not the operator's to hold: `/etc/5gpn/intercept/config.json` is the truth
source that renders them, and the reserved blocks carrying them already belong
to the interception manager. When a run reseeds that document, a preserved YAML
keeps the previous pair and the routing check fails closed with
`credential-mismatch`, aborting publication on a host that is otherwise
healthy. An install therefore realigns those four scalars against the truth
source before preserving the file.

The alignment rewrites the exact source positions of those scalars and nothing
else — no re-serialization, so comments, quoting, key order, and every unrelated
byte survive. It refuses rather than guesses whenever it cannot prove the edit
is safe: a non-plain scalar, a parser mark that does not hold the value it
claims, or a credential outside the rendered alphabet all abort the install. An
already-aligned file is detected and left untouched, and a legacy config with no
interception blocks is simply skipped — whether such a config is acceptable is
the routing check's decision, not the alignment's. The result is validated with
`mihomo -t` and published by atomic rename like any other candidate.

The seed also sets the top-level `ipv6: false`, because mihomo's own default for
that key is `true` and an IPv4-only steering gateway must not resolve or dial
IPv6. This is defence in depth for the paths that do not pass through the
loopback origin resolver, such as a proxy node named by hostname. It is
deliberately not a structural invariant: the file is operator-owned and
preserved byte-for-byte, so requiring the key would reject every configuration
published before it existed. The enforcing guard for already-deployed
configurations is the origin resolver's AAAA NODATA.

The public mihomo `:80` listener remains general data-plane ingress for
DNS-steered HTTP traffic; it is not an ACME-only socket. The seed rejects
`console.<base>` requests whose destination port is 80 before the console
`DIRECT` rule, because the console contract is HTTPS-only and no loopback
HTTP backend exists.

New seed listeners use the same-port `console.<base>:443`, `:80`, `:5060`,
`:8080`, and `:8443` hostname targets.
The exact console name in `sniffer.force-domain` is the other half of this
invariant: forced sniffing replaces the provisional name with a successfully
discovered TLS, HTTP, or QUIC hostname. A failed TCP 443 sniff safely falls back
to the public console; the panel protocol/port rules reject unsupported UDP and
non-443 panel fallbacks. This avoids mihomo v1.19.28's target-keyed
sniff-failure cache, where one IP target shared by every connection can suppress
sniffing globally for 600 seconds after repeated malformed traffic. The
`hosts` entry still resolves the console fallback to `127.0.0.1`; no new public
backend is introduced. Structural validation also
rejects hostname-targeted gateway configurations whose source-address or
domain skip lists can preempt the required forced sniff; legacy loopback-target
operator configurations remain accepted and are never rewritten implicitly.

The seed uses `REJECT` for the zashboard deny-by-default rule and every
anti-loop destination guard. Mihomo v1.19.28 implements `REJECT-DROP` by
holding the TCP relay read path for about 60 seconds, so it is not an overload
control and must not be the seed default for public listeners. `REJECT` keeps
the same deny boundary without a failed loopback dial or mihomo's dial retry
path. These actions remain operator-owned: structural validation accepts both
deny actions and normal install operations do not rewrite an existing valid
configuration; explicit reset publishes the safer seed.

Normal install, reinstall, and `configure` operations must validate and
preserve an existing valid file byte-for-byte. They must not silently rewrite
it. Only an explicit reset action, either `mihomo-reset` or the TTY-confirmed
installer command `upgrade-reset-mihomo`, may replace it, and reset must:

1. render a complete candidate outside the live path;
2. validate the candidate with the pinned `mihomo -t`;
3. back up the current file;
4. publish the candidate with an atomic rename.

This ownership rule also applies across release channels. A normal
stable-to-beta upgrade accepts the common persisted JSON schemas and creates
the beta-only interception state separately; a missing marketplace document
continues to mean no configured sources. It does not migrate or patch existing
mihomo YAML. After preserving the file, the
installer uses the daemon's structural parser to check the two overlay anchors
and their placement, the authenticated
`intercept-egress` listener, `MODULE-INTERCEPT` processor node, fail-closed rule, and
credential agreement with the sidecar document. A preserved configuration
carrying no anchors is refused in preflight, while the host is still untouched,
with the instruction to run `5gpn mihomo-reset`: routing has no renderer behind
it, so such a gateway could never enable an extension, and the file is the
operator's to replace rather than the installer's. Reset restores the seed and
discards whatever the operator added to it; `test/overlay/migrate-to-anchored.sh`
is the rule-preserving alternative for a host worth migrating rather than
reseeding. Any other structurally incompatible boundary aborts for the same
reason instead of degrading active traffic silently.

`dns.env` itself has only the current key schema. The retired
`DNS_EGRESS_RESOLVER` key is neither accepted nor ignored. Every pre-v5
deployment, including `0.0.19`, `test-env`, and `kfchost`, requires an
operator-reviewed lockstep rebuild before upgrade. The old v4 control plane must
first retain an active-state recovery copy, then disable the MITM master,
withdraw its owned egress/policy/capture rules, stop the sidecar, and retain a
second clean post-disable routing baseline. A fixed `jq` projection preserves the
listener, both SOCKS credential pairs, TLS paths, upstream proxy, and protocol
booleans while setting version 5, master disabled, and empty modules/order. The
candidate is checked by both verified current binaries: the sidecar validates
the document and `5gpn-dns --check-interception-routing` must report `ready`
against the live clean mihomo file, proving credentials match and no old managed
rules remain. Checked config and `dns.env` candidates are synced and published
with same-directory atomic renames plus pre-commit rollback copies. Deleting v4
and accepting newly randomized credentials would break the preserved mihomo
boundary. Extensions are explicitly re-imported and reviewed. Neither file nor
plugin state is represented as a lossless automatic migration.

The raw console editor follows the same validation and atomic-publication
rules. Required infrastructure invariants cannot be edited away: the plaintext
controller remains disabled, the TLS controller stays on loopback, the shared
zash certificate paths and controller secret remain fixed, and the egress DNS
broker remains loopback. Its upstream choice remains inside `5gpn-dns`; mihomo
must not be pointed directly at one external resolver. GET returns a SHA-256 revision of the original config
bytes; raw PUT and console reset must submit that revision. The daemon compares
it under the shared store lock and again after `mihomo -t`, immediately before
publication, so stale editors and external changes observed before that final
check are rejected with `409`. A manual editor does not honor the daemon's
process-local mutex and can still race the final atomic rename; operators must
coordinate out-of-band writes.

The ingress-module UI is a narrow, one-shot structural editor over this same
complete file, not a second configuration source. It derives state from the
current YAML, accepts only fixed catalog entries, and modifies a module only
when all of its listener and sniffer objects match the canonical shape. Each
write is protected by a revision of the original bytes, validates the complete
candidate, retains the daemon-owned backup at
`/etc/5gpn/.mihomo-config.yaml.bak`, atomically publishes it, and hot-applies it. A
stale revision or partial/custom module shape is rejected. A failed hot apply
restores and reapplies the previous bytes. There is no separate ingress-capability state file,
generated region, startup reconciliation, or daemon-owned YAML fragment; the
result remains fully operator-owned and visible in the raw editor.

The two `RUNTIME-OVERLAY,5gpn,*` anchors and the `runtime-overlay:` block that
resolves them are reserved for the interception manager. Deleting either makes
active extensions degraded and immediately removes their DNS overlay; the
manager withdraws rather than repairs, because it does not write this file. An
anchor left without its runtime block is a configuration mihomo refuses to
parse, so the two are published and restored together or not at all. `5gpn
mihomo-reset` refuses when the live file no longer carries the block, since that
block is the only record of this box's overlay sockets and peer identities and a
reset without it would produce a permanently dead gateway with reset as the
suggested repair.

Interception extensions are managed through the authenticated
`/api/interception/modules` surface. The global master, HTTP/2, and QUIC
fallback settings use authenticated `GET`/`PUT /api/interception/settings` over
the same complete-document revision. The Console and Telegram bot call the same
in-process `InterceptModuleManager`; neither has a private toggle path. Import,
argument update, delete, reorder, operator group binding, operator capture-DNS
binding, and enable/disable
operations carry the SHA-256 revision of the complete sidecar document. Typed
setting updates, including a `location` value supplied through the Console map
editor or Telegram input flow, use that same revision and manager; there is no
plugin-specific settings endpoint.

The Telegram bot is a trusted plugin-management surface only for allowlisted
administrators in private chats. It exposes the same normalized marketplace and
extension state needed to add, refresh, browse, and remove marketplace sources;
install from a marketplace entry or HTTPS manifest URL; import a pasted local
manifest; uninstall, enable, or disable an extension; edit every typed setting;
bind an operator egress group; select China/trust capture DNS; reorder
extensions; and check and apply updates.
It does not gain a separate state store or mutation path. Marketplace operations
use the marketplace manager, while extension operations use the same
`InterceptModuleManager` transactions as the Console. An install or applied
update always finishes disabled; enabling is a separate confirmed operation.

Every Telegram write is a two-step review and confirmation. The review renders
the complete normalized impact relevant to the operation, including the source,
identity, versions, immutable snapshot digest, changed settings, capture hosts,
action match/execution metadata and script digests (but not script bodies),
permissions, the network grant, execution position, egress and capture-DNS
bindings, and enabled/runtime transition. Enable reviews also list every exact normalized
global routing rule. Reorder reviews show the complete before/after order and
state that overlapping routing, egress, and capture-DNS first-match can change.
Long reviews may be split across protected
messages or a protected document, but the confirmation control is sent only
after the complete review. The daemon stores only an opaque, short-lived,
one-use confirmation reference in callback data. Its server-side record is bound
to the allowlisted administrator user ID, the exact private chat ID, the exact
operation payload, and every applicable current-state proof: the complete
sidecar revision and affected extension snapshot digest, or the marketplace
document revision and exact normalized marketplace snapshot digest. Marketplace
installation and extension update additionally bind the exact candidate
extension snapshot digest. Cross-user or cross-chat use, expiry, replay, a
changed revision, or any digest mismatch fails closed and requires a new review.
The normalized marketplace proof covers the local display label, configured and
redirect-final URLs, normalized metadata, entries, and resolved resources; it
excludes only the observation timestamp. Remote index, manifest, and script
digests remain independent publisher data.

When a candidate or installed extension declares the network grant, every review
says so. An enable review additionally states that the script may send any
decrypted request, response, setting, or storage data visible to it to any host
it can reach, and may rewrite a captured request there with its method, decoded
body, and end-to-end headers, including possible cookies or authorization. The
grant carries no destination list, so a review that named one would be
describing a boundary that does not exist. Telegram never compresses this into a generic permission
label or treats an earlier acknowledgement as approval for a changed snapshot.

Telegram supports `location` settings through the client's native location
sharing flow and through explicit longitude, latitude, and accuracy input. The
bot warns before collection that native or manually entered coordinates travel
through Telegram and the Telegram Bot API. The Console remains the richer
editor for city search, a draggable OpenStreetMap point, accuracy visualization,
and direct coordinate fields; Telegram does not embed or proxy that full map.
When Telegram omits horizontal accuracy, the bot records the contract's
conservative 100000-metre maximum rather than inventing precision.

An active-extension, reorder, binding, or master enable/disable transaction
holds the sidecar and mihomo store locks in a fixed order. It validates the
candidate sidecar with the installed
`5gpn-intercept --check-config`, reads the operator's configuration to confirm
the anchors are placed correctly and to extract the terminal `MATCH` target,
verifies every selected group exists, compiles the desired routing into a typed
generation, and preserves the old sidecar bytes for rollback. The operator's
mihomo file is neither rewritten nor reloaded, so a routing change can no longer
perturb the rules in it.

The generation transaction is ordered so that a failure cannot leave capability
without the state it depends on: publish the candidate sidecar document, wait
for the root-owned certificate publisher to acknowledge the exact host-set
digest, hand the sidecar its bundle once its unit is able to start — which it
cannot be until that certificate exists — then read back the live generation,
compile and stage (idempotent, conferring no capability), record a durable
commit intent, and commit with compare-and-swap against both the live generation
and the core configuration revision. The DNS overlay is published last, only
once the generation is effective, because publishing it earlier would steer
clients at a gateway that cannot yet process their traffic.

The compensation is one step, installed before the first publication that can
need it, and it runs only when the overlay reports that the generation provably
did not take. A commit whose response is lost, and a commit that landed before
its bookkeeping failed, both leave the candidate in place: a lost response says
nothing about whether the commit landed, and undoing on that basis would revoke
a generation already serving traffic. Those apply as unresolved rather than
failed, and restart recovery adjudicates them against the core. An
active generation matching neither the base nor the target means a third party
moved it, which is deliberately left for an operator rather than resolved
automatically. The daemon republishes from the sidecar document at every start,
so a core whose generation store was lost is corrected rather than trusted; the
driver short-circuits when the recomputed generation is already live, so a
healthy boot costs one readback.

While that bounded certificate wait is active, a
missing target digest causes the manager to atomically republish the exact same
candidate bytes at a fixed interval. This preserves the revision and content
while retriggering `PathChanged` after an earlier event was coalesced into an
already-running certificate oneshot; the complete wait still fails closed after
15 seconds. The root oneshot's systemd start guard permits 64 starts per 30
seconds, enough for that bounded 500 ms retry window while retaining a finite
rate limit. Disable operations may leave a temporary
certificate SAN superset, but the runtime allowlist rejects disabled hosts.

`/etc/5gpn/intercept/config.json` version 6 preserves installer-owned SOCKS credentials,
loopback addresses, and certificate paths across every API write. It also
stores the MITM master and protocol settings plus immutable native extension,
manifest, script, origin-permission, typed-setting, and capture-host snapshots,
normalized routing-rule declarations, the complete execution-order permutation,
and mutable operator egress-group and capture-DNS bindings. Both request and
response actions
execute top-to-bottom in that order; the same order determines the first egress
binding and first overlapping extension routing rule that wins. A raw mihomo PUT or reset cannot remove a group that is
still referenced by any installed extension, including a disabled one. An
out-of-band missing group makes routing not-ready; reconciliation withdraws the
DNS overlay and never substitutes DIRECT or the terminal group.

The sidecar reloads only a fully valid document after its file identity,
metadata, or content changes and retains the last valid snapshot after an
invalid external replacement. Byte-identical atomic replacements reuse the
compiled snapshot, deterministic invalid documents are negative-cached by file
identity, and transient read errors remain retryable. A running
sidecar exits cleanly when the master turns off. The continuously enabled
`5gpn-intercept-runtime.path` starts the conditioned sidecar when an atomic
configuration replacement turns the master on; `ExecCondition=--check-enabled`
keeps it inactive while the master is off.

New seeds use mihomo's native TLS controller only:

```yaml
external-controller: ""
external-controller-tls: 127.0.0.1:9090
tls:
  certificate: /etc/5gpn/cert/zash/current/fullchain.pem
  private-key: /etc/5gpn/cert/zash/current/privkey.pem
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
| `console.<base>` | Public React SPA, `/ios/ios-dot.mobileconfig`, `/ios/ios-intercept-ca.mobileconfig`, and `/api/*` | SPA assets and profile downloads are public; every API endpoint requires the console bearer token. |
| `zash.<base>` | zashboard | Separate mihomo source-IP allowlist route and a dedicated controller pass-through. |

Mihomo sends public console traffic to `127.0.0.1:443` and allowlisted
zashboard traffic to `127.0.0.2:443`. Non-allowlisted zashboard sources are
rejected before reaching its HTTP server.

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
separate `/proxy/` is the only general controller pass-through. An authenticated
console request mints a short-lived, one-use zashboard handoff URL. The zash
origin consumes it, sets a host-only `Secure`, `HttpOnly`, `SameSite=Strict`
session cookie, and redirects to zashboard with only a fixed non-secret setup
placeholder. Every controller request requires that session; the daemon strips
browser authorization and injects the controller secret server-side. The secret
is never returned by `/api/status` or placed in a URL, referrer, history, DOM, or
localStorage.

Plugin engine logs use an independent credential and transport boundary.
Bearer-authenticated `POST /api/intercept/logs/ticket` mints a 30-second,
one-use credential stored only as a SHA-256 digest. A same-origin, syntactically
valid WebSocket upgrade to `/intercept/logs` consumes it before the daemon
strips the query and browser credentials and proxies HTTP/1.1 over the fixed
Unix socket. The public gate accepts no other path or query. The authenticated
`GET /api/intercept/health` distinguishes an intentionally idle sidecar from a
missing expected runtime and supplies the Sidebar's active-plugin count.

The sidecar publishes script `console.log`/`info`/`warn`/`error`, bounded action
completion, timeout, failure, and configuration lifecycle events into a
1000-entry process-memory ring. At most eight read-only WebSockets may consume
it, new subscribers start at the current tail, and slow readers never block an
action. Script console text and detailed action errors are not copied to
journald or another file. Event URLs omit user information, query strings, and
fragments. The ring disappears on sidecar exit; reconnect resumes with new
events and does not backfill the disconnected interval.

The Telegram bot runs inside `5gpn-dns` and calls the same in-process
`Controller` used by the HTTP API. `/id` provides the caller's numeric user ID;
all status, log, and operator actions require both an authorized user ID and a
private chat. The bot explicitly subscribes to message and callback-query
updates and owns a configured token's long-polling mode rather than exposing a
webhook listener.

The bot is a trusted private-chat operations surface, not a second full console.
Its menu covers status and refresh, DNS diagnosis, recent logs, upstream
visibility, rule reload, confirmed mihomo restart and certificate renewal, iOS
bootstrap, complete marketplace and extension lifecycle management, and a link
to the console. Complex ordered-policy editing, subscriptions, the complete
operator-owned mihomo YAML, and the rich draggable location map stay in the Web
console. Privileged
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
`DNS_BASE_DOMAIN` is the only persisted hostname identity; the daemon and
scripts derive `dot`, `console`, and `zash` names from it.

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
- `upstreams.json` is the sole source of truth for the china/trust upstream
  groups: installer-seeded, control-API-managed, with no `dns.env` counterpart.
  `ecs.json` and `tgbot.json` are control-API-managed runtime overrides.
  `tgbot.json` contains the validated token/admin set, is written
  atomically with mode `0600`, and overrides the `dns.env` bootstrap defaults.
  A present but unreadable/malformed bot override disables the bot fail-closed
  instead of restoring a possibly revoked bootstrap administrator;
- `mihomo/config.yaml` and `mihomo/whitelist.txt` are operator data-plane state.
- `intercept/config.json` is the sidecar runtime document. Its SOCKS credentials
  and fixed paths are installer-owned; native extension installs store bounded
  immutable manifests and scripts, normalized capture hosts, structured action
  matchers, typed settings, the network grant, permissions, upstream
  mappings, normalized typed routing rules, enabled state, explicit execution order, and operator group
  bindings.
  The global MITM master, HTTP/2 negotiation, and QUIC fallback protection live
  in the same document;
- `extension-marketplaces.json` is the operator-managed list of explicitly added
  marketplace URLs and their last complete, bounded index snapshots. The
  Console and the trusted private-chat Telegram bot share this state. It has an
  independent byte revision, so refreshing discovery metadata cannot change a
  sidecar runtime revision. A missing file means no configured marketplaces;
- `/var/lib/5gpn-intercept/store.json` is the size-bounded, sidecar-owned
  persistence backend exposed as `context.storage` only when a native manifest
  explicitly requests `persistentStorage`.
  An existing unreadable, malformed, or structurally invalid store disables
  storage mutations until a later restart can load a valid store; it is never
  replaced with an empty candidate.
  Scripts cannot choose its path. Normal uninstall preserves its independently
  marked state directory with the extension document; purge and decommission
  remove it through the fixed canonical path and ownership marker.

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

- `/etc/5gpn/cert/dot/current` for DoT and iOS profile signing;
- `/etc/5gpn/cert/web/current` for console HTTPS and its public iOS profile download;
- `/etc/5gpn/cert/zash/current` for zashboard HTTPS and the mihomo controller.

Modular interception uses a separate private trust domain. Its root certificate
and signing key live under the independently ownership-marked
`/etc/5gpn/intercept-ca`; no runtime service can read the signing key. The
sidecar receives only a non-CA leaf under `/etc/5gpn/intercept/tls`. Its SAN set
contains only the exact and wildcard `captureHosts` of currently enabled native
extensions. A wildcard SAN is permitted only in the normalized
`*.example.com` shape; an extension cannot request an all-domain or IP
certificate. With no enabled extension the private root remains available but
no runtime leaf or sidecar process is required.
There is exactly one interception root for the entire extension subsystem, not one
root per extension. Adding or removing an extension can change the constrained runtime
leaf SAN set but never creates, rotates, or distributes another root.

`5gpn-intercept-cert.path` watches the atomically replaced extension document and
starts the root-owned, sandboxed `5gpn-intercept-cert.service`. The helper asks
the sidecar binary's minimal duplicate-key-safe certificate-request parser for
one canonical SAN list and digest. This root path never compiles or executes
extension JavaScript. The helper signs a new
397-day leaf, publishes both staged keypair files, then writes the public
`intercept/cert-state` digest that unblocks the extension transaction only after
the pair validates. The sidecar retains its last valid in-memory leaf across a
transient mixed-file reload attempt. The independent, always-enabled
`5gpn-intercept-cert.timer` invokes the same idempotent helper daily for expiry;
it does not depend on the public Certbot timer, lineage availability, or
certificate mode. The root is never rotated implicitly and the sidecar loads a
new leaf on the next handshake without a restart.
`5gpn-intercept.service` also requires and orders itself after the idempotent
certificate oneshot, so an extension document changed while the gateway was off
cannot start the sidecar with a stale SAN set. Its separate runtime path unit
reacts to the same atomic document replacement, while the service condition
prevents a disabled MITM runtime from remaining started.

The root is distributed in a separate, removable, CMS-signed
`/ios/ios-intercept-ca.mobileconfig`. A manually downloaded profile still
requires the operator to enable full SSL trust in iOS. Removing interception
trust does not remove or change the cellular DoT profile. Normal uninstall and
purge preserve the private root for enrolled devices; explicit decommission
removes it through its ownership marker.

Each `current` entry is an atomically replaced relative symlink to a complete,
validated generation containing both `fullchain.pem` and `privkey.pem`. Readers
therefore observe either the old pair or the new pair, never one file from each.

Reinstall must prefer safe reuse over issuance. Before reusing material, it
verifies the configured mode/provenance, validity window, the exact SAN shape
required by that mode, certificate/private-key match, and (for production) a
trusted issuer chain. A pre-existing external lineage without provenance may be
reused read-only only when its exact live/archive paths, authenticator
parameters, absence of persistent per-lineage hooks, validity window, identity,
and key form the strict expected 5gpn fingerprint. The installer records it as
reused but never invokes Certbot to renew, reconfigure, or replace it and never
gains deletion ownership. It installs only the exact-lineage deploy hook so the
external owner's renewal can update the role copies; the public 5gpn renewal
timer remains disabled. Invalid, expiring, partial, or mode-mismatched unowned
lineages fail closed with an operator repair instruction. Provenance records the
selected mode and whether the Certbot lineage was created by 5gpn, reused from
an existing operator lineage, or is currently missing. Cloudflare reuse requires
the apex and wildcard, while HTTP-01 reuse requires the three exact service SANs
and no apex or wildcard. A debug self-signed certificate can never satisfy
production reuse. Debug mode stores its source only below the independently
root-marked `/etc/5gpn/debug-cert` tree, and
repeated debug installs reuse a still-valid matching debug keypair instead of
generating a new one each time. When the canonical lineage is entirely absent,
a valid mode-matching preserved role copy may recover service without issuing a
new certificate; renewal automation stays disabled until the lineage is repaired
or reissued.

Active role-certificate provenance is separate from the root-only retained
Certbot ownership record. Switching an owned production lineage to debug does
not discard the proof needed to return to production or to decommission that
retained lineage safely; external reuse never creates such ownership proof.

Only a missing lineage or provenance-confirmed owned lineage may enter issuance
or forced renewal. Role copies are staged completely before replacement.
Production renewal is scoped to `--cert-name <base>`; a 5gpn timer must not run
an unscoped renewal over every lineage on the host. For an owned lineage, both
the timer and the confirmed Telegram bot action invoke the same mode-aware
renewal helper. It returns without disruption when
the lineage is not due only after validating the Let's Encrypt production
server, authenticator, hook-free scoped renewal config, trusted live chain, and
all three deployed role copies. A stale role copy is repaired through the owned
deploy hook. The helper runs Cloudflare DNS-01 without stopping mihomo, and for
a due HTTP-01 renewal first repeats the `1.1.1.1` A/AAAA gate, then briefly
stops mihomo to release TCP `:80` for Certbot's standalone listener. The helper
restores mihomo after either success or failure. During initial HTTP-01
issuance, failure and signal paths restore an originally active mihomo, while
success keeps it stopped until the new lineage has been validated and all role
certificates, including `zash/current`, have been published. The normal
`full_install` service-start phase then restores the data plane.

Install/configure, the project timer, the bot action, external deploy-hook role
publication, and decommission serialize on one root-owned private certificate
lock. Install/configure/uninstall also hold an outer installer transaction lock.
The public timer and Bot helper acquire that installer gate non-blockingly before
the certificate lock, so they cannot enter the sidecar certificate-lock handoff;
the required sidecar certificate oneshot takes only the certificate lock.
Before inspecting Certbot state, the installer stops the distro
`certbot.timer` and fails if `certbot.service` is already active. An owned 5gpn
lineage may keep that unscoped timer disabled only when no unrelated lineage
depends on it; otherwise installation fails closed. A read-only reused lineage
keeps external renewal ownership, so a successful run restarts the distro timer
it paused. That pause/restart pairing is in-memory and success-path only: a run
that fails partway leaves the distro timer stopped, and uninstall does not
restore it either. Reviving it is then an operator step
(`systemctl enable --now certbot.timer`), which matters because that timer may
renew lineages having nothing to do with 5gpn. After an
installer has published and validated
all certificate state, it briefly releases the certificate lock while systemd
starts the sidecar's required certificate oneshot, then reacquires it before
final endpoint verification. This bounded handoff prevents the oneshot from
deadlocking against its parent installer.

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
proves that 5gpn created the lineage. Reused or unproven external lineages remain
for manual review. If such a preserved Cloudflare lineage still references the
5gpn credential, that credential is preserved so decommissioning cannot break
its future renewal.

## Installer publication and host safety

5gpn has two isolated first-party release channels. Official tags use strict
SemVer `X.Y.Z`, identify commits reachable from `main`, and publish normal
GitHub releases. Beta tags use `X.Y.Z-beta.N`, identify commits reachable from
`beta`, and publish GitHub prereleases that are explicitly ineligible for the
repository's latest-release pointer. `N` is a positive, monotonically
increasing integer for its base version. The publication workflow rejects a tag
whose syntax or branch provenance does not match its channel.

The source and quick-install entrypoints default to the latest official
release. `--beta` is the only beta selector and is an explicit non-interactive
opt-in; it is not accepted from the caller environment, shown in the TUI, or
persisted in `dns.env`. Official discovery accepts only an official tag. Beta
discovery accepts only a published, non-draft GitHub prerelease with a beta tag
and never falls back to the official channel. An unpinned source installer
delegates to the verified installer bundle for the resolved tag before making
deployment changes, so checkout templates cannot be mixed with another
release's binaries. Packaged and installed scripts remain pinned to their
stamped exact tag, including management operations such as `configure`. A
stable package that includes the cross-channel upgrade mechanism also stores
the verified quick installer from its own bundle. When that installed stable
script receives an explicit `--beta`, it delegates the entire invocation to
that resolver instead of combining stable templates with beta artifacts.

Stable-to-beta upgrade has two explicit modes. Normal `--beta` installation
preserves a valid existing mihomo file byte-for-byte and performs the structural
interception-readiness check described above, which refuses a file carrying no
overlay anchors. `--beta upgrade-reset-mihomo` is
available only from a pinned beta bundle, requires an existing installation and
an interactive TTY confirmation, and replaces the complete mihomo file with the
validated current seed inside the same install transaction. It does not merge
operator proxies, providers, groups, or rules. No non-interactive, ordinary
install, reinstall, or `configure` path may select that reset implicitly.

This source behavior is not deployable through the public beta selector until
a new beta prerelease containing it is published. Release documentation and
integration results must distinguish the repository revision under test from
the latest published prerelease. A completed stable-to-beta upgrade establishes
no direct beta-to-stable downgrade contract; restoration uses an
operator-created pre-upgrade snapshot.

An install or reinstall is staged before it mutates the working deployment:

1. validate persisted configuration and prerequisites;
2. download version-pinned release artifacts and verify their published
   checksums;
3. render and validate candidates, including `mihomo -t` where applicable;
4. take any required backups;
5. atomically publish files and units, then restart and probe services.

A failed preflight, download, checksum, certificate, render, or validation
happens before step 5 and therefore leaves the previously runnable binaries,
units, renewal hook, and operator configuration in place. Third-party tools are
prebuilt and version-pinned; no compiler toolchain is installed on the gateway.
Gum bootstrap failure is non-fatal and falls back to plain output.

**The installer does not roll back.** Once publication has begun there is no
compensating action: no snapshot is captured, nothing is restored, and no
service is quarantined. A failure during step 5 leaves the host partially
installed, and the run says so explicitly alongside the phase it died in. The
operator reruns the installer or repairs the host by hand.

This is a deliberate trade. The previous transaction subsystem restored and
verified services on failure, but any single unit it could not put back
escalated into disabling *every* project unit — including ones it had already
restored and probed successfully — which turned a partial failure into a
gateway that was fully down and would not come back at reboot. Removing the
subsystem removes that failure amplification along with roughly 1300 lines of
capture/restore/quarantine machinery. What remains is fail-before-publish: every
preflight, digest, ownership, and `mihomo -t` check still runs, and still
refuses ahead of step 5.

The unwind path is correspondingly small. On any exit the installer reports the
failing phase exactly once, drops its artifact staging directory, and releases
the certificate and install locks; signals are ignored while it does so, so a
disconnect cannot strand a lock. Locks and staging are concurrency and
validation, not recovery, and they stay.

Replacement of the current `5gpn-dns`, `5gpn-intercept`, mihomo, and
certificate-renewal service/timer units is not gated on provenance. These fixed
unit names are the project's own deployment artifacts: installing claims them
outright and uninstalling deletes them. Unit *contents* are pinned by the
repository policy suites against `etc/systemd/`, never by inspecting the
installed file — inspecting it cannot pin what a release ships, it can only
reject a host that has not upgraded yet, which is every host mid-upgrade. An
operator drop-in is not a reason to refuse either: replacing the unit file
leaves drop-ins in place and systemd keeps applying them, which is the supported
way to override anything here. Stop-and-disable failure still blocks deletion of
that unit file.

A systemd template such as `5gpn-journal@.service` is a definition, not a unit:
with no instance there is nothing to start, stop, enable, or report on, and
`systemctl` answers its status queries with an empty string. Any code path that
treats one like an ordinary unit reads "broken" off a name that is working as
designed, so uninstall deletes a template's unit file without gating on a
stop-and-disable it can never pass.

The same rule governs the other fixed 5gpn paths — `/opt/5gpn`, `/etc/5gpn`, the
state root, the management launcher, the polkit rule, the Certbot deploy hook,
and the published static trees. Each still publishes an ownership marker, and
recursive removal still re-verifies it, but *claiming* one is self-healing: an
absent marker, one written by an older release, or one whose value has since
changed all resolve to republishing the current marker and continuing. A marker
names its owner, not its revision. Project roots are claimed as the first action
of both install and uninstall, and the static trees and interception state root
are claimed immediately before removal, so no check is ever reached with a stale
marker. These ownership values therefore carry no revision suffix.

Certificate material is the exception and keeps strict ownership: the
certificate root and role trees, the debug-certificate root, the Certbot lineage
ownership record, and the interception CA root are accepted only on their own
valid marker. There is no migration path for an unmarked one: a populated
certificate root or an unowned interception CA root is refused outright, during
preflight and therefore before anything is published. Adopting a tree whose
shape this release never validated is the one thing that must not happen to
signing key material, and the pre-marker shapes those paths used to accept are
no longer recognised. An operator meeting this refusal backs the tree up and
removes it, or restores the marker, before rerunning.
Because there is no self-healing claim on that path, their marker values are
frozen: changing one strands every existing host. The config-root value is
additionally duplicated in `scripts/cert-renew.sh`,
`scripts/intercept-cert-renew.sh`, and `scripts/renew-hook.sh`, which validate
`/etc/5gpn` independently; the policy suite pins all four together.

Root-owned recursive deletion requires all of the following:

- an absolute canonical path, rejecting symlinks and aliases;
- rejection of empty paths, `/`, and system roots; operator-configurable
  publication paths are additionally rejected if they resolve to a system
  directory or to a project root;
- a target that is a real directory, root-owned and not writable by others;
- for certificate material, a non-symlink 5gpn ownership marker with exact
  expected contents;
- deletion constrained to the validated directory.

The quick-installer source marker follows the same rules. It cannot be supplied
through a symlink, forged by merely placing any file with the marker name, or
used to authorize clearing a pre-existing non-empty directory.

Uninstall removes the resources this installation manages. Certificates,
Certbot lineages, and operator configuration are removed only when proven owned;
the fixed unit, launcher, polkit, hook, and directory paths above are removed
because they are ours by path. It does not modify unrelated third-party
services, binaries, data, `/etc/fstab` entries outside its own marked line,
sysctls, modules, or directories. In particular:

- a pre-existing `/swapfile` is untouched: the managed swapfile lives inside the
  project state root, and only the exact `/etc/fstab` line carrying the 5gpn
  swap marker is removed;
- global Gum and Certbot assets are untouched unless a 5gpn marker proves
  ownership; a preserved Gum binary survives runtime removal;
- `mihomo.service` is a generic unit name and is *not* protected: if the host
  had its own unit at that path, this installation replaced it and uninstall
  deletes it;
- no nftables ruleset or host firewall configuration is modified.

`--purge` can remove additional 5gpn-owned state, but it does not weaken path,
marker, lineage, or ownership checks. Certificate deletion remains separate so
purge cannot accidentally defeat reinstall reuse or remove another domain's
key material.

The repository is pre-release and has one current contract. Persisted config
uses only current key names, versioned JSON files must match the current schema
exactly, and operator commands and Telegram callback data use only their current
forms. The installer and daemon do not contain aliases, migrations, or teardown
for superseded pre-release implementations.

## Runtime hardening and failure boundaries

All three long-running services run as dedicated non-root accounts under hardened systemd units.
Mihomo and `5gpn-dns` receive only `CAP_NET_BIND_SERVICE`; `5gpn-intercept`
receives no capabilities because all of its network sockets use high loopback
ports. Its systemd-owned `/run/5gpn-intercept` directory is mode `0750`, and the
log socket is explicitly mode `0660`; `5gpn-dns` reaches it only through its
existing `gpn-intercept` supplementary group.
`5gpn-dns` and `5gpn-intercept` receive only IPv4 and Unix socket families,
while mihomo additionally needs IPv6 and netlink for its
own direct egress and route lookup. Runtime state owned by `5gpn-dns` is
private to that account. `/etc/5gpn` is a sticky, setgid `root:gpn-dns`
directory: the control plane can atomically replace the files it owns, but it
cannot rename root-owned certificate, ACME, mihomo, or interception roots.
`/etc/5gpn/mihomo` and `/etc/5gpn/intercept` use the same sticky-directory
boundary. Their control-plane documents are owned by `gpn-dns` with the runtime
account as group and mode `0640`, while mihomo-owned cache files remain owned by mihomo and TLS
material remains root-owned. This preserves atomic control-plane publication
without letting one compromised service replace another service's fixed root or
critical file. The daemon's fixed mihomo rollback backup is
`/etc/5gpn/.mihomo-config.yaml.bak`, owned by `gpn-dns`, grouped to `gpn-dns`,
and mode `0640`. It deliberately remains in the outer sticky directory and
never reuses a legacy `/etc/5gpn/mihomo/config.yaml.bak` that mihomo may own.
Writes remain confined to those declared paths. `SAFE_PATHS` grants
mihomo read access only to the zash certificate role and does not broaden
filesystem writes.

The marked `/etc/5gpn/cert` root is `root:root` mode `0751`: runtime accounts
can traverse to their role but cannot list or change the root. Each role and its
generation directory is root-owned, mode `0750`, and grouped only to its reader;
keypair files are root-owned mode `0640`. Root deploy helpers reject symlinked,
hardlinked, special, non-canonical, or metadata-drifted role trees before
publication. The interception CA and runtime TLS roots apply the same
root-owned, single-link validation under their sticky parents.

The `gpn-dns` account is not a member of `systemd-journal` and cannot read the
host journal directly. For an authorized private-chat Bot log request, polkit
allows it to start only `5gpn-journal@5gpn-dns.service` or
`5gpn-journal@mihomo.service`. The root-owned template validates the instance,
exports at most the newest 50 lines and 256 KiB to an atomic, read-only runtime
file, and accepts no caller-selected unit or path. The same root-owned polkit
rule authorizes only two other operations: restarting `mihomo.service` and
starting `5gpn-certbot-renew.service`. The installer ownership-gates,
snapshots, and rolls back that exact rule and exporter together with the other
service units. Any unit drop-in or pre-existing exact journal-export instance
invalidates the ownership fingerprint and aborts before polkit publication.
No long-running runtime-service sandbox can access `/etc/5gpn/acme` or the
interception CA signing key. Only the bounded root certificate oneshot may read
that key, and only the scoped public-certificate renewal helper may read the
Cloudflare Zone:DNS:Edit credential.

Each native HTTP action runs in a fresh goja VM and must define exactly
`transform(context)`. The context contains only the declared phase's bounded
request/response projection, typed settings, console logging, and an optional
quota-bound storage object when the immutable manifest requested that
permission. A declared and operator-confirmed network permission adds
`context.network.request` and the cross-origin request-rewrite capability
described above. Neither is restricted to a declared destination set — the grant
names none — and both are routed through authenticated mihomo SOCKS5. There are no compatibility globals,
ambient `fetch`, filesystem, process, timer, module loader, socket, or ambient
Go object.
Validated JavaScript Programs, typed settings, host/path matchers, and ordered
lookup data belong to one immutable configuration snapshot. They are compiled
once and reclaimed with that snapshot; an executed VM and its heap are never
pooled or reused. Main upstream HTTP/1.1, HTTP/2, and HTTP/3 transports are
reused only within the same monotonically numbered configuration generation.
New generations retire the prior pools, while already accepted requests may
finish against their captured old snapshot. Long-lived transport pools and
inbound UDP associations retain only immutable proxy, host-mapping, network-
target, protocol, and host-authorization projections; they never retain script
Programs, decoded settings, or the complete configuration snapshot. Script
`context.network` keepalive is narrower still: it is reusable only inside one
action and exact origin, and is synchronously closed when that action returns.
Source, request, response, per-action, total-extension, persistent-key, and
persistent-file sizes are bounded. Request and response bodies support omitted,
string, or Uint8Array delivery as declared by `bodyMode`, plus bounded identity,
gzip, deflate, and Brotli decoding. Upstream requests ask for identity encoding;
transformed responses are returned uncompressed with corrected length headers.
When no request action matches, a non-H3 request with a known body length at or
below the same limit streams without materializing the body and preserves its
content coding and late trailers. A known-length, identity-coded H1/H2 request
whose matching request actions all declare `bodyMode: none` may also take a
conditional streaming path. The sidecar reserves body admission before running
those actions because `bodyMode` limits only the input projection and an action
may still create a replacement or synthetic body. Actions retain their exact
order and execute without a body projection. If none rewrites the URL or
replaces the body, their final header projection is applied and the original
body plus late trailers stream upstream; the unused reservation is released
before the round trip. A synthetic response or abort does not materialize or
forward the request body. A replacement body remains replayable and the
original body is boundedly drained, but not materialized, so its late trailers
remain intact.
Every URL rewrite still forwards a complete decoded body unless a prior action
has supplied the final replacement. Unknown-length, chunked, encoded,
H3-replayable, and action-visible request bodies retain the bounded buffering
path. Every replacement and synthetic result body is independently bounded by
the action and process-wide body limits.
Response projections and patches include validated HTTP trailers, and a
permitted synchronous network response exposes its trailers only after the
bounded body has been read. Forbidden framing fields, invalid names, and
control characters fail closed. Unmodified and transformed trailers are
declared and published correctly across HTTP/1.1, HTTP/2, and HTTP/3, including
an H2/H3-to-H1 conversion where upstream trailers were not announced in
advance.
Body-buffering transformation flows are admitted against a process-wide byte
budget, not a stream count. Every matching request action reserves what it may
hold resident before it can produce side effects or a dynamic body, including
for a bodyless request, and releases an unused reservation as soon as
preparation proves that no materialized body is retained. A response rule set
whose members read neither the body nor the trailers takes no reservation at
all and streams. Excess work fails closed with service unavailable instead of
exceeding the sidecar cgroup.

Counting streams instead conflated memory with concurrency: a `bodyMode: none`
action and a maximal buffered response cost the same unit of a capacity of two,
and because the reservation is taken before the action loop and held across the
upstream round trip whenever the buffer is retained, two of them excluded every
other extension in the process.
VM execution has a rule timeout, and regexp2's non-RE2 JavaScript fallback has
an independent 250 ms match limit so catastrophic backtracking cannot evade the
VM interrupt. Validated action path RE2 expressions, active/per-extension/action
host matchers, and execution-order lookup are compiled once per immutable
sidecar configuration snapshot; reload replaces that bounded snapshot and does
not populate a global cache. Script errors fail the transformed request closed.

The control API is disabled when no bearer token is configured; it is never
served unauthenticated. Certificate or TLS identity errors fail closed. A bad
non-security runtime override is logged and ignored in favor of the last valid
or persisted configuration rather than crashing the sole resolver. The
Telegram token/admin override is the deliberate exception: a present but
invalid file disables that remote control path so revoked authority cannot be
restored from stale bootstrap defaults.

The repository contains no Python. The `5gpn-dns` Go module has exactly three
direct dependencies: `github.com/miekg/dns`, `github.com/go-telegram/bot`, and
`gopkg.in/yaml.v3`. The separate `5gpn-intercept` module has exactly seven
direct dependencies: `github.com/quic-go/quic-go` for QUIC v1/v2 and HTTP/3,
`github.com/dop251/goja` for the isolated native extension JavaScript runtime,
`github.com/dlclark/regexp2/v2` solely to impose the explicit
backtracking timeout on goja's fallback expression engine,
`github.com/andybalholm/brotli` for bounded Brotli request/response decoding,
`github.com/itchyny/gojq` for declarative jq actions, and `golang.org/x/net`
plus `github.com/andybalholm/cascadia` for the bounded document model published
proxy-compat bundles need. This count is stated in three places — here,
`AGENTS.md`, and the sidecar's own policy suite — and they disagreed: gojq was
listed as indirect in `go.mod` while `config.go` and `module_jq.go` imported it
directly, so one document said four and another said six for a module that
actually had seven. These architecture
decisions add no gateway toolchain. The YAML
dependency is an explicit security decision: raw
mihomo edits are parsed structurally before invariant validation so decoy keys,
wrong nesting, duplicate keys, and multi-document overrides cannot satisfy the
control-plane boundary. Adding another direct dependency to either module
requires an explicit architecture decision.

## Web console constraints

The console is a React/DaisyUI SPA with the five-theme catalog, `light`
default, and MiSans stack. DaisyUI remains below the zds cascade layer while
direct utility classes can still win. Sidebar active state is CSS-only. Theme
controls live in the top-bar profile menu and Settings appearance.

Scale is tokenized, not hand-written. `styles/theme.css` declares seven type
steps (11/12/13/15/20/28/40px, nothing smaller than 11px), five radius steps
(chip/ctl/card/dialog/pill), five control heights (chip 32, row 36, ctl 40,
field 44, action 48 — `action` is the mobile primary/secondary button, which is
taller than an icon button and was previously written as a bare `h-12`), and
two translucent tints, one for a wash on a filled container and one for an
inset, defined per theme so a dark scheme inverts them rather than washing out.
`styles/scale.test.ts` fails a bare `text-[Npx]` or `rounded-[Npx]` and any
padding, margin or gap that leaves the 4px grid, anywhere in `src/**`; it also
fails a bare control-range height inside `components/ds`, because the
primitives are what every page inherits, while a feature-level `h-12 w-12` is
usually a decorative circle around an icon and no pattern can tell that from a
control. A height that steps down does so at `md`. Pages branch their mobile
layout on `(max-width: 767px)` while Tailwind's `sm` begins at 640px, so a step
written at `sm` returned a control to its desktop size inside a layout that was
still mobile — a 32px chip beside a 44px input in the same row. Card padding
and card gaps follow the same breakpoint and get smaller on a phone, not
larger. Because the steps are named, `lib/cn.ts` must keep teaching
tailwind-merge about them — an unknown `text-<word>` is otherwise classified as
a text colour and silently strips the colour from any class list that sets
both. Touch targets are 44px on mobile, and the two pages whose primary action
is destructive or publishes an edit — policy rules and the mihomo config
editor — pin that action to the bottom of the viewport there, because both sit
above an unbounded scroll. `lib/theme.test.ts` pins each theme-picker swatch to
that theme's own declared primary: the swatch has to be a concrete value
because it is painted inline, so the copy is deliberate and the drift is what
is guarded.

Colour carries one of two meanings and never both. Distinguishing N peer
entities — decisions, plugins, chart series — uses the categorical
`--color-chart-1..5` slots in a fixed, non-rotating assignment, because several
themes give the semantic roles byte-identical values. Semantic roles are for
state only. The five decisions have exactly one wording, the top-level
`decision.*` namespace, shared by the overview, the query log and the resolve
test.

Logs remain virtualized, polling remains single-flight and cancellable, and
mobile uses card rows with a drawer sidebar. `components/ds/LogSurface` owns
the chrome the log pages share — title row, toolbar row, status slot, list,
footer — and one height policy (`logSurfaceHeight`), a viewport-relative band
rather than a row-count product. It has no `paused`, `onClear` or `connected`
prop and never renders a pause control: what pausing does to the data differs
per page, so the surface reserves the slot and nothing more. The list is a
render prop receiving the computed height, because it must stay a direct child
of the card element. Every live view shares one pause control
(`components/ds/LiveToggle`), whose paused label is required to state what
pausing does to the data. The query log deliberately does not adopt the shell —
its toolbar is a separate card, its pause sits in the page header, it has no
clear and its body is a four-way state — and takes only the search control and
the height policy. A settings card reports loading and failure through
`components/ds/CardState`, and shows a skeleton rather than live controls bound
to `undefined`, which is indistinguishable from a value that is genuinely
empty. A disabled control states why it is disabled in persistent text, not a
tooltip a touch screen cannot reach.
Route metadata is centralized in `web/src/app/navigation.ts`. Route search is
available from `md` up and through a globally-registered ⌘K/Ctrl-K palette;
both are the same combobox. The built `web/dist` directory is a release
artifact, not committed source; PWA, initial asset, lazy-route, and font budgets
remain enforced.

The Plugin navigation group owns installed modules, marketplace discovery, and
the dedicated `/plugin-logs` route; Policy Rules belongs to Parse. The plugin
log page is a compact single-card console with a virtualized 32-pixel desktop
stream and virtualized two-line mobile cards. Search, level/plugin filters,
pause, expansion, and clear are browser-local; on mobile the filters live in a
sheet and what is applied comes back as removable chips. Paused, inactive and
disconnected are one banner carrying the highest-priority condition, not three
that can stack. Pause retains an independent
view snapshot while the live 1000-entry ring continues ingesting; clear advances
only a local watermark and never mutates the sidecar ring, and because that is
all it does it offers an undo rather than a confirmation.

The mihomo log page carries the same toolbar: level (a parameter of the
WebSocket upgrade, so changing it reopens the socket), payload search, pause
and clear. Pausing buffers and reports the count; it must not discard.

State an operator cannot see is a defect. Policy rules compare the current list
against a snapshot taken after the last successful apply and carry the pending
count on the header card, not only inside the Apply button. The mihomo config
editor parses the line number out of `mihomo -t` stderr into a jump, shows a
line-level diff while dirty, and keeps reset behind an overflow. The overview
states how fresh its numbers are and turns to an error when polling fails.

Settings may expose the fixed mihomo ingress-capability catalog. The page is
five sections behind a sticky index — appearance, service and certificates,
interception and extensions, ingress and notifications, resolution upstreams —
and the component versions ride in that index rather than in a strip at the
end. Any two-column group uses one breakpoint. A capability toggle is
only a local draft until the operator reviews a capability and exposure warning
and explicitly confirms the apply. The UI must distinguish a bound UDP socket
from supported raw UDP forwarding, show revision/custom-config conflicts, and
state that external firewall policy remains the operator's responsibility. The
catalog includes default-enabled `block-quic-443`; its copy must say that it
rejects gateway UDP/443, forces only capable clients to fall back, does not
close the listener or manage the host firewall, and is distinct from the
MITM-only QUIC fallback control.

Settings also owns the MITM master, HTTP/2, and QUIC fallback controls. They are
revision-protected immediate controls: changing the master requires an explicit
dialog confirmation, while either protocol capability applies immediately once
MITM is enabled. Disabling the master removes the DNS overlay and mihomo
extension-capture rules and stops the sidecar; plugin snapshots stay
stored and subsequent traffic follows the normal operator-owned mihomo rules.
The page must state that QUIC fallback is guaranteed for already matched IETF
QUIC v1/v2 traffic and other variants are not guaranteed.

Within the Web Console, the dedicated `/extensions` route owns installed native
plugins. It shows immutable
manifest/script digests, semantic version, normalized capture hosts, actions,
permissions, the network grant, typed settings, upstream mappings, exact
typed routing rules, explicit execution position, operator egress binding, and
operator capture-DNS binding, and enabled/runtime state. A card separates the
two kinds of thing it carries: capabilities are neutral chips, while a state the
operator has to act on — missing egress group, unfilled settings, master off,
unconfirmed trust — becomes one banner showing only the highest-priority
condition together with the route that resolves it. Typed routing rules render
as matcher → REJECT/DIRECT in every place they appear, never as a stringified
object.

The extensions card and the marketplace card share that language — status
banner, neutral capability chips, one routing-rule renderer — but not their
code, and deliberately so. Their models overlap in fields that do not mean the
same thing: `capture_dns` and a bound `egress_group` exist only after install,
`manifest_digest` and `snapshot_digest` hash different bytes, and
`upstream_mapping_count` exists on both while the marketplace withholds it on
purpose. A normalized card model would make a catalog entry state a resolver
group, an egress binding or a digest match that nothing has established. Do not
merge the two components; keep the language shared and the models apart.

Enabling uses one
review for the complete snapshot. It
lists every global routing rule and, when network permission exists, states that
the grant names no destination and that the plugin can send any decrypted
request, response, setting, or storage data visible to it to any host it can
reach. Reordering opens a separate
before/after review because it changes action, egress, and global routing
precedence. An authenticated,
on-demand detail read exposes the exact stored manifest and script bodies for
review; list responses do not send those potentially large bodies. “Install
from URL” and “Add locally” are separate dialogs with no source-mode switch.
The former accepts one HTTPS native manifest; the latter accepts pasted or
uploaded YAML. Invalid native manifests fail installation rather than entering a
compatibility mode. Required settings must be complete before enable. Enable,
disable, delete, reorder, binding, settings, and update changes use revision
checks and explicit confirmation. Required missing or removed group bindings
render the plugin not-ready and cannot silently fall back. A `location` setting uses the shared map point picker with
explicit city search, draggable point, accuracy, and direct coordinate fields.
The same picker is offered over `text` or `number` settings keyed exactly
`longitude` and `latitude`, with an optional `accuracy`, because a published
proxy-compat bundle reads a coordinate as three flat arguments and a `location`
value would reach it nested under one key. That form writes the three keys
rather than a location object, so what the script receives is unchanged.
City search calls bearer-protected `GET /api/geocode/cities`; the daemon sends
only the bounded query and language to the fixed Nominatim origin through the
same post-resolution SSRF dial guard used by subscription fetches. It never
forwards the bearer token, arbitrary headers, or an operator-selected URL.

Within the Web Console, the top-level `/marketplace` route owns browser-based
extension discovery. It loads only
authenticated, daemon-validated cached indexes, exposes source filters, local
search and truthful sorting, and supports adding, refreshing, and removing
explicit sources. An operator may assign a bounded local display name; that
alias never replaces or authenticates the marketplace metadata identity. Each
entry shows bounded descriptive metadata, declared capability counts, license,
source domain, manifest digest, and the required routing-rule count. A card
carries three install-decision facts plus one expandable permission count;
tags do not compete for that space. When an entry is installed at a different
version than the source now offers, the card states both versions and offers
the update, which routes to the extensions page's existing reviewed snapshot
replacement rather than performing one itself — comparing two versions already
in hand is not invented metadata, but installing without review would be.
Refreshing several sources settles every one and reports how many succeeded
instead of aborting at the first failure. Selecting Install first confirms the cached
scope, then the daemon refetches and verifies the exact manifest and scripts;
success ends in review of the actual disabled immutable snapshot. Remote images,
browser-side marketplace fetches, invented popularity/author claims, and
automatic installation or enablement are forbidden.

The project extension repository remains external and is never automatically
installed or mirrored. The Setup Guide owns the one shared
interception-root QR code, download link, installation steps, and iOS manual
full-trust instructions. It asks which device it is guiding and expands only
that branch, remembering the answer per browser. The CA card shares the MITM
`enabled` condition with the warning banner above it: with the master off it
collapses to one row plus the switch that would make it relevant. The
locally-stored trust acknowledgement is marked as a record this browser wrote,
visually distinct from the server-side master state beside it. It states that
trust applies to every plugin while
decryption remains limited to enabled capture hosts and requires explicit device
authorization.

`/extensions/hosts` is the authenticated capture-host audit view. It groups
every declared host pattern by plugin, distinguishes running/configured/disabled
state using the global master plus `active_capture_hosts`, highlights exact duplicate
declarations, shows action order and the first effective egress winner for a
duplicate host, shows the first effective capture-DNS winner and its
China/trust binding, and supports local search and filtering. Modern Android Private
DNS remains supported, but the Setup Guide does not offer Android MITM CA
installation because modern Android applications generally reject user CAs.

## Verification boundary

Changes are tested in proportion to their surface. The complete local gates
are the repository shell tests, formatting/vet/race tests for both Go modules, Web typecheck and
Vitest/build/bundle checks, and Playwright tests. CI also renders the anchored
mihomo seed and validates it with the digest-pinned mihomo version, which is the
gate proving that the shipped core parses the overlay anchors. The separate
extensions repository deterministically generates its marketplace index and
passes both that index and every maintained manifest to the current core
`beta` parser tests, so either side rejects a contract drift. Real gateway
behavior is accepted with `tests/integration-smoke.md`.
