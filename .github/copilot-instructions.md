# Copilot instructions

Follow `AGENTS.md`; `docs/architecture.md` is the only current-architecture
reference. Historical plans and design handoffs are context only.

## Current system

- `5gpn-dns` serves client DoT on `:853`, loopback debug DNS on
  `127.0.0.1:5353/udp`, loopback egress DNS for mihomo on `127.0.0.1:5354`,
  and the authenticated console/API on loopback TLS `:443`.
- New mihomo seeds listen on configured local IPv4 addresses at TCP `:80`,
  `:443`, `:8080`, and `:8443`, plus UDP `:443`. They sniff the original host
  and own all post-steering egress behavior. Existing valid operator configs
  remain byte-preserved until an explicit edit or reset.
- DNS policy is an ordered, first-match block/direct/proxy model in
  `/etc/5gpn/policy.json`. It does not project into mihomo.
- The complete `/etc/5gpn/mihomo/config.yaml` is operator-owned. Preserve it on
  reinstall and `configure`; only explicit reset may replace it after
  validation and atomic publication.
- Optional ingress modules are authenticated, explicit one-shot structural
  edits of that same complete config, never a generated region or second state
  file. The `speedtest-5060` module is default-off and may add TCP/UDP `:5060`
  only when the current listener/sniffer/guard shape is canonical and protected
  by the exact-byte config revision. It also blocks console/zash on that port.
  UDP support means sniffable QUIC only; raw Ookla UDP cannot recover its
  pre-steering target.
- `console.<base>` publicly serves the SPA and `/ios/`; every `/api/*` route
  remains bearer-authenticated. `zash.<base>` is source-allowlisted. There is
  no separate bootstrap hostname. `dot.<base>` is DoT.
- The console uses bearer `/api/*` endpoints. Mihomo logs require a one-use
  ticket minted by `POST /api/mihomo/log-ticket`; the console has no arbitrary
  controller proxy. zashboard uses its separate allowlisted `/proxy/`.

Do not add Xray, sing-box, smartdns, chinadns-ng, Python, DoH/public `:53`,
policy-v2 drafts, structured egress, TUN/TProxy, WireGuard, fwmark, policy
routing, or host firewall ownership. This project is pre-release: accept only
the current config keys, schemas, commands, and callbacks; do not add aliases,
migrations, or teardown for superseded implementations.

## Development commands

From the repository root:

```bash
for t in tests/test_*.sh; do bash "$t"; done

cd cmd/5gpn-dns
gofmt -w .
go vet ./...
go test -race ./...

cd ../../web
npm ci
npm run typecheck
npx vitest run
npm run build
npm run bundle:check
npx playwright test
```

CI downloads mihomo `v1.19.28`, verifies the pinned digest, renders
`etc/mihomo/config.yaml.tmpl`, and runs `mihomo -t`. Keep that job aligned with
the installer's version pin and renderer placeholders.

## Change rules

- Operator-facing shell interaction must use the repository's Gum helpers with
  a noninteractive plain-output fallback. Gate Gum interaction on a TTY and
  guard cancellation under `set -e`.
- Never broadly flush nftables, overwrite host firewall config, or recursively
  delete an unvalidated/unowned path.
- Never place a debug certificate under `/etc/letsencrypt`; use
  `/etc/5gpn/debug-cert`.
- Keep certificate modes exact: `cloudflare`, `http-01`, or `debug`; do not add
  aliases. HTTP-01 uses the three derived service names and its scoped renewal
  helper, while Cloudflare credentials remain DNS-01-only.
- Keep Go's direct dependencies limited to `miekg/dns` and
  `go-telegram/bot` unless a design explicitly changes the policy.
- Preserve sequential member order inside each upstream group and concurrent
  china/trust auto arbitration. Preserve Rcode/authority when rewriting.
- Subscription parse/scan/network failure keeps the old cache. SSRF checks
  apply after every resolution and redirect.
- Keep the DaisyUI/zds cascade layer ordering, CSS-only active sidebar,
  virtualized logs, responsive drawer, and single-flight cancellable polling.
- `web/src/app/navigation.ts` is the route manifest used by the router and E2E;
  add a route there, its loader in `router.tsx`, a `page-<id>` root selector,
  and coverage together.
- Do not commit `web/dist` or weaken bundle/PWA/font budgets just to make a
  regression pass.

When behavior changes, update `docs/architecture.md`,
`etc/5gpn-dns/dns.env.example`, relevant shell policy tests, and
`tests/integration-smoke.md` in the same change.
