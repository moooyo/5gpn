# 5gpn

[简体中文](README.md) | [English](README.en.md)

**5gpn is a DoT-only DNS-steering gateway for clients with routable IPv4 connectivity.**
It uses DNS answers to decide whether a connection should be blocked, made directly by the client, or sent to the gateway. Once traffic reaches the gateway, the operator-owned mihomo configuration controls application-layer egress. Android and iOS can use their native DoT support without a resident client app.

> [!IMPORTANT]
> This project is pre-release. This document describes the current source tree; the quick installer deploys the latest published tag, so released functionality may temporarily lag behind `HEAD`. Check [Releases](https://github.com/moooyo/5gpn/releases) before deployment.

> [!WARNING]
> Manage only networks and traffic you are authorized to control. Optional native extensions can decrypt and modify traffic after a device trusts the private CA; understand their permissions and disclosure risks before enabling them. The software is provided under the [MIT License](LICENSE).

## What 5gpn is

5gpn keeps DNS decisions distinct from application-traffic egress inside one
long-running process:

- The `moooyo/mihomo` fork is the entire runtime: DoT DNS policy, forwarding,
  native-extension interception, Telegram, and the authenticated controller.
- zashboard is the static Console mihomo serves at `https://console.<base>/ui/`.
- This repository contains the host installer/operator TUI and Docker image
  assembly, but no runtime or Console source. Both delivery paths consume the
  same digest-pinned mihomo and zashboard release artifacts.

It is not a VPN, full tunnel, or default router. It includes no proxy nodes and does not install or manage TUN, TProxy, WireGuard, NAT, fwmarks, policy routing, or a host firewall. The only client DNS ingress is DoT on `:853`; there is no public DoH or client-facing plain DNS on `:53`.

## How it works

```text
Android Private DNS / iOS configuration profile
                       |
                       | DoT :853
                       v
                    mihomo
             ordered DNS policy
          block / direct / proxy + fallback
              /                    \
     real origin IPv4          gateway IPv4
            |                       |
            v                       v
        client direct          in-process tunnel and rules
                                      |
                         optional HTTP/TLS capture hook
                                      |
                    isolated one-shot goja workers
                                      |
                       operator binding / terminal target
                                      |
                               operator egress
```

DNS policy is one globally ordered, first-match rule list:

| Decision | DNS result | Subsequent path |
| --- | --- | --- |
| `block` | `NXDOMAIN` | The client makes no connection |
| `direct` | Adopted real IPv4 address | The client connects directly to the origin |
| `proxy` | Gateway IPv4 address | Client → mihomo → operator-configured egress |
| `auto` fallback | Adopt China when its answer contains a `chnroute` A, otherwise adopt trust; keep `chnroute` A records in the adopted reply and rewrite the rest to the gateway | Deterministic adoption and per-A rewriting, never whichever response arrives first |
| `direct` fallback | Adopted real IPv4 address | Direct regardless of the `chnroute` result |
| `gateway` fallback | Gateway IPv4 address | Enter the gateway without querying an upstream |

The table describes successful A answers. When adopting or rewriting an upstream response, 5gpn preserves its Rcode and authority data; `NXDOMAIN` and `SERVFAIL` never become `NOERROR`.

`auto` queries the China and trust upstream groups concurrently. Members within each group are attempted sequentially in configured order with fair slices of the remaining deadline. Fresh installations seed `223.5.5.5:53` and `22.22.22.22:53` into `/etc/5gpn/mihomo/5gpn/dns.json`, the atomic source of truth for DNS policy and upstreams, after which the Console can hot-apply a revision-protected whole-document update. A member of either group declares its transport by spec form: a bare `IP[:port]` is plain UDP, `serverName@IP[:port]` is DoT, and `https://host/path@IP[:port]` is DoH over a pooled HTTP/2 connection. Transport is a per-member property, so one group may mix all three. Plain UDP carries no query-name anti-spoof mechanism, so prefer DoT or DoH wherever the resolver offers it. A queries follow the policy above; AAAA, HTTPS, and SVCB return NODATA with authority data. Other types go to the trust group with AAAA, HTTPS, and SVCB records removed from every section before the reply is cached or returned.

The AAAA NODATA is not client-only. After mihomo sniffs a hostname it re-resolves the origin through the loopback resolver on `127.0.0.1:5354`, which returns the same synthetic NODATA before consulting any upstream. That boundary is what actually keeps egress on IPv4: mihomo issues an AAAA query for every origin unconditionally, its `dns.ipv6` setting does not suppress it — only the top-level `ipv6` key does — and `/etc/5gpn/mihomo/config.yaml` is fully operator-owned, so no seed value can be assumed present. If the AAAA were forwarded, mihomo would learn the origin's real IPv6 addresses and race them against the IPv4 ones; once the IPv6 leg completes its TCP handshake the dual-stack fallback no longer fires, and a destination that refuses or mislocates the gateway's datacenter IPv6 prefix then fails at the application layer with nothing left to fall back to. With NODATA, mihomo has only IPv4 candidates. The trade-off is accepted deliberately: an origin published only as AAAA — or an operator node configured by hostname — is unreachable through the gateway, and on an IPv4-only data plane an IPv6 answer would not have been dialable either. Fresh and explicitly reset mihomo seeds additionally set `ipv6: false` as defence in depth.

When both the MITM master and an extension are enabled and active, the capture-host overlay steers matching names to the gateway before operator DNS rules. It still cannot select a mihomo node or group. Extension egress and capture-DNS bindings belong to a separate, confirmed data-plane transaction.

## Core capabilities

- **DoT-only access**: Android Private DNS and iOS profiles use `dot.<base>`; the local debug DNS listener is confined to `127.0.0.1:5353/udp`.
- **Auditable DNS policy**: exact, suffix, keyword, and subscription matchers feed one ordered set of `block`, `direct`, and `proxy` rules plus one fallback.
- **Operator-owned data plane**: the complete mihomo YAML has no daemon-generated region; normal install, reinstall, and `configure` preserve a valid file byte for byte.
- **Unified control plane**: zashboard covers status, setup, DNS logs and diagnosis, policy, upstreams, mihomo health and configuration, extensions, marketplace discovery, and logs. The Telegram bot is read-only and alert-only.
- **Optional native extensions**: strict `5gpn.io/v1` snapshots, explicitly declared exact and constrained-wildcard capture-host allowlists, typed settings, permission review, explicit execution order, and a non-empty operator egress binding that defaults to `DIRECT`.
- **Checked installation**: exact tags, SHA-256 verification, staging, atomic file publication, and readiness probes. Publication begins when the installer starts claiming its durable project roots; failures before that phase run no publication step, while later failures are reported as potentially partial. No Go or Node toolchain is installed on the gateway.

## Requirements

Before you start, provide:

- A host installation requires Linux amd64, kernel 5.7 or newer, systemd 257
  or newer, a pure cgroup v2 hierarchy with the memory and pids controllers,
  and root access. The installer checks this isolation baseline before project
  publication and directly supports apt or dnf/yum systems.
- Docker is a separate narrow baseline: Linux amd64, rootful Docker Engine 28
  or newer, pure cgroup v2, the systemd cgroup driver, and no daemon
  `userns-remap`. The first release does not support rootless Docker, Docker
  Desktop, SELinux enforcing, or arm64.
- The quick installer requires `flock` and `findmnt` from `util-linux` before it creates any installer files. Minimal images must install it first with `apt-get install -y util-linux`, `dnf install -y util-linux`, or `yum install -y util-linux`.
- An interactive TTY for the first installation. `curl | sudo bash` attempts to reattach `/dev/tty`; a first install without a TTY fails closed.
- At least one non-loopback IPv4 address assigned to a local interface and routable from clients. The 5gpn steering path is IPv4-only; IPv6-only clients cannot reach the gateway unless the network provides IPv4 reachability such as CLAT.
- A base domain you control. The system derives `dot.<base>` and `console.<base>`.
- Production modes require an A record for `console.<base>` pointing to the public or otherwise client-routable gateway IPv4; `debug` skips the public DNS gate. Before Android enables Private DNS, `dot.<base>` must also resolve through the client's existing resolver.
- A cloud security group or independently managed firewall that restricts ingress. 5gpn never creates, changes, or removes host firewall rules.

Three IPv4 settings have distinct roles on a host installation. Docker fixes
its internal listeners at `0.0.0.0` and Compose explicitly publishes the
standard host ports into the container:

- `DNS_PUBLIC_IP` is the deployment's public identity and HTTP-01 A-record target;
- `DNS_GATEWAY_IP` is the client-routable gateway address returned in steered DNS answers;
- `DNS_MIHOMO_LISTEN_IPS` lists the non-loopback IPv4 addresses mihomo actually binds on the host and normally includes `DNS_GATEWAY_IP`. Never use an address that exists only outside NAT as a local bind address.

### Deployment ingress

TCP `853` is mihomo's fixed client DNS ingress. The remaining data-plane listeners belong to a fresh or explicitly reset mihomo seed; an existing valid operator-owned YAML remains authoritative.

| Port | Purpose |
| --- | --- |
| TCP `853` | The only client DNS ingress (DoT) |
| TCP `443` | Console HTTPS and DNS-steered TLS/HTTP traffic |
| TCP `80` | DNS-steered HTTP; also required for HTTP-01 challenges |
| TCP `8080`, `8443` | Explicit alternate Web ingress that requires a visible HTTP Host or TLS SNI |
| UDP `443` | Remains bound; one fixed global rule rejects gateway UDP/443 so capable clients can fall back to TCP |

Expose only what you need. The UDP/443 guard is not a firewall rule, does not close the socket, and cannot guarantee that every client falls back. Product management cannot disable it; an H3-only client fails.

## Certificate modes

The host installer's first-install TUI asks for one of the following modes. Both production
modes use one scoped Certbot lineage named `<base>` and deploy it to the only
current public certificate roles: `dot` and `console`.

| Mode | Certificate and DNS requirements | Renewal behavior |
| --- | --- | --- |
| `cloudflare` | DNS-01; SANs are `<base>` and `*.<base>`; requires a token limited to `Zone:DNS:Edit`. When queried through the fixed resolver `1.1.1.1`, `console.<base>` must return only one A, without a CNAME, pointing to `DNS_PUBLIC_IP` or, for a private deployment, `DNS_GATEWAY_IP` | Does not stop mihomo |
| `http-01` | When queried through the fixed resolver `1.1.1.1`, `console.<base>` and `dot.<base>` must each return only one public A equal to `DNS_PUBLIC_IP`, without a CNAME or any AAAA, and public TCP `80` must be reachable | Initial issuance stops mihomo only when it was active; failure or a signal restores it immediately, while success leaves restoration to the install flow after the lineage and role certificates are fully published. Renewal when due briefly releases `:80` and restores mihomo after success or failure |
| `debug` | Isolated self-signed certificate, no Certbot, and not trusted by clients by default | Testing only |

The Cloudflare token is written only to `/etc/5gpn/acme/cloudflare.ini`, which is root-only; it never enters `dns.env`, the caller environment, or logs. Optional interception uses a completely separate private root CA and never replaces the public DoT or Console certificate.

Docker is fixed to Cloudflare DNS-01. The `cloudflare_api_token` Compose secret
becomes a mode-`0600` Certbot credential only in the `/run` tmpfs; one `<base>`
lineage requests `<base>` and `*.<base>` and publishes the `dot` and `console`
roles. Docker rejects `http-01`, `debug`, and an unknown `CERT_MODE`.

## Quick install

Install the latest official release:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
```

Explicitly switch to a beta whose base version is newer than the latest
official release; an older public beta is refused rather than installed:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
```

From a checkout, use:

```bash
sudo bash install.sh
sudo bash install.sh --beta
```

The source installer first resolves and delegates to one verified, exact 5gpn
release bundle. That bundle carries independent mihomo and zashboard release
tags, asset templates, and SHA-256 pins in one strictly parsed
`release/pins.env`; the same bundle installs that manifest and its URL builder
under `/opt/5gpn/release`. Component artifacts therefore cannot drift from the
scripts and templates that install them. The default channel accepts only `X.Y.Z`;
`--beta` accepts only a published `X.Y.Z-beta.N` whose base version is newer
than the latest official release. It never falls back and never downgrades to an
older beta line.

The first installation collects configuration through the TUI and atomically writes the exact six-key `/etc/5gpn/dns.env`. A reinstall is supported only when the existing deployment already uses the current identity, paths, keys, and document schemas; it reads only that file and never treats the caller environment as configuration input. Before stopping a managed 5gpn service or publishing a live 5gpn file, preflight rejects any legacy unit definition, account, group, binary, state tree, configuration key, document, certificate role, or mihomo rule footprint. A generic `mihomo` user or group is always such a conflict. That check is read-only: the installer does not rename, remove, rewrite, or adopt legacy state. Host dependency installation is a separate pre-publication step and may update distribution packages. The staged, digest-pinned Core must pass both its exact root-only `5gpn-config inspect-controller` v2 contract and `5gpn-state validate --owner-uid` contract before publication. Existing runtime documents are validated by that Core, so shell code does not duplicate its decoder/validation rules and validation cannot follow or adopt files with the wrong owner, mode, or link count. Exact non-sensitive installation roots may claim a safe populated directory with no marker after canonical-path, metadata, legacy, symlink, hardlink, special-file, and nested-mount checks; certificate, CA, UI, and temporary roots remain strict. A failure during publication is reported as a partial installation rather than hidden behind a rollback claim.

A missing `dns.json` enables two built-in 24-hour subscriptions: ChinaMax
domains with `direct` intent and the GFW list with `proxy` intent. Mihomo fetches
them into its private state directory; the authenticated Console can disable,
replace, or reorder them.

## Docker

Docker runs the complete gateway, not a reduced feature set: DNS, forwarding,
Console, Telegram, and native extensions remain in the same `5gpn-mihomo`.
Delivery is fixed to one image, one container, and one Compose service;
certificate operations are trusted short-lived helpers synchronously started
and waited by the entrypoint or monolith. Image assembly requires the exact
`5gpn-container-runtime-v2` Core handshake.

Extract Compose, seccomp, the bootstrap example, and the
[Docker runbook](docs/docker.md) from the same tag's
`5gpn-installer.tar.gz`; no source checkout is required. Copy the bootstrap
template and fill in the base domain, client-routable gateway IPv4, and email.
The controller secret persists only in operator-owned `config.yaml`; fresh
bootstrap generates it into that YAML and must never write it to `dns.env` or
the bootstrap configuration. The Cloudflare token file must contain only the
token:

```bash
cp docker/bootstrap/config.env.example docker/bootstrap/config.env
${EDITOR:-vi} docker/bootstrap/config.env
install -m 0600 /dev/null docker/bootstrap/cloudflare_api_token
${EDITOR:-vi} docker/bootstrap/cloudflare_api_token
sudo chown 10001:10001 \
  docker/bootstrap/config.env docker/bootstrap/cloudflare_api_token
sudo chmod 0600 docker/bootstrap/config.env docker/bootstrap/cloudflare_api_token
```

Confirm Engine 28+, cgroup v2, and the systemd driver, then take the complete
`tag@sha256` reference from the `OCI image:` line in the selected GitHub
Release body. Only a Release that records that reference has a matching Docker
image. Stable publication updates the convenience registry alias `latest`, but
deployments must not use that movable alias; beta never updates it:

```bash
docker version --format '{{.Server.Version}}'
docker info --format '{{.CgroupVersion}} {{.CgroupDriver}}'
TAG=X.Y.Z
IMAGE_DIGEST=sha256:REPLACE_WITH_RELEASE_MANIFEST_DIGEST
export FIVEGPN_IMAGE="ghcr.io/moooyo/5gpn:${TAG}@${IMAGE_DIGEST}"
docker compose pull gateway
docker compose up -d gateway
docker compose logs -f gateway
```

Compose uses a bridge network with explicit IPv4 port publication, a private
cgroup namespace, `writable-cgroups=true`, and the repository's seccomp
profile. The loopback controller owns container port `443`, so public `443`
maps to the data-plane socket on `9443`; the other public ports map to the same
container port. It needs no `privileged`, added capability, `SYS_ADMIN`, Docker
socket, or host cgroup bind mount. Durable storage is split between
`fivegpn-data:/etc/5gpn` and `fivegpn-ui:/opt/5gpn/ui`; the image root is
read-only and only `/run` and scratch directories are tmpfs. The UI volume
durably publishes the Console and both profiles as one complete
`/opt/5gpn/ui/current` generation. Durable `dns.env` retains exactly the
current six installation coordinates. The pinned Core validates existing
runtime documents through `5gpn-state validate --owner-uid` and operator YAML
through owner-scoped `5gpn-config inspect-controller --owner-uid` v2.
Volumes produced by the retired container-runtime-v1 layout are rejected
unchanged and have no in-place migration path. To upgrade a future v2
deployment, change `FIVEGPN_IMAGE` to the complete `tag@sha256` reference from
the new Release body, then run `pull` and `up -d` again. Do not run
`docker compose down -v` unless you intend to remove configuration, ACME state,
the interception CA, Console generations, and both signed profiles.

> [!WARNING]
> The simplified single-container form intentionally weakens certificate-key
> isolation. The same `fivegpn` identity can read the Cloudflare token, ACME
> account, public private keys, and interception CA private key. Worker cgroup
> isolation remains a mandatory startup invariant; authorized extension code
> still never runs in the main process, but the Docker container is not a
> security boundary between these trusted keys.

## After installation

Start by checking service state:

```bash
sudo 5gpn status
```

Run a minimal service and configuration check:

```bash
sudo systemctl is-active 5gpn-mihomo
sudo /opt/5gpn/bin/5gpn-mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo
```

The installer owns one Unix service identity, `fivegpn:fivegpn`. DNS,
interception, Telegram, and forwarding all run inside `5gpn-mihomo.service`;
there are no separate `gpn-dns`, `gpn-intercept`, or unprefixed `mihomo`
service accounts. All external product names remain `5gpn`; this spelled-out
identity is the only exception because portable Linux/POSIX account names
cannot begin with a digit.

A pre-existing `fivegpn` name is not automatically adopted. An incompatible
identity can be repaired only when a safe current ownership marker or the
marked current main unit proves provenance, all existing UID/GID values are
exclusive system-range IDs, and the old numeric ownership is durably journaled
before removal. Preflight only authorizes this recovery in memory; journal and
account mutation begin only after the declared publication boundary.
Interrupted reconciliation resumes from that journal. A
same-named identity on a fresh host, a normal-range ID, or any shared/aliased ID
is rejected without mutation. If the crash happened after account removal,
recovery still requires the current marker/unit provenance and recorded IDs
that remain safe and unclaimed by any other identity; an exact surviving
`fivegpn` group may retain its recorded GID. A journal alone is not ownership
proof. Group-only journal recovery is possible only when all three runtime
documents are absent; any present document requires a proven current or
journaled owner UID.

### Process recovery

mihomo is the sole long-running process and therefore the gateway's single
failure domain. Expected extension exceptions, timeouts, and network failures
fail only the current operation. A critical listener failure, escaped panic, or
other unrecoverable runtime failure exits the process. The shipped systemd unit
restarts any unexpected exit after three seconds and limits repeated starts to
ten within 60 seconds. The unit then remains failed, and the limit action is
explicitly `none`, so a crash loop cannot reboot or power off the host. Existing
connections are lost during a successful restart.

On a host, systemd owns that process replacement. In Docker,
`restart: unless-stopped` replaces the whole container; there is no in-container
systemd, init, cron, sidecar, or supervisor. The synchronous entrypoint ends
with `exec 5gpn-mihomo`, making mihomo PID 1. `/restart`, SIGTERM, and fatal
paths perform one complete orderly shutdown before Docker replaces the failure
domain. Compose allows that path 45 seconds before forced termination.

Extension code is the deliberate process-isolation exception, not another
long-running component. Each validation and action starts the same
`5gpn-mihomo` binary in a one-shot worker mode below a dedicated cgroup-v2
memory limit. Worker-manager construction and its hard-isolation probe are an
unconditional startup invariant: failure terminates monolith startup before DoT,
the controller, or another listener is opened. After that probe succeeds, a
single child start error, timeout, crash, or OOM fails only its validation or
action while the main process remains live. Extension code is never executed in
the main process. On a host, stopping the systemd unit removes all workers with
the main process; in Docker, stopping the container does the same. At most two workers run concurrently.
Each Linux worker has `memory.max=536870912`, `memory.swap.max=0`,
`memory.oom.group=1`, and `pids.max=32`; the admitted aggregate upper bounds are
1GiB and 64 tasks. These are caps, not reserved memory or a physical-RAM
minimum; deployment sizing must still leave capacity for the main gateway and
the host. `RestrictNamespaces=` is intentionally absent from the main unit:
systemd 257 blocks all `clone3` calls when it applies that seccomp policy, while
Go's cgroup-FD spawn requires `clone3(CLONE_INTO_CGROUP)`. The unit still denies
`unshare` and `setns`; the runtime startup probe makes failure fatal before any
gateway listener becomes available.

This is process recovery, not self-healing: a persistent bad configuration,
port conflict, or broken certificate remains an operator-visible failure. A
deliberate `systemctl stop 5gpn-mihomo` stays stopped. Use an independent external
monitor that actively probes DoT and HTTPS. Retired `DNS_HEARTBEAT_*` keys are
unsupported legacy footprints and make installer preflight fail before publication.
The DNS gateway, listener, and certificate-path fields are installation-owned;
controller writes must preserve them exactly and are rejected before
persistence if they attempt to change them. The gateway anti-loop boundary is
dynamic Core state, not an `IP-CIDR` rule in operator YAML.

Then verify DNS with a `dig` build that supports DoT:

```bash
DOT=dot.example.com
GW=203.0.113.10
dig +tls @"$GW" -p 853 example.com A +tls-host="$DOT"
dig @127.0.0.1 -p 5353 example.com A
```

Replace the example domain and address with actual values; skip the first DNS command when an older `dig` lacks `+tls`. Public plain DNS `:53` and remote access to `:5353` must fail. There is no `5gpn-dns` or `5gpn-intercept` service in the monolith. The routine [deployment smoke](tests/deployment-smoke.md) is strictly read-only and may run only on an explicitly designated gateway. Start at the [acceptance index](tests/integration-smoke.md) for installer, disruption, mihomo runtime, and Console coverage; every mutating root-repository checklist, and every zashboard controller mutation scheduled by root release/acceptance, is disposable-only.

Then open `https://console.<base>/ui/`. The panel and two iOS profiles are
public, while `/5gpn/*` and the ordinary controller routes require mihomo's
controller secret. A successful interactive installation prints a
password-equivalent zashboard setup link. The same link and decoded manual
fields are available later under `sudo 5gpn` → `Console connection`;
non-interactive installer output never includes them.

For manual setup, select `Clash API`, enable `HTTPS`, enter
`console.<base>` as the host, `443` as the port, leave `Secondary Path` empty,
and use the displayed controller secret as the password. Do not enter
`127.0.0.1`: zashboard runs in the browser, so loopback names the browser's
client device rather than the gateway. Use the root-only management action,
which reads the exact version-2 controller projection through the pinned Core;
the secret is never mirrored into `dns.env`.

- **Android**: find `dot.<base>` in the Console Setup Guide and enter it as the system Private DNS provider. Modern Android apps generally do not trust user-installed CAs by default, so the project does not offer an Android MITM CA workflow.
- **iOS**: download and install `/ui/ios-dot.mobileconfig` from the Setup Guide. If extensions are needed, install `/ui/ios-intercept-ca.mobileconfig` separately and manually enable Full SSL Trust in system settings.
- **zashboard**: `https://console.<base>/ui/` and both profiles beneath
  `/ui/` are public. `/5gpn/*` and the ordinary controller routes require the
  single mihomo controller secret. There is no separate Console token, origin,
  source allowlist, or handoff session.

The Console includes `/overview`, `/setup-guide`, `/logs`, `/resolve-test`, `/policy-rules`, `/extensions`, `/extensions/hosts`, `/marketplace`, `/plugin-logs`, `/mihomo`, `/mihomo-config`, and `/settings`. Its API and mihomo's controller share the same process, origin, and controller secret.

The Telegram bot runs inside mihomo and is configured from Console Settings.

The bot requires a Telegram token and administrator allowlist. `/id` reports
the caller and chat IDs; configured administrators may use `/status` and
`/resolve <domain>`. The command surface is read-only: extension, policy,
certificate, service, log, and mihomo mutations remain Console or host
operations.

## Configuration ownership

| Path | Ownership and purpose |
| --- | --- |
| `/etc/5gpn/dns.env` | Exactly six installer inputs: base domain, public/gateway/listener IPv4 values, certificate mode, and certificate email |
| `/etc/5gpn/mihomo/config.yaml` | Complete operator-owned mihomo configuration |
| `/etc/5gpn/mihomo/5gpn/dns.json` | Ordered DNS policy, upstreams, subscriptions, and resolver settings |
| `/etc/5gpn/mihomo/5gpn/intercept.json` | Interception master, fixed-false HTTP/3 marker, and extension snapshots |
| `/etc/5gpn/mihomo/5gpn/bot.json` | Telegram switch, token, administrators, and alerts |

Normal install, current-schema reinstall, and `configure` validate an existing mihomo file with `5gpn-mihomo -t` and the exact root-only controller inspector, then preserve it byte for byte. Only explicit `mihomo-reset` may replace it after backup, complete validation, and atomic rename; that command is not a legacy conversion path. Gateway changes update installation-owned DNS state and the dynamic Core guard after restart without rewriting operator YAML. Domain or listener changes that conflict with operator YAML still abort before publication.

The root-only **Nodes** tab in `sudo 5gpn` is a narrow explicit exception, not
a whole-file replacement. It can add or remove static `proxies` and their
membership in the existing `Proxies` selector. The one-shot core helper accepts
Mihomo/Clash proxy YAML or mihomo-supported plain/standard-Base64 share-link
exports, rejects a partially parsed batch, shows the parsed names before
confirmation, revision-checks and validates the complete file, keeps the
previous bytes, publishes atomically, hot-applies the complete path, and checks
the live group. It does not create a Console node API, second node database, or
continuing Sub-Store subscription. Provider subscriptions and arbitrary group
or rule edits remain manual operator YAML changes.

### Mihomo proxy selection

The supported 5gpn seed remains in `mode: rule` and ends with
`MATCH,Proxies`. Ordinary gateway traffic therefore uses the current member of
the operator-defined `Proxies` group, which initially contains only `DIRECT`.
Mihomo's virtual `GLOBAL` selector belongs to global mode; switching modes
bypasses the complete rule list, including the private-address and UDP/443
guards, and is not the supported 5gpn data-plane mode.

Persistent nodes and providers belong only in the fully operator-owned
`/etc/5gpn/mihomo/config.yaml`. The Console's **Update config** path/payload
action hot-applies a complete configuration but never writes that file, so a
restart or reload of the default path discards payload-only changes. Validate
and publish the operator file first, then use **Reload config** or restart for a
durable change.

The fresh/reset seed starts its `Proxies` group with `DIRECT` only; 5gpn ships no proxy nodes. Running `sudo 5gpn mihomo-reset` directly prints a replacement warning but does not ask for another confirmation. Before running it, prepare to restore custom proxies, providers, groups, and rules from the backup.

Console writes hot-apply the revisioned mihomo `5gpn` documents. Deployment values in `dns.env` change only through a validated installer run; certificates hot-reload when their files change.

## Common commands

| Command | Effect |
| --- | --- |
| `sudo 5gpn` | Open the interactive management menu |
| `sudo 5gpn status` | Show service, interception, domain, and address state |
| `sudo 5gpn restart` | Restart mihomo |
| `sudo 5gpn configure` | Open the full configuration TUI and apply a validated transaction |
| `sudo 5gpn ios` | Regenerate the iOS profile and QR code |
| `sudo 5gpn set-cf-token` | Update the Cloudflare token through the TUI |
| `sudo 5gpn mihomo-reset` | Back up and replace the complete mihomo YAML with the current validated seed |
| `sudo 5gpn uninstall` | Ownership-checked removal that preserves configuration and certificate state by default |
| `sudo 5gpn uninstall --purge` | Remove more project state while retaining certificates, ACME state, and the interception CA |
| `sudo 5gpn uninstall --decommission` | Remove the exact public lineage and private CA only when provenance proves 5gpn ownership |

Controller-secret rotation is a complete operator-file transaction: edit
`config.yaml`, validate the complete file with the pinned Core, publish it
atomically, and explicitly restart mihomo. There is no partial `rotate-token`
writer and the secret is never copied into `dns.env`.

## Native extensions

Native extensions are optional, and a fresh installation has the MITM master disabled. The control and capture engine remains inside mihomo; no sidecar service is started. Untrusted code runs only in same-binary one-shot workers, so mihomo remains the sole long-running process:

- Only strict `5gpn.io/v1` YAML is accepted. URL manifests and referenced remote scripts are fetched once through HTTPS, redirect, and SSRF guards; local add accepts one pasted or uploaded manifest. Every input is size-bounded, hashed, and stored as an immutable local snapshot. A fresh install lands disabled; a reviewed update atomically retains the extension's prior enabled authorization.
- `traffic.captureHosts` is the sole traffic-acquisition permission. Only when both the extension and MITM master are enabled and ready does it capture plain HTTP or TLS/H1/H2 on ports `80` and `443`.
- HTTP/3 interception is unsupported. `http3=true` is rejected, and the fixed global UDP/443 `REJECT` has no product-management off switch. Fallback-capable clients may retry over captured TCP; H3-only clients fail.
- An extension may remain armed while the MITM master is off, but it is not ready and contributes no DNS overlay or in-process capture policy.
- When certificate publication is pending or has failed, enabled capture names remain claimed at the gateway and their HTTP/TLS connections are rejected before ordinary routing. A fenced ready result activates them without another write or restart; an old certificate is never presented and pending never becomes direct bypass.
- The Console exposes every declared typed setting, including the local location editor. One save replaces the complete settings map as a single validated revision; it cannot leave a partially saved combination. Enabled extensions may apply a reviewed Marketplace update in place: in-flight requests finish on the old immutable snapshot and later requests see only the fully compiled replacement. The installed page exposes no separate source-URL update check.
- Every validation and action runs in a fresh, memory-isolated one-shot process containing a bounded goja VM. Linux uses delegated cgroup-v2 memory and pids controller subtrees; supported Windows execution uses a 512MiB Job Object with `ActiveProcessLimit=1`. If that hard limit cannot be established, the operation fails closed without an in-process fallback. Quota-bound storage, logs, and permitted network calls cross bounded IPC back to the main process, where network calls enter mihomo's inner dialer and current rule evaluation. The sandbox has no filesystem, process, module loader, socket, ambient `fetch`, or direct egress.
- Every extension has an explicit egress binding that defaults to `DIRECT`. The operator may select an existing mihomo group, but the manifest and scripts cannot name or change that value. A selected group that disappears fails closed without silently returning to `DIRECT`. Global routing rules reviewed in the enablement confirmation may select only `REJECT` or `DIRECT` and exist only while both the extension and MITM master are enabled.
- Execution order affects action composition, egress and capture-DNS winners for overlapping hosts, and routing first-match behavior, so reordering also requires confirmation.
- Marketplace data is discovery metadata, not a trust root. Nothing is installed, enabled, updated, crawled, or mirrored automatically. First-party extension source lives in the separate [moooyo/5gpn-extensions](https://github.com/moooyo/5gpn-extensions) repository, and the [official marketplace index](https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json) it publishes is compiled into the core as the only source that is ever read. The marketplace is not configuration: there is no persisted `catalogs` array and no control that adds, renames, removes, or disables a source. Operators may still install any manifest through Install from URL or local add.
- Plugin engine logs exist only in mihomo's 1000-entry memory ring. Pausing or clearing the Console view neither stops ingestion nor deletes that ring; the log disappears when the process exits.

> [!CAUTION]
> When a manifest declares `permissions.network: true` and the operator confirms it, the script may send any request or response data visible to it, including decrypted content, settings, and storage data, to any host it can reach. The grant has no destination allowlist. An authorized cross-origin URL rewrite forwards the complete method, decoded body, and end-to-end headers, potentially including `Cookie` or `Authorization`. The enablement confirmation names the unrestricted grant and every routing rule; any changed snapshot requires a new review.

On a host installation only the root-owned certificate publisher can read the
private CA signing key; mihomo receives a constrained leaf. Docker instead uses
the explicitly disclosed weaker same-container boundary above. Installing the private CA does not guarantee that every application can be captured. Certificate pinning, mTLS, application-provisioned ECH, HTTP/3, and protocols without HTTP semantics are unsupported: the connection fails closed instead of bypassing interception. See [docs/native-extensions.md](docs/native-extensions.md) for the full manifest contract.

## Upgrades and release channels

- The default quick installer selects only the latest official release. `--beta` is an explicit, per-invocation opt-in, accepts only a prerelease whose base is newer than latest official, and is never persisted in `dns.env`.
- A normal channel transition uses one complete verified installer bundle and supports only a deployment that already conforms to the current schema. It preserves a valid current operator-owned mihomo YAML byte for byte.
- A legacy footprint is a hard pre-publication error. The installer reports the conflicting path, unit, account, key, document, certificate role, or mihomo construct without stopping it or changing any bytes. Rebuild or decommission that host explicitly before a fresh installation; no in-place legacy migration is provided.
- `mihomo-reset` replaces the complete YAML only for a current-schema deployment. Custom proxies, providers, groups, and rules are not merged and must be restored manually from the backup.
- A successful beta channel switch does not guarantee an in-place switch back to the official channel. Keep a system snapshot before switching when reversal is required. The installer does not claim whole-system rollback after publication begins.
- A GitHub Release always contains only `5gpn-installer.tar.gz`,
  `checksums.txt`, and `THIRD_PARTY_NOTICES.md`. The same tag separately
  publishes `ghcr.io/moooyo/5gpn:<tag>`; stable advances `latest`, while beta
  never does.
- Repository administration must prevent release-tag updates and deletion with a GitHub ruleset and keep immutable releases enabled. The workflow binds assets and the OCI digest to the tag-push commit. A retry may reuse only an identical exact image and matching draft/immutable release; drift is rejected. Stable GHCR `latest` advances only after the GitHub release is immutable.

## Security boundaries and known limitations

- Name-based encrypted-DNS blocking cannot stop a client that uses a hard-coded resolver IP and can route around the gateway. 5gpn does not claim network-layer enforcement.
- Steering depends on DNS and a visible hostname. Arbitrary ports, generic raw UDP, traffic without a usable Host/SNI, inner names hidden by application-provisioned ECH, and connections that bypass 5gpn DNS are unsupported.
- The fixed global UDP/443 guard rejects only traffic that reaches the gateway. It is immutable through product management, does not manage a firewall, and does not affect ordinary UDP or QUIC sniffing on other explicitly operator-configured ports.
- Console SPA assets and profiles under `/ui/*` are public. `/5gpn/*` and the ordinary controller routes require mihomo's controller secret; there is no second panel origin, source allowlist, handoff session, or Console bearer.
- Trust in the extension root CA spans the whole extension subsystem, while actual decryption remains limited to enabled capture hosts. Normal uninstall and purge preserve this CA for enrolled devices; only explicit decommission attempts to remove an ownership-proven CA and public lineage.
- 5gpn never modifies nftables or another host firewall. Any additional public ingress must be restricted to intended clients by the operator.

See [docs/architecture.md](docs/architecture.md) for the complete, normative current system boundary.

## Development and verification

This repository contains installer assets and Docker assembly, but no runtime
or Console source. The source-level gate is:

```bash
for s in install.sh quick-install.sh release/*.sh scripts/*.sh docker/*.sh tests/container-acceptance.sh tests/docker/*.sh; do bash -n "$s"; done
for t in tests/test_*.sh; do bash "$t"; done

tests/verify-artifact-pins.sh
```

CI renders and validates the seed with the digest-pinned mihomo binary. The [acceptance index](tests/integration-smoke.md) separates the read-only [deployment smoke](tests/deployment-smoke.md) from disposable-only [installer](tests/acceptance/installer.md) and [disruption/recovery](tests/acceptance/disruption-recovery.md) acceptance, and links the immutable mihomo and zashboard runbooks that own their internal behavior. When root release/acceptance schedules zashboard, every controller mutation is still disposable-only even if the fixed zashboard runbook permits a restored mutation on an explicitly designated gateway.
Hosted CI may build and inspect the Docker image, but real cgroup, worker OOM,
certificate, restart, and persistence acceptance runs through
[tests/container-acceptance.sh](tests/container-acceptance.sh) on a disposable
Engine 28 target reached through `test-env`, never on the working gateway.

## Repository layout

| Path | Contents |
| --- | --- |
| *(external: `moooyo/mihomo`)* | The single runtime: DNS, forwarding, HTTP/TLS interception, Telegram, and controller API |
| *(external: `moooyo/zashboard`)* | The React Console served by mihomo |
| `Dockerfile`, `compose.yaml`, `docker/` | Single-container image, Compose/security profile, bootstrap, and trusted short-lived certificate helpers |
| `release/` | Centralized third-party artifact coordinates and their strict parser/URL builder |
| `etc/` | Current dns.env example, mihomo seed, and systemd units |
| `scripts/` | Certificate and iOS profile helpers; the suite runner stays source-only |
| `tests/` | Shell regressions, the read-only deployment smoke, and disposable acceptance runbooks |
| `docs/` | Current architecture and the extension author contract |
| `.github/workflows/` | Shared CI gate and exact-tag release pipeline |
| `install.sh`, `quick-install.sh` | Transactional installer and trusted release entrypoint |

## Documentation and license

- [Current architecture](docs/architecture.md)
- [Native extension authoring contract](docs/native-extensions.md)
- [Acceptance ownership and safety index](tests/integration-smoke.md)
- [Read-only Linux deployment smoke](tests/deployment-smoke.md)
- [Disposable installer acceptance](tests/acceptance/installer.md)
- [Disposable disruption and recovery acceptance](tests/acceptance/disruption-recovery.md)
- [Docker 28 disposable acceptance contract](tests/container-acceptance.sh)
- [Docker deployment runbook](docs/docker.md)
- [Official extension repository](https://github.com/moooyo/5gpn-extensions)
- [Releases](https://github.com/moooyo/5gpn/releases) and [Issues](https://github.com/moooyo/5gpn/issues)
- [MIT License](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md)
