# Copilot instructions

Follow `AGENTS.md`. Read `docs/architecture.md` before architectural changes;
it is the sole current-architecture reference. Historical plans, fixtures, and
handoffs are context only.

## Current system

- The `moooyo/mihomo` fork is the only long-running process. The installed unit
  is `5gpn-mihomo.service`, the executable is
  `/opt/5gpn/bin/5gpn-mihomo`, and the sole managed Unix identity is
  `fivegpn:fivegpn`.
- Client DNS ingress is DoT `:853` only. The same process owns DNS policy,
  forwarding, native-extension interception, the Telegram control plane, and
  the authenticated controller API.
- Product API routes are `/5gpn/*`, capability keys are `5gpn-*`, and runtime
  documents live under `/etc/5gpn/mihomo/5gpn`.
- HTTP/3 interception is unsupported and the fixed UDP/443 `REJECT` guard is
  mandatory. HTTP/H1/H2 interception remains available on explicitly enabled
  capture hosts.
- `/etc/5gpn/mihomo/config.yaml` is operator-owned. Normal install, reinstall,
  and configure operations preserve it; only an explicit validated reset may
  replace it.
- Runtime source belongs in `moooyo/mihomo`, Console source belongs in
  `moooyo/zashboard`, and first-party extension source belongs in
  `moooyo/5gpn-extensions`. This repository ships only the installer, templates,
  operational scripts, tests, and digest-pinned release coordinates.

Do not add a sidecar, second controller origin, public DoH or plain DNS,
TUN/TProxy, host firewall management, policy-routing machinery, or an in-process
subsystem supervisor. Expected operation failures stay local; unrecoverable
runtime invariants terminate the monolith and systemd applies the bounded
restart policy.

## Development checks

From the repository root:

```bash
for t in tests/test_*.sh; do bash "$t"; done
tests/verify-artifact-pins.sh
```

CI also renders the seed and validates it with the exact mihomo version and
digest pinned by `install.sh`. Keep `.github/workflows/checks.yml` synchronized
with that pair.

When behavior changes, update `AGENTS.md`, `MEMORY.md`,
`docs/architecture.md`, the relevant shell policy tests, and
`tests/integration-smoke.md` together. Preserve the Gum-or-echo installer
policy, filesystem ownership markers, fail-before-publish checks, certificate
boundaries, and operator-owned configuration contract.
