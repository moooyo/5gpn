# Deployment integration smoke test

This checklist covers behavior that unit tests and static policy tests cannot
prove. Run it on a disposable or explicitly designated Linux gateway. The
current architecture is `docs/architecture.md`.

## Prerequisites

- A Linux amd64 host with the current release installed.
- `dig` with DoT support, `curl`, `openssl`, `jq`, and `systemctl`.
- A client with L3 reachability to one address in `DNS_MIHOMO_LISTEN_IPS`.
- A test `BASE_DOMAIN`, valid wildcard certificate (or an explicitly accepted
  debug certificate), and a real `DNS_EGRESS_RESOLVER` rather than the
  `22.22.22.22` sentinel.
- At least two controllable upstreams when testing sequential fallback.

Capture before-state for host-owned facilities. In particular:

```bash
sudo nft list ruleset > /tmp/nft.before
sudo cp -a /etc/5gpn/mihomo/config.yaml /tmp/mihomo-config.before
```

## 1. Static and service health

- [ ] `systemctl is-active 5gpn-dns mihomo` reports both active.
- [ ] `journalctl -u 5gpn-dns -b` contains no bind/config fatal error.
- [ ] `ss -lntup` shows:
  - `:853/tcp` owned by `5gpn-dns`;
  - `127.0.0.1:5353/udp` and `127.0.0.1:5354/tcp+udp`;
  - console `127.0.0.1:443/tcp`, zashboard `127.0.0.2:443/tcp`;
  - mihomo `:80/tcp` and `:443/tcp+udp` on every configured local listen IP.
- [ ] Nothing listens publicly on DNS `:53`, DoH `:8443`, profile `:8111`, or
  old control ports `:9443`/`:18443`.
- [ ] `mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo` succeeds.
- [ ] Every `DNS_MIHOMO_LISTEN_IPS` value appears on a local interface. A
  non-local NAT/public address is rejected by installer validation.

## 2. DNS transport and protocol behavior

Let `DOT=dot.<base>` and `GW=<DNS_GATEWAY_IP>`.

- [ ] `dig +tls @$GW -p 853 example.com A +tls-host=$DOT` completes with a
  certificate valid for `$DOT`.
- [ ] `dig @127.0.0.1 -p 5353 example.com A` works on-box; the same debug port
  is unreachable remotely.
- [ ] Plain `dig @$GW example.com` and `curl -k https://$GW:8443/dns-query`
  fail because those public transports do not exist.
- [ ] AAAA returns the documented IPv4-only negative response.
- [ ] HTTPS/SVCB returns NOERROR/NODATA with the synthetic authority needed to
  keep the client on visible SNI and avoid ipv4hint bypass.
- [ ] An upstream NXDOMAIN/SERVFAIL retains its Rcode and authority data; it is
  not rewritten into NOERROR.

## 3. Ordered DNS policy

Use temporary rules with overlapping matchers and restore the original model
afterward.

- [ ] An exact rule ordered before a conflicting suffix/keyword rule wins.
- [ ] Reordering the two rules and applying changes the winner. This proves
  global first-match order across intents, not merely order within a category.
- [ ] `block` returns NXDOMAIN without probing upstreams.
- [ ] `direct` returns real upstream addresses and never `DNS_GATEWAY_IP`.
- [ ] `proxy` returns `DNS_GATEWAY_IP` for A answers.
- [ ] Each unmatched fallback behaves distinctly:
  - `auto`: china answer only when it contains a chnroute address, otherwise
    trust/gateway steering;
  - `direct`: real address, no gateway rewrite;
  - `gateway`: gateway steering.
- [ ] A cached reply preserves its original verdict/reason/upstream metadata in
  `/api/querylog`; a fallback-direct cache hit is not mislabeled chnroute-cn.
- [ ] `/api/lookup` and `/api/resolve-test` agree with the live query for direct,
  proxy, every fallback, NXDOMAIN, and NODATA.

## 4. Upstream ordering, reload, and subscriptions

- [ ] With two healthy members in one group, only the first configured member
  is queried/adopted.
- [ ] With the first member silent, the next member is attempted before the
  total request deadline. Recovered first member regains precedence.
- [ ] Parent-context cancellation does not open the upstream breaker; a member
  attempt deadline does allow fallback.
- [ ] `PUT /api/upstreams` hot-swaps groups, preserves china ECS, flushes old
  cached answers, reruns the 0x20 probe, and survives daemon restart through
  `upstreams.json`.
- [ ] A subscription hostname resolves through the current trust snapshot.
- [ ] Network failure, redirect to a special-use address, oversized line, or
  parser error retains the previous cache byte-for-byte and schedules backoff.
- [ ] An unchanged fetch does not rewrite cache files or flush response cache.

## 5. Console, profile bootstrap, and authentication

Set `CONSOLE=console.<base>`, `PROFILE=profile.<base>`, and `TOKEN` to the
current API bearer. Direct loopback tests isolate daemon routing:

```bash
curl --resolve "$CONSOLE:443:127.0.0.1" -fsS \
  -H "Authorization: Bearer $TOKEN" "https://$CONSOLE/api/status"
curl --resolve "$PROFILE:443:127.0.0.1" -fsSI \
  "https://$PROFILE/ios/ios-dot.mobileconfig"
```

- [ ] Correct console bearer returns 200; missing/wrong bearer returns 401 and
  never exposes status or mihomo credentials.
- [ ] The profile response is `200` with
  `Content-Type: application/x-apple-aspen-config`, contains no secret, and is
  installable by iOS before DoT is configured.
- [ ] A normal install fails before declaring success when the profile A record
  is missing/wrong. `SKIP_PROFILE_DNS_CHECK=1` is used only in a documented
  CI/staged run, never to hide a broken production bootstrap.
- [ ] `https://$PROFILE/` redirects only to `/ios/`.
- [ ] `$PROFILE/api/status`, SPA paths, and `$PROFILE/proxy/*` return 404/421;
  changing only the Host header while keeping another TLS SNI cannot bypass
  this isolation.
- [ ] The generated download page links to
  `/ios/ios-dot.mobileconfig`; a nonexistent profile path never returns the SPA
  shell as a false-positive `200 text/html`.
- [ ] Production CSP reports no inline script/style or worker/font violation.

## 6. Mihomo controller boundaries

- [ ] `DNS_MIHOMO_CONTROLLER` completes a TLS handshake for `DNS_ZASH_DOMAIN`
  with the zash role certificate; plaintext HTTP or a mismatched SNI fails
  closed.
- [ ] `GET /api/mihomo/health` succeeds only with the console bearer.
- [ ] `POST /api/mihomo/log-ticket` returns a short-lived opaque ticket.
- [ ] That ticket upgrades `/proxy/logs` exactly once; reuse, expiry, missing
  ticket, and arbitrary `/proxy/*` controller paths are rejected.
- [ ] The ticket and controller secret do not appear in logs, error bodies, or
  persisted browser URLs beyond the short-lived WebSocket request.
- [ ] zashboard works through its own allowlisted SNI and `/proxy/` using the
  mihomo secret it presents. The console SNI cannot obtain this broad proxy.
- [ ] A wrong controller secret reports unauthenticated health without clearing
  a valid console token.

## 7. Data-plane forwarding

- [ ] A proxy/foreign DNS answer is exactly `DNS_GATEWAY_IP`, and that address
  is one of the active mihomo listener addresses.
- [ ] HTTPS, HTTP, and QUIC connections steered to the gateway are sniffed and
  forwarded according to the operator mihomo config.
- [ ] Mihomo's re-resolution reaches `127.0.0.1:5354`, then the configured real
  egress resolver; it does not loop back into DoT `:853` or gateway ingress.
- [ ] Direct/CN DNS answers bypass the gateway and connect to the real address.
- [ ] Anti-loop rules reject gateway-self, loopback, private, link-local,
  CGNAT, and other protected destinations before the terminal egress group.
- [ ] The host has no 5gpn TUN/TProxy, WireGuard, fwmark, policy table, or NAT
  forwarding setup.

## 8. Config apply and concurrency

- [ ] Editing only a harmless mihomo field runs validation, atomically replaces
  the file, hot-applies it, and retains mode `0600` in a `0700` directory.
- [ ] Raw config edits that remove `external-controller-tls`, change the zash
  certificate paths, or omit `DNS_ZASH_DOMAIN` return 400 and leave
  disk/runtime unchanged.
- [ ] The dedicated secret-rotation workflow updates the daemon and mihomo
  together; neither side is left locked out.
- [ ] Two concurrent policy Apply calls serialize or return a clear conflict.
  Readers never observe a mixture of generations, and a failed apply leaves the
  prior generation active.
- [ ] Structural subscription sync/persistence failure makes Apply fail; only a
  remote fetch outage may degrade while retaining old cache.

## 9. Install, upgrade, and uninstall safety

- [ ] A normal reinstall and each ordinary `change-*` operation leave the
  operator mihomo config byte-for-byte identical and still validated; they do
  not migrate an older installation to TLS-only controller mode. Older boxes
  need `DNS_ZASH_DOMAIN` configured plus either an explicit `mihomo-reset` or a
  manual TLS-only edit before verified Controller clients connect.
- [ ] Explicit mihomo reset validates a candidate first, creates a backup, and
  atomically installs the seed. A failed candidate leaves the original intact.
- [ ] A deliberately failed service start causes installer failure; it never
  prints a successful completion banner.
- [ ] Debug install writes self-signed material only below
  `/etc/5gpn/debug-cert`; hashes under `/etc/letsencrypt/archive` remain
  unchanged.
- [ ] Pinned quick-install failure does not fall back to a mismatched `main`.
- [ ] Missing/invalid Gum checksum falls back to plain output without installing
  the unverified binary.
- [ ] Compare `nft list ruleset` with `/tmp/nft.before`: install, upgrade, and
  uninstall leave unrelated tables, `/etc/nftables.conf`, and firewall service
  enablement unchanged. Only a uniquely identified legacy 5gpn table may be
  removed.
- [ ] Custom cleanup paths outside 5gpn defaults are rejected unless canonical,
  safe, and marked as 5gpn-owned. `/`, system directories, and unowned paths are
  never recursively deleted.
- [ ] Install an operator-managed `sing-box.service`,
  `/usr/local/bin/sing-box`, and `/usr/local/etc/sing-box`; normal reinstall and
  uninstall preserve all three. A legacy unit is disabled and removed only when
  its unit file explicitly identifies 5gpn ownership; shared binary and config
  paths remain untouched.

## 10. Certificate renewal and recovery

- [ ] The wildcard lineage covers dot/console/zash/profile and renews with
  Cloudflare DNS-01 without stopping mihomo or binding an ACME `:80` listener.
- [ ] `certbot renew --dry-run` succeeds; the deploy hook updates role copies and
  regenerates/signs the iOS profile.
- [ ] New TLS handshakes observe renewed files by mtime without daemon restart.
  The zash wildcard role is shared by the zashboard panel and the mihomo
  controller, so a renewed controller cert becomes visible on the next TLS
  handshake without restarting or reloading mihomo.
- [ ] A temporarily missing/broken cert is visible in status/journal; restoring
  valid files allows the TLS listeners to recover without destroying DNS state.

After the run, restore temporary policy/upstream/config changes and compare the
captured nftables and mihomo files. Record release version, mihomo version, test
date, and any intentionally skipped checkbox with its reason.
