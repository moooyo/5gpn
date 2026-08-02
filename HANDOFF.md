# What is not done — 5gpn monolith

Input for a design session, not a status report. Everything below is either
unbuilt or unverified; what *is* built is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Delete this file when the list empties.

All three branches are pushed and in sync:

| Repository | Branch | Head |
| --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `c813885a` |
| `moooyo/zashboard` | `feat/5gpn-console` | `02793c0` |
| `moooyo/5gpn` | `feat/installer-tui` | `d3a9651` |

Green: `go test -race ./gpn/...` and all 26 installer suites. See
[Reproducing the checks](#reproducing-the-checks) at the bottom.

---

## 0. Fresh-install acceptance — verification debt, no design needed

**Do this before designing anything else.** It is the only item here that can
invalidate the others.

`v0.1.0-beta.1` on `test-env` is green on 50 acceptance checks, and that number
is not evidence for the current tree. The beta *upgraded* a provisioned host,
so it preserved the operator's `config.yaml` and never rendered a seed. The
seed path was broken end to end at that point — the template still carried
`RUNTIME-OVERLAY` anchors, a rule type the monolith deleted, so `mihomo -t`
would have rejected the rendered config — and nothing caught it because no run
exercised it.

That is fixed, and it has never been run on a real host.

- Repackage from the current tree (`scripts/package-beta.sh`; build zashboard
  on Windows first and pass `ZASHBOARD_DIST`).
- Provision a **clean** host and install onto it. Not another upgrade.
- Re-run all three acceptance suites.

Until that passes, treat every claim about the installer as "the suites agree",
which is a weaker statement than it sounds: they are greps.

---

## 1. The installer TUI — scope is genuinely undecided

**The branch is named `feat/installer-tui` and it is not clear what that was
meant to mean.** This needs a decision before code.

What exists today, and works:

- `configure_install_tui()` — the install-time prompt flow (domain, gateway IP,
  resolver, certificate mode). Gum-driven, TTY-gated, falls back to `read -p`.
- `manage_menu()` — the post-install menu behind bare `5gpn`: restart, configure,
  add/remove zashboard allowlist IP, reset mihomo config, uninstall.
- 32 Gum call sites, with a plain-echo fallback everywhere.
  `test_tui_policy` and `test_gum_policy` hold that shape.

`docs/architecture.md` used to say "the TUI is not started" in the same
sentence as claims about `install.sh` that were simply stale. It sat beside
"This repository is an installer and a TUI", which describes what is there. I
removed the stale bullet rather than guess at the intent.

**Open questions:**

- Is the intended work a *rewrite* of the existing TUI, or new surfaces inside
  it? If new: which, given zashboard now owns every runtime surface (DNS
  document, extensions, settings) and the installer owns only install-time and
  lifecycle operations?
- The menu lost two entries during the monolith work — `Reload rules` and
  `Configure Telegram Bot` — because both invoked helpers deleted in `939638c`.
  Does anything replace them, or is the smaller menu the answer?
- Is there a case for the installer to reach the control API at all (it now
  does, once: `gpn_interception_snapshot` for `show_status`), or should status
  stay unit-level and let zashboard own the rest?

---

## 2. Marketplace — greenfield

Does not exist. Extensions install by manifest URL or pasted manifest, and
`gpn/engine`'s review → digest-checked install → update-check → apply path is
complete and tested (`manage_test.go`, `manifest_test.go`, and the 18-check
extension acceptance suite).

So the missing piece is *discovery*, not installation.

**Already decided:** the catalog lives in an independent repository
(`https://github.com/moooyo/5gpn-extensions` — the string is already in the
retired parser's history; whether that repo exists is unverified). The core
repository must not vendor extension source; `test_intercept_policy` asserts
that.

**Open questions:**

- What is a marketplace here — a static index the gateway fetches, or a service?
  A static index keeps the gateway's trust surface as it is now (fetch guarded
  by `publicUnicast`, digest checked before install).
- Who signs? Today the digest is quoted by the operator from a review response.
  A catalog implies something signs the catalog itself.
- Where does it render — a zashboard page, or inside the existing Extensions
  page as a second install source?

---

## 3. Telegram bot — greenfield, and its zashboard page is blocked on it

Not ported. `dns.env` still carries `DNS_TGBOT_FILE`, `TGBOT_PROXY_URL`,
`TGBOT_ALERTS` and the installer still writes them, so the configuration
surface is reserved; nothing reads it.

The `setup-tgbot` command was removed from `install.sh` because it sourced
`scripts/setup-tgbot.sh`, deleted in `939638c` — it could only ever fail.

**Already decided:** the bot's own extension-management UI is *not* being
ported. Its management surface moves into zashboard rather than being a second
marketplace inside a chat client.

**Blocked on this item:** M7's bot configuration page. There is nothing to
configure until the bot exists.

**Two pieces of test coverage are parked on it**, recorded in the test files
themselves so they are not silently lost:

- `test_domain_validation` dropped its `bot.go` regexp comparison. It existed
  because two implementations of one FQDN rule drift silently. It has to return
  as a Go test *beside the regexp* in the fork, not as a grep across
  repositories.
- `test_tgbot_installer_policy` keeps the `dns.env` half and asserts that the
  `setup-tgbot` command stays gone until a helper exists behind it. The live
  apply path needs its own coverage where the bot lands.

**Open questions:**

- Does the bot live in `gpn/` inside the fork (one process, consistent with
  everything else) or as a separate process again? The monolith argument says
  in-process; a chat client that blocks on network is a different failure shape
  from a resolver.
- What can it still do, given zashboard owns extension management? Alerts and
  status reads are the obvious residue.

---

## 4. `gpn/engine` has no tests for the request path

The largest untested surface in the tree, and inherited rather than introduced.

Covered: the document (`manage_test.go`), the manifest parser
(`manifest_test.go`), capture ownership.

**Not covered:** the proxy, the goja script runtime, TLS termination. Those are
the parts that see live traffic and run operator-supplied JavaScript.

Two facts that should shape the design:

- `gpn/dns` has real socket tests (`service_test.go` binds listeners and asks
  questions over the wire). That is the bar, and it caught things unit tests
  could not.
- A pre-existing data race in `Doc.Update` — mutators were handed the published
  document's backing arrays — survived every existing test and was only caught
  by `-race` on a test that happened to run the subscription goroutine
  concurrently. Fixed in `c813885a`. Assume more of that shape is in the
  untested half.

---

## 5. UDP / HTTP-3 capture — deliberately deferred, still deferred

`captureUDPFor` exists in `tunnel/gpn.go` and is unused; `MatchUDP` returns
false. The comment there states the reason: the UDP path builds an association,
so a capture also owns `nat.NewWriteBackProxy` and the `handleUDPToLocal` pump,
which deserves its own change with its own tests.

The guard in the meantime is the seed template's fixed
`AND,((NETWORK,UDP),(DST-PORT,443)),REJECT`, which makes a capable client fall
back to TCP, which *is* captured. `test_mihomo_policy` asserts its position
relative to the private-range denies and the terminal `MATCH`.

**This rule must not be removed before the capture path works.** Removing it
first does not enable QUIC capture; it makes gateway QUIC bypass interception
silently.

---

## Constraints any design has to respect

These are load-bearing and each one looks removable.

- **`RELEASE_TAG` is a textual contract.** `release.yml` stamps the line with an
  anchored `sed`; `quick-install.sh` reads it back with `awk` and `sed` without
  ever sourcing the downloaded bundle. One column-zero, double-quoted,
  uninterpolated assignment. Reformatting breaks bundle validation even when the
  shell semantics are identical.
- **`NOT,((IN-TYPE,INNER))` on the two panel allow rules.** The engine reaches
  every upstream by dialling back through mihomo's own rules — that is what
  keeps intercepted traffic inside the operator's routing — so engine egress is
  what those rules must be told apart from. It arrives as `INNER` with no
  inbound name. The qualifier looks vacuous; deleting it lets a captured
  extension naming the console reach the management plane.
  `migrate-to-monolith.sh` rewrites rather than strips it for the same reason.
- **The certificate oneshot is root with an empty capability set**, so it is
  subject to ordinary permission checks. Hence state directory `0711` and
  certificate request `0644`. Do not tighten either without re-running the
  extension acceptance suite.
- **A red suite hides new breakage.** Three `install.sh` paths that could only
  ever fail — `reload_rules`, `setup_tgbot`, and a `china_ip_list` seed
  reference — were each invisible inside a suite that had been failing for
  unrelated reasons. Keep them green.

---

## Reproducing the checks

**Go** — the way CI does it, which on this box means WSL:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/mihomo-5gpn-monolith \
  && gofmt -l ./gpn/ && GOOS=linux go vet ./gpn/... \
  && GOOS=linux go build ./... \
  && CGO_ENABLED=1 go test -race ./gpn/... -count=1"
```

`gofmt -l` on the *working tree* reports false positives: the tree is CRLF and
the index is LF. Check the committed content if it disagrees.

**Installer suites** — `scripts/run-suites.sh` makes the LF copy and runs them
under Linux:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/5gpn-installer-tui && bash scripts/run-suites.sh"
```

Names for a subset (`run-suites.sh install_policy tui_policy`), `SUITE_TAIL=N`
for more failure context.

**The gateway** — use Windows OpenSSH
(`C:\Windows\System32\OpenSSH\ssh.exe`); git bash's ssh cannot resolve the
name. Keep remote commands straight-line — PowerShell mangles `for`/`if` blocks
passed through `ssh`.

```
ssh test-env "bash /tmp/beta/<bundle>/scripts/acceptance-monolith.sh"
ssh test-env "bash /tmp/beta/<bundle>/scripts/acceptance-monolith-writes.sh"
ssh test-env "bash /tmp/beta/<bundle>/scripts/acceptance-monolith-extension.sh"
```

Rollback material from the beta is under `/root/5gpn-pre-monolith-*/`.

**Two environment traps:** `package-beta.sh` reports the fork budget as
`unknown` under WSL because the worktree's `.git` file points at a Windows path
— the real number is 8 files, +106/−14 against upstream `Alpha` (6 files,
+60/−4 excluding `go.mod`/`go.sum`), verifiable from git bash. And zashboard
cannot be built from WSL at all; its `node_modules` are Windows-native.
