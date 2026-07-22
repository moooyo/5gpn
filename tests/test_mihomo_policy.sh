#!/usr/bin/env bash
# Asserts the mihomo data-plane install/config/unit shape (replaces test_proxy_policy.sh).
set -u
FAIL=0
root="$(cd "$(dirname "$0")/.." && pwd)"
check() { if grep -qE "$2" "$root/$1"; then echo "ok: $3"; else echo "FAIL: $3 ($1 !~ $2)"; FAIL=1; fi; }
nocheck() { if grep -qE "$2" "$root/$1"; then echo "FAIL: $3 ($1 =~ $2)"; FAIL=1; else echo "ok: $3"; fi; }

# Task 1: mihomo binary install
check install.sh 'install_mihomo\(\)' 'install_mihomo function exists'
check install.sh 'MetaCubeX/mihomo/releases' 'downloads mihomo from MetaCubeX'
check install.sh 'mihomo-linux-amd64-compatible' 'uses amd64-compatible asset'
check install.sh 'MIHOMO_VERSION' 'mihomo version pin knob'
nocheck install.sh 'install_xray\(\)' 'install_xray removed'

# Task 2: mihomo unit
check etc/systemd/mihomo.service 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' 'project-private mihomo ExecStart'
check etc/systemd/mihomo.service 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' 'mihomo AF set incl AF_NETLINK (required for QUIC/UDP DIRECT dial)'
check etc/systemd/mihomo.service 'ReadWritePaths=/etc/5gpn/mihomo' 'mihomo writes provider caches'
check etc/systemd/mihomo.service 'Environment=SAFE_PATHS=/etc/5gpn/cert/zash' 'mihomo SAFE_PATHS scoped to the shared zash controller cert'
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
check "$T" 'external-controller-tls: 127\.0\.0\.1:9090' 'TLS controller loopback listener'
check "$T" 'certificate: /etc/5gpn/cert/zash/current/fullchain\.pem' 'controller TLS certificate key pinned'
check "$T" 'private-key: /etc/5gpn/cert/zash/current/privkey\.pem'   'controller TLS private-key key pinned'
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
check "$T" 'DOMAIN,__ZASH_DOMAIN__.*DST-PORT,8080.*REJECT' 'zash cannot expose loopback :8080'
check "$T" 'DOMAIN,__ZASH_DOMAIN__.*DST-PORT,8443.*REJECT' 'zash cannot expose loopback :8443'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__.*DST-PORT,5060.*REJECT' 'console cannot expose loopback :5060'
check "$T" 'DOMAIN,__ZASH_DOMAIN__.*DST-PORT,5060.*REJECT' 'zash cannot expose loopback :5060'
check "$T" 'rule-providers:'                           'rule-providers block'
check "$T" 'whitelist:'                                'whitelist rule-provider'
check "$T" 'behavior: ipcidr'                          'whitelist ipcidr behavior'
check "$T" 'format: text'                              'whitelist provider uses text format'
check "$T" 'RULE-SET,whitelist,DIRECT,src'             'source-IP allowlist rule'
check "$T" 'DOMAIN,__ZASH_DOMAIN__,REJECT'              'fast deny for non-allowlisted zashboard traffic'
nocheck "$T" 'REJECT-DROP'                             'seed avoids connection-retaining reject rules'
check "$T" '127\.0\.0\.1:5354'                         'loopback origin DNS selector'
check "$T" 'AND,\(\(DOMAIN,__CONSOLE_DOMAIN__\),\(NETWORK,UDP\)\),REJECT' 'console UDP fallback fast-reject rule'
check "$T" 'AND,\(\(DOMAIN,__CONSOLE_DOMAIN__\),\(DST-PORT,80\)\),REJECT' 'console HTTP fast-reject rule'
check "$T" 'DOMAIN,__CONSOLE_DOMAIN__,DIRECT'             'public console SNI direct route'
check "$T" 'AND,\(\(DOMAIN,__ZASH_DOMAIN__\),\(NETWORK,UDP\)\),REJECT' 'zashboard UDP fast-reject rule'
check "$T" 'AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT' 'HTTP3/QUIC UDP 443 block enabled by default'
egress_guard_line="$(grep -nF '  - IN-NAME,intercept-egress,REJECT' "$root/$T" | cut -d: -f1 || true)"
quic_block_line="$(grep -nF '  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT' "$root/$T" | cut -d: -f1 || true)"
match_line="$(grep -nF '  - MATCH,Proxies' "$root/$T" | cut -d: -f1 || true)"
if [ -n "$egress_guard_line" ] && [ -n "$quic_block_line" ] && [ -n "$match_line" ] \
   && [ "$egress_guard_line" -lt "$quic_block_line" ] && [ "$quic_block_line" -lt "$match_line" ]; then
    echo 'ok: QUIC block follows sidecar fail-closed egress guard and precedes terminal policy'
else
    echo 'FAIL: QUIC block ordering is unsafe'
    FAIL=1
fi
console_direct_line="$(grep -nF '  - DOMAIN,__CONSOLE_DOMAIN__,DIRECT' "$root/$T" | cut -d: -f1 || true)"
zash_direct_line="$(grep -nF '  - AND,((DOMAIN,__ZASH_DOMAIN__),(RULE-SET,whitelist,DIRECT,src)),DIRECT' "$root/$T" | cut -d: -f1 || true)"
panel_order_ok=1
for rule in \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(NETWORK,UDP)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,80)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8080)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8443)),REJECT' \
    'AND,((DOMAIN,__ZASH_DOMAIN__),(NETWORK,UDP)),REJECT' \
    'AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,80)),REJECT' \
    'AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,8080)),REJECT' \
    'AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,8443)),REJECT' \
    'AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,5060)),REJECT' \
    'AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,5060)),REJECT'; do
    reject_line="$(grep -nF "  - $rule" "$root/$T" | cut -d: -f1 || true)"
    route_line="$zash_direct_line"
    [[ "$rule" == *'__CONSOLE_DOMAIN__'* ]] && route_line="$console_direct_line"
    if [ -z "$reject_line" ] || [ -z "$route_line" ] || [ "$reject_line" -ge "$route_line" ]; then
        panel_order_ok=0
    fi
done
zash_deny_line="$(grep -nF '  - DOMAIN,__ZASH_DOMAIN__,REJECT' "$root/$T" | cut -d: -f1 || true)"
anti_loop_line="$(grep -nF '  - IP-CIDR,__GATEWAY_IP__/32,REJECT,no-resolve' "$root/$T" | cut -d: -f1 || true)"
if [ "$panel_order_ok" = 1 ] && [ -n "$zash_deny_line" ] && [ -n "$anti_loop_line" ] \
    && [ "$zash_deny_line" -lt "$anti_loop_line" ]; then
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
check cmd/5gpn-dns/mihomo_config.go 'mihomoConfigSeedTemplate = ' 'mihomo_config.go carries the Go-side copy of the seed template'
nocheck cmd/5gpn-dns/mihomo_config.go '>>>5gpn'        'Go copy of the seed template also carries no marker regions'
nocheck cmd/5gpn-dns/policy_compile.go 'RULE-SET'                   'policy_compile.go no longer renders mihomo RULE-SET lines (DNS-only compiler)'
nocheck cmd/5gpn-dns/policy_compile.go 'type: file, behavior: domain' 'policy_compile.go no longer renders mihomo rule-provider stanzas'

check install.sh 'render_mihomo_config'                'installer renders config'
nocheck install.sh 'apply_.*_to_xray'                  'xray patchers removed'

# Task 4: whitelist TUI management + live refresh (no full config reload)
check install.sh 'add_allow_ip\(\)' 'whitelist add op'
check install.sh 'del_allow_ip\(\)' 'whitelist del op'
check install.sh 'providers/rules/whitelist' 'live whitelist refresh via controller'
check install.sh 'whitelist' 'manage_menu exposes whitelist' # ensure a menu label

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

# Task 9: bot manages mihomo, not xray (daemon no longer actively drives xray
# at runtime either -- see test_5gpndns_policy.sh's botServices assertion).
check cmd/5gpn-dns/bot.go '"mihomo"' 'bot manages mihomo'
nocheck cmd/5gpn-dns/bot.go '"xray"' 'bot no longer manages xray'

# Task 10: lifecycle/management surface uses mihomo + transactional configure.
check install.sh 'configure\)' 'single transactional configure op'
check install.sh 'for svc in mihomo 5gpn-dns|systemctl enable "\$svc"' 'lifecycle drives mihomo (enable/restart)'
nocheck install.sh 'for svc in .*xray' 'start/status service loop no longer includes xray'
nocheck install.sh 'systemctl restart xray' 'restart_services no longer restarts xray'
nocheck install.sh 'xray\.service|/usr/local/bin/xray' 'no old Xray teardown remains'

# Task A4: zashboard dist acquisition (pinned dist.zip download + wiring)
check install.sh 'install_zashboard\(\)' 'install_zashboard function exists'
check install.sh 'ZASH_VERSION="v3\.15\.0"' 'ZASH_VERSION fixed pin'
check install.sh 'Zephyruso/zashboard/releases/download' 'downloads zashboard from Zephyruso/zashboard'
if grep -A1 -E '^\s*install_web(\s*\|\| return 1)?\s*$' "$root/install.sh" | grep -q 'install_zashboard'; then
    echo "ok: full_install calls install_zashboard right after install_web"
else
    echo "FAIL: full_install calls install_zashboard right after install_web"; FAIL=1
fi
# Custom DNS_ZASH_DIR cleanup is marker-gated; raw rm of the env path is banned.
check install.sh 'claim_zashboard_dir\(\)' 'zashboard ownership marker claim exists'
check install.sh 'clear_zashboard_dir\(\)' 'zashboard marker-gated clear exists'
check install.sh 'remove_zashboard_dir\(\)' 'zashboard marker-gated uninstall exists'
nocheck install.sh 'rm -rf "\$DNS_ZASH_DIR"' 'no raw recursive deletion of DNS_ZASH_DIR'
# The zashboard backend-seeding deep-link is C3 frontend scope, NOT the
# installer -- install.sh must only acquire+unzip the dist, never patch it in.
nocheck install.sh 'secondaryPath=/proxy' 'zashboard #/setup deep-link NOT hardcoded in install.sh (belongs to C3 frontend)'

echo "----"; [ "$FAIL" = 0 ] && echo "test_mihomo_policy: PASS" || { echo "test_mihomo_policy: FAIL"; exit 1; }
