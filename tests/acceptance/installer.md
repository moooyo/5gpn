# Disposable-only installer acceptance

> **DISPOSABLE ONLY:** this checklist installs, reconfigures, resets, and
> removes 5gpn state. It may change packages, accounts, units, certificates,
> and files. Never run it on a working gateway or a host carrying
> unrecoverable operator state. Rebuild the target after the run.

This checklist owns the root repository's installer and publication boundary.
It does not duplicate mihomo runtime algorithms or zashboard visual and
interaction acceptance; use the immutable links in
[../integration-smoke.md](../integration-smoke.md) for those surfaces.

## Prerequisites and evidence

- Use a disposable Linux amd64 host or isolated systemd container with kernel
  5.7 or newer, systemd 257 or newer, pure cgroup v2, and the memory and pids
  controllers available.
- Provide out-of-band access and an explicit rebuild path. Installer rollback
  is not an acceptance assumption.
- Record the exact 5gpn release tag and installer-bundle digest, the independent
  `release/pins.env` digest, mihomo and zashboard release tags and asset
  digests, the host image digest, and every DNS, HTTPS, ACME, and certificate
  fixture digest.
- Verify every fixture before the first mutation. Do not use a branch name,
  moving tag, raw `main` or `beta` URL, or unqualified container tag.
- Capture the initial account database, unit definitions and state, managed
  root metadata, relevant certificate lineage bytes, operator YAML and runtime
  document hashes, and the complete nftables ruleset outside the target's
  managed roots.

No extension input is required by this checklist. If a cross-component fixture
needs an extension, use only the immutable fixture and digest ledger named by
the pinned mihomo or zashboard acceptance document; never substitute a current
branch URL.

## 1. Release resolution and bundle binding

- [ ] A normal quick install selects the newest official `X.Y.Z` release and
  ignores prereleases. `--beta` selects only the newest published
  `X.Y.Z-beta.N` whose base is newer than the newest official release.
- [ ] An older beta line, missing or malformed metadata, cross-channel tag,
  normal release with a beta-looking tag, beta tag selected for the official
  channel, or unreachable verified release fails before project publication
  and never falls back to a branch or the other channel.
- [ ] Channel selection happens before bundle download and resolves one exact
  5gpn tag for the complete operation. The packaged installer is stamped with
  that tag and cannot combine its templates with another release's artifacts.
- [ ] `checksums.txt` authenticates `5gpn-installer.tar.gz` and
  `THIRD_PARTY_NOTICES.md`. The bundle contains installer inputs only and does
  not republish mihomo or zashboard. It contains the exact `release/pins.env`
  and `release/pins.sh` pair used by every artifact consumer, and `install.sh`
  carries derived digest bindings for that exact pair and bundled
  `quick-install.sh`.
- [ ] The installer obtains the exact independent mihomo and zashboard assets
  named by the strictly parsed manifest, verifies both SHA-256 values before
  publication, and changes the paired pins in one root-repository revision.
- [ ] Missing, symlinked, hard-linked, malformed, duplicate, unknown,
  incomplete, quoted, whitespace-bearing, non-ASCII, control-byte, or
  unapproved release-pin input fails
  before any artifact download or project publication. No pin file is executed
  as shell code and no caller environment value becomes a release coordinate.
- [ ] The release publishes exactly the documented root assets. Installed
  files retain the exact release tag and the root-owned
  `/opt/5gpn/release/{pins.env,pins.sh}` coordinates used by the run; no mutable
  source URL becomes an installed input.

## 2. Fresh installation and publication order

- [ ] A first installation without a usable TTY fails closed before project
  publication. With a TTY, Gum is bootstrapped before configuration prompts;
  an unavailable or invalid Gum artifact falls back to plain output without
  installing unverified bytes.
- [ ] Configuration is accepted only from the TUI or an existing valid current
  `dns.env`, never from caller environment variables. The persisted file has
  the exact current key set, strict quoting and mode, and no controller secret
  or retired key.
- [ ] Read-only host, path, legacy, unit, identity, platform, certificate, and
  current-document preflight completes before any managed service stop,
  account change, root claim, certificate issuance, or live publication.
- [ ] The installer stages and digest-verifies Core and Console, validates the
  operator YAML with the pinned Core, runs the Core's real
  `5gpn-state validate --owner-uid` against the absolute state directory, and
  jointly verifies all six systemd candidates before publication.
- [ ] Missing runtime documents remain valid fresh-seed inputs and are not
  created by preflight. Any present document must be a no-follow regular,
  singly linked, mode-`0600` file owned by the proven current UID and valid for
  the staged Core's exact schema. A fresh state root is published as exact
  service-owned `0711`; an interrupted inherited-setgid `2711` root is
  normalized on the next current-schema run before any document publication.
- [ ] The four exact non-sensitive fixed roots may claim safe populated,
  unmarked contents only after all canonical-path, metadata, legacy, symlink,
  hardlink, special-entry, and nested-mount checks pass. Invalid or retired
  markers are never replaced. Certificate, CA, UI, and temporary roots remain
  strict.
- [ ] Publication begins only after the complete read-only gate and staging
  gate pass. The binary and complete Console tree are published before the
  runtime starts on the new pair. Hidden Console metadata is preserved.
- [ ] Service readiness requires the exact unit, listener, controller, UI,
  profile, capability, certificate, and state-validation boundaries. A failed
  start or readiness probe never prints a completion banner.

## 3. Current-schema reinstall and configuration boundaries

- [ ] A current-schema reinstall preserves a valid operator-owned
  `/etc/5gpn/mihomo/config.yaml` byte-for-byte, including custom proxies,
  providers, groups, rules, and operator listeners.
- [ ] Reinstall preserves valid current `dns.json`, `intercept.json`, and
  `bot.json` bytes and their owner/mode/link boundaries. The staged Core, not a
  shell JSON decoder, is authoritative for current-schema validation.
- [ ] Reinstall replaces only the exact current managed script and unit lists;
  retired managed helpers cannot survive as compatibility aliases.
- [ ] A normal `configure` operation preserves the complete operator YAML and
  runtime documents. Host-coordinate changes use the explicit checked
  installer transaction and cannot leave `dns.env`, the Core's
  installation-owned DNS projection, or the live gateway boundary split.
- [ ] The installed main unit and staged copy are byte-identical, PID 1 reports
  `NeedDaemonReload=no`, and the first `ExecStartPre` is the bundle's exact
  root-owned `configure-runtime-gate.sh`; it is the only command carrying the
  `+` privileged-exec prefix. The following UI validator and main process still
  run with their declared `fivegpn` credentials and sandbox.
- [ ] Any certificate-role publication, gateway update, or other
  runtime-affecting configure transaction creates one private
  nonce, submits one systemd `TryRestartUnit` with job mode `fail`, and records
  the returned job ID/object path. PID 1 stops Core and holds the start phase in
  the nonce-acknowledging `ExecStartPre`; configure never issues a later
  independent `StartUnit`.
- [ ] Stop Core directly while that gate is blocked, immediately before gate
  release, and immediately after release. In every case the operator stop
  replaces or stops the same PID1 job and remains inactive; configure does not
  enqueue a replacement start. An initially inactive unit also remains
  inactive.
- [ ] Send TERM directly to each pre-start `ControlPID` without submitting a
  stop job. The helper rejects the signal as non-operator, the start fails, and
  no MainPID appears. Only a current PID1 `stop` job permits a clean TERM exit.
- [ ] Explicit `mihomo-reset` is available only on a current-schema deployment.
  It validates the complete candidate first, keeps a previous-file backup, and
  publishes atomically. A failed candidate leaves the original bytes intact;
  no custom YAML content is silently merged.
- [ ] A deliberate stopped state is not misreported as crash recovery. Normal
  service-start behavior follows the selected operation rather than promising
  to repair deterministic host or configuration errors.

## 4. Compatibility and identity refusal

- [ ] Introduce each unsupported footprint independently: retired unit
  definitions, generic `mihomo` user or group, old project identities,
  unprefixed binary, retired state or cache paths, retired `dns.env` keys,
  retired document schema or certificate role, and retired mihomo constructs.
  Preflight reports the exact conflict read-only before publication and leaves
  every byte, link, owner, mode, account, and unit state unchanged.
- [ ] No migration, teardown, schema conversion, state salvage, compatibility
  alias, or automatic legacy adoption path is offered. The operator must
  decommission the old footprint outside 5gpn or rebuild the host.
- [ ] An incompatible same-named `fivegpn` identity without safe current marker
  or marked current-unit provenance is rejected unchanged. Normal-range IDs,
  UID/GID aliases, shared membership, supplementary groups, and unsafe
  journals are always rejected.
- [ ] With safe current provenance, exclusive system-range IDs may enter the
  journaled reconciliation transaction. The journal is not ownership proof,
  numeric IDs cannot be reused by another identity, and it clears only after
  managed-root ownership reconciliation succeeds.
- [ ] A group-only recovery journal is accepted only while all three runtime
  documents are absent. Any present document requires a proven current or
  journaled owner UID before the staged Core reads it.

## 5. Certificates, renewal, UI, and profiles

- [ ] `CERT_MODE` accepts exactly `cloudflare`, `http-01`, and `debug` through
  the current configuration flow. Debug material is published only below
  `/etc/5gpn/debug-cert` and never modifies Let's Encrypt archive bytes.
- [ ] Both production modes use the exact scoped `<base>` Certbot lineage. An
  invalid, partial, expiring, mode-mismatched, or unowned ambiguous lineage is
  rejected before Certbot mutation; a fully valid external lineage is reused
  read-only without transferring ownership, pausing the distro timer, or
  enabling the project timer. A retained ownership record for another base is
  unrelated, and an old selected base or production mode does not create a late
  rejection of a new strictly validated external source. A source/ownership
  conflict for the current base fails before dependency or project publication.
- [ ] `.provenance` identifies only the certificate source currently selected
  for the role copies. Returning from debug or repairing `missing` classifies
  the live canonical lineage again from the exact-base `.certbot-ownership`
  record plus its current certificate and renewal fingerprint. Owned reuse is
  zero-Certbot; external reuse installs the deploy hook first and proves the
  published roles still equal the live source. The renewal helper requires both
  current `owned` provenance and the independent exact-base ownership record.
- [ ] Explicit owned-lineage decommission validates the complete lineage, then
  withdraws owned-renewal provenance and removes and durably syncs only that
  base's ownership entry before Certbot deletion. A crash or deletion failure
  leaves the lineage external/read-only without restoring either authority.
  Repeating decommission with an already absent lineage marks it missing and
  clears a stale exact-base entry without invoking Certbot or touching
  ownership retained for another base. The Services screen reports renewal as
  healthy only when configured base/mode, current provenance, and exact-base
  ownership agree. The certificate publication helpers remain installed until
  role, debug-certificate, credential, and interception-CA removal completes.
- [ ] Owned Cloudflare issuance has the exact apex and wildcard SANs and never
  stops mihomo. HTTP-01 requires the exact `console` and `dot` A/AAAA gate,
  uses only the bounded standalone `:80` window, and publishes the verified
  lineage before the normal service-start phase.
- [ ] The static Certbot service and timer bytes match the release bundle and
  were included in the same pre-publication six-unit verification as the main
  and interception-certificate units.
- [ ] Only a proven owned production lineage enables scoped renewal. Debug and
  external provenance disable the scoped timer without deleting its static
  unit files or changing an external renewal owner.
- [ ] Successful public certificate publication updates only the current `dot`
  and `console` roles. The installed
  `/opt/5gpn/scripts/{publication-fs.sh,cert-role-ctl.sh}` files are regular,
  root-owned, mode `0755`, singly linked, and are the helpers bound by every
  certificate-role reader and writer. The complete Console distribution, `.zash_version`,
  disjoint `.zash_primary_files` and `.zash_compat_files` manifests, hidden
  build metadata, and both signed profiles are
  assembled in one unpublished UI generation before the relative `current`
  symlink changes once. A retired `web` role or unsafe certificate tree fails
  before publication.
- [ ] The exact profile-input manifest binds the DoT signer leaf and public
  key, interception-CA DER, domain, gateway, and both CMS digests. It contains
  no private-key digest or secret, rejects unknown/duplicate keys, and scoped
  renewal repairs a stale manifest even when certificate role copies already
  match the live lineage.
- [ ] `/opt/5gpn/ui` contains only its marker, `generations`, and relative
  `current`; each retained generation is root-owned, singly linked, contains no
  special entry or nested mount, and is complete. Profile responses have the
  explicit Apple media type and contain no controller secret. The installer
  does not edit the host MIME database.
- [ ] Serve an A index that names an A-only hashed asset, stage a B distribution
  with a mutually exclusive B asset, and switch current between the two
  requests. The A asset remains readable from the B current generation, while
  B top-level index/manifest/worker files are the new bytes. A same asset path
  with different bytes fails before current changes.
- [ ] Compatibility assets come only from the immediately previous primary
  manifest and never enter the new primary manifest. Stable favicon, PWA icon,
  manifest, registration, worker, and no-cache URLs exposed by A remain present
  and generation-local in B; arbitrary A top-level files are not carried.
- [ ] The interception CA remains a separate root-owned trust boundary. The
  runtime reads only the constrained non-CA leaf and cannot read the CA key.

## 6. Host non-ownership and cleanup

- [ ] Fresh install, current reinstall, configure, reset, uninstall, and purge
  leave the captured nftables ruleset, `/etc/nftables.conf`, firewall service
  state, policy-routing tables, and unrelated network facilities unchanged.
- [ ] 5gpn creates no TUN, TProxy, WireGuard, fwmark, NAT forwarding rule, or
  host firewall table.
- [ ] Recursive cleanup accepts only an exact canonical safe root with a valid
  current ownership marker and no nested mount. Every recursively deleted UI
  candidate or generation also carries and revalidates its own marker. `/`,
  system directories, symlinked roots, unowned custom paths, invalid markers,
  unsafe current links, and unmarked generation children fail closed.
- [ ] Normal uninstall and purge preserve the interception CA and any external
  public lineage according to the documented enrollment boundary. Explicit
  decommission removes only ownership-proven material.
- [ ] A failure before project publication leaves managed services, accounts,
  units, roots, and live files unchanged. Shared distribution package changes
  are reported separately and are never described as rolled back.

## Completion evidence

Record the final installed release, component versions and digests, file and
unit inventories, readiness results, and every intentionally skipped check.
Compare all host non-ownership snapshots with their before-values. Rebuild the
disposable target; do not promote it to a working gateway merely because the
checklist passed.
