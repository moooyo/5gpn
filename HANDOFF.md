# What is not done — 5gpn monolith

Input for a design session, not a status report. Everything below is either
unbuilt or unverified; what *is* built is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Delete this file when the list empties.

Everything is pushed. `beta` is fast-forwarded to `feat/installer-tui`.

| Repository | Branch | Published |
| --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `v1.19.28-monolith.6` |
| `moooyo/zashboard` | `feat/5gpn-console` | `v3.16.0-monolith.2` |
| `moooyo/5gpn` | `feat/installer-tui` | `0.0.62-beta.15` |

Green: `go test -race ./gpn/...`, all 26 installer suites, and CI on every
branch push. See [Reproducing the checks](#reproducing-the-checks).

---

## 0. Acceptance — one decision, unchanged

`0.0.62-beta.15` is deployed on `test-env`. Acceptance there:

| Suite | Result |
| --- | --- |
| `acceptance-monolith-writes.sh` | **12 / 12** |
| `acceptance-monolith-extension.sh` | **18 / 18** |
| `acceptance-monolith-surfaces.sh` | **31 / 31** |
| `acceptance-monolith.sh` | 17 / 20 |

`acceptance-monolith-surfaces.sh` is new and covers the three subsystems that
landed together — datagram capture, the catalog, the bot. It fetches the real
first-party index and reviews a real entry against its published digest and
advertised capabilities, so the network path is exercised rather than mocked.

**The one open decision is the same one.** The three remaining failures are one
cause, and the suite says so itself: `no enabled block rule found in the
migrated policy`. `acceptance-monolith.sh` asserts *migrated* content — an
operator policy that a gateway carries through `migrate-state-to-monolith.sh`.
A fresh gateway has no policy rules and an unfetched subscription record by
design. So:

- Mark those checks as requiring a configured gateway, and keep a smaller
  fresh-install acceptance? Or
- Seed a policy rule and trigger a subscription fetch as part of acceptance, so
  it covers a configured gateway and the fresh case is asserted separately?

Do not simply relax the assertions. A suite that passes by asking less is the
failure mode this whole branch has been correcting.

---

## What shipped on 2026-08-03, and what it cost

The three items this file used to list as unbuilt are built. They are described
by `docs/architecture.md`; what belongs here is the shape of what went wrong,
because it repeated.

**Every bug found in this round was on the second install, not the first.**
The previous round's lesson was "the upgrade path did something the fresh path
never learned to do". This round was the mirror: fresh installs were green
throughout, and five separate faults were only reachable by upgrading a host
that already had state.

- `mihomo_config_matches_install_config` accepted only the *retired*
  `NOT,((IN-NAME,intercept-egress))` qualifier, so **every monolith-installed
  host failed its own drift check** and was told to run `upgrade-reset-mihomo`,
  which replaces the operator's entire config. The check reads a config that
  must already exist, so the first install never runs it.
- **A comment ran as a command.** The dns.env heredoc is unquoted by design, so
  a comment containing `` `catalogs` `` executed `catalogs` and failed the
  publication phase with exit 127.
- The installer's mode sweep hardened everything under the mihomo home to
  0660, **including the core's own `gpn/` state directory**, leaving the
  certificate request unreadable by the root-with-no-capabilities oneshot that
  is the only thing that mints leaves.
- Renaming `mitm.quic_fallback_protection` to `mitm.http3` made
  `DisallowUnknownFields` **refuse the intercept.json on every deployed
  gateway**. Worse than refusing: `StartInterception`'s failure is a warning, so
  the core came up resolving and forwarding with interception silently absent.
- `DefaultDocument` seeds the catalog, and `DefaultDocument` applies only to an
  absent document — so extension discovery **shipped dark on every host that
  already existed**.

And one that was not about state at all: `quick-install.sh --beta` took the
first tag GitHub listed, but `/releases` is ordered **lexicographically**, so
`beta.9` outranks `beta.11`. It worked for nine betas and then pinned every
`--beta` install to beta.9, silently, because downloading an older bundle than
the operator asked for is a successful install of the wrong thing.

Each now has a test that fails without its fix. Two are worth naming because
they are couplings nothing was watching: `test_seed_template_renderers` renders
the seed and runs the drift check against it, and `test_dns_env_writes` extracts
the heredoc body and refuses backticks and `$( )` outright.

**What this suggests for the next round.** There is no second-install
acceptance. Every suite here runs against a gateway in one state, and five
faults lived in the transition between two. A suite that installs, upgrades, and
then asserts would have caught all five.

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
  document, extensions, catalogs, bot, settings) and the installer owns only
  install-time and lifecycle operations?
- The menu lost two entries during the monolith work — `Reload rules` and
  `Configure Telegram Bot` — because both invoked helpers deleted in `939638c`.
  The bot is now configured in zashboard, so that entry is answered. Does
  anything replace `Reload rules`, or is the smaller menu the answer?

---

## 2. `gpn/engine` has no tests for the request path

The largest untested surface in the tree, and inherited rather than introduced.

Covered: the document (`manage_test.go`), the manifest parser
(`manifest_test.go`), the certificate store's presence/absence contract
(`cert_test.go`), the catalog (`catalog_test.go`), the datagram capture bridge
and a live QUIC/H3 round trip through it (`quiccapture_test.go`), capture
ownership.

**Not covered:** the proxy's request path, the goja script runtime, TLS
termination. Those are the parts that see live traffic and run
operator-supplied JavaScript.

Two facts that should shape the design:

- `gpn/dns` has real socket tests (`service_test.go` binds listeners and asks
  questions over the wire). That is the bar, and it caught things unit tests
  could not. `quiccapture_test.go` follows it: a real quic-go client handshakes
  against the engine's own leaf and gets an HTTP/3 response back.
- A pre-existing data race in `Doc.Update` survived every existing test and was
  only caught by `-race`. Assume more of that shape is in the untested half.

---

## 3. Datagram capture is unproven against a real client

`MatchUDP`/`HandleUDP` are wired and `quiccapture_test.go` drives a genuine QUIC
handshake and HTTP/3 request through the same bridge the core uses. What has
**not** happened is a browser on a real network reaching a captured host over
H3 through `test-env`.

The parts most likely to be wrong there and invisible in a test:

- **Connection migration.** One listener per process exists precisely so a
  rebinding client keeps its connection IDs. Nothing has rebound yet.
- **MTU and datagram truncation.** The bridge copies into whatever buffer
  quic-go offers; a path with a smaller MTU than the test's has not been seen.
- **Alt-Svc.** A client only tries H3 if the origin advertised it, and responses
  pass through the engine's rewrite path. Whether the advertisement survives is
  untested.

---

## 4. Marketplace — the catalog exists, the rest is open

Discovery works: `GET /gpn/interception/catalog`, a reviewed and digest-checked
install from an entry, and the zashboard listing. `test-env` fetches the
first-party index and reviews an entry from it.

**Open questions the implementation deliberately did not answer:**

- **Who signs?** Today the entry's SHA-256 is checked against the fetched
  manifest, and the entry's advertised capabilities against what was parsed —
  but the catalog itself is trusted because it was fetched over TLS from a host
  the operator configured. A signature over the index would move that trust to a
  key. Nothing currently pins one.
- **Is a second source ever added?** The document supports up to 16 and
  zashboard renders them, but there is no UI for adding one — the only way is a
  `PUT /gpn/interception/catalog/sources`.
- **Update flow from a catalog.** `CheckUpdate` re-reads the URL an extension
  was installed from, never the catalog. That is deliberate, and it means a
  catalog that publishes a new version does not surface as an update unless the
  entry's manifest URL is the same one the operator installed from.

---

## 5. Telegram bot — reads and alerts; the rest was deleted on purpose

Ported into `gpn/bot`. `/status`, `/resolve`, `/id`, transition alerts, and
nothing that mutates. Configured in zashboard, its own `bot.json`.

**Unverified:** no real Telegram token has ever been configured on `test-env`.
The poll loop, the admin gate and the alert transitions have Go tests against a
stand-in Telegram; the live path — `getMe` against the real API through the
core's inner dialer, on a network that blocks it — has not run.

**Open questions:**

- Alerts are transition-only and cannot report the gateway's own death.
  `DNS_HEARTBEAT_URL` remains the external dead-man's switch. Is anything
  actually consuming it?
- `/resolve` is the only command taking an argument, and it is bounded by the
  FQDN rule. If more read commands arrive, the `Facts` struct is where the
  boundary is enforced — widen it deliberately, not incidentally.

---

## 6. UDP / HTTP-3 — the reject rule stays

`captureUDPFor` is wired and `MatchUDP` answers for captured hosts on :443 with
`mitm.http3` on. The seed's fixed `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT`
**stays in place either way**: capture is consulted before rule resolution, so
with HTTP/3 on the reject only ever sees datagrams capture did not want, and
with it off it is the whole mechanism.

**This rule must not be removed.** Removing it does not enable QUIC capture; it
makes gateway QUIC bypass interception whenever `http3` is off or the master
switch is. `test_mihomo_policy` asserts its position and the CI seed gate
asserts its presence.

---

## Constraints any design has to respect

These are load-bearing and each one looks removable.

- **`RELEASE_TAG` is a textual contract.** `release.yml` stamps the line with an
  anchored `sed`; `quick-install.sh` reads it back with `awk` and `sed` without
  ever sourcing the downloaded bundle. One column-zero, double-quoted,
  uninterpolated assignment. Reformatting breaks bundle validation even when the
  shell semantics are identical.
- **`NOT,((IN-TYPE,INNER))` on the two panel allow rules.** The engine reaches
  every upstream by dialling back through mihomo's own rules, so engine egress
  arrives as `INNER` with no inbound name. The qualifier looks vacuous; deleting
  it lets a captured extension naming the console reach the management plane.
  The installer's drift check must accept **this** spelling and not the retired
  `IN-NAME,intercept-egress` one — `test_seed_template_renderers` now renders the
  seed and runs the check against it.
- **`MIHOMO_SAFE_PATHS` must equal the unit's `Environment=SAFE_PATHS`.** A bare
  `mihomo -t` otherwise rejects a config the running service accepts.
- **`cert_role_group` is the only role→account mapping.**
- **One path to a leaf.** The engine writes `certificate-request`,
  `5gpn-intercept-cert.path` sees it change, the root oneshot signs.
- **The CA signing key never enters the engine's address space.**
- **The certificate oneshot is root with an empty capability set**, so it is
  subject to ordinary permission checks. Hence state directory `0711` and
  certificate request `0644` — and hence the installer's mode sweep must prune
  `$MIHOMO_DIR/gpn`, which is the core's own state and not the installer's to
  re-mode.
- **The dns.env heredoc is unquoted.** Backticks and `$( )` in it, *including in
  comments*, are live command substitution. `test_dns_env_writes` refuses both.
- **Retired document fields are dropped, not preserved.** `DisallowUnknownFields`
  stays — it is what catches a typo in a hand-edited document — but a key this
  program itself retired is not a typo, and refusing it disables interception on
  every deployed gateway at once. See `retiredDocumentFields`.
- **`Config.Catalogs` is not `omitempty`.** An absent key seeds the default; an
  explicitly empty list is an operator decision that must survive a restart.
  With `omitempty` those are the same bytes.
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
must run from a tree with `install.sh` beside it — run it from `/tmp/5gpn-lf`
after `run-suites.sh` has built that copy.

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
  `mihomo_reports_exact_version` parses the `-v` first line, and its regex
  requires a non-empty build time after the Go version.
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
endless "Invalid domain" loop and a 45 MB log. A working driver is on the host
at `/tmp/fresh-install.exp`.

Run it detached (`setsid nohup … > /tmp/fi.log`) so a dropped ssh session does
not take the install with it.

### Upgrading in place

An upgrade **is** headless: `bash quick-install.sh --beta` on a provisioned host
needs no TTY.

**Fetch `quick-install.sh` by commit SHA, not by branch.**
`raw.githubusercontent.com` serves a cached copy of a branch for minutes, so a
fetch of `.../beta/quick-install.sh` right after a push silently runs the
previous revision — which is exactly how an afternoon went before this was
understood.

### test-env

Windows OpenSSH only (`C:\Windows\System32\OpenSSH\ssh.exe`); git bash's ssh
cannot resolve the name. Keep remote commands straight-line — PowerShell mangles
`for`/`if` blocks and `$(...)` passed through `ssh`.

It currently holds `0.0.62-beta.15`, upgraded in place from the beta.9 fresh
install. Backups: `/root/5gpn-pre-freshinstall-20260803T011558Z` and
`/root/5gpn-pre-beta10-*`. `get_public_ip` returns `10.0.1.20` there.

**Read the journal, not just the installer's exit code.** The interception
engine failing to load is a `[GPN]`-tagged warning in `journalctl -u mihomo`,
and the install reports success regardless — that is how a build that refused
every deployed intercept.json looked like a clean upgrade.

To wipe it back to clean, in one straight line: disable the units, remove the
unit files, `daemon-reload`, `reset-failed`, `rm -rf /etc/5gpn /opt/5gpn
/var/lib/5gpn* /run/5gpn /usr/local/bin/5gpn`, drop the `mobileconfig` line from
`/etc/mime.types`, then `userdel`/`groupdel` `mihomo`, `gpn-dns` and
`gpn-intercept`. Scan for leftovers by pattern rather than by name — the first
attempt missed the user `gpn-intercept` and the groups `5gpn-overlay-ctl` and
`5gpn-overlay-gen`.

The acceptance suites are not in the installer bundle; `scp` them from `tests/`
and strip CRLF. All four are on the host at `/root/acceptance-monolith*.sh`.
