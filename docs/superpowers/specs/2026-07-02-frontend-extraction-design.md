# Frontend extraction — standalone build + split deployment — design

- **Date:** 2026-07-02
- **Status:** approved (design), pending spec review → implementation plan
- **Scope:** move the control-console SPA out of `cmd/5gpn-dns/web/`, serve it from
  disk instead of `go:embed`, and ship it as a separate release asset

## Motivation

The React control console currently lives at `cmd/5gpn-dns/web/` and is compiled
into the Go binary via `//go:embed web/dist` (`cmd/5gpn-dns/webui.go`). This
couples the frontend to the Go module: it sits under a `cmd/` command package, a
committed placeholder `web/dist/index.html` is needed to keep `go build` happy,
and any UI change means rebuilding/reshipping the whole binary.

Goal: **maintain, build, and package the frontend independently** of the Go
binary, while keeping everything in the one monorepo and keeping deployment
operator-friendly.

## Decisions (locked)

- **Where:** frontend source moves to repo-root **`web/`** (out of `cmd/`).
- **Deployment model:** **split** — the daemon serves the SPA from a disk
  directory at runtime (no more `go:embed`); install.sh distributes the frontend
  artifact separately.
- **Release:** **one `dns-v*` release, two assets** — the backend binary
  (`5gpn-dns-linux-amd64`) and a frontend tarball (`5gpn-web-<ver>.tar.gz`).
  Versions stay aligned by construction.
- **Serve dir:** `DNS_WEB_DIR`, default **`/opt/5gpn/web`**.

## Non-goals

- Not a separate git repo (stays monorepo).
- Not external static hosting (CDN/Pages) — the daemon still serves the SPA.
- No change to the `:9443` control API, its auth, or the SPA's runtime behavior
  (same-origin, bearer token in localStorage) — only *where the static files
  come from* changes.

## Design

### 1. Directory layout

`git mv cmd/5gpn-dns/web web`. The frontend becomes a standalone project at
repo root `web/` (its own `package.json`, `vite.config.ts`, `tsconfig.json`,
`src/`, …). The Go module (`cmd/5gpn-dns`) no longer contains any frontend files.

### 2. Daemon serve mechanism (`cmd/5gpn-dns/webui.go` rewrite)

Replace `embed.FS` with a runtime disk read:

- `newWebUIHandler(webDir string)` uses `os.DirFS(webDir)` instead of
  `fs.Sub(embeddedWeb, "web/dist")`. The existing SPA deep-link fallback (any
  path with no matching static file → `index.html`) is preserved.
- New config field `WebDir` from env **`DNS_WEB_DIR`** (default `/opt/5gpn/web`).
- **Empty/missing dir:** when `webDir` has no `index.html`, serve a small
  built-in placeholder HTML constant ("控制台未部署 — 安装 5gpn-web") so the
  `:9443` API keeps working and the SPA path returns a clear message rather than
  a 500. The `//go:embed` line and `embeddedWeb` var are removed.
- Benefit: updating the UI is a matter of replacing the on-disk directory; no
  binary rebuild.

### 3. Config + systemd

- `config.go`: add `WebDir` (env `DNS_WEB_DIR`, default `/opt/5gpn/web`).
- `etc/5gpn-dns/dns.env.example`: document `DNS_WEB_DIR=/opt/5gpn/web`.
- `etc/systemd/5gpn-dns.service`: add the web dir to `ReadOnlyPaths` (daemon
  only reads it). Sandbox is **not loosened** — one extra read-only path, address
  families unchanged.

### 4. Build + release

- `.github/workflows/ci.yml` `web` job: change paths `cmd/5gpn-dns/web` → `web`
  (npm ci / build / typecheck otherwise unchanged).
- `.github/workflows/release.yml`: after the SPA build, package it —
  `tar czf 5gpn-web-<ver>.tar.gz -C web/dist .` — and upload it as a **second
  asset** on the `dns-v*` release (alongside the binary + checksums). The Go
  build no longer needs the frontend, so ordering between the two is irrelevant.

### 5. install.sh

- New `install_web()`, mirroring `install_5gpndns()`'s download/verify/install
  pattern: download `5gpn-web-<DNS_VERSION>.tar.gz` from the release, optional
  sha256 pin (`WEB_SHA256`), extract into `DNS_WEB_DIR` (`/opt/5gpn/web`).
- `full_install` calls it. Re-running install refreshes the UI in place.
- `DNS_WEB_DIR` is written into `dns.env` alongside the other listener/config env.

### 6. Cleanup + docs

- Delete the committed placeholder `cmd/5gpn-dns/web/dist/index.html` (the embed
  is gone, so `go build` no longer needs it).
- Update `.gitignore` (drop the `cmd/5gpn-dns/web/**` rules, add `web/**` ones),
  `web/vite.config.ts` comment, `web/package.json` description, README.md,
  docs/DESIGN.md, tests/integration-smoke.md.
- **CLAUDE.md:** this reverses the standing "frontend is built in CI → `web/dist`
  → `go:embed`; committed placeholder index.html; do NOT commit built web/dist"
  convention. Record the reversal: the SPA is now served from `DNS_WEB_DIR` on
  disk, shipped as a separate `5gpn-web-*.tar.gz` release asset; there is no
  embed and no committed placeholder.

### 7. Testing

- New `cmd/5gpn-dns/webui_test.go`: with a temp dir as `webDir`, assert (a) a
  real static file is served, (b) a deep-link path falls back to `index.html`,
  (c) an empty/missing dir serves the built-in placeholder (not a 500).
- `api_test.go`: the test that asserts the embedded SPA is served at `/` moves to
  the DirFS model (point it at a temp `webDir`).
- Full `go test ./...` + policy suite stay green.
- test-env: re-run install (manual self-signed cert per
  [[no-selfsigned-in-installer]] — generate the cert by hand, not via an
  installer flag) and confirm `:9443` serves the real SPA from `/opt/5gpn/web`,
  and that an unpopulated dir shows the placeholder.

## Migration order (implementation plan will detail)

1. `git mv cmd/5gpn-dns/web web`; fix intra-project paths (vite base, tsconfig).
2. Rewrite `webui.go` (DirFS + placeholder) + `config.go` (`DNS_WEB_DIR`).
3. Update systemd unit + dns.env.example.
4. Update CI (`web` job path) + release (web tarball asset).
5. Add `install_web()` to install.sh; wire into full_install.
6. Delete placeholder; update .gitignore + all docs + CLAUDE.md reversal.
7. Tests (webui_test.go, api_test.go), then test-env validation.

## Risks

- **Frontend not deployed on a box:** mitigated by the built-in placeholder — the
  API still works; the SPA path just says "not installed".
- **Version skew:** avoided by shipping both assets on the same `dns-v*` release;
  install.sh pulls both at the same `DNS_VERSION`.
- **Sandbox:** adding a read-only path only; no family/capability change.
- **Docs drift:** CLAUDE.md/DESIGN/README all describe the embed model today and
  must be updated together (they are load-bearing for future work).
