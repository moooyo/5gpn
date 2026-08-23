# Docker deployment

Docker is an alternative packaging and lifecycle for the same 5gpn monolith.
It is one image, one container, and one Compose service. DNS, forwarding,
Console, Telegram, and native extensions are not split into sidecars.

## Publication status

The merged root implementation requires the exact offline Core handshake
`5gpn-container-runtime-v2`. `release/pins.env` now names a container-capable
pair that satisfies it: the pinned Core's published binary answers the
handshake, and the pinned Console carries the deployment-neutral setup wording.
Both are immutable published releases and their digests are bound in the pin
manifest. `release/pins.env` and `THIRD_PARTY_NOTICES.md` are the only places
that name the exact coordinates.

Release-mode acceptance first passed on 2026-08-22. Publication is not gated on
a record of that run -- the release job binds to the image it builds and pushes,
not to a hand-set variable -- so running acceptance against the exact candidate
before tagging is a maintainer's obligation, and nothing downstream will catch
skipping it.

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

${EDITOR:-vi} docker/bootstrap/cloudflare_api_token
```

That is the whole configuration step. Neither file needs a particular owner or
mode for the gateway to start.

The container runs as UID:GID `10001:10001` with every capability dropped, so it
can only read what the kernel lets that identity read. A file created with an
ordinary umask is mode 0644, which it can read — along with every other local
user on that host. On a single-operator host that is usually fine and is the
expected default. Compose cannot narrow it for you either: `uid`, `gid`, and
`mode` on a file-based secret are silently ignored outside swarm, and Compose
warns about that on every run.

If the token should stay private to root and the gateway — a shared host, or
several administrators — spend one more command:

```bash
sudo chgrp 10001 docker/bootstrap/cloudflare_api_token
sudo chmod 0640 docker/bootstrap/cloudflare_api_token
```

Bootstrap does not warn about a readable token, because that is the documented
default and warning about it would only teach operators to ignore warnings. It
does warn about one that is group- or other-**writable**, which no default
produces and which would let another local user replace your token.

`config.env` never needs any of this. It holds a domain, two IPv4 addresses, an
email, and a certificate mode — no secret at all.

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

Transient ACME issuance failure is retried in place with bounded backoff at 60,
300, 1800, and 3600 seconds. A failure certbot's output proves cannot succeed on
retry — a token that cannot see the zone, a rejected identifier, a rate limit
whose window outlasts that ladder — is reported immediately with its cause,
then held for an hour before the process exits. The hold is deliberate: because
Compose uses `restart: unless-stopped`, exiting is not a way to stop attempting.
Docker restarts on every exit code and resets its restart backoff after any run
lasting ten seconds or more, so an immediate exit would issue a fresh Let's
Encrypt order roughly every fifteen seconds. Holding bounds a permanent
misconfiguration to about one order per hour while the operator reads the cause.

Structural, permission, lineage, volume, document, and publication failures stop
that attempt without silently repairing or adopting state. A deterministic error
retries the whole container until the operator stops it and fixes the input.
Restart is crash recovery, not configuration repair.

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

The secret is generated only for a fresh operator YAML, and the boot that
generates it prints it once:

```
[OK]   ==================== CONTROLLER SECRET ====================
[OK]   <64 hex characters>
```

Read it from `docker compose logs gateway` on that first boot and store it. It
is your Console login. Because it lands in the container log, it is as private
as `docker logs` on that host; rotate it in the operator YAML if that is not
private enough. Later boots reuse the existing YAML and print nothing.

To display it afterwards, protect the terminal and its scrollback, then run the
same owner-scoped Core inspector used by bootstrap:

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

### Build the candidate

Build only through
[`docker/build-candidate-image.sh`](../docker/build-candidate-image.sh). The
release workflow runs the same script, so the image a maintainer accepts and the
image that ships are built by identical steps. Any other build — a bare
`docker build`, the default builder, an unset `SOURCE_DATE_EPOCH` — reintroduces
exactly the drift that having one definition prevents.

**An accepted image ID does not carry forward.** Both `--tag` and the commit
land in labels — `org.opencontainers.image.version` and
`org.opencontainers.image.revision` — and labels are inside the image config
digest. So the image ID changes with every new commit *and* every tag string.
Decide the tag before acceptance, and re-run acceptance after any commit that
moves the candidate, however unrelated the change looks.

```bash
image_id="$(bash docker/build-candidate-image.sh --tag X.Y.Z)"
echo "$image_id"
```

On a host that cannot reach `registry-1.docker.io` — `test-env` resolves it to a
poisoned address, so `docker buildx create` cannot pull the driver image — set
`FIVEGPN_BUILD_REGISTRY_MIRROR=mirror.gcr.io`, which serves all three pinned
references. It cannot change the result: every reference it fetches stays
digest-pinned. Hosted CI leaves the variable unset and is unaffected.

The build must run from a clean checkout of the commit that will be tagged.
Because the release workflow requires the tagged commit to be reachable from
`main` or `beta` while the acceptance driver requires `HEAD` to equal
`FIVEGPN_EXPECTED_COMMIT`, merge first and build the post-merge commit;
acceptance bound to a pre-merge commit is discarded by the merge.

### Prepare the target

Release mode publishes `0.0.0.0` on `853`, `80`, `443`, `8080`, and `8443`. Any
host gateway already holding those ports must be stopped for the run. The
driver also requires:

- zero installed extensions on the candidate;
- a system-trusted public lineage the candidate already holds, or
  `FIVEGPN_CONTROLLER_CA_FILE` pointing at a PEM bundle that verifies it;
- `FIVEGPN_CONTROLLER_SECRET_FILE` as a single-link mode-0600 regular file of
  at most 4096 bytes holding one 16-to-512-character token.

The run is mutating: it stops, renames, and re-creates the named container,
rolling back on failure.

### Run release acceptance

```bash
accepted_commit="$(git rev-parse HEAD)"
accepted_mihomo_sha="$(sed -n 's/^MIHOMO_SHA256=//p' release/pins.env)"
accepted_container=fivegpn-gateway   # the candidate container's actual name
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

`git status --porcelain` must be empty before this runs; the driver compares
every versioned acceptance input against `git show HEAD:<path>`.

### Development mode

Development mode rehearses the same probes without producing release evidence.
It remaps the published ports to loopback highports so it can coexist with a
host gateway, and it deliberately emits differently named variables that the
release gate will not accept. It takes
`FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256` — the digest of a locally built binary
— instead of `FIVEGPN_EXPECTED_MIHOMO_SHA256`, which must be absent.

```bash
FIVEGPN_ACCEPTANCE_HOST=test-env \
FIVEGPN_ACCEPTANCE_TARGET=disposable \
FIVEGPN_ACCEPTANCE_MODE=development \
FIVEGPN_EXPECTED_COMMIT="$(git rev-parse HEAD)" \
FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256=<64-hex> \
FIVEGPN_DEVELOPMENT_PROJECT=<safe test project name> \
FIVEGPN_DEVELOPMENT_BIND_IP=127.0.0.1 \
FIVEGPN_DEVELOPMENT_HOST_PORTS='{"853":2853,"80":20080,"443":20443,"8080":28080,"8443":28443}' \
FIVEGPN_CAPABILITIES_URL=https://console.example.com:20443/capabilities \
FIVEGPN_CONTROLLER_SECRET_FILE=/root/acceptance/controller-secret \
  bash tests/container-acceptance.sh <container>
```

### Record the evidence

The run prints the accepted commit, the candidate image ID, the pinned Core
digest, and the probe-bundle digest. Nothing consumes them: record them where
humans read, so a later reader can tell which image and which probes a given
tag was accepted against.

Publication itself is bound to the image the release job builds and pushes, and
the pushed manifest is verified against those exact bytes. Stable `latest` moves
only after the GitHub Release is immutable. Development-mode output is labelled
so it cannot be mistaken for a release record.
