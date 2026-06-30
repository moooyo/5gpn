# 5gpn-dns Integration Smoke — DNS brain validation (Linux, manual)

> These checks run on **test-env** (Debian 13, root@10.0.1.20).
> Requires: `5gpn-dns` binary, `dig` (+ `dig +tls` for DoT), `curl` (for DoH), mock upstream capability.
> Use `GATEWAY_IP` = this host's IP for the smoke.

## Pre-req setup

- [ ] Deploy `5gpn-dns` to `/usr/local/bin/5gpn-dns` (CI binary or local cross-compile + scp).
- [ ] Place rules in `/etc/5gpn/rules/`: `adblock.txt`, `direct.txt`, `blacklist.txt`, `china_ip_list.txt`.
- [ ] Place cert at `/etc/5gpn/cert/{fullchain.pem,privkey.pem}` (self-signed ok; DoT client uses `+insecure`).
- [ ] Start 5gpn-dns with env: `DNS_LISTEN_DOT=:853 DNS_LISTEN_DOH=:8443 DNS_LISTEN_PLAIN=:53 DNS_GATEWAY_IP=<this-host-ip> DNS_RULES_DIR=/etc/5gpn/rules /usr/local/bin/5gpn-dns`.
- [ ] Run automated Go unit tests (dev box / CI): `go test ./cmd/5gpn-dns/...` → expect all PASS.
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

---

## Results

- Date / host:
- 5gpn-dns version:
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
