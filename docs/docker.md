# Docker deployment

Docker is an alternative packaging and lifecycle for the same 5gpn monolith.
It is one image, one container, and one Compose service. DNS, forwarding,
Console, Telegram, and native extensions are not split into sidecars.

## Publication status

The merged root implementation requires the exact offline Core handshake
`5gpn-container-runtime-v2`. `release/pins.env` now names a container-capable
pair that satisfies it: Core `v1.19.30-monolith.34`, whose published binary
answers the handshake, and Console `v3.21.0-monolith.34`, which carries the
deployment-neutral setup wording. Both are immutable published releases and
their digests are bound in the pin manifest.

What still fails closed is the acceptance evidence. No exact image has passed
release-mode acceptance, so the three `FIVEGPN_CONTAINER_ACCEPTED_*` repository
variables are unset and the publication gate rejects every tag. No current tag
is a supported Docker v2 release until that run exists and those variables
record it.

Do not weaken the handshake or use a development binary in a release image.
This runbook describes the v2 delivery that becomes usable only after the exact
image passes release-mode acceptance against the pinned pair already recorded
in `release/pins.env`.

## Supported host

The first Docker release supports only:

- Linux `amd64`;
- rootful Docker Engine 28 or newer;
- a pure cgroup v2 hierarchy with the memory and pids controllers;
- Docker's systemd cgroup driver;
- no daemon `userns-remap`; and
- Debian or Ubuntu with AppArmor.

Rootless Docker, Docker Desktop, SELinux enforcing, and arm64 are outside this
contract. The runtime's real worker startup probe remains authoritative and
exits before listeners open if delegation is not usable.

## Obtain the launch files

Every GitHub Release remains exactly three assets. The installer archive also
carries the tagged Docker launch files, while the matching image is a separate
GHCR artifact:

```bash
TAG=X.Y.Z
curl -fLO "https://github.com/moooyo/5gpn/releases/download/${TAG}/5gpn-installer.tar.gz"
curl -fLO "https://github.com/moooyo/5gpn/releases/download/${TAG}/checksums.txt"
sha256sum -c checksums.txt
mkdir "5gpn-${TAG}"
tar xzf 5gpn-installer.tar.gz -C "5gpn-${TAG}"
cd "5gpn-${TAG}"
```

The required local launch inputs are `compose.yaml`,
`docker/seccomp-5gpn.json`, and `docker/bootstrap/config.env.example`. Do not
mix files from a branch with a tagged image. Image assembly reads the same
bound `release/pins.env` through `release/pins.sh`; there is no Docker-only
component lock.

## Configure

Copy the bootstrap template and set the base domain, the client-routable
gateway IPv4, and the Let's Encrypt email. Container listeners are fixed at
`0.0.0.0`; public and gateway addresses are deployment identity, not
container-interface bind targets. Docker accepts Cloudflare DNS-01 only.

Do not add a controller secret to the bootstrap file. On a fresh v2 volume,
bootstrap generates a random secret once and writes it only into the complete
operator-owned `/etc/5gpn/mihomo/config.yaml`. Durable `/etc/5gpn/dns.env`
contains exactly six installation coordinates and never contains the secret,
listener paths, certificate paths, policy, or runtime tuning.

```bash
cp docker/bootstrap/config.env.example docker/bootstrap/config.env
${EDITOR:-vi} docker/bootstrap/config.env

install -m 0600 /dev/null docker/bootstrap/cloudflare_api_token
${EDITOR:-vi} docker/bootstrap/cloudflare_api_token

sudo chown 10001:10001 \
  docker/bootstrap/config.env docker/bootstrap/cloudflare_api_token
sudo chmod 0600 \
  docker/bootstrap/config.env docker/bootstrap/cloudflare_api_token
```

The Cloudflare file contains the raw API token and nothing else. Use a token
scoped to `Zone:DNS:Edit` for the selected zone. Fixed identity
`10001:10001` owns the process, delegated cgroup, and both persistent-volume
ABIs.

DNS-01 creates only temporary ACME TXT records. Before client enrollment, the
operator must publish `console.<base>` and `dot.<base>` A records that resolve
to `DNS_PUBLIC_IP`, which defaults to `DNS_GATEWAY_IP` when no separate public
identity is needed. The container does not create or maintain those A records.
The Docker data plane is IPv4-only.

Both bootstrap inputs are read from fixed defaults relative to the launch
directory and may be relocated without editing `compose.yaml`:

| Variable | Default | Delivered as |
|---|---|---|
| `FIVEGPN_BOOTSTRAP_CONFIG` | `./docker/bootstrap/config.env` | read-only bind mount at `/run/5gpn-bootstrap-input/config.env` |
| `CLOUDFLARE_API_TOKEN_FILE` | `./docker/bootstrap/cloudflare_api_token` | Compose secret `cloudflare_api_token` |
| `FIVEGPN_DATA_VOLUME` | `fivegpn-data` | named volume at `/etc/5gpn` |
| `FIVEGPN_UI_VOLUME` | `fivegpn-ui` | named volume at `/opt/5gpn/ui` |

Bootstrap entries must be exact `KEY=value` lines with no surrounding
whitespace. Both the entrypoint and the public certificate helper parse this
file, and both reject a line that carries leading or trailing spaces.

## Start

After a v2-compatible tag has been published, confirm the host boundary and use
the exact image tag matching the release bundle. Compose requires
`FIVEGPN_IMAGE` and has no movable default. Stable publication may update the
convenience alias `latest`; beta never does.

```bash
docker version --format '{{.Server.Version}}'
docker info --format 'cgroup={{.CgroupVersion}} driver={{.CgroupDriver}}'

export FIVEGPN_IMAGE="ghcr.io/moooyo/5gpn:${TAG}"
docker compose pull gateway
docker compose up -d gateway
docker compose logs -f gateway
```

Bootstrap first verifies the exact runtime-v2 handshake, then locks both named
volumes for the container lifetime. It accepts only the exact six-key
`dns.env`, validates existing operator YAML through owner-scoped
`5gpn-config inspect-controller --owner-uid` v2, and validates
`dns.json`, `intercept.json`, and `bot.json` through
`5gpn-state validate --owner-uid`. Shell code does not maintain a second
decoder for those Core-owned documents.

Bootstrap then initializes or validates the interception CA, obtains one
Cloudflare Certbot lineage for `<base>` and `*.<base>`, publishes the `dot` and
`console` roles, and publishes the pinned Console plus both signed profiles as
one complete `/opt/5gpn/ui/current` generation. Finally it validates the whole
Mihomo configuration and `exec`s `5gpn-mihomo` as PID 1.

ACME issuance failure is retried with bounded backoff. Structural, permission,
lineage, volume, document, and publication failures stop that attempt without
silently repairing or adopting state. Because Compose uses
`restart: unless-stopped`, a deterministic error retries the whole container
until the operator stops it and fixes the input. Restart is crash recovery, not
configuration repair.

The persistent `.5gpn-docker-lineage-ready` marker is the first complete public
lineage commit fence and binds the base domain. Before that fence, bootstrap
may clean only marker-owned first-boot partials and preserves ACME accounts.
After the fence, an invalid lineage is restored only from a validated complete
generation or fails closed.

## Published ports

Compose uses an IPv4-only bridge and publishes only:

| Host mapping | Purpose |
|---|---|
| `0.0.0.0:853:853/tcp` | The only client DNS ingress, DoT. |
| `0.0.0.0:80:80/tcp` | DNS-steered plain HTTP. |
| `0.0.0.0:443:9443/tcp` | DNS-steered TLS/H1/H2 data plane. |
| `0.0.0.0:443:9443/udp` | Gateway UDP/443 reaches the fixed global reject so fallback-capable clients may retry TCP. |
| `0.0.0.0:8080:8080/tcp` | Explicit alternate HTTP/TLS ingress. |
| `0.0.0.0:8443:8443/tcp` | Explicit alternate HTTP/TLS ingress. |

There is no product `:5060` listener. Compose does not publish plain DNS 53,
debug DNS 5353, the origin resolver 5354, or the internal controller port 443.
Every mapping binds the host's IPv4 wildcard explicitly, so an IPv6-enabled
daemon does not also publish it on `::`.

The public 443 mapping targets the Docker-only data-plane socket
`0.0.0.0:9443`. The tunnel still targets `console.<base>:443`, and the internal
controller remains `127.0.0.1:443`, preserving public and sniffed destination
semantics. Restrict public ingress with an independently managed firewall or
cloud security group because 5gpn does not manage one.

## Persistence and v1 rejection

Docker v2 has exactly two durable volumes:

| Volume | Mount | Contents |
|---|---|---|
| `fivegpn-data` | `/etc/5gpn` | Operator YAML, six-key `dns.env`, Core documents, ACME account and lineage, public certificate roles, interception CA and leaf, and ownership markers. |
| `fivegpn-ui` | `/opt/5gpn/ui` | The owned generation root, `current` symlink, Console bytes, compatibility manifests, and both signed profiles. |

Compose fixes the engine-level names so moving the launch directory does not
create an apparently empty gateway. An operator may deliberately set
`FIVEGPN_DATA_VOLUME` and `FIVEGPN_UI_VOLUME`, but both names must remain stable
for every later invocation. Two different containers cannot share either live
volume; startup takes a non-blocking lifetime lock on both.

The image root is read-only. `/run/5gpn`, `/run/5gpn-bootstrap`, `/tmp`, and
`/var/tmp` are tmpfs. The UI is not tmpfs: its complete generation tree is
durable and independently validated before listeners open.

A data volume produced by the retired container-runtime-v1 layout is rejected
unchanged. Extra `dns.env` keys, a secret mirrored outside `config.yaml`, old
document schemas, retired paths, and a flat UI tree are hard errors. There is
no in-place migration, compatibility alias, or automatic adoption. Preserve or
back up the old volume outside the installer, then start v2 with explicitly new
data and UI volume names if a fresh deployment is intended.

Never run `docker compose down -v` unless deletion of both volumes, including
operator configuration, ACME identity, private CA, Console generations, and
signed profiles, is intentional.

## Controller secret

The secret is generated only for a fresh operator YAML. To display it, protect
the terminal and its scrollback, then run the same owner-scoped Core inspector
used by bootstrap:

```bash
docker compose exec -T gateway /bin/sh -ec '
  /opt/5gpn/bin/5gpn-mihomo 5gpn-config inspect-controller \
    --owner-uid 10001 --config /etc/5gpn/mihomo/config.yaml \
    | jq -r .secret
'
```

Do not parse YAML with `grep`, copy the secret into `dns.env`, or place it in a
Compose environment variable.

## Runtime and security boundary

The Compose contract drops every capability and uses the bridge network's
namespaced `net.ipv4.ip_unprivileged_port_start=0` so UID 10001 can bind low
ports without `NET_BIND_SERVICE`. It also uses `no-new-privileges`, a private
cgroup namespace, Docker 28 writable-cgroup delegation, `pids_limit: 256`, and
the shipped clone3-aware seccomp profile. It does not use `privileged`,
`SYS_ADMIN`, an unconfined profile, the Docker socket, or a host cgroup bind
mount.

`5gpn-mihomo` is the sole long-running process. Initial bootstrap commands and
runtime certificate reconciliation commands are trusted short-lived children;
every one is waited, and runtime helpers are terminated as a process group
during shutdown. `/restart`, SIGTERM, and fatal runtime invariants converge on
the same orderly whole-process shutdown. Compose grants 45 seconds before
forced termination, after which `restart: unless-stopped` may replace the
container.

This simplified form deliberately has weaker certificate-key isolation than
the host/systemd installation. The same `fivegpn` identity can read the
Cloudflare credential, ACME account, public private keys, and interception CA
private key. There is no sidecar or namespace boundary between those trusted
materials. Untrusted extension execution remains separate: every operation
uses a fresh same-binary worker born atomically in a bounded cgroup leaf, and
startup fails if that isolation cannot be established.

## Update a v2 deployment

Set `FIVEGPN_IMAGE` to the new exact tag and run `pull` followed by `up -d`.
Keep both volume names unchanged. Back up both volumes while the gateway is
stopped. After changing the Cloudflare token file, recreate or restart the
gateway so bootstrap copies the new credential into tmpfs. Certificate renewal,
role publication, and UI/profile generation otherwise hot-apply without
restarting Mihomo.

## Release acceptance

GitHub-hosted CI prepares the verified component pins, builds the image, and
performs static inspection only. It cannot prove writable-cgroup delegation.
Maintainers run [`tests/container-acceptance.sh`](../tests/container-acceptance.sh)
against the exact candidate on a disposable Docker Engine 28 target reached
through `test-env`. The working gateway is authorized only for read-only
deployment smoke and must not receive recreation, OOM injection, certificate
mutation, or other Docker acceptance writes.

The release-mode driver binds its Git root and `HEAD`, `release/pins.env`, the
Compose and seccomp contracts, the acceptance driver and probes, the compressed
Core artifact digest, and the exact image ID. A copied, dirty, or weakened
harness cannot produce release evidence by repeating an expected commit string.

After compatible Core and Console releases have been pinned, the evidence flow
is:

```bash
accepted_commit="$(git rev-parse HEAD)"
accepted_mihomo_sha="$(sed -n 's/^MIHOMO_SHA256=//p' release/pins.env)"
accepted_container=FIVEGPN_ACCEPTED_CONTAINER
evidence="container-acceptance-${accepted_commit}.log"

set -o pipefail
FIVEGPN_ACCEPTANCE_HOST=test-env \
FIVEGPN_ACCEPTANCE_TARGET=disposable \
FIVEGPN_EXPECTED_COMMIT="$accepted_commit" \
FIVEGPN_EXPECTED_MIHOMO_SHA256="$accepted_mihomo_sha" \
FIVEGPN_CAPABILITIES_URL=https://console.example.com/capabilities \
FIVEGPN_CONTROLLER_SECRET_FILE=/root/acceptance/controller-secret \
  bash tests/container-acceptance.sh "$accepted_container" \
  | tee "$evidence"
```

Only the exact release-mode output may populate:

- `FIVEGPN_CONTAINER_ACCEPTED_COMMIT`;
- `FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256`; and
- `FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID`.

The release workflow rebuilds the image and requires the resulting image ID to
equal the accepted value before publishing the exact GHCR tag. Stable `latest`
moves only after the GitHub Release is immutable. Historical development-mode
evidence cannot satisfy this gate.
