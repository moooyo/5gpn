# P1 Integration Smoke — smartdns DNS brain (Linux, manual)

> These checks CANNOT run on the Windows dev box (no Python, no smartdns).
> Run on a Linux machine with `smartdns` + `python3` installed and a DoT
> client (`kdig` from knot-dnsutils, or `dig +tls`). Record results inline.

## Pre-req setup

- [ ] Install smartdns and python3.
- [ ] Place a cert at `/etc/smartdns/cert/{fullchain.pem,privkey.pem}` (self-signed ok for smoke; client uses `+tls` without strict validation).
- [ ] Copy `5gpn/etc/proxy-domains.txt` → `/etc/smartdns/proxy-domains.txt`.
- [ ] Generate lists + render config + start:
      `SMARTDNS_DIR=/etc/smartdns GATEWAY_IP=<this-host-ip> bash 5gpn/scripts/update-lists.sh`
      `systemctl restart smartdns`
- [ ] First, run the automated suite that the dev box could not:
      `bash 5gpn/tests/run-tests.sh` → expect `ALL TESTS PASSED`.

## Behavioral checks (DoT on :853)

- [ ] **Foreign domain → gateway IP**
      `kdig @<host-ip> +tls www.google.com`
      Expect: answer == `<GATEWAY_IP>` (NOT a real Google IP).

- [ ] **Domestic domain → real China IP**
      `kdig @<host-ip> +tls www.qq.com`
      Expect: a real China IP (in china_ip_list), NOT the gateway IP.

- [ ] **Mixed IP → prefer China (选国内)**
      Pick a domain known to resolve to both CN and foreign IPs; `kdig @<host-ip> +tls <domain>`.
      Expect: a China IP (direct), NOT the gateway IP.
      If it returns the gateway IP instead: tune anti-pollution / preference
      (e.g. add a `nameserver /domain/cn` split or `-whitelist-ip` on the cn
      group) and re-test. Record the tuning applied here:
      - tuning: __________

- [ ] **AAAA disabled**
      `kdig @<host-ip> +tls -t AAAA www.google.com`
      Expect: empty / SOA (no AAAA records).

- [ ] **No loop**
      Inspect `journalctl -u smartdns` during the above.
      Expect: no recursive queries back to this host's own :853 / :5353.

- [ ] **Anti-pollution (constraint 2)**
      Confirm `/etc/smartdns/china-whitelist.conf` (whitelist-ip lines) and
      `/etc/smartdns/bogus-nxdomain.conf` exist and smartdns started cleanly
      (the `conf-file` includes load — a missing include aborts startup).
      Query several known-blocked foreign domains repeatedly; each must
      CONSISTENTLY return the GATEWAY IP, never a fake "domestic-looking" IP.
      If a blocked domain ever resolves direct, the domestic answer slipped the
      whitelist — add it to proxy-domains.txt (self-heal) and record the IP:
      - leaked domain / IP: __________

## Results

- Date / host:
- smartdns version:
- Pass/fail per check:
- Notes:

---

# P2 — Transparent forwarding + direct egress (run after P2 is wired)

Prereqs on the Linux box:
- Build/install dlundquist sniproxy to `/usr/local/sbin/sniproxy`.
- `cp 5gpn/etc/sniproxy.conf /etc/sniproxy.conf`
- `bash 5gpn/scripts/setup-firewall.sh`  (creates pxout user, DoT-only nft, installs sniproxy unit, rejects UDP 443)
- `systemctl enable --now sniproxy`
- Static checks: `bash 5gpn/tests/test_proxy_policy.sh` → `proxy policy: PASS`

Direct egress only — no fwmark / table 100 / tunnels / exit layer.

Checks (client DNS = this gateway's DoT):

- [ ] **TCP/HTTPS end-to-end**: `curl https://<a-foreign-domain>` → smartdns returns
      gateway IP → sniproxy reads SNI → resolves via 22.22.22.22 → egresses out the
      gateway's default route → page loads.
- [ ] **QUIC disabled → TCP fallback**: `curl --http3 https://<foreign-domain>` should fail/fall
      back (UDP 443 is rejected), while plain `curl https://<foreign-domain>` loads via sniproxy.
      Optionally confirm `nc -uvz <gateway> 443` is refused (ICMP port-unreachable, fast fallback).
- [ ] **No loop**: `tcpdump -ni any port 53` shows the proxies' lookups going to
      22.22.22.22, NOT to :853/:5353; no traffic loops back to the gateway.
- [ ] **DoT-only inbound**: external `nc -uvz <gateway> 53` fails (no public 53); DoT :853 works.
- [ ] **No exit layer**: `ip rule` has no fwmark→table-100 rule; `nft list ruleset` has no
      `pgw_exit` table (direct egress only).

Results:
- Pass/fail per check:
- Notes:

---

# Cert auto-renewal (behind DoT-only firewall + sniproxy:80)

The LE cert backs DoT :853; if renewal fails the whole gateway goes dark (no :53
fallback). Renewal uses `--standalone`, so :80 must be free — but the firewall
drops :80 and sniproxy binds :80. The installer ships pre/post renewal-hooks
(open 80 + stop sniproxy → restore) and a Persistent daily timer.

- [ ] **Hooks present**: `ls /etc/letsencrypt/renewal-hooks/{pre,post}/` shows the
      `10-5gpn-open80.sh` / `10-5gpn-close80.sh` scripts (executable).
- [ ] **Timer active**: `systemctl list-timers | grep certbot` shows a renewal timer
      (ours `5gpn-certbot-renew.timer`, or the distro's if it was already enabled).
- [ ] **Dry-run renewal end-to-end** (firewall in drop policy, sniproxy running):
      `certbot renew --dry-run` succeeds. During it, confirm `:80` is briefly open and
      sniproxy is stopped, then restored (`systemctl is-active sniproxy` == active after).
- [ ] **smartdns reloads new cert**: after a real renewal the deploy hook
      (`/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh`) copies certs to
      `/etc/smartdns/cert/` and restarts smartdns; DoT :853 serves the new cert.

Results:
- Pass/fail per check:
- Notes:
