# 5gpn Docker integration handoff

**Recorded:** 2026-08-18. **Updated:** 2026-08-22.

This file is a pickup record, not an architecture authority. Read
[`AGENTS.md`](AGENTS.md), [`docs/architecture.md`](docs/architecture.md), and
[`MEMORY.md`](MEMORY.md) first — those define current behavior. This file
records only where the Docker delivery stands and what to do next.

## Current position

| | |
|---|---|
| Code | `main`, `beta`, and `codex/docker-runtime` are all fast-forwarded to the same commit. Confirm with `git rev-parse origin/main origin/beta origin/codex/docker-runtime`. |
| Core and Console | Both released and pinned. `release/pins.env` and `THIRD_PARTY_NOTICES.md` are the only files allowed to name their coordinates. |
| Offline gates | Green in hosted CI on `main`, which is the gate that counts. Do not read a green `test-env` run as equivalent: until 2026-08-22 the suites passed there and failed on every clean runner, because `tests/test_docker_certificate_helpers.sh` depended on a `/run/5gpn` that only the host gateway's presence created. CI had been red on `main` for two days, and `set -euo pipefail` aborted the shell job at the seventh suite, so most suites were not running at all. |
| Image build | Works, and is reproducible — two from-scratch builds of one commit, builder torn down and tree `git clean -xfd`ed in between, produced the identical image ID. |
| Cloudflare DNS-01 | **Works end to end as of 2026-08-22**, verified against a real zone. This was never true before: the first live run obtained a correct wildcard and was then rejected by three of this repository's own assertions. See "What the first real issuance cost". |
| Release acceptance | **PASSED 2026-08-22**, release mode, on the disposable Docker target. It ran three times that day, once per candidate commit, because the revision label sits in the config digest and every new commit is a different image. The run that backs the published tag is `e884aa9`. Interception, DoT steering, SNI sniffing, and the extension lifecycle were verified alongside it. |
| Published artifacts | **`0.0.82-beta.2`, 2026-08-22** — the first Docker delivery ever published. GitHub pre-release with the three installer assets, plus `ghcr.io/moooyo/5gpn:0.0.82-beta.2`. Stable `latest` still points at `0.0.81`, as the beta channel requires. |

**Next action:** none outstanding for the beta. Promoting to a stable `X.Y.Z`
means re-running acceptance against that commit, tagging from `main`, and
accepting that stable does move `latest`.

The `test-env` state after the beta: the host gateway is `systemctl disable
--now`, the Compose deployment is torn down, and both named volumes are kept.
The `test.5gpn.de` certificate in `fivegpn-data` is valid to 2026-11-20, so the
next acceptance run reuses it and spends no ACME order.

## What the first real issuance cost, and what it proved

Recorded 2026-08-22. A real Cloudflare zone and a `Zone:DNS:Edit` token were
supplied, and `CERT_MODE=cloudflare` ran for the first time in this
repository's history. Let's Encrypt issued a correct wildcard on the first
attempt. This helper then refused it, three times over, and the container
restart-looped:

1. Exact file-mode assertions on the lineage. Certbot's modes follow the
   ambient umask, and the entrypoint sets `umask 0077`, so it wrote `0600`
   where the checks demanded `0644` — rejecting the *stricter* state.
2. `live/<domain>/README`. Certbot writes one into every lineage directory.
   `lineage_set_is_exclusive` already tolerated the copy in the live root; the
   inner one was not in any whitelist.
3. `domains =` in the renewal configuration. Certbot 4.0.0, the version Debian
   13 ships and this image pins, does not write that key. Older versions did.

All three are fixed at `5c22abe`, and the assertions now describe invariants
rather than one environment's defaults. Two lessons worth keeping:

- **A path that has never executed is not evidence, however green its gates
  are.** Every one of these survived `bash -n`, 43 suites, and hosted CI,
  because none of them can see a real certificate.
- **Re-test against the artifact, not the tool.** The issued lineage was cloned
  out of the volume and the validators were run against it directly as uid
  10001. That found defect 3 — which only became reachable once 1 and 2 were
  fixed — without spending a second ACME order or stopping the gateway again.

The certificate from that run is still in `fivegpn-data`, valid to 2026-11-20.
Bootstrap accepts it and skips Certbot entirely, so acceptance can be re-run
against it at no ACME cost.

Do not treat any image ID quoted in this repository's history as acceptance
evidence. `VERSION` and `VCS_REF` land in labels and therefore inside the image
config digest, so the ID changes with every commit and every tag string. The
only ID that counts is the one printed by the build of the exact commit that
will be tagged, with the exact tag as `--tag`.

## Resume here

On the acceptance host, build the candidate:

```bash
cd ~/5gpn-release && git fetch origin && git checkout --detach <tagged-commit>
git clean -xfd
FIVEGPN_BUILD_REGISTRY_MIRROR=mirror.gcr.io \
  bash docker/build-candidate-image.sh --tag <exact-future-tag>
```

`--tag` must be the tag that will actually be pushed; it is not cosmetic. The
mirror variable is only needed where `registry-1.docker.io` is unreachable, and
it cannot change the result — every reference it fetches stays digest-pinned.
The command prints the image ID on stdout and nothing else, so
`image_id="$(...)"` is safe.

Then follow [`docs/docker.md`](docs/docker.md) for the container and the
release-mode acceptance invocation.

## Release blockers and required order

All nine steps are complete; `0.0.82-beta.2` is published.

Publication is no longer gated on a record of the acceptance run. Three hand-set
repository variables used to stand there, and the release job compared its own
rebuilt image ID against a value a maintainer had pasted back in -- so the gate
was satisfiable in one paste by exactly the person who would skip the run. It is
gone. Publication binds to the image the release job itself builds and pushes,
and verifies the pushed manifest against those bytes. Running acceptance against
the exact candidate before tagging is now a maintainer's obligation, and nothing
downstream will catch skipping it.

1. ~~Finish and review the Mihomo maintenance integration for the v2 container
   lifecycle, cgroup layout, certificate manager, TLS reload, and orderly
   shutdown.~~ Done: merged into `feat/5gpn-monolith` at `9497ae63`.
2. ~~Run the proportional Mihomo build, race, vet, and acceptance gates remotely
   on `test-env`.~~ Done for the tagged release.
3. ~~Publish immutable container-capable Mihomo and deployment-neutral Zashboard
   releases.~~ Done; the exact coordinates live in `release/pins.env`.
4. ~~Update their paired coordinates in `release/pins.env` and the
   human-readable notice table.~~ Done at `c420626`.
5. ~~Run the full root shell, pin, image, and container-policy gates remotely.~~
   Done on `test-env`. The macOS workstation cannot substitute: most suites need
   bash 4+ and GNU coreutils, and `tests/test_cert_role_ctl.sh` exits zero there
   while emitting no assertions at all, which reads as a pass.
6. ~~Merge to `main` and build the exact reproducible image.~~ Done, but the
   image must be rebuilt whenever `main` moves: the revision label is inside the
   config digest, so the candidate at `40404b6` is not the candidate at today's
   HEAD. Because every merge was a fast-forward, the accepted commit and the
   tagged commit can be the same object; keep it that way. Build only through
   `docker/build-candidate-image.sh`, which the release workflow also calls, so
   the two cannot drift.
7. ~~Run `tests/container-acceptance.sh` in release mode against the exact image
   on the disposable Docker target.~~ **Passed 2026-08-22**, most recently
   against `e884aa9`, the commit `0.0.82-beta.2` was cut from.
   Re-run it against whatever commit is actually tagged; the image ID changes
   with the revision label, so a passing run does not carry forward.

   The certificate inputs are supplied and proven: a real Cloudflare zone, a
   token verified to hold `Zone:DNS:Edit` on it, and an issued wildcard already
   in `fivegpn-data`. Bootstrap accepts that lineage and skips Certbot, so a
   re-run spends no ACME order. Development acceptance mode is not an
   alternative: it requires an image labelled `development-local`, and the
   candidate this repository builds is `pinned-release`.

   What remains is operational:

   - the host gateway must not hold `853/80/443/8080/8443`. `systemctl stop`
     alone is not enough — the unit returns on reboot and will take the ports
     back mid-run. Use `systemctl disable --now 5gpn-mihomo`;
   - a controller secret at `FIVEGPN_CONTROLLER_SECRET_FILE` — a single-link
     mode-0600 regular file of at most 4096 bytes holding one
     16-to-512-character token;
   - a candidate with zero installed extensions, or the extension probe aborts.

   The run is mutating: it stops, renames, and re-creates the container.
8. ~~Record the run's evidence.~~ Done for `e884aa9`, the commit behind
   `0.0.82-beta.2`:

   | | |
   |---|---|
   | accepted commit | `e884aa960a452dcda37d112b5b501d3c98fa1daf` |
   | accepted image ID | `sha256:016332b95c04935048fecad5a4d558ddd33196a6f243dd3cf3a38cebbdfe1ebe` |
   | pinned Core digest | the `MIHOMO_SHA256` in `release/pins.env` at that commit — pin values may appear in exactly two files, and this is not one of them |
   | probe bundle | `344f60be3e7056e183569aacbaad0913573f23e02fe2646be3f9f5545cd5e427` |

   Nothing consumes these. They are here so a later reader can tell which image
   and which probes this tag was accepted against.
9. ~~Publish.~~ Done: `0.0.82-beta.2`. The release job builds the image itself
   and verifies the pushed manifest against those exact bytes; there is no
   separate acceptance gate to satisfy. Move stable `latest` only after the
   GitHub Release is immutable.

   Two things this step turned out to get wrong:

   - **The first publication did not create a private package.** This handoff
     predicted it would and that visibility would need flipping by hand.
     `ghcr.io/moooyo/5gpn:0.0.82-beta.2` answered an anonymous manifest pull
     with 200 on the first try. Nothing had to be changed.
   - **`0.0.82-beta.1` is a dead tag** on the previous commit. Its run reached
     `Build exact-tag Linux amd64 image` — the first time that step had ever
     executed, because every earlier release failed at the acceptance gate that
     preceded it — and aborted: packaging the installer bundle writes into the
     working tree, and the build script refuses a dirty tree. Fixed at
     `e884aa9` with a policy assertion pinning the order. The tag cannot be
     deleted; a repository rule blocks tag deletion, which is the kind of
     enforcement the removed acceptance gate only imitated. It published
     nothing. `ghcr.io/moooyo/5gpn` does not exist yet; the
   first publication creates it **private**, so its visibility must be changed
   before the documented anonymous `docker compose pull` flow works.

   **Publish the first one as a beta.** `release.yml` classifies `X.Y.Z` as
   stable — reachable from `main`, `prerelease=false`, `make_latest=true` — and
   `X.Y.Z-beta.N` as beta, reachable from `beta`, `make_latest=false`. Both
   channels publish a GHCR image. Since the very first publication creates the
   package private, a stable tag would mark a Release latest and make `latest`
   eligible to move while the documented anonymous pull is still broken. A beta
   tag cannot move `latest` by rule, so the package can be created, flipped to
   public, and the whole publish path exercised before any stable tag depends on
   it. `0.0.81` was preceded by `0.0.81-beta.1` through `-beta.4`; keep that
   shape.

Use ordinary non-force pushes. Do not publish a tag, GHCR image, or GitHub
Release until the current pin manifest, exact release-mode evidence, and final
image identity all agree.

## Environment facts that will cost you time

- **The image had never actually been built** before 2026-08-21. The branch was
  unpushed, so the `checks.yml` `docker-image` job had never run, and the
  release job is gated shut. The first real build hit four separate defects in a
  row — an illegal BuildKit builder name, an `/etc/ssl/certs` directory APT
  could not traverse, a Docker Hub the host cannot reach, and a
  nondeterministic ldconfig `aux-cache` that made the image ID unreproducible
  and the release gate unsatisfiable by construction. All four are fixed and
  covered by `tests/test_docker_delivery_policy.sh`. Expect the same class of
  surprise from any other path that has never been executed.
- **`test-env` cannot reach Docker Hub.** `registry-1.docker.io` resolves to a
  poisoned address, so `docker buildx create` cannot pull the driver image. Use
  `FIVEGPN_BUILD_REGISTRY_MIRROR=mirror.gcr.io`, which serves all three pinned
  references. Hosted CI leaves the variable unset and is unaffected.
- **`test-env` runs a live host gateway** on `5gpn-mihomo.service`, holding
  `853/80/443/8080/8443`. Release-mode acceptance needs those ports, so it and
  the gateway cannot run at the same time. Disable rather than stop it: a plain
  `systemctl stop` is undone by the next reboot, and the unit will reclaim the
  ports underneath a later run.
- **A green `test-env` suite can be an artifact of that gateway.** It creates
  `/run/5gpn`, and until `663978b` one suite silently depended on that directory
  existing. The same shape bit twice more the same day: an assertion tied to the
  ambient umask, and a staged Console generation in `scripts/ui-generation.sh`
  whose files inherited the caller's umask and then failed the validation that
  would have fixed them — invisible on CI and as root, both `022`, and only
  reproducible on a login shell with `002`. All three are fixed. When a check
  reads the filesystem, ask what it is really reading before trusting the
  verdict.
- **Do not trust a local test run on macOS.** Most suites need bash 4+ and GNU
  coreutils; on the workstation roughly three quarters fail for environment
  reasons and at least one exits zero without asserting anything. Only the
  pure-grep policy suites are meaningful there.
- **Pin values may appear in exactly two files.** `release/pins.env` and
  `THIRD_PARTY_NOTICES.md`. `tests/test_release_artifact_binding.sh` enforces
  it, so describe the pinned pair by role in prose, never by coordinate.
- **Exiting is not how a container stops retrying.** `restart: unless-stopped`
  restarts on every exit code, and Docker resets its restart backoff after any
  run of ten seconds or more — measured on Docker 29, a container that runs 12s
  and exits restarts every ~15s indefinitely. Anything that wants to stop
  attempting something expensive must hold, not return.

## Valid design

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
- The delivery intentionally accepts weaker trusted-key isolation: the same
  `fivegpn` identity may read the Cloudflare credential, ACME account, public
  private keys, and interception CA key. Untrusted extension code still runs
  only in fresh bounded worker processes.
- Public `:443` maps to the container-only data-plane socket on `:9443`, while
  the load-bearing controller stays on `127.0.0.1:443` and the sniffed target
  remains port 443. The published ingress set has no product `:5060` listener.
- The GitHub Release remains exactly three assets. The same tag may publish
  `ghcr.io/moooyo/5gpn:<tag>` as a separate registry artifact. Stable may move
  `latest` only after immutable GitHub publication; beta never moves it.
- Image preparation consumes the same bound `release/pins.env` and strict
  `release/pins.sh` parser as the host installer. It creates no Docker-only lock
  and requires the Core's exact offline `5gpn-container-runtime-v2` handshake.

## Root adaptation completed

The root Docker implementation follows the current installer and runtime
contracts:

1. Durable `/etc/5gpn/dns.env` contains exactly the six current installation
   coordinates. It contains no controller secret, fixed listener field,
   controller path, certificate path, policy, or runtime tuning field.
2. The controller secret has one persistent source: operator-owned
   `/etc/5gpn/mihomo/config.yaml`. Fresh container bootstrap may generate it
   once into that YAML, but never mirrors it into `dns.env` or another
   credential file.
3. Existing operator YAML is inspected through the pinned Core's owner-scoped
   `5gpn-config inspect-controller --owner-uid` version-2 projection. Existing
   `dns.json`, `intercept.json`, and `bot.json` are validated through
   `5gpn-state validate --owner-uid`; container shell code maintains no second
   schema decoder.
4. The state root and document metadata match the current Core contract. Any
   data volume produced by container-runtime-v1 is rejected unchanged. There is
   no compatibility alias, automatic rewrite, or in-place volume migration.
5. The separate persistent `fivegpn-ui` volume contains the Console and both
   profiles as one complete generation at `/opt/5gpn/ui/current`, including the
   current primary/compat manifests and stable top-level file checks.
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
9. Bootstrap proves writable cgroup delegation before any certificate work, so
   a host missing `cgroup: private` or `writable-cgroups=true` fails with a
   message naming the setting instead of spending a real ACME order first.

## Origin, and the limit of the old evidence

The root Docker branch introduced the single-image delivery in `5da2c6c` and
recorded its pickup state in `ca25ff7`. The runtime branch introduced
certificate reload support in `7370b743` and the managed container lifecycle in
`9b7295f6`, both since merged and released.

Those older branches passed a development-mode Docker 28 acceptance run on
`test-env` covering the cgroup-FD startup probe, authenticated capabilities,
JavaScript execution, a 512 MiB worker OOM, PID 1 survival, certificate hot
reload, transactional recreation, and named-volume persistence. Its candidate
image was assembled from a previously built local base after Docker Hub
timeouts, so it was explicitly development-only.

That evidence is not transferable. It binds an old implementation commit, old
runtime binary, old probe corpus, and old image ID, and must not populate or
satisfy the release variables for any new tag.
