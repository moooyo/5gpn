# Docker delivery handoff

**Recorded:** 2026-08-16

This file is a pickup record, not an architecture authority. Read
[`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md), and
[`MEMORY.md`](MEMORY.md) before changing behavior. Those documents define the
current contract; this file records the exact development state, evidence, and
remaining release work.

## Pickup snapshot

| Scope | Remote branch | Implementation commit | Intended base |
| --- | --- | --- | --- |
| Installer, Docker assembly, CI, and release | `moooyo/5gpn:codex/docker-runtime` | `5da2c6c225e5d52c3a99816882e8004d098ad089` | `origin/main@6068376c3816cd76021c778635ed60b3a71a26d8` (`0.0.80`) |
| Runtime | `moooyo/mihomo:codex/docker-runtime` | `9b7295f625c38dbcbfe171da364501ffab0eae95` | `origin/feat/5gpn-monolith@5798f177fbe0ef209d50e39204c16b21e53194ee` |
| Console | no change in this work | pinned `v3.16.1-monolith.30` | `moooyo/zashboard:feat/5gpn-console` |

The 5gpn branch contains these implementation commits:

- `3d5c980` — align the host interception signer with the installer-owned
  `0750` directory boundary;
- `5da2c6c` — add the single-image, single-container Docker delivery.

The mihomo branch contains:

- `7370b743` — make TLS keypair reload work for both ordinary in-place writes
  and atomic parent-symlink generation switches;
- `9b7295f6` — add the managed container runtime lifecycle, certificate manager,
  orderly restart/termination, and complete subsystem shutdown.

Both branches were pushed normally with upstream tracking. No pull request,
tag, GitHub Release, or GHCR publication was created. This handoff is a later
documentation-only commit, so the development acceptance below deliberately
names its parent implementation commit `5da2c6c`; release acceptance must be
rerun on the eventual exact tag commit.

Canonical local development worktrees at handoff time:

```text
/Users/moooyo/.codex/worktrees/f7b3/5gpn
/Users/moooyo/.codex/worktrees/f7b3/mihomo
```

## Delivered behavior

- One `linux/amd64` image, one container, one Compose service, and one
  long-running process. Synchronous bootstrap ends with `exec 5gpn-mihomo`, so
  the monolith remains PID 1.
- An IPv4-only user-defined bridge publishes the supported ports. Public 443 is
  translated to the Docker-only data-plane socket on container port 9443;
  controller `127.0.0.1:443` and the public target port remain unchanged.
- The fixed `10001:10001` identity owns the named-volume ABI and the private
  delegated cgroup. The Compose boundary uses Docker Engine 28 writable-cgroup
  delegation, the checked clone3-aware seccomp profile, no capabilities,
  `no-new-privileges`, a read-only root, and tmpfs runtime paths.
- Docker certificate bootstrap is Cloudflare DNS-01 only. The simplified owner
  decision intentionally lets the same trusted container identity read the CF
  token, ACME state, public keys, and interception CA key.
- Mihomo starts trusted public/interception certificate helpers only after the
  real worker isolation probe. Helpers are serialized process groups, are
  always waited, and are terminated before engine shutdown.
- SIGTERM and managed `/restart` converge on complete orderly shutdown. A
  bounded hard-exit watchdog covers a blocked startup, reload, or operator
  hook. Fatal outcomes remain non-zero.
- Public DoT and controller certificates follow atomic generation-symlink
  changes without process restart. Ordinary same-inode/same-size file rewrites
  also remain reloadable.
- Certificate helpers claim only strict empty directories. Marker publication
  uses same-filesystem staging, fixed no-clobber candidates, exact byte/size and
  ownership validation, and bounded recovery of an empty `0700` directory that
  was interrupted before reaching `0750`.
- Image assembly consumes the independent mihomo and zashboard pins already in
  `install.sh`; there is no second component lock. A stale core without the
  exact `5gpn-container-runtime-v1` handshake cannot enter an image.
- GitHub Release remains exactly three assets. The matching OCI image is a GHCR
  artifact; stable may advance `latest`, beta may not.
- Release publication is resumable but fail-closed: exact image content and
  labels, immutable release identity, tag provenance, stable monotonicity, and
  final `latest` ordering are all revalidated.
- Test-env acceptance now proves its Git root and `HEAD`, compares each
  versioned acceptance input directly with the raw `HEAD` blob, and separately
  binds the core digest and image ID. A dirty or weakened local probe cannot
  emit release evidence merely by repeating an expected commit string.

## Verification completed

All builds and tests were run on `ssh test-env`; no local build or test was
used.

Mihomo:

```text
go test -p 1 -count=1 . ./5gpn ./component/ca ./hub ./hub/route
go test -race -p 1 -count=1 . ./5gpn/... ./component/ca ./hub ./hub/route
go vet -p 1 ./5gpn/...
go build -p 1 ./...
```

All passed. The race suite was serialized because test-env has about 3.8 GiB
RAM and no swap; the earlier whole-repository parallel protocol run was killed
by host memory pressure, not by a Go assertion.

5gpn:

```text
for t in tests/test_*.sh; do bash "$t"; done
bash tests/verify-artifact-pins.sh
docker-compose-v5.4.0 -f compose.yaml config --format json
```

All installer, policy, certificate, release-bundle, and Docker helper tests
passed. Mihomo, zashboard, and all three Gum artifact pins matched their
published assets. Compose v5.4 expanded the single-service schema successfully.

Final Docker 28 development acceptance passed with:

```text
FIVEGPN_CONTAINER_ACCEPTANCE_PROBES_SHA256=d912ead28eaf1d1deac076b07487b5f46446be67994ce0eaf6d546baa7315849
FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_COMMIT=5da2c6c225e5d52c3a99816882e8004d098ad089
FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_MIHOMO_BINARY_SHA256=e582f5aaaf064b99a64f42df7c8d88fac5ad5c6eb96cb2646919db7f56c79eff
FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_IMAGE_ID=sha256:4a9abfa568cb9d2caef4e4dbbf747f50314d1422ebe13107939c3858262ddf85
```

That run covered the real cgroup-FD startup probe, authenticated capabilities,
healthy JavaScript execution, interception signing, a 512 MiB action-cgroup
OOM and its classification, PID 1 survival, public DoT/controller certificate
hot reload without PID replacement, transactional container recreation, and
byte-stable named-volume persistence.

### Development-image qualification

Docker Hub repeatedly timed out while resolving both the digest-pinned
Dockerfile frontend and the digest-pinned Debian base. To finish runtime
acceptance without weakening either pin, the development image was assembled
from the six-day-old local `5gpn:dev-test` image built from the same
Dockerfile/package snapshot, then overlaid with the exact committed runtime,
entrypoint, helpers, UI, component manifest, notices, and labels.

This is valid **development runtime evidence only**. It is intentionally named
`FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_*` and must never be copied into the
three release variables or described as a reproducible release image.

## Publication blocker

`install.sh` still pins `v1.19.28-monolith.29` with compressed-asset SHA-256
`d04749b6b51974a788028b6596a3a2db803ca4144f60f915cd696c181f7a7ae3`.
That published binary predates `5gpn-container-runtime-v1`. Consequently the
new hosted Docker-image job and release image preparation are expected to fail
closed at the container-contract probe until a new mihomo release exists.

Do not bypass that probe or substitute the development binary in a release.

## Exact next steps

1. Review/merge the mihomo runtime branch into the intended
   `feat/5gpn-monolith` delivery line.
2. Build the immutable Linux amd64-compatible mihomo artifact from the reviewed
   runtime commit with `with_gvisor`, `-trimpath`, explicit version/build-time
   ldflags, and an empty build ID. Publish a new mihomo tag and release asset.
3. Download the compressed asset and record its SHA-256. Update every enforced
   runtime version/digest copy in 5gpn together, including `install.sh` and the
   matching checks workflow references.
4. Run all 5gpn shell tests and `bash tests/verify-artifact-pins.sh` again.
5. With Docker Hub access restored, build the exact candidate using the pinned
   BuildKit image, pinned Dockerfile frontend, pinned Debian base, tag commit,
   `SOURCE_DATE_EPOCH`, and `rewrite-timestamp=true`.
6. Run `tests/container-acceptance.sh` in **release mode** from a clean checkout
   at that exact final 5gpn commit, using the compressed mihomo artifact digest.
7. Only after that run, set these repository variables from its output:

   ```text
   FIVEGPN_CONTAINER_ACCEPTED_COMMIT
   FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256
   FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID
   ```

8. Rebuild once more in the release workflow and require the candidate image ID
   to equal the accepted ID before publishing the exact GHCR tag. Stable
   `latest` moves only after the GitHub Release becomes immutable.

## Test-env cleanup state

The development test container, temporary Docker 28 daemon, its remaining
`nsfs` mount, volumes, images, credentials, PKI material, logs, and the
marker-owned `/var/tmp/5gpn-docker-dev` tree were removed after acceptance.

The host gateway was not replaced or restarted:

```text
5gpn-mihomo.service ActiveState=active
MainPID=2964626
NRestarts=0
system Docker running containers=0
```

`/var/tmp/5gpn-codex-019fe480` was deliberately retained because it has no
validated 5gpn ownership marker. Do not recursively delete it without a new,
explicit provenance decision. Other historical `/var/tmp/5gpn-*` paths and an
old interactive TUI process were likewise outside this task's cleanup scope.

## Resume checks

```bash
git -C /Users/moooyo/.codex/worktrees/f7b3/mihomo fetch --prune origin
git -C /Users/moooyo/.codex/worktrees/f7b3/mihomo status -sb
git -C /Users/moooyo/.codex/worktrees/f7b3/mihomo log --oneline origin/feat/5gpn-monolith..HEAD

git -C /Users/moooyo/.codex/worktrees/f7b3/5gpn fetch --prune origin
git -C /Users/moooyo/.codex/worktrees/f7b3/5gpn status -sb
git -C /Users/moooyo/.codex/worktrees/f7b3/5gpn log --oneline origin/main..HEAD
```

Use ordinary non-force pushes. Do not publish a tag, GHCR image, or release
until the new immutable mihomo pin and exact release-mode test-env evidence are
both present.
