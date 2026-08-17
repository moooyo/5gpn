# 5gpn acceptance index

This file is an index, not an executable checklist. Acceptance is split by
ownership and mutation risk so a routine deployment check cannot accidentally
become a failure-injection run.

## Safety classes

- **READ-ONLY** means no controller write, installer invocation, mutating
  management command, service signal, restart, stop, file write, lock
  occupation, package action, certificate issuance, or deliberate resource
  exhaustion. Read-only Core inspection is allowed. Ordinary DNS and HTTPS
  requests may populate the same bounded in-memory caches and logs as normal
  client traffic, but they must not change durable configuration or host state.
- **DISPOSABLE ONLY** means the checklist changes host or controller state,
  publishes files, stops or kills processes, injects failures, or tests hostile
  filesystem layouts. Run it only on a host or container that can be rebuilt
  after the run. A working gateway is never an acceptable target.

If a read-only step would require mutation on the selected deployment, mark it
blocked and move the investigation to a disposable environment. Do not widen
the safety class in place.

Within this root repository, only `deployment-smoke.md` is authorized by this
index for a working gateway. There is no executable root acceptance mega-suite:
`tests/test_*.sh` are source regressions, not deployment runbooks. A shell
command is not made read-only by its name or by an attempted restore; any
controller write attempt, including a write expected to be rejected, belongs
on a disposable target. An external runbook cannot widen this root
release/acceptance policy.

## Checklist ownership

| Checklist | Safety class | Owned scope |
| --- | --- | --- |
| [deployment-smoke.md](deployment-smoke.md) | **READ-ONLY** | Installed release identity, managed files and units, systemd policy, listeners, DoT, public UI/profile delivery, authentication boundaries, and one established cross-repository forwarding path. |
| [acceptance/installer.md](acceptance/installer.md) | **DISPOSABLE ONLY** | Release resolution, artifact pins, fresh install, current-schema reinstall, configure/reset boundaries, host ownership, identity recovery, certificates, profiles, and cleanup policy. |
| [acceptance/disruption-recovery.md](acceptance/disruption-recovery.md) | **DISPOSABLE ONLY** | Process crash/stop behavior, interrupted publication, certificate and timer failure recovery, hostile filesystem fixtures, lock replacement, and partial-install reporting. |

Runtime behavior implemented inside mihomo is accepted in the mihomo
repository at immutable documentation commit
[`aba0cfcea5ebeda580ab63e174fd17146c3ef962`](https://github.com/moooyo/mihomo/commit/aba0cfcea5ebeda580ab63e174fd17146c3ef962):

- [read-only runtime smoke](https://github.com/moooyo/mihomo/blob/aba0cfcea5ebeda580ab63e174fd17146c3ef962/acceptance/runtime-smoke.md)
- [disposable runtime acceptance](https://github.com/moooyo/mihomo/blob/aba0cfcea5ebeda580ab63e174fd17146c3ef962/acceptance/runtime-disposable.md)
- [runtime acceptance ownership and evidence rules](https://github.com/moooyo/mihomo/blob/aba0cfcea5ebeda580ab63e174fd17146c3ef962/acceptance/README.md)

Browser rendering and Console interaction are accepted in the zashboard
repository at immutable documentation commit
[`cf3d018ffa20eae0297c434b7a185b0d69f43b66`](https://github.com/moooyo/zashboard/commit/cf3d018ffa20eae0297c434b7a185b0d69f43b66):

- [5gpn Console acceptance](https://github.com/moooyo/zashboard/blob/cf3d018ffa20eae0297c434b7a185b0d69f43b66/docs/5gpn-console-acceptance.md)

The immutable zashboard runbook permits some restored controller mutations on
an explicitly designated current-schema gateway. Root release/acceptance
scheduling does not inherit that permission: if any zashboard step sends a
controller mutation, its target is **DISPOSABLE ONLY**. A planned restore does
not make the step read-only or authorize it on a working gateway.

These root runbooks do not repeat DNS-engine concurrency, worker admission,
extension execution, Marketplace rendering, responsive layout, or browser
interaction assertions. They prove that the exact pinned Core and Console were
installed together and that their public and authenticated boundaries are
wired correctly.

## Evidence and immutable inputs

Every run records:

- the exact 5gpn release tag and installer-bundle SHA-256;
- the exact mihomo release tag, binary SHA-256, version output, and Git commit;
- the exact zashboard release tag, `dist.zip` SHA-256, and displayed commit;
- host or container identity, OS, kernel, systemd version, architecture, and
  start/end timestamps;
- the exact commit or image digest of each controlled DNS, HTTP, TLS, ACME, or
  fault-injection fixture; and
- every skipped assertion with its reason.

Do not use a branch name, a moving tag, an unqualified container tag, a raw
`main` or `beta` URL, or an extension resource without a recorded byte length
and SHA-256. Stop before mutation when any fetched object differs from its
recorded digest.

## Recommended order

1. Verify release and fixture identities before touching the target.
2. Run the root [read-only deployment smoke](deployment-smoke.md).
3. Run the immutable mihomo read-only checklist for runtime-internal coverage.
4. Use separate disposable targets for installer and disruption acceptance and
   for the mihomo disposable runtime checklist.
5. Run the immutable zashboard checklist on a disposable target whenever any
   controller mutation is in scope. Root scheduling never treats restoration
   as permission to mutate an explicitly designated working gateway.

Never run disposable checklists concurrently against the same target. Record
the complete ledger before interpreting a result.
