# 5gpn Docker integration handoff

**Recorded:** 2026-08-18

This file is a pickup record, not an architecture authority. Read
[`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md), and
[`MEMORY.md`](MEMORY.md) first. Those documents define current behavior; this
file records the recovered Docker work, the maintenance-line merge, and the
remaining delivery work.

## Recovered branch state

| Scope | Branch or source | Recovered commit | Relationship at pickup |
|---|---|---|---|
| Root installer and Docker assembly | `moooyo/5gpn:codex/docker-runtime` | `ca25ff750612d923d4a0ed865be31f481cde262f` | Three commits above `0.0.80`; the current `origin/main` tip is `af5be1b3e98a0d98399b37332aab7be626f6ba27`, 21 commits ahead of that base. |
| Container-aware runtime | `moooyo/mihomo:codex/docker-runtime` | `9b7295f625c38dbcbfe171da364501ffab0eae95` | Must be integrated with the current `feat/5gpn-monolith` maintenance tip before a new Core release is cut. |
| Console | `moooyo/zashboard:feat/5gpn-console` | no Docker-only patch | The Docker image must consume the exact Console coordinate paired with the current Core in `release/pins.env`. |
| Extensions | `moooyo/5gpn-extensions:main` | no Docker-only patch | Acceptance inputs must use an immutable reviewed revision and digest. |

The root Docker branch introduced the single-image delivery in `5da2c6c` and
later recorded its pickup state in `ca25ff7`. The runtime branch introduced
certificate reload support in `7370b743` and the managed container lifecycle in
`9b7295f6`. No Docker PR, tag, GitHub Release, or GHCR image was published from
those branches.

## Valid design that survives the maintenance merge

- Docker is an alternative packaging and lifecycle for the same monolith. It is
  one `linux/amd64` image, one container, one Compose service, and one
  long-running product process. Synchronous bootstrap ends with
  `exec 5gpn-mihomo`, so Mihomo remains PID 1.
- The first supported host is rootful Docker Engine 28 or newer with pure
  cgroup v2, the systemd cgroup driver, no daemon `userns-remap`, a private
  cgroup namespace, writable cgroup delegation, and the shipped clone3-aware
  seccomp profile. The container uses no `privileged`, `SYS_ADMIN`, Docker
  socket, unconfined seccomp profile, or host cgroup bind mount.
- Fixed UID/GID `10001:10001` owns the container process, delegated cgroup, and
  both persistent-volume ABIs. The image root is read-only;
  `fivegpn-data:/etc/5gpn` and `fivegpn-ui:/opt/5gpn/ui` are the two durable
  volumes, while only runtime scratch paths are tmpfs.
- Docker certificate issuance is Cloudflare DNS-01 only. Trusted public and
  interception certificate helpers are short-lived, serialized, waited process
  groups. Runtime helpers start only after the mandatory real worker-isolation
  probe and are terminated before engine shutdown. Compose grants the complete
  shutdown path 45 seconds before forced termination.
- The simplified delivery intentionally accepts weaker trusted-key isolation:
  the same `fivegpn` identity may read the Cloudflare credential, ACME account,
  public private keys, and interception CA key. Untrusted extension code still
  runs only in fresh bounded worker processes.
- Public `:443` maps to the container-only data-plane socket on `:9443`, while
  the load-bearing controller stays on `127.0.0.1:443` and the sniffed target
  remains port 443. The current published ingress set has no product `:5060`
  listener.
- The GitHub Release remains exactly three assets. The same tag may publish
  `ghcr.io/moooyo/5gpn:<tag>` as a separate registry artifact. Stable may move
  `latest` only after immutable GitHub publication; beta never moves it.
- Image preparation consumes the same bound `release/pins.env` and strict
  `release/pins.sh` parser as the host installer. It creates no Docker-only lock
  and requires the Core's exact offline
  `5gpn-container-runtime-v2` handshake.

## Root adaptation completed

The root Docker implementation now follows the current installer and runtime
contracts:

1. Durable `/etc/5gpn/dns.env` contains exactly the six current installation
   coordinates. It contains no controller secret, fixed listener field,
   controller path, certificate path, policy, or runtime tuning field.
2. The controller secret has one persistent source: operator-owned
   `/etc/5gpn/mihomo/config.yaml`. Fresh container bootstrap may generate it
   once into that YAML, but must never mirror it into `dns.env` or another
   credential file.
3. Existing operator YAML is inspected through the pinned Core's owner-scoped
   `5gpn-config inspect-controller --owner-uid` version-2 projection. Existing
   `dns.json`, `intercept.json`, and `bot.json` are validated through
   `5gpn-state validate --owner-uid`; container shell code must not maintain a
   second schema decoder.
4. The state root and document metadata match the current Core contract. Any
   data volume produced by container-runtime-v1 is rejected unchanged. There
   is no compatibility alias, automatic rewrite, or in-place volume migration.
5. The separate persistent `fivegpn-ui` volume contains the Console and both
   profiles as one complete generation at `/opt/5gpn/ui/current`, including the
   current primary/compat manifests and stable top-level file checks. A flat
   copied tree and the retired UI tmpfs are not current behavior.
6. The fresh/reset seed comes from the current template: rule mode,
   `MATCH,Proxies`, one fixed UDP/443 reject, no `:5060` listener, and no static
   gateway `IP-CIDR` rule. The Core owns the dynamic private-carrier anti-loop
   guard.
7. Docker component preparation, hosted CI, release publication, notices, and
   acceptance read coordinates only from the bound pin manifest and use the
   current paired Core/Console review contract.
8. Container probes expect `5gpn-interception` capability and review contract
   version 7 and cover the current controller, state, UI-generation, and
   certificate boundaries.
9. Compose uses a 45-second stop grace period and Docker acceptance runs on a
   disposable Engine 28 target reached through
   `test-env`. The working gateway is authorized only for read-only deployment
   smoke and must not receive container recreation, OOM injection, certificate
   mutation, or other fault-injection work.

## Historical evidence and its limit

The older branches passed a development-mode Docker 28 acceptance run on
`test-env`. That run covered the real cgroup-FD startup probe, authenticated
capabilities, JavaScript execution, a 512 MiB worker OOM, PID 1 survival,
certificate hot reload, transactional recreation, and named-volume
persistence across both durable roots. The candidate image was assembled from
a previously built local base after Docker Hub timeouts, so the result was
explicitly development-only.

That evidence is not transferable to the current maintenance merge. It binds
the old root implementation commit, old runtime binary, old probe corpus, and
old image ID. It must not populate or satisfy the release variables for a new
tag.

## Release blockers and required order

The root implementation is not publishable with the current pin pair. Pinned
Core `.32` does not implement container-runtime-v2. Deployment-neutral
Zashboard setup wording has landed on its maintenance branch but has no
immutable release and is not yet pinned.

1. Finish and review the Mihomo maintenance integration for the v2 container
   lifecycle, cgroup layout, certificate manager, TLS reload, and orderly
   shutdown.
2. Run the proportional Mihomo build, race, vet, and acceptance gates remotely
   on `test-env`; do not run them locally.
3. Publish immutable container-capable Mihomo and deployment-neutral Zashboard
   releases.
4. Update their paired coordinates in `release/pins.env` and the
   human-readable notice table.
5. Run the full root shell, pin, image, and container-policy gates remotely.
6. Build the exact reproducible image from a clean final commit with the pinned
   Dockerfile frontend, base image, source epoch, and normalized timestamps.
7. Run `tests/container-acceptance.sh` in release mode against that exact image
   on the disposable Docker target.
8. Record only that run's exact values in
   `FIVEGPN_CONTAINER_ACCEPTED_COMMIT`,
   `FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256`, and
   `FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID`.
9. Require the release workflow rebuild to reproduce the accepted image ID
   before publishing the exact GHCR tag. Move stable `latest` only after the
   GitHub Release is immutable.

Use ordinary non-force pushes. Do not publish a tag, GHCR image, or GitHub
Release until the current pin manifest, exact release-mode evidence, and final
image identity all agree.
