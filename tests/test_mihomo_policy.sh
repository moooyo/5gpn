#!/usr/bin/env bash
# Asserts the mihomo data-plane install/config/unit shape (replaces test_proxy_policy.sh).
set -u
FAIL=0
root="$(cd "$(dirname "$0")/.." && pwd)"
check() { if grep -qE "$2" "$root/$1"; then echo "ok: $3"; else echo "FAIL: $3 ($1 !~ $2)"; FAIL=1; fi; }
nocheck() { if grep -qE "$2" "$root/$1"; then echo "FAIL: $3 ($1 =~ $2)"; FAIL=1; else echo "ok: $3"; fi; }

# Task 1: mihomo binary install
check install.sh 'install_mihomo\(\)' 'install_mihomo function exists'
# The data plane no longer comes from upstream: upstream does not implement the
# RUNTIME-OVERLAY anchors, so an upstream core makes the overlay a mechanism that
# can never switch on. What has to stay true is that the source is pinned and
# auditable — a named repository, an exact version, and a digest — rather than
# assembled from anything an operator or an environment can influence.
check install.sh '^MIHOMO_REPO="[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"$' 'mihomo source repository is a pinned literal'
check install.sh 'github.com/\$\{MIHOMO_REPO\}/releases/download' 'downloads mihomo from the pinned repository'
check install.sh '^MIHOMO_SHA256="[0-9a-f]{64}"$' 'mihomo artifact is pinned by digest'
check install.sh 'mihomo-linux-amd64-compatible' 'uses amd64-compatible asset'
check install.sh 'MIHOMO_VERSION' 'mihomo version pin knob'
nocheck install.sh 'install_xray\(\)' 'install_xray removed'

# Task 2: mihomo unit
check etc/systemd/mihomo.service 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' 'project-private mihomo ExecStart'
check etc/systemd/mihomo.service 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' 'mihomo AF set incl AF_NETLINK (required for QUIC/UDP DIRECT dial)'
check etc/systemd/mihomo.service 'ReadWritePaths=/etc/5gpn/mihomo' 'mihomo writes provider caches'
check etc/systemd/mihomo.service 'Environment=SAFE_PATHS=/etc/5gpn/cert/console' 'mihomo SAFE_PATHS scoped to the controller cert role'
check install.sh 'mihomo\.service' 'install_units installs mihomo.service'

# Task 3: mihomo config template shape
T=etc/mihomo/config.yaml.tmpl
check "$T" '__MIHOMO_LISTENERS__'                      'dynamic local-listener placeholder'
SNI_REGRESSION=tests/mihomo-sniff-cache-regression.sh
check "$SNI_REGRESSION" '__INTERCEPT_INBOUND_USERNAME__'  'sniff-cache fixture renders interception inbound username'
check "$SNI_REGRESSION" '__INTERCEPT_INBOUND_PASSWORD__'  'sniff-cache fixture renders interception inbound password'
check "$SNI_REGRESSION" '__INTERCEPT_UPSTREAM_USERNAME__' 'sniff-cache fixture renders interception upstream username'
check "$SNI_REGRESSION" '__INTERCEPT_UPSTREAM_PASSWORD__' 'sniff-cache fixture renders interception upstream password'
check "$T" 'external-controller: ""'                   'plaintext controller disabled in seed'
check "$T" 'certificate: /etc/5gpn/cert/console/current/fullchain\.pem' 'controller TLS certificate key pinned'
check "$T" 'private-key: /etc/5gpn/cert/console/current/privkey\.pem'   'controller TLS private-key key pinned'
nocheck install.sh 'http://127\.0\.0\.1:9090'           'installer no longer calls the plaintext mihomo controller'
check install.sh 'render_mihomo_listeners\(\)'          'dynamic listener renderer'
check install.sh 'name: gateway%s'                       'current gateway listener name'
check install.sh 'name: gateway80%s'                     'current gateway HTTP listener name'
check install.sh 'name: gateway8080%s'                   'alternate HTTP listener name'
check install.sh 'name: gateway8443%s'                   'alternate HTTPS listener name'
check install.sh 'name: gateway5060%s'                   'default Speedtest listener name'
check install.sh 'type: tunnel.*port: 443.*network: \[tcp, udp\]' ':443 tcp+udp listener renderer'
check install.sh 'target: %s:443'                       'listener renderer hostname target'
check install.sh 'port: 8080.*network: \[tcp\].*target: %s:8080' ':8080 TCP hostname target renderer'
check install.sh 'port: 8443.*network: \[tcp\].*target: %s:8443' ':8443 TCP hostname target renderer'
check install.sh 'port: 5060.*network: \[tcp, udp\].*target: %s:5060' ':5060 TCP/UDP hostname target renderer'
check install.sh 'render_mihomo_listeners "\$MIHOMO_LISTEN_IPS" "\$CONSOLE_DOMAIN"' 'renderer receives the console hostname'
nocheck "$T" 'proxy:'                                  'NO proxy field on listeners (would bypass rules)'
check "$T" 'parse-pure-ip: true'                       'sniffer parse-pure-ip'
check "$T" 'override-destination: true'                'sniffer override-destination'
check "$T" 'force-domain: \[__CONSOLE_DOMAIN__\]'     'console fallback always forces hostname sniffing'
check "$T" 'TLS:  \{ ports: \[443, 8080, 8443, 5060\] \}'   'TLS sniffer covers default ingress ports'
check "$T" 'HTTP: \{ ports: \[80, 8080, 8443, 5060\] \}'    'HTTP sniffer covers default ingress ports'
check "$T" 'QUIC: \{ ports: \[443, 5060\] \}'               'QUIC sniffer covers default UDP ingress ports'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__.*DST-PORT,8080.*REJECT' 'console cannot expose loopback :8080'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__.*DST-PORT,8443.*REJECT' 'console cannot expose loopback :8443'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__.*DST-PORT,5060.*REJECT' 'console cannot expose loopback :5060'
nocheck "$T" 'rule-providers:'                         'no rule-provider survives the allowlist removal'
nocheck "$T" 'RULE-SET,[[:space:]]*whitelist'          'no rule reads the retired allowlist provider'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__,REJECT'           'fail-closed deny for engine egress naming the console'
nocheck "$T" 'REJECT-DROP'                             'seed avoids connection-retaining reject rules'
check "$T" '127\.0\.0\.1:5354'                         'loopback origin DNS selector'
check "$T" 'AND,\(\(DOMAIN,__CONSOLE_DOMAIN__\),\(NETWORK,UDP\)\),REJECT' 'console UDP fallback fast-reject rule'
check "$T" 'AND,\(\(DOMAIN,__CONSOLE_DOMAIN__\),\(DST-PORT,80\)\),REJECT' 'console HTTP fast-reject rule'
# The panel allow rule carries both predicates. It sits above the loopback deny,
# because the console resolves to 127.0.0.1, and the engine dials its upstreams
# back through these same rules as INNER -- there is no inbound name to exclude
# by, so the type is the name.
#
# The source rule-set that used to sit beside it is gone by owner decision:
# the panel answers any client that can reach this gateway. That makes the
# INNER exclusion the ONLY qualifier left on this rule, so it is asserted on
# its own -- lose it and a captured extension running operator-supplied
# JavaScript reaches the management plane.
check "$T" 'AND,\(\(NOT,\(\(IN-TYPE,INNER\)\)\),\(DOMAIN,__CONSOLE_DOMAIN__\)\),DIRECT' 'the panel route excludes engine egress'
check "$T" 'external-controller-tls: 127\.0\.0\.1:443' 'the controller listens where the console DIRECT dial lands'
check "$T" 'AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT' 'HTTP3/QUIC UDP 443 block enabled by default'
# HTTP/3 interception is unsupported. The fixed guard must appear exactly once,
# below the private-range denies and above the terminal MATCH, so a capable
# client falls back to TCP. This remains scoped to UDP/443; the seed still
# permits ordinary UDP and keeps QUIC sniffing on :5060.
private_deny_line="$(grep -nF '  - IP-CIDR,169.254.0.0/16,REJECT,no-resolve' "$root/$T" | cut -d: -f1 || true)"
quic_block_line="$(grep -nF '  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT' "$root/$T" | cut -d: -f1 || true)"
quic_block_count="$(grep -cFx '  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT' "$root/$T" || true)"
match_line="$(grep -nF '  - MATCH,Proxies' "$root/$T" | cut -d: -f1 || true)"
if [ "$quic_block_count" = "1" ] && [ -n "$private_deny_line" ] \
   && [ -n "$quic_block_line" ] && [ -n "$match_line" ] \
   && [ "$private_deny_line" -lt "$quic_block_line" ] && [ "$quic_block_line" -lt "$match_line" ]; then
    echo 'ok: the single fixed UDP/443 guard follows private denies and precedes terminal policy'
else
    echo 'FAIL: the fixed UDP/443 guard is missing, duplicated, or out of position'
    FAIL=1
fi
console_direct_line="$(grep -nF '  - AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,__CONSOLE_DOMAIN__)),DIRECT' "$root/$T" | cut -d: -f1 || true)"
panel_order_ok=1
for rule in \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(NETWORK,UDP)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,80)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8080)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8443)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,5060)),REJECT'; do
    reject_line="$(grep -nF "  - $rule" "$root/$T" | cut -d: -f1 || true)"
    route_line="$console_direct_line"
    if [ -z "$reject_line" ] || [ -z "$route_line" ] || [ "$reject_line" -ge "$route_line" ]; then
        panel_order_ok=0
    fi
done
panel_deny_line="$(grep -nF '  - DOMAIN,__CONSOLE_DOMAIN__,REJECT' "$root/$T" | cut -d: -f1 || true)"
anti_loop_line="$(grep -nF '  - IP-CIDR,__GATEWAY_IP__/32,REJECT,no-resolve' "$root/$T" | cut -d: -f1 || true)"
if [ "$panel_order_ok" = 1 ] && [ -n "$panel_deny_line" ] && [ -n "$anti_loop_line" ] \
    && [ "$panel_deny_line" -lt "$anti_loop_line" ]; then
    echo "ok: panel rejects precede panel routes and anti-loop guards follow them"
else
    echo "FAIL: unsafe panel/anti-loop rule ordering"; FAIL=1
fi
nocheck "$T" '__PROFILE_DOMAIN__'                         'retired profile SNI removed'
# UP-4 (2026-07-15 policy/mihomo decoupling): the daemon no longer owns ANY
# region of the mihomo config -- the four >>>5gpn:*/<<<5gpn:* marker comment
# blocks (rule-providers/proxy-providers/proxy-groups/split-rules) are GONE,
# and policy_compile.go no longer renders any mihomo-side RULE-SET/rule-
# provider projection (DNS-only compiler, design §2.4). The seed's egress
# skeleton is a plain operator-owned "Proxies" select group and a terminal
# MATCH,Proxies rule -- not a compiler-rendered split-rules region.
nocheck "$T" '>>>5gpn'                                 'no daemon-owned marker regions remain in the template'
nocheck "$T" '<<<5gpn'                                 'no daemon-owned marker end-tags remain in the template'
check "$T" 'proxy-groups:'                             'proxy-groups block present'
check "$T" 'name: Proxies'                             'default Proxies select group present'
check "$T" 'type: select'                               'Proxies group type: select'
check "$T" 'proxies: \[DIRECT\]'                        'Proxies group seeded with DIRECT only'
check "$T" '  - MATCH,Proxies'                          'terminal MATCH routes to the Proxies group'
nocheck "$T" 'MATCH,DIRECT'                             'no bare MATCH,DIRECT terminal (replaced by MATCH,Proxies)'
last_line="$(tail -1 "$root/$T")"
if [ "$last_line" = "  - MATCH,Proxies" ]; then
    echo "ok: MATCH,Proxies is the template's last line (single terminal rule)"
else
    echo "FAIL: template's last line is not the terminal MATCH,Proxies rule (got: $last_line)"
    FAIL=1
fi
# The seed template had a second copy in Go so the daemon could re-render it.
# There is no second copy now: etc/mihomo/config.yaml.tmpl is the only one, and
# install.sh is its only renderer. If a Go-side copy reappears anywhere, the
# two will drift and a mihomo-reset will produce a config the installer never
# validated.
if [ -e "$root/cmd" ]; then
    echo 'FAIL: a cmd/ tree came back; the seed template may have a second copy again'
    FAIL=1
else
    echo 'ok: the seed template has exactly one copy, rendered only by install.sh'
fi
nocheck cmd/5gpn-dns/policy_compile.go 'RULE-SET'                   'policy_compile.go no longer renders mihomo RULE-SET lines (DNS-only compiler)'
nocheck cmd/5gpn-dns/policy_compile.go 'type: file, behavior: domain' 'policy_compile.go no longer renders mihomo rule-provider stanzas'

check install.sh 'render_mihomo_config'                'installer renders config'
nocheck install.sh 'apply_.*_to_xray'                  'xray patchers removed'

# Task 4: the source allowlist was removed by owner decision. Nothing may
# reintroduce a management surface for it -- the ops, the live refresh, or
# the file they edited -- because the rule and the provider that gave it
# meaning are gone from the seed.
nocheck install.sh 'add_allow_ip' 'no allowlist add op'
nocheck install.sh 'del_allow_ip' 'no allowlist del op'
nocheck install.sh 'providers/rules/whitelist' 'no live allowlist refresh'
# Same exemption as in test_installer_safety: retire_mihomo_whitelist names the
# path in order to delete it. Everything else naming it is a survivor.
if [[ -n "$(awk '
    /^retire_mihomo_whitelist\(\)/ { skip = 1 }
    skip { if ($0 == "}") skip = 0; next }
    /[/]whitelist[.]txt/ { print }
' "$root/install.sh")" ]]; then
    echo "FAIL: installer builds a path to an allowlist file outside the retirement"; FAIL=1
else
    echo "ok: installer builds no allowlist path outside the retirement"
fi

# Task 5: selectable Cloudflare DNS-01 wildcard or HTTP-01 exact-SAN cert.
check install.sh 'dns-cloudflare' 'Cloudflare mode uses DNS-01'
check install.sh 'DNS_BASE_DOMAIN|BASE_DOMAIN' 'base-domain knob'
check install.sh '\*\.' 'Cloudflare cert includes wildcard *.base'
check install.sh 'standalone --preferred-challenges http-01' 'HTTP-01 mode uses the standalone challenge'
check install.sh 'run_http_certbot\(\)' 'HTTP-01 has a scoped mihomo stop/restore wrapper'
check scripts/cert-renew.sh 'DNS_RESOLVER=1\.1\.1\.1' 'HTTP renewal DNS gate uses 1.1.1.1'
check scripts/cert-renew.sh 'renew --cert-name "\$base"' 'renewal remains cert-name scoped'
nocheck install.sh 'systemctl stop xray' 'certificate issuance never stops xray'
nocheck scripts/cert-renew.sh 'xray' 'renewal helper never touches xray'
nocheck scripts/renew-hook.sh 'xray' 'renew-hook does not touch xray'
check install.sh 'set_cf_token' 'TUI op to set CF token'


# Task 10: lifecycle/management surface uses mihomo + transactional configure.
check install.sh 'configure\)' 'single transactional configure op'
check install.sh 'systemctl enable mihomo' 'lifecycle drives the one unit (enable/restart)'
nocheck install.sh 'for svc in .*xray' 'start/status service loop no longer includes xray'
nocheck install.sh 'systemctl restart xray' 'restart_services no longer restarts xray'
nocheck install.sh 'xray\.service|/usr/local/bin/xray' 'no old Xray teardown remains'

# Task A4: zashboard dist acquisition (pinned dist.zip download + wiring)
check install.sh '^install_ui\(\)' 'install_ui function exists'
# The shape, not the number. What matters is that the pin is one column-zero,
# double-quoted, uninterpolated literal naming a monolith tag -- not `latest`,
# not a variable, not something a caller can set. Asserting the exact version
# instead made every console release edit this file, which is churn that teaches
# the next person to bump the string without reading what it is for.
check install.sh '^ZASH_VERSION="v[0-9]+\.[0-9]+\.[0-9]+-monolith\.[0-9]+"' 'ZASH_VERSION is a fixed literal monolith pin'
nocheck install.sh '^ZASH_VERSION=.*(\$|`|latest)' 'ZASH_VERSION is neither interpolated nor a moving tag'
check install.sh 'ZASH_REPO="moooyo/zashboard"' 'zashboard comes from our fork'
check install.sh '\$\{ZASH_REPO\}/releases/download' 'zashboard download URL is parameterised by ZASH_REPO'
nocheck install.sh 'Zephyruso/zashboard/releases/download' 'no hardcoded upstream zashboard download remains'
# The bundle must be on disk before install_units starts the service: the unit
# names UI_DIR in ReadOnlyPaths with no `-` prefix, so an unpublished directory
# is not a missing panel, it is a unit that cannot enter its namespace.
if grep -A1 -E '^\s*install_ui(\s*\|\| return 1)?\s*$' "$root/install.sh" | grep -q 'install_units'; then
    echo "ok: full_install publishes the UI immediately before install_units"
else
    echo "FAIL: full_install publishes the UI immediately before install_units"; FAIL=1
fi
# UI cleanup is marker-gated; raw rm of the published path is banned.
check install.sh 'claim_ui_dir\(\)' 'UI ownership marker claim exists'
check install.sh 'remove_ui_dir\(\)' 'UI marker-gated removal exists'
nocheck install.sh 'rm -rf "\$UI_DIR"' 'no raw recursive deletion of UI_DIR'
# The role->account mapping must exist exactly once. It used to be two case
# statements -- one in the writer, one in the validator -- so moving DoT into the
# mihomo process changed one of them and produced a tree the other rejected.
check install.sh '^cert_role_group\(\)' 'certificate role ownership has one definition'
nocheck install.sh 'dot\|web\) group=' 'no second role->account mapping remains'
# Every `mihomo -t` the installer runs must see the SAFE_PATHS the unit grants.
# The seed names paths outside its own home -- the certificates and the UI
# bundle -- so a -t without them rejects a config the running service accepts,
# and a fresh install fails its own preflight on a correct config.
installer_safe="$(sed -n 's/^MIHOMO_SAFE_PATHS="\(.*\)"$/\1/p' "$root/install.sh")"
unit_safe="$(sed -n 's/^Environment=SAFE_PATHS=\(.*\)$/\1/p' "$root/etc/systemd/mihomo.service" | tr -d '\r')"
if [[ -n "$installer_safe" && "$installer_safe" == "$unit_safe" ]]; then
    echo "ok: installer and unit agree on SAFE_PATHS"
else
    echo "FAIL: SAFE_PATHS drifted (installer='$installer_safe' unit='$unit_safe')"; FAIL=1
fi
untested_t="$(grep -c '^[^#]*[^_]-t -f' "$root/install.sh" || true)"
guarded_t="$(grep -c 'SAFE_PATHS="\$MIHOMO_SAFE_PATHS"' "$root/install.sh" || true)"
if [[ "$untested_t" -gt 0 && "$guarded_t" -ge "$untested_t" ]]; then
    echo "ok: every mihomo -t carries the unit SAFE_PATHS"
else
    echo "FAIL: a mihomo -t runs without SAFE_PATHS ($guarded_t guarded of $untested_t)"; FAIL=1
fi
# The retired console origin must not come back with its own directory or listener.
nocheck install.sh 'install_web\(\)|DNS_WEB_DIR=|DNS_ZASH_LISTEN=' 'no second origin is published'
# The zashboard backend-seeding deep-link is C3 frontend scope, NOT the
# installer -- install.sh must only acquire+unzip the dist, never patch it in.
nocheck install.sh 'secondaryPath=/proxy' 'zashboard #/setup deep-link NOT hardcoded in install.sh (belongs to C3 frontend)'

# The allowlist sweep, over the whole tree rather than a list of files.
#
# Removing the allowlist touched install.sh, the template, six test files and
# the docs -- and still missed .github/workflows/checks.yml, which seeded a
# whitelist.txt and asserted the retired rule shape. CI caught it, which is one
# release later than the local suite should have.
#
# Two shapes are swept, chosen so the assertions that assert ABSENCE do not
# match themselves: a redirection that creates an allowlist file, and an actual
# rule line reading the retired provider. Prose about the removal, and the
# migration that performs it, name the string without being either shape.
#
# test_installer_safety.sh is exempt: it creates one on purpose, to prove
# retire_mihomo_whitelist deletes it. That is the same kind of exemption the
# zash sweep gives the migration -- the one caller allowed to name a thing is
# the one whose job is to get rid of it.
creators="$(grep -rn '> *"[^"]*whitelist\.txt"' \
    --include='*.sh' --include='*.yml' --include='*.tmpl' \
    "$root/install.sh" "$root/scripts" "$root/etc" "$root/tests" "$root/.github" 2>/dev/null \
    | grep -v '/tests/test_installer_safety.sh' || true)"
if [[ -n "$creators" ]]; then
    printf '%s\n' "$creators" >&2
    echo "FAIL: something still creates an allowlist file"; FAIL=1
else
    echo "ok: nothing creates an allowlist file"
fi
rules="$(grep -rn '^[[:space:]]*-[[:space:]]*AND,.*RULE-SET,[[:space:]]*whitelist' \
    --include='*.sh' --include='*.yml' --include='*.tmpl' --include='*.yaml' \
    "$root/install.sh" "$root/scripts" "$root/etc" "$root/.github" 2>/dev/null || true)"
if [[ -n "$rules" ]]; then
    printf '%s\n' "$rules" >&2
    echo "FAIL: a rule still reads the retired allowlist provider"; FAIL=1
else
    echo "ok: no rule reads the retired allowlist provider"
fi

echo "----"; [ "$FAIL" = 0 ] && echo "test_mihomo_policy: PASS" || { echo "test_mihomo_policy: FAIL"; exit 1; }
