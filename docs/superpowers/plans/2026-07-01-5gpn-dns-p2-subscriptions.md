# 5gpn-dns Phase 2 (Subscriptions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Go tasks follow TDD (write `*_test.go` first, watch it fail, implement, pass). Steps use checkbox (`- [ ]`).

**Goal:** An in-process subscription manager in `5gpn-dns` that fetches the four rule categories (adblock/direct/blacklist/chnroute) from remote URLs on a schedule, parses several list formats, caches to disk, merges with manual entries, keeps the old cache on failure, and hot-reloads — exposing a `Controller` for Phase 3's API.

**Architecture:** A `SubManager` goroutine reads `/etc/5gpn/subscriptions.json`, per-subscription ticker → HTTP GET → format parser → atomic write to `rulesDir/<category>/<name>.txt` → the existing atomic `swapRuleSets` reload. Domain categories already merge `<cat>.txt` + `<cat>/*.txt` via `globPattern` (seam exists); only chnroute needs a multi-file loader. A `Controller` wraps the manager + reload + manual-rule edits + stats.

**Tech Stack:** Go 1.26 + stdlib `net/http` (no new third-party dep beyond miekg/dns). Go tests run in CI + dev box; runtime validation on test-env (Debian).

**Spec:** [docs/superpowers/specs/2026-07-01-5gpn-dns-p2-subscriptions-design.md](../specs/2026-07-01-5gpn-dns-p2-subscriptions-design.md).

## Global Constraints

- **Cache path convention:** subscription caches are written to `rulesDir/<category>/<name>.txt` (the existing `globPattern` already globs `<category>/*.txt` and merges with the manual `<category>.txt`). Categories: `adblock`, `direct`, `blacklist`, `chnroute`. (The spec's `<cat>.d/` wording aligns to this existing `<cat>/` subdir form.)
- **Fail-safe:** on fetch error / parse error / entry count below the per-category floor (domain floor = 1, chnroute floor = 100), KEEP the existing cache file untouched; never write an empty/partial cache. Atomic write = temp file + `os.Rename`.
- **No blanking on reload:** `loadRuleSets` already errors on an empty chnroute; keep that.
- **Determinism/engine untouched:** do not change arbitration, the handler decision logic, or transports. P2 only adds loading sources + the manager + controller + counters.
- **Dependency floor:** stdlib `net/http` only; still just `github.com/miekg/dns` as the third-party dep.
- **In-process:** the fetch/schedule live in the binary (a `SubManager` goroutine started from `main`), NOT an external script.
- **Controller seam for P3:** P2 implements subscription methods + `Reload` + `AddRule`/`RemoveRule` + `Stats`; P3 adds `Lookup` and the HTTP layer. Keep method names exactly as in Task 4.
- **Branch:** direct on `main`. **Platform:** Go tests on dev box + CI; live fetch/sandbox on test-env.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `cmd/5gpn-dns/chnroute.go` | Modify | add `LoadChnrouteFiles(paths ...string)` (merge many CIDR files; empty→error) |
| `cmd/5gpn-dns/main.go` | Modify | chnroute load via multi-file glob; build `SubManager`+`Controller`; `go subMgr.Run(ctx)` |
| `cmd/5gpn-dns/parsers.go` (+`_test`) | Create | format parsers: plain/gfwlist/dnsmasq/adblock/hosts → domains; cidr → CIDRs |
| `cmd/5gpn-dns/subscription.go` (+`_test`) | Create | `Subscription`, `SubManager` (LoadSubscriptions, fetch+cache, Add/Remove, Update, Run) |
| `cmd/5gpn-dns/controller.go` (+`_test`) | Create | `Controller` wrapping SubManager + reload + AddRule/RemoveRule + Stats |
| `cmd/5gpn-dns/handler.go` | Modify | add atomic verdict counters (Stats source) |
| `cmd/5gpn-dns/config.go` | Modify | add `DNS_SUBSCRIPTIONS` (default `/etc/5gpn/subscriptions.json`) |
| `install.sh` | Modify | write default `subscriptions.json`; create `rules/<cat>/` dirs; env `DNS_SUBSCRIPTIONS` |
| `etc/systemd/5gpn-dns.service` | Modify | `ReadWritePaths=/etc/5gpn/rules` (manager writes caches) |
| `scripts/update-lists.sh` | Modify | become a manual `systemctl reload 5gpn-dns` trigger (chnroute now via subscription) |
| `tests/test_5gpndns_policy.sh` | Modify | grep asserts for the above |
| `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `tests/integration-smoke.md` | Modify | subscriptions model |

---

## Task 1: chnroute multi-file loader

**Files:** Modify `cmd/5gpn-dns/chnroute.go`, `cmd/5gpn-dns/main.go`; test `chnroute_test.go`.

**Interfaces — Produces:** `func LoadChnrouteFiles(paths ...string) (*Chnroute, error)` — parse+merge CIDRs from all existing paths (missing paths skipped); error if the merged set is empty.

- [ ] **Step 1: failing test** in `chnroute_test.go`:
```go
func TestLoadChnrouteFilesMerges(t *testing.T) {
	d := t.TempDir()
	a := filepath.Join(d, "a.txt"); os.WriteFile(a, []byte("1.0.0.0/8\n"), 0o644)
	b := filepath.Join(d, "b.txt"); os.WriteFile(b, []byte("203.0.113.0/24\n"), 0o644)
	c, err := LoadChnrouteFiles(a, b, filepath.Join(d, "missing.txt"))
	if err != nil { t.Fatal(err) }
	if !c.Contains(net.ParseIP("1.2.3.4")) || !c.Contains(net.ParseIP("203.0.113.5")) {
		t.Fatal("merge failed")
	}
}
func TestLoadChnrouteFilesEmptyErrors(t *testing.T) {
	if _, err := LoadChnrouteFiles(filepath.Join(t.TempDir(), "none.txt")); err == nil {
		t.Fatal("want error on empty")
	}
}
```
- [ ] **Step 2:** `cd cmd/5gpn-dns && go test ./... -run Chnroute` → FAIL (undefined).
- [ ] **Step 3:** implement `LoadChnrouteFiles`: for each existing path, read+parse CIDRs into the same interval slice used by `LoadChnroute` (refactor `LoadChnroute` to call `LoadChnrouteFiles(path)`); sort+merge; error if 0 entries. Keep `LoadChnroute` as a one-path wrapper for existing callers/tests.
- [ ] **Step 4:** In `main.go` `loadRuleSets`, replace `LoadChnroute(cfg.ChnrouteFile)` with `LoadChnrouteFiles(append([]string{cfg.ChnrouteFile}, globChnrouteDir(cfg.RulesDir)...)...)` where `globChnrouteDir` globs `filepath.Join(rulesDir,"chnroute","*.txt")` (reuse the same glob style as `globPattern`).
- [ ] **Step 5:** `go vet ./... && go test ./...` PASS. Commit `feat(sub): chnroute multi-file loader (manual + chnroute/*.txt)`.

## Task 2: Format parsers (TDD)

**Files:** Create `cmd/5gpn-dns/parsers.go`, `parsers_test.go`.

**Interfaces — Produces:**
```go
// Each parser takes raw bytes, returns normalized, deduped, sorted lines.
func ParseDomains(format string, raw []byte) ([]string, error) // format: plain|gfwlist|dnsmasq|adblock|hosts
func ParseCIDRs(raw []byte) ([]string, error)                  // cidr format
var ErrUnknownFormat = errors.New("unknown format")
```

- [ ] **Step 1: failing tests** covering each format with a small sample and expected output:
  - `plain`: `"a.com\n# c\nb.com\n"` → `[a.com b.com]`.
  - `gfwlist` (base64 of `||x.com^\n|http://y.com\n@@||white.com^\n!comment`) → `[x.com y.com]` (`@@` whitelist + `!` comment dropped).
  - `dnsmasq`: `"server=/z.cn/114.114.114.114\naddress=/w.cn/1.1.1.1\n"` → `[w.cn z.cn]`.
  - `adblock`: `"||ad.com^\n||b.com^$third-party\n##.banner\n@@||ok.com^\n/regex/\n"` → `[ad.com b.com]` (element-hide `##`, exception `@@`, regex dropped; `$modifier` on a pure-domain block kept as the domain).
  - `hosts`: `"0.0.0.0 h.com\n127.0.0.1 g.com localhost\n"` → `[g.com h.com]` (take the domain field(s) after the IP; skip `localhost`? keep simple: take the FIRST hostname after the IP → `[g.com h.com]`).
  - `cidr` via `ParseCIDRs`: `"1.0.0.0/8\n# x\nbad\n2.2.2.0/24\n"` → `[1.0.0.0/8 2.2.2.0/24]` (bad line skipped).
  - unknown format → `ErrUnknownFormat`.
- [ ] **Step 2:** FAIL. **Step 3:** implement each parser (stdlib: `bufio`, `strings`, `encoding/base64`, `net` for CIDR validation; lowercase+trim-dot domains; dedup via map; sort). **Step 4:** PASS. **Step 5:** commit `feat(sub): rule-list format parsers (plain/gfwlist/dnsmasq/adblock/hosts/cidr)`.

## Task 3: Subscription config + SubManager (TDD w/ httptest)

**Files:** Create `cmd/5gpn-dns/subscription.go`, `subscription_test.go`.

**Interfaces — Consumes:** `ParseDomains`/`ParseCIDRs` (Task 2). **Produces:**
```go
type Subscription struct {
	ID, Category, Name, URL, Format string
	Enabled  bool
	Interval time.Duration // JSON string like "24h"
}
type UpdateResult struct{ ID string; OK bool; Entries int; Err string }
type SubManager struct{ /* path, rulesDir, subs []Subscription, http *http.Client, reload func() error, mu sync.Mutex */ }
func LoadSubscriptions(path string) ([]Subscription, error) // parse subscriptions.json ({"subscriptions":[...]}); missing file => nil,nil
func NewSubManager(path, rulesDir string, reload func() error) (*SubManager, error)
func (m *SubManager) List() []Subscription
func (m *SubManager) UpdateOne(ctx context.Context, id string) UpdateResult // fetch+parse+guard+atomic-write cache; then reload()
func (m *SubManager) UpdateAll(ctx context.Context) []UpdateResult
func (m *SubManager) Add(s Subscription) error    // validate + persist json + UpdateOne
func (m *SubManager) Remove(id string) error      // persist json + delete cache file + reload
func (m *SubManager) Run(ctx context.Context)     // per-enabled-sub ticker; initial pass if cache missing/stale
```

- [ ] **Step 1: failing tests** using `httptest.Server` (return canned bodies) + a temp rulesDir + a `reload` counter:
  - `LoadSubscriptions`: good JSON parses (Interval `"24h"`→`24*time.Hour`); missing file → `(nil,nil)`; bad JSON → error.
  - `UpdateOne` success: httptest returns `"a.com\nb.com\n"` (plain, category blacklist) → writes `rulesDir/blacklist/<name>.txt` with the two domains, `reload` called once, result `OK, Entries:2`.
  - **keep-old on failure**: pre-write a cache file, then `UpdateOne` where httptest returns 500 (or a body that parses to 0 entries under the floor) → cache file UNCHANGED, result `OK:false`, `reload` NOT called (or called but cache preserved).
  - `Add` persists to subscriptions.json (re-`LoadSubscriptions` sees it) + creates the cache; `Remove` deletes the cache file + removes from json.
  - atomic write: no `.tmp` left behind.
- [ ] **Step 2:** FAIL. **Step 3:** implement: `http.Client{Timeout:30s}`, `io.LimitReader` cap (e.g. 32MiB), pick parser by `Category`(cidr for chnroute else `Format`→ParseDomains), floor guard, temp+rename to `rulesDir/<category>/<name>.txt` (mkdir the category dir), call `reload()` only on a successful write. `Run`: `time.NewTicker(sub.Interval)` per enabled sub in goroutines, `select` on ctx.Done; initial `UpdateOne` if the cache file is missing. `Add`/`Remove` mutate `m.subs` under mutex + rewrite the json (marshal `{"subscriptions":...}`, Interval back to string).
- [ ] **Step 4:** PASS (`go test ./... -run Sub`). **Step 5:** commit `feat(sub): subscription manager (fetch/parse/cache/schedule, keep-old-on-failure)`.

## Task 4: Controller + engine Stats (TDD)

**Files:** Create `cmd/5gpn-dns/controller.go`, `controller_test.go`; modify `handler.go` (counters).

**Interfaces — Consumes:** `SubManager`, `reload func() error`. **Produces:**
```go
type Stats struct{ Total, Direct, Proxy, Block uint64; CacheEntries int; ChinaOK, ChinaErr, TrustOK, TrustErr uint64 }
type Controller struct{ /* subs *SubManager; reload func() error; rulesDir string; stats *statsCounters; cacheLen func() int */ }
func NewController(subs *SubManager, reload func() error, rulesDir string, stats *statsCounters, cacheLen func() int) *Controller
func (c *Controller) Subscriptions() []Subscription
func (c *Controller) AddSubscription(s Subscription) error
func (c *Controller) RemoveSubscription(id string) error
func (c *Controller) Update(ctx context.Context, id string) []UpdateResult // id==""→all
func (c *Controller) AddRule(cat, entry string) error    // append to rulesDir/<cat>.txt (validate domain/cidr) + reload
func (c *Controller) RemoveRule(cat, entry string) error // rewrite manual file w/o entry + reload
func (c *Controller) Reload() error
func (c *Controller) Stats() Stats
// handler.go: a statsCounters with atomic increments; ServeDNS/resolve bumps Total + the chosen verdict.
```

- [ ] **Step 1: failing tests**: `AddRule("blacklist","x.com")` appends to `<rulesDir>/blacklist.txt` and calls reload; invalid domain/cidr → error, file unchanged; `RemoveRule` removes the line; `Update("")` delegates to `UpdateAll`; `Stats()` returns the counter snapshot; a handler test asserting a resolved query increments `Total` and the right verdict counter (Direct/Proxy/Block).
- [ ] **Step 2:** FAIL. **Step 3:** implement Controller (thin delegation; AddRule/RemoveRule = validate + manual-file edit + `reload()`); add `statsCounters` (atomics) to `Handler`, bump in `resolve` per verdict (block=adblock NXDOMAIN, proxy=gateway-rewritten/blacklist, direct=CN/direct kept). `cacheLen` returns `cache.Len()` (add if missing). **Step 4:** PASS. **Step 5:** commit `feat(sub): Controller (subs+rules+reload+stats) and engine verdict counters`.

## Task 5: main wiring + config

**Files:** Modify `cmd/5gpn-dns/config.go`, `main.go`; test `config_test.go`.

- [ ] **Step 1:** `config_test.go`: `DNS_SUBSCRIPTIONS` env parsed (default `/etc/5gpn/subscriptions.json`). FAIL.
- [ ] **Step 2:** config.go: add `SubscriptionsFile: envOr("DNS_SUBSCRIPTIONS","/etc/5gpn/subscriptions.json")`. PASS.
- [ ] **Step 3:** main.go: after building the Handler + `reload` closure (that calls `loadRuleSets`+`swapRuleSets`), construct `subMgr, err := NewSubManager(cfg.SubscriptionsFile, cfg.RulesDir, reload)` (nil/skip if file missing), `ctrl := NewController(subMgr, reload, cfg.RulesDir, h.stats, h.cache.Len)`, and `go subMgr.Run(ctx)`. Keep SIGHUP→reload. (ctrl is unused in P2 beyond construction; P3's server takes it — keep it in scope, e.g. return from a setup func, so P3 wires it. Acceptable to leave a `_ = ctrl` with a comment "P3 API consumes this" — but prefer storing it where P3 will read it.)
- [ ] **Step 4:** `go vet ./... && go test ./... && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/5gpn-dns .` all pass. **Step 5:** commit `feat(sub): wire SubManager+Controller into main; DNS_SUBSCRIPTIONS config`.

## Task 6: install + systemd + firewall + update-lists + grep tests

**Files:** Modify `install.sh`, `etc/systemd/5gpn-dns.service`, `scripts/update-lists.sh`, `tests/test_5gpndns_policy.sh`.

- [ ] **Step 1 (grep test first):** extend `tests/test_5gpndns_policy.sh` to assert: `install.sh` writes `subscriptions.json` and creates `rules/blacklist`,`rules/direct`,`rules/adblock`,`rules/chnroute` dirs and references `DNS_SUBSCRIPTIONS`; `5gpn-dns.service` has `ReadWritePaths=/etc/5gpn/rules`; `update-lists.sh` does `systemctl reload 5gpn-dns` (no direct fetch of chnroute for the resolver). Run → FAIL.
- [ ] **Step 2:** `etc/systemd/5gpn-dns.service`: add `ReadWritePaths=/etc/5gpn/rules` (the sandbox otherwise blocks cache writes under `ProtectSystem=strict`). Keep `ReadOnlyPaths` for the rest.
- [ ] **Step 3:** `install.sh` `full_install`: create `/etc/5gpn/rules/{adblock,direct,blacklist,chnroute}/` dirs; write a default `/etc/5gpn/subscriptions.json` with one enabled `chnroute` subscription pointing at `https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt` (format `cidr`, interval `24h`) — this replaces the P1 update-lists chnroute fetch — plus commented/disabled examples for the other three categories; add `DNS_SUBSCRIPTIONS=/etc/5gpn/subscriptions.json` to `dns.env`.
- [ ] **Step 4:** `scripts/update-lists.sh`: repurpose to a manual refresh trigger — `systemctl reload 5gpn-dns` (SIGHUP re-reads caches); drop the china_ip_list download (the in-process manager owns it now). Keep the gum preamble + DRY_RUN.
- [ ] **Step 5:** `bash tests/test_5gpndns_policy.sh` PASS + `bash -n install.sh scripts/update-lists.sh`. Commit `feat(install): default subscriptions.json + rules subdirs; sandbox ReadWritePaths; update-lists→reload`.

## Task 7: Docs

**Files:** Modify `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `tests/integration-smoke.md`.

- [ ] **Step 1:** DESIGN.md §4/§9: rule sets are now manual file + subscriptions (`<cat>/*.txt` caches); the in-process manager. §12: add a 2026-07-01 Phase-2 entry. README: features mention subscription auto-update. CLAUDE.md: note "rule lists now support subscriptions (Phase 2 done)" reversing the manual-only note. integration-smoke.md: add subscription checks (Task 8's matrix).
- [ ] **Step 2:** Commit `docs: Phase 2 subscriptions`.

## Task 8: test-env validation

**Files:** none (validation); record in integration-smoke.md.

- [ ] **Step 1:** Cross-compile (`GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build`), scp to test-env.
- [ ] **Step 2:** Start a local `python3 -m http.server`-style httptest OR write a tiny file server serving a `blacklist` list; point a subscription at it (via a test `subscriptions.json`); run `5gpn-dns` with a self-signed cert + mock china upstream (reuse the Phase-1 harness).
- [ ] **Step 3 (validate):** after startup, the subscription's cache file appears at `rules/blacklist/<name>.txt` and a listed domain now resolves to the gateway IP (blacklist verdict). Change the served body → trigger `UpdateAll` (or wait/short interval) → cache + behavior update (hot-reload, no restart). Stop the file server → next update KEEPS the old cache (domain still blacklisted). Confirm the systemd sandbox `ReadWritePaths=/etc/5gpn/rules` lets the manager write (run under the real unit; no permission error).
- [ ] **Step 4:** Record results in integration-smoke.md; commit `test: validate Phase 2 subscriptions on test-env`.

---

## Self-Review

**1. Spec coverage:** §3 config → T3/T5; §4 parsers → T2; §5 SubManager/Controller/loading → T1/T3/T4/T5; §6 install/systemd/update-lists → T6; §7 tests → T1-T4 (Go) + T6 (grep) + T8 (test-env); §8 risks → covered (keep-old, sandbox). Controller for P3 → T4 (methods named exactly; Lookup deferred to P3 per spec). **No gaps.**
**2. Placeholder scan:** parsers, SubManager, Controller show interfaces + concrete failing tests + implementation rules; shell steps give exact directives. No TBD.
**3. Type consistency:** `Subscription`/`UpdateResult`/`SubManager` methods, `Controller` methods, `Stats` fields consistent across T3/T4/T5; cache path `rulesDir/<category>/<name>.txt` consistent with `globPattern`; `LoadChnrouteFiles` used in T1+T5. **Consistent.**
