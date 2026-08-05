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
- This repository contains only the installer and operator TUI. It installs
  digest-pinned mihomo and zashboard release artifacts.

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
                          goja actions and inner dial
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

`auto` queries the China and trust upstream groups concurrently. Members within each group are attempted sequentially in configured order with fair slices of the remaining deadline. Fresh installations seed `223.5.5.5:53` and `22.22.22.22:53` into `/etc/5gpn/mihomo/gpn/dns.json`, the atomic source of truth for DNS policy and upstreams, after which the Console can hot-apply a revision-protected whole-document update. A member of either group declares its transport by spec form: a bare `IP[:port]` is plain UDP, `serverName@IP[:port]` is DoT, and `https://host/path@IP[:port]` is DoH over a pooled HTTP/2 connection. Transport is a per-member property, so one group may mix all three. Plain UDP carries no query-name anti-spoof mechanism, so prefer DoT or DoH wherever the resolver offers it. A queries follow the policy above; AAAA, HTTPS, and SVCB return NODATA with authority data. Other types go to the trust group with AAAA, HTTPS, and SVCB records removed from every section before the reply is cached or returned.

The AAAA NODATA is not client-only. After mihomo sniffs a hostname it re-resolves the origin through the loopback resolver on `127.0.0.1:5354`, which returns the same synthetic NODATA before consulting any upstream. That boundary is what actually keeps egress on IPv4: mihomo issues an AAAA query for every origin unconditionally, its `dns.ipv6` setting does not suppress it — only the top-level `ipv6` key does — and `/etc/5gpn/mihomo/config.yaml` is fully operator-owned, so no seed value can be assumed present. If the AAAA were forwarded, mihomo would learn the origin's real IPv6 addresses and race them against the IPv4 ones; once the IPv6 leg completes its TCP handshake the dual-stack fallback no longer fires, and a destination that refuses or mislocates the gateway's datacenter IPv6 prefix then fails at the application layer with nothing left to fall back to. With NODATA, mihomo has only IPv4 candidates. The trade-off is accepted deliberately: an origin published only as AAAA — or an operator node configured by hostname — is unreachable through the gateway, and on an IPv4-only data plane an IPv6 answer would not have been dialable either. Fresh and explicitly reset mihomo seeds additionally set `ipv6: false` as defence in depth.

When both the MITM master and an extension are enabled and active, the capture-host overlay steers matching names to the gateway before operator DNS rules. It still cannot select a mihomo node or group. Extension egress and capture-DNS bindings belong to a separate, confirmed data-plane transaction.

## Core capabilities

- **DoT-only access**: Android Private DNS and iOS profiles use `dot.<base>`; the local debug DNS listener is confined to `127.0.0.1:5353/udp`.
- **Auditable DNS policy**: exact, suffix, keyword, and subscription matchers feed one ordered set of `block`, `direct`, and `proxy` rules plus one fallback.
- **Operator-owned data plane**: the complete mihomo YAML has no daemon-generated region; normal install, reinstall, and `configure` preserve a valid file byte for byte.
- **Unified control plane**: zashboard covers status, setup, DNS logs and diagnosis, policy, upstreams, mihomo health and configuration, extensions, marketplace discovery, and logs. The Telegram bot is read-only and alert-only.
- **Optional native extensions**: strict `5gpn.io/v1` snapshots, explicitly declared exact and constrained-wildcard capture-host allowlists, typed settings, permission review, explicit execution order, and operator-selected egress binding.
- **Checked installation**: exact tags, SHA-256 verification, staging, atomic file publication, and readiness probes. Failures before publication leave the host untouched; failures during publication are reported as partial. No Go or Node toolchain is installed on the gateway.

## Requirements

Before you start, provide:

- A Linux amd64 gateway with systemd and root access. The installer directly supports distributions using apt or dnf/yum; it attempts best-effort adaptation for other distributions only when one of those package managers is detected.
- An interactive TTY for the first installation. `curl | sudo bash` attempts to reattach `/dev/tty`; a first install without a TTY fails closed.
- At least one non-loopback IPv4 address assigned to a local interface and routable from clients. The 5gpn steering path is IPv4-only; IPv6-only clients cannot reach the gateway unless the network provides IPv4 reachability such as CLAT.
- A base domain you control. The system derives `dot.<base>` and `console.<base>`.
- Production modes require an A record for `console.<base>` pointing to the public or otherwise client-routable gateway IPv4; `debug` skips the public DNS gate. Before Android enables Private DNS, `dot.<base>` must also resolve through the client's existing resolver.
- A cloud security group or independently managed firewall that restricts ingress. 5gpn never creates, changes, or removes host firewall rules.

Three IPv4 settings have distinct roles:

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
| TCP/UDP `5060` | Default-enabled `speedtest-5060` module; SIP, Ookla native UDP, and generic raw UDP are unsupported |
| UDP `443` | Remains bound; one fixed global rule rejects gateway UDP/443 so capable clients can fall back to TCP |

Expose only what you need. `speedtest-5060` is an unauthenticated Host/SNI relay and must be source-restricted on public deployments. The UDP/443 guard is not a firewall rule, does not close the socket, and cannot guarantee that every client falls back. Product management cannot disable it; an H3-only client fails.

## Certificate modes

The first-install TUI asks for one of the following modes. Both production modes use one scoped Certbot lineage named `<base>` and deploy its certificate into the dot, web, and console role directories.

| Mode | Certificate and DNS requirements | Renewal behavior |
| --- | --- | --- |
| `cloudflare` | DNS-01; SANs are `<base>` and `*.<base>`; requires a token limited to `Zone:DNS:Edit`. When queried through the fixed resolver `1.1.1.1`, `console.<base>` must return only one A, without a CNAME, pointing to `DNS_PUBLIC_IP` or, for a private deployment, `DNS_GATEWAY_IP` | Does not stop mihomo |
| `http-01` | When queried through the fixed resolver `1.1.1.1`, `console.<base>` and `dot.<base>` must each return only one public A equal to `DNS_PUBLIC_IP`, without a CNAME or any AAAA, and public TCP `80` must be reachable | Initial issuance stops mihomo only when it was active; failure or a signal restores it immediately, while success leaves restoration to the install flow after the lineage and role certificates are fully published. Renewal when due briefly releases `:80` and restores mihomo after success or failure |
| `debug` | Isolated self-signed certificate, no Certbot, and not trusted by clients by default | Testing only |

The Cloudflare token is written only to `/etc/5gpn/acme/cloudflare.ini`, which is root-only; it never enters `dns.env`, the caller environment, or logs. Optional interception uses a completely separate private root CA and never replaces the public DoT or Console certificate.

## Quick install

Install the latest official release:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
```

Explicitly install the latest beta prerelease:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
```

From a checkout, use:

```bash
sudo bash install.sh
sudo bash install.sh --beta
```

The source installer also resolves and delegates to one verified, exact release bundle so binaries from one tag cannot be mixed with scripts or templates from another. The default channel accepts only `X.Y.Z`; `--beta` accepts only a published `X.Y.Z-beta.N` and never falls back to an official release when no valid beta exists.

The first installation collects configuration through the TUI and atomically writes `/etc/5gpn/dns.env`. Reinstall reads only that file and never treats the caller environment as configuration input. Preflight and staging fail before publication where possible; a failure during publication is reported as a partial installation rather than hidden behind a rollback claim.

## After installation

Start by checking service state:

```bash
sudo 5gpn status
```

Run a minimal service and configuration check:

```bash
sudo systemctl is-active mihomo
sudo /opt/5gpn/bin/mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo
```

Then verify DNS with a `dig` build that supports DoT:

```bash
DOT=dot.example.com
GW=203.0.113.10
dig +tls @"$GW" -p 853 example.com A +tls-host="$DOT"
dig @127.0.0.1 -p 5353 example.com A
```

Replace the example domain and address with actual values; skip the first DNS command when an older `dig` lacks `+tls`. Public plain DNS `:53` and remote access to `:5353` must fail. There is no `5gpn-dns` or `5gpn-intercept` service in the monolith. See [tests/integration-smoke.md](tests/integration-smoke.md) for the complete real-host checklist, and run it only on a disposable or explicitly designated Linux gateway.

Then open `https://console.<base>/ui/`. The panel and two iOS profiles are
public, while `/gpn/*` and the ordinary controller routes require mihomo's
controller secret. On first open, enter that secret in zashboard. To recover it
on the host:

```bash
sudo sed -n 's/^DNS_MIHOMO_SECRET=//p' /etc/5gpn/dns.env
```

- **Android**: find `dot.<base>` in the Console Setup Guide and enter it as the system Private DNS provider. Modern Android apps generally do not trust user-installed CAs by default, so the project does not offer an Android MITM CA workflow.
- **iOS**: download and install `/ui/ios-dot.mobileconfig` from the Setup Guide. If extensions are needed, install `/ui/ios-intercept-ca.mobileconfig` separately and manually enable Full SSL Trust in system settings.
- **zashboard**: `https://console.<base>/ui/` is the Console. There is no second origin, source allowlist, handoff session, or separate Console token.

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
| `/etc/5gpn/dns.env` | Persistent source of truth for deployment identity and daemon knobs |
| `/etc/5gpn/mihomo/config.yaml` | Complete operator-owned mihomo configuration |
| `/etc/5gpn/mihomo/gpn/dns.json` | Ordered DNS policy, upstreams, subscriptions, and resolver settings |
| `/etc/5gpn/mihomo/gpn/intercept.json` | Interception master, fixed-false HTTP/3 marker, catalogs, and extension snapshots |
| `/etc/5gpn/mihomo/gpn/bot.json` | Telegram switch, token, administrators, and alerts |

Normal install, reinstall, and `configure` validate an existing mihomo file with `mihomo -t` and then preserve it byte for byte. Only explicit `mihomo-reset` or TTY-confirmed `upgrade-reset-mihomo` may replace it after backup, complete validation, and atomic rename. If `configure` finds that a new domain, gateway, or listener conflicts with the operator-owned YAML, it aborts before writing instead of silently modifying the data plane.

The fresh/reset seed starts its `Proxies` group with `DIRECT` only; 5gpn ships no proxy nodes. Running `sudo 5gpn mihomo-reset` directly prints a replacement warning but does not ask for another confirmation. Before running it, prepare to restore custom proxies, providers, groups, and rules from the backup.

Console writes hot-apply the revisioned mihomo `gpn` documents. Deployment values in `dns.env` change only through a validated installer run; certificates hot-reload when their files change.

## Common commands

| Command | Effect |
| --- | --- |
| `sudo 5gpn` | Open the interactive management menu |
| `sudo 5gpn status` | Show service, domain, address, and rule state |
| `sudo 5gpn restart` | Restart mihomo |
| `sudo 5gpn configure` | Open the full configuration TUI and apply a validated transaction |
| `sudo 5gpn ios` | Regenerate the iOS profile and QR code |
| `sudo 5gpn rotate-token` | Rotate the mihomo controller secret and restart mihomo |
| `sudo 5gpn set-cf-token` | Update the Cloudflare token through the TUI |
| `sudo 5gpn mihomo-reset` | Back up and replace the complete mihomo YAML with the current validated seed |
| `sudo 5gpn uninstall` | Ownership-checked removal that preserves configuration and certificate state by default |
| `sudo 5gpn uninstall --purge` | Remove more project state while retaining certificates, ACME state, and the interception CA |
| `sudo 5gpn uninstall --decommission` | Remove the exact public lineage and private CA only when provenance proves 5gpn ownership |

## Native extensions

Native extensions are optional, and a fresh installation has the MITM master disabled. The engine remains inside mihomo; no sidecar service is started:

- Only strict `5gpn.io/v1` YAML is accepted. URL manifests and referenced remote scripts are fetched once through HTTPS, redirect, and SSRF guards; local add accepts one pasted or uploaded manifest. Every input is size-bounded, hashed, and stored as an immutable local snapshot. Installs and updates always finish disabled.
- `traffic.captureHosts` is the sole traffic-acquisition permission. Only when both the extension and MITM master are enabled and ready does it capture plain HTTP or TLS/H1/H2 on ports `80` and `443`.
- HTTP/3 interception is unsupported. `http3=true` is rejected, and the fixed global UDP/443 `REJECT` has no product-management off switch. Fallback-capable clients may retry over captured TCP; H3-only clients fail.
- An extension may remain armed while the MITM master is off, but it is not ready and contributes no DNS overlay or in-process capture policy.
- Every action runs in a fresh, bounded goja VM. Quota-bound `context.storage` exists only when the manifest requests it. The sandbox exposes bounded action-scoped timers and, with the network grant, synchronous `request` plus promise-based `requestAsync`; it has no filesystem, process, module loader, socket, ambient `fetch`, or direct egress. All permitted network calls return through mihomo's inner dialer and current rule evaluation.
- An extension may require the operator to choose from existing mihomo groups, but its manifest and scripts cannot name or change a group. Global routing rules reviewed in the enablement confirmation may select only `REJECT` or `DIRECT` and exist only while both the extension and MITM master are enabled.
- Execution order affects action composition, egress and capture-DNS winners for overlapping hosts, and routing first-match behavior, so reordering also requires confirmation.
- Marketplace data is discovery metadata, not a trust root. Nothing is installed, enabled, updated, crawled, or mirrored automatically. First-party extension source lives in the separate [moooyo/5gpn-extensions](https://github.com/moooyo/5gpn-extensions) repository, which publishes the [official marketplace index](https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json).
- Plugin engine logs exist only in mihomo's 1000-entry memory ring. Pausing or clearing the Console view neither stops ingestion nor deletes that ring; the log disappears when the process exits.

> [!CAUTION]
> When a manifest declares `permissions.network: true` and the operator confirms it, the script may send any request or response data visible to it, including decrypted content, settings, and storage data, to any host it can reach. The grant has no destination allowlist. An authorized cross-origin URL rewrite forwards the complete method, decoded body, and end-to-end headers, potentially including `Cookie` or `Authorization`. The enablement confirmation names the unrestricted grant and every routing rule; any changed snapshot requires a new review.

Only the root-owned certificate publisher can read the private CA signing key; mihomo receives a constrained leaf and cannot access the root key. Installing the private CA does not guarantee that every application can be captured. Certificate pinning, mTLS, application-provisioned ECH, HTTP/3, and protocols without HTTP semantics are unsupported: the connection fails closed instead of bypassing interception. See [docs/native-extensions.md](docs/native-extensions.md) for the full manifest contract.

## Upgrades and release channels

- The default quick installer selects only the latest official release. `--beta` is an explicit, per-invocation beta opt-in and is never persisted in `dns.env`.
- A normal channel transition uses one complete verified installer bundle and preserves a valid current operator-owned mihomo YAML byte for byte. Moving from the retired multi-process design to the monolith is a separate checked migration: it removes only the retired anchors and inbound from a candidate, rewrites the management-plane exclusion to `INNER`, requires the fixed UDP/443 guard, and publishes only after pinned `mihomo -t` succeeds.
- `upgrade-reset-mihomo` replaces the complete YAML. Custom proxies, providers, groups, and rules are not merged and must be restored manually from the backup.
- A successful beta upgrade does not guarantee that an in-place downgrade to the stable release channel is supported. Keep a system snapshot before upgrading when reversal is required. The installer does not claim whole-system rollback after publication begins.
- Every pre-v5 deployment that still uses interception config schema v4 requires an explicit, recoverable lockstep rebuild first. Never delete the old interception file or change only its schema version. Follow the [pre-v5 rebuild runbook](docs/pre-v5-upgrade.md) exactly.

## Security boundaries and known limitations

- Name-based encrypted-DNS blocking cannot stop a client that uses a hard-coded resolver IP and can route around the gateway. 5gpn does not claim network-layer enforcement.
- Steering depends on DNS and a visible hostname. Arbitrary ports, generic raw UDP, traffic without a usable Host/SNI, inner names hidden by application-provisioned ECH, and connections that bypass 5gpn DNS are unsupported.
- The fixed global UDP/443 guard rejects only traffic that reaches the gateway. It is immutable through product management, does not manage a firewall, and does not affect ordinary UDP or QUIC sniffing on other configured ports such as `:5060`.
- Console SPA assets and profiles under `/ui/*` are public. `/gpn/*` and the ordinary controller routes require mihomo's controller secret; there is no second panel origin, source allowlist, handoff session, or Console bearer.
- Trust in the extension root CA spans the whole extension subsystem, while actual decryption remains limited to enabled capture hosts. Normal uninstall and purge preserve this CA for enrolled devices; only explicit decommission attempts to remove an ownership-proven CA and public lineage.
- 5gpn never modifies nftables or another host firewall. Public ingress, especially `:5060`, must be restricted to intended clients by the operator.

See [docs/architecture.md](docs/architecture.md) for the complete, normative current system boundary.

## Development and verification

This repository contains installer assets only. The local gate is:

```bash
for s in install.sh quick-install.sh scripts/*.sh; do bash -n "$s"; done
for t in tests/test_*.sh; do bash "$t"; done

tests/verify-artifact-pins.sh
```

CI renders and validates the seed with the digest-pinned mihomo binary. Validate real Linux gateway behavior with [tests/integration-smoke.md](tests/integration-smoke.md).

## Repository layout

| Path | Contents |
| --- | --- |
| *(external: `moooyo/mihomo`)* | The single runtime: DNS, forwarding, HTTP/TLS interception, Telegram, and controller API |
| *(external: `moooyo/zashboard`)* | The React Console served by mihomo |
| `etc/` | Configuration examples, mihomo seed, systemd/polkit units, and rule seeds |
| `scripts/` | Certificate, rule, iOS profile, and Telegram operations helpers |
| `tests/` | Shell regressions, upgrade fixtures, and gateway smoke checklist |
| `docs/` | Current architecture, extension author contract, and upgrade runbook |
| `.github/workflows/` | Shared CI gate and exact-tag release pipeline |
| `install.sh`, `quick-install.sh` | Transactional installer and trusted release entrypoint |

## Documentation and license

- [Current architecture](docs/architecture.md)
- [Native extension authoring contract](docs/native-extensions.md)
- [Pre-v5 rebuild and release-channel upgrades](docs/pre-v5-upgrade.md)
- [Linux gateway integration smoke checklist](tests/integration-smoke.md)
- [Official extension repository](https://github.com/moooyo/5gpn-extensions)
- [Releases](https://github.com/moooyo/5gpn/releases) and [Issues](https://github.com/moooyo/5gpn/issues)
- [MIT License](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md)
