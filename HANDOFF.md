# Handoff — 5gpn monolith, 2026-08-03

Working state, not documentation. `docs/architecture.md` is the normative
description of the system; this file is what a next session needs in order to
pick the work up, and it should be deleted when the milestones it tracks are
done.

## Where things are

Three worktrees, all clean, all committed, nothing pushed.

| Worktree | Branch | Head |
| --- | --- | --- |
| `D:/Code/worktrees/mihomo-5gpn-monolith` | `feat/5gpn-monolith` | `c813885a` (27 commits) |
| `D:/Code/worktrees/zashboard-5gpn-console` | `feat/5gpn-console` | `02793c0` (4 commits) |
| `D:/Code/worktrees/5gpn-installer-tui` | `feat/installer-tui` | `c6e1a60` (13 commits) |

**`v0.1.0-beta.1` is packaged and running on `test-env`** as a single
`mihomo.service`. The three retired units are stopped and disabled. Rollback
material is under `/root/5gpn-pre-monolith-*/`.

**That beta predates everything below.** It was an upgrade of a provisioned
host, so it preserved the operator's `config.yaml` and never rendered a seed —
which is why a fresh install being broken did not show up in its 50 green
acceptance checks. Repackage before trusting `test-env` to represent the tree.

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
- **M8** — the unit set is collapsed, the migration scripts are verified on a
  live host, and **the `install.sh` body is done**: both retired binaries are
  gone from it and the seed template renders against the monolith core. **No
  TUI.**
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

Green. It was not green at `215a9697`: `Doc.Update` handed mutators memory that
live readers held, and the resolver's subscription goroutine raced it.
`gofmt -l` on the *working tree* reports false positives — the tree is CRLF and
the index is LF. Check the committed content if it disagrees.

**Installer suites** — 26 of 26. `scripts/run-suites.sh` makes the LF copy and
runs them under Linux:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/5gpn-installer-tui && bash scripts/run-suites.sh"
```

Pass suite names for a subset (`run-suites.sh install_policy tui_policy`), and
`SUITE_TAIL=N` for more failure context.

**On the gateway** — 50 checks, green as of the beta, *not* re-run against the
current tree:

```
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith.sh"
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith-writes.sh"
ssh test-env "bash /tmp/beta/5gpn-v0.1.0-beta.1/scripts/acceptance-monolith-extension.sh"
```

Use Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`); git bash's ssh
cannot resolve the name. **Keep remote commands straight-line** — PowerShell
mangles `for`/`if` blocks passed through `ssh`.

## Next, in order

### 1. Repackage and re-run acceptance

Nothing below should start before the current tree is on a host. The install
path changed substantially and the last acceptance run does not cover it. A
**fresh** install is the case to exercise, not another upgrade — that is the
path that was broken, and it is now the one with no live evidence behind it.

### 2. The TUI

Nothing of it exists. `test_tui_policy` passes because it asserts the
installer's own Gum usage, which is real; it says nothing about a TUI.

### 3. Marketplace and Telegram bot

Neither exists. Extensions install by manifest URL or pasted manifest without
them, which is what the acceptance suite exercises. The bot's own extension
management surface is deliberately not being ported — the decision on record is
that its UI moves into zashboard.

Two pieces of coverage are parked on the bot landing, both recorded in the
files themselves so they are not lost:

- `test_domain_validation` dropped its `bot.go` regexp comparison. It existed
  because two implementations of one FQDN rule drift silently, so it has to
  return as a Go test beside the regexp — not as a grep across repositories.
- `test_tgbot_installer_policy` keeps the `dns.env` half and asserts that the
  `setup-tgbot` command stays gone until there is a helper behind it. The live
  apply path needs its own coverage in the fork.

### 4. `gpn/engine` has no tests for the request path

`manage_test.go` and `manifest_test.go` cover the document and the parser. The
proxy, the goja runtime and the TLS termination are untested and were
inherited. This is the largest untested surface in the tree.

### 5. UDP/QUIC capture is not wired

`MatchUDP` returns false. The seed template's fixed
`AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` is the guard that makes a capable
client fall back to TCP, which is captured. Do not remove it ahead of the
capture path; `test_mihomo_policy` asserts its position for that reason.

## Things that will bite

- **The certificate oneshot runs as root with an empty capability set.** It is
  therefore subject to ordinary permission checks. That is why the state
  directory is `0711` and the certificate request is `0644`. Do not "tighten"
  either without re-running the extension acceptance suite.
- **`RELEASE_TAG` is a textual contract, not just a variable.** `release.yml`
  rewrites the line with an anchored `sed`, and `quick-install.sh` reads it back
  with `awk` and `sed` without ever sourcing the downloaded bundle: one
  column-zero, double-quoted, uninterpolated assignment. Reformatting it breaks
  bundle validation even when the shell semantics are identical.
- **The panel allow rules exclude `IN-TYPE,INNER`, and that is load-bearing.**
  The engine reaches every upstream by dialling back through mihomo's own
  rules, which is what keeps intercepted traffic inside the operator's routing
  — but it also means engine egress is what those two rules have to be told
  apart from. It used to arrive on a named SOCKS listener. Deleting the
  qualifier as vacuous lets a captured extension naming the console reach the
  management plane; `migrate-to-monolith.sh` rewrites rather than strips it for
  the same reason.
- **`package-beta.sh` reports the fork budget as `unknown` under WSL**, because
  the worktree's `.git` file points at a Windows path. The real number is 8
  files, +106/-14 against upstream `Alpha`, or 6 files +60/-4 excluding
  `go.mod`/`go.sum`. The previous handoff said "two files and eight lines";
  that was wrong. Verify from git bash.
- **The zashboard UI cannot be built from WSL** — its `node_modules` are
  Windows-native. Build with `npm run build` on Windows and pass
  `ZASHBOARD_DIST` to the packager.
- **A red suite hides new breakage.** Three separate paths in `install.sh`
  could only ever fail — `reload_rules`, `setup_tgbot`, and a `china_ip_list`
  seed reference — and every one was invisible inside a suite that had been
  failing for unrelated reasons. Keep them green.
