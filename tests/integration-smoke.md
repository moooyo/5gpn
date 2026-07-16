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
- [ ] `journalctl -u mihomo -b` contains no `External controller tls listen error`
  or safe-path rejection after startup.
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

## 5. Public console, iOS bootstrap, and authentication

Set `CONSOLE=console.<base>` and `TOKEN` to the
current API bearer. Direct loopback tests isolate daemon routing:

```bash
curl --resolve "$CONSOLE:443:127.0.0.1" -fsS \
  -H "Authorization: Bearer $TOKEN" "https://$CONSOLE/api/status"
curl --resolve "$CONSOLE:443:127.0.0.1" -fsSI \
  "https://$CONSOLE/ios/ios-dot.mobileconfig"
```

- [ ] Correct console bearer returns 200; missing/wrong bearer returns 401 and
  never exposes status or mihomo credentials.
- [ ] The console profile response is `200` with
  `Content-Type: application/x-apple-aspen-config`, contains no secret, and is
  installable by iOS before DoT is configured.
- [ ] A normal install fails before declaring success when the console A record
  is missing/wrong; exported skip variables cannot bypass the gate.
- [ ] `https://$CONSOLE/` serves the SPA; unauthenticated
  `$CONSOLE/api/status` returns 401.
- [ ] The authenticated console `/setup-guide` route shows separate iOS and
  Android instructions, the exact `DNS_DOMAIN`, a profile QR code, and a direct
  `/ios/ios-dot.mobileconfig` link. Legacy `/ios/` redirects to the guide; a
  nonexistent profile path never returns the SPA shell as a false-positive
  `200 text/html`.
- [ ] Production CSP reports no inline script/style or worker/font violation.

## 6. Mihomo controller boundaries

- [ ] `DNS_MIHOMO_CONTROLLER` completes a TLS handshake for `DNS_ZASH_DOMAIN`
  with the zash role certificate and no earlier safe-path rejection in
  `journalctl -u mihomo -b`; plaintext HTTP or a mismatched SNI fails closed.
- [ ] zashboard REST and WebSocket operations succeed through `/proxy/` while
  the 5gpn-to-mihomo hop is HTTPS.
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
- [ ] Raw config edits that enable `external-controller`, remove
  `external-controller-tls`, or change either required zash certificate path
  return 400 and leave disk/runtime unchanged.
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

- [ ] The wildcard lineage covers dot/console/zash and renews with
  Cloudflare DNS-01 without stopping mihomo or binding an ACME `:80` listener.
- [ ] `certbot renew --dry-run` succeeds; the deploy hook updates role copies and
  regenerates/signs the iOS profile.
- [ ] New TLS handshakes observe renewed files by mtime without daemon restart.
- [ ] After certificate renewal, a new Controller TLS handshake presents the
  renewed certificate without restarting mihomo.
- [ ] A temporarily missing/broken cert is visible in status/journal; restoring
  valid files allows the TLS listeners to recover without destroying DNS state.

## 11. Telegram bot (optional real-network smoke)

Use a disposable Telegram bot token, at least two test administrator accounts,
and a temporary group. Back up `/etc/5gpn/tgbot.json` first and do not paste the
token into recorded command output, screenshots, or issue logs.

- [ ] `5gpn --setup-tgbot` requires a TTY, reports an existing `DNS_TGBOT_FILE` as the active
  source, validates a replacement token through the live control API, and
  atomically leaves a root-only (`0600`) JSON override. It does not claim that a
  caller environment token became active.
- [ ] A malformed or unauthorized token makes both CLI and Web apply fail. The
  previous live bot and the byte-for-byte override remain usable, and neither
  path prints a success message.
- [ ] `GET /api/tgbot` never returns the token. Its lifecycle/health fields agree
  with reality after enable, network failure, recovery, disable, and an
  unexpected polling-loop exit.
- [ ] A token that previously had a webhook is safely returned to long polling
  without dropping pending updates. Commands and inline callback buttons both
  work, proving the explicit `message` + `callback_query` update selection.
- [ ] `/id` reports the numeric user ID. Every status, log, diagnostic, and
  maintenance action is rejected outside an authorized administrator's private
  chat; adding the bot to a group cannot reveal domains, addresses, or journal
  output.
- [ ] Removing an administrator takes effect immediately. A concurrent stale
  token/admin apply cannot later restore the revoked account or replace a newer
  configuration.
- [ ] Menu navigation and refresh work for status, DNS diagnosis, logs,
  upstreams, maintenance, iOS install, and the Web-console link. DNS diagnosis
  agrees with `/api/resolve-test`; policy/subscription/YAML editing is absent.
- [ ] Mihomo restart and certificate renewal require an unexpired one-use
  confirmation. Replaying or double-clicking it cannot start a second job, and
  the final message/audit record contains the real success or failure result.
- [ ] Short logs retain the newest failure lines and paginate without breaking
  Unicode or HTML. Oversized logs arrive as a protected text document. The iOS
  action sends a PNG QR plus a direct
  `console.<base>/ios/ios-dot.mobileconfig` URL button.
- [ ] When direct Telegram access is unavailable, setting a valid proxy through
  the Telegram TUI and letting it restart the daemon restores operation through the
  chosen HTTP/HTTPS CONNECT proxy. Invalid schemes/credentials fail visibly.
  This test must not change `/etc/5gpn/mihomo/config.yaml`; any local mihomo
  HTTP/mixed listener is created and secured explicitly by the operator.
- [ ] With alerts disabled in the TUI, health polling sends no unsolicited messages.
  With it enabled by the TUI, certificate, mihomo, and upstream
  failure/recovery transitions produce protected private alerts to every
  configured admin without repeated unchanged-state spam. Stopping the daemon
  cannot produce a Telegram alert; the configured external heartbeat monitor
  must detect that dead-man's-switch failure.

After the run, restore temporary policy/upstream/config changes and compare the
captured nftables and mihomo files, restore the Telegram override, and revoke
the disposable token. Record release version, mihomo version, test date, and
any intentionally skipped checkbox with its reason.
