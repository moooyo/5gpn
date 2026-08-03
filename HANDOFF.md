# What is not done — 5gpn monolith

Input for a design session, not a status report. Everything below is either
unbuilt or unverified; what *is* built is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Delete this file when the list empties.

Everything is pushed. `beta` is fast-forwarded to `feat/installer-tui`.

| Repository | Branch | Published |
| --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `v1.19.28-monolith.7` |
| `moooyo/zashboard` | `feat/5gpn-console` | `v3.16.0-monolith.3` |
| `moooyo/5gpn` | `feat/installer-tui` | `0.0.62-beta.21` |

Green: `go test -race ./gpn/...`, all 26 installer suites, and CI on every
branch push. See [Reproducing the checks](#reproducing-the-checks).

---

## 0. Acceptance — green

`0.0.62-beta.21` is deployed on `test-env`. Acceptance there:

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
`https://console.<base>/ui/` now, on the one controller, behind the source
allowlist. `zash.<base>` is deleted rather than aliased: an alias would be a
second way into the management plane with no second purpose.

The security half is the part worth restating. `zash.<base>` carried the
allowlist while the console rule was unrestricted, which was harmless only
because nothing listened for either. Moving the panel onto the console name
meant the allowlist had to move with it, and
`mihomo_config_matches_install_config`'s assertion had to **invert** — an
unrestricted console rule is now the management plane answering every client
whose DNS points at the gateway. `scripts/migrate-panel-to-console.sh` does the
four things this requires to an operator-owned config and nothing else.

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
  invisible. Every caller reads dns.env, so the readiness probe, `apply_whitelist`
  and the daemon all dialled a dead port and the install failed at "mihomo did
  not become ready" with mihomo running fine.
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

## 1. The installer TUI — rewritten; two things left

`manage_menu` is five screens now: 概览 / 服务 / 证书 / 网络 / 危险操作. Each
renders the facts its own actions act on, immediately above them. The two dead
entries are gone — 「重载规则」 with the helper it called, 「配置 Telegram Bot」
because the console owns it, and the overview says where the runtime surfaces
live so an operator is not left hunting.

`test_tui_policy` now compares the label list against the dispatch, which is the
coupling that let two entries do nothing for the whole of the monolith work.

**Left:**

- **Navigation is two levels, not tabs.** Gum's `choose` is a single-select list
  with no key handler, so left/right tabs would need a hand-rolled raw-mode
  reader with its own terminal restore on every signal — and it would have no
  plain-echo fallback, which is the property every surface here keeps. If tabs
  are wanted, that is the cost.
- **`configure_install_tui` is untouched.** The install-time flow is still a
  linear prompt sequence. It works and its shape is held by `test_tui_policy`,
  but it did not get the same treatment and nobody has decided whether it should.

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

## 4. Marketplace — decided, bar one gap

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

**Still open:** there is no UI for adding a second source. The document supports
16 and zashboard renders them all, but the only way in is a
`PUT /gpn/interception/catalog/sources`.

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

It currently holds `0.0.62-beta.21`, upgraded in place from the beta.9 fresh
install. Backups: `/root/5gpn-pre-freshinstall-20260803T011558Z` and
`/root/5gpn-pre-beta10-*`; the pre-console config.yaml is at
`/etc/5gpn/mihomo/config.yaml.pre-console.bak`. `get_public_ip` returns
`10.0.1.20` there, and `10.0.1.20/32` is the one entry in the panel allowlist.

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
