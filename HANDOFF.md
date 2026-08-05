# 5gpn monolith handoff

The current release contract is described by
[`docs/architecture.md`](docs/architecture.md), which is normative, and by the
git history. Most narrative below records earlier beta work and is explicitly
superseded where it conflicts with the current monolith or HTTP/3 boundary.

| Repository | Maintenance branch | Release coordinate |
| --- | --- | --- |
| `moooyo/mihomo` | `feat/5gpn-monolith` | `v1.19.28-monolith.13` |
| `moooyo/zashboard` | `feat/5gpn-console` | `v3.16.0-monolith.20` |
| `moooyo/5gpn` | `main` | `0.0.63` |

The stable release has one long-running process: mihomo. HTTP/3 interception is
unsupported, `http3=true` is rejected, and the fixed global UDP/443 `REJECT`
cannot be disabled through product management. Fallback-capable clients may
retry over TCP and enter HTTP/H1/H2 capture; H3-only clients fail. There is no
sidecar, runtime-overlay publication, or loopback SOCKS return path.

Green: `go test -race ./gpn/...` (**run it in WSL** — Windows has no gcc, so
`-race` cannot build there), all 28 installer suites, four console build-time
checks, and CI on every branch push. See [Reproducing the checks](#reproducing-the-checks).

---

## Pick up here

Nothing is half-finished; everything below is a next thing, not a loose end.
The former beta line is promoted to `main` as stable `0.0.62`; `main`, `beta`,
and `feat/installer-tui` identify the same release commit.

In the order they are worth doing:

1. **A render smoke test for the console** — mount each page, assert no throw,
   and assert no sidebar route row falls outside the sidebar's box at a short
   viewport. Eleven console faults so far, all found by the owner because
   nothing in CI opens a page. happy-dom is enough for the first half and **not**
   for the second: the eleventh fault was pure layout, so the height assertion
   needs a real engine (the CDP harness that found it is described below, under
   "The sidebar dropped its last tab").
2. **Second-install acceptance** — still the top item on the installer side, and
   still nothing installs, upgrades, then asserts. Nine of ten faults in the
   earlier round lived in that transition.
3. **`gpn/engine` request-path tests** — the proxy path, the goja runtime and
   TLS termination are the largest untested surface, and they are the parts that
   see live traffic and run operator-supplied JavaScript.
4. **Unverified despite shipping:** the read-only bot against a real Telegram
   token.
5. **Three lifecycle functions with no callers** — `stopBot`, `stopDns`,
   `stopInterception`. Switching backends does not clear those assemblies. Each
   `refresh*` guards on `activeUuid`, so the blast radius is small, but it is the
   same class as the capability probe that was never called.

**Read before touching the console:** the four `npm run build` checks exist
because each caught something that shipped. Do not weaken one to make a change
pass.

## 0. Acceptance — green

This is a superseded beta acceptance record. `0.0.62-beta.42` was deployed on
`test-env` with core `v1.19.28-monolith.11` and console
`v3.16.0-monolith.19`, upgraded in place. Acceptance there was:

| Suite | Result |
| --- | --- |
| `acceptance-monolith.sh` | **19 / 19** |
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

**Partly retired 2026-08-04.** A fresh gateway now seeds the China-direct and
GFW-proxy subscriptions, so `2 subscription(s) fetched and live` runs instead of
reporting `--`, and the suite went 18 -> 19. The block-rule check is still
conditional: the seeded defaults carry no block intent, so nothing on a default
gateway proves a block rule returns NXDOMAIN. That one still needs a configured
gateway and no suite requires one.

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

**Two bugs produced that, and the second is the one that mattered.**

`initCapabilityDiscovery` was **never called**. Its only mention outside its own
definition was its own retry timer, and nothing schedules a first attempt. So
`states` stayed `{}`, `featureState` returned `'unknown'` for every key,
`featureSupported` was permanently false, and both gates — `renderRoutes` and
SettingsPage's `menuItems` — filtered the entire 5gpn surface out. **On every
backend, always.** The lazy route chunks shipped in the bundle and were
unreachable. It compiled, it linted, and the pages existed; nothing on the path
could notice, because the thing that was missing was a caller.

It is triggered at module scope now, on `activeUuid`, `immediate`, the same
shape `version.ts` uses. `scripts/check-capability-probe.mjs` runs before every
build and asserts that specific property — a general unused-export sweep does
not catch it, because the function was referenced twice inside its own file and
reads as used by any reference count.

The second, found first: SetupPage's empty-list bootstrap
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

**Then the page it unlocked was blank**, with `SyntaxError: 10` and nothing else
— @intlify strips its error text from production builds, so the code is the
whole message. 10 is `INVALID_LINKED_FORMAT`, and the cause was
`gpnUpstreamGrammar`, the help text that documents the upstream spelling:
`serverName@IP` is DoT, `https://host/path@IP` is DoH. **`@` is vue-i18n's
linked-message syntax**, so compiling that message throws, and the throw happens
during render. All four locales carried it. The literal escape is `{'@'}`.

Nothing could catch it as written: valid TypeScript, typechecks, lints, ships,
and the only place it fails is the one page that renders it. It also survived a
grep for quoted values containing `@`, because prettier had wrapped the key and
the value onto separate lines. So the check runs **every message through the
compiler vue-i18n uses at runtime** — 2548 across four locales — rather than
linting for a character.

And a third console error on every load: the service worker cannot register
behind the self-signed `CERT_MODE=debug` certificate — a browser lets an
operator click through the warning to view a page but not to register a worker —
and vite-plugin-pwa's injected `registerSW.js` calls `register()` with no catch,
so it surfaced as an uncaught `SecurityError` with a stack. Noise that
guaranteed is what the next real error gets scrolled past. The panel owns the
registration now and prints one line.

**The lesson, now three deep:** a string printed for a human to act on is not
verified by anything on the path. A URL, a command, a credential. Each was
produced by working code, next to a probe that passed, and each was wrong in a
way only a person could notice.

---

## The console round, 2026-08-04 — and where its faults lived

Ten console-side faults in one day. **Every one compiled, typechecked, linted
and shipped, and every one failed only in a browser.** That is the shape to
carry forward: the checks this repository is good at cannot see any of them.

**Four made the panel look like it had no 5gpn in it at all:**

- `initCapabilityDiscovery` was **never called** — its only mention outside its
  own definition was its own retry timer. So `featureSupported` was permanently
  false and both gates, `renderRoutes` and SettingsPage's `menuItems`, filtered
  the entire 5gpn surface out on every backend, forever. The pages shipped as
  lazy chunks nobody could route to.
- SetupPage's empty-list bootstrap guessed `http://127.0.0.1:9090`. 5gpn serves
  the bundle from the controller, so all three fields are wrong, it failed
  silently, and there was no backend to probe.
- `gpnUpstreamGrammar` documented the upstream spelling `serverName@IP`, and
  **`@` is vue-i18n's linked-message syntax** — the compile throws during render
  and blanked the DNS page, reported only as `SyntaxError: 10`.
- Three snapshot lists could marshal as JSON `null` (Go nil slices) and the
  console read `.length` off them, so a gateway with no extensions rendered the
  extensions page into a TypeError.

**Guards, all in `npm run build`:** `check-capability-probe.mjs` (the probe has a
module-level trigger), `check-i18n-compiles.mjs` (every message through the real
compiler — 2804 of them), `check-i18n-keys-exist.mjs` (every literal `t('key')`
resolves in en), `check-built-output.mjs` (the shipped service-worker
registration handles its own failure). Plus a Go test asserting the snapshot's
list fields never marshal as null.

**What moved, and the principle behind it.** The owner's rule is that settings
live in the settings page. So: DNS policy, upstreams and diagnostics became a
settings category; the three interception toggles moved off the extensions page
into the panel that had been rendering them as read-only badges; rule
subscriptions got their own row. The extensions page became tabs
(已安装 / 扩展市场 / 从 URL 安装 / 日志) with SegmentedControl, and the catalog
was renamed to the marketplace it is — the entry for adding one had existed all
along, but nothing on screen used the word, so it was invisible while visible.

**No save buttons.** zashboard's answer for a settings row that writes to the
backend is to write on `@change` — `BackendPortsGrid` patches `/configs` that
way and the tun/allow-lan toggles beside it do the same. The DNS panel's
save/revert bar was this fork inventing a second interaction model.

**The two DNS rule rows stopped overlapping, and the core now pins the
precedence.** A subscription is a rule with `kind=subscription`, so it was
listed and editable in *both* dialogs, and the kind dropdown could turn a
hand-written rule into a subscription in place — at which point it vanished
from the list you were looking at and reappeared in the other one, unannounced.
Two entry points for one row. They are disjoint now: 解析规则 holds only
hand-written matchers and offers only the three kinds that are one; 规则订阅
owns the URL rules and took over the reorder buttons.

Splitting the lists takes away the shared index, and `classify` returns the
first match — so "does my exception beat the imported list?" would have had no
visible answer. **Owner decision: every hand-written rule is evaluated before
every subscription.** `Policy.ordered` groups the slice in `Service.Update`, so
the panel, the bot and a direct PUT all get the same precedence, and again on
open, so a gateway configured under the old interleaved model converges at once
instead of resolving in the old order until someone next edits the policy.
Grouping the stored document rather than the match loop keeps the existing
invariant: a rule's position in the slice is still the whole statement of when
it runs. `gpn/dns/policy_order_test.go` pins all of it.

**Extension logs.** Capture already existed and was well bounded; `Publish` threw
every event away unless a websocket was already attached. Right for a live tail,
wrong for a debug log — an operator opens it after something broke, so a stream
starting at "now" has nothing. The hub retains its ring unconditionally now and
`GET /gpn/interception/logs` reads it with extension, level and substring
filters.

**Also shipped:** the DNS overview card (QPS by sampling `total`, cache hit rate,
decision mix, upstream health) built from zashboard's own overview pieces; the
setup guide as a page, deriving everything from the origin serving it; the
default China-direct and GFW-proxy subscriptions, seeded by the core AND
offered explicitly in the console because a default only ever reaches an absent
document.

**One place per number.** The DNS settings page carried a statistics block that
was the text copy of what the overview card draws — total, cache hits/lookups/
entries, and both upstream groups — read twice, and in that copy with no trend.
It is gone. "Steered to the gateway" went with it: it was the sum of two slices
the decision mix already separates by cause. "CN ranges loaded" is the one entry
on that list that is not a statistic — it is the ground arbitration stands on,
and at zero every address is judged foreign and the whole Chinese internet is
steered into the tunnel — so it moved onto the card as a permanent footnote
instead of being dropped. Upstream health is now two sparklines of p50 with
ok/total and p95, sampled by the same one-second poller as QPS; a quiet gateway
returns to no samples after 15 minutes, and those points carry `init` so the
chart does not claim a 0 ms resolver.

**The overview has two surfaces, and the default configuration shows only one.**
The DNS card was reported missing twice. It was not missing: `splitOverviewPage`
is **off by default**, and with it off `renderRoutes` drops the `overview` route
entirely — the overview is embedded in the settings page, and what renders there
is `components/settings/overview/OverviewCard.vue`, a **fixed list of two cards
that does not read `overviewCardOrder`**. So a card added to
`defaultOverviewCardOrder` renders correctly on `OverviewPage` and is reachable
only by someone who has turned the split on. Both times I checked the page it
does render on. **Adding an overview card means touching both surfaces.** The
fixed list was left fixed on purpose: switching it to `overviewCardOrder` would
also pull TopologyCharts, ConnectionHistory, ProviderTrafficOverview and
RuleHitCountCard into the settings page, which is upstream's curation to make.

**One recurring trap, now three deep.** A string printed for a human to act on
is verified by nothing: the `/ios/` profile URL that 404'd while the probe
checked `/ui/`, the migration command that answered `command not found` because
nothing in `scripts/` has the executable bit, and the banner that printed
`DNS_API_TOKEN` when the panel takes `DNS_MIHOMO_SECRET`.

**And one that is not fixed.** I cannot render these pages. Every console fault
this round was found by the owner, not by me. The cheap generalisation — a
vitest + happy-dom smoke test that mounts each page and asserts it does not
throw — would have caught the i18n compile, the null `.length`, and arguably the
probe. It was declined this round to avoid three devDependencies and rebase
friction on the fork. **It is the highest-value thing left on the console side.**

---

## The sidebar dropped its last tab, and the scrollbar that would have said so

Reported 2026-08-04: after a refresh the sidebar is one tab short, and clicking
another tab makes it correct. It was `Settings`, the last row.

**Nothing in the DOM was wrong.** Twenty consecutive reloads against `test-env`
gave eight rows every time, each with its icon, at every viewport from 1440×900
to 1280×500, collapsed and expanded, on every route, with the tab indicator
aligned. The capability probe does add the three 5gpn tabs a frame after first
paint — 13–21 ms, measured over twenty reloads — but that is not clickable, and
it is all three at once, never one.

**`.sidebar` is a scroll container whose scrollbar is hidden.** `overflow-x-hidden`
makes `overflow-y` compute to `auto`; `.scrollbar-hidden` then removes the
scrollbar. So "does not fit" does not render as "scroll me". It renders as "not
there". And nothing in the column could shrink — nav, statistics and carousel all
carried the default `min-height: auto` — so below roughly 677 px of window height
the column exceeded its box and the excess was cut, bottom first: statistics,
then, under ~304 px, the last route row. The tell was in the owner's own
screenshots: **neither one showed the statistics block**, which a 493 px render
shows plainly.

**Navigation is the one block that must never be the one to go** — losing a row
means losing the only way to reach a page. The secondary blocks now declare
`min-h-0` and scroll themselves. Measured against the live gateway: sidebar
overflow was 176 px at a 493 px window, and is 0 down to 360 px, with all eight
rows inside the box down to 310 px. Below that the window is shorter than the
navigation itself and something has to scroll.

Two more came out of the same file. The list carried `h-full`, pinning it to the
nav's height: daisyUI's `.menu` is `flex-flow: column wrap`, so a squeezed nav
would fold rows into a second column that `overflow-x-hidden` then clipped — and
because the `ul`'s size never changed, `useResizeObserver` could never fire. And
the indicator watch did not include `renderRoutes`, so nothing re-measured the
highlight when the 5gpn tabs arrived a frame late.

**How it was found, and the tool that is now available.** Headless Chrome over
CDP, driving the deployed console with a seeded backend, then serving a locally
built `dist/` over the real origin through `Fetch.fulfillRequest` so the fix
could be verified against the live gateway without deploying anything. That is
the second exhibit for the open item above: **this was a layout fault, so
happy-dom would not have caught it.** A render check for the console needs real
layout.

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

## 2. Historical request-path test gap (superseded record)

The largest untested surface in the tree, and inherited rather than introduced.

At the time, coverage included the document (`manage_test.go`), the manifest parser
(`manifest_test.go`), the certificate store's presence/absence contract
(`cert_test.go`), the catalog (`catalog_test.go`), and capture ownership. The
former datagram/HTTP3 tests do not define the current product contract.

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

## 3. Historical datagram-capture design (superseded)

The earlier beta attempted a QUIC bridge. That path is not a supported product
capability. Current `MatchUDP` leaves UDP/443 to the fixed reject guard and
`http3=true` is invalid.

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

## 6. UDP / HTTP/3 — current contract

HTTP/3 interception is unsupported. `mitm.http3` must be `false`; startup and
management writes reject `true`. The seed's fixed
`AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` is evaluated before extension rules
or capture and cannot be disabled through the controller rule-management API.
Removing it manually from the operator-owned YAML withdraws interception
readiness; it does not enable QUIC capture.

A client that supports fallback may retry over TCP and reach plain HTTP or
TLS/H1/H2 capture. H3-only clients fail. The rule is scoped to gateway UDP/443
and does not disable ordinary UDP or QUIC sniffing on another configured port,
including the optional `:5060` ingress.

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

**Console** — the fork is at `D:/Code/worktrees/zashboard-5gpn-console`. Its
remote for our fork is **`fork`**, not `origin`; `origin` is upstream
Zephyruso/zashboard and pushing there fails.

```
npm run type-check      # vue-tsc; plain tsc cannot resolve .vue
npm run build           # runs the four checks first, then vite
```

The four checks are `scripts/check-{capability-probe,i18n-compiles,i18n-keys-exist,built-output}.mjs`.
`check-built-output.mjs` runs AFTER vite because it inspects `dist/`.

**Release loop, all three repositories.** Each artifact is pinned by version AND
digest, and the two must move together or the installer downloads the right file
and refuses it.

```
# console
cd zashboard-5gpn-console && git push fork feat/5gpn-console
git tag v3.16.0-monolith.N && git push fork v3.16.0-monolith.N   # triggers 5gpn-release.yml
curl -fsSL -o z.zip https://github.com/moooyo/zashboard/releases/download/<tag>/dist.zip
sha256sum z.zip                                                   # -> ZASH_SHA256

# core: built locally, there is no CI release for it
cd mihomo-5gpn-monolith
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 go build -tags with_gvisor -trimpath   -ldflags '-X "github.com/metacubex/mihomo/constant.Version=<tag>"             -X "github.com/metacubex/mihomo/constant.BuildTime=<date -u>" -w -s -buildid='   -o mihomo-linux-amd64-compatible .
gzip -k …  &&  gh release create <tag> --repo moooyo/mihomo --prerelease <asset>.gz

# installer: bump BOTH install.sh and .github/workflows/checks.yml for the core
bash tests/verify-artifact-pins.sh
git push --atomic origin HEAD:feat/installer-tui HEAD:beta HEAD:main
git tag X.Y.Z && git push origin X.Y.Z
```

`MIHOMO_VERSION`/`MIHOMO_SHA256` appear in **two** files — `install.sh` and
`.github/workflows/checks.yml`. Bumping only one fails CI's seed gate.

**Deploying to test-env.** Re-fetch `quick-install.sh` **by commit SHA**, not by
branch: `raw.githubusercontent.com` caches a branch for minutes and you will
silently run the previous revision.

```
ssh test-env 'curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/<sha>/quick-install.sh -o /tmp/qi.sh && sudo bash /tmp/qi.sh'
```

Windows OpenSSH only. Keep remote commands straight-line — heredocs through
`ssh` from PowerShell get mangled; write the script locally and `scp` it.

**After deploying, hard-reload the browser.** zashboard is a PWA
(`registerType: 'autoUpdate'`) and will otherwise serve the previously cached
bundle, which reads exactly like "the fix did not land".

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

An upgrade **is** headless: `bash quick-install.sh` on a provisioned host
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

Before stable promotion it held `0.0.62-beta.38`, upgraded in place from the
beta.9 fresh install. Verify the live version rather than treating this
historical snapshot as current. Backups: `/root/5gpn-pre-freshinstall-20260803T011558Z` and
`/root/5gpn-pre-beta10-*`; the pre-console config.yaml is at
`/etc/5gpn/mihomo/config.yaml.pre-console.bak`. `get_public_ip` returns
`10.0.1.20` there. The panel has no allowlist; it answers any client that can
reach the box and resolve `console.5gpn.test`.

**Read the journal, not just the installer's exit code.** The interception
engine failing to load is a `[GPN]`-tagged warning in `journalctl -u mihomo`,
and the install reports success regardless — that is how a build that refused
every deployed intercept.json looked like a clean upgrade.

Use `5gpn uninstall --decommission` for a clean host. Its ownership-marker and
canonical-path checks are the supported deletion boundary; do not replace it
with a broad recursive removal command.

The acceptance suites are not in the installer bundle; `scp` them from `tests/`
and strip CRLF. All four are on the host at `/root/acceptance-monolith*.sh`.
