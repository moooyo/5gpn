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
  reachable China and trust upstream groups. The seeded defaults are
  `223.5.5.5` and `22.22.22.22`; `22.22.22.22` is a placeholder for a trusted
  internal resolver, NOT a public recursive one, so a smoke run that depends on
  real foreign resolution must point trust at a resolver that actually
  recurses. The daemon logs a warn-only startup probe when the trust answer
  looks fabricated — treat that warning as a signal the fixture is wrong, not
  as noise.
- At least two controllable upstreams when testing sequential fallback.
- For an upgrade acceptance run, preserve active `dns.env`, mihomo YAML, and
  the complete mihomo `5gpn/` state directory before mutation. A legacy
  multi-process deployment must follow `docs/pre-v5-upgrade.md` and then the
  checked monolith migration; do not improvise a partial schema edit.

Capture before-state for host-owned facilities. In particular:

```bash
sudo nft list ruleset > /tmp/nft.before
sudo cp -a /etc/5gpn/mihomo/config.yaml /tmp/mihomo-config.before
```

## 1. Static and service health

- [ ] `systemctl is-active 5gpn-mihomo` reports active. No `5gpn-dns` or
  `5gpn-intercept` long-running service exists.
- [ ] `systemctl show -p User -p Group 5gpn-mihomo` reports exactly
  `fivegpn:fivegpn`, the installer's only managed Unix service identity.
- [ ] `systemctl show 5gpn-mihomo -p Restart -p RestartUSec \
  -p StartLimitIntervalUSec -p StartLimitBurst -p StartLimitAction` reports
  `Restart=always`, a three-second restart delay, a 60-second start-limit
  interval, burst 10, and action `none`.
- [ ] `journalctl -u 5gpn-mihomo -b` contains no `External controller tls listen error`
  or safe-path rejection after startup.
- [ ] `ss -lntup` shows:
  - `:853/tcp` owned by mihomo;
  - `127.0.0.1:5353/udp` and `127.0.0.1:5354/tcp+udp`;
  - console/controller `127.0.0.1:443/tcp`;
  - mihomo TCP `:80`, `:443`, `:5060`, `:8080`, and `:8443`, plus UDP `:443`
    and `:5060`, on every
    configured local listen IP when testing a fresh or explicitly reset seed.
- [ ] Nothing exposes public DNS `:53`, a DoH handler, or a standalone profile
  port. TCP `:8443` is mihomo application ingress, not DoH.
- [ ] `/opt/5gpn/bin/5gpn-mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo` succeeds.
- [ ] Every `DNS_MIHOMO_LISTEN_IPS` value appears on a local interface. A
  non-local NAT/public address is rejected by installer validation.

### Crash-restart injection

Run this only through an out-of-band management path. It deliberately drops all
live gateway connections once. Capture immutable state first, send an
uncatchable signal to the main process, and allow up to 15 seconds for the
three-second systemd restart:

```bash
sudo sha256sum /etc/5gpn/mihomo/config.yaml \
  /etc/5gpn/mihomo/5gpn/*.json > /tmp/5gpn-crash-state.before
before_pid="$(systemctl show 5gpn-mihomo -p MainPID --value)"
before_restarts="$(systemctl show 5gpn-mihomo -p NRestarts --value)"
test "$before_pid" -gt 0
sudo systemctl is-active --quiet 5gpn-mihomo.service

sudo systemctl kill --kill-whom=main --signal=SIGKILL 5gpn-mihomo.service

deadline=$((SECONDS + 15))
while (( SECONDS < deadline )); do
  after_pid="$(systemctl show 5gpn-mihomo -p MainPID --value)"
  if systemctl is-active --quiet 5gpn-mihomo \
     && [[ "$after_pid" != 0 && "$after_pid" != "$before_pid" ]]; then
    break
  fi
  sleep 1
done

after_restarts="$(systemctl show 5gpn-mihomo -p NRestarts --value)"
test "$after_pid" != 0
test "$after_pid" != "$before_pid"
test "$after_restarts" -gt "$before_restarts"
sudo sha256sum /etc/5gpn/mihomo/config.yaml \
  /etc/5gpn/mihomo/5gpn/*.json > /tmp/5gpn-crash-state.after
diff -u /tmp/5gpn-crash-state.before /tmp/5gpn-crash-state.after
```

- [ ] mihomo becomes active with a new main PID and an incremented `NRestarts`.
- [ ] The operator YAML and revisioned `5gpn` documents remain byte-identical.
  DoT, the authenticated controller, and one ordinary forwarded request all
  work after restart. Connections that existed at the injected crash are
  expected to have failed.
- [ ] A deliberate stop is not undone by `Restart=always`. Run
  `sudo systemctl stop 5gpn-mihomo`, wait five seconds, record that `MainPID` is
  still zero, and then run `sudo systemctl start 5gpn-mihomo` before evaluating the
  result or continuing the checklist.
- [ ] An independent monitor outside this host actively probes DoT and HTTPS,
  observes the injected outage, and clears only after service recovery. The
  persisted `DNS_HEARTBEAT_URL` and `DNS_HEARTBEAT_INTERVAL` fields are inert
  and are not accepted as evidence of health or recovery.

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
  `/5gpn/dns/querylog`; a fallback-direct cache hit is not mislabeled chnroute-cn.
- [ ] `/5gpn/dns/resolve` agrees with the live query for direct, proxy, every
  fallback, NXDOMAIN, and NODATA.

## 4. Upstream ordering, reload, and subscriptions

- [ ] With two healthy members in one group, only the first configured member
  is queried/adopted.
- [ ] With the first member silent, the next member is attempted before the
  total request deadline. Recovered first member regains precedence.
- [ ] Parent-context cancellation does not open the upstream breaker; a member
  attempt deadline does allow fallback.
- [ ] A revision-correct whole-document `PUT /5gpn/dns` hot-swaps upstream
  groups, preserves China ECS, flushes old cached answers, and survives mihomo
  restart through `/etc/5gpn/mihomo/5gpn/dns.json`.
- [ ] A whole-document write that changes any listener or certificate-path
  field returns 400, leaves the revision and disk bytes unchanged, and leaves
  all existing listeners serving.
- [ ] A china group configured with a DoT or DoH member resolves CN names, and
  the operator's `DNS_CHINA_ECS` subnet still rides the query on that member —
  ECS is attached before the transport is chosen, but nothing else covers it.
- [ ] Repeated whole-document writes with a China DoH member leave mihomo's fd
  count flat. A pooled `http.Transport` is retired on a grace timer, and a
  regression here leaks one per save rather than failing visibly.
- [ ] A subscription hostname resolves through the current trust snapshot.
- [ ] Network failure, redirect to a special-use address, oversized line, or
  parser error retains the previous cache byte-for-byte and schedules backoff.
- [ ] An unchanged fetch does not rewrite cache files or flush response cache.

## 5. Public console, iOS bootstrap, and authentication

Set `CONSOLE=console.<base>` and `SECRET` to mihomo's current controller
secret. Direct loopback tests isolate controller routing:

```bash
curl --resolve "$CONSOLE:443:127.0.0.1" -fsS \
  -H "Authorization: Bearer $SECRET" "https://$CONSOLE/5gpn/dns"
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
  probe="$(curl --noproxy '*' --resolve "$CONSOLE:443:127.0.0.1" \
    -sS -o /dev/null -w $'%{http_code}\t%{content_type}' \
    "https://$CONSOLE/ui/$profile")"
  IFS=$'\t' read -r code content_type <<< "$probe"
  media_type="${content_type%%;*}"
  media_type="${media_type#"${media_type%%[![:space:]]*}"}"
  media_type="${media_type%"${media_type##*[![:space:]]}"}"
  [[ "$code" == 200 \
    && "${media_type,,}" == application/x-apple-aspen-config ]] || {
      printf '%s: HTTP %s, Content-Type %s\n' \
        "$profile" "${code:-none}" "${content_type:-<missing>}" >&2
      exit 1
    }
done
```

- [ ] The correct controller secret returns 200 from `/5gpn/dns` and ordinary
  authenticated controller routes. A missing or wrong secret returns 401.
- [ ] Both console profile responses are `200` with media type exactly
  `application/x-apple-aspen-config` (case-insensitive, optional parameters
  allowed), contain no secret, and are installable by iOS before DoT is
  configured.
- [ ] Installing or reinstalling does not add a `mobileconfig` entry to
  `/etc/mime.types` or otherwise modify the host's shared MIME database; the
  controller supplies the profile media type itself.
- [ ] A normal install fails before declaring success when the console A record
  is missing/wrong; exported skip variables cannot bypass the gate.
- [ ] `https://$CONSOLE/ui` redirects to `/ui/`; `/ui/` serves zashboard
  without authentication. A nonexistent profile path never returns a valid
  profile as a false-positive.
- [ ] The Console Setup Guide shows the derived `dot.<DNS_BASE_DOMAIN>`
  identity, Android instructions, and direct links to both public `/ui/`
  profiles.
- [ ] Production CSP reports no inline script/style or worker/font violation.

## 6. Mihomo controller boundaries

- [ ] The single `console.<base>` origin completes a TLS handshake with the
  console certificate and no safe-path rejection in `journalctl -u 5gpn-mihomo -b`;
  plaintext HTTP or a mismatched SNI fails closed.
- [ ] zashboard REST and WebSocket operations use mihomo's controller directly
  on the same origin. There is no `/proxy/`, second panel SNI, source allowlist,
  handoff session, or separate Console bearer.
- [ ] `/ui/*` remains the only unauthenticated controller surface. `/5gpn/*`
  and ordinary controller routes reject a missing or wrong controller secret,
  and neither secrets nor extension log contents appear in error bodies or
  persistent journal output.
- [ ] An engine inner dial naming `console.<base>` is rejected by the
  `IN-TYPE,INNER` exclusion before it can reach the management listener.

## 7. Data-plane forwarding

- [ ] A proxy/foreign DNS answer is exactly `DNS_GATEWAY_IP`, and that address
  is one of the active mihomo listener addresses.
- [ ] HTTPS and HTTP connections steered to the gateway are sniffed and
  forwarded according to the operator mihomo config. Every gateway UDP/443
  flow is rejected by the fixed guard.
- [ ] Fresh/reset seeds forward sniffable TCP `:8080` and `:8443` traffic to
  the visible HTTP Host or TLS SNI on the same destination port. No-SNI,
  unrecognized raw TCP, and UDP on those ports fail closed.
- [ ] A fresh or explicitly reset seed reports `speedtest-5060` enabled and has
  TCP and UDP `:5060` listeners on every configured gateway address, with
  `5060` present in the HTTP, TLS, and QUIC sniffer port sets and the exact
  console `:5060` reject immediately after the canonical panel-reject
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
- [ ] UDP traffic that remains identified as `console.<base>` is rejected
  promptly before its panel `DIRECT` rule. QUIC on another configured port,
  including the optional `:5060` ingress, still follows operator data-plane
  rules after successful sniffing.
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

- [ ] Hot-applying a complete payload through `PUT /configs` changes only the
  live runtime: the operator YAML hash and mode remain unchanged, and reloading
  the default path removes payload-only proxy nodes and groups.
- [ ] A candidate operator YAML that adds one proxy and wires it into
  `Proxies` passes the pinned `5gpn-mihomo -t`. After safe publication and
  reload, `/proxies` lists the node in `Proxies`, the selector can choose it,
  and the terminal `MATCH,Proxies` traffic path uses it in rule mode.
- [ ] The root TUI Nodes tab previews a pasted Clash proxy and a standard-Base64
  URI export without writing, then a confirmed import atomically persists every
  parsed static node, appends it to `Proxies`, preserves the current selection,
  and verifies the live `/proxies` projection. One bad URI or a stale revision
  rejects the whole batch. Delete removes the exact static node and membership,
  but refuses a node currently selected by any group or referenced elsewhere.
  A reinstall keeps `config.yaml.5gpn-nodes.lock` root-owned `0600`, after which
  another node transaction still succeeds.
- [ ] Publishing an invalid operator candidate is refused before replacement;
  the live YAML, controller listeners, UI path, and current runtime remain
  unchanged.
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
- [ ] Starting from a clean legacy multi-process fixture, follow the historical
  pre-v5 runbook without shortcuts, then run the checked monolith migration.
  The candidate removes only retired runtime-overlay anchors and the old
  interception inbound boundary, rewrites panel exclusions to `IN-TYPE,INNER`,
  contains exactly one fixed UDP/443 guard, and passes the pinned `5gpn-mihomo -t`
  before atomic publication. Preserve recoverable copies throughout.
- [ ] After migration, exactly one long-running mihomo process owns DNS,
  forwarding, interception, Telegram, and the controller. The migrated DNS,
  extension, catalog, and bot documents remain readable; the operator-owned
  egress configuration remains intact; retired services cannot restart or bind
  their old ports.
- [ ] Inject failures before candidate validation, state publication, and
  service readiness. A failure before publication leaves the host untouched; a
  failure during publication is reported as partial and never claims a rollback
  that did not occur. Unowned lookalike paths remain untouched.
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
- [ ] Exact old names are migration inputs only. With owned legacy evidence,
  safe legacy identity shapes for `mihomo`, `gpn-dns`, `gpn-intercept`,
  `5gpn-overlay-ctl`, and `5gpn-overlay-gen` are removed non-interactively after
  the old unit is stopped and process use is excluded. An unsafe or ambiguous
  host identity is preserved with a warning rather than guessed to be ours.
- [ ] The owned old `mihomo.service`, `/opt/5gpn/bin/mihomo`, and
  `/etc/5gpn/mihomo/gpn` migrate to `5gpn-mihomo.service`,
  `/opt/5gpn/bin/5gpn-mihomo`, and `/etc/5gpn/mihomo/5gpn`. If both state
  directories contain data, installation fails before mutating either.

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
  DNS-01 without stopping mihomo or binding an ACME `:80` listener.
- [ ] In `http-01` mode, install and mode-switch TUI screens display the required
  A records for `console.<base>` and `dot.<base>` and require an
  explicit confirmation before any issuance attempt.
- [ ] For HTTP-01, make one A answer absent, wrong, or non-unique, or publish an
  AAAA answer. The gate observes the failure through `1.1.1.1`, keeps waiting
  and then fails closed without issuing a certificate. After both names
  each return exactly the sole A `DNS_PUBLIC_IP` and no AAAA through `1.1.1.1`,
  the same install/configure path proceeds.
- [ ] The HTTP-01 lineage contains exactly the two service SANs and contains
  neither `<base>` nor `*.<base>`.
- [ ] HTTP-01 initial issuance stops mihomo, serves the standalone ACME
  challenge on TCP `:80`, keeps mihomo stopped while the new lineage and
  `console/current` role certificate are validated/published, and restores it in
  the later service-start phase. A forced challenge failure or signal also
  restores a previously active mihomo service.
- [ ] A scheduled check while the certificate is not due leaves mihomo running.
  A due HTTP-01 renewal repeats the `1.1.1.1` DNS gate and the same bounded
  stop-and-restore window; a due Cloudflare renewal remains interruption-free.
- [ ] The systemd timer and an explicit host-side renewal invoke the same
  mode-aware scoped helper. Their result and journal output agree for not-due,
  success, DNS-gate failure, Certbot failure, and mihomo-restore failure.
- [ ] Hold `/run/5gpn/install.lock`, then start the public renewal service: it
  exits without reaching the certificate lock or Certbot. The interception
  certificate oneshot still succeeds during the installer's explicit
  certificate-lock handoff.
- [ ] A successful production renewal runs the deploy hook, updates all three
  role copies, and regenerates/signs the iOS profile.
- [ ] After a fresh install and an in-place upgrade, `/etc/5gpn` is
  `root:root` mode `0755`, `/etc/5gpn/cert` is `root:root` mode `0751`, and
  its root marker is `root:root` mode `0644`. Verify the runtime traversal
  contract directly:
  `sudo -u fivegpn test -r /etc/5gpn/cert/dot/current/fullchain.pem` and
  `sudo -u fivegpn test -r /etc/5gpn/cert/console/current/privkey.pem` both succeed.
  Both use `fivegpn`, not one account each: the DoT listener moved into the same
  process that serves the controller, so one account reads every certificate the
  gateway presents. A `dot` role still readable only by a legacy DNS account is the shape
  that let a fresh install come up with no DNS ingress and no error.
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

Use a disposable Telegram bot token and at least two test administrator
accounts. Back up `/etc/5gpn/mihomo/5gpn/bot.json` first and never paste the token
into recorded command output, screenshots, or issue logs.

- [ ] Console configuration writes the bot document atomically. Reads
  report only `token_set`; neither `/5gpn/bot` nor status output returns the
  token. A malformed or unauthorized token leaves the previous document and
  running bot usable.
- [ ] A token that previously had a webhook is safely returned to long polling.
  Lifecycle and health fields agree with enable, network failure, recovery,
  disable, and an unexpected polling-loop exit.
- [ ] `/id` returns only the caller and chat numeric IDs. `/status` and
  `/resolve <domain>` answer configured administrators and agree with the
  Console's resolver and interception state. Removing an administrator takes
  effect on the next update.
- [ ] The command surface is read-only. Attempts to install, enable, disable,
  update, reorder, or configure an extension; edit policy; restart mihomo; read
  logs; or touch the interception CA return `unknown command` and leave every
  document revision unchanged.
- [ ] With alerts disabled, the bot sends no unsolicited messages. With alerts
  enabled, resolver, interception, certificate, subscription, and upstream
  failure/recovery transitions notify configured administrators without
  repeated unchanged-state spam.
- [ ] Stopping mihomo cannot produce a Telegram alert from inside that process.
  An independent external pull probe detects the unavailable DoT and HTTPS
  endpoints; no in-process push heartbeat is treated as evidence of health.

## Native HTTP/H1/H2 interception and the HTTP/3 boundary

- [ ] `GET /5gpn/interception` reports `http3: false`. A revision-correct
  settings write attempting `http3: true` returns 422, does not advance the
  revision, and does not change any other setting.
- [ ] The running rule set contains exactly one fixed global
  `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` before extension rules and capture.
  The controller rule-management API refuses to disable it.
- [ ] A client offered H3 receives no forwarded UDP/443 response. A client that
  supports fallback retries over TCP and reaches the same origin through
  HTTP/H1/H2 capture; an H3-only client fails.
- [ ] Ordinary UDP remains unaffected. The optional `:5060` ingress still
  recognizes supported QUIC Host/SNI and follows operator rules; raw UDP remains
  outside the HTTP interception contract.

- [ ] On a fresh install the Console MITM master is off and there are no
  installed extensions. The engine is loaded inside mihomo and exposes no
  sidecar process, loopback interception listener, or SOCKS return hop. Enabling
  the master without an enabled extension still captures nothing.
- [ ] With the MITM master and at least one extension enabled, reinstall the
  same release. The installer must hand the private certificate lock to the
  required `5gpn-intercept-cert.service`, reacquire the lock before final
  verification, and preserve the interception document and operator-owned
  mihomo bytes.
- [ ] `/etc/5gpn/intercept-ca/root.key` is root-only and is inaccessible from
  mihomo; the runtime leaf is not a CA and
  covers only the capture hosts of enabled native extensions. With none enabled,
  the private root remains valid but no leaf is required.
- [ ] Turn the MITM master on before enabling a synthetic extension whose host
  is not covered by the current leaf. The enable write authorizes the extension
  and returns `pending`; before publication DNS still claims the host at the
  gateway, while the pre-capture plan rejects its new TCP/TLS connections before
  ordinary rules can turn the pending state into a direct bypass. Do not toggle
  the master, write the extension a second time, start the oneshot manually, or
  restart mihomo.
  The path unit must observe the atomic JSON v1 request, and the runtime must
  automatically become ready after the root publisher commits a JSON v1 result
  carrying the same `target_digest` and `attempt` plus the SHA-256 of the exact
  `fullchain.pem` and `privkey.pem` bytes. The interception document revision
  remains the revision returned by enable while readiness changes; only then may
  the claimed connections enter TLS interception and extension actions.
- [ ] Hold the certificate lock while publishing rapid A -> B -> C host-set
  requests, then release it. A result for A or B must never make either stale
  set ready, partially replaced certificate/key files must fail their commit
  hashes, and the bounded publisher must converge to C. Publish a safe error for
  the current attempt, use the authenticated retry action, and verify the same
  target digest receives a fresh attempt while a late error for the old attempt
  is ignored. An empty host request commits `ready` without material hashes.
  Throughout the test, mihomo cannot read the signing key and the publisher has
  no network address family or Linux capability.
- [ ] Turning the Console master off withdraws the DNS overlay and in-process
  traffic policy. Turning it back on restores only armed hosts whose current
  request, committed result, exact keypair bytes, validity, and complete SAN set
  all agree; it never restores a merely enabled or publisher-error host.
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
- [ ] `/ui/ios-intercept-ca.mobileconfig` downloads as a CMS-signed Apple profile.
  On an owned test iPhone, install it and explicitly enable full trust under
  Certificate Trust Settings. Removing this profile does not remove the DoT
  profile.
- [ ] From Console `/extensions`, install a strict `5gpn.io/v1` synthetic
  manifest by HTTPS URL and verify the server snapshots both the manifest and a
  relative script. Repeat through the separate local-add dialog with an inline
  script. Unknown fields, duplicate keys, YAML aliases/anchors/merges, multiple
  documents, non-HTTPS resources, unsafe redirects, and out-of-scope action
  hosts must fail installation. Every valid install starts disabled with an
  explicit `DIRECT` egress binding; required typed settings remain hard enable
  gates. The unrestricted network grant is a single reviewed boolean with no
  destination list; changing it changes the immutable snapshot digest.
- [ ] Confirm `/extensions` contains only installed-plugin management and host
  audit entry points: there is no embedded Marketplace tab and no decorative
  capture/transform/egress traffic rail. Open the top-level `/marketplace`
  route with no configured sources. Add
  `https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json`, verify
  an optional local display name does not replace the index identity, then use
  the source chips, search, truthful sort, and refresh controls across the
  published entries. Refreshing a valid source atomically updates the
  complete list. Inject an unreachable origin, unsafe redirect, private dial
  target, malformed/oversized JSON, duplicate field, and partial entry; each
  failure must leave the previous complete marketplace snapshot unchanged.
- [ ] Open `/plugin-logs` with an enabled synthetic extension. Verify
  `console.log`/`info`/`warn`/`error` levels, action completion and timeout
  metadata, plugin/action filters, debounced search, one-row expansion, local
  clear, and pause behavior on desktop and mobile. Confirm authenticated
  `/5gpn/interception/logs` reads the retained in-memory ring and script console
  text does not appear in the persistent journal.
- [ ] Select one official marketplace entry, review the cached scope in the
  install-confirm dialog, and verify the daemon then refetches the
  listed manifest, checks its SHA-256 and derived capability summary, then shows
  the actual imported snapshot review. External script resources remain live
  and are not compared with catalog digests. A changed manifest, identity,
  version, permission, or capability count must abort before the module revision
  changes. A valid install starts disabled and never turns on the MITM master.
  The installed page exposes no check-update button and the old
  `/extensions/{id}/update` routes return 404; selecting a changed Marketplace
  entry is the only reviewed update path. Remove and re-add the marketplace;
  installed immutable extension snapshots must be unaffected.
- [ ] Reorder installed extensions through the Console. Request and response
  actions execute top-to-bottom in the displayed order. For a host or network
  origin shared by extensions with different bindings, the first matching
  bound extension wins; moving it changes the immutable in-process policy only
  after revision check. A stale reorder is rejected without changing state.
- [ ] Verify every installed extension defaults its capture-host DNS binding to
  trust. Switch one to China and confirm its captured hostname resolves through
  the live China group with `DNS_CHINA_ECS`; non-captured names remain on trust.
  Create an exact/wildcard overlap with different bindings and verify the first
  enabled extension in execution order wins. Reorder and confirm the winner
  changes only after the reviewed revision-protected transaction. URL paths
  under one hostname must not change the selected resolver.
- [ ] With the master off, enable the synthetic module in the Console and verify
  it remains armed but has no DNS overlay or in-process capture policy. Turn the
  master on and confirm the DNS answer changes to the gateway only while the
  extension is ready.
- [ ] With `MitM over HTTP/2` on, verify plain HTTP and TLS/H1/H2 apply the same
  native request/response actions. Text and binary-body scripts
  decode identity, gzip, zlib/raw deflate, and Brotli bodies within their
  expanded-size bounds. Verify `transform(context)` receives only the structured
  request/response projection and typed settings. `context.storage` exists only
  when the manifest requests it; ambient `fetch`, filesystem, process, timer,
  compatibility globals, and module-loader access fail closed. A plugin with
  network permission receives only `context.network.request`; authorized
  requests succeed through mihomo's inner dialer, while redirects,
  oversized responses, excessive calls, caller cancellation, VM timeout, and
  backtracking-regexp timeout remain bounded. The enable dialog must state that
  the plugin can send any decrypted request, response, setting, or storage data
  visible to it to any host it can reach; the grant has no destination list.
- [ ] Verify every installed extension, whether or not the manifest marks egress
  required, has `DIRECT` selected initially and the Console offers no empty
  option. Switch one to an existing group; only live group names plus `DIRECT`
  are offered. An out-of-band group removal keeps the missing name visible but
  disabled, marks the extension not-ready, withdraws the DNS overlay, and never
  falls back to DIRECT or the terminal group; rebinding restores service through
  the normal transaction. Attempting to clear the binding is rejected without
  moving the revision.
- [ ] Turn `MitM over HTTP/2` off and verify new captured TLS connections
  negotiate HTTP/1.1 only. The fixed UDP/443 reject remains unchanged.
- [ ] Install
  `https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml`,
  search for a city in the map picker the Console renders over its flat
  `longitude`/`latitude`/`accuracy` settings, fine-tune the marker/coordinates
  and accuracy, save settings, and enable the extension. The extension declares
  no `location` setting -- the bundle it runs reads three flat arguments -- so
  confirm the three settings hold the picked values afterwards, and that a point
  left at upstream's `113.94114`/`22.544577` is treated as unconfigured by the
  bundle and patches nothing.
- [ ] Exercise WLOC over TCP/H2. The response is patched, the upstream
  certificate is verified, and connection tracing shows the engine's upstream
  entering mihomo's inner dialer with the selected egress group rather than
  dialing Apple directly. H3 remains rejected by the boundary above.
- [ ] With malformed protobuf, a client that does not trust the private CA, a
  wrong SNI, or any inactive extension target, interception fails closed. Disabling
  the extension restores ordinary end-to-end forwarding without changing the
  operator's terminal egress group.

After the run, restore temporary policy/upstream/config changes and compare the
captured nftables and mihomo files, restore the Telegram override, and revoke
the disposable token. Record release version, mihomo version, test date, and
any intentionally skipped checkbox with its reason.
