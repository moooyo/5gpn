# Frontend Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the React control console out of `cmd/5gpn-dns/web/`, serve it from a disk directory at runtime instead of `go:embed`, and ship it as a separate `dns-v*` release asset.

**Architecture:** The daemon's `:9443` control server serves the SPA from `os.DirFS(cfg.WebDir)` (default `/opt/5gpn/web`), falling back to a built-in placeholder when the directory has no `index.html`. Frontend source lives at repo-root `web/`, builds independently, and is packaged as `5gpn-web-<ver>.tar.gz` uploaded alongside the binary on the same release. `install.sh` downloads and extracts it.

**Tech Stack:** Go 1.26 (`os`/`io/fs`/`net/http`), Vite + React + Tailwind + TypeScript, GitHub Actions, bash (`install.sh`), nftables/systemd unchanged.

## Global Constraints

- Go module is `cmd/5gpn-dns`; module deps stay `miekg/dns` + `go-telegram/bot` only (no new Go deps).
- `DNS_WEB_DIR` default is exactly `/opt/5gpn/web`; env var name exactly `DNS_WEB_DIR`.
- Frontend dir is exactly repo-root `web/`.
- Release asset name is exactly `5gpn-web-<ver>.tar.gz` where `<ver>` is the `dns-v*` tag minus the `dns-` prefix (matches the binary's version stamp).
- systemd sandbox must NOT be loosened — only add one read-only path; address families stay `AF_INET AF_UNIX`.
- No committed built frontend (`web/dist/**` stays gitignored); after this change there is NO committed placeholder either (embed is gone).
- Pure-grep policy tests run under Git Bash on Windows; Go tests run via `go test ./...` from `cmd/5gpn-dns`.

---

### Task 1: Serve the SPA from disk instead of `go:embed`

**Files:**
- Modify: `cmd/5gpn-dns/config.go` (add `WebDir` field + `LoadConfig` line + doc comment)
- Modify: `cmd/5gpn-dns/webui.go` (rewrite: embed → `os.DirFS` + placeholder)
- Modify: `cmd/5gpn-dns/api.go:58` (pass `cfg.WebDir`)
- Modify: `cmd/5gpn-dns/api_test.go:763-764` (comment only)
- Create: `cmd/5gpn-dns/webui_test.go`

**Interfaces:**
- Produces: `newWebUIHandler(webDir string) (http.Handler, error)`; `Config.WebDir string` (env `DNS_WEB_DIR`, default `/opt/5gpn/web`); `placeholderHTML` const.
- Consumes: existing `Config` struct, `envOr(key, def string) string`.

- [ ] **Step 1: Write the failing test** — `cmd/5gpn-dns/webui_test.go`:

```go
package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebUIHandler_ServesRealFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>APP SHELL</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "assets", "app.js"), []byte("console.log(1)"), 0o644); err != nil {
		t.Fatal(err)
	}
	h, err := newWebUIHandler(dir)
	if err != nil {
		t.Fatalf("newWebUIHandler: %v", err)
	}

	// Real asset is served verbatim.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/assets/app.js", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "console.log") {
		t.Errorf("asset: code=%d body=%q", rec.Code, rec.Body.String())
	}

	// Deep link falls back to index.html (SPA shell).
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/dashboard/subs", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "APP SHELL") {
		t.Errorf("fallback: code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestWebUIHandler_PlaceholderWhenEmpty(t *testing.T) {
	h, err := newWebUIHandler(t.TempDir()) // empty dir, no index.html
	if err != nil {
		t.Fatalf("newWebUIHandler: %v", err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200 (placeholder)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "5gpn-dns") {
		t.Errorf("placeholder body = %q", rec.Body.String())
	}
}
```

- [ ] **Step 2: Run it — verify it fails to compile**

Run: `cd cmd/5gpn-dns && go test -run TestWebUIHandler ./...`
Expected: FAIL — `newWebUIHandler` currently takes no arguments (compile error).

- [ ] **Step 3: Rewrite `cmd/5gpn-dns/webui.go`** to the full contents:

```go
package main

import (
	"io/fs"
	"net/http"
	"os"
	"strings"
)

// placeholderHTML is served when the SPA directory has no index.html (the
// frontend has not been deployed yet). The :9443 API keeps working; this just
// tells the operator to install the 5gpn-web release tarball into DNS_WEB_DIR.
const placeholderHTML = `<!doctype html><html><head><meta charset="utf-8"><title>5gpn-dns</title></head>` +
	`<body>5gpn-dns 控制台未部署 — 安装 5gpn-web tarball 到 DNS_WEB_DIR。</body></html>`

// newWebUIHandler serves the SPA from webDir on disk (os.DirFS). Any path with
// no matching static file falls back to index.html (client-side routing on a
// hard refresh / deep link). When webDir has no index.html (frontend not
// deployed) it serves a built-in placeholder rather than a 404/500.
func newWebUIHandler(webDir string) (http.Handler, error) {
	sub := os.DirFS(webDir)
	fileServer := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if pathExists(sub, r.URL.Path) {
			fileServer.ServeHTTP(w, r)
			return
		}
		serveIndex(w, r, sub)
	}), nil
}

// pathExists reports whether the cleaned, slash-trimmed request path names a
// regular file within sub. Directories are not treated as existing files here;
// this only short-circuits the SPA fallback for genuine static assets.
func pathExists(sub fs.FS, urlPath string) bool {
	name := strings.TrimPrefix(urlPath, "/")
	if name == "" {
		name = "."
	}
	info, err := fs.Stat(sub, name)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

// serveIndex serves webDir/index.html (the SPA shell) for any non-asset path,
// or the built-in placeholder when index.html is absent.
func serveIndex(w http.ResponseWriter, r *http.Request, sub fs.FS) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	data, err := fs.ReadFile(sub, "index.html")
	if err != nil {
		_, _ = w.Write([]byte(placeholderHTML))
		return
	}
	_, _ = w.Write(data)
}
```

- [ ] **Step 4: Add `WebDir` to `cmd/5gpn-dns/config.go`.** After the `WWWDir` struct field (`config.go:65`) add:

```go
	WebDir    string // env DNS_WEB_DIR; default /opt/5gpn/web; control-console SPA static root
```

In `LoadConfig` after the `WWWDir` line (`config.go:122`) add:

```go
		WebDir:            envOr("DNS_WEB_DIR", "/opt/5gpn/web"),
```

And in the `LoadConfig` doc-comment env list (near `config.go:100`) add:

```go
//	DNS_WEB_DIR         /opt/5gpn/web (control-console SPA static root)
```

- [ ] **Step 5: Wire `cfg.WebDir` in `cmd/5gpn-dns/api.go:58`.** Change:

```go
	webUI, err := newWebUIHandler()
```
to:
```go
	webUI, err := newWebUIHandler(cfg.WebDir)
```

- [ ] **Step 6: Update the stale comment in `cmd/5gpn-dns/api_test.go:763-764`.** Change:

```go
// TestControlServer_WebUI_ServesIndex confirms the SPA placeholder is served
// at "/" (via the embedded web/dist).
```
to:
```go
// TestControlServer_WebUI_ServesIndex confirms the SPA placeholder is served at
// "/" when no SPA is deployed (WebDir empty in tests → built-in placeholder).
```

- [ ] **Step 7: Run tests — verify pass**

Run: `cd cmd/5gpn-dns && go test ./... 2>&1 | tail -3`
Expected: `ok` — new `webui_test.go` passes; existing `TestControlServer_WebUI_ServesIndex`/`_SPAFallback` still pass (empty `WebDir` → placeholder body contains `5gpn-dns`).

- [ ] **Step 8: Verify `go build` no longer needs the embed dir**

Run: `cd cmd/5gpn-dns && go vet ./... && go build ./...`
Expected: no error (the `//go:embed web/dist` line is gone; `web/dist` is no longer referenced by Go).

- [ ] **Step 9: Commit**

```bash
git add cmd/5gpn-dns/config.go cmd/5gpn-dns/webui.go cmd/5gpn-dns/api.go cmd/5gpn-dns/api_test.go cmd/5gpn-dns/webui_test.go
git commit -m "refactor(webui): serve SPA from DNS_WEB_DIR on disk, drop go:embed"
```

---

### Task 2: Move the frontend to repo-root `web/`

**Files:**
- Move: `cmd/5gpn-dns/web/` → `web/` (git mv)
- Delete: `web/dist/index.html` (committed placeholder — no longer needed)
- Modify: `.gitignore` (swap the `cmd/5gpn-dns/web/**` rules for `web/**`)
- Modify: `web/vite.config.ts` (comment), `web/package.json` (description)

**Interfaces:** none (mechanical move; Go build already independent of `web/` after Task 1).

- [ ] **Step 1: Move the directory**

Run:
```bash
git mv cmd/5gpn-dns/web web
git rm web/dist/index.html
```
Expected: `web/` now at repo root; the committed placeholder is removed.

- [ ] **Step 2: Update `.gitignore`.** Replace lines 25-27:

```
/cmd/5gpn-dns/web/node_modules/
/cmd/5gpn-dns/web/dist/*
!/cmd/5gpn-dns/web/dist/index.html
```
with:
```
/web/node_modules/
/web/dist/
```
(The whole built `dist/` is ignored now — there is no committed placeholder.)

- [ ] **Step 3: Update `web/vite.config.ts` comment** (around lines 4-5). Replace the two comment lines that reference `cmd/5gpn-dns/web/dist` and `//go:embed web/dist` with:

```ts
// Build output (web/dist) is packaged as the 5gpn-web release tarball and
// served by the Go control server from DNS_WEB_DIR on disk (cmd/5gpn-dns/webui.go).
```

- [ ] **Step 4: Update `web/package.json` description.** Change:

```json
  "description": "5gpn-dns control console SPA (embedded into the Go binary via go:embed)",
```
to:
```json
  "description": "5gpn-dns control console SPA (served by the daemon from DNS_WEB_DIR; shipped as the 5gpn-web release tarball)",
```

- [ ] **Step 5: Verify the frontend still builds at its new home**

Run: `cd web && npm ci && npm run build && npm run typecheck`
Expected: `dist/` produced with real `assets/*.js`+`*.css`; typecheck clean.

- [ ] **Step 6: Verify Go build is unaffected + tree clean (dist ignored)**

Run: `cd cmd/5gpn-dns && go build ./... && cd .. && git status --short`
Expected: `go build` OK; `git status` shows only the moved/modified tracked files (no `web/dist/` — it is gitignored).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(web): move frontend to repo-root web/, drop committed dist placeholder"
```

---

### Task 3: systemd unit + dns.env

**Files:**
- Modify: `etc/systemd/5gpn-dns.service` (`ReadOnlyPaths`)
- Modify: `etc/5gpn-dns/dns.env.example` (`DNS_WEB_DIR`)

**Interfaces:** none.

- [ ] **Step 1: Add the SPA dir to `ReadOnlyPaths` in `etc/systemd/5gpn-dns.service`.** Change:

```
ReadOnlyPaths=/etc/5gpn/dns.env -/etc/5gpn/cert
```
to:
```
ReadOnlyPaths=/etc/5gpn/dns.env -/etc/5gpn/cert -/opt/5gpn/web
```
(The `-` prefix tolerates the path being absent before the first `install_web`.)

- [ ] **Step 2: Document `DNS_WEB_DIR` in `etc/5gpn-dns/dns.env.example`.** After the `DNS_LISTEN_API=:9443` line add:

```
# --- Control-console SPA (served from disk by the :9443 server) ---
# Directory install.sh extracts the 5gpn-web release tarball into. An unpopulated
# dir serves a built-in placeholder; the :9443 API works regardless.
DNS_WEB_DIR=/opt/5gpn/web
```

- [ ] **Step 3: Verify the unit still parses (grep policy tests untouched)**

Run: `cd .. ; bash tests/test_hardening_policy.sh && bash tests/test_5gpndns_policy.sh`
Expected: both PASS (sandbox families unchanged; only a read-only path added).

- [ ] **Step 4: Commit**

```bash
git add etc/systemd/5gpn-dns.service etc/5gpn-dns/dns.env.example
git commit -m "feat(systemd): DNS_WEB_DIR read-only path + dns.env doc"
```

---

### Task 4: CI + release — build path + web tarball asset

**Files:**
- Modify: `.github/workflows/ci.yml` (web job path)
- Modify: `.github/workflows/release.yml` (package + upload web tarball)

**Interfaces:** none.

- [ ] **Step 1: Fix the `web` job path in `.github/workflows/ci.yml`.** Change the two occurrences of `cmd/5gpn-dns/web`:
  - `cache-dependency-path: cmd/5gpn-dns/web/package-lock.json` → `cache-dependency-path: web/package-lock.json`
  - the `cd cmd/5gpn-dns/web` line → `cd web`

- [ ] **Step 2: Package + upload the web tarball in `.github/workflows/release.yml`.** Change the "Build web UI" step's `cd cmd/5gpn-dns/web` → `cd web`. Then after the "Build" (Go) step, add a step that tars `web/dist` and add the tarball to the upload list:

```yaml
      - name: Package web UI
        run: |
          VER="${GITHUB_REF_NAME#dns-}"
          tar czf "5gpn-web-${VER}.tar.gz" -C web/dist .
          sha256sum "5gpn-web-${VER}.tar.gz" >> cmd/5gpn-dns/checksums.txt
```

In the existing `Upload release assets` step's `files:` list add:

```yaml
            5gpn-web-*.tar.gz
```

- [ ] **Step 3: Validate YAML**

Run: `python -c "import yaml; [yaml.safe_load(open(f)) for f in ['.github/workflows/ci.yml','.github/workflows/release.yml']]; print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "ci: build web/ at new path; ship 5gpn-web tarball as a release asset"
```

---

### Task 5: install.sh — download + extract the web tarball

**Files:**
- Modify: `install.sh` (add `install_web()`, wire into `full_install`, usage env)
- Modify: `tests/test_install_policy.sh` (assert `install_web` exists)

**Interfaces:**
- Consumes: existing `DNS_VERSION`, `BUILD_DIR`, `gum_spin`, `info/ok/warn/err`.
- Produces: `DNS_WEB_DIR` (default `/opt/5gpn/web`) populated from `5gpn-web-<ver>.tar.gz`.

- [ ] **Step 1: Write the failing policy assertion** in `tests/test_install_policy.sh` (before the final `[ $rc -eq 0 ]`):

```bash
# --- Frontend shipped separately + served from disk (not go:embed) ---
grep -Eq 'install_web'          "$INSTALL" || fail "no install_web() to fetch the 5gpn-web tarball"
grep -Eq '5gpn-web-.*\.tar\.gz' "$INSTALL" || fail "install_web does not fetch the 5gpn-web tarball asset"
grep -Eq 'DNS_WEB_DIR'          "$INSTALL" || fail "DNS_WEB_DIR not wired in install.sh"
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bash tests/test_install_policy.sh`
Expected: FAIL — the three new asserts fail (install.sh has no `install_web` yet).

- [ ] **Step 3: Add `DNS_WEB_DIR` constant near the other paths in `install.sh`** (after `DNS_CERT_DIR="/etc/5gpn/cert"`, ~line 27):

```bash
DNS_WEB_DIR="/opt/5gpn/web"               # control-console SPA (served from disk by :9443)
```

- [ ] **Step 4: Add `install_web()` after `install_5gpndns()`** (mirrors its download/verify pattern):

```bash
# 5gpn-web: control-console SPA tarball from the same moooyo/5gpn release.
# Served from disk by the :9443 control server (DNS_WEB_DIR); no go:embed.
install_web() {
    local ver="${DNS_VERSION:-dns-v0.1.0}"
    local v="${ver#dns-}"
    local url="https://github.com/moooyo/5gpn/releases/download/${ver}/5gpn-web-${v}.tar.gz"
    info "Downloading control-console SPA (5gpn-web ${v})..."
    mkdir -p "$BUILD_DIR" "$DNS_WEB_DIR"
    local tgz="$BUILD_DIR/5gpn-web-${v}.tar.gz"
    gum_spin "Downloading 5gpn-web ${v}…" curl -fsSL "$url" -o "$tgz" \
        || { warn "5gpn-web download failed ($url); the :9443 console will show a placeholder."; return 0; }
    local exp="${WEB_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$tgz" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "5gpn-web sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "5gpn-web sha256 verified."
    fi
    rm -rf "${DNS_WEB_DIR:?}"/*
    tar -xzf "$tgz" -C "$DNS_WEB_DIR" \
        || { warn "5gpn-web extract failed; :9443 console will show a placeholder."; return 0; }
    ok "Control-console SPA installed to ${DNS_WEB_DIR}/."
}
```

Note: a download failure is **non-fatal** (`return 0`) — the daemon serves the placeholder and the API still works; only a sha256 mismatch is fatal.

- [ ] **Step 5: Call `install_web` in `full_install`.** After the `install_5gpndns` call sits inside `install_deps`; add `install_web` right after `install_singbox` (both are prebuilt-artifact fetches):

```bash
    install_singbox
    install_web
```

- [ ] **Step 6: Write `DNS_WEB_DIR` into dns.env.** In `write_dns_env` (the function that writes `/etc/5gpn/dns.env`), add a line alongside the other `DNS_*` env writes:

```bash
DNS_WEB_DIR=${DNS_WEB_DIR}
```
(Match the surrounding heredoc/printf style used for the other vars — grep `write_dns_env` for the exact form and follow it.)

- [ ] **Step 7: Document `WEB_SHA256` + `DNS_WEB_DIR` in `usage()`.** In the "Env overrides" block add:

```
               WEB_SHA256= (pin the 5gpn-web tarball), DNS_WEB_DIR=/opt/5gpn/web,
```

- [ ] **Step 8: Run the policy suite — verify pass + syntax**

Run: `bash -n install.sh && for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL $t"; done; echo done`
Expected: `bash -n` clean; no `FAIL` lines; `done`.

- [ ] **Step 9: Commit**

```bash
git add install.sh tests/test_install_policy.sh
git commit -m "feat(install): fetch + extract the 5gpn-web SPA tarball into DNS_WEB_DIR"
```

---

### Task 6: Docs + CLAUDE.md convention reversal

**Files:**
- Modify: `README.md`, `docs/DESIGN.md`, `tests/integration-smoke.md`, `CLAUDE.md`

**Interfaces:** none.

- [ ] **Step 1: `README.md`** — change the `cmd/5gpn-dns/web/` table row to describe the new home + model:

```
| `web/` | React 控制台前端（独立构建；`npm run build` → `web/dist`，打包成 `5gpn-web-*.tar.gz` release asset；daemon 从 `DNS_WEB_DIR`=/opt/5gpn/web 磁盘 serve） |
```

- [ ] **Step 2: `docs/DESIGN.md`** — replace the `cmd/5gpn-dns/web/` + `go:embed web/dist` sentence (~line 144) with:

```
`web/`（repo 根，React + Vite + Tailwind + TS）。构建产物打包成 `5gpn-web-<ver>.tar.gz`，随 `dns-v*` release 一起发布；daemon 的 :9443 控制服务从磁盘目录 `DNS_WEB_DIR`（默认 /opt/5gpn/web）serve，未部署时显示内置占位。视图不变：Login / Dashboard / Subscriptions / Rules / Lookup / Stats。
```

- [ ] **Step 3: `tests/integration-smoke.md`** — update the two lines referencing `go:embed cmd/5gpn-dns/web/dist` (~142, ~157) to describe serving from `DNS_WEB_DIR` on disk, e.g. the asset check becomes: `curl -sk https://<host-ip>:9443/assets/<hashed-asset>` → `200`, confirming the SPA is served from `/opt/5gpn/web` (not the built-in placeholder).

- [ ] **Step 4: `CLAUDE.md` — record the reversal.** In the control-plane bullet, replace the "built in CI (`npm run build` → `web/dist` → `go:embed`); committed placeholder `web/dist/index.html`; Do NOT commit the built `web/dist`" phrasing with:

```
The frontend (`web/` at repo root) is built independently (`npm run build`), packaged as `5gpn-web-<ver>.tar.gz` and shipped as a second asset on the same `dns-v*` release; the daemon serves it from disk at `DNS_WEB_DIR` (default `/opt/5gpn/web`) via `os.DirFS` — **NOT** `go:embed` (deliberate reversal 2026-07-02: the embed model + committed placeholder are gone). An unpopulated `DNS_WEB_DIR` serves a built-in placeholder; do NOT commit the built `web/dist`.
```

- [ ] **Step 5: Verify docs mention no stale embed path**

Run: `grep -rn "go:embed web/dist\|cmd/5gpn-dns/web" README.md docs/DESIGN.md CLAUDE.md tests/integration-smoke.md || echo "no stale refs"`
Expected: `no stale refs` (or only intentional historical mentions).

- [ ] **Step 6: Commit**

```bash
git add README.md docs/DESIGN.md tests/integration-smoke.md CLAUDE.md
git commit -m "docs: frontend served from DNS_WEB_DIR (reverse the go:embed convention)"
```

---

### Task 7: test-env validation

**Files:** none (validation only).

- [ ] **Step 1: Build the linux-amd64 binary + web tarball locally**

```bash
cd cmd/5gpn-dns && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /tmp/5gpn-dns-linux-amd64 .
cd ../../web && npm ci && npm run build && tar czf /tmp/5gpn-web.tar.gz -C dist .
```

- [ ] **Step 2: Stage on test-env** (Windows `scp.exe`/`ssh.exe`; manual self-signed cert per [[no-selfsigned-in-installer]] — generate by hand, not an installer flag). Put the binary at `/usr/local/bin/5gpn-dns`, extract the web tarball into `/opt/5gpn/web`, write a minimal `dns.env` with `DNS_WEB_DIR=/opt/5gpn/web` + cert paths, start the daemon.

- [ ] **Step 3: Verify serving**

```bash
# real SPA served from disk
curl -sk https://127.0.0.1:9443/ | grep -qi '<div id="root"' && echo SPA-OK
# empty dir → placeholder
rm -rf /opt/5gpn/web/* && curl -sk https://127.0.0.1:9443/ | grep -q '5gpn-dns 控制台未部署' && echo PLACEHOLDER-OK
```
Expected: `SPA-OK` then `PLACEHOLDER-OK`.

- [ ] **Step 4: Tear down** the test-env staging (stop daemon; remove staged files).

---

## Self-Review

**Spec coverage:** ① move to `web/` → Task 2. ② DirFS serve + placeholder → Task 1. ③ config + systemd → Tasks 1, 3. ④ CI + release tarball → Task 4. ⑤ install_web → Task 5. ⑥ cleanup + docs + CLAUDE reversal → Tasks 2, 6. ⑦ tests → Task 1 (webui_test), Task 7 (test-env). All spec sections covered.

**Placeholder scan:** the only "fill in per surrounding style" is Task 5 Step 6 (`write_dns_env` line) — mitigated by naming the exact function to grep and the exact `KEY=VALUE` to add. No `TBD`/`TODO`.

**Type consistency:** `newWebUIHandler(webDir string) (http.Handler, error)` used in Task 1 Step 3 (def), Step 5 (call site), and webui_test.go (Step 1). `Config.WebDir` / env `DNS_WEB_DIR` / default `/opt/5gpn/web` consistent across Tasks 1, 3, 5, 6. Release asset `5gpn-web-<ver>.tar.gz` consistent across Tasks 4, 5, 6, 7.
