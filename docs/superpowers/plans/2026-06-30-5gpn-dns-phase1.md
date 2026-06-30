# 5gpn-dns Phase 1 Implementation Plan (Go DNS engine)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Go tasks follow TDD (write `*_test.go` first, watch it fail, implement, pass).

**Goal:** A self-built Go binary `5gpn-dns` that replaces smartdns + chinadns-ng as the DNS brain: serves DoT/DoH/plain ingress, handles all common query types, runs a deterministic chnroute arbitration (prefer China IP if present, no speed test), rewrites foreign IPs to the gateway IP (sing-box funnel), with four local-file rule sets (adblock/force-direct/blacklist/chnroute), caching, cert hot-reload, and SIGHUP reload.

**Architecture:** One Go package under `cmd/5gpn-dns/`, dep = `github.com/miekg/dns` only (chnroute/cache/rules/transports use stdlib; DoH uses `net/http`). Built in CI (`CGO_ENABLED=0` static linux-amd64) → GitHub release; `install.sh` downloads the prebuilt binary. sing-box data plane unchanged.

**Tech Stack:** Go 1.26 + `github.com/miekg/dns`; bash (`install.sh`, `scripts/*`), nftables, systemd, Python stdlib (`tgbot.py`). Go tests run in CI (`go test`) and on the dev box (Go 1.26.3 present). Runtime/behavior gates run on **test-env** (Debian 13) via dev-box cross-compile + scp.

**Spec:** [docs/superpowers/specs/2026-06-30-5gpn-dns-go-design.md](../specs/2026-06-30-5gpn-dns-go-design.md) (Phase 1 = §1-§13; subscriptions=P2, API/UI=P3 are out of scope here).

## Global Constraints

- **Determinism (load-bearing):** tier-default (`A` not on any list) returns China IPs iff the China upstream's answer contains an IP ∈ chnroute; decision is by chnroute membership of the China answer, **never by which upstream replied first**, and **no ping/speed test**. Wait for the China answer up to `DNS_QUERY_TIMEOUT`.
- **chnroute semantics:** IP ∈ chnroute ⇒ China (direct); IP ∉ chnroute ⇒ foreign ⇒ rewrite to `DNS_GATEWAY_IP`. There is no separate foreign-cidr file.
- **Query types:** `A` → arbitrate+rewrite; `AAAA` → SOA (IPv4-only); `HTTPS`/`SVCB`(type 65) → empty NOERROR; **all other types** → forward to trusted DoT, return verbatim (no rewrite). Cache first for every type.
- **Rule precedence (A semantics):** adblock (all qtypes → NXDOMAIN) > force-direct (resolve, return real IP, NO rewrite) > blacklist (A=gateway) > default arbitration. Domain on both direct+blacklist ⇒ direct wins.
- **Transports:** DoT `:853/tcp` (TLS, LE cert), DoH `:8443/https` (net/http, dns-message GET+POST, same cert), plain DNS `:53` udp+tcp (public — a deliberate reversal of the DoT-only stance; firewall rate-limits it), debug `127.0.0.1:5353` plain. All share one handler. **No DoQ / no quic-go.**
- **Cert hot-reload:** `tls.Config.GetCertificate` re-reads cert/key by mtime; renewal must NOT require a restart.
- **Dependency floor:** only third-party dep is `github.com/miekg/dns`. Everything else stdlib. Pin in `go.mod`.
- **Anti-loop:** upstreams are external only (China UDP, trusted DoT); never query self. sing-box's `22.22.22.22` resolver is unrelated and untouched.
- **No build toolchain on the box:** the binary is built in CI and downloaded by install.sh (`DNS_VERSION` pin, `DNS_SHA256` opt-in). Dev/validation: cross-compile on the Windows dev box (`GOOS=linux GOARCH=amd64 CGO_ENABLED=0`) + scp to test-env.
- **Branch:** direct on `main` (user-authorized).
- **Platform:** Go tests run on dev box + CI; runtime/DoT/transport/cert behavior is test-env. test-env SSH per CLAUDE.md (Windows native ssh; scp files; `tr -d '\r' | bash` for scripts).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `cmd/5gpn-dns/go.mod` / `go.sum` | Create | Module `github.com/moooyo/5gpn/cmd/5gpn-dns`; dep miekg/dns |
| `cmd/5gpn-dns/chnroute.go` (+`_test`) | Create | CN IPv4 set: load CIDR file → sorted uint32 intervals; `Contains(ip)`; reload |
| `cmd/5gpn-dns/rules.go` (+`_test`) | Create | Domain rule set: load file(s) → suffix matcher; `Match(name)`; reload |
| `cmd/5gpn-dns/cache.go` (+`_test`) | Create | TTL cache keyed by (name,qtype); size cap; get/put |
| `cmd/5gpn-dns/upstream.go` | Create | UDP + DoT query clients (miekg/dns), first-success of a group |
| `cmd/5gpn-dns/arbitrate.go` (+`_test`) | Create | Concurrent China+trusted query; chnroute decision; injectable for tests |
| `cmd/5gpn-dns/handler.go` (+`_test`) | Create | qtype dispatch, rule precedence, foreign→gateway rewrite, build response |
| `cmd/5gpn-dns/cert.go` | Create | mtime-reloading `GetCertificate` |
| `cmd/5gpn-dns/server.go` | Create | DoT/DoH/plain/debug listeners over one handler |
| `cmd/5gpn-dns/config.go` | Create | env → Config struct |
| `cmd/5gpn-dns/main.go` | Create | wire Config→sets→handler→servers; SIGHUP reload |
| `.github/workflows/release.yml` | Create | tag `dns-v*` → build static linux-amd64 + checksums → release |
| `.github/workflows/ci.yml` | Modify | add `go vet` + `go test ./...` |
| `etc/systemd/5gpn-dns.service` | Create | unit + EnvironmentFile + sandbox |
| `etc/5gpn-dns/dns.env.example` | Create | documented env defaults |
| `install.sh` | Modify | `install_5gpndns`, full_install swap, services, cert/renew, remove smartdns, env/help |
| `scripts/setup-firewall.sh` | Modify | open 53(udp/tcp)+853+8443; install 5gpn-dns unit; :53 rate-limit |
| `scripts/update-lists.sh` | Modify | fetch china_ip_list → /etc/5gpn/rules; SIGHUP 5gpn-dns; drop foreign-cidr/render |
| `scripts/renew-hook.sh` | Modify | copy cert → /etc/5gpn/cert; SIGHUP 5gpn-dns (no smartdns) |
| `scripts/gen_foreign_cidr.py`, `scripts/render_smartdns_conf.py`, `etc/smartdns.conf.template` | Delete | replaced |
| `tgbot.py` | Modify | SERVICES → `5gpn-dns` + sing-box; blacklist file path |
| `tests/test_5gpndns_policy.sh` | Create | grep asserts (install/unit/firewall/services) |
| `tests/test_smartdns_conf_policy.sh`, `tests/test_dns_split_policy.sh` | Delete | replaced by Go tests + new grep |
| `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `docs/HANDOFF.md`, `tests/integration-smoke.md` | Modify | new architecture; record reversals |

---

## Task 1: Module scaffold + chnroute matcher (TDD)

**Files:** Create `cmd/5gpn-dns/go.mod`, `chnroute.go`, `chnroute_test.go`.

**Interfaces — Produces:**
```go
type Chnroute struct{ /* sorted []ipRange */ }
func LoadChnroute(path string) (*Chnroute, error) // plain CIDR-per-line; '#' comments; skips bad lines
func (c *Chnroute) Contains(ip net.IP) bool        // IPv4; false for non-v4
func (c *Chnroute) Len() int
```

- [ ] **Step 1: failing test** `chnroute_test.go`:
```go
func TestChnrouteContains(t *testing.T) {
	dir := t.TempDir(); p := filepath.Join(dir, "cn.txt")
	os.WriteFile(p, []byte("1.0.0.0/8\n# comment\n203.0.113.0/24\nbogus\n"), 0o644)
	c, err := LoadChnroute(p)
	if err != nil { t.Fatal(err) }
	for _, tc := range []struct{ ip string; want bool }{
		{"1.2.3.4", true}, {"203.0.113.5", true},
		{"8.8.8.8", false}, {"203.0.114.1", false},
	} {
		if got := c.Contains(net.ParseIP(tc.ip)); got != tc.want {
			t.Errorf("Contains(%s)=%v want %v", tc.ip, got, tc.want)
		}
	}
}
func TestChnrouteRefusesEmpty(t *testing.T) {
	dir := t.TempDir(); p := filepath.Join(dir, "e.txt"); os.WriteFile(p, []byte("# none\n"), 0o644)
	if _, err := LoadChnroute(p); err == nil { t.Fatal("want error on empty chnroute") }
}
```
- [ ] **Step 2:** `cd cmd/5gpn-dns && go mod init github.com/moooyo/5gpn/cmd/5gpn-dns && go mod tidy` then `go test ./...` → FAIL (undefined).
- [ ] **Step 3:** implement `chnroute.go`: parse CIDR → `[start,end uint32]`, `sort.Slice` by start, merge overlaps; `Contains` = ipv4→uint32 + binary search (`sort.Search`); `LoadChnroute` returns error if 0 valid entries (guard: an empty set would make everything look foreign). 
- [ ] **Step 4:** `go test ./...` → PASS.
- [ ] **Step 5:** commit `feat(dns): module scaffold + chnroute matcher`.

## Task 2: Domain rule sets (TDD)

**Files:** `rules.go`, `rules_test.go`.

**Interfaces — Produces:**
```go
type DomainSet struct{ /* map[string]struct{} of normalized fqdns */ }
func LoadDomainSet(paths ...string) (*DomainSet, error) // one domain per line; '#'; lowercases; trims trailing '.'
func (d *DomainSet) Match(name string) bool             // suffix/parent match: a.b.example.com matches example.com
func (d *DomainSet) Len() int
```

- [ ] **Step 1: failing test** covering: exact match, parent-domain match (`a.b.example.com`→`example.com`), non-match (`notexample.com` must NOT match `example.com`), case-insensitivity, trailing-dot normalization, empty set ok (Len 0, Match false). Missing files are skipped (not an error) so optional rule files are fine.
- [ ] **Step 2:** `go test` → FAIL.
- [ ] **Step 3:** implement: load each existing path, normalize (`strings.ToLower`, trim `.`), store in a set; `Match` walks labels from full name up to TLD checking membership (`example.com`, then `com`), returns true on first hit. Guard against matching the empty/TLD-only string.
- [ ] **Step 4:** `go test` → PASS. **Step 5:** commit `feat(dns): domain rule sets (suffix match)`.

## Task 3: TTL cache (TDD)

**Files:** `cache.go`, `cache_test.go`.

**Interfaces — Produces:**
```go
type Cache struct{ /* mu, map[key]entry, max int */ }
type cacheKey struct{ name string; qtype uint16 }
func NewCache(max int) *Cache
func (c *Cache) Get(name string, qtype uint16) (*dns.Msg, bool) // returns a copy with adjusted TTLs; false if expired/absent
func (c *Cache) Put(name string, qtype uint16, m *dns.Msg, ttl time.Duration)
```

- [ ] **Step 1: failing test:** put then get returns a copy (mutating the returned msg must not corrupt cache); expired entry (ttl in the past via a faked clock or 1ns sleep) returns false; capacity eviction when exceeding max. Use a `now func() time.Time` field on Cache for deterministic expiry (inject in test) — do NOT call time.Now in a way the test can't control.
- [ ] **Step 2:** FAIL. **Step 3:** implement (mutex map; store expiry = now+ttl; Get checks expiry, deep-copies msg; simple size-cap eviction — evict oldest/any on overflow). **Step 4:** PASS. **Step 5:** commit `feat(dns): ttl cache`.

## Task 4: Upstreams + arbitration (TDD with injected upstreams)

**Files:** `upstream.go`, `arbitrate.go`, `arbitrate_test.go`.

**Interfaces — Produces:**
```go
// An Exchanger sends a query and returns the reply (one upstream or a group).
type Exchanger interface{ Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) }
func NewUDPGroup(addrs []string) Exchanger      // first successful of N concurrent UDP queries
func NewDoTGroup(addrs []string) Exchanger      // first successful of N concurrent DoT (tcp-tls:853) queries

// Arbitrate runs china + trust concurrently and picks per chnroute.
func Arbitrate(ctx context.Context, q *dns.Msg, china, trust Exchanger, cn *Chnroute, timeout time.Duration) (*dns.Msg, error)
// Rule: wait for china (<=timeout). If china reply has any A ∈ cn → return china reply.
// Else return trust reply (await it). Deterministic — independent of which returns first.
```

- [ ] **Step 1: failing test** for `Arbitrate` using fake Exchangers (return canned `*dns.Msg`), table-driven:
  - china=CN A (1.2.3.4∈cn), trust=foreign A (9.9.9.9) → result = china (1.2.3.4). **And the reverse timing** (fake china that sleeps 200ms, trust instant) → still china (proves not first-response).
  - china=foreign A (8.8.8.8∉cn), trust=foreign A → result = trust.
  - china=error/timeout, trust=foreign → result = trust.
  - china=NODATA (no A), trust=foreign A → result = trust.
- [ ] **Step 2:** FAIL. **Step 3:** implement: launch both via goroutines+channels with `ctx`; read china (or its timeout); decide; if needed await trust. `chinaIsCN` = any A RR in china answer with `cn.Contains`. `NewUDPGroup`/`NewDoTGroup` = fan out `dns.Client{Net:"udp"|"tcp-tls"}` to addrs, return first non-error response (`context`-cancel the losers). **Step 4:** PASS. **Step 5:** commit `feat(dns): upstream groups + deterministic chnroute arbitration`.

## Task 5: Query handler — types + precedence + rewrite (TDD)

**Files:** `handler.go`, `handler_test.go`.

**Interfaces — Consumes:** `*Chnroute`, the three `*DomainSet` (adblock/direct/blacklist), `*Cache`, china+trust `Exchanger`, `gatewayIP net.IP`, `Arbitrate`. **Produces:**
```go
type Handler struct{ /* sets, cache, exchangers, cn, gatewayIP, ttlMin, ttlMax, timeout */ }
func (h *Handler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) // implements dns.Handler
```

- [ ] **Step 1: failing tests** (call `h.resolve(ctx, q)` — a testable inner that returns `*dns.Msg` — and assert):
  - `AAAA` any name → SOA in authority, no answer.
  - `HTTPS`(type 65) → NOERROR, empty answer.
  - adblock-listed name (any qtype incl A) → NXDOMAIN (Rcode).
  - direct-listed name, A, arbitrate→foreign 9.9.9.9 → answer keeps **9.9.9.9** (NO rewrite to gateway).
  - blacklist-listed name, A → answer = gateway IP, no upstream call.
  - default name, A, china=CN 1.2.3.4 → answer 1.2.3.4 (direct, kept).
  - default name, A, arbitrate→foreign 9.9.9.9 → answer = gatewayIP (rewritten).
  - default name, A, mixed china answer {1.2.3.4(cn),9.9.9.9(foreign)} chosen → per-IP rewrite → {1.2.3.4, gatewayIP} deduped.
  - `MX`/`TXT` name → forwarded to trust Exchanger, returned verbatim (use a fake trust that returns a known MX, assert equality).
- [ ] **Step 2:** FAIL. **Step 3:** implement dispatch + precedence (Global Constraints) + per-IP rewrite (`IP∈cn ? IP : gatewayIP`, dedup, drop AAAA) + cache get/put (clamp TTL to [ttlMin,ttlMax]). Non-A/AAAA/65 → `trust.Exchange` verbatim. **Step 4:** PASS. **Step 5:** commit `feat(dns): query handler (types, precedence, rewrite)`.

## Task 6: Config + cert reload + servers + main (wire-up)

**Files:** `config.go`, `cert.go`, `server.go`, `main.go`. (Light tests: `config_test.go` for env parsing.)

**Interfaces:** `config.go`: `type Config struct{...}; func LoadConfig() (Config, error)` reads `DNS_*` env (see spec §6/§13: listeners, cert/key, gateway, china, trust, rules dir, chnroute, cache, ttl, timeout). `cert.go`: `func certGetter(certPath, keyPath string) func(*tls.ClientHelloInfo)(*tls.Certificate,error)` (mtime-cached reload). `server.go`: start DoT (`dns.Server{Net:"tcp-tls"}`), plain (`udp`+`tcp`), debug (127.0.0.1 udp), DoH (`http.Server` TLS, `/dns-query` GET base64url `dns` param + POST `application/dns-message`, decode→`h.resolve`→encode). `main.go`: load config, load sets+chnroute, build Handler, start all listeners, install `SIGHUP` → reload chnroute+sets (swap atomically), block.

- [ ] **Step 1:** `config_test.go`: set env, assert `LoadConfig` parses listeners/lists/ttl; missing required (cert when DoT enabled) → error. Run → FAIL.
- [ ] **Step 2:** implement config.go (+ defaults from spec §13) → test PASS.
- [ ] **Step 3:** implement cert.go, server.go (DoH handler unpacks `*dns.Msg`, calls the same `h.resolve`, packs reply), main.go (SIGHUP reload via atomic.Pointer swap of the rule sets/chnroute used by Handler).
- [ ] **Step 4:** `go build ./... && go vet ./...` clean; `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/5gpn-dns .` succeeds.
- [ ] **Step 5:** commit `feat(dns): config, cert hot-reload, DoT/DoH/plain servers, main`.

## Task 7: CI build/release + ci.yml go test

**Files:** Create `.github/workflows/release.yml`; modify `.github/workflows/ci.yml`.

- [ ] **Step 1:** `release.yml`: on `push: tags: ['dns-v*']` → setup-go → `cd cmd/5gpn-dns && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o 5gpn-dns-linux-amd64 .` → `sha256sum 5gpn-dns-linux-amd64 > checksums.txt` → `softprops/action-gh-release` upload both.
- [ ] **Step 2:** `ci.yml`: add a `go` job (setup-go) running `cd cmd/5gpn-dns && go vet ./... && go test ./...`. Keep the existing bash/python jobs.
- [ ] **Step 3:** Validate workflow YAML parses (`python -c "import yaml,sys; yaml.safe_load(open(f))"` for each). Commit `ci(dns): release workflow + go test in CI`.

## Task 8: Installer — install_5gpndns, services, cert/renew, remove smartdns

**Files:** Modify `install.sh`; create `etc/systemd/5gpn-dns.service`, `etc/5gpn-dns/dns.env.example`; modify `scripts/renew-hook.sh`; delete `etc/smartdns.conf.template`, `scripts/render_smartdns_conf.py`, `scripts/gen_foreign_cidr.py`. Test: `tests/test_5gpndns_policy.sh` (create).

**Interfaces — Consumes:** the released binary `5gpn-dns-linux-amd64`. Produces `/usr/local/bin/5gpn-dns`, `/etc/5gpn/{cert,rules}`, `/etc/5gpn/dns.env`, the unit.

- [ ] **Step 1 (failing grep test)** `tests/test_5gpndns_policy.sh`: assert `install.sh` has `install_5gpndns`, downloads `5gpn-dns-linux-amd64`, `DNS_VERSION`/`DNS_SHA256`; `5gpn-dns.service` exists with `EnvironmentFile=/etc/5gpn/dns.env` + sandbox; renewal hook restarts/HUPs `5gpn-dns` not smartdns; no `install_smartdns`/`render_smartdns_conf`/`gen_foreign_cidr` references remain in `install.sh`/`update-lists.sh`. Run → FAIL.
- [ ] **Step 2:** create `etc/systemd/5gpn-dns.service` (mirror sing-box.service sandbox: `User=root`, `EnvironmentFile=/etc/5gpn/dns.env`, `ExecStart=/usr/local/bin/5gpn-dns`, `ExecReload=/bin/kill -HUP $MAINPID`, `Restart=on-failure`, `NoNewPrivileges`/`ProtectSystem=strict`/`ProtectHome`/`PrivateTmp`/`ProtectKernel*`/`RestrictSUIDSGID`/`RestrictAddressFamilies=AF_INET AF_UNIX`/`ReadOnlyPaths=/etc/5gpn`). `etc/5gpn-dns/dns.env.example` with all `DNS_*` defaults.
- [ ] **Step 3:** `install.sh`: replace `install_singbox`-style `install_smartdns` with `install_5gpndns()` (download `https://github.com/moooyo/5gpn/releases/download/${DNS_VERSION}/5gpn-dns-linux-amd64`, opt-in `DNS_SHA256`, install 0755). In `full_install`: call it; write `/etc/5gpn/dns.env` (from collected vars: cert paths, `DNS_GATEWAY_IP=$GATEWAY_IP`, etc.); install `5gpn-dns.service`; `systemctl disable --now smartdns 2>/dev/null||true` + remove smartdns unit/conf. `start_services`/`show_status`: `smartdns`→`5gpn-dns`. Deploy/renew hook + `renew-hook.sh`: copy certs to `/etc/5gpn/cert` then `systemctl reload 5gpn-dns` (HUP) — keep the pre/post `stop sing-box` for :80 (unchanged; 5gpn-dns binds :853 not :80). Update env summary/help.
- [ ] **Step 4:** `git rm etc/smartdns.conf.template scripts/render_smartdns_conf.py scripts/gen_foreign_cidr.py`.
- [ ] **Step 5:** `bash tests/test_5gpndns_policy.sh` PASS; `bash -n install.sh scripts/renew-hook.sh`. Commit `feat(install): install_5gpndns + unit + cert/renew; drop smartdns`.

## Task 9: Firewall + update-lists + tgbot

**Files:** Modify `scripts/setup-firewall.sh`, `scripts/update-lists.sh`, `tgbot.py`. Delete `tests/test_smartdns_conf_policy.sh`, `tests/test_dns_split_policy.sh`. Extend `tests/test_5gpndns_policy.sh`.

- [ ] **Step 1 (extend failing grep test):** assert firewall opens `udp/tcp 53` + `tcp 8443` (+ keeps 853 and sing-box ports) and rate-limits :53; `update-lists.sh` writes `/etc/5gpn/rules/china_ip_list.txt` and `reload 5gpn-dns` (no render/gen_foreign); installs `5gpn-dns.service` (or install.sh does); `tgbot.py SERVICES` contains `5gpn-dns` (no smartdns). Run → FAIL.
- [ ] **Step 2:** `setup-firewall.sh`: change `tcp_ports="22, 853"` and add `udp dport 53 accept` + `tcp dport 53 ... rate-limit ... accept` + `tcp dport 8443 accept`; apply the same per-source rate meter to :53 new conns (mirror the 853 meter). Install `5gpn-dns.service` instead of (or alongside) the sing-box one — keep sing-box.service install; ADD 5gpn-dns.service install + daemon-reload. Update header comment (DoT-only → DoT/DoH/plain).
- [ ] **Step 3:** `update-lists.sh`: download china_ip_list → `${RULES_DIR:-/etc/5gpn/rules}/china_ip_list.txt` (keep-old-on-failure + min-size guard preserved); drop `gen_foreign_cidr`/`render`/foreign-cidr/china_ip/china-domains; end with `systemctl reload 5gpn-dns 2>/dev/null || true` (non-DRY_RUN).
- [ ] **Step 4:** `tgbot.py`: `SERVICES = ["5gpn-dns", "sing-box"]`; restart-menu button; blacklist add/del path → `/etc/5gpn/rules/blacklist.txt` (or keep proxy-domains.txt as the blacklist source — match install.sh choice); architecture comment.
- [ ] **Step 5:** `git rm tests/test_smartdns_conf_policy.sh tests/test_dns_split_policy.sh`. Run `bash tests/test_5gpndns_policy.sh` PASS + `for t in tests/test_*_policy.sh; do bash "$t"; done` (sing-box ones unaffected) + `python -m py_compile tgbot.py`. Commit `feat: firewall DoT/DoH/plain + update-lists chnroute + tgbot 5gpn-dns`.

## Task 10: Docs + conventions

**Files:** Modify `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `docs/HANDOFF.md`, `tests/integration-smoke.md`.

- [ ] **Step 1:** `CLAUDE.md`: (a) prebuilt-binaries list += `5gpn-dns` (our own CI release, `DNS_SHA256` opt-in; note it is built in CI, not on the box); (b) reverse "control plane = tgbot only / no HTTP API+web UI" → note Phase 3 will add a public API+web UI coexisting with tgbot (mark P2/P3 as planned); (c) reverse "DoT-only inbound" → DoT/DoH/plain53; (d) remove smartdns references, replace with 5gpn-dns. Keep these as deliberate, dated reversals.
- [ ] **Step 2:** `docs/DESIGN.md`: rewrite §2 (architecture: 5gpn-dns brain + sing-box), §4 (four rule sets + deterministic arbitration + all query types), §5 (anti-pollution via trusted DoT + chnroute), §12 add the decision entry (smartdns/chinadns-ng → self-built 5gpn-dns; why; the validation that drove it). `README.md`: rewrite work-principle + features to the 5gpn-dns model + the multi-transport ingress.
- [ ] **Step 3:** `docs/HANDOFF.md`: note the architecture supersession. `tests/integration-smoke.md`: replace the smartdns DNS checks with 5gpn-dns checks (the §11 validation matrix from the spec). 
- [ ] **Step 4:** whole-repo sweep `grep -rnE 'smartdns|chinadns|foreign-cidr|render_smartdns' --include=*.sh --include=*.py --include=*.md` outside dated historical specs → only intentional history remains. Commit `docs: 5gpn-dns architecture; reverse DoT-only/tgbot-only conventions`.

## Task 11: End-to-end validation on test-env

**Files:** none (validation); record results in `tests/integration-smoke.md` + spec.

- [ ] **Step 1:** Cross-compile on dev box: `cd cmd/5gpn-dns && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/5gpn-dns .`; scp to test-env.
- [ ] **Step 2:** Run with env pointing at **mock upstreams** (reuse the validation harness from `.superpowers/sdd/`: a small UDP mock for China + a mock for trusted; or run trusted against a real DoT if reachable). Seed `china_ip_list.txt` (incl 1.0.0.0/8), `blacklist.txt`, `direct.txt`, `adblock.txt`. Self-signed cert for DoT/DoH.
- [ ] **Step 3 (load-bearing — determinism):** `dig +tls @127.0.0.1 -p 853 mixed A` with china-slow/trust-fast AND china-fast/trust-slow → **both return the CN IP**. china=foreign-only → trusted (→ gateway-rewritten). Repeat 3× each.
- [ ] **Step 4 (rules + types):** adblock→NXDOMAIN; direct→real IP unmodified; blacklist→gateway IP; default CN→direct, default foreign→gateway. `AAAA`→SOA; `HTTPS`(65)→empty; `MX`/`TXT`→forwarded verbatim.
- [ ] **Step 5 (transports + cert):** DoT `dig +tls`; DoH `curl --resolve ... 'https://<host>:8443/dns-query?dns=<b64>'`; plain `dig @127.0.0.1 -p 53`; replace cert file → new handshake serves new cert (no restart). `kill -HUP` after editing blacklist → behavior changes.
- [ ] **Step 6 (sandbox):** run under the real unit; confirm `RestrictAddressFamilies` etc. don't break it (add `AF_NETLINK` only if a socket error appears — record). Append results to `tests/integration-smoke.md`; commit `test: validate 5gpn-dns end-to-end on test-env`.

---

## Self-Review

**1. Spec coverage:** §3 pipeline → Tasks 4/5; §4 four rule sets → Tasks 2/5; §6 program (config/cert/servers/main) → Task 6; §13 transports+all-types → Tasks 5/6/9; arbitration determinism → Task 4 (reverse-timing test) + Task 11 Step 3; install/systemd/firewall/update-lists/renew/tgbot → Tasks 8/9; CI build → Task 7; docs+reversals → Task 10; validation → Task 11. Deletions (smartdns template/render/gen_foreign, old tests) → Tasks 8/9. **No gaps.**
**2. Placeholder scan:** Go tasks give signatures + concrete failing tests + implementation rules; shell/systemd tasks give exact directives. The DoH handler + main SIGHUP are described by behavior with exact stdlib mechanisms (net/http, atomic.Pointer) — implementer writes the body under TDD/go vet. No TBD/TODO.
**3. Name consistency:** `Chnroute.Contains`, `DomainSet.Match`, `Cache.Get/Put`, `Exchanger.Exchange`, `Arbitrate`, `Handler.ServeDNS`/`resolve` used consistently across tasks; env names `DNS_*` per spec §6/§13; binary `5gpn-dns`, unit `5gpn-dns.service`, rules dir `/etc/5gpn/rules`, gateway env `DNS_GATEWAY_IP` consistent across Go + install + firewall. **Consistent.**
