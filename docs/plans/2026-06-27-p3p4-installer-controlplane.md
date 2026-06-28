# P3 + P4 — Installer & control plane (build notes)

- Status: authored, NOT executed (no Python/Go/Linux on dev box). Shell scripts pass `bash -n`. Python/HTML reviewed by reading, not run.
- Built by parallel subagents against a shared conventions/API contract; reviewed + committed by the controller.
- **Superseded 2026-06-27 (QUIC dropped):** quic-proxy, UDP 443 and the Go toolchain were removed. HTTP/3 is not proxied — UDP 443 is `reject`ed at the firewall so clients fall back to TCP (sniproxy). Ignore below: the quic-proxy `go build` step, and the `quic_proxy`/`quic-proxy` status/restart keys. Authoritative: DESIGN.md §12 ⑤.

## P3 — installer / orchestration (direct-egress architecture)

| File | Role |
|---|---|
| `install.sh` (~774 lines) | OS detect + deps; smartdns (pkg→binary); build sniproxy (dlundquist) + quic-proxy (`go build`); install config/scripts; domain A-record verify + certbot issue + renew-hook; lowmem detect; runs `update-lists.sh` + `setup-firewall.sh`; iOS profile + socket-activated server; enable smartdns/sniproxy/quic-proxy. Flags: (full) / `--update-lists` / `--status` / `--add-domain` / `--del-domain` / `--ios` / `--setup-api` / `--setup-tgbot`. |
| `quick-install.sh` | one-shot entrypoint: clone repo → `new-5gpn/install.sh`. |
| `src/ios-http.py` | inetd-style socket-activated responder for the iOS `.mobileconfig`. |
| `scripts/gen-ios-profile.sh` | writes the DoT `.mobileconfig` (DNSProtocol=TLS, ServerName=domain, ServerAddresses=[public ip], cellular-only) + index.html. |
| `scripts/renew-hook.sh` | certbot deploy hook → copy certs to `/etc/smartdns/cert/`, restart smartdns (+ api if active). |
| `etc/systemd/new5gpn-iosprofile.{socket,@service}` | socket activation on :8111. |

Key integration note (caught in review): `update-lists.sh` resolves its template via `$HERE/..`, so `install.sh` writes `smartdns.conf.template` to BOTH `/etc/smartdns/` and `/opt/new-5gpn/etc/`.

## P4 — control plane (lean; no exits/rules/AI)

| File | Role |
|---|---|
| `api-server.py` (~490) | stdlib HTTPS API. Bearer-token (`hmac.compare_digest`), per-connection TLS handshake (10s timeout, not in accept loop), permissive CORS. Endpoints: `GET /api/status`, `GET/POST/DELETE /api/domains`, `POST /api/update-lists`, `POST /api/restart`, `GET /api/backup`, `POST /api/restore` (zip-slip-safe, whitelisted arcnames). |
| `tgbot.py` (~612) | stdlib urllib long-poll bot; whitelist by chat id; Chinese inline menu: 状态/代理域名/更新chnroute/续证书/重启服务/日志/iOS二维码; shells out to `install.sh` subcommands. |
| `webui/index.html` (~514) | single-file dashboard (no build/CDN); login (URL+token), status cards, proxy-domain CRUD, chnroute refresh, restart, backup/restore, light/dark, mobile. |

### API contract (shared by api/bot/webui)
`Authorization: Bearer <token>` (from `/etc/new-5gpn/.api_token`), HTTPS on `.api_port` (8443). Status JSON keys use `quic_proxy` (underscore); restart `service` values use `quic-proxy` (hyphen) / `all`.

## Pending Linux verification (unchanged + new)
- `python3 -m py_compile` api-server.py, tgbot.py, ios-http.py; `go build` quic-proxy; full install on a clean box.
- `api-server.py` is internet-facing — verify TLS + auth + firewall (`API_PORT` opened by setup-firewall) on the target before exposing.
