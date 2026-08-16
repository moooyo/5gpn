# Docker deployment

Docker is an alternative packaging and lifecycle for the same 5gpn monolith.
It is one image, one container, and one Compose service. DNS, forwarding,
Console, Telegram, and native extensions are not split into sidecars.

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

Every GitHub Release still has exactly three assets. The existing installer
archive also carries the Docker launch files, while the image itself is
published only through GHCR:

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
download those files from a branch while running a tagged image.
The GitHub release body records the matching `ghcr.io/moooyo/5gpn:<tag>` OCI
digest when an immutable digest reference is preferred.

## Configure

Copy the bootstrap template and set the base domain, the client-routable
gateway IPv4, and the Let's Encrypt email. Container listeners are fixed at
`0.0.0.0`; the public and gateway addresses are deployment identity, not
container-interface bind targets. Docker accepts Cloudflare DNS-01 only. Keep
`CERT_MODE=cloudflare`; `http-01`, `debug`, and unknown values are rejected.

Set `DNS_MIHOMO_SECRET` to a new value matching
`[A-Za-z0-9._~-]{16,256}` before first start.
If it is omitted, bootstrap generates one and persists it in
`/etc/5gpn/dns.env` inside the volume. Treat both forms as credentials.

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
scoped to `Zone:DNS:Edit` for the selected zone. The fixed numeric identity
`10001:10001` is both the container runtime identity and the persistent-volume
ABI; changing it prevents safe cgroup delegation and state reuse.

DNS-01 creates only temporary ACME TXT records. Before client enrollment, the
operator must publish `console.<base>` and `dot.<base>` A records that resolve
to `DNS_PUBLIC_IP` (which defaults to `DNS_GATEWAY_IP` when no separate public
identity is needed); the container does not create or maintain those A records.
The Docker data plane is IPv4-only.

## Start

Confirm the host boundary, then use the exact image tag matching the release
bundle. Compose requires `FIVEGPN_IMAGE` and has no movable default. Stable
publication also updates the convenience alias `latest`, while beta never does;
using that alias is an explicit choice outside the tagged-bundle default.

```bash
docker version --format '{{.Server.Version}}'
docker info --format 'cgroup={{.CgroupVersion}} driver={{.CgroupDriver}}'

export FIVEGPN_IMAGE="ghcr.io/moooyo/5gpn:${TAG}"
docker compose pull gateway
docker compose up -d gateway
docker compose logs -f gateway
```

Bootstrap creates or validates the interception CA, obtains one public Certbot
lineage for `<base>` and `*.<base>`, publishes the `dot` and `console` roles,
copies the pinned Console into tmpfs, validates the complete mihomo
configuration, and finally `exec`s `5gpn-mihomo` as PID 1. ACME issuance
failure is retried with bounded backoff; structural, permission, lineage, and
publication failures stop that attempt immediately without repairing or
partially trusting state. Because Compose uses `restart: unless-stopped`, a
deterministic error will retry the whole container until the operator stops it
and fixes the input; restart is crash recovery, not configuration repair.

The persistent `.5gpn-docker-lineage-ready` marker is the first complete public
lineage commit fence and binds the base domain. Before that fence, bootstrap may
clean only marker-owned first-boot partials and preserves ACME accounts. After
the fence, an invalid current lineage is restored only from a validated complete
generation or fails closed; it is never reset silently. Role generation cleanup
uses `.delete.generation-*` tombstones before deletion.

Compose uses an IPv4-only bridge network and explicitly publishes `853/tcp`, `80/tcp`,
`443/tcp+udp`, `5060/tcp+udp`, `8080/tcp`, and `8443/tcp` on the Docker host.
These host ports must be free before startup. Every mapping binds the host's
IPv4 wildcard `0.0.0.0` explicitly, so an IPv6-enabled Docker daemon does not
also publish the service on `::`. Compose does not publish plain DNS 53, debug
DNS 5353, the origin resolver 5354, or the container's internal controller port
443. Restrict public ingress with an independently managed firewall or cloud
security group because 5gpn does not manage one.

The 443 mapping targets the Docker-only data-plane socket
`0.0.0.0:9443`. The tunnel still targets `console.<base>:443`, and the internal
controller remains `127.0.0.1:443`, so public and sniffed destination semantics
stay on port 443. The translated container port exists only to avoid binding a
wildcard `:443` tunnel over that loopback controller. Every other published
port maps to the same container port.

## Runtime and persistence

The only durable volume is `fivegpn-data:/etc/5gpn`. It contains operator YAML,
monolith documents, the ACME account and lineage, public certificate roles, and
the interception CA and leaf. The image root is read-only; `/run`, scratch
directories, and `/opt/5gpn/ui` are tmpfs.
Compose fixes the engine-level volume name to `fivegpn-data` so moving the
launch directory does not create an apparently empty gateway. An operator may
set `FIVEGPN_DATA_VOLUME` to another stable name deliberately; that name must be
kept for every later invocation.

The Compose contract drops every capability and uses the bridge network's
namespaced `net.ipv4.ip_unprivileged_port_start=0` so fixed UID 10001 can bind
the low container ports without `NET_BIND_SERVICE`. It also uses
`no-new-privileges`, a private cgroup namespace, Docker 28's
`writable-cgroups=true`, and the shipped clone3-aware seccomp profile. It does
not use `privileged`, `SYS_ADMIN`, an unconfined profile, the Docker socket, or
a host cgroup bind mount.

To display an automatically generated controller secret, use an interactive
terminal and protect its scrollback:

```bash
docker compose exec gateway grep '^DNS_MIHOMO_SECRET=' /etc/5gpn/dns.env
```

To update, set `FIVEGPN_IMAGE` to the new exact tag and run `pull` followed by
`up -d` again. Back up the named volume while the gateway is stopped. Never run
`docker compose down -v` unless deleting the operator configuration, ACME
identity, public certificates, and interception CA is intentional.

After changing the Cloudflare token file, restart or recreate the gateway so
the entrypoint can copy the new credential into tmpfs. Certificate renewal and
interception-leaf publication otherwise hot-apply without restarting mihomo.

## Process and key boundary

`5gpn-mihomo` is the sole long-running process. Initial certificate/bootstrap
commands and runtime renewal/reconciliation commands are trusted short-lived
children; every one is waited, and runtime helpers are terminated as a process
group during shutdown. `/restart`, SIGTERM, and a fatal runtime invariant all
take the complete orderly shutdown path, after which Docker's
`restart: unless-stopped` policy replaces the container.

This simplified form deliberately has weaker certificate-key isolation than the
host/systemd installation. The same `fivegpn` identity can read the Cloudflare
credential, ACME account, public private keys, and interception CA private key.
There is no sidecar or namespace boundary between those trusted materials.
Untrusted extension execution remains separate: each operation uses a fresh
same-binary worker born atomically in its bounded cgroup leaf, and startup fails
if that isolation cannot be established.

## Release acceptance

GitHub-hosted CI prepares the verified component pins, builds the image, and
performs static inspection only. It cannot prove writable-cgroup delegation.
Maintainers run [`tests/container-acceptance.sh`](../tests/container-acceptance.sh)
against the exact candidate on `test-env` with Docker Engine 28. That manual
gate covers authenticated capabilities, a real extension operation, worker OOM
containment, certificate hot publication, container recreation, and named-volume
persistence. Its extension/OOM, certificate, and transactional-recreate probes
are the reviewed files under `tests/docker`; the driver refuses symlinks or a
missing probe and prints a digest over the exact commit, Compose contract,
seccomp profile, driver, and probe files. There is no site-owned executable
callback. A hosted-runner substitute or an incomplete probe bundle is not an
accepted result.
The candidate is built with the release workflow's pinned BuildKit image,
peeled commit revision, `SOURCE_DATE_EPOCH`, and
`rewrite-timestamp=true`; a plain development `docker build` does not produce
the accepted release image ID.

Run the command on the host whose hostname is exactly `test-env`, from the
exact candidate checkout. The driver verifies that `HEAD` is the requested
commit and that every tracked installer-pin, Compose, seccomp, driver, and
probe input still matches that commit; a copied or locally edited probe tree is not release
evidence. Release mode is the default and accepts only an image whose component
manifest says `pinned-release`. After the exact commit and
pinned artifact pass, a repository administrator
records all three coordinates. Release refuses to publish when any variable is
missing or stale:

```bash
accepted_commit="$(git rev-parse HEAD)"
accepted_mihomo_sha="$(sed -n 's/^MIHOMO_SHA256="\([0-9a-f]*\)".*/\1/p' install.sh)"
accepted_container=FIVEGPN_ACCEPTED_CONTAINER
evidence="container-acceptance-${accepted_commit}.log"
set -o pipefail
FIVEGPN_ACCEPTANCE_HOST=test-env \
FIVEGPN_EXPECTED_COMMIT="$accepted_commit" \
FIVEGPN_EXPECTED_MIHOMO_SHA256="$accepted_mihomo_sha" \
FIVEGPN_CAPABILITIES_URL=https://console.example.com/capabilities \
FIVEGPN_CONTROLLER_SECRET_FILE=/root/acceptance/controller-secret \
  bash tests/container-acceptance.sh "$accepted_container" \
  | tee "$evidence"
accepted_image_id="$(sed -n 's/^FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID=//p' "$evidence")"
gh variable set FIVEGPN_CONTAINER_ACCEPTED_COMMIT --body "$accepted_commit"
gh variable set FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256 --body "$accepted_mihomo_sha"
gh variable set FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID --body "$accepted_image_id"
```

An explicitly selected `FIVEGPN_ACCEPTANCE_MODE=development` accepts only a
`development-local` image and requires its exact uncompressed mihomo binary
digest plus an explicit loopback high-port map. It emits only
`FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_*` values, which cannot satisfy the
release variables above. `tests/container-acceptance.sh --help` lists those
development-only inputs and the optional narrow CA/hostname-resolution inputs.

These variables are evidence selectors, not a substitute for retaining the
test-env command output with the release record.
