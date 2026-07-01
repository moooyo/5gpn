# 5gpn-dns Phase 3 (API + Web UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Go tasks follow TDD. The Web UI task uses superpowers:frontend-design:frontend-design for the visual work. Steps use checkbox (`- [ ]`).

**Goal:** A separate HTTPS control-plane on `:9443` (token-auth, firewall-restricted) exposing a REST API over the Phase-2 `Controller` + an embedded React/Vite/Tailwind Web console, with `tgbot.py` rewritten as an API client — all coexisting; the DNS resolution plane (DoT/DoH/plain) is untouched.

**Architecture:** A `ControlServer` (`http.Server` on `:9443`, TLS via the existing `certGetter`) routes `/api/*` (bearer-token auth) to thin handlers over `Controller`, and serves the `go:embed`'d SPA at `/`. `Controller` gains `Lookup`. The SPA (built in CI via `vite build`) is a login + dashboard + subscriptions + rules + lookup + stats console. `tgbot.py` calls the same API.

**Tech Stack:** Go 1.26 + stdlib `net/http` (backend). React 18 + Vite + TypeScript + Tailwind (frontend, built in CI — node is a CI-only dep). Python stdlib (tgbot). Go tests in CI + dev box; `vite build`/`tsc` in CI; runtime on test-env.

**Spec:** [docs/superpowers/specs/2026-07-01-5gpn-dns-p3-api-webui-design.md](../specs/2026-07-01-5gpn-dns-p3-api-webui-design.md). Consumes the Phase-2 `Controller` (`docs/.../p2-subscriptions-design.md`).

## Global Constraints

- **Separate listener:** control plane on `DNS_LISTEN_API` (default `:9443`), its own `http.Server` with `TLSConfig.GetCertificate = certGetter(cert,key)` (reuse P1's mtime hot-reloader). NOT merged with DoH `:8443`.
- **Auth:** every `/api/*` request needs `Authorization: Bearer <DNS_API_TOKEN>`; compare with `crypto/subtle.ConstantTimeCompare`; missing/wrong → `401`. The SPA static routes are unauthenticated (they hold no secrets; the browser supplies the token per API call). If `DNS_API_TOKEN` is empty, the control server is DISABLED (don't serve an unauthenticated admin API).
- **Firewall:** `:9443` allowed only from `CLIENT_NET` (never `0.0.0.0/0` by default) — admin plane is not public like DoH.
- **Backend deps:** stdlib `net/http` + `embed` only; still just `miekg/dns` third-party. **Frontend build is CI-only** (node); the box downloads the prebuilt binary (SPA embedded). "No toolchain on the box" holds.
- **Controller is the only backend:** handlers never touch the engine/subscription internals directly; all through `Controller`. `Controller.Lookup` shares a `classify()` with `resolve` (no logic fork).
- **Carried P2 minors to close here:** (1) `SubManager.Add` on a live daemon must (re)start that sub's ticker (not only fetch once); (2) the API `POST /api/subscriptions` returns the `UpdateResult` so the caller sees fetch success/failure; (3) restrict subscription URL scheme to `http`/`https` (no `file://`/SSRF) now that Add is reachable over HTTP.
- **SPA embed:** `//go:embed web/dist` served with SPA fallback to `index.html`. `web/dist` is gitignored (CI builds it); a committed placeholder `web/dist/index.html` keeps `go build` working for dev/CI-go-test before a frontend build.
- **Branch:** direct on `main`. **Platform:** Go tests dev box + CI; `vite build`/`tsc` CI; runtime test-env.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `cmd/5gpn-dns/handler.go` | Modify | extract `classify(name)→(verdict,reason)` shared by `resolve` |
| `cmd/5gpn-dns/controller.go` | Modify | add `Lookup(ctx,name) LookupResult` |
| `cmd/5gpn-dns/subscription.go` | Modify | Add (re)starts ticker on live daemon; Add returns UpdateResult; URL scheme guard |
| `cmd/5gpn-dns/api.go` (+`_test`) | Create | ControlServer: token middleware, routes, JSON handlers over Controller |
| `cmd/5gpn-dns/webui.go` | Create | `//go:embed web/dist` + SPA file server (fallback index.html) |
| `cmd/5gpn-dns/config.go` | Modify | `DNS_LISTEN_API` (:9443), `DNS_API_TOKEN` |
| `cmd/5gpn-dns/main.go`, `server.go` | Modify | build+start/stop the ControlServer with `ctrl`; disabled if no token |
| `web/` (package.json, vite, src/**) | Create | React+Vite+TS+Tailwind SPA |
| `web/dist/index.html` | Create | committed placeholder so go build works pre-frontend-build |
| `install.sh` | Modify | gen `DNS_API_TOKEN`, `DNS_LISTEN_API` in dns.env; print token once |
| `scripts/setup-firewall.sh` | Modify | allow `:9443` from CLIENT_NET only |
| `tgbot.py` | Rewrite | API client (calls :9443 with token) |
| `.github/workflows/release.yml`, `ci.yml` | Modify | node + `vite build` before `go build`; frontend lint/build gate |
| `docs/*`, `CLAUDE.md` | Modify | API+UI now exist (reversal); node CI dep |

---

## Task 1: Controller.Lookup + classify extraction + P2-minor closeouts

**Files:** Modify `handler.go`, `controller.go`, `subscription.go`; tests alongside.

**Interfaces — Produces:**
```go
// handler.go — shared decision, no upstream call for the classification itself
type Verdict struct{ Verdict, Reason string } // verdict: direct|proxy|block ; reason: adblock|force-direct|blacklist|chnroute-cn|chnroute-foreign|default
func (h *Handler) classify(name string, ips []net.IP) Verdict // pure decision given name (+ resolved IPs for the chnroute step)
// controller.go
type LookupResult struct{ Name, Verdict, Reason string; IPs []string; Upstream string }
func (c *Controller) Lookup(ctx context.Context, name string) LookupResult
// subscription.go
func (m *SubManager) Add(s Subscription) (UpdateResult, error) // now returns the fetch result; also starts a ticker if Run is active
```

- [ ] **Step 1 (TDD):** handler test that `classify` returns the right verdict/reason for: adblock name→block/adblock; blacklist→proxy/blacklist; direct→direct/force-direct; a CN IP→direct/chnroute-cn; a foreign IP→proxy/chnroute-foreign. Controller test: `Lookup` on a blacklist name → verdict proxy (no upstream); on a default name with a fake exchanger returning a CN IP → direct + the IP. Subscription test: `Add` returns an `UpdateResult`; a sub with `url:"file:///etc/passwd"` → validation error (scheme guard); a sub added while `Run(ctx)` is active gets a ticker (assert a second fetch happens within a short interval). Run → FAIL.
- [ ] **Step 2:** implement: refactor `resolve` to call `classify` at the decision points (behavior identical — the existing handler tests must still pass); `Controller.Lookup` runs `classify` and, for non-block A, resolves via the engine's exchangers (or `Arbitrate`) to fill IPs + upstream; `SubManager.Add` returns `UpdateOne`'s result and, if a `runCtx` is stored (set in `Run`), launches a ticker for the new sub; add a URL-scheme check (`http`/`https` only) in `validateSubscription`.
- [ ] **Step 3:** `go vet ./... && go test ./...` PASS (existing determinism/handler tests still green). Commit `feat(api): Controller.Lookup + classify extraction; SubManager Add returns result, live reschedule, URL scheme guard`.

## Task 2: Config + ControlServer skeleton + token auth

**Files:** Modify `config.go`; create `api.go`, `webui.go`, `web/dist/index.html`; test `config_test.go`, `api_test.go`.

**Interfaces — Produces:**
```go
// config.go: ListenAPI string (DNS_LISTEN_API default ":9443"); APIToken string (DNS_API_TOKEN, no default)
// api.go
type ControlServer struct{ /* srv *http.Server, ctrl *Controller, token string */ }
func NewControlServer(cfg Config, ctrl *Controller) (*ControlServer, error) // nil,nil if cfg.APIToken=="" (disabled)
func (s *ControlServer) Start() error
func (s *ControlServer) Shutdown(ctx context.Context) error
// auth middleware: bearer token via crypto/subtle; 401 on missing/wrong
```

- [ ] **Step 1 (TDD):** `api_test.go` (httptest): a protected route returns 401 with no/blank/wrong bearer, 200 with the right token (constant-time compare); `webui.go` serves `web/dist/index.html` at `/` and SPA-falls-back unknown non-`/api` paths to index.html. `config_test.go`: `DNS_LISTEN_API` default `:9443`, `DNS_API_TOKEN` read. Run → FAIL.
- [ ] **Step 2:** implement config fields; `web/dist/index.html` placeholder (`<!doctype html><title>5gpn-dns</title>Web UI build pending`); `webui.go` embed + `http.FileServer` with SPA fallback; `api.go` `NewControlServer` (returns nil if no token), `http.ServeMux`, auth middleware wrapping `/api/`, TLS from `certGetter`. 
- [ ] **Step 3:** `go vet && go test && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/5gpn-dns .` pass. Commit `feat(api): control-plane server skeleton (:9443, token auth, embedded SPA)`.

## Task 3: API handlers over Controller

**Files:** Modify `api.go`; test `api_test.go`.

- [ ] **Step 1 (TDD, httptest + a fake/real Controller):** each endpoint (per spec §4): `GET /api/status`, `GET /api/stats`, `GET /api/lookup?domain=`, `GET/POST/PATCH/DELETE /api/subscriptions[/{id}]`, `POST /api/update`, `GET/POST/DELETE /api/rules/{cat}`, `POST /api/reload`. Assert: JSON shapes; `POST /api/subscriptions` returns the UpdateResult; invalid category/domain/cidr/format → 400 JSON `{error}`; all need auth. Run → FAIL.
- [ ] **Step 2:** implement handlers delegating to `Controller` (Subscriptions/AddSubscription/RemoveSubscription/Update/AddRule/RemoveRule/Reload/Stats/Lookup). Validate inputs; JSON-encode; proper status codes. 
- [ ] **Step 3:** `go vet && go test` PASS. Commit `feat(api): REST handlers (status/stats/lookup/subscriptions/rules/update/reload)`.

## Task 4: Wire ControlServer into main/Servers

**Files:** Modify `main.go`, `server.go` (or keep ControlServer separate).

- [ ] **Step 1:** In `main.go`, build `cs, err := NewControlServer(cfg, ctrl)` (ctrl already built); if non-nil `cs.Start()` after DNS servers, and `cs.Shutdown` in the shutdown path. Remove the `_ = ctrl`. Log the listen addr (or "control API disabled: no DNS_API_TOKEN").
- [ ] **Step 2:** `go vet && go test && cross-compile` pass. Commit `feat(api): start control-plane server from main (gated on DNS_API_TOKEN)`.

## Task 5: Web UI (React + Vite + Tailwind)

**Files:** Create `web/` (package.json, vite.config.ts, tailwind config, tsconfig, index.html, `src/**`). **Use superpowers:frontend-design:frontend-design for the visual design.**

- [ ] **Step 1:** scaffold Vite React-TS + Tailwind in `web/` (`npm create vite`, add tailwind). `vite.config.ts` `build.outDir='dist'`, `base='/'`.
- [ ] **Step 2:** a small typed API client (`src/api.ts`) with the token from `localStorage` (Bearer header); 401 → clear token → login view.
- [ ] **Step 3:** views (invoke frontend-design for the look — dark/light, not a template face): **Login** (token field), **Dashboard** (status + stats cards), **Subscriptions** (table CRUD + "Update now" per row / all), **Rules** (four category lists, add/remove), **Lookup** (domain → verdict + IPs + reason), **Stats**. Wire to the API client.
- [ ] **Step 4:** `cd web && npm ci && npm run build` produces `web/dist`; `tsc --noEmit` clean. Copy the built `web/dist` over the placeholder locally so `go build` embeds it; confirm `GOOS=linux ... go build` embeds and the binary serves the UI (smoke: run locally, `curl -k https://127.0.0.1:9443/` returns the built index.html).
- [ ] **Step 5:** Commit `feat(webui): React+Vite+Tailwind control console` (do NOT commit `web/dist` — gitignored; commit `web/` sources + the placeholder index.html only).

## Task 6: install.sh + firewall + token

**Files:** Modify `install.sh`, `scripts/setup-firewall.sh`, `etc/5gpn-dns/dns.env.example`; extend `tests/test_5gpndns_policy.sh`.

- [ ] **Step 1 (grep test):** assert install generates `DNS_API_TOKEN` (openssl rand) into dns.env + `DNS_LISTEN_API`; firewall allows `:9443` from CLIENT_NET only. FAIL.
- [ ] **Step 2:** `install.sh full_install`: `DNS_API_TOKEN="$(openssl rand -hex 32)"` (only if not already in dns.env) → write to dns.env + `DNS_LISTEN_API=:9443`; print the token + the URL once (card). `dns.env.example`: document both. `setup-firewall.sh`: add `ip saddr ${CLIENT_NET} tcp dport 9443 accept` (NOT public).
- [ ] **Step 3:** `bash tests/test_5gpndns_policy.sh` PASS + `bash -n install.sh scripts/setup-firewall.sh`. Commit `feat(install): DNS_API_TOKEN + :9443 control plane (firewall CLIENT_NET only)`.

## Task 7: tgbot → API client

**Files:** Rewrite `tgbot.py`; modify `tests/test_tgbot.py`.

- [ ] **Step 1:** rewrite `tgbot.py` to call the API: read `DNS_API_TOKEN` + `API_BASE` (default `https://127.0.0.1:9443`, `verify=False` for the self/LE cert on localhost — or trust the LE cert via the domain); add-domain → `POST /api/rules/blacklist`, del → `DELETE`, status → `GET /api/status`, refresh → `POST /api/update`, restart service stays `systemctl`. Keep the Telegram admin-gating + DOMAIN_RE. Remove the file-edit/install.sh-subcommand paths.
- [ ] **Step 2:** `python -m py_compile tgbot.py`; update `test_tgbot.py` (mock the HTTP calls); run it. Commit `feat(tgbot): rewrite as 5gpn-dns API client (coexists with Web UI)`.

## Task 8: CI (frontend build + embed)

**Files:** Modify `.github/workflows/release.yml`, `ci.yml`.

- [ ] **Step 1:** `release.yml`: before the Go build, `actions/setup-node` → `cd web && npm ci && npm run build` (produces `web/dist`) → then the existing `go build` (embeds it). `ci.yml`: add a job/step `cd web && npm ci && npm run build && npx tsc --noEmit` (frontend gate) + keep `go vet`/`go test`. 
- [ ] **Step 2:** `python -c "import yaml; yaml.safe_load(open(f))"` both parse. Commit `ci(webui): build frontend before go build; frontend lint/build gate`.

## Task 9: Docs + CLAUDE reversal

**Files:** Modify `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `tests/integration-smoke.md`.

- [ ] **Step 1:** CLAUDE.md: control plane = tgbot **+ public API + Web UI on :9443** (token+firewall-restricted) — mark the P1 "no API/UI" reversal DONE; note node is a CI-only dep (frontend build). DESIGN/README: add the control-plane + UI. integration-smoke: the P3 validation matrix (Task 10). Commit `docs: Phase 3 API + Web UI; CLAUDE reversal (API/UI reintroduced)`.

## Task 10: test-env validation

**Files:** none; record in integration-smoke.md.

- [ ] Cross-compile (with a real `vite build` embedded), scp, run with `DNS_API_TOKEN` set + a self-signed cert. Validate: `curl -k https://127.0.0.1:9443/api/status` 401 without token, 200 with; `/api/lookup?domain=` returns correct verdict; subscriptions CRUD + `/api/update` works (reuse P2 harness); `curl -k https://127.0.0.1:9443/` returns the built UI HTML; firewall `:9443` reachable only from CLIENT_NET (external blocked); tgbot client add/del domain via API reflects in a lookup. Record + commit.

---

## Self-Review
**1. Spec coverage:** §2 decisions → global constraints + T1-T4/T6; §4 endpoints → T3; §5 Lookup/Stats → T1/T3; §6 UI → T5; §7 install/CI/tgbot → T6/T7/T8; §8 tests → T1-T4 (Go) + T5 (frontend build) + T6 (grep) + T10 (test-env); §9 risks (token/firewall/SSRF) → constraints + T1/T6. Carried P2 minors → T1. **No gaps.**
**2. Placeholder scan:** Go tasks give interfaces + failing tests + rules; frontend task names the exact views + build commands (frontend-design does the visual specifics — appropriate, not a placeholder). No TBD.
**3. Type consistency:** `Controller.Lookup`/`LookupResult`, `classify`/`Verdict`, `ControlServer` methods, `DNS_LISTEN_API`/`DNS_API_TOKEN`, endpoint paths consistent across T1-T4/T6/T7. **Consistent.**
