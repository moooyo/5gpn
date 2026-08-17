# 5gpn current architecture

This document is the normative description of the current 5gpn system. Design
proposals and historical notes are not sources of current behavior.

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

A 5gpn release publishes only `5gpn-installer.tar.gz`, `checksums.txt`, and
`THIRD_PARTY_NOTICES.md`; the bundle contains installer material only. It does
not build or republish mihomo or zashboard. The installer fetches those artifacts
from their own repositories using independent release tags and SHA-256 pins.
Those coordinates exist once in the bundled `release/pins.env`. A fixed-key
parser rejects shell syntax and malformed or unapproved values, and constructs
only HTTPS GitHub release URLs for the three known repositories. The installer,
CI, and network verifier use that same library; the installed management copy
retains the manifest and parser under `/opt/5gpn/release`.
At process start the installer copies the two single-link files into one private
process-owned snapshot, requires the source identity and digest to remain stable
across that capture, and executes and parses only the snapshot. It rechecks the
original pair before any download and at the final publication boundary. After
that boundary, installed copies are materialized only from the already-bound
snapshot, so a later checkout edit cannot turn a safe run into a partial one.
Release packaging stamps `install.sh` with the two snapshot digests as a derived
generation binding; an installed backend rejects the development sentinel or a
mixed script/pin generation before it sources the parser.
It separately stamps the quick-installer digest. Release-bundle execution,
full reinstall, and channel handoff validate that digest, while unrelated
status, restart, node, certificate, and uninstall actions do not depend on
quick-installer health.
An installed management process also records its own script and pin-pair state;
after waiting for the install lock it refuses to act if another transaction
replaced that backend and asks the operator to invoke `5gpn` again.
The tags remain independently versioned, but a change to their shared
`5gpn-interception` contract is one release decision: the root repository updates
and verifies both pins in the same commit. Both artifacts are staged and
verified before publication, then the binary and Console tree are published
before the service is restarted into the new pair. The filesystem publications
are sequential rather than one cross-artifact atomic rename; exact capability
matching makes a transient or partially published mixed pair fail closed.

The installer archive also carries the tagged Docker launch set: `compose.yaml`,
the seccomp profile, bootstrap example, and Docker runbook. These are installer
inputs, not a bundled runtime. The same tag may publish the separate
`linux/amd64` registry artifact `ghcr.io/moooyo/5gpn:<tag>`; stable may advance
`latest` only after the GitHub release is immutable, while beta never moves it.
Image assembly loads the same bound `release/pins.env` through
`release/pins.sh`, verifies and copies those exact Core and Console artifacts,
and creates no Docker-only component lock. The Core must additionally answer
the offline `5gpn-container-contract` command with exactly
`5gpn-container-runtime-v2`. Publication records the exact OCI digest and may
reuse an existing exact tag only when image content and the complete label map
match the candidate; any drift fails closed.

Zashboard remains installable as a PWA, but its worker is network-only. It
precaches no application files, deletes caches left by older releases when it
activates, and mihomo serves every `/ui/*` response with `Cache-Control:
no-store`. An offline control plane cannot operate the gateway; keeping an old
one available is actively unsafe.

The public static surface is one generation tree at `/opt/5gpn/ui`. That stable
root contains only its root-owned marker, `generations/`, and a relative
`current -> generations/generation-*` symlink. Mihomo's `external-ui` is the
fixed `/opt/5gpn/ui/current`, while `SAFE_PATHS` and the systemd read-only
boundary cover the stable root. Every generation is a complete root-owned,
single-link regular tree containing the Console, `.zash_version`, and both
signed profiles. Install, renewal, and manual profile refresh build or clone an
unpublished generation under the shared certificate lock, validate and fsync
it, and change visibility with one `current` rename. A service startup precheck
validates the complete current tree before mihomo opens listeners.
Independent public renewal takes the install lock, rejects retained configure
gate state, then takes the certificate lock. The interception-certificate
oneshot is deliberately different: the full installer releases the certificate
lock while retaining the install lock and waits for that oneshot, so it takes
only the certificate lock and then rejects retained gate state. Configure cannot
create a gate while that check is in flight because it needs the same
certificate lock before its runtime-affecting transaction.

One browser may fetch an old `index.html` immediately before a generation
switch and request its hashed asset immediately afterwards. Each generation
therefore records `.zash_primary_files`, a root-owned digest manifest of its
own `assets/` files, and `.zash_compat_files`, a disjoint manifest containing
only primary assets copied from the immediately previous generation because
the new dist omitted them. A same asset path with different bytes is rejected.
Compat files never become primary input for the next generation, so this is a
one-release old-tab window rather than an accumulating fallback archive.

All top-level bytes come from the new dist. The digest-pinned Console build is
required to keep its stable old-tab URLs present across that one-release
window: `apple-touch-icon.png`, `favicon.ico`, `favicon.svg`,
`favicon-dark.svg`, `icon.svg`, the four `pwa-*` icons named by
`manifest.webmanifest`, `registerSW.js`, `sw.js`, and `pwa-no-cache.js` when
the preceding generation exposed them. The manifest must remain valid JSON
and may name only safe generation-local stable icon paths. Their bytes may
change with the new generation; this is an explicit stable-URL compatibility
assumption, not a promise that arbitrary top-level content stays byte-identical.
After a durable current switch, garbage collection keeps only current and
previous; GC failure is a warning and never rolls back the committed pointer.

The Docker form uses the same stable-root, generation, manifest, profile, and
relative-`current` shape in its separate persistent `fivegpn-ui` volume.
Ownership there belongs to fixed container identity `10001:10001` rather than
host root, but a flat copied UI tree and the retired UI tmpfs are not supported
container schemas. `external-ui` remains `/opt/5gpn/ui/current`.

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
the controller, Console, and profiles. A `web` certificate role or the retired
`DNS_WEB_CERT`/`DNS_WEB_KEY` fields are unsupported legacy footprints that make
installer preflight fail before publication; current configuration neither
persists nor consumes them. The interception CA
and constrained leaf are a separate private trust boundary, not another public
certificate role.

Both role writers use one bundled `cert-role-ctl.sh` over the shared
`publication-fs.sh` durability and mount-boundary primitives. One immutable
source snapshot supplies both roles. Each complete generation is synced and
renamed before its relative `current` pointer is changed, and each pointer
rename is followed by a fatal role-directory sync. The two pointers are a
documented sequential publication boundary, not a cross-role atomic rename: a
failure after the first pointer commits is reported as `committed-partial`, and
a post-rename sync failure is `committed-undurable`. Neither state is rolled
back. The next locked run validates the live pointers and repairs forward.
Garbage collection begins only after both pointers are durable, re-reads the
live pointer immediately before each deletion, refuses every mount boundary,
and uses a durable tombstone so an interrupted exact-file unlink is resumable.

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
process scheduling controls, service success-status changes, and every global
`[Unit]` or `[Install]` directive, including aliases, manual start/stop, failure
actions, conditions, assertions, dependencies, and job timeouts. This deliberately includes accounting keys and
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
  `fivegpn-data` volume at `/etc/5gpn`, one `fivegpn-ui` volume at
  `/opt/5gpn/ui`, tmpfs runtime directories, every capability dropped, no new
  privileges, no Docker socket, and no host cgroup bind mount; and
- `init: false`, `restart: unless-stopped`, and a 45-second stop grace period.

The Docker data-plane listeners use the stable container coordinate
`0.0.0.0`; public and gateway addresses remain DNS/deployment identity rather
than container-interface bind targets. Container bootstrap retains the current
six-key installation-coordinate boundary and must not add the controller
secret, fixed listener paths, or certificate paths to `dns.env`. Compose
publishes `853/tcp`, `80/tcp`, `443/tcp+udp`, `8080/tcp`, and `8443/tcp`.
There is no product `:5060` listener. The public 443 mapping terminates at
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
acceptance run on a disposable target reached through `test-env`. The working
gateway's read-only deployment authorization does not authorize container
recreation, OOM injection, certificate mutation, or other Docker acceptance
writes.
The driver verifies that its Git root and `HEAD` are the requested candidate
and that every versioned pin-manifest, Compose, seccomp, driver, and probe
input is tracked and unchanged at that commit. Supplying a commit label to a
copied or locally weakened harness is not acceptance evidence.

The durable configuration and UI roots are independently locked for the
container lifetime. Existing operator YAML is accepted only through the
owner-scoped `5gpn-config inspect-controller --owner-uid` v2 projection, and
Core-owned documents only through `5gpn-state validate --owner-uid`. A data
volume created by container-runtime-v1 is rejected unchanged before bootstrap;
there is no in-place schema or volume migration.

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

Its only persistent source is the complete operator-owned
`/etc/5gpn/mihomo/config.yaml`. The installer never mirrors it into `dns.env`
and never parses or edits its YAML scalar with shell text tools. Root management
invokes the pinned binary's root-only
`5gpn-config inspect-controller --config <path>` mode and accepts exactly one
version-2 JSON object with seven fields: `version`, `raw_revision`, `secret`,
`external_controller_tls`, `external_ui`, `certificate`, and `private_key`.
The fixed controller, UI, and TLS paths must match the installation contract.
Inspection errors do not echo operator data. Each authenticated curl request
receives its bearer through a fresh inherited descriptor rather than argv, and
request-body stdin remains available.

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
`nosniff`, `no-referrer`, and a restrictive Permissions Policy. Zashboard can
still represent explicit HTTP(S) and WS(S) backends, so the connect policy
permits those schemes without permitting remote script execution; the managed
5gpn backend itself remains the fixed console origin.

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

Both profile files live in the complete generation selected by
`/opt/5gpn/ui/current`, and mihomo serves them beneath `/ui/` alongside
zashboard. `/opt/5gpn/www`, a flat `/opt/5gpn/ui` bundle, `WWW_DIR`, and any
separate web root are unsupported legacy footprints and must never receive a
current profile. Profile signing binds the exact DoT certificate generation,
key bytes, and interception-CA bytes before the first read and rechecks them
after both CMS payloads are complete. Each signature is verified and unpacked,
including the requested DoT domain/address and embedded CA digest, before the
candidate may become current.
The generation's exact profile-input manifest persists only public evidence:
the signer leaf and SPKI digests, interception-CA DER digest, requested domain
and gateway, and both CMS digests. The private-key file digest is used only in
the in-process anti-drift snapshot and is never written to the public UI tree.
Scoped renewal compares this manifest with the live lineage, DNS coordinates,
and interception CA even when the role copies already match, so a failed
best-effort profile refresh is repaired on the next renewal run.

## Control surface

`/capabilities` reports which subsystems are actually installed, with a schema
version each. A client that does not understand exactly that version treats the
feature as absent rather than rendering it — field meanings may have moved, and
showing an operator a status that might be wrong is worse than showing nothing.
A subsystem whose document failed to load does not advertise itself, so an
absent panel and an empty one mean different things.

`/5gpn/dns` is read and written whole so policy, upstream, subscription, and
tuning changes remain one revision-protected decision. The gateway address,
listener addresses, and certificate paths inside that document are
installation-owned and read-only through this API. A whole-document client
must round-trip them unchanged. Gateway or listener changes require a checked
installer operation and a complete process restart. Rejecting them before the
durable write prevents a port conflict from becoming a persistent systemd
restart loop and prevents a live resolver generation from disagreeing with the
dynamic gateway guard published at startup.

`/5gpn/interception` is the opposite, and for the same reason. Enabling an
extension authorizes a capture set, a script set, a storage grant and possibly
an unrestricted network grant; reordering decides which of two extensions owns
an overlapping host, and therefore which script acts on it, which egress binding
wins and which resolver group looks up its origin. A single endpoint taking the
whole document would make those indistinguishable from renaming something, and
the confirmation an operator gave would not correspond to any particular
decision. So each is its own write.

Each mutable runtime-document API quotes that document's revision and is
refused with `409` if the same document has moved, carrying its current
revision back so a client can re-read. This is an API optimistic-concurrency
contract, not a universal revision shared by installer, YAML, certificate, or
filesystem transactions.

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
position unusable. Filters never redefine the global sequence.

Version 7 retains those surfaces and makes the feature version the exact
operator review contract. Every installed-extension detail and every install or
Marketplace review candidate carries `review_contract: 7`. Its `actions` are
bounded, typed `ActionReview` projections: they identify the action, matchers,
gate, kind, body mode, timing and body limits, source form, and declarative
parameters. Script and JQ source text, manifest bytes, and mock response body
bytes are not returned; code is represented by its SHA-256 and byte count, and
a mock body by its kind, decoded length, and SHA-256. Each action also carries a
deterministic `review_digest` over its complete executable declaration,
including the digests of hidden code or body bytes. That action digest supports
an exact changed-action identity; the IDs, digests, and returned sequence support
the Console's added, removed, changed, and reordered presentation. Neither
replaces the candidate digest, reviewed source, document revision, or apply-time
refetch.

Four confirmation-bearing writes require the exact current contract before any
engine mutation: fresh install apply, Marketplace update apply, complete
execution-order replacement, and `enabled: true`. A missing, older, or future
value returns HTTP 400 and leaves revision and state unchanged. `enabled: false`
may omit the field so revocation remains available; null and zero are decoded as
the same absent value, while an explicitly sent nonzero stale or future version
is rejected. The Console treats a returned
contract as an untrusted number, renders no actionable review unless it equals
its compiled-in constant, and always sends that local constant rather than
echoing the server's value. A stale tab therefore either stops before issuing a
write or sends its old constant and is rejected by a newer core.

This control-plane change does not create a new persisted authorization epoch.
`intercept.json` remains current schema version 6, and an already enabled
current-schema snapshot remains authorized when a v7 core loads it. The v7 gate
applies to the next install, Marketplace update, reorder, or enable operation;
disabling that snapshot remains possible without a contract, while enabling it
again requires the current contract. A Console and core must still match the
feature version exactly; a client must not infer any of these routes or fields
from an older version.

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

Typed extension `REJECT` and `DIRECT` rules are part of that same derived
runtime plan, not an independently live rule set. While the certificate is
pending or in error, or the fixed client boundary is unavailable, both typed
decisions are withdrawn. A claimed HTTP(S) capture host remains rejected before
ordinary routing so it cannot bypass the authorization, while unrelated traffic
receives no extension decision and returns to the operator-owned rule set. Once
the certificate and boundary are ready again, the typed rules resume from the
same immutable document without a revision change or another operator write.

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
disable ordinary UDP forwarding or QUIC sniffing on other explicitly
operator-configured ports. Fresh and reset seeds do not create a `:5060`
listener or a product-managed ingress module.

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
routing-mark, managed secret, TLS certificate/private-key, and external-UI
changes are startup-only and `/configs` returns `409` instead of claiming they
became live. Other permitted plan changes are prepared before publication and
do not replace the fixed managed controller projection. New HTTP requests use
the current plan; already-authenticated WebSocket connections end on their
normal connection lifetime. An unexpected end of the current controller
listener is a monolith-fatal invariant.

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
`DNS_HEARTBEAT_INTERVAL` keys are unsupported legacy footprints and make
installer preflight fail before publication. An independent
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
installed path is `/etc/5gpn/mihomo/5gpn`; no alternate or historical state
directory name is accepted. Writes
are temp-file, fsync, rename, fsync-directory; the in-memory pointer is
published only after the rename, so a reader can never observe a value a crash
would un-observe. A document that fails to parse refuses to open rather than
resetting to defaults, which would discard the operator's extensions and policy
without saying so.

Updates carry the revision they were read at and are refused with
`ErrRevisionConflict` if it has moved. This is each runtime document's API
optimistic-concurrency boundary: it prevents two operators with the same page
open in two tabs from silently overwriting one another. Mutexes, atomic file
publication, installer locks, Nodes file locks, and certificate fences enforce
their separate ordering and durability contracts.

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
way to name the pair: a policy revision and the upstream/tuning state it was
reviewed against could become live in separate generations. It also put the
files the Console most needed to repair out of its reach. The
installation-owned gateway remains in this document so resolver answers and the
startup guard use one validated state generation, but controller writes must
round-trip it unchanged.

A missing `dns.json` is seeded with the same two subscription rules as the
pinned core default: ChinaMax domains with `direct` intent and the GFW list with
`proxy` intent, both refreshed every 24 hours. Their caches live in the
monolith's private `dns-rules` state directory. `/etc/5gpn/rules` is never a
current cache path.

`dns.env` contains exactly six installation inputs: `DNS_BASE_DOMAIN`,
`DNS_PUBLIC_IP`, `DNS_GATEWAY_IP`, `DNS_MIHOMO_LISTEN_IPS`, `CERT_MODE`, and
`CERT_EMAIL`. The DoT/debug/origin listeners, managed controller address, UI
root, and public certificate paths are fixed constants. The controller secret
belongs only to `config.yaml`; runtime policy, upstreams, subscription state,
resolver tuning, statistics, and heartbeat fields are not mirrored here.
Unknown or retired keys—including the wider pre-release environment schema—are
rejected; the installer never rewrites an older schema into the current one.
Before Gum or project-root publication, existing bytes undergo read-only root
metadata, exact-key, grammar, and value validation; after a fixed-root claim,
the same file is revalidated through the current marker boundary. The installer
lock is the only concurrent-writer contract for this file: one invocation reads
a single inode snapshot, binds publication to that revision, and checks it again
immediately before rename. Manual root edits that do not take the installer lock
must not run concurrently with install, reinstall, reset, or configure.
Historical `policy.json`, `upstreams.json`,
`ecs.json`, `subscriptions.json`, `stats.json`, `/etc/5gpn/rules`, and sidecar
documents are unsupported legacy footprints. The monolith never reads them,
and installer preflight reports them without modifying them.

`configure` is an installed-management transaction, not a release reinstall.
It requires the current owned `dns.env`, operator YAML, existing `dns.json`,
installed Core, runtime identity, unit, and filesystem boundaries; it never
downloads artifacts, installs dependencies, claims roots, creates accounts,
publishes binaries, scripts, units, or Console assets, or seeds a missing
document. The install lock is acquired before the installed-backend revision
check. The TUI collects and confirms one complete candidate before a missing
Cloudflare credential is held only in process memory. It is persisted only
after both the node-writer and certificate locks are held and certificate
selection, operator YAML, public DNS, `dns.env`, and `dns.json` pass the final
recheck. Configure never collects one for an external lineage or valid
preserved-role recovery. The operator YAML inode,
metadata, and raw revision remain pinned across that complete TUI interaction;
a concurrent edit is not adopted. A changing transaction also holds the
`config.yaml.5gpn-nodes.lock` used by the one-shot node writer. Pre-start Core
validation and a post-readiness revision check fence runtime activation;
ordinary active-service updates use systemd `try-restart`, so a concurrent
operator stop wins. An unchanged candidate writes nothing and does not restart
mihomo.

Changed fields have deliberately narrow effects. Certificate email changes
only `dns.env`. A production public-IP change passes the mode-aware public DNS
gate and changes only `dns.env`; in debug mode it also replaces the debug
certificate, republishes both roles, refreshes profiles, and restarts. A
gateway change prepares an unpublished profile generation, performs a
revision-checked update of only `dns.json.gateway`, updates `dns.env`, then
atomically publishes that profile generation and restarts; debug mode also reissues
the certificate because both configured IPs are part of its SAN contract. The
released controller API intentionally refuses that installation-owned field.
Every certificate-role publication, gateway CAS, and other runtime-affecting
configure write quiesces an active Core with one fail-on-conflict systemd
`TryRestartUnit` job. PID 1 performs the stop half, then the unit's first,
root-only `ExecStartPre` acknowledges a private configure nonce and blocks the
start half of that same job while publication is in progress. Configure never
issues a separate `StopUnit` followed by a later `StartUnit`.

The private record binds the nonce to the exact systemd job ID and object path,
its root control PID, and the unit invocation. The job remains the same object
while systemd changes its internal type from try-restart to start. The helper is
the unit's only privileged-exec-prefixed command; normal starts return from it
immediately. Its following unprivileged invocation runs the strict UI-current
validator. TERM is accepted as a clean pre-start exit only when the helper
proves that PID 1 currently owns this unit's `stop` job; a bare signal fails the
start and cannot bypass either pre-start check. A direct operator `systemctl
stop` replaces the pending restart in PID 1, terminates the current helper
cleanly, and remains inactive. Configure sees
that the exact job disappeared and never submits a replacement start. An
initially inactive service receives no configure-owned start job; the nonce
still prevents a concurrent external start from crossing the publication
boundary, and cleanup retains inactive state.

A retained gate before its matching release is recoverable only while the exact
original blocked job, acknowledgement, control PID, and pre-publication
restoration entitlement all still agree. Recovery releases that job rather than
creating another one. Once any certificate role, `dns.json`, `dns.env`, or UI
`current` publication is visible, that entitlement is revoked and a pre-release
crash keeps the unit inactive. A durable matching release is the activation
commit: all selected inputs are already visible, so recovery may let only the
same exact job finish after revalidating the token, ACK, current inputs,
readiness, final `active/running` state, positive MainPID, zero ControlPID, and
absence of another systemd job. Failed, timed-out, or deactivating activation is
cleaned to inactive and reported as failure. Cleanup first atomically changes
the owned record to a closing state, so a concurrent start cannot publish a
record-less acknowledgement while subordinate state is removed. An interrupted
close resumes only while inactive. The latest complete document, writer
quiescence, and exact blocked job are revalidated before the file CAS. HTTP-01
configure uses the same outer job and never starts or stops mihomo from inside
Certbot; certificate roles, the prepared profile, coordinates, and final
runtime inputs complete before the single activation release. Before any other mutating full-install,
management, reset, certificate, profile, or uninstall entry can publish files
or call systemd, it read-only rejects retained named or temporary gate state
and directs the operator to the installed `5gpn configure` recovery path.
Read-only status remains available; no alternate entry guesses that a retained
gate is safe or deletes it as unrelated residue. A
listener change requires the operator YAML to already match, then updates
`dns.env` and restarts. Base-domain or certificate-mode changes run the DNS,
certificate, role, profile, environment, and restart boundaries. Only a
service that is stably active is restarted. An inactive service remains
inactive, a stop observed while the TUI is open wins, and a failed or
transitioning unit rejects configuration instead of being described as an
operator stop.

`config.yaml` remains fully operator-owned.
The installer never renders the `dns.json` gateway into that file as an
`IP-CIDR` rule. At startup the Core derives a dynamic anti-loop guard from the
installation-owned gateway and applies it only to private 5gpn system and
extension tunnel carriers. Ordinary client ingress and generic mihomo `INNER`
traffic are unaffected. A checked gateway change takes effect after the
required full process restart without rewriting operator rules.

The Docker deployment maps two local named volumes. `fivegpn-data` at
`/etc/5gpn` persists operator configuration, monolith documents, public
certificate lineage and role copies, interception CA and leaf, and ownership
markers. `fivegpn-ui` at `/opt/5gpn/ui` persists the complete Console/profile
generation tree. The image root is read-only; `/run/5gpn`, the secured
bootstrap copy, `/tmp`, and `/var/tmp` are tmpfs. A fresh container publishes
the pinned Console and profiles as one complete `/opt/5gpn/ui/current`
generation. It may seed missing current-schema files,
but the controller secret is written only to operator-owned `config.yaml`,
never `dns.env`. Before runtime start the pinned Core validates the exact
controller projection and any existing `dns.json`, `intercept.json`, and
`bot.json` files through its one-shot modes; container shell code does not carry
a parallel schema decoder. Existing files are preserved and validated under
the same metadata and atomic-publication rules. The fixed numeric `fivegpn`
UID/GID is therefore part of both Docker volume ABIs and may not drift between
image tags. A container-runtime-v1 data volume, extra `dns.env` keys, a flat UI
tree, or retired document schemas are unsupported footprints rejected
unchanged rather than automatic migration inputs.

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

Public-certificate source state has two independent records. `.provenance`
names only the source currently selected for the role copies; it is not a
history of Certbot ownership. `.certbot-ownership` is the deletion and renewal
authority for exact base-domain lineages. Selecting debug writes
`debug:none` without erasing that independent ownership record. Returning to
the same production base may reuse the canonical owned lineage only when the
ownership record still names that base, the current selection is either that
same owned production mode or same-base debug, and the live certificate,
private key, production ACME server, authenticator, credential path, and
live/archive paths all match the requested mode. No Certbot issuance occurs on
that path. A mismatched current base, mode, source, or ownership record cannot
authorize reuse.

A canonical lineage with no matching ownership record remains external. It may
be selected only through the same strict certificate and renewal fingerprint,
is copied through the common role publisher, and never gains deletion or
renewal authority. Because `.provenance` names the source currently copied into
the roles, an old base or production mode does not block selecting a different
strictly validated external lineage. External and debug selection do not pause or take over the
distro Certbot timer; external renewal remains responsible for the canonical
lineage, while the 5gpn deploy hook updates only the role copies. The
`missing` state continues to mean a preserved role-copy fallback with renewal
disabled and is not lineage history. A repaired canonical lineage is classified
again from its current strict fingerprint and the exact-base ownership record;
`missing` alone authorizes neither owned nor external renewal.
Explicit lineage decommission validates the complete owned lineage, first
withdraws current owned-renewal provenance, then revokes and syncs the
exact-base ownership entry before invoking Certbot deletion. A crash or
Certbot failure after either withdrawal leaves a present lineage
read-only/external and never transfers stale authority to a future same-named
lineage; neither change is rolled back. An already absent lineage with a
retained stale entry is marked missing and cleaned without invoking Certbot.
The installed certificate publication helpers remain present until role,
debug-certificate, credential, and interception-CA decommission has finished;
runtime cleanup cannot remove the helpers that prove those deletion boundaries.

Service status is provenance-aware. An inactive 5gpn-owned Certbot timer is an
error; a debug certificate has no applicable renewal timer; a reused external
lineage remains externally renewed; and `missing` provenance requires repair.
Owned status is healthy only when the configured base and mode, current
provenance, and exact-base ownership record agree. An owned/external mismatch
is a persistent repair state and never borrows an active timer's healthy mark.
Each displayed systemd unit is queried at most once per rendered snapshot.

## Installation compatibility boundary

The installer supports exactly two starting states: a fresh host with no 5gpn
footprint, or a deployment already produced by the current schema. A current
reinstall uses `5gpn-mihomo.service`, `/opt/5gpn/bin/5gpn-mihomo`, the single
`fivegpn:fivegpn` identity, `/etc/5gpn/mihomo/5gpn`, the exact current `dns.env`
key set, and current `dns.json`, `intercept.json`, and `bot.json` schemas. A
normal channel transition preserves a valid operator-owned `config.yaml` byte
for byte. Explicit `mihomo-reset` remains a current-schema reset, not a
conversion mechanism.

Compatibility preflight completes before any managed 5gpn service is stopped,
managed account or unit is changed, project certificate is issued, or live 5gpn
file is published. It performs read-only inspection and reports every
conflicting footprint. It never stops, renames, deletes, rewrites, imports,
adopts, or changes permissions on legacy state. Host dependency installation is
a separate pre-publication step and may change distribution package state.

The installer does not independently decode the three Core-owned document
schemas. After downloading and digest-verifying the pinned Core into staging,
it first validates the exact controller-inspection v2 projection of the fresh
seed or existing operator YAML, then runs that binary's `5gpn-state validate`
one-shot mode against the absolute
state directory, with `--owner-uid` set to the proven current `fivegpn` UID or
the old UID recorded by an interrupted reconciliation journal. The command only
reads `dns.json`, `intercept.json`, and `bot.json`; missing documents are valid
fresh-seed inputs and are not created. Any present document must be a no-follow
regular file owned by that UID, mode `0600`, singly linked, and satisfy the exact
schema implemented by the Core that will be published. A group-only identity
journal can resume only when all three documents are absent; any present
document requires a proven current or journaled UID. Validation finishes before
project-root claims, managed 5gpn account/service changes, or live 5gpn file
publication. The staged binary is never executed as a service during this
check. The steady state root is service-owned mode `0711`. A fresh mkdir below
the setgid mihomo home may be interrupted with the otherwise exact `2711`
shape; that narrow residue is accepted only as current reconciliation input,
sealed before mutation, and normalized to `0711` before document publication.

The exact non-sensitive top-level roots `/opt/5gpn`, `/etc/5gpn`,
`/var/lib/5gpn`, and `/var/lib/5gpn-intercept` are installation coordinates,
not content-provenance claims. When one has no ownership marker, the installer
may claim its existing contents only after canonical-path, top-level metadata,
known-legacy, symlink, hardlink, special-entry, and nested-mount checks pass. An
existing invalid or retired marker is refused rather than replaced. Certificate
roots, the interception CA, the UI tree, and temporary paths keep their stricter
ownership requirements. Every recursive deletion still revalidates the current
marker and nested-mount boundary.

Unsupported footprints include any definition of generic `mihomo.service` or
retired `5gpn-dns.service`, `5gpn-intercept.service`,
`5gpn-intercept-runtime.path`, `5gpn-journal@.service`,
`5gpn-journal@5gpn-dns.service`, or `5gpn-journal@mihomo.service`; a generic
`mihomo` user or group; old `gpn-dns`, `gpn-intercept`, or overlay-group
identities; an unprefixed runtime binary; `/etc/5gpn/mihomo/gpn`,
`/opt/5gpn/www`, a flat UI tree or operator config naming
`external-ui: /opt/5gpn/ui`, standalone resolver state, sidecar configuration, or old rule
caches; retired `dns.env` keys or document schemas; a `web` certificate role;
and mihomo constructs such as
`RUNTIME-OVERLAY,5gpn,*`, `runtime-overlay-processor`, `intercept-egress`, or
`MODULE-INTERCEPT`.

The current `fivegpn` name has a narrower recovery rule and is never adopted by
name alone. If an existing identity is incompatible, repair is allowed only
when either a safe current root marker or the marked current
`5gpn-mihomo.service` definition proves it belongs to this installation. Every
existing UID and GID must be below the host's normal-user threshold and must be
exclusive to `fivegpn`. Read-only preflight grants only an in-memory repair
authorization. After the installer crosses its declared publication boundary
and before deleting a proven current identity, it durably records the old
numeric IDs; after an interruption, the next run resumes from that journal,
recreates the system identity, and reconciles only validated managed roots
before clearing it. Even when the crash happened
after account deletion, safe current marker or unit provenance must still be
present, the current journal must validate, and the recorded system-range IDs
must remain unclaimed by any other identity; an exact surviving `fivegpn` group
may retain its recorded GID. The journal is recovery state rather than ownership
proof. A same-named identity without current provenance, a normal-range ID, an
alias, shared membership, or an unsafe journal is a hard read-only refusal.

Finding any such footprint is a hard pre-publication error. The operator must
explicitly decommission or rebuild the host outside the installer and then
begin a fresh installation. 5gpn provides no in-place legacy migration,
retired-component teardown, state salvage, schema conversion, or compatibility
alias.

## Verification boundary

Changes are tested in proportion to their surface. In the mihomo repository,
`go build ./...` and `go test -race ./5gpn/...` must be green. This root
repository's `tests/` directory holds the installer suites, which are shell and
must be run under Linux against an LF checkout.

The root release gate downloads the exact digest-pinned Core and invokes its
`5gpn-state validate --owner-uid` command against missing, valid, malformed,
wrong-owner, wrong-mode, symlink, and hardlink fixtures. A fake executable in a
shell unit test checks argument plumbing only and cannot prove that the pinned
release contains the one-shot mode.

Acceptance is split by repository ownership and mutation risk. The root
[acceptance index](../tests/integration-smoke.md) is routing documentation, not
one executable mega-checklist. The root repository owns installed artifact
binding, installer publication, host ownership, systemd and listener policy,
public UI/profile delivery, certificate helpers, and their cross-repository
integration.

The root [deployment smoke](../tests/deployment-smoke.md) is strictly read-only.
It may run on an explicitly designated working gateway, but it performs no
controller write, installer or management mutation, service signal or restart,
host-file write, lock occupation, certificate issuance, package action, or
fault injection. Ordinary DNS and HTTPS probes may populate bounded in-memory
caches and logs just like client traffic; durable configuration, process
identity, restart count, and file hashes must remain unchanged.

Installer mutation and recovery/failure injection are separate
**disposable-only** runbooks:
[installer acceptance](../tests/acceptance/installer.md) and
[disruption/recovery acceptance](../tests/acceptance/disruption-recovery.md).
They are never run on a working gateway. A failure before project publication
must leave managed state untouched except for separately reported shared
distribution package effects; a failure after publication begins is accepted
only as an explicitly reported partial installation, never as an automatic
rollback claim.

Mihomo-internal runtime behavior is owned by the immutable acceptance documents
at commit
[`aba0cfcea5ebeda580ab63e174fd17146c3ef962`](https://github.com/moooyo/mihomo/tree/aba0cfcea5ebeda580ab63e174fd17146c3ef962/acceptance).
Console rendering and interaction behavior is owned by the immutable zashboard
runbook at commit
[`cf3d018ffa20eae0297c434b7a185b0d69f43b66`](https://github.com/moooyo/zashboard/blob/cf3d018ffa20eae0297c434b7a185b0d69f43b66/docs/5gpn-console-acceptance.md).
That runbook permits some restored controller mutations on an explicitly
designated current-schema gateway, but root release/acceptance scheduling does
not inherit that permission. Every zashboard controller mutation dispatched by
the root acceptance flow is disposable-only; a planned restore does not make a
write read-only or authorize it on a working gateway.
The root acceptance runbooks do not duplicate their DNS-engine, worker,
extension, Marketplace, responsive-layout, or browser-interaction assertions.

Every acceptance run records exact release tags, Git commits, artifact and
fixture SHA-256 values, host or image identity, timestamps, and skipped checks.
A branch name, moving tag, unqualified image tag, raw `main` or `beta` URL, or
extension input without a recorded length and digest is not an acceptance
input. A real gateway reachable as `test-env` may be used only for the
read-only deployment class; all mutating and fault-injection work uses a
disposable target.

Docker adds one release gate without weakening that safety split. Hosted CI may
prepare the bound components, build the `linux/amd64` image, and inspect static
contents, but it cannot prove writable cgroup delegation. The exact candidate
therefore runs on a disposable Engine 28, cgroup-v2 target reached through
`test-env`, never on the working gateway. That acceptance covers the real
startup probe, an extension worker operation, worker OOM containment,
authenticated capability version 7, certificate hot publication, container
recreation, and persistence across both named volumes. Publication fails
closed unless
`FIVEGPN_CONTAINER_ACCEPTED_COMMIT` and
`FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256` match the exact tag commit and its
current `release/pins.env` Core digest, and
`FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID` matches the reproducibly rebuilt image.
No hosted-runner fallback or historical development result may satisfy these
coordinates.

The merged root implementation requires runtime-v2, but the currently pinned
Core `.32` does not provide that handshake. The deployment-neutral Zashboard
setup wording also remains unpublished and unpinned. Until immutable compatible
Core and Console releases replace both coordinates in `release/pins.env`, the
Docker release gate is expected to fail closed.
