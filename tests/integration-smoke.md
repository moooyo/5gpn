# 5gpn-dns Integration Smoke — DNS brain validation (Linux, manual)

> These checks run on **test-env** (Debian 13, root@10.0.1.20).
> Requires: `5gpn-dns` binary, `dig` (+ `dig +tls` for DoT), `curl` (for DoH), mock upstream capability.
> Use `GATEWAY_IP` = this host's IP for the smoke.

## Pre-req setup

- [ ] Deploy `5gpn-dns` to `/usr/local/bin/5gpn-dns` (CI binary or local cross-compile + scp).
- [ ] Place rules in `/etc/5gpn/rules/`: `adblock.txt`, `direct.txt`, `blacklist.txt`, `china_ip_list.txt` (manual files; §I below adds subscription caches under `<category>/*.txt`).
- [ ] (Optional, for §I) Place `/etc/5gpn/subscriptions.json` with at least one subscription pointing at a local test HTTP server.
- [ ] Place cert at `/etc/5gpn/cert/{fullchain.pem,privkey.pem}` (self-signed ok; DoT client uses `+insecure`).
- [ ] Start 5gpn-dns with env: `DNS_LISTEN_DOT=:853 DNS_LISTEN_DOH=:8443 DNS_LISTEN_PLAIN=:53 DNS_GATEWAY_IP=<this-host-ip> DNS_RULES_DIR=/etc/5gpn/rules DNS_SUBSCRIPTIONS=/etc/5gpn/subscriptions.json /usr/local/bin/5gpn-dns`.
- [ ] Run automated Go unit tests (dev box / CI): `go test ./cmd/5gpn-dns/...` → expect all PASS (includes subscription/controller tests).
- [ ] Run grep policy suite: `bash tests/run-tests.sh` → expect `ALL TESTS PASSED`.

---

## §11 Validation Matrix

### A. Deterministic chnroute arbitration (highest-priority risk item)

- [ ] **Prefer-CN — timing 1: China reply arrives first**
      Mock: China upstream returns a CN IP; trusted DoT returns a foreign IP; China arrives first.
      `dig @<host-ip> +short <domain>` → must return CN IP (direct), NOT foreign IP.
      Repeat 5× to confirm stability.

- [ ] **Prefer-CN — timing 2: trusted DoT arrives first**
      Mock: same IPs, but trusted DoT is faster.
      `dig @<host-ip> +short <domain>` → must still return CN IP (deterministic, not racing).

- [ ] **No CN IP from China upstream → use trusted**
      Mock: China upstream returns only foreign IPs.
      `dig @<host-ip> +short <domain>` → returns the trusted answer (rewritten to gateway IP).

- [ ] **China upstream timeout → fall back to trusted**
      Mock: China upstream hangs until `DNS_QUERY_TIMEOUT`.
      `dig @<host-ip> +short <domain>` → returns trusted answer within timeout + margin.

### B. Four rule categories

- [ ] **adblock → NXDOMAIN**
      Add a domain to `adblock.txt`; `dig @<host-ip> +short <domain>` → NXDOMAIN (rcode 3).
      Also test via DoT and DoH.

- [ ] **force-direct → real IP, no rewrite**
      Add a domain with known foreign IPs to `direct.txt`; `dig @<host-ip> +short <domain>`
      → real foreign IP returned (NOT the gateway IP). Confirm no ip-alias rewrite.

- [ ] **blacklist → gateway IP**
      Add a domain to `blacklist.txt`; `dig @<host-ip> +short <domain>` → `<GATEWAY_IP>`.
      No actual DNS resolution should occur (address return, not upstream query).

- [ ] **Default chnroute: CN IP → direct; foreign → gateway IP**
      Domain whose real IPs are in chnroute: result is CN IP.
      Domain whose real IPs are all foreign: result is `<GATEWAY_IP>`.

- [ ] **force-direct beats blacklist (conflict)**
      Add same domain to both `direct.txt` and `blacklist.txt`.
      `dig @<host-ip> +short <domain>` → real IP returned (force-direct wins), NOT gateway IP.
      Confirm log entry for the conflict.

### C. Transport: DoT / DoH / plain :53

- [ ] **DoT :853** — `dig @<host-ip> -p 853 +tls +insecure www.example.com` → valid answer.

- [ ] **DoH :8443** — `curl -s "https://<host-ip>:8443/dns-query?dns=$(echo -n <base64url-query>)" -H "Accept: application/dns-message" -k` returns a DNS response (or use a DoH client). Alternatively: `kdig @<host-ip>:8443 +https www.example.com`.

- [ ] **Plain DNS :53** — `dig @<host-ip> www.example.com` → valid answer.

- [ ] **Rate limit on :53** — flood `dig @<host-ip>` rapidly from one source; confirm rate limiter kicks in (REFUSED or drop; check logs). Other sources still served.

### D. Query type handling

- [ ] **AAAA → SOA** — `dig @<host-ip> +tls -t AAAA www.google.com` → SOA (no AAAA records).

- [ ] **HTTPS(65) → empty NOERROR** — `dig @<host-ip> +tls -t HTTPS www.google.com` → empty answer section, NOERROR.

- [ ] **MX forwarded verbatim** — `dig @<host-ip> +tls -t MX gmail.com` → real MX records (forwarded to trusted DoT, not rewritten).

- [ ] **TXT forwarded verbatim** — `dig @<host-ip> +tls -t TXT google.com` → real TXT records.

- [ ] **PTR forwarded verbatim** — `dig @<host-ip> +tls -t PTR <some-reverse>` → forwarded, not rewritten.

### E. Certificate hot-reload

- [ ] **Hot-reload without restart** — replace `/etc/5gpn/cert/fullchain.pem` + `privkey.pem` with a new self-signed cert. Send `kill -HUP $(pidof 5gpn-dns)`. Make a new DoT connection: confirm new cert is served (check fingerprint / serial). 5gpn-dns process must not restart.

### F. SIGHUP rule reload

- [ ] **SIGHUP reloads rules** — add a new domain to `blacklist.txt`. Send `kill -HUP $(pidof 5gpn-dns)`. Query the new domain → gateway IP returned (new rule active without restart).

### G. Systemd sandbox (AF / privilege checks)

- [ ] **NoNewPrivileges** — `systemctl show 5gpn-dns -p NoNewPrivileges` → `yes`.
- [ ] **ProtectSystem** — `systemctl show 5gpn-dns -p ProtectSystem` → `strict`.
- [ ] **RestrictAddressFamilies** — `systemctl show 5gpn-dns -p RestrictAddressFamilies` → includes `AF_INET AF_UNIX`.
- [ ] **Service starts cleanly** — `systemctl is-active 5gpn-dns` → `active` after sandbox constraints applied (no permission denials in journal).

### H. Anti-pollution baseline

- [ ] **Trusted DoT resolves correctly** — known-blocked foreign domains consistently return gateway IP, never a fake "domestic-looking" IP.
- [ ] **china_ip_list.txt present** — `ls -l /etc/5gpn/rules/china_ip_list.txt` → exists and non-empty. `update-lists.sh` refreshes it cleanly; old table retained on network failure.

### I. Phase 2 — Subscription manager (in-process fetch/parse/cache)

> Requires a local `httptest`-style server (or any HTTP server you control) serving a rule-list body, and `/etc/5gpn/subscriptions.json` pointing a subscription at it.

- [ ] **Subscription cache generated from a URL → rule effective**
      Configure a subscription (e.g. `category: "blacklist"`, `format: "plain"`) pointing at a local HTTP server serving one test domain.
      Start/reload `5gpn-dns` → confirm `/etc/5gpn/rules/blacklist/<name>.txt` is created with the parsed domain.
      `dig @<host-ip> +short <that-domain>` → gateway IP (blacklist rule now effective, merged with any manual `blacklist.txt`).

- [ ] **Change served body → update → hot-reload**
      Change the HTTP server's response body (add/remove a domain), then trigger an update: either wait for the subscription's `interval` tick, or send an on-demand update (SIGHUP after cache refresh, or restart the fetch cycle per test harness).
      Confirm the cache file content changes and the new/removed domain's resolution behavior flips accordingly — **without restarting the `5gpn-dns` process**.

- [ ] **Offline / fetch failure → keep old cache**
      With an existing good cache present, point the subscription at an unreachable URL (or stop the test HTTP server) and force a fetch.
      Confirm the cache file under `/etc/5gpn/rules/<category>/<name>.txt` is **unchanged** (old cache retained, not cleared or truncated) and the previously-loaded rule remains effective. Also verify: a response that parses to too few entries (below the category's floor guard) is treated the same as a failure (old cache kept).

- [ ] **Sandbox `ReadWritePaths`/`ReadOnlyPaths` match the current model**
      `systemctl show 5gpn-dns -p ReadWritePaths` → includes `/etc/5gpn` (the whole conf dir, not just `/etc/5gpn/rules` — this changed under Phase 3 so the API can atomically rewrite `subscriptions.json`, which needs the *directory* writable).
      `systemctl show 5gpn-dns -p ReadOnlyPaths` → includes `/etc/5gpn/dns.env` (and `-/etc/5gpn/cert` if present) — these two are re-protected read-only carve-outs so the resolver can never rewrite its own token or TLS material.
      Confirm both hold at once: the subscription manager can create/update files under `/etc/5gpn/rules/<category>/`, AND the control-plane API can rewrite `/etc/5gpn/subscriptions.json`, while `/etc/5gpn/dns.env` and `/etc/5gpn/cert/*` stay unwritable (no permission-denied in the journal for the former; a write attempt against the latter should fail).

- [ ] **`update-lists.sh` is now reload-only** — running `scripts/update-lists.sh` performs no network fetch itself; it only triggers `systemctl reload 5gpn-dns` (confirm via strace/journal: no outbound HTTP from the script, only from the `5gpn-dns` process's own subscription manager).

---

## Results

- Date / host:
- 5gpn-dns version:
- Pass/fail per check:
- Notes:

---

## §J Phase 3 — 控制面 API + Web UI

> Covers `cmd/5gpn-dns/api.go` (bearer-token HTTPS REST API on `:9443`, over the `Controller` facade) and the React SPA (`web/`, served from disk at `DNS_WEB_DIR`, default `/opt/5gpn/web`).

- [ ] **Unauthenticated request rejected, bearer token accepted**
      `curl -sk -o /dev/null -w '%{http_code}' https://<host-ip>:9443/api/status` → `401` (no `Authorization` header).
      `curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DNS_API_TOKEN" https://<host-ip>:9443/api/status` → `200`.

- [ ] **Empty `DNS_API_TOKEN` ⇒ control plane not served at all**
      Restart `5gpn-dns` with `DNS_API_TOKEN=` (empty). Confirm `:9443` does not accept connections (or the API routes are absent) — the control plane must never be served unauthenticated.

- [ ] **Firewall gates `:9443` to CLIENT_NET**
      From a CLIENT_NET source: `curl -sk https://<host-ip>:9443/` succeeds (connection accepted).
      From a non-CLIENT_NET source: connection to `:9443` is dropped/rejected by `nft` (confirm via `nft list ruleset` showing the `ip saddr ${CLIENT_NET} tcp dport 9443 accept` rule, and no broader accept for 9443).

- [ ] **SPA served from disk at `/`**
      `curl -sk https://<host-ip>:9443/` → `200`, HTML body (the React shell).
      `curl -sk https://<host-ip>:9443/assets/<hashed-asset>` → `200`, real JS/CSS asset — confirms the SPA is served from `/opt/5gpn/web` (`DNS_WEB_DIR`), not the built-in placeholder.

- [ ] **Rules + subscriptions CRUD, `/api/lookup`, `/api/reload` roundtrip**
      Through the authenticated API: add/remove a rule-list entry, add/remove a subscription, issue a test `/api/lookup` for a known domain, and trigger `/api/reload` — each call returns success and the effect is observable (new rule active, subscription present in a subsequent list call, reload doesn't error).

- [ ] **Subscription CRUD persists under the systemd sandbox**
      This is the regression the `ReadWritePaths=/etc/5gpn` sandbox fix (§I above) addresses — a bare-process run (no systemd unit) wouldn't catch it.
      Run this check specifically **under the systemd-managed service** (`systemctl start 5gpn-dns`, not a manual foreground run): create a subscription via the API, then `systemctl restart 5gpn-dns` (or just re-read `/etc/5gpn/subscriptions.json` on disk) and confirm the new subscription is actually persisted to disk — no permission-denied in the journal from the API's atomic temp-create+rename.

- [ ] **In-daemon Telegram bot responds to an authorized admin**
      The bot is an in-process goroutine of `5gpn-dns` now (configured via `TGBOT_TOKEN` / `TGBOT_ADMINS` in `/etc/5gpn/dns.env`; empty token ⇒ bot disabled). Run `install.sh --setup-tgbot` (or set the two keys manually) and `systemctl restart 5gpn-dns`, then from an admin ID issue a bot command that touches state (e.g. status or add/del forced-proxy domain) and confirm it succeeds — i.e. the daemon picked up the token/admins from dns.env and the bot drives the Controller facade directly (no loopback HTTP hop).

Results:
- Pass/fail per check:
- Notes:

---

# P2 — Transparent forwarding + direct egress (run after P2 is wired)

Prereqs on the Linux box:
- Install prebuilt sing-box to `/usr/local/bin/sing-box` (e.g. via `install_singbox()` in `install.sh`).
- `cp 5gpn/etc/sing-box/config.json /usr/local/etc/sing-box/config.json`
- `bash 5gpn/scripts/setup-firewall.sh`  (creates nft rules: 53/853/8443 + sing-box ports, :53 rate-limit; installs sing-box unit)
- `systemctl enable --now sing-box`
- Static checks: `bash 5gpn/tests/test_proxy_policy.sh` → `proxy policy: PASS`

Direct egress only — no fwmark / table 100 / tunnels / exit layer.

Checks (client DNS = this gateway):

- [ ] **TCP/HTTPS end-to-end**: `curl https://<a-foreign-domain>` → 5gpn-dns returns gateway IP → sing-box direct inbound sniff tls → resolves via 22.22.22.22 → egresses out the gateway's default route → page loads.
- [ ] **QUIC proxied**: `curl --http3 https://<foreign-domain>` should succeed via sing-box (UDP 443 accepted, sing-box sniff quic takes the SNI and direct-egresses).
- [ ] **No loop**: `tcpdump -ni any port 53` shows sing-box's lookups going to 22.22.22.22, NOT to :853/:8443/:5353; no traffic loops back to the gateway.
- [ ] **Multi-transport inbound**: external queries on :53, :853, :8443 all reach 5gpn-dns and return correct answers.
- [ ] **No exit layer**: `ip rule` has no fwmark→table-100 rule; `nft list ruleset` has no `pgw_exit` table (direct egress only).

Results:
- Pass/fail per check:
- Notes:

---

# Cert auto-renewal (behind firewall + sing-box:80)

The LE cert backs DoT :853 and DoH :8443; if renewal fails the gateway loses TLS. Renewal uses `--standalone`, so :80 must be free — but the firewall drops :80 and sing-box binds :80. The installer ships pre/post renewal-hooks (open 80 + stop sing-box → restore) and a Persistent daily timer. After renewal, `renew-hook.sh` copies certs to `/etc/5gpn/cert/` and sends `kill -HUP` to 5gpn-dns (hot-reload, no restart needed).

- [ ] **Hooks present**: `ls /etc/letsencrypt/renewal-hooks/{pre,post}/` shows the `10-5gpn-open80.sh` / `10-5gpn-close80.sh` scripts (executable).
- [ ] **Timer active**: `systemctl list-timers | grep certbot` shows a renewal timer.
- [ ] **Dry-run renewal end-to-end** (firewall in drop policy, sing-box running): `certbot renew --dry-run` succeeds.
- [ ] **5gpn-dns hot-reloads new cert**: after a real renewal the deploy hook copies certs to `/etc/5gpn/cert/` and sends HUP; DoT :853 and DoH :8443 serve the new cert without service restart.

Results:
- Pass/fail per check:
- Notes:
