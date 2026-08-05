# 5gpn current architecture

This document is the normative description of the current 5gpn system. Design
proposals and archived migration notes are not sources of current behavior.

The project is pre-release. There is no compatibility obligation to anything
described in earlier revisions of this file.

## System boundary

5gpn is an IPv4 DNS-steering gateway. It has **one long-running process**.

- **mihomo** (the `moooyo/mihomo` fork) is the entire runtime: the DNS decision
  engine, the interception/plugin engine, the forwarding data plane, the
  Telegram control plane, and the control API.
- **zashboard** is the only user interface. It is a static bundle mihomo serves
  and an API client that talks to mihomo's controller.
- **This repository** is an installer and a TUI. It contains no service.

Two root oneshots survive, and only because they hold key material a
network-facing process must not:

- `5gpn-intercept-cert.service` owns the interception CA and mints the leaf
  whose SAN set covers the enabled capture hosts.
- `5gpn-certbot-renew.service` owns the Let's Encrypt lineage for the public
  service names.

The DNS answer determines whether a client connects directly to an origin or
connects to the gateway. When the gateway address is returned, mihomo sniffs the
original hostname and owns every subsequent egress choice. DNS policy does not
choose a mihomo node, proxy group, selector, or transport.

```text
client
  | DoT :853
  v
mihomo ─┬─ 5gpn/dns      ordered policy, deterministic CN arbitration
        │                   |                        |
        │   real origin address                gateway address
        │       v                                    v
        │  client connects direct          5gpn capture hook, after the sniffer
        │                                   and before rule resolution
        │                                            |
        ├─ 5gpn/engine   goja scripts, MITM TLS/H1/H2 ─┘
        │       |
        │       | 5gpn/dial -> the same rule evaluation any connection gets
        v       v
     tunnel / proxies / rules ──> operator-defined egress
```

This is not a host router or VPN. The project does not install or manage TUN,
TProxy, WireGuard, fwmarks, policy-routing tables, NAT, or a host firewall.

## Why one process

The three-artifact design (a DNS daemon, an interception sidecar, and mihomo)
required roughly fourteen thousand lines whose entire purpose was letting two
processes agree on what the other was serving: a generation store, a two-key
compare-and-swap, a lease registry with per-boot fencing tokens, a commit-intent
journal, roll-forward recovery, quarantine and draining states, two
`SO_PEERCRED` control sockets, a wire schema duplicated on each side of them,
and two authenticated loopback SOCKS5 hops per intercepted connection.

In one address space that coordination is a field read. What replaced all of it
is `5gpn/state`: a file written atomically, a pointer swapped atomically, and a
content hash so two browser tabs cannot silently overwrite each other.

The cost is a shared failure domain. Expected extension failures do not consume
that boundary: JavaScript exceptions, timeouts, denied network calls, and
invalid configuration writes fail their current action or request. A panic that
escapes that containment, a critical DNS listener that ends, or another
unrecoverable runtime invariant terminates the process instead of leaving a
partially live gateway. The deleted coordination machinery was not buying fault
isolation anyway — it was buying agreement between processes that no longer
exist.

### Failure and process recovery

systemd is the only process supervisor. The shipped `5gpn-mihomo.service` runs
`/opt/5gpn/bin/5gpn-mihomo` as the sole managed Unix user and group, `fivegpn`.
All external product names remain `5gpn`; the spelled-out Unix identity is the
only exception because portable Linux/POSIX account names cannot begin with a
digit.
It uses
`Restart=always` with a three-second delay, so both a non-zero crash and an
unexpected clean return replace the entire runtime from its atomically
persisted state. Ten starts within 60 seconds hit systemd's start limit and
leave the unit failed; `StartLimitAction=none` guarantees the limit never
reboots or powers off the host. A
deliberate `systemctl stop 5gpn-mihomo` is an operator action and is not
restarted; `systemctl start 5gpn-mihomo` is then required.

This is crash recovery, not self-healing. It does not rewrite a bad operator
configuration, free a conflicting port, repair certificate files, or detect a
process that remains alive but cannot make progress. A deterministic startup
failure eventually leaves the unit failed at the start limit. Availability
monitoring therefore belongs outside this process and host, using active DoT
and HTTPS probes rather than an in-process heartbeat.

## Listeners

| Listener | Purpose |
| --- | --- |
| `:853/tcp` | The only client DNS ingress, DNS over TLS. |
| `127.0.0.1:5354/udp` and `/tcp` | The origin boundary. mihomo's own resolver queries it after the sniffer recovers a hostname, and it answers a different question from the client listener — see below. Loopback is enforced at bind. |
| `127.0.0.1:5353/udp` | Local debugging only. The bind is refused if it is not loopback: it answers the same policy without TLS or client identity, which on a public address is an open resolver. |
| `127.0.0.1:443/tcp` | TLS-only external controller. Serves the Clash-compatible API, the `/5gpn/*` routes, `/capabilities`, and the zashboard bundle at `/ui/` — so the panel is `https://console.<base>/ui/`. Loopback, on :443, because that is the port a browser reaching the console name arrives on: the name resolves to `127.0.0.1` through the seed's `hosts` block, so the allow rule's DIRECT dial lands here, on this same process through a different listener. |
| configured gateway addresses | HTTP/TLS ingress for traffic steered to the gateway, sniffed for Host or SNI. |

There is no public DoH listener and no client-facing plain DNS listener on `:53`.
There is no separate console origin, no separate panel origin, and no interception
SOCKS5 listener. All three were deleted with the processes that needed them.
The panel is the console: one name, one listener, one certificate role.

That origin is not source-restricted. It answers any client that can reach this
gateway on `:443` and resolve the console name, and the bearer secret is the
only credential in front of the control API — `/ui/` is deliberately outside it,
because an unenrolled phone fetching its profile holds no token. The source
allowlist that used to sit on this rule was removed by owner decision; mihomo's
controller has no source-IP facility of its own (only the secret and CORS), so
the rule engine was the only place such a restriction could live, and nothing
replaced it. What remains on the rule is the `IN-TYPE,INNER` exclusion, which is
load-bearing for a different reason: the engine dials every captured upstream
back through these same rules, so without it an extension running
operator-supplied JavaScript could name the console and reach the management
plane.

### Why the origin boundary is a socket

A client asks "where should I connect", and the answer may be this gateway.
mihomo asks "where does this name actually live", and answering *that* with the
gateway address would point the box at itself. So the origin listener carries no
ordered policy, no CN arbitration and no gateway rewrite — not as a setting, but
by construction. What it does own is the operator's china/trust binding for a
captured host, and the synthetic NODATA that keeps egress on IPv4: mihomo issues
the AAAA query unconditionally, and an answered one is raced against the v4
addresses, where a winning v6 leg retires the dual-stack fallback and leaves
nothing behind it.

It is a socket rather than a function call because mihomo reaches its resolver
through package-level globals that `hub/executor.updateDNS` reassigns on every
`ApplyConfig`. A loopback nameserver named in the operator's own configuration
survives a reload; anything else would need an edit to an upstream-owned file,
which is the one cost this fork is organised to avoid.

Both boundaries share one cache, keyed so they can never share an answer.

## Authentication

Exactly one credential: mihomo's controller secret, presented as
`Authorization: Bearer` or as `?token=` on a WebSocket upgrade.

The 5gpn bearer token, the one-use log tickets, the zashboard handoff URL, the
`__Host-5gpn-zash` session cookie and the two-origin `127.0.0.1`/`127.0.0.2`
split are all deleted. `/5gpn/*` registers through `hub/route.Register`, which
mounts inside the group that already applies `authentication(secret)`, so a
client that can reach `/configs` can reach these and one that cannot, cannot.

`/ui/*` is mounted outside that group. That is deliberate and is the only
unauthenticated surface: an unenrolled phone downloading a `.mobileconfig`
trusts nothing yet and holds no secret.

The controller assigns `.mobileconfig` responses the explicit media type
`application/x-apple-aspen-config`; serving profiles must not depend on the
host distribution's MIME database. The installer never edits a shared MIME
table. Its readiness probe bypasses proxy environment variables and requires
both public profiles to return HTTP 200 with that exact media type, comparing
the type case-insensitively and allowing parameters.

## Control surface

`/capabilities` reports which subsystems are actually installed, with a schema
version each. A client that does not understand exactly that version treats the
feature as absent rather than rendering it — field meanings may have moved, and
showing an operator a status that might be wrong is worse than showing nothing.
A subsystem whose document failed to load does not advertise itself, so an
absent panel and an empty one mean different things.

`/5gpn/dns` is read and written whole. The edits are not independent: moving a
gateway to a new address and changing the upstreams that serve it is one
decision, and there is no useful state between the two halves of it.
The listener addresses and certificate paths inside that document are
installation-owned and read-only through this API. A whole-document client
must round-trip them unchanged. Listener changes require a checked installer
operation; rejecting them before the durable write prevents a port conflict
from becoming a persistent systemd restart loop.

`/5gpn/interception` is the opposite, and for the same reason. Enabling an
extension authorizes a capture set, a script set, a storage grant and possibly
an unrestricted network grant; reordering decides which of two extensions owns
an overlapping host, and therefore which script acts on it, which egress binding
wins and which resolver group looks up its origin. A single endpoint taking the
whole document would make those indistinguishable from renaming something, and
the confirmation an operator gave would not correspond to any particular
decision. So each is its own write.

Every write quotes the revision it was read at and is refused with `409` if it
has moved, carrying the current revision back so a client can re-read rather
than being told only that it lost.

Install and update are two calls, joined by a digest. The digest covers the
manifest bytes, every script that will run, and the immutable capability shape —
and deliberately not the operator's bindings or entered settings, which would
make it change whenever they edited a field and stop meaning "this is what you
reviewed". The install re-fetches and compares rather than committing the
candidate it already holds, which is what makes the digest a check on the
publisher rather than on our own bookkeeping.

`/5gpn/interception/catalog` is discovery and nothing else. A catalog is a list
of manifests: it is fetched through the same guarded client an import uses, it
is never persisted, and installing from an entry runs exactly the
review-then-confirm path a pasted URL runs. It is deliberately not an update
source — `CheckUpdate` re-reads the URL an extension was installed from, never an
entry that happens to share its id, or adding a catalog would silently change
where an operator's code comes from.

What a catalog is allowed to do is contradict itself, and that is checked. An
entry states the manifest's SHA-256 and the shape of what it declares; if the
fetched manifest disagrees, the review is refused rather than returned with a
footnote, because the review is the screen where the operator decides and a
wrong description reaching it is the whole failure. The index is decoded
leniently: it is a contract with every deployed gateway, so rejecting unknown
fields would make older cores refuse whole catalogs whenever a publisher added
something for newer ones.

`/5gpn/bot` is one read and one write, whole-document rather than a write per
field. The interception routes are split because each authorizes something
different; here there is a single question — who may ask this gateway things
over Telegram — and splitting it would allow a gateway with a token and no
admins, or admins and no token. The token is write-only in both directions: no
read returns it, and an empty write keeps the stored one, so a console edits the
admin list having never held it.

## Capture

Interception is a hook in `tunnel/tunnel.go`, three lines, placed after the
sniffer has filled `metadata.Host` and before `resolveMetadata` selects an
outbound. That window is the only point at which the destination is known and
nothing has been read off the connection, so the buffered ClientHello is still
available to the TLS server that receives it.

`captureTCPFor` refuses `Type == INNER`. The engine reaches its upstreams by
dialing back through the same tunnel, which arrives as an inner connection;
capturing those would feed the engine its own output indefinitely.

An engine upstream is dialed through `inner.HandleTcp`, mihomo's existing
mechanism for "the core needs to dial something and wants its own rules
applied". An intercepted upstream therefore cannot diverge from an ordinary
client connection: same rules, same outbound selection, same row in the
connection table.

### Datagrams and HTTP/3

The interception engine does not consume datagrams. HTTP/3 interception is an
explicitly unsupported capability: the persisted setting remains present as
`mitm.http3`, but configuration validation requires it to be `false` and every
management write attempting `true` is rejected without changing the revision.

Fresh and explicitly reset seeds contain exactly one fixed global rule:

```text
AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
```

The tunnel evaluates this guard before extension routing rules and before TCP
capture. The controller rule-management API refuses attempts to disable it. The complete
mihomo YAML remains operator-owned, so an operator can still edit it manually;
removing or disabling the guard withdraws the fixed client boundary and makes
extension interception fail closed rather than enabling HTTP/3 capture.

A client that supports protocol fallback can retry over TCP, where plain HTTP
or TLS/H1/H2 follows the ordinary capture path. An H3-only client fails. The
guard affects only UDP destination port 443 that reaches the gateway: it is not
a firewall, does not affect traffic that bypasses the gateway, and does not
disable ordinary UDP forwarding or QUIC sniffing on other configured ports such
as the optional `:5060` ingress.

## The Telegram control plane

`5gpn/bot` is one goroutine, off unless configured. It reads and it alerts. It
cannot enable an extension, install one, edit policy, restart a service or touch
the interception CA — zashboard owns extension management, and a second surface
for authorizing what may decrypt traffic would be a second place for the
operator's confirmation to mean something slightly different.

The narrowness is enforced by construction rather than by review: `5gpn/bot`
cannot import the resolver or the engine, and reaches both through a `Facts`
struct of read functions the façade assembles. Widening what a command can do
requires widening that struct.

Alerts are transitions, never states, and the bot does not claim to detect the
gateway's own death: a monitor inside the process cannot report that the process
stopped, and an operator who read silence as health would be worse off than one
who knows it means nothing. The persisted `DNS_HEARTBEAT_URL` and
`DNS_HEARTBEAT_INTERVAL` fields are not consumed by the monolith and provide no
health signal. An independent monitor must actively probe the gateway from
outside the host.

Egress goes through the core's own inner dialer, so reaching `api.telegram.org`
from a network that blocks it is the operator's existing rules rather than a
private proxy knob.

## Code layout and the fork budget

All 5gpn code lives under `5gpn/` in the mihomo fork, a directory upstream never
touches. The façade package is named `fivegpn`, because Go identifiers cannot
begin with a digit. Upstream packages may import `5gpn`; they may not import
anything beneath it. `5gpn/importrule_test.go` enforces this by walking
`go list`.

The rule exists because the fork's cost is not the size of `5gpn/` — it is how
many upstream-owned files carry a 5gpn-shaped change, since those are what a
rebase must reconcile. All 5gpn-specific upstream edits remain concentrated in
two files: `tunnel/tunnel.go` owns the capture and reviewed-routing hooks, while
`hub/hub.go` starts the subsystems and propagates critical startup failure.
Runtime authorization and fail-fast startup made the former twelve-line count
obsolete; keep the file boundary rather than preserving a misleading fixed
line budget. The supporting bookkeeping remains in fork-owned files.

Two other categories of change exist against upstream and are deliberately not
counted, because counting them would make the number mean something else.
`go.mod` and `go.sum` conflict on every rebase, but resolving them is mechanical
and needs no knowledge of 5gpn. And the fork inherits changes to
`component/sniffer/` and `listener/socks/` from the branch it grew out of;
those are general improvements to mihomo rather than 5gpn-shaped, and the right
destination for them is upstream.

There is one ordering constraint on the façade: `hub/route` imports
`hub/executor`, so `fivegpn` cannot be called from `hub/executor` without an import
cycle. It is started from `hub/hub.go`.

Absorbing the script engine raises the module's go directive to 1.25, which
drops the sub-1.25 rows of the upstream build matrix — every legacy Windows and
macOS target. For a Linux gateway that costs nothing. It also arms vet's
non-constant-format-string check against upstream files: those are not fixed,
because every edit there is rebase surface. CI runs `go vet ./5gpn/...` and
`go build ./...`.

## State

`5gpn/state` holds every 5gpn document under the mihomo home directory. The
installed path is `/etc/5gpn/mihomo/5gpn`; `gpn` is retained only as the exact
legacy source name recognized by the one-time installer migration. Writes
are temp-file, fsync, rename, fsync-directory; the in-memory pointer is
published only after the rename, so a reader can never observe a value a crash
would un-observe. A document that fails to parse refuses to open rather than
resetting to defaults, which would discard the operator's extensions and policy
without saying so.

Updates carry the revision they were read at and are refused with
`ErrRevisionConflict` if it has moved. This is the only concurrency control in
the system and it exists for one reason: two operators with the same page open
in two tabs.

There are three documents. `dns.json` is the resolver: listeners, gateway
address, the two upstream groups and their client subnet, the ordered policy,
and the handful of knobs with no correct universal value. `intercept.json` is
the interception engine: the master switch, the protocol settings, the
configured extension catalogs, and the installed extensions with their immutable
snapshots and the operator's own bindings. `bot.json` is the Telegram control
plane: the switch, the token, the admin set and whether alerts are on.

The bot is its own document rather than a field on either of the others,
because it is neither: the resolver document is what the gateway answers with
and the interception document is what may decrypt. Putting a chat credential in
either would widen what a write to those means.

A fetched catalog index is not in any of them. It is refetchable by definition,
and persisting one would let a stale listing outlive the process that fetched
it — which is what the previous design's salvage, unusable and raw-passthrough
machinery existed to survive.

`intercept.json` retains an `http3` field so the API shape is explicit, but the
only valid value is `false`; it is not a feature toggle. HTTP/2 remains the only
optional intercepted HTTP protocol above H1.

`dns.json` replaced four files — `policy.json`, `upstreams.json`, `ecs.json` and
the DNS-shaped half of an environment file that systemd read and the runtime
could not write. Splitting them made every cross-cutting edit two writes with no
way to name the pair: moving a gateway to a new address and changing the
upstreams that serve it left a window in which the resolver was configured as
neither. It also put the one file the console most needed to repair out of its
reach.

`config.yaml` remains fully operator-owned.

## Upgrading an existing gateway

A legacy three-process gateway may carry configuration the monolith cannot
parse: two retired `RUNTIME-OVERLAY,5gpn,*` anchors and an
`IN-NAME,intercept-egress,REJECT` terminator. The core fails `5gpn-mihomo -t` rather
than starting with capture silently absent.

`scripts/migrate-to-monolith.sh` removes those three rules. It does not strip
the `NOT,((IN-NAME,intercept-egress))` qualifiers on the two panel allow rules;
it rewrites them to `NOT,((IN-TYPE,INNER))`. The qualifier looks vacuous once
the listener is gone — nothing can arrive on an inbound that does not exist —
but the rule was never about the listener. It kept extension-borne traffic off
the gateway's own management plane, and the engine still produces such traffic:
every upstream it opens goes back through these same rules by inner dialling,
which is what keeps intercepted traffic inside the operator's routing. That
traffic arrives as `INNER`, with no inbound name. Stripping the qualifier would
therefore let a captured extension naming the console reach it — so migrated
hosts get the same predicate a fresh install seeds.

The legacy `intercept-egress` listener and `MODULE-INTERCEPT` node are unused by
the monolith but harmless, so they are cleanup rather than migration.

The units are handled the same way, and the asymmetry is deliberate: the
installer publishes only the units this release owns, but keeps removing the
ones it used to. An orphaned `5gpn-dns.service` on an upgraded host would keep
restarting against a binary that is gone — or keep `:853` bound against the one
that is not. The list of retired units is therefore the only record that they
were ever ours, and dropping an entry from it strands whatever it names on every
host that has not upgraded yet.

The final naming transition is similarly exact. The current runtime is
`5gpn-mihomo.service`, executes `/opt/5gpn/bin/5gpn-mihomo`, and runs as the
single `fivegpn:fivegpn` identity. An old-only
`/etc/5gpn/mihomo/gpn` directory is renamed on the same filesystem to
`/etc/5gpn/mihomo/5gpn`; two populated directories fail before either is
changed. The generic `mihomo.service` and old `mihomo`, `gpn-dns`,
`gpn-intercept`, and overlay-group identities are removed only with project
provenance and an exact, idle, numerically exclusive system identity. An owned
legacy unit or state tree is provenance; so is the closed shape of the
project-specific `gpn-dns` or `gpn-intercept` account. The generic `mihomo`
identity additionally requires its owned unit/state evidence or membership in
the retired `5gpn-overlay-*` groups. An incompatible current `fivegpn` account
is different: that name is installer-owned, so exclusive numeric IDs are
retained while the account is recreated non-interactively. Aliased IDs fail
closed.

## Verification boundary

Changes are tested in proportion to their surface. `go build ./...` and
`go test -race ./5gpn/...` must be green. `tests/` holds the installer suites,
which are shell and must be run under Linux against an LF checkout.

A real gateway is reachable as `test-env` over OpenSSH. Because it is a working
gateway, configuration changes are validated against copies rather than in
place.
