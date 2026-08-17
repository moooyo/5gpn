# Disposable-only disruption and recovery acceptance

> **DISPOSABLE ONLY:** this checklist kills and stops the gateway, interrupts
> installation and identity reconciliation, injects certificate failures,
> replaces lock and filesystem objects, and intentionally reaches partial
> publication states. Run it only with out-of-band access on a target that will
> be rebuilt. Never run it on a working gateway.

The expected result is observed containment and honest recovery reporting, not
a promise that every injected failure can be rolled back. 5gpn has no automatic
installer rollback. Rebuild the target after the run even when every assertion
passes.

Runtime-internal worker OOM, timeout, admission, DNS generation, extension,
and Telegram fault injection belongs to the immutable mihomo disposable
runbook linked from [../integration-smoke.md](../integration-smoke.md). Browser
failure and interaction behavior belongs to the immutable zashboard runbook.

## Prerequisites and fixture ledger

- Start from a disposable current-schema installation produced by the exact
  release under test. Preserve an out-of-band shell that does not depend on the
  gateway data plane.
- Record the exact host or container image digest, root release and bundle
  digest, centralized release-pin manifest digest, component releases and asset
  digests, and the commit or image digest of every DNS, HTTP, ACME, certificate,
  filesystem, and fault-injection fixture.
- Record initial PIDs, `NRestarts`, unit active/enabled states, account and
  group databases, ownership markers, lock inode identities, nftables state,
  operator YAML and runtime document hashes, certificate trees, UI/profile
  hashes, and journal cursors.
- Stop before mutation when any fetched fixture differs from its recorded byte
  length or SHA-256. Do not use branch URLs, moving tags, mutable images, or
  unrecorded extension resources.
- Do not run another installer, renewal, certificate publisher, management
  command, or acceptance checklist concurrently unless the specific step says
  the concurrency is the fixture under test.

## 1. Monolith crash and deliberate stop

- [ ] Record immutable configuration hashes, the main PID, and `NRestarts`,
  then send `SIGKILL` to only the main process through systemd. Within the
  documented restart window, the complete unit becomes active with a new PID
  and a higher restart count.
- [ ] The operator YAML and all current runtime documents remain byte-identical
  across the crash. DoT, the authenticated controller, public UI/profiles, and
  one ordinary forwarding request recover together; connections present at the
  crash are allowed to fail.
- [ ] Stop `5gpn-mihomo.service` deliberately and wait longer than
  `RestartSec`. `MainPID` remains zero because an operator stop is not undone by
  `Restart=always`. Start it explicitly before continuing.
- [ ] Pause configure after its root gate helper acknowledges the exact
  `TryRestartUnit` job. Record that the job ID/object path is unchanged as its
  type becomes `start`, the unit is `activating/start-pre`, Core's service
  account is process-free, and the helper is the root `ControlPID`.
- [ ] Issue an ordinary operator `systemctl stop` at the blocked gate. The stop
  replaces the pending restart, terminates the helper cleanly, removes the
  original job, and leaves the unit `inactive/dead`; neither `Restart=always`
  nor configure submits another start.
- [ ] Repeat with `systemctl kill --kill-whom=control --signal=TERM` and direct
  `kill -TERM <ControlPID>` while no stop job exists. Both fail the start and
  never reach MainPID; neither signal is accepted as gate release.
- [ ] An independent monitor outside the host observes the DoT and HTTPS outage
  and clears only after recovery. No in-process heartbeat is accepted as
  evidence that the process itself is alive.
- [ ] Force a deterministic startup error until the configured start limit is
  reached. The unit remains failed with `StartLimitAction=none`; the host is not
  rebooted or powered off and no configuration is rewritten as repair.

## 2. Fail-before-publication and partial publication

- [ ] Inject independent failures during platform, path, unit, identity,
  certificate, release-pin parsing, artifact, operator-YAML, and state-document
  preflight. Every
  pre-publication failure leaves managed services, accounts, units, roots,
  markers, certificates, binary, Console, and live documents at their
  before-values.
- [ ] Repeat with a dependency-package action that succeeds before a later
  project gate fails. The installer reports the package side effect explicitly
  and does not claim that shared distribution state was rolled back.
- [ ] Interrupt after the declared publication boundary at each sequential
  binary, Console, unit, account, certificate, state, and service step. The
  installer reports a partial installation and the last completed boundary; it
  never restores an unverified snapshot or prints a success banner.
- [ ] A deliberately mixed Core/Console capability pair fails closed. A
  transient or interrupted cross-artifact publication is never classified as a
  releasable state, and the next run re-enters full current-schema preflight.
- [ ] Replace or remove the retained quick installer used for a channel switch,
  or make it linked or non-root-owned. Delegation fails closed before selecting
  mixed release inputs and directs the operator to a newly verified quick
  installer.
- [ ] Hold an installed management command on the install lock while another
  transaction replaces `install.sh` or the release-pin pair. After it acquires
  the lock, the queued command rejects the stale backend before reading or
  changing runtime state and asks the operator to rerun `5gpn`. If publication
  was interrupted between the script and pin files, recovery starts only from
  a newly downloaded, digest-verified external quick installer; the mixed
  installed CLI is not trusted as its own repair tool.
- [ ] Force the final service start and each readiness probe to fail. The
  operation reports failure with the current installation phase, preserves the
  observable partial state, and never claims successful completion.

## 3. Identity reconciliation interruption

- [ ] With safe current provenance and exclusive system-range IDs, interrupt
  immediately after identity journal publication. The next run validates the
  same journal and resumes without deleting or adopting any unrelated identity
  or path.
- [ ] Interrupt after account removal but before recreation. Recovery still
  requires a safe current marker or marked unit, the exact valid journal, and
  proof that no other user or group claimed the recorded IDs. An exact
  surviving `fivegpn` group may retain only its recorded GID.
- [ ] Claim the recorded UID or GID with another identity, add a supplementary
  group, create a primary-GID alias, move an ID into the normal-user range, or
  corrupt the journal. Recovery fails read-only and does not recurse through
  managed roots with ambiguous numeric ownership.
- [ ] Interrupt during the managed-root ownership sweep. The journal remains
  until every validated root is reconciled, and the next run resumes only
  within those exact roots. It never treats the journal itself as ownership
  proof.
- [ ] Exercise a group-only journal with all three runtime documents absent,
  then add one document. The absent-document case may resume; the present file
  blocks until a proven owner UID exists.

## 4. Public certificate and timer recovery

- [ ] Begin with known distro `certbot.timer` active/enabled states. Inject a
  failure or signal after the installer changes that timer but before scoped
  renewal is enabled and active. Cleanup restores the exact prior active and
  enabled state without masking the original error.
- [ ] With an owned production lineage, let scoped renewal commit successfully.
  The distro timer remains disabled only after the project timer is both
  enabled and active. A host with another lineage that depends on the distro
  timer fails before takeover.
- [ ] Hold the installer lock and start public renewal. The renewal service
  exits before taking the certificate lock or invoking Certbot. Release the
  lock and confirm the next normal run uses the same static scoped service.
- [ ] Force Cloudflare issuance and renewal failures. Mihomo remains running,
  the prior public role files and profiles remain complete, and the failed
  candidate is never published.
- [ ] For configure HTTP-01, inject wrong or non-unique A, any AAAA, ACME bind
  failure, Certbot failure, publication failure, signal interruption, and gate
  release failure separately. Certbot never starts or stops Core. Before any
  visible publication, only the same still-blocked PID1 job may be released;
  after a visible role/file/profile commit the unit remains inactive and the
  exact partial failure is reported.
- [ ] Kill configure after gate creation but before the returned job identity is
  durably bound, after ACK, before publication, and after publication. A later
  configure releases only a record whose exact original job, ACK, root control
  PID, invocation, and restoration entitlement remain live. Every unbound,
  canceled, replaced, or post-publication case is cleaned while Core stays
  inactive; recovery never creates a new start job.
- [ ] Interrupt public role and UI/profile publication at each file, fsync, and
  rename boundary. Public certificate roles retain their documented sequential
  boundary: failure before the first current leaves both old roles selected;
  failure after one role commits is reported as `committed-partial`, never
  rolled back, and a later run repairs forward. A post-current directory sync
  failure is `committed-undurable`. Run
  `tests/publication-fs-mount-acceptance.sh` and
  `tests/cert-role-mount-acceptance.sh` only inside the disposable private mount
  namespace; bind-mounted role roots, generation scopes, generations, and
  nested paths must fail closed without changing the external sentinel.
  Combine an authorized old/new service GID split with safe `.new.*`,
  `.delete.*`, and `.current.*` residues. Record every UID, GID, digest, and
  pointer target: read-only recoverability must accept the exact state without
  writing, locked repair must converge it, and strict current validation must
  pass afterwards.
  UI/profile candidates never change current before the complete tree
  is verified and durable; after the current rename, a directory-fsync failure
  is reported as committed-but-unconfirmed and is never rolled back. Retired
  `web` material is never published.
- [ ] Interrupt a fresh install after the UI root/candidate exists but before
  the first current symlink. The installer explicitly reports a partial
  publication, the service startup precheck refuses to open listeners, and a
  rerun may clean only ownership-proven unpublished candidates. During
  reinstall and profile refresh, every pre-switch interruption leaves the old
  current generation byte-identical and online.
- [ ] Run the not-due, successful, DNS-gate failure, Certbot failure, deploy
  failure, and service-restore cases through both the systemd timer and the
  explicit host action. They use the same scoped helper and report equivalent
  outcomes.

## 5. Interception certificate publisher recovery

- [ ] Hold the certificate lock while publishing rapid A, B, and C host-set
  requests, then release it. Results for A or B cannot make a stale set ready;
  only a result with C's target digest, attempt fence, exact keypair hashes,
  validity, and complete SAN set may commit.
- [ ] Interrupt before certificate write, between certificate and key writes,
  before hash-bound result publication, and after result publication. Partial
  keypair bytes never become ready, and a later invocation converges from the
  durable request/result boundary without changing the interception document
  revision.
- [ ] Publish a current-attempt error, request an authenticated retry, and then
  deliver a late result for the old attempt. The retry uses a fresh attempt and
  ignores the stale result. An empty host set commits ready without material
  hashes.
- [ ] Hold the installer lock while triggering the path/timer publisher through
  the supported certificate-lock handoff. The oneshot never bypasses the
  inherited lock identity, gains network access, or exposes the CA key to
  `fivegpn`.

## 6. Hostile filesystem and lock fixtures

- [ ] For each exact non-sensitive fixed root, inject a symlink, hardlinked
  regular file, FIFO, socket, device, unsafe owner/mode, known legacy child, or
  nested mount before first claim. Preflight refuses the root and publishes no
  marker. A safe regular-file-only populated fixture is claimed without
  deleting or rewriting its existing bytes.
- [ ] Repeat link, special-entry, marker, and nested-mount attacks against the
  stricter certificate, interception-CA, UI, and temporary trees. None may use
  the populated-unmarked fixed-root exception.
- [ ] Replace an ownership marker after read-only preflight but before the
  publication recheck. Replace a lock pathname while an inherited descriptor
  still names the old inode. Both operations fail closed before recursive
  ownership change or key publication.
- [ ] Replace a public certificate role, interception TLS tree, keypair file,
  runtime document, operator YAML, unit file, or managed script with a symlink
  or hardlink at each checked boundary. The relevant helper refuses it and
  preserves the previously committed live object.
- [ ] Attempt recursive cleanup with `/`, a system directory, an unowned custom
  path, invalid or retired marker, symlinked canonical root, or nested mount.
  Cleanup refuses every target. A valid marked disposable root deletes only its
  own checked contents.
- [ ] Introduce every retired footprint while a current service is active.
  Compatibility preflight reports it without stopping the service, changing
  accounts, altering permissions, or modifying the footprint.

## 7. Final containment evidence

- [ ] Host firewall, nftables, routing, TUN/TProxy, WireGuard, and unrelated
  service state match the initial snapshot after every isolated fixture except
  for explicitly recorded shared package effects.
- [ ] No failure path claims automatic rollback. Every result identifies
  whether it occurred before publication or during a partial installation.
- [ ] Secrets, private keys, Telegram tokens, descriptor-backed Authorization
  headers, and extension source bytes are absent from process listings,
  screenshots, shell tracing, and the evidence archive.
- [ ] Every skipped case has a reason, and every mutation is tied to an exact
  fixture identity and timestamp.

Revoke disposable credentials and destroy or rebuild the target. Do not use a
fault-injected installation as a production or shared test gateway.
