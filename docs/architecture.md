# 5gpn current architecture

This document is the normative description of the current 5gpn system. Design
proposals and archived migration notes are not sources of current behavior.

The project is pre-release. There is no compatibility obligation to anything
described in earlier revisions of this file.

## System boundary

5gpn is an IPv4 DNS-steering gateway. It has **one long-running process**.

- **mihomo** (the `moooyo/mihomo` fork) is the entire runtime: the DNS decision
  engine, the interception/plugin engine, the forwarding data plane, and the
  control API.
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
mihomo ─┬─ gpn/dns      ordered policy, deterministic CN arbitration
        │                   |                        |
        │   real origin address                gateway address
        │       v                                    v
        │  client connects direct          gpn capture hook, after the sniffer
        │                                   and before rule resolution
        │                                            |
        ├─ gpn/engine   goja scripts, MITM TLS/H1/H2 ─┘
        │       |
        │       | gpn/dial -> the same rule evaluation any connection gets
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
is `gpn/state`: a file written atomically, a pointer swapped atomically, and a
content hash so two browser tabs cannot silently overwrite each other.

The cost is a shared failure domain. A panic in the script engine takes the
gateway's DNS and forwarding with it. This is an accepted trade: a user who
installs a third-party plugin is responsible for that choice, and the
coordination machinery was not buying isolation anyway — it was buying agreement
between processes that no longer exist.

## Listeners

| Listener | Purpose |
| --- | --- |
| `:853/tcp` | The only client DNS ingress, DNS over TLS. |
| `127.0.0.1:5354/udp` and `/tcp` | The origin boundary. mihomo's own resolver queries it after the sniffer recovers a hostname, and it answers a different question from the client listener — see below. Loopback is enforced at bind. |
| `127.0.0.1:5353/udp` | Local debugging only. The bind is refused if it is not loopback: it answers the same policy without TLS or client identity, which on a public address is an open resolver. |
| `127.0.0.1:9090/tcp` | TLS-only external controller. Serves the Clash-compatible API, the `/gpn/*` routes, `/capabilities`, and the zashboard bundle at `/ui/`. |
| configured gateway addresses | HTTP/TLS ingress for traffic steered to the gateway, sniffed for Host or SNI. |

There is no public DoH listener and no client-facing plain DNS listener on `:53`.
There is no separate console origin, no zashboard origin, and no interception
SOCKS5 listener. All three were deleted with the processes that needed them.

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
split are all deleted. `/gpn/*` registers through `hub/route.Register`, which
mounts inside the group that already applies `authentication(secret)`, so a
client that can reach `/configs` can reach these and one that cannot, cannot.

`/ui/*` is mounted outside that group. That is deliberate and is the only
unauthenticated surface: an unenrolled phone downloading a `.mobileconfig`
trusts nothing yet and holds no secret.

## Control surface

`/capabilities` reports which subsystems are actually installed, with a schema
version each. A client that does not understand exactly that version treats the
feature as absent rather than rendering it — field meanings may have moved, and
showing an operator a status that might be wrong is worse than showing nothing.
A subsystem whose document failed to load does not advertise itself, so an
absent panel and an empty one mean different things.

`/gpn/dns` is read and written whole. The edits are not independent: moving a
gateway to a new address and changing the upstreams that serve it is one
decision, and there is no useful state between the two halves of it.

`/gpn/interception` is the opposite, and for the same reason. Enabling an
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

UDP/QUIC capture is not wired. `MatchUDP` reports false and gateway QUIC is
handled by the fixed `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` capability,
which makes a capable client retry over TCP.

## Code layout and the fork budget

All 5gpn code lives under `gpn/` in the mihomo fork, a directory upstream never
touches. Upstream packages may import `gpn`; they may not import anything
beneath it. `gpn/importrule_test.go` enforces this by walking `go list`.

The rule exists because the fork's cost is not the size of `gpn/` — it is how
many upstream-owned files carry a 5gpn-shaped change, since those are what a
rebase must reconcile. That number is **two files, eight lines**: the capture
hook in `tunnel/tunnel.go` (seven) and the one call that starts the subsystems
in `hub/hub.go` (one). Everything else 5gpn adds is a new file, which does not
conflict.

Two other categories of change exist against upstream and are deliberately not
counted, because counting them would make the number mean something else.
`go.mod` and `go.sum` conflict on every rebase, but resolving them is mechanical
and needs no knowledge of 5gpn. And the fork inherits changes to
`component/sniffer/` and `listener/socks/` from the branch it grew out of;
those are general improvements to mihomo rather than 5gpn-shaped, and the right
destination for them is upstream.

There is one ordering constraint on the façade: `hub/route` imports
`hub/executor`, so `gpn` cannot be called from `hub/executor` without an import
cycle. It is started from `hub/hub.go`.

Absorbing the script engine raises the module's go directive to 1.25, which
drops the sub-1.25 rows of the upstream build matrix — every legacy Windows and
macOS target. For a Linux gateway that costs nothing. It also arms vet's
non-constant-format-string check against upstream files: those are not fixed,
because every edit there is rebase surface. CI runs `go vet ./gpn/...` and
`go build ./...`.

## State

`gpn/state` holds every 5gpn document under the mihomo home directory. Writes
are temp-file, fsync, rename, fsync-directory; the in-memory pointer is
published only after the rename, so a reader can never observe a value a crash
would un-observe. A document that fails to parse refuses to open rather than
resetting to defaults, which would discard the operator's extensions and policy
without saying so.

Updates carry the revision they were read at and are refused with
`ErrRevisionConflict` if it has moved. This is the only concurrency control in
the system and it exists for one reason: two operators with the same page open
in two tabs.

There are two documents. `dns.json` is the resolver: listeners, gateway address,
the two upstream groups and their client subnet, the ordered policy, and the
handful of knobs with no correct universal value. `intercept.json` is the
interception engine: the master switch, the protocol settings, and the installed
extensions with their immutable snapshots and the operator's own bindings.

`dns.json` replaced four files — `policy.json`, `upstreams.json`, `ecs.json` and
the DNS-shaped half of an environment file that systemd read and the daemon
could not write. Splitting them made every cross-cutting edit two writes with no
way to name the pair: moving a gateway to a new address and changing the
upstreams that serve it left a window in which the resolver was configured as
neither. It also put the one file the console most needed to repair out of its
reach.

`config.yaml` remains fully operator-owned.

## Upgrading an existing gateway

A deployed three-process gateway carries configuration the monolith cannot
parse: two `RUNTIME-OVERLAY,5gpn,*` anchors and an
`IN-NAME,intercept-egress,REJECT` terminator. The core fails `mihomo -t` rather
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

The `intercept-egress` listener and the `MODULE-INTERCEPT` node are dead but
harmless, so they are cleanup rather than migration.

The units are handled the same way, and the asymmetry is deliberate: the
installer publishes only the units this release owns, but keeps removing the
ones it used to. An orphaned `5gpn-dns.service` on an upgraded host would keep
restarting against a binary that is gone — or keep `:853` bound against the one
that is not. The list of retired units is therefore the only record that they
were ever ours, and dropping an entry from it strands whatever it names on every
host that has not upgraded yet.

## Verification boundary

Changes are tested in proportion to their surface. `go build ./...` and
`go test -race ./gpn/...` must be green. `tests/` holds the installer suites,
which are shell and must be run under Linux against an LF checkout.

A real gateway is reachable as `test-env` over OpenSSH. Because it is a working
gateway, configuration changes are validated against copies rather than in
place.

## Not yet true

This document describes the target the work is converging on. These parts are
designed and not yet implemented; do not read their presence above as a claim
that they ship today.

- The marketplace surface does not exist. Extensions install from a manifest URL
  or a pasted manifest, which is the whole of the install path today.
- The Telegram bot is not ported. Its management UI is designed to live in
  zashboard alongside every other surface rather than as a second marketplace
  inside a chat client, and neither half is written.
- UDP and HTTP/3 capture are not wired. `MatchUDP` reports false, and gateway
  QUIC is handled by the fixed `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT`
  capability, which makes a capable client retry over TCP.
