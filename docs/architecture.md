# 5gpn current architecture

This document is the normative description of the current 5gpn system. Design
proposals and archived migration notes are not sources of current behavior.

The project is pre-release. There is no compatibility obligation to anything
described in earlier revisions of this file.

## System boundary

5gpn is an IPv4 DNS-steering gateway. It has **one long-running process**.

- **mihomo** (the `moooyo/mihomo` fork) is the entire runtime: the DNS decision
  engine, the interception/plugin engine, the forwarding data plane, the
  Telegram control plane, and the control API. It is the sole long-running
  process. Each extension validation or action uses a short-lived worker mode
  of the same binary; workers are not services, sidecars, or durable state
  owners.
- **zashboard** is the only user interface. It is a static bundle mihomo serves
  and an API client that talks to mihomo's controller.
- **This repository** is the host installer and TUI, and the assembly source
  for the Docker image. It contains no runtime, Console, or extension source.

A GitHub Release publishes exactly `5gpn-installer.tar.gz`, `checksums.txt`, and
`THIRD_PARTY_NOTICES.md`. The archive contains the host installer plus the
minimal Docker launch set (`compose.yaml`, the seccomp profile, bootstrap
example, and runbook), but no runtime or Console binary. The same tag also
publishes `ghcr.io/moooyo/5gpn:<tag>` for `linux/amd64`, and a stable tag
additionally advances `ghcr.io/moooyo/5gpn:latest`. A beta tag never moves
`latest`. The image does not rebuild mihomo or zashboard: its build consumes the
independent release coordinates and SHA-256 pins from the tagged `install.sh`,
verifies both downloaded artifacts, and copies those exact results into the
image. It also requires the pinned binary's offline
`5gpn-container-contract` command to print exactly
`5gpn-container-runtime-v1`; a stale runtime without the container lifecycle is
therefore unpublishable even when its ordinary version string is valid. There
is no second component lock file. Publication writes the exact OCI digest into
the GitHub release body. A retry reuses only a content-and-label-identical exact
image and matching draft or immutable release; any drift fails closed. Stable
`latest` moves only after the GitHub release is immutable, and beta never moves
it.

Zashboard remains installable as a PWA, but its worker is network-only. It
precaches no application files, deletes caches left by older releases when it
activates, and mihomo serves every `/ui/*` response with `Cache-Control:
no-store`. An offline control plane cannot operate the gateway; keeping an old
one available is actively unsafe.

Core and Console self-upgrade are not controller capabilities. Authenticated
requests to `/upgrade` and `/upgrade/ui` fail with HTTP 403, and the Console
contains no check, automatic action, or manual action for them. `/configs/geo`
remains an independent maintenance action. Core and Console versions move only
through a digest-pinned 5gpn release: the host installer bundle or the matching
container image tag.

The host/systemd installation retains two root oneshots, and only because they
hold key material a network-facing process must not:

- `5gpn-intercept-cert.service` owns the interception CA and mints the leaf
  whose SAN set covers the enabled capture hosts.
- `5gpn-certbot-renew.service` owns the Let's Encrypt lineage for the public
  service names.

The Docker delivery deliberately chooses a simpler and weaker key boundary.
It runs one image as one container and one Compose service. `5gpn-mihomo` is
still the only long-running process and PID 1 after synchronous bootstrap.
The entrypoint starts and waits for the trusted initial CA and public-certificate
helpers before `exec`. After the mandatory worker-isolation probe succeeds, the
runtime may start and wait for trusted short-lived renewal or reconciliation
helpers. None is a service or sidecar. The container's single `fivegpn` identity
can read the Cloudflare credential, ACME account, public certificate keys, and
interception CA key. This loss of the host installation's process-level key
separation is an explicit owner decision for the simplified Docker form, not an
accidental security claim.

The only current public certificate roles are `dot` for DoT and `console` for
the controller, Console, and profiles. A legacy `web` certificate role and the
old `DNS_WEB_CERT`/`DNS_WEB_KEY` configuration fields are migration inputs only;
current configuration neither persists nor consumes them. The interception CA
and constrained leaf are a separate private trust boundary, not another public
certificate role.

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
        ├─ 5gpn/engine   MITM TLS/H1/H2 ──────────────┘
        │       | bounded IPC to one-shot goja workers
        │       | 5gpn/dial -> protected rule prefix, then operator binding
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

Inside the trusted long-running runtime that coordination is a field read. What
replaced all of it is `5gpn/state`: a file written atomically, a pointer swapped
atomically, and a content hash so two browser tabs cannot silently overwrite
each other. Untrusted extension code is the narrow exception to the shared
address space: every validation and action executes in a stateless one-shot
child of the same binary and reaches storage, logs, and approved network calls
only through bounded IPC back to the main process.

The cost is a shared failure domain for the trusted runtime. Worker-manager
construction and the initial hard-isolation probe run unconditionally during
engine construction, before any gateway listener opens.
Startup isolation probe failure is fatal before listeners open.
It does not leave DoT or the controller available without extension isolation.
After a successful probe, each child failure stays local.
JavaScript exceptions, timeouts, denied network calls, child-start errors,
worker crashes, and worker OOMs therefore fail the current operation. There is
no in-process script fallback. A panic in the main process, a
critical DNS listener that ends, or another unrecoverable runtime invariant
terminates the process instead of leaving a partially live gateway. The deleted
coordination machinery was not buying this isolation — it was buying agreement
between independently durable services that no longer exist.

### Failure and process recovery

There is no in-process subsystem supervisor. On a host installation, systemd
is the process supervisor. The shipped `5gpn-mihomo.service` runs
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

The Linux deployment baseline is kernel 5.7 or newer, systemd 257 or newer, and
a pure cgroup v2 hierarchy with its memory and pids controllers available.
Before any project publication, the installer checks that baseline, rejects
managed main-unit or global service drop-ins, and runs
`systemd-analyze verify` against byte-derived candidates for every shipped
unit. The systemd floor is 257 because 254 through 256 parse
`ProtectControlGroups=` as a boolean and do not support the required `private`
namespace mode. `5gpn-mihomo.service` uses `MemoryAccounting=yes`,
`TasksAccounting=yes`,
`Delegate=memory pids`, and no `DelegateSubgroup=`. With
`ProtectControlGroups=private`, systemd starts the trusted parent alone at
`0::/`, with the empty unit hierarchy mounted at `/sys/fs/cgroup`. Before any
listener opens, the parent creates `/main` or validates the empty directory left
by a prior clean stop, moves only itself into it, verifies
that the delegated root is empty, enables the memory and pids controllers, and
then creates the worker aggregate as a sibling. Its final `/proc/*/cgroup` entry
is `0::/main`. Setting `DelegateSubgroup=main` in the unit would instead make
that subgroup the cgroup namespace root, hide the unit parent, and make the
required sibling worker hierarchy impossible. `OOMPolicy=continue` keeps a
worker OOM from stopping the unit, while `KillMode=control-group` removes every
worker when the unit stops. No in-process supervisor is introduced.

The global drop-in rejection includes the complete systemd 257 `Memory*`,
`CPU*`, `IO*`, `BlockIO*`, `Tasks*`, `ManagedOOM*`, and `Limit*` resource
families, their startup/allowed-node variants, `Slice=`/`DisableControllers=`,
and process scheduling controls. This deliberately includes accounting keys and
the older `MemoryLimit`, `CPUShares`, and `BlockIO*` aliases: accepting an
apparently observational global family member makes the fail-before-publication
gate dependent on an incomplete hand-maintained key list. Any inherited member
of these families is rejected before project publication.

Guest worker admission is global 2 and per extension 1. The per-extension bound
applies to runtime actions; whole-document validation shares the global pool
because it is not attributable to one installed extension.
Admission never queues; saturation fails the current operation immediately.
Pure parent-side declarative actions do not acquire a worker slot. The five
such kinds are reject, mock, header edits, URL rewrite, and bounded body
replacement. JQ and script validation/execution use a worker because their
guest-controlled allocation is the reason for this isolation boundary.

Worker admission is fixed at two concurrent processes. Each Linux leaf receives
`memory.max=536870912`, `memory.swap.max=0`, `memory.oom.group=1`, and
`pids.max=32`, making the admitted aggregate upper bounds of 1GiB and 64 tasks.
Those limits cap consumption; they do not reserve memory and are not a physical
RAM preflight. Host sizing must account separately for the main runtime and the
operating system. The Windows worker boundary uses the same 512MiB process limit
and `ActiveProcessLimit=1` in a Job Object.

`RestrictNamespaces=` is deliberately absent from the main service. In systemd
257, every non-default value installs a seccomp rule that returns `ENOSYS` for
all `clone3` calls because seccomp cannot inspect the pointed-to flags. Go's
`UseCgroupFD` path necessarily calls `clone3(CLONE_INTO_CGROUP)` so the child is
born inside the already sealed leaf; falling back to `clone` would lose that
atomic boundary. The unit instead denies direct `unshare` and `setns` calls with
`SystemCallFilter=~unshare setns`. It cannot safely filter namespace flags inside
`clone3`, so the runtime startup isolation probe is the authoritative gate. A
failed initial cgroup-FD spawn aborts monolith startup before listeners open;
after a successful probe, one later child-start failure remains local to its
validation or action. Neither phase selects an in-process or move-after-spawn
fallback.

This is crash recovery, not self-healing. It does not rewrite a bad operator
configuration, free a conflicting port, repair certificate files, or detect a
process that remains alive but cannot make progress. A deterministic startup
failure eventually leaves the unit failed at the start limit. Availability
monitoring therefore belongs outside this process and host, using active DoT
and HTTPS probes rather than an in-process heartbeat.

### Docker deployment

The Docker form preserves the same runtime and one-failure-domain model. It is
one image, one container, and one Compose service; it does not introduce a DNS
container, certificate sidecar, init process, cron daemon, or supervisor.
`docker/entrypoint.sh` performs bounded bootstrap operations synchronously as
the fixed `fivegpn` identity `10001:10001` and waits for each child. It then uses `exec` so
`5gpn-mihomo` becomes PID 1 with `FIVEGPN_RUNTIME=container`. An empty or
unrecognized runtime value never silently selects container semantics.

The runtime still constructs the worker controller and performs the real
cgroup-FD worker probe before opening listeners. Only after that probe succeeds
may its certificate manager run either fixed helper command. Public renewal and
interception reconciliation are globally serialized, each child is placed in a
separate process group, and the parent always waits for it. Shutdown stops new
certificate work, sends the active helper group TERM and then KILL after a
bounded deadline, waits for DNS/subscription and Bot loops, closes Engine
transports, logs, workers and its cgroup hierarchy, and then exits. Ordinary
mihomo listener descriptors close with PID 1 rather than widening the fork
surface with a second lifecycle API. In container mode `/restart` requests that
same orderly whole-process exit; Docker's restart policy replaces the
container. It never `exec`s over live workers or helpers.

The manager runs an immediate reconciliation and then a 24-hour check with a
fresh cryptographic 0–1 hour jitter on every round. Helpers inherit no ambient
process environment: only the fixed `PATH`, `HOME=/nonexistent`, `LANG=C`,
`LC_ALL=C`, and `TMPDIR=/tmp` are supplied. Container `/restart` acknowledges
and flushes the HTTP response before notifying the process owner. Managed host
and container runtimes both complete the same 5gpn teardown and exit normally;
systemd or Docker then replaces the process. Only a non-managed upstream mihomo
path retains the old self-exec fallback.

The supported Compose contract is deliberately narrow:

- Linux `amd64`, rootful Docker Engine 28 or newer, a pure cgroup v2 host, the
  systemd cgroup driver, and no daemon `userns-remap`;
- a private cgroup namespace plus Docker 28's `writable-cgroups=true`, so runc
  delegates only the container cgroup directory and delegation files to the
  fixed container UID/GID;
- the shipped seccomp profile, derived from Docker's default profile, which
  admits `clone3` for `CLONE_INTO_CGROUP` while retaining the default denials;
- an IPv4-only bridge network with explicit public port mappings, a namespaced
  `net.ipv4.ip_unprivileged_port_start=0`, a read-only image root, one
  `/etc/5gpn` named volume, tmpfs runtime directories, every capability dropped,
  no new privileges, no Docker socket, and no host cgroup bind mount; and
- `init: false`, `restart: unless-stopped`, and a 30-second stop grace period.

The Docker data-plane listeners use the stable container coordinate
`0.0.0.0`, which is persisted as `DNS_MIHOMO_LISTEN_IPS`; public and gateway
addresses remain DNS/deployment identity rather than container-interface bind
targets. Compose publishes `853/tcp`, `80/tcp`, `443/tcp+udp`,
`5060/tcp+udp`, `8080/tcp`, and `8443/tcp`. The public 443 mapping terminates at
the Docker-only tunnel socket `0.0.0.0:9443`, whose target remains
`console.<base>:443`. This translation is necessary because a wildcard
container `:443` socket would collide with the load-bearing controller at
`127.0.0.1:443`; it does not change the public port or the sniffed destination
port. Every other published port maps to the same container port. Every mapping
binds the Docker host's IPv4 wildcard `0.0.0.0` explicitly; an IPv6-enabled
daemon must not publish the service on `::`. Compose publishes neither plain
DNS (`53`), the debug listener (`5353`), the origin boundary (`5354`), nor the
container's controller port 443.

Rootless Docker, Docker Desktop, daemon user-namespace remapping, SELinux
enforcing hosts, and `arm64` are outside the first supported release. AppArmor
on Debian or Ubuntu is the validated host MAC path. The worker startup probe is
still authoritative: a platform that appears to meet the list but cannot
create the exact bounded sibling hierarchy fails before DoT or the controller
opens. A GitHub-hosted image build and static container smoke cannot prove this
runtime property; the release gate includes a real Engine 28/cgroup-v2
acceptance run on `test-env`.
The driver verifies that its Git root and `HEAD` are the requested candidate
and that every versioned installer-pin, Compose, seccomp, driver, and probe
input is tracked and unchanged at that commit. Supplying a commit label to a
copied or locally weakened harness is not acceptance evidence.

Docker certificate bootstrap is Cloudflare DNS-01 only. It accepts the
`cloudflare_api_token` Compose secret, keeps the generated Certbot credential
file under `/run`, uses the single `<base>` lineage for `<base>` and
`*.<base>`, and publishes the `dot` and `console` roles. `http-01`, `debug`,
and any other `CERT_MODE` are rejected in the Docker path. The host installer
continues to support its documented `cloudflare`, `http-01`, and `debug`
modes.

`/etc/5gpn/letsencrypt/.5gpn-docker-lineage-ready` is the mode-0600,
`fivegpn`-owned first-lineage commit fence and binds the base domain. Before it
exists, bootstrap may clean only marker-owned partial first-boot lineage files
and never deletes ACME accounts. After it exists, a damaged current lineage is
restored only from a previously validated complete generation or fails closed;
it is never silently reset. Public-role generation collection first renames a
candidate to `.delete.generation-*` in the same role directory and removes only
that tombstone, so an interrupted deletion cannot make a live generation
ambiguous.

## Listeners

| Listener | Purpose |
| --- | --- |
| `:853/tcp` | The only client DNS ingress, DNS over TLS. |
| `127.0.0.1:5354/udp` and `/tcp` | The origin boundary. mihomo's own resolver queries it after the sniffer recovers a hostname, and it answers a different question from the client listener — see below. Loopback is enforced at bind. |
| `127.0.0.1:5353/udp` | Local debugging only. The bind is refused if it is not loopback: it answers the same policy without TLS or client identity, which on a public address is an open resolver. |
| `127.0.0.1:443/tcp` | TLS-only external controller. Serves the Clash-compatible API, the `/5gpn/*` routes, `/capabilities`, and the zashboard bundle at `/ui/` — so the panel is `https://console.<base>/ui/`. Loopback, on :443, because that is the port a browser reaching the console name arrives on: the name resolves to `127.0.0.1` through the seed's `hosts` block, so the allow rule's DIRECT dial lands here, on this same process through a different listener. |
| configured gateway addresses (host) or the Compose-published `0.0.0.0` tunnel sockets (Docker) | HTTP/TLS ingress for traffic steered to the gateway, sniffed for Host or SNI. Docker maps public `:443` to its tunnel's private `:9443` socket while retaining target port 443. |

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

Every `/ui/*` response is nevertheless an isolated browser boundary. Mihomo
sets a same-origin script policy, denies framing and object embedding, permits
only the local bundle plus the explicit OpenStreetMap tile origin, and emits
`nosniff`, `no-referrer`, and a restrictive Permissions Policy. Controller API
coordinates remain operator-configurable, so the connect policy permits HTTP(S)
and WS(S) backends without permitting remote script execution.

The installer and the root-only management TUI may display a zashboard setup
URL. It is not the deleted server-side handoff: it is the ordinary public
`/ui/` URL followed by a client-side `#/setup` fragment containing the same
controller secret and explicit Clash connection fields. A fragment is not sent
in the HTTP request. Before the router or controller probe can observe it, the
Console synchronously replaces the history entry with a credential-free URL;
until that consumption succeeds, however, the complete link and terminal
scrollback remain password-equivalent. It is therefore printed only to an
interactive terminal or after an explicit `Console connection` action;
redirected installer output contains only the public panel URL and tells the
operator how to retrieve the credential on the host. The manual host is always
`console.<base>`, never `127.0.0.1`, because zashboard executes on the browser's
device and its loopback is not the gateway.

The controller assigns `.mobileconfig` responses the explicit media type
`application/x-apple-aspen-config`; serving profiles must not depend on the
host distribution's MIME database. The installer never edits a shared MIME
table. Its readiness probe bypasses proxy environment variables and requires
both public profiles to return HTTP 200 with that exact media type, comparing
the type case-insensitively and allowing parameters.

Both profile files are published directly beneath `/opt/5gpn/ui`, which is the
only current profile publication directory, and mihomo serves them beneath
`/ui/` alongside zashboard. `/opt/5gpn/www`, `WWW_DIR`, and any separate web
root are legacy migration inputs only and must never receive a current profile.

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

Fresh install and Marketplace update are each review/apply pairs joined by a
digest. The digest covers the manifest bytes, every script that will run, and
the immutable capability shape — and deliberately not the operator's bindings
or entered settings, which would make it change whenever they edited a field
and stop meaning "this is what you reviewed". Apply re-fetches and compares
rather than committing the candidate it already holds, which is what makes the
digest a check on the publisher rather than on our own bookkeeping. Pasted URL
and local review are install-only; an installed ID can update only from an
explicitly selected Marketplace entry, and no installed-source update route is
mounted.

Extension detail exposes that complete immutable `snapshot_digest` separately
from the manifest-only source digest, so an enable review can identify the same
capability and code shape an install or update review names. If apply re-fetches
a different immutable snapshot, a different extension ID, or Marketplace claims
that no longer match the candidate, it returns HTTP 409 with
`code: review_conflict` and the current document revision. The client preserves
entered settings, disables the old confirmation, and requires a fresh review;
it does not classify this state by parsing human-readable error text.
Marketplace update apply also quotes the exact manifest URL returned by review.
Changing or removing that selected entry therefore invalidates the confirmation
even when a different URL happens to serve byte-identical code; a digest proves
content identity, not that the operator authorized an unshown source change.
The returned value is the selected entry URL and remains authoritative when its
fetch redirects; the redirect-resolved `candidate.detail.source_url` cannot be
substituted for it.
These `snapshot_digest`, reviewed-source, and structured-conflict fields were
introduced by the `5gpn-interception` capability version 4 contract. Version 5
retains that complete surface and adds the authenticated same-origin location
search used by typed extension settings. Version 6 retains both and adds the
cursor contract for the bounded in-memory plugin log: every event has a
monotonic decimal-string `seq`, one process lifetime has an opaque `stream_id`,
and incremental reads quote both the stream and exclusive `after` cursor. The
response reports decimal-string oldest/latest/dropped values and an explicit
reset when a process restart, future cursor, or ring eviction makes the old
position unusable. Filters never redefine the global sequence. A Console and
core must still match the feature version exactly; a client must not infer the
location or log routes from an older version that never mounted their contract.
Catalog review resolves its configured source and installed-state projection
from one committed interception revision. If that document changes while the
catalog or manifest is being fetched, review returns a revision conflict rather
than pairing an old source with a newer revision.

`enabled` records operator authorization, not a claim that every runtime
prerequisite is currently healthy. The API separately projects each module's
derived runtime phase. Enabling, changing a capture set, or applying an update
may therefore return an authorized `certificate_pending` module; it becomes
`active` without another configuration write once the root publisher commits a
matching certificate result. Certificate transitions never advance the
interception document revision and no derived `active` bit is persisted.

All setting values for one extension are one configuration decision and are
written as a complete typed map. The engine validates and compiles the whole map
before one document rename and pointer swap; it does not expose a sequence of
per-key writes that could leave action gates observing a combination the
operator never submitted. Egress and capture-DNS bindings remain separate
writes because they authorize different routing decisions. Every extension has
one explicit egress binding, defaulting to `DIRECT`; an empty binding is not a
state the current document or API can represent. The live choice list contains
only `DIRECT` and real proxy groups. If a selected group later disappears, the
stored name remains visible and traffic fails closed until the operator selects
an available value.

An enabled extension may be updated from a reviewed Marketplace entry without
first disabling it. Review still precedes apply, apply refetches and verifies
the reviewed immutable digest, and operator bindings and type-compatible
setting values are retained. The fully
validated replacement is published by the same immutable Config pointer swap:
an in-flight request finishes on the old snapshot and a later request sees only
the new one. A new required setting must be supplied as part of the reviewed
apply; the existing explicit egress binding is retained. Neither condition
silently disables the extension.

`/5gpn/interception/catalog` is explicit discovery, installation, and update
selection. A fresh interception document has `catalogs: []`: there is no
built-in publisher and no marketplace request until an authenticated operator
adds an HTTPS source through the Console. A catalog is a list of manifests: it
is fetched through the same guarded client an import uses and is never
persisted. Selecting an entry runs the same review-then-confirm boundary as a
fresh import. For an installed ID, that explicit selection authorizes changing
the source to the reviewed entry; merely adding or refreshing a catalog never
changes installed code.

What a catalog is allowed to do is contradict itself, and that is checked. An
entry states the manifest's SHA-256 and the shape of what it declares; if the
fetched manifest disagrees, the review is refused rather than returned with a
footnote, because the review is the screen where the operator decides and a
wrong description reaching it is the whole failure. The index is decoded
leniently: it is a contract with every deployed gateway, so rejecting unknown
fields would make older cores refuse whole catalogs whenever a publisher added
something for newer ones.

A successful fetch atomically replaces one source's complete in-memory index.
Network, JSON, duplicate-field, or partially invalid entry failures retain the
last complete snapshot regardless of its cache age and return it together with
an explicit source error. A source that has never succeeded reports the same
error with an empty list. Cache TTL schedules another fetch; it never converts
stale discovery data into an apparent publisher deletion.

For an installed entry, the listing reports **current** when the catalog version
and manifest SHA-256 match the installed snapshot. A same-version manifest
republish is therefore still an update, while a successful reviewed apply
becomes current after the catalog's local installed-state projection refreshes.
External script resources are fetched live during review and are not enumerated
or compared against a parallel catalog resource-digest list. They remain part
of the runtime's complete immutable snapshot digest. This status never replaces
review: any non-current entry is refetched and checked before apply.

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

An engine upstream enters mihomo through a narrow in-memory `INNER` dial. The
operator-owned rule prefix through the fixed UDP/443 guard runs first, so
management-plane, private-address, and explicit `REJECT` decisions cannot be
bypassed; the extension's reviewed operator binding is then the terminal egress
choice. The hostname is resolved once, every answer must be globally routable,
and the accepted address is pinned for the outbound while HTTP Host and TLS SNI
retain the original name. The connection still appears in mihomo's ordinary
connection table, but the normal rule remainder cannot silently replace the
binding the operator reviewed.

### Certificate readiness

After an authorization changes the enabled capture-host union, mihomo
atomically writes a versioned certificate request containing the target digest,
a random attempt fence and the canonical host list. On a host installation the
CA signing key remains outside mihomo and `5gpn-intercept-cert.path` starts the
root oneshot. In Docker the same long-running mihomo process notifies its
certificate manager, which starts and waits for the fixed trusted
`docker-intercept-cert.sh reconcile` helper; a startup scan and daily
reconciliation cover notifications lost across a process exit. Both publishers
sign only the current request, recheck the fence before every publication
boundary, fsync the certificate and key, and commit a hash-bound ready or error
result last. A stale A or B attempt can never overwrite a newer C request.

The runtime treats the result as data, not as a second configuration document.
It derives one immutable interception plan from the committed Config, the fixed
client boundary, live egress groups and the current certificate generation. A
plan is active only when the non-CA keypair matches its committed hashes, is
currently valid and covers the complete enabled host union. Otherwise the
authorized hosts remain claimed but their HTTP/TLS traffic is explicitly
rejected before ordinary mihomo rules; pending must never become direct bypass.
The same gate runs again for every ClientHello—including resumed TLS—and every
HTTP request on an existing connection. Session-ticket keys rotate with the
certificate-plan generation.

The host certificate publisher has no network namespace, capability,
controller credential or mihomo control call. The Docker helper performs no
network operation, but the single-container design does not give it a separate
network or key namespace. A retry changes only the request attempt and does not
change the interception revision. Runtime readiness is reconstructed from
durable configuration and the committed certificate files on every process
start; it is never repaired by rewriting operator state or restarting a
subsystem.

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

### Mihomo modes and proxy groups

The fresh/reset seed uses `mode: rule` and ends in `MATCH,Proxies`. `Proxies` is
an operator-defined selector containing only `DIRECT` until the operator adds
static nodes or providers and wires them into that group. It is the normal
terminal egress for gateway traffic that passes the preceding guards.

`GLOBAL` is a mihomo-created virtual selector for `mode: global`; it is not the
terminal group in rule mode. Global and direct modes bypass the rule list, so
they also bypass the private-address and UDP/443 guards. Extension capture
therefore treats any non-rule mode as an unavailable client boundary. The
supported 5gpn configuration remains rule mode even though the fully
operator-owned YAML can still be edited manually.

The Console can hot-apply a complete YAML payload or load an absolute safe
path through the upstream `/configs` API, but that API never writes
`config.yaml`. Persistent proxy nodes, providers, memberships, and rules are
operator file changes; the Console is not a second node database. The root
management TUI has one deliberately narrower host action for static nodes. A
short-lived `5gpn-mihomo 5gpn-nodes` command parses pasted Mihomo/Clash
`proxies` YAML or the share-link formats already supported by mihomo, rejects
partial imports, and adds the validated static nodes to the existing `Proxies`
selector. Delete removes the static node and that membership, but the complete
candidate must still parse, so a reference from another group, rule, or dialer
makes the whole operation fail.

This is a revision-checked edit of the operator file, not another source of
truth. The one-shot command keeps a previous-file backup, validates the
complete candidate through mihomo's own configuration parser under the same
`SAFE_PATHS` as the service, and publishes with an fsynced same-directory
rename. The TUI then hot-applies that complete path through the existing
`/configs` route. A failed hot apply restarts the
complete service from the already validated disk file; it does not roll the
operator edit back. No node CRUD route, selector API, generated YAML region, or
continuing subscription service exists. Provider subscriptions and arbitrary
group/rule edits remain manual operator YAML changes.

Hot apply has an explicit controller boundary. Listener address, transport,
and routing-mark changes are startup-only and `/configs` returns `409` instead
of claiming they became live. With listener topology unchanged, a complete
controller plan—secret, CORS, TLS material, and UI root—is prepared first and
then swapped atomically; preparation failure leaves the prior listener usable.
An empty UI root withdraws the old UI rather than continuing to serve stale
files. New HTTP requests and TLS handshakes use the new plan; already-established
TLS and authenticated WebSocket connections end on their normal connection
lifetime. An unexpected end of the current controller listener is a
monolith-fatal invariant, while closing a retired generation during a successful
swap is not.

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
who knows it means nothing. Retired `DNS_HEARTBEAT_URL` and
`DNS_HEARTBEAT_INTERVAL` keys are tolerated only while an older `dns.env` is
rewritten and are not persisted by the current installer. An independent
monitor must actively probe the gateway from outside the host.

Egress goes through the core's own inner dialer, so reaching `api.telegram.org`
from a network that blocks it is the operator's existing rules rather than a
private proxy knob.

## Code layout and the fork budget

Fork synchronization is branch-explicit. `moooyo/mihomo` rebases conceptually
on canonical `MetaCubeX/mihomo:Alpha` (merged into the published maintenance
branch, never history-rewritten), while `moooyo/zashboard` tracks
`Zephyruso/zashboard:main`. A remote's default branch is not evidence of the
baseline: before every sync, verify the documented branch and merge-base, then
fast-forward the corresponding fork baseline and merge it into the maintenance
branch. In particular, the mihomo fork's `origin/HEAD -> main` is unrelated to
the `Alpha` ancestry and must never be used as an update source.

All 5gpn code lives under `5gpn/` in the mihomo fork, a directory upstream never
touches. The façade package is named `fivegpn`, because Go identifiers cannot
begin with a digit. Upstream packages may import `5gpn`; they may not import
anything beneath it. `5gpn/importrule_test.go` enforces this by walking
`go list`.

The rule exists because the fork's cost is not the size of `5gpn/` — it is how
many upstream-owned files carry a 5gpn-shaped change, since those are what a
rebase must reconcile. All runtime 5gpn-specific upstream edits remain
concentrated in two files: `tunnel/tunnel.go` owns the capture and
reviewed-routing hooks, while `hub/hub.go` starts the subsystems and propagates
critical startup failure. `main.go` dispatches the offline `5gpn-nodes` command
and the internal extension worker mode into the root `5gpn` façade. Both are
same-binary one-shot modes; neither starts a service or owns durable runtime
state. Runtime authorization and fail-fast startup made
the former twelve-line count obsolete; keep these file boundaries rather than
preserving a misleading fixed line budget. The supporting bookkeeping remains
in fork-owned files.

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

The configured catalog list starts as an explicit empty array. No official or
third-party source is seeded, because contacting a publisher is an operator
trust decision. The authenticated Console is the only management surface that
adds marketplace URLs.

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

A missing `dns.json` is seeded with the same two subscription rules as the
pinned core default: ChinaMax domains with `direct` intent and the GFW list with
`proxy` intent, both refreshed every 24 hours. Their caches live in the
monolith's private `dns-rules` state directory. `/etc/5gpn/rules` is never a
current cache path.

`dns.env` now contains only installation-owned host coordinates: the DoT/debug
listeners used for a missing-document seed, base/public/gateway/listener
addresses, certificate mode and email, and the controller coordinates and
secret. Runtime policy, upstreams, subscription
state, resolver tuning, statistics, and heartbeat fields are not mirrored
there. Known retired keys are accepted only so one installer rewrite can drop
them. Legacy `policy.json`, `upstreams.json`, `ecs.json`, `subscriptions.json`,
`stats.json`, and `/etc/5gpn/rules` remain root-only migration evidence; the
monolith neither reads them nor receives write access to them.

`config.yaml` remains fully operator-owned.

The Docker deployment maps one local named volume at `/etc/5gpn`. That volume
is the complete persistence boundary for the operator configuration, monolith
documents, public certificate lineage and role copies, interception CA and leaf,
and ownership markers. The image root is read-only; `/run/5gpn`, the secured
bootstrap copy, `/tmp`, `/var/tmp`, and `/opt/5gpn/ui` are tmpfs. A fresh
container copies the pinned Console into that empty UI tmpfs and may seed
missing files, but must preserve
and validate existing operator-owned files under the same atomic-publication
rules. The fixed numeric `fivegpn` UID/GID is therefore part of the Docker
volume ABI and may not drift between image tags.

## Operator TUI

The terminal UI renders the facts for the selected tab into a complete cached
frame before replacing the visible screen. Cursor-only movement reuses that
snapshot, while changing tabs runs only the destination tab's renderer. The
paint first prepares the complete frame, then resets terminal styling, homes,
erases the visible region, and writes that frame in one output call. Slow
system and controller probes therefore never leave a blank screen, while old
long-line, inverse-video, and QR suffixes cannot survive a shorter frame. It
does not use `2J` or clear scrollback. Plain list and non-Gum fallbacks retain
the same actions. Sensitive Console connection fields are an explicit action
and are never part of the overview frame.

The Nodes tab is a host-side editor for static snapshots, not a Console node
store. Multiline Gum input accepts a Mihomo/Clash proxy mapping/list or supported
share-link export. The TUI holds the installer lock, quotes the current raw-file
revision, delegates all protocol parsing and complete-config validation to the
one-shot core command, and adds every imported name to `Proxies`. Deletion is
exact-name, refuses a node currently selected by any live group, and rejects a
candidate that leaves another reference dangling. Only a successful atomic file
publication followed by full-path hot apply and live `/proxies` verification is
reported as complete; a reload failure triggers a complete service restart
against the validated new file. If that also fails,
the TUI reports the saved-versus-live split and the previous-file backup path;
it does not roll the edit back automatically.

Service status is provenance-aware. An inactive 5gpn-owned Certbot timer is an
error; a debug certificate has no applicable renewal timer; a reused external
lineage remains externally renewed; and `missing` provenance requires repair.
Each displayed systemd unit is queried at most once per rendered snapshot.

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

Legacy `DNS_INTERCEPT_CONFIG`, `DNS_WEB_CERT`, `DNS_WEB_KEY`, `WWW_DIR`, and the
retired resolver/API/tuning keys may be recognized only while an older
installation is rewritten. The old sidecar config and resolver state are kept
root-only, while a structurally verified `web` certificate-role tree may remain
as migration evidence. None is accepted as current configuration or exposed to
the mihomo service account, and none creates a listener, certificate consumer,
or profile publication path.

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

Docker has an additional manual release gate. GitHub-hosted CI may prepare the
digest-pinned components, build the `linux/amd64` image, inspect its static
contents, and exercise commands that do not start the gateway. It must not
claim that this proves cgroup isolation. Before publication, the exact candidate
is exercised on `test-env` with rootful Docker Engine 28, cgroup v2 and the
systemd cgroup driver. The acceptance contract verifies the real startup probe,
an extension worker operation, worker OOM containment, authenticated
capabilities, certificate hot publication, container recreation, and named-volume
persistence. Publication additionally fails closed unless repository variables
`FIVEGPN_CONTAINER_ACCEPTED_COMMIT` and
`FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256` match the exact tag commit and its
current `install.sh` pin, and `FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID` matches the
reproducibly rebuilt candidate image content digest. Those variables are
updated only after that exact candidate passes on `test-env`. No GitHub-hosted
fallback may turn a missing or stale real-host result into a pass.
