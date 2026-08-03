# What is not done — 5gpn monolith

Input for a design session, not a status report. Everything below is either
unbuilt or unverified; what *is* built is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Delete this file when the list empties.

Everything is pushed. `beta` is fast-forwarded to `feat/installer-tui`.

| Repository | Branch | Head | Published |
| --- | --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `112f1be3` | `v1.19.28-monolith.2` |
| `moooyo/zashboard` | `feat/5gpn-console` | `3079675` | `v3.16.0-monolith.1` |
| `moooyo/5gpn` | `feat/installer-tui` | `d245ddd` | `0.0.62-beta.9` |

Green: `go test -race ./gpn/...`, all 26 installer suites, and CI on every
branch push. See [Reproducing the checks](#reproducing-the-checks).

---

## 0. Fresh-install acceptance — done, bar one decision

**A clean host installs and comes up.** This was the gate, and it is walked.
`0.0.62-beta.9` installs onto a wiped `test-env` end to end: readiness passes,
the console verifies, exit 0. Acceptance on that host:

| Suite | Result |
| --- | --- |
| `acceptance-monolith-writes.sh` | **12 / 12** |
| `acceptance-monolith-extension.sh` | **18 / 18** |
| `acceptance-monolith.sh` | 17 / 20 |

The extension suite is the one that matters: it drives the whole lifecycle from
zero — enable, the engine writes its certificate request, the path unit fires,
the root oneshot mints a leaf covering exactly the requested host, the resolver
attributes the name, capture steers it, uninstall restores the request.

Getting there took seven fixes, every one of them the same shape: **the upgrade
path did something the fresh path never learned to do.** The deployed beta was
green on 50 checks because it upgraded a provisioned host. Pins at overlay.6; no
`external-ui` in the seed; nothing creating `/opt/5gpn/ui`; the DoT certificate
owned by the retired `gpn-dns`; the role→account mapping duplicated so changing
one made the two disagree; `dns.json` never given the certificate pair while the
installer seeded a retired `upstreams.json`; readiness and console verification
both waiting on the deleted loopback console origin; the iOS profiles published
to an unserved `WWW_DIR`; and an interception engine that refused to exist
before its first leaf, which deadlocked a fresh gateway out of ever enabling an
extension.

**The one open decision.** The three remaining failures are one cause, and the
suite says so itself: `no enabled block rule found in the migrated policy`.
`acceptance-monolith.sh` asserts *migrated* content — an operator policy that a
gateway carries through `migrate-state-to-monolith.sh`. A fresh gateway has no
policy rules and an unfetched subscription record by design. So:

- Mark those checks as requiring a configured gateway, and keep a smaller
  fresh-install acceptance? Or
- Seed a policy rule and trigger a subscription fetch as part of acceptance, so
  it covers a configured gateway and the fresh case is asserted separately?

Do not simply relax the assertions. A suite that passes by asking less is the
failure mode this whole branch has been correcting.

**Small, separate.** The seeded document emits `policy.rules: null`, because Go
marshals a nil slice that way, and consumers' `jq` iteration errors on it. `[]`
says the same thing without the foot-gun. It will not turn the three checks
green — they want an actual rule — so it is its own change.

---

## 1. The installer TUI — scope is genuinely undecided

**The branch is named `feat/installer-tui` and it is not clear what that was
meant to mean.** This needs a decision before code.

What exists today, and works:

- `configure_install_tui()` — the install-time prompt flow (certificate mode,
  domain; public/gateway/listen IPv4 are prompted only in advanced mode and
  otherwise derived from `get_public_ip`, which prefers the box's own egress
  source address).
- `manage_menu()` — the post-install menu behind bare `5gpn`: restart, configure,
  add/remove zashboard allowlist IP, reset mihomo config, uninstall.
- 32 Gum call sites, with a plain-echo fallback everywhere.
  `test_tui_policy` and `test_gum_policy` hold that shape.

**Open questions:**

- Is the intended work a *rewrite* of the existing TUI, or new surfaces inside
  it? If new: which, given zashboard now owns every runtime surface (DNS
  document, extensions, settings) and the installer owns only install-time and
  lifecycle operations?
- The menu lost two entries during the monolith work — `Reload rules` and
  `Configure Telegram Bot` — because both invoked helpers deleted in `939638c`.
  Does anything replace them, or is the smaller menu the answer?

---

## 2. Marketplace — greenfield

Does not exist. Extensions install by manifest URL or pasted manifest, and
`gpn/engine`'s review → digest-checked install → update-check → apply path is
complete and tested — and now demonstrated end to end on a real gateway by the
extension acceptance suite.

So the missing piece is *discovery*, not installation.

**Already decided:** the catalog lives in an independent repository
(`https://github.com/moooyo/5gpn-extensions`; whether that repo exists is
unverified). The core repository must not vendor extension source;
`test_intercept_policy` asserts that.

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

**Already decided:** the bot's own extension-management UI is *not* being
ported. Its management surface moves into zashboard rather than being a second
marketplace inside a chat client.

**Blocked on this item:** M7's bot configuration page.

**Two pieces of test coverage are parked on it:**

- `test_domain_validation` dropped its `bot.go` regexp comparison. It has to
  return as a Go test *beside the regexp* in the fork, not as a grep across
  repositories.
- `test_tgbot_installer_policy` keeps the `dns.env` half and asserts that the
  `setup-tgbot` command stays gone until a helper exists behind it.

Residue to clean up when this lands: `tests/test_install_policy.sh` defines
`BOT_OPS` pointing at `cmd/5gpn-dns/bot_ops.go`, a path deleted with the
three-process layout. Nothing reads the variable.

**Open questions:**

- Does the bot live in `gpn/` inside the fork (one process, consistent with
  everything else) or as a separate process again?
- What can it still do, given zashboard owns extension management? Alerts and
  status reads are the obvious residue.

---

## 4. `gpn/engine` has no tests for the request path

The largest untested surface in the tree, and inherited rather than introduced.

Covered: the document (`manage_test.go`), the manifest parser
(`manifest_test.go`), the certificate store's presence/absence contract
(`cert_test.go`), capture ownership.

**Not covered:** the proxy, the goja script runtime, TLS termination. Those are
the parts that see live traffic and run operator-supplied JavaScript.

Two facts that should shape the design:

- `gpn/dns` has real socket tests (`service_test.go` binds listeners and asks
  questions over the wire). That is the bar, and it caught things unit tests
  could not.
- A pre-existing data race in `Doc.Update` survived every existing test and was
  only caught by `-race`. Assume more of that shape is in the untested half.

---

## 5. UDP / HTTP-3 capture — deliberately deferred, still deferred

`captureUDPFor` exists in `tunnel/gpn.go` and is unused; `MatchUDP` returns
false. The UDP path builds an association, so a capture also owns
`nat.NewWriteBackProxy` and the `handleUDPToLocal` pump, which deserves its own
change with its own tests.

The guard in the meantime is the seed template's fixed
`AND,((NETWORK,UDP),(DST-PORT,443)),REJECT`, which makes a capable client fall
back to TCP, which *is* captured. `test_mihomo_policy` asserts its position, and
the CI seed gate asserts its presence.

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
  shell semantics are identical. It no longer selects an artifact — the core and
  the UI come from their own repositories under their own digest pins — but it
  still gates an unpinned source and still drives channel delegation.
- **`NOT,((IN-TYPE,INNER))` on the two panel allow rules.** The engine reaches
  every upstream by dialling back through mihomo's own rules, so engine egress
  arrives as `INNER` with no inbound name. The qualifier looks vacuous; deleting
  it lets a captured extension naming the console reach the management plane.
- **`MIHOMO_SAFE_PATHS` must equal the unit's `Environment=SAFE_PATHS`.** The
  seed names paths outside its own home — the certificates and the UI bundle at
  `external-ui` — so a bare `mihomo -t` rejects a config the running service
  accepts, and a fresh install fails its own preflight on a correct config.
  `test_mihomo_policy` asserts the two are equal and that no `-t` escapes the
  guard.
- **`cert_role_group` is the only role→account mapping.** It was two case
  statements, one in the writer and one in the validator, and moving DoT into
  the mihomo process changed one of them — which produced a directory the other
  rejected as unsafe. `dot` and `zash` resolve to `mihomo`, which serves them;
  `web` has no reader left and stays on the retired account rather than being
  widened.
- **One path to a leaf.** The engine writes `certificate-request`,
  `5gpn-intercept-cert.path` sees it change, the root oneshot signs. The
  installer establishes the CA and stops. A second entry point is what forced a
  first-install special case, because a gateway with no extensions has nothing
  to sign.
- **The CA signing key never enters the engine's address space.** It can mint a
  leaf for any name; the leaf's SAN set is the enforcement of the capture
  policy, and it only bounds anything because the process holding the leaf
  cannot sign a new one. `InaccessiblePaths=-/etc/5gpn/intercept-ca`.
- **The certificate oneshot is root with an empty capability set**, so it is
  subject to ordinary permission checks. Hence state directory `0711` and
  certificate request `0644`.
- **A red suite hides new breakage.** Keep all 26 green.

---

## Reproducing the checks

**Go** — the way CI does it, which on this box means WSL:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/mihomo-5gpn-monolith \
  && gofmt -l ./gpn/ && GOOS=linux go vet ./gpn/... \
  && GOOS=linux go build ./... \
  && CGO_ENABLED=1 go test -race ./gpn/... -count=1"
```

**Installer suites** — `scripts/run-suites.sh` makes the LF copy and runs them
under Linux:

```
wsl -e bash -lc "cd /mnt/d/Code/worktrees/5gpn-installer-tui && bash scripts/run-suites.sh"
```

Names for a subset (`run-suites.sh install_policy tui_policy`), `SUITE_TAIL=N`
for more failure context. `tests/verify-artifact-pins.sh` needs the network and
must run from a tree with `install.sh` beside it — copy both to an LF directory
preserving `tests/`, or it fails on its own path derivation.

### Cutting a release

Three repositories, and a fix only reaches a host through a published release,
because `install.sh` fetches digest-pinned artifacts and `quick-install.sh`
fetches a digest-checked bundle. There is no local-bundle install path.

- **mihomo** has no working Actions on the fork: every `v1.19.28-*` release was
  built locally and uploaded. Build with the flags `package-beta.sh` uses
  (`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -tags with_gvisor -trimpath`, ldflags
  setting `constant.Version` **and** `constant.BuildTime`), gzip to
  `mihomo-linux-amd64-compatible-<tag>.gz`, `gh release create --prerelease`.
  The version token must match `MIHOMO_VERSION` exactly —
  `mihomo_reports_exact_version` parses the `-v` first line.
- **zashboard** has `5gpn-release.yml`, triggered by a `v*-monolith.*` tag.
- **5gpn**: tag `X.Y.Z-beta.N` **reachable from `origin/beta`**, and N greater
  than every existing `X.Y.Z-beta.*`. `classify` enforces both.
- Then bump `MIHOMO_VERSION`/`MIHOMO_SHA256` in **both** `install.sh` and
  `.github/workflows/checks.yml`, and run `verify-artifact-pins.sh`.

### Driving a fresh install

The installer refuses a headless first install by design: `configure_install_tui`
requires a TTY and `attach_tty` reattaches stdin to `/dev/tty`, so answers
cannot be piped. Drive it with `expect`, and **set `stty_init`** — without a pty
size gum's textinput panics inside `placeholderView`, which presents as an
endless "Invalid domain" loop and a 45 MB log.

Run it detached (`setsid nohup … > /tmp/fi.log`) so a dropped ssh session does
not take the install with it.

### test-env

Windows OpenSSH only (`C:\Windows\System32\OpenSSH\ssh.exe`); git bash's ssh
cannot resolve the name. Keep remote commands straight-line — PowerShell mangles
`for`/`if` blocks and `$(...)` passed through `ssh`.

It currently holds a **fresh install of `0.0.62-beta.9`**, not the old
three-process deployment. Pre-wipe backup: `/root/5gpn-pre-freshinstall-20260803T011558Z`
(`etc-5gpn.tgz` plus every unit file). `get_public_ip` returns `10.0.1.20` there,
so a default install reproduces the deployment that was wiped.

To wipe it back to clean, in one straight line: disable the units, remove the
unit files, `daemon-reload`, `reset-failed`, `rm -rf /etc/5gpn /opt/5gpn
/var/lib/5gpn* /run/5gpn /usr/local/bin/5gpn`, drop the `mobileconfig` line from
`/etc/mime.types`, then `userdel`/`groupdel` `mihomo`, `gpn-dns` and
`gpn-intercept`. Scan for leftovers by pattern rather than by name — the first
attempt missed the user `gpn-intercept` and the groups `5gpn-overlay-ctl` and
`5gpn-overlay-gen`.

The acceptance suites are not in the installer bundle; `scp` them from
`tests/` and strip CRLF.
