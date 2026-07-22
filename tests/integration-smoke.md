# Deployment integration smoke test

This checklist covers behavior that unit tests and static policy tests cannot
prove. Run it on a disposable or explicitly designated Linux gateway. The
current architecture is `docs/architecture.md`.

## Prerequisites

- A Linux amd64 host with the current release installed.
- `dig` with DoT support, `curl`, `openssl`, `jq`, and `systemctl`.
- A client with L3 reachability to one address in `DNS_MIHOMO_LISTEN_IPS`.
- A test `BASE_DOMAIN`, a certificate matching the selected `CERT_MODE`
  (`cloudflare`, `http-01`, or an explicitly accepted `debug` certificate), and
  reachable China and trust upstream groups (operational defaults are
  `223.5.5.5` and `22.22.22.22`).
- At least two controllable upstreams when testing sequential fallback.
- For cross-channel upgrade acceptance, use an immutable pre-v5 deployment
  (`0.0.13`, `0.0.19`, or an equivalent `test-env`/`kfchost` snapshot) plus a
  locally built release bundle stamped with the exact beta candidate tag. Do
  not substitute the latest published beta unless it actually contains the
  candidate revision under test.
- Preserve active `dns.env`, interception v4, and mihomo files before any
  mutation, then retain a separate clean post-disable v4/mihomo baseline. The
  raw environment containing retired `DNS_EGRESS_RESOLVER` and the v4
  document must each fail with the actionable pre-v5 repair message. Remove only
  that exact environment key only after the old v4 control plane has disabled
  MITM and removed its managed rules. Use the documented fixed `jq` projection
  to preserve listener/SOCKS/TLS/upstream/protocol infrastructure in disabled
  empty v5, validate it with the verified current sidecar and require the current
  DNS routing checker to report `ready` against clean mihomo, atomically publish it,
  and re-import extensions. Never accept randomized credentials against the
  preserved mihomo file or represent the rebuild as an automatic migration.

Capture before-state for host-owned facilities. In particular:

```bash
sudo nft list ruleset > /tmp/nft.before
sudo cp -a /etc/5gpn/mihomo/config.yaml /tmp/mihomo-config.before
```

## 1. Static and service health

- [ ] `systemctl is-active 5gpn-dns mihomo` reports both active.
- [ ] `systemctl show -p User -p Group -p SupplementaryGroups 5gpn-dns`
  reports `gpn-dns`, `gpn-dns`, and exactly `mihomo`; mihomo
  reports its dedicated `mihomo` user/group.
- [ ] `journalctl -u 5gpn-dns -b` contains no bind/config fatal error.
- [ ] `journalctl -u mihomo -b` contains no `External controller tls listen error`
  or safe-path rejection after startup.
- [ ] `runuser -u gpn-dns -- journalctl -n 1 --no-pager` is denied; the daemon
  has no general host-journal permission. Starting each fixed exporter through
  the Bot produces a root-owned, `gpn-dns`-readable `0640` file below
  `/run/5gpn-journal`, bounded to 256 KiB and containing the requested unit's
  newest 50 lines.
- [ ] Evaluate the installed polkit rule with a `gpn-dns` subject. It authorizes
  only `org.freedesktop.systemd1.manage-units` details
  `mihomo.service`/`restart`, `5gpn-certbot-renew.service`/`start`, and the two
  exact `5gpn-journal@{5gpn-dns,mihomo}.service`/`start` instances; changing
  any unit or verb is denied. Verify with `pkcheck` before exercising the Bot.
- [ ] `ss -lntup` shows:
  - `:853/tcp` owned by `5gpn-dns`;
  - `127.0.0.1:5353/udp` and `127.0.0.1:5354/tcp+udp`;
  - console `127.0.0.1:443/tcp`, zashboard `127.0.0.2:443/tcp`;
  - mihomo TCP `:80`, `:443`, `:5060`, `:8080`, and `:8443`, plus UDP `:443`
    and `:5060`, on every
    configured local listen IP when testing a fresh or explicitly reset seed.
- [ ] Nothing exposes public DNS `:53`, a DoH handler, or a standalone profile
  port. TCP `:8443` is mihomo application ingress, not DoH.
- [ ] `mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo` succeeds.
- [ ] Every `DNS_MIHOMO_LISTEN_IPS` value appears on a local interface. A
  non-local NAT/public address is rejected by installer validation.

## 2. DNS transport and protocol behavior

Let `DOT=dot.<base>` and `GW=<DNS_GATEWAY_IP>`.

- [ ] `dig +tls @$GW -p 853 example.com A +tls-host=$DOT` completes with a
  certificate valid for `$DOT`.
- [ ] `dig @127.0.0.1 -p 5353 example.com A` works on-box; the same debug port
  is unreachable remotely.
- [ ] Plain `dig @$GW example.com` fails because public plain DNS does not
  exist. `curl -k https://$GW:8443/dns-query` must not return a valid DoH
  response; TCP `:8443` is an application-forwarding listener without a DoH
  handler.
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
- [ ] `/api/resolve-test` agrees with the live query for direct, proxy, every
  fallback, NXDOMAIN, and NODATA.

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
  Android instructions, the derived `dot.<DNS_BASE_DOMAIN>` identity, a profile
  QR code, and a direct `/ios/ios-dot.mobileconfig` link. Public `/ios/`
  redirects to the guide; a
  nonexistent profile path never returns the SPA shell as a false-positive
  `200 text/html`.
- [ ] Production CSP reports no inline script/style or worker/font violation.

## 6. Mihomo controller boundaries

- [ ] `DNS_MIHOMO_CONTROLLER` completes a TLS handshake for
  `zash.<DNS_BASE_DOMAIN>`
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
- [ ] Fresh/reset seeds forward sniffable TCP `:8080` and `:8443` traffic to
  the visible HTTP Host or TLS SNI on the same destination port. No-SNI,
  unrecognized raw TCP, and UDP on those ports fail closed.
- [ ] A fresh or explicitly reset seed reports `speedtest-5060` enabled and has
  TCP and UDP `:5060` listeners on every configured gateway address, with
  `5060` present in the HTTP, TLS, and QUIC sniffer port sets and exact
  console/zash `:5060` rejects immediately after the canonical panel-reject
  prefix. Disabling it requires confirmation and removes only those canonical
  objects; re-enabling restores them. Restrict the test source in the provider
  security group.
- [ ] On the enabled module, HTTP Host and TLS SNI preserve destination port
  `5060`. Test QUIC only against an origin that actually serves supported QUIC
  on `:5060`. A raw UDP packet and a raw TCP/SIP connection fail closed; they
  are not successful Speedtest acceptance cases.
- [ ] With the reset seed active, send at least six malformed or non-TLS TCP
  connections to the gateway `:443` listener, then immediately verify both a
  valid `console.<base>` TLS request and a different gateway-steered TLS SNI.
  The console still reaches its loopback backend and the different SNI is
  sniffed and forwarded normally; neither request waits for a 600-second
  sniff-failure cache expiry.
- [ ] With the reset seed active, an HTTP request for `console.<base>` through
  the gateway `:80` listener is rejected promptly before the console `DIRECT`
  rule. Mihomo logs show no attempted dial to `127.0.0.1:80`; HTTPS through
  the gateway `:443` listener still reaches the console successfully.
- [ ] UDP traffic that remains identified as `console.<base>` or `zash.<base>`
  is rejected promptly before either panel `DIRECT` rule; successfully sniffed
  QUIC for other hostnames still follows the operator data-plane rules.
- [ ] The reset seed contains no `REJECT-DROP`. Non-allowlisted zashboard and
  anti-loop traffic match `REJECT`, create no outbound dial retries, and leave
  no connection tracker after the client closes.
- [ ] Mihomo's re-resolution reaches `127.0.0.1:5354`. A non-extension hostname
  reaches trust; an active extension bound to China reaches the live China
  group with the configured ECS; the same extension bound to trust reaches
  trust. No case loops into DoT `:853` or gateway ingress.
- [ ] Direct/CN DNS answers bypass the gateway and connect to the real address.
- [ ] Anti-loop rules reject gateway-self, loopback, private, link-local,
  CGNAT, and other protected destinations before the terminal egress group.
- [ ] The host has no 5gpn TUN/TProxy, WireGuard, fwmark, policy table, or NAT
  forwarding setup.

## 8. Config apply and concurrency

- [ ] A stale ingress-module revision, a partial/custom `:5060` shape, or a
  missing, late, or bypassed fail-closed private/loopback guard is rejected
  without changing the live file. Force a module hot-apply failure and verify
  the previous exact bytes are restored and reapplied. Disabling a canonical
  module removes only its exact listeners, sniffer entries, and panel guards.

- [ ] Load the raw editor, change the ingress module elsewhere, then submit the
  old raw snapshot and an old reset confirmation. Both stale revisions return
  `409`, preserve the newer module config, and leave the controller untouched.

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

## 9. Install, reinstall, and uninstall safety

- [ ] A normal reinstall and `configure` leave the operator mihomo config
  byte-for-byte identical after validation.
- [ ] Explicit mihomo reset validates a candidate first, creates a backup, and
  atomically installs the seed. A failed candidate leaves the original intact.
- [ ] A deliberately failed service start causes installer failure; it never
  prints a successful completion banner.
- [ ] Debug install writes self-signed material only below
  `/etc/5gpn/debug-cert`; hashes under `/etc/letsencrypt/archive` remain
  unchanged.
- [ ] Pinned quick-install failure does not fall back to a mismatched `main`.
- [ ] With both channels published, the default quick installer resolves the
  newest normal `X.Y.Z` release even when a newer beta prerelease exists.
- [ ] `quick-install.sh --beta` resolves the newest published
  `X.Y.Z-beta.N` prerelease. Missing beta metadata, a normal release carrying a
  beta-looking tag, and a beta-tagged bundle selected for the official channel
  all fail before deployment mutation and never fall back across channels.
- [ ] Starting from a clean pre-v5 release/fixture, populate every common JSON
  state file and install a valid customized legacy mihomo config. First prove
  the untouched `dns.env` and interception v4 document fail with the explicit
  rebuild instructions. Through the old v4 API, disable MITM and verify the
  sidecar stops and old reserved rules disappear. Create recoverable copies,
  build the fixed credential-preserving empty v5 candidate, validate it with the
  current sidecar, atomically replace v4, remove only the retired key, and verify
  the preserved mihomo infrastructure still authenticates. Record that the old
  master-disable transaction changed the mihomo hash by removing its managed
  blocks, then treat that clean post-disable hash as the preservation baseline.
  Upgrade with
  the exact stamped beta bundle through ordinary `--beta`. The common policy,
  upstream, ECS, Telegram, subscription, and statistics state remains readable,
  the new interception state uses the current schema, a missing marketplace
  file is exposed as an empty source list, and the clean post-disable mihomo
  hash is byte-for-byte unchanged by the installer. DNS, Console, Telegram,
  and the existing data plane remain healthy, while completion explicitly says
  core install complete and Extensions unavailable. Enabling interception must
  fail closed until its mihomo boundary is made ready.
- [ ] Restore the same pre-v5 baseline, repeat the explicit schema rebuild, and
  run the exact stamped beta bundle as
  `--beta upgrade-reset-mihomo` from a real TTY. Review and accept the destructive
  warning. The retained backup must hash-identically to the old customized file;
  the replacement must pass pinned `mihomo -t`, match the sidecar credentials,
  contain exactly one canonical listener/node/fail-closed boundary, and permit a
  synthetic extension to enable and pass end-to-end traffic verification. Run
  the command without a TTY and cancel its confirmation in separate attempts;
  both must stop before the mihomo or deployment transaction is mutated.
- [ ] Repeat both pre-v5 upgrade paths with injected failures before and after
  CA creation, state-root creation, service-account creation, mihomo candidate
  validation, publication, and service readiness. Paths absent before the
  attempt are absent afterward; pre-existing owned CA/state trees are restored
  byte-for-byte; unowned lookalike paths are refused; a newly created
  `gpn-intercept` user/group is removed only when still in its expected isolated
  shape; and pre-existing accounts remain untouched. The original mihomo file,
  services, nftables state, and installed release stay runnable after rollback.
- [ ] With a future stamped stable fixture that includes cross-channel
  delegation, invoke its installed `5gpn --beta` and verify that it executes the
  root-owned quick installer retained from the verified bundle, selects one
  exact beta tag, and uses only that tag's scripts and artifacts. A missing,
  symlinked, or non-root-owned retained quick installer fails closed and directs
  the operator to the remote verified quick path. Do not expect this behavior
  from the historical `0.0.13` installer.
- [ ] GitHub still reports the official release through `/releases/latest` after
  publishing a beta, and every installed first-party asset reports or records
  the same exact selected tag.
- [ ] Missing/invalid Gum checksum falls back to plain output without installing
  the unverified binary.
- [ ] Compare `nft list ruleset` with `/tmp/nft.before`: install, reinstall, and
  uninstall leave every table, `/etc/nftables.conf`, and firewall-service
  enablement unchanged.
- [ ] Custom cleanup paths outside 5gpn defaults are rejected unless canonical,
  safe, and marked as 5gpn-owned. `/`, system directories, and unowned paths are
  never recursively deleted.
- [ ] Pre-create similarly named operator-managed services, binaries, and
  directories without 5gpn ownership markers; install, reinstall, and uninstall
  preserve them unchanged.

## 10. Certificate renewal and recovery

- [ ] `CERT_MODE` accepts exactly `cloudflare`, `http-01`, and `debug`; switching
  between modes is a confirmed TUI operation, not a caller-environment input.
- [ ] Both production modes use only the canonical
  `/etc/letsencrypt/live/<base>` lineage with Certbot name `<base>`; no numbered
  duplicate or unscoped host lineage is issued or renewed.
- [ ] Place an invalid, expiring, partial, or mode-mismatched canonical lineage
  at `<base>` without 5gpn-owned provenance. Install fails before invoking
  Certbot and leaves the lineage bytes/config unchanged. A fully valid external
  fingerprint is reused read-only, remains non-deletable by decommission, gets
  the exact-lineage deploy hook, and does not enable the 5gpn public timer.
- [ ] With only an owned `<base>` lineage, the installer disables the distro
  `certbot.timer` so renewal cannot bypass the project lock. With another
  lineage present and depending on that global timer, installation fails closed
  instead of disabling unrelated renewal. Forced failure restores the exact
  pre-transaction enabled/active state; an already active `certbot.service`
  also aborts before lineage inspection.
- [ ] Record an enabled/active distro `certbot.timer`, complete the first owned
  takeover, and verify the root-only saved state survives an owned reinstall
  without changing. Switch to debug or uninstall normally: the original
  enabled/active state is restored exactly and the saved takeover state is
  removed.
- [ ] In `cloudflare` mode, the certificate has the exact apex `<base>` and
  `*.<base>` SAN shape. Initial issuance and a due timer renewal use Cloudflare
  DNS-01 without stopping mihomo or binding an ACME `:80` listener; a synthetic
  `zash.<base>` remains valid for this mode.
- [ ] In `http-01` mode, install and mode-switch TUI screens display the required
  A records for `console.<base>`, `zash.<base>`, and `dot.<base>` and require an
  explicit confirmation before any issuance attempt.
- [ ] For HTTP-01, make one A answer absent, wrong, or non-unique, or publish an
  AAAA answer. The gate observes the failure through `1.1.1.1`, keeps waiting
  and then fails closed without issuing a certificate. After all three names
  each return exactly the sole A `DNS_PUBLIC_IP` and no AAAA through `1.1.1.1`,
  the same install/configure path proceeds.
- [ ] The HTTP-01 lineage contains exactly the three service SANs and contains
  neither `<base>` nor `*.<base>`.
- [ ] HTTP-01 initial issuance stops mihomo, serves the standalone ACME
  challenge on TCP `:80`, keeps mihomo stopped while the new lineage and
  `zash/current` role certificate are validated/published, and restores it in
  the later service-start phase. A forced challenge failure or signal also
  restores a previously active mihomo service.
- [ ] A scheduled check while the certificate is not due leaves mihomo running.
  A due HTTP-01 renewal repeats the `1.1.1.1` DNS gate and the same bounded
  stop-and-restore window; a due Cloudflare renewal remains interruption-free.
- [ ] The systemd timer and the Telegram bot's confirmed renewal action invoke
  the same mode-aware scoped helper. Their result and journal output agree for
  not-due, success, DNS-gate failure, Certbot failure, and mihomo-restore failure.
- [ ] Hold `/run/5gpn/install.lock`, then start the public renewal service: it
  exits without reaching the certificate lock or Certbot. The interception
  certificate oneshot still succeeds during the installer's explicit
  certificate-lock handoff.
- [ ] A successful production renewal runs the deploy hook, updates all three
  role copies, and regenerates/signs the iOS profile.
- [ ] After a fresh install and an in-place upgrade, `/etc/5gpn` is
  `root:gpn-dns` mode `3771`, `/etc/5gpn/cert` is `root:root` mode `0751`, and
  its root marker is `root:root` mode `0644`. Verify the runtime traversal
  contract directly:
  `sudo -u gpn-dns test -r /etc/5gpn/cert/dot/current/fullchain.pem` and
  `sudo -u mihomo test -r /etc/5gpn/cert/zash/current/privkey.pem` both succeed.
  Neither runtime account can rename the root-owned `cert`, `mihomo`,
  `intercept`, or interception `tls` directory through its sticky parent.
- [ ] New TLS handshakes observe renewed files by mtime without daemon restart.
- [ ] After Cloudflare renewal, a new Controller TLS handshake presents the
  renewed certificate without restarting mihomo. HTTP-01 needs no additional
  certificate-loading restart beyond restoring mihomo after its ACME `:80`
  window.
- [ ] A temporarily missing/broken cert is visible in status/journal; restoring
  valid files allows the TLS listeners to recover without destroying DNS state.

## 11. Telegram bot (optional real-network smoke)

Use a disposable Telegram bot token, at least two test administrator accounts,
and a temporary group. Back up `/etc/5gpn/tgbot.json` first and do not paste the
token into recorded command output, screenshots, or issue logs.

- [ ] `5gpn setup-tgbot` requires a TTY, reports an existing `DNS_TGBOT_FILE` as the active
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
  upstreams, maintenance, iOS install, marketplace, installed extensions, and
  the Web-console link. DNS diagnosis agrees with `/api/resolve-test`;
  policy/subscription/YAML editing is absent.
- [ ] From an authorized private chat, add and refresh the official marketplace,
  browse its normalized entries, install one entry, remove/re-add its source,
  and verify the installed immutable snapshot is unaffected. Repeat installation
  through an HTTPS manifest URL and pasted local manifest text. Exercise
  uninstall, enable/disable, update check/apply, egress binding, and complete
  reorder. Every install and applied update finishes disabled, and all results
  agree with the Console and the underlying marketplace/sidecar revisions.
- [ ] For every Telegram marketplace or extension mutation, verify that the bot
  renders the complete normalized impact before exposing Confirm. Capture a
  confirmation and try it after expiry, twice, from the second administrator,
  from a different private chat, and from the group. Then change the marketplace
  revision/index digest, sidecar revision/installed snapshot digest, and
  install/update candidate digest between review and confirmation. Every stale,
  replayed, cross-user, cross-chat, or digest-mismatched attempt must fail without
  state changes and require a fresh review.
- [ ] Install a synthetic extension with multiple exact network origins. Each
  affected Telegram review lists every origin, and enable states that the script
  can send any decrypted request, response, setting, or storage data visible to
  it to each origin. Paginate or attach an oversized review and verify Confirm
  appears only after the final review part. Change one origin through a disabled
  update and verify the old confirmation cannot authorize the new snapshot.
- [ ] Edit `text`, `select`, `boolean`, `number`, and `location` values from
  Telegram, with revision conflict injection for each save. Set `location` once
  with a Telegram native location message and once with manual longitude,
  latitude, and accuracy. Both paths warn before collection that coordinates
  pass through Telegram and the Bot API; the bot does not claim to embed the
  Console's city-search/draggable-map/accuracy-visualization editor.
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

## Modular HTTP/3 interception

- [ ] On a fresh install the Console MITM master is off, there are no installed
  extensions, `5gpn-intercept.service` is inactive, and `--check-enabled` exits
  nonzero. `5gpn-intercept-runtime.path` remains active. Enabling the master
  without an enabled extension still leaves the sidecar stopped. Install and
  enable a valid native extension, then verify the service starts as
  `gpn-intercept`, has no capabilities, listens only on
  `127.0.0.1:18080/tcp`, and passes
  `/opt/5gpn/bin/5gpn-intercept --config /etc/5gpn/intercept/config.json --healthcheck`.
  Its private `/var/lib/5gpn-intercept/store.json` survives a sidecar restart,
  while purge removes the independently marked state directory.
- [ ] With the MITM master and at least one extension enabled, reinstall the
  same release. The installer must hand the private certificate lock to the
  required `5gpn-intercept-cert.service`, start and health-check the sidecar,
  reacquire the lock before final verification, and preserve the interception
  document, marketplace cache, and operator-owned mihomo bytes. Inject a
  sidecar start failure and verify rollback runs only after the lock is held
  again.
- [ ] On a fresh or explicitly reset mihomo config, Settings reports
  `block-quic-443` enabled and the canonical UDP/443 reject appears exactly once
  after `IN-NAME,intercept-egress,REJECT` and before every `MODULE-INTERCEPT` rule.
  Disable and re-enable it through the authenticated module API; each change
  must revision-check, pass full `mihomo -t`, hot-apply, and preserve unrelated
  operator YAML. Confirm that the UDP listener remains bound and that traffic
  bypassing the gateway is unaffected.
- [ ] `/etc/5gpn/intercept-ca/root.key` is root-only and is inaccessible from
  `5gpn-dns`, mihomo, and `5gpn-intercept`; the runtime leaf is not a CA and
  covers only the capture hosts of enabled native extensions. With none enabled,
  the private root remains valid but no leaf is required.
- [ ] `5gpn-intercept-cert.path` and `5gpn-intercept-runtime.path` react to an atomic module config replacement,
  the root-owned publisher writes the expected `cert-state` digest, and neither
  long-running daemon can read the signing key. Turning the Console master off
  removes DNS/mihomo interception state and cleanly stops the sidecar; turning
  it back on starts the sidecar and restores only the armed hosts.
- [ ] `5gpn-intercept-cert.timer` remains enabled and active in Cloudflare,
  HTTP-01, debug, and missing-public-lineage installations. Trigger it directly
  and verify it invokes only `5gpn-intercept-cert.service`; a public renewal
  failure cannot skip the interception-leaf expiry check.
- [ ] Replace `/etc/5gpn/cert`, one certificate role, or
  `/etc/5gpn/intercept/tls` with a symlink, drift a root marker to a runtime
  owner, or add a hardlink to a keypair file. The corresponding root helper
  fails before publication and preserves every prior live keypair. Replacing a
  lock pathname while the inherited descriptor still references the old inode
  is also rejected.
- [ ] `/ios/ios-intercept-ca.mobileconfig` downloads as a CMS-signed Apple profile.
  On an owned test iPhone, install it and explicitly enable full trust under
  Certificate Trust Settings. Removing this profile does not remove the DoT
  profile.
- [ ] From Console `/extensions`, install a strict `5gpn.io/v1` synthetic
  manifest by HTTPS URL and verify the server snapshots both the manifest and a
  relative script. Repeat through the separate local-add dialog with an inline
  script. Unknown fields, duplicate keys, YAML aliases/anchors/merges, multiple
  documents, non-HTTPS resources, unsafe redirects, and out-of-scope action
  hosts must fail installation. Every valid install starts disabled; required
  typed settings and required operator egress-group bindings remain hard enable
  gates. Exact network origins are normalized into the immutable snapshot and
  changing them changes the reviewed digest.
- [ ] Confirm `/extensions` contains only installed-plugin management and host
  audit entry points: there is no embedded Marketplace tab and no decorative
  capture/transform/egress traffic rail. Open the top-level `/marketplace`
  route with no configured sources. Add
  `https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json`, verify
  an optional local display name does not replace the index identity, then use
  the source chips, search, truthful sort, and refresh controls across the
  published entries. Refreshing a valid source atomically updates the
  complete list. Inject an unreachable origin, unsafe redirect, private dial
  target, malformed/oversized JSON, duplicate field, and partial entry; each
  failure must leave the previous complete marketplace snapshot unchanged.
- [ ] Select one official marketplace entry, review the cached scope in the
  install-confirm dialog, and verify the daemon then refetches the
  listed manifest, checks its byte size and SHA-256 plus every referenced script
  size/digest and derived capability summary, then shows the actual imported
  snapshot review. A changed manifest, script, identity, version, permission,
  or capability count must abort before the module revision changes. A valid
  install starts disabled and never turns on the MITM master. Remove and re-add
  the marketplace; installed immutable extension snapshots must be unaffected.
- [ ] Reorder installed extensions through the Console. Request and response
  actions execute top-to-bottom in the displayed order. For a host or network
  origin shared by extensions with different bindings, the first matching
  bound extension wins; moving it changes the ordered mihomo egress rule block
  only after revision check, `mihomo -t`, and hot apply. A stale reorder is
  rejected without changing either config.
- [ ] Verify every installed extension defaults its capture-host DNS binding to
  trust. Switch one to China and confirm its captured hostname resolves through
  the live China group with `DNS_CHINA_ECS`; non-captured names remain on trust.
  Create an exact/wildcard overlap with different bindings and verify the first
  enabled extension in execution order wins. Reorder and confirm the winner
  changes only after the reviewed revision-protected transaction. URL paths
  under one hostname must not change the selected resolver.
- [ ] With the master off, enable the synthetic module in the Console and verify
  it remains armed but has no DNS overlay or mihomo host rule. Turn the master
  on, then disable/re-enable the extension from
  Telegram. Each surface shows the same revision and state. The complete
  mihomo config passes `mihomo -t`; ordered `intercept-egress` domain/port rules
  sit before the fail-closed `IN-NAME,intercept-egress,REJECT` terminator, while
  sorted port-80/443 `MODULE-INTERCEPT` rules sit after it and the optional QUIC
  guard. The DNS answer changes to the gateway only while enabled, and
  certificate/mihomo failure injection restores the previous state.
- [ ] With `MitM over HTTP/2` on and QUIC fallback protection off, verify plain
  HTTP, TLS/H1/H2, QUIC v1/v2, and H3 apply the same native request/response
  actions. Text and binary-body scripts
  decode identity, gzip, zlib/raw deflate, and Brotli bodies within their
  expanded-size bounds. Verify `transform(context)` receives only the structured
  request/response projection and typed settings. `context.storage` exists only
  when the manifest requests it; ambient `fetch`, filesystem, process, timer,
  compatibility globals, and module-loader access fail closed. A plugin with
  declared network origins receives only `context.network.request`; exact
  scheme/host/effective-port matches succeed through authenticated mihomo
  SOCKS5, while cross-origin calls, redirects, implicit cookies/authorization,
  oversized responses, excessive calls, caller cancellation, VM timeout, and
  backtracking-regexp timeout remain bounded. The enable dialog must state that
  the plugin can send any decrypted request, response, setting, or storage data
  visible to it to every listed origin.
- [ ] Bind a required extension to an existing mihomo group and verify only
  group names plus `DIRECT` are offered. Removing or renaming a referenced group
  through the raw config API is rejected before publication. An out-of-band
  invalidation marks the extension not-ready, withdraws the DNS overlay, and
  never falls back to DIRECT or the terminal group; rebinding restores service
  through the normal transaction.
- [ ] Turn `MitM over HTTP/2` off and verify new TLS connections negotiate
  HTTP/1.1 only. Turn QUIC fallback protection on and verify matched IETF QUIC
  v1/v2 receives no forwarded response while a capable client retries over
  TCP/HTTPS. Record clients that fail instead of falling back; do not claim
  legacy GQUIC coverage.
- [ ] Install
  `https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml`,
  search for a city in its generic map-backed `location` setting, fine-tune the
  marker/coordinates and accuracy, save settings, and enable the extension.
- [ ] Exercise WLOC over TCP/H2, QUIC v1/H3, and QUIC v2/H3. In every case the
  response is patched, the upstream certificate is verified, and packet capture
  shows the sidecar's upstream TCP/UDP entering mihomo's authenticated
  `intercept-egress` listener rather than dialing Apple directly.
- [ ] With malformed protobuf, a client that does not trust the private CA, a
  wrong SNI, or any inactive extension target, interception fails closed. Disabling
  the extension restores ordinary end-to-end forwarding without changing the
  operator's terminal egress group.

After the run, restore temporary policy/upstream/config changes and compare the
captured nftables and mihomo files, restore the Telegram override, and revoke
the disposable token. Record release version, mihomo version, test date, and
any intentionally skipped checkbox with its reason.
