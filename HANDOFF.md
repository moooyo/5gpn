# What is not done — 5gpn monolith

Input for a design session, not a status report. Everything below is either
unbuilt or unverified; what *is* built is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Delete this file when the list empties.

Everything is pushed. `beta` is fast-forwarded to `feat/installer-tui`.

| Repository | Branch | Published |
| --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `v1.19.28-monolith.7` |
| `moooyo/zashboard` | `feat/5gpn-console` | `v3.16.0-monolith.5` |
| `moooyo/5gpn` | `feat/installer-tui` | `0.0.62-beta.28` |

Green: `go test -race ./gpn/...`, all 26 installer suites, and CI on every
branch push. See [Reproducing the checks](#reproducing-the-checks).

---

## 0. Acceptance — green

`0.0.62-beta.28` is deployed on `test-env`. Acceptance there:

| Suite | Result |
| --- | --- |
| `acceptance-monolith.sh` | **18 / 18** |
| `acceptance-monolith-writes.sh` | **12 / 12** |
| `acceptance-monolith-extension.sh` | **18 / 18** |
| `acceptance-monolith-surfaces.sh` | **31 / 31** |

`acceptance-monolith-surfaces.sh` is new and covers the three subsystems that
landed together — datagram capture, the catalog, the bot. It fetches the real
first-party index and reviews a real entry against its published digest and
advertised capabilities, so the network path is exercised rather than mocked.

The three migrated-content checks are gone by owner decision. They asserted an
enabled block rule, a non-empty policy and a subscription with fetched entries —
none of which an *installed* gateway has by design, so they failed forever and
17/20 was a number nobody could read a regression out of. They are conditional
now and report `--`.

**What that costs, stated so it is not rediscovered as a surprise:** on a
gateway with no policy and no subscriptions, nothing proves that a block rule
produces NXDOMAIN or that a subscription fetch completes. Asserting either needs
a configured gateway, and no suite requires one. The suite header says this too.

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

**What this suggests for the next round, and it is the top item.** There is
still no second-install acceptance. Every suite runs against a gateway in one
state, and five of six faults lived in the transition between two — nine of ten
once the panel move below is counted, with one of them a repeat of the fault
directly above it. A suite that installs, upgrades, then asserts would have
caught all nine, and it is the only thing on this list that would have caught
them *before* a human noticed. Nothing else on this page has that record.

---

## The panel got a domain, and the rule held four more times

The panel had no reachable address at all. The controller sat on loopback
`:9090` behind an SSH tunnel; `zash.<base>` was in the hosts block, in five
reject rules, in the one allow rule carrying the source allowlist, and in the
controller's certificate path — and nothing ever listened for it. The panel is
`https://console.<base>/ui/` now, on the one controller. `zash.<base>` is
deleted rather than aliased: an alias would be a second way into the management
plane with no second purpose.

The source allowlist moved onto the console name with the panel, and was then
**removed entirely by owner decision** — see the section below.
`scripts/migrate-panel-to-console.sh` performs both transitions on an
operator-owned config and nothing else.

**Four more second-install faults, in a single feature.** The rule from the
round above held again, unbroken, and each of these reached a real upgrade:

- `cert_root_contents_are_safe` still allowed `dot|web|zash`, so the migrated
  host passed the role rename and then failed the certificate root's own
  structural validation.
- `deploy_cert_roles` still *wrote* `roles=(dot web zash)`, so the next upgrade
  died with `Unknown certificate role: zash` — same fault, second list, one
  release later, because the fix had enumerated the sites it knew about.
- `write_dns_env` **preserved** `DNS_MIHOMO_CONTROLLER`, so an upgraded host
  kept `:9090` while the controller moved to `:443`. Fresh installs had nothing
  to preserve and took the correct default, which is exactly why it was
  invisible. Every caller reads dns.env, so the readiness probe and the daemon
  dialled a dead port and the install failed at "mihomo did not become ready"
  with mihomo running fine.
- The success banner, the regenerate message and **the QR code** all printed
  `/ios/ios-dot.mobileconfig`, a 404. `verify_console_endpoint` probed `/ui/`
  and passed, so the install reported success while the URL a phone would scan
  pointed at nothing.

The last two are a category the earlier list does not name: **a value copied out
of its source can go stale, and a path is only verified for the reader that is a
machine.** `DNS_MIHOMO_CONTROLLER` now reads back from the operator's
config.yaml, and `ios_profile_url` is the single derivation the three printers
call, tied by test to the path `verify_console_endpoint` actually probes.

`test_cert_role_tree` grew the check that matters after two role-list misses:
naming the enumerating sites did not work twice, so it now **sweeps** for the
shapes a role name takes on its way to the filesystem — a cert path or a
`roles=()` member — across `install.sh`, `scripts/` and `etc/`, with the
migration cut out by range rather than matched by name.

Verified on `test-env` end to end: `/ui/` 200 and both profiles 200 from an
allowlisted source, `/configs` 401, and the connection refused outright once the
source is removed from the allowlist. Two consecutive installs are idempotent.

---

## The allowlist is gone, and the trade was stated first

The panel is not source-restricted. Any client that can reach this gateway on
`:443` and resolves the console name gets `/ui/` and both iOS profiles
unauthenticated, and the control API behind one bearer secret. On a VPS whose
interface holds the public address, that means the internet.

This was the owner's call, made against a stated alternative. The facts it was
made on, so it is not relitigated from memory:

- mihomo's controller has **no source-IP facility at all**. `config.go` offers
  the secret and CORS; the auth middleware never reads `RemoteAddr`. The rule
  engine was the only place such a restriction could live.
- `/ui/*` is mounted **outside** the authenticated group in
  `hub/route/server.go`, deliberately — an unenrolled phone fetching its profile
  holds no token.
- `dns.env.example` used to say access control lived in whitelist.txt "**not in
  an in-process login-failure lockout**". Removing it leaves neither: no
  allowlist, no rate limit, no lockout. The secret is 192 bits, so brute force is
  not the worry; secret *leakage* now has no second factor behind it.

The counter-proposal, recorded because it remains available: seed the allowlist
with the installing operator's `SSH_CLIENT` address (~3 lines), which removes the
"locked out immediately after install" friction without giving up the layer.

**What deliberately stayed.** The `IN-TYPE,INNER` exclusion on the console allow
rule. It is load-bearing for a different reason than the allowlist was: the
engine dials every captured upstream back through these same rules, so without
it an extension running operator-supplied JavaScript could name the console and
reach the management plane. With the allowlist gone it is the *only* qualifier
left, so the drift check now requires it rather than merely writing it.

**Cost:** 365 deletions against 230 insertions; 220 lines out of install.sh.

**Four more faults, and the pattern shifted.** These were not second-install
faults — they were *removal* faults, which is a category this page had not seen:

- The removal swept install.sh, the template, six test files and the docs, and
  missed `.github/workflows/checks.yml`, which both seeded a `whitelist.txt` and
  asserted the retired rule shape. CI caught it. Same shape as the two zash role
  lists: enumerate what you remember, and the one you forget is the one that
  breaks.
- `mihomo-sniff-cache-regression.sh` injected a hosts mapping by anchoring on
  `rule-providers:` — the line after `hosts:` only because the allowlist provider
  lived there. Deleting the allowlist deleted the anchor, and the failure
  surfaced two assertions later as a curl timeout that named nothing.
- The drift check learned to reject a surviving `RULE-SET,whitelist`; the message
  that follows it did not, so a host failing for exactly the reason the migration
  exists to fix was told to "edit and validate the operator-owned file
  explicitly". Both read one predicate now.
- The hint then printed a bare script path. **Nothing in `scripts/` carries the
  executable bit** — all ten are 100644 in git, because the repo is developed on
  Windows, and the release tarball is a plain `cp -r scripts`. The installer
  stopped an upgrade, named the fix, and the fix answered `command not found`.

The last one is the `/ios/` URL again: *a string printed for a human to act on,
which no machine on the path ever tried.* That is now two instances, and the
generalisable check is cheap — assert the printed command is runnable, not that
it says a particular word.

Writing the round-trip test for the third fault immediately found two more: the
predicate was wrong under `set -e` (`grep ... && return 0` per shape aborts the
list at the first non-match), and the drift check accepted a `:9090` config
outright — which is not benign now that dns.env follows the config, because such
a host is internally consistent and the only thing that breaks is the console
DIRECT dial landing on `127.0.0.1:443`. That is how beta.19 failed.

**Verified on `test-env`:** migrated, upgraded, `whitelist.txt` removed by
`retire_mihomo_whitelist`, `/ui/` 200 from an off-box client with no allowlist
anywhere, `/configs` 401, and all four acceptance suites at 18 / 12 / 18 / 31.

---

## The panel looked like upstream, and the credential it asked for was wrong

Opening `https://console.<base>/ui/` on a fresh browser produced a stock
zashboard: no DNS page, no extensions page, nothing 5gpn. Everything behind it
was correct — the fork was deployed, the core advertised `gpn-dns`,
`gpn-interception` and `gpn-bot` at version 1, and `UNDERSTOOD_SCHEMA_VERSIONS`
listed all three.

**The panel never had a backend to ask.** SetupPage's empty-list bootstrap
submits its default form, and that default is `http` / `127.0.0.1` / `9090` —
the shape for "dashboard hosted elsewhere, backend on this machine". 5gpn is the
inverse: the bundle is served by the controller itself through `external-ui`, so
panel and API are always same-origin, and all three fields are wrong here. The
protocol (TLS-only, `external-controller` is `""`), the host (from the browser,
`127.0.0.1` is the operator's own machine) and the port (443).

So the quiet auto-submit could only fail, and quietly: the list stayed empty, the
capability probe never started, `featureSupported` stayed false for everything,
and `renderRoutes` filtered out every gpn page. **A panel whose 5gpn half is
gated on a probe that never runs is indistinguishable from upstream.** It adopts
the serving origin now, which is the one answer that does not have to be guessed.

Then the credential the operator would paste was the wrong one. The banner
printed `DNS_API_TOKEN`; the panel takes `DNS_MIHOMO_SECRET`; they are different
values, so following the installer's own output produced a 401 from a panel that
was working. **That is the third instance of the same class** — after the
`/ios/` profile URL and the bare migration path — and this one had a *test
asserting the wrong credential was shown*.

`DNS_API_TOKEN` belonged to the control server the monolith deleted, and nothing
had read it since: not the core, not zashboard, not a script. It is retired
rather than corrected. Two live surfaces went with it: `tgbot_api_call`, which
had zero callers and POSTed to a `/api/tgbot` the core does not serve; and
`rotate_token`, reachable from the menu, which reported *"old token invalid
immediately, log in with the new one"* while rotating that dead key and
restarting `5gpn-dns` — a unit deleted with the same process, its failure
swallowed by `2>/dev/null`. It rotates the controller secret now, through a
staged same-directory rename of the operator's config.yaml, and restarts mihomo,
which drops client traffic and says so.

`quick-install.sh` also never removed its private `/tmp` directory — it cannot,
because it `exec`s install.sh and loses the shell that would hold the trap.
Thirty-odd had accumulated. It sweeps its own leftovers at the start of the next
run, which is better than a trap: the migration failure names a script path
*inside* that directory, and cleaning up at exit would delete the file the
operator was just told to run.

**The lesson, now three deep:** a string printed for a human to act on is not
verified by anything on the path. A URL, a command, a credential. Each was
produced by working code, next to a probe that passed, and each was wrong in a
way only a person could notice.

---

## 1. The installer TUI — done

`manage_menu` is a tab strip now: 概览 / 服务 / 证书 / 网络 / 危险操作 across the
top, that screen's actions down the side, its facts rendered between them.
←/→ switches, ↑/↓ selects, Enter runs, q leaves.

**The cost this file recorded for tabs was wrong.** It said a hand-rolled
raw-mode reader owing a terminal restore on every signal, with no plain-echo
fallback. That is true of an `stty` implementation. `read -rsn1` is not one: it
takes a single key without echoing and bash restores what it altered, so there
is no raw mode and nothing to strand an operator with echo off.
`test_tui_policy` asserts the absence of `stty` for exactly that reason, and
that the escape-sequence read times out — a bare ESC is someone leaving, and a
blocking read for the rest of the sequence would hang the menu.

The screens live in one `MANAGE_SCREENS` table read by both the tab UI and the
plain list, so the two cannot offer different things. The list stays, because
tabs draw at a cursor and read one key and therefore need both ends to be a
terminal; piped output and `TERM=dumb` still get a working menu.
`test_manage_menu_fallback` drives that path rather than grepping it.

`configure_install_tui` keeps its linear collection **deliberately**. Those
fields are dependency-ordered — the certificate mode decides whether an ACME
email and a Cloudflare token are asked for at all, the base domain is what the
DNS-prerequisite card is rendered from — so a screen enterable out of order
would present fields whose validity depends on answers not yet given. What it
lacked was not a way sideways but a way **back**: a typo in the base domain
first became visible on the summary, and the summary offered only yes or no, so
correcting one character meant cancelling the whole install. The summary is a
review screen now — confirm, or pick a field and re-answer it.

That also retired what `advanced` cost. It still decides which fields the first
pass stops on, but every field is reachable from the review, so an auto-detected
address an operator disagrees with no longer needs a rerun.

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

## 4. Marketplace — decided, and the gap is closed

Discovery works: `GET /gpn/interception/catalog`, a reviewed and digest-checked
install from an entry, and the zashboard listing. `test-env` fetches the
first-party index and reviews an entry from it.

**Decided 2026-08-03:**

- **Nothing signs the index.** The catalog grants no authority — every install
  still runs review → digest → confirm, and an entry that misdescribes its
  manifest is refused at the review. A compromised catalog host can mislead a
  listing; it cannot cause an install. Key management for that is cost without a
  matching threat.
- **An update may come from an entry, when asked.** `ApplyCatalogUpdate` moves an
  installed extension's source to the entry's manifest URL. `CheckUpdate` still
  re-reads only the URL an extension was installed from: the distinction is not
  "may the source ever change" but "may it change without being asked".

**Closed 2026-08-04:** sources can be added, removed and enabled/disabled from
the extensions page. Writes replace the whole list because that is the core's
contract, carried on the interception revision. The client mirrors the core's
validation so a rejection is explained where the operator is typing, and the
core remains the authority.

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

It currently holds `0.0.62-beta.28`, upgraded in place from the beta.9 fresh
install. Backups: `/root/5gpn-pre-freshinstall-20260803T011558Z` and
`/root/5gpn-pre-beta10-*`; the pre-console config.yaml is at
`/etc/5gpn/mihomo/config.yaml.pre-console.bak`. `get_public_ip` returns
`10.0.1.20` there. The panel has no allowlist; it answers any client that can
reach the box and resolve `console.5gpn.test`.

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
