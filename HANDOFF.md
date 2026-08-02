# Handoff — 5gpn monolith, 2026-08-02

Working state, not documentation. `docs/architecture.md` is the normative
description of the system; this file is what a next session needs in order to
pick the work up, and it should be deleted when the milestones it tracks are
done.

## Where things are

Three worktrees, all clean, all committed, nothing pushed.

| Worktree | Branch | Head |
| --- | --- | --- |
| `D:/Code/worktrees/mihomo-5gpn-monolith` | `feat/5gpn-monolith` | `215a9697` (25 commits) |
| `D:/Code/worktrees/zashboard-5gpn-console` | `feat/5gpn-console` | `02793c0` (4 commits) |
| `D:/Code/worktrees/5gpn-installer-tui` | `feat/installer-tui` | `009cd98` (7 commits) |

**`v0.1.0-beta.1` is packaged and running on `test-env`** as a single
`mihomo.service`. The three retired units are stopped and disabled. Rollback
material is under `/root/5gpn-pre-monolith-*/`.

## What is done

- **M4** — `gpn/dns` is the whole decision engine. Ordered policy (one walk,
  first match wins across intents, fallback folded into the decision), CN
  arbitration by set membership, ECS on the china group only, cache with a
  flush-epoch guard, single flight, query log, subscriptions, and upstream
  groups over UDP/DoT/DoH.
- **M6** — the DNS document surface, the full interception surface, and
  manifest review → install → update check → apply. Every write quotes a
  revision; `409` returns the current one. **Missing: marketplace, Telegram
  bot.**
- **M7** — `GpnDnsPage.vue` and `GpnExtensionsPage.vue`, capability-gated, four
  languages. **Missing: the bot config page** (there is no bot to configure).
- **M8** — partially. The unit set is collapsed; state and config migration
  scripts exist and are verified on a live host. **The `install.sh` body is
  not done.** No TUI.
- **M9** — `scripts/package-beta.sh` produces the bundle;
  `scripts/upgrade-to-beta.sh` inside it moves a provisioned host across.

## Verification, and how to reproduce it

**Go** — run it the way CI does, which on this box means WSL:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/mihomo-5gpn-monolith \
  && gofmt -l ./gpn/ && GOOS=linux go vet ./gpn/... \
  && GOOS=linux go build ./... \
  && CGO_ENABLED=1 go test -race ./gpn/... -count=1"
```

`gofmt -l` on the *working tree* reports false positives — the tree is CRLF and
the index is LF. Check the committed content if it disagrees.

**Installer suites** — 18 of 27. They need an LF copy under Linux:

```
wsl -e bash -lc "rm -rf /tmp/5gpn-lf && mkdir -p /tmp/5gpn-lf \
  && cd /mnt/d/Code/worktrees/5gpn-installer-tui \
  && tar --exclude=./.git --exclude=dist -cf - . | (cd /tmp/5gpn-lf && tar xf -) \
  && cd /tmp/5gpn-lf && grep -rIl $'\r' . | xargs -r sed -i 's/\r$//' \
  && for t in tests/test_*.sh; do bash \$t >/dev/null 2>&1 \
       && echo \"PASS \$t\" || echo \"FAIL \$t\"; done"
```

**On the gateway** — 50 checks, all green:

```
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith.sh"
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith-writes.sh"
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith-extension.sh"
```

Use Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`); git bash's ssh
cannot resolve the name. **Keep remote commands straight-line** — PowerShell
mangles `for`/`if` blocks passed through `ssh`.

## Next, in order

### 1. The `install.sh` body

~15 call sites still invoke the two retired binaries as libraries. Each needs a
decision, and for most of them the answer is that the calling logic goes rather
than being replaced, because the machinery it served no longer exists:

| Call | Line | Enclosing | Disposition |
| --- | --- | --- | --- |
| `--align-interception-credentials` | 3375 | `align_interception_credentials` | Delete. There is no second SOCKS hop to align credentials across. |
| `--print-mihomo-fields` | 3457 | seed rendering | Delete. It rendered the `intercept-egress` credentials into the seed. |
| `--check-enabled` | 5690 | `wait_service_ready` | Delete. It gated readiness on a conditioned second unit. |
| `--healthcheck` | 5697 | `wait_service_ready` | Replace with `GET /gpn/interception` on the controller, or drop — the unit's own readiness is now the whole answer. |
| `--check-enabled` | 5922 | `show_status` | Replace with `GET /gpn/interception` (`.snapshot.enabled`). |
| `--seed-defaults` | 3298 | seeding | Delete. The datasets are embedded in the binary now. |
| `--check-config` | 3021, 3066 | interception publication | Delete. The engine validates on load and refuses to publish an invalid document. |
| `--check-config` | 3579 | `preflight_existing_interception_state` | Delete, or re-point at the staged mihomo binary if a preflight on an untouched host is still wanted. |
| `--print-certificate-request` / `--print-certificate-hosts` | 3096, 3139 | certificate wait | Delete. Replaced by `<stateDir>/certificate-request`. |
| `--print-mihomo-secret` | 3339 | `read_mihomo_secret` | Replace. It reads `secret:` out of the operator's YAML; the acceptance scripts already do this with `grep`/`sed`. |
| `install_5gpndns`, `install_intercept` | 2971-2993 | — | Delete, with their call sites in `full_install` (6342-6343). |
| `stage_artifacts` binary halves | 2593-2622 | `stage_artifacts` | Delete. Keep `checksums.txt` — the web tarball is verified from it. |
| `SIDECAR_REPO/VERSION/SHA256` | 172-174 | — | Delete; only `stage_artifacts` uses them. |
| `binary_reports_exact_version` | 2380-2391 | — | Dead once the above go. mihomo has its own. |

Line numbers are from `009cd98` and will drift as soon as the first deletion
lands; `grep -n 'DNS_BIN\|INTERCEPT_BIN' install.sh` is the reliable index.

**Do not remove `RELEASE_TAG`.** It is the release selector, not a
binary variable: it also versions the console SPA, drives the stable/beta
channel delegation, and gates `upgrade-reset-mihomo`.

The seed template `etc/mihomo/config.yaml.tmpl` still carries the
`RUNTIME-OVERLAY` anchors, the `intercept-egress` listener, the
`MODULE-INTERCEPT` node and the `runtime-overlay:` block. It needs those
removed and a `dns:` section pointing `nameserver` at `127.0.0.1:5354` — the
deployed v5 config already has that section, which is why the origin boundary
wired up on `test-env` with the operator's file untouched.

Then the TUI. Nothing of it exists.

### 2. The nine red suites

None can simply be deleted — every one but `test_pii_policy` is entangled with
`install.sh`, so deleting it would drop real installer coverage:

| Suite | install.sh refs | Disposition |
| --- | --- | --- |
| `test_pii_policy` | 0 | Delete. Pure `cmd/5gpn-dns` subject; covered by Go tests in the fork now. |
| `test_seed_template_renderers` | 2 | Rewrite against the monolith template. |
| `test_domain_validation` | 6 | Prune the `bot.go` assertions; keep the installer ones. |
| `test_tgbot_installer_policy` | 6 | Prune; the bot's installer surface is gone until the bot is ported. |
| `test_intercept_policy` | 16 | Prune the manifest-parser assertions — that subject moved to `gpn/engine/manifest_test.go`. |
| `test_tui_policy` | 17 | Rewrite for the new TUI once it exists. |
| `test_mihomo_policy` | 50 | Two assertions reference `cmd/5gpn-dns`; the rest are seed/installer and stay. |
| `test_5gpndns_policy` | 92 | Prune heavily; most of it asserts the retired daemon. |
| `test_install_policy` | 98 | Prune the journal-exporter, polkit and `5gpn-dns` assertions. |

### 3. Marketplace and Telegram bot

Neither exists. Extensions install by manifest URL or pasted manifest without
them, which is what the acceptance suite exercises. The bot's own extension
management surface is deliberately not being ported — the decision on record is
that its UI moves into zashboard.

## Things that will bite

- **`gpn/engine` has no tests for the request path.** `manage_test.go` and
  `manifest_test.go` cover the document and the parser. The proxy, the goja
  runtime and the TLS termination are untested here and were inherited.
- **UDP/QUIC capture is not wired.** `MatchUDP` returns false; the fixed
  `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` capability is the guard.
- **The certificate oneshot runs as root with an empty capability set.** It is
  therefore subject to ordinary permission checks. That is why the state
  directory is `0711` and the certificate request is `0644`. Do not "tighten"
  either without re-running the extension acceptance suite.
- **`package-beta.sh` reports the fork budget as `unknown` under WSL**, because
  the worktree's `.git` file points at a Windows path. The real number is two
  files and eight lines against upstream `Alpha`; verify it from git bash.
- **The zashboard UI cannot be built from WSL** — its `node_modules` are
  Windows-native. Build with `npm run build` on Windows and pass
  `ZASHBOARD_DIST` to the packager.
