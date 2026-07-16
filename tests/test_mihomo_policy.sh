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
check etc/systemd/mihomo.service 'ExecStart=/usr/local/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' 'mihomo ExecStart'
check etc/systemd/mihomo.service 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' 'mihomo AF set incl AF_NETLINK (required for QUIC/UDP DIRECT dial)'
check etc/systemd/mihomo.service 'ReadWritePaths=/etc/5gpn/mihomo' 'mihomo writes provider caches'
check etc/systemd/mihomo.service 'Environment=SAFE_PATHS=/etc/5gpn/cert/zash' 'mihomo SAFE_PATHS scoped to the shared zash controller cert'
check install.sh 'mihomo\.service' 'install_units installs mihomo.service'

# Task 3: mihomo config template shape
T=etc/mihomo/config.yaml.tmpl
check "$T" '__MIHOMO_LISTENERS__'                      'dynamic local-listener placeholder'
check "$T" 'external-controller: ""'                   'plaintext controller disabled in seed'
check "$T" 'external-controller-tls: 127\.0\.0\.1:9090' 'TLS controller loopback listener'
check "$T" 'certificate: /etc/5gpn/cert/zash/fullchain\.pem' 'controller TLS certificate key pinned'
check "$T" 'private-key: /etc/5gpn/cert/zash/privkey\.pem'   'controller TLS private-key key pinned'
nocheck install.sh 'http://127\.0\.0\.1:9090'           'installer no longer calls the plaintext mihomo controller'
check install.sh 'render_mihomo_listeners\(\)'          'dynamic listener renderer'
check install.sh 'type: tunnel.*port: 443.*network: \[tcp, udp\]' ':443 tcp+udp listener renderer'
check install.sh 'target: 127\.0\.0\.1:443'             'listener renderer loopback target'
nocheck "$T" 'proxy:'                                  'NO proxy field on listeners (would bypass rules)'
check "$T" 'parse-pure-ip: true'                       'sniffer parse-pure-ip'
check "$T" 'override-destination: true'                'sniffer override-destination'
check "$T" 'rule-providers:'                           'rule-providers block'
check "$T" 'whitelist:'                                'whitelist rule-provider'
check "$T" 'behavior: ipcidr'                          'whitelist ipcidr behavior'
check "$T" 'format: text'                              'whitelist provider uses text format'
check "$T" 'RULE-SET,whitelist,DIRECT,src'             'source-IP allowlist rule'
check "$T" 'REJECT-DROP'                               'silent deny for non-allowlisted'
check "$T" '127\.0\.0\.1:5354'                         'DNS broker → egress resolver'
check "$T" '__PROFILE_DOMAIN__: 127\.0\.0\.1'           'profile SNI loopback host mapping'
check "$T" 'DOMAIN,__PROFILE_DOMAIN__,DIRECT'            'profile SNI bypasses panel whitelist'
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

# Task 5: Cloudflare DNS-01 wildcard cert (replace http-01/:80)
check install.sh 'dns-cloudflare' 'certbot uses Cloudflare DNS-01'
check install.sh 'DNS_BASE_DOMAIN|BASE_DOMAIN' 'base-domain knob'
check install.sh '\*\.' 'wildcard cert (certbot -d "*.${base}")'
nocheck install.sh 'systemctl stop xray' 'no stop-xray-for-:80 dance'
nocheck scripts/renew-hook.sh 'xray' 'renew-hook does not touch xray'
check install.sh 'set_cf_token' 'TUI op to set CF token'

# Task 9: bot manages mihomo, not xray (daemon no longer actively drives xray
# at runtime either -- see test_5gpndns_policy.sh's botServices assertion).
check cmd/5gpn-dns/bot.go '"mihomo"' 'bot manages mihomo'
nocheck cmd/5gpn-dns/bot.go '"xray"' 'bot no longer manages xray'

# Task 10: lifecycle/management surface swept to mihomo + single base-domain op.
check install.sh 'change_base_domain\(\)|change-base-domain' 'single base-domain change op'
check install.sh 'for svc in mihomo 5gpn-dns|systemctl enable "\$svc"' 'lifecycle drives mihomo (enable/restart)'
# SCOPED negatives (NOT a broad nocheck 'xray' -- legacy teardown needs it): the
# ACTIVE service loops (start_services/show_status) and restart_services must no
# longer name xray.
nocheck install.sh 'for svc in .*xray' 'start/status service loop no longer includes xray'
nocheck install.sh 'systemctl restart xray' 'restart_services no longer restarts xray'
# Legacy xray teardown MUST remain (a box upgrading FROM xray needs it removed,
# else old xray keeps holding :443/:80 and mihomo can never bind).
check install.sh 'xray\.service' 'legacy xray.service still torn down (clean/uninstall)'
check install.sh '/usr/local/bin/xray' 'legacy /usr/local/bin/xray still removed on uninstall'

# Task A4: zashboard dist acquisition (pinned dist.zip download + wiring)
check install.sh 'install_zashboard\(\)' 'install_zashboard function exists'
check install.sh 'ZASH_VERSION="\$\{ZASH_VERSION:-v3\.15\.0\}"' 'ZASH_VERSION default pin'
check install.sh 'Zephyruso/zashboard/releases/download' 'downloads zashboard from Zephyruso/zashboard'
if grep -A1 -E '^\s*install_web\s*$' "$root/install.sh" | grep -q 'install_zashboard'; then
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
