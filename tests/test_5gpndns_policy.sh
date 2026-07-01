#!/usr/bin/env bash
# Policy assertions for the 5gpn-dns installer rollout (Task 8).
# Pure grep — runs on the dev box under Git Bash, no Linux/Python needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
RENEW="$ROOT/scripts/renew-hook.sh"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"
FIREWALL="$ROOT/scripts/setup-firewall.sh"
UPDATE_LISTS="$ROOT/scripts/update-lists.sh"
TGBOT="$ROOT/tgbot.py"

# --- install.sh: install_5gpndns function present ---
grep -Fq 'install_5gpndns'                  "$INSTALL" || fail "install.sh: no install_5gpndns function"
grep -Fq '5gpn-dns-linux-amd64'             "$INSTALL" || fail "install.sh: does not download 5gpn-dns-linux-amd64"
grep -Fq 'moooyo/5gpn'                      "$INSTALL" || fail "install.sh: release URL not from moooyo/5gpn"
grep -Fq 'DNS_VERSION'                      "$INSTALL" || fail "install.sh: no DNS_VERSION var"
grep -Fq 'DNS_SHA256'                       "$INSTALL" || fail "install.sh: no opt-in DNS_SHA256"

# --- etc/systemd/5gpn-dns.service: must exist with required directives ---
[ -f "$DNS_SVC" ] || fail "etc/systemd/5gpn-dns.service does not exist"
grep -Fq 'EnvironmentFile=/etc/5gpn/dns.env' "$DNS_SVC" || fail "5gpn-dns.service: no EnvironmentFile=/etc/5gpn/dns.env"
grep -Fq 'ExecStart=/usr/local/bin/5gpn-dns' "$DNS_SVC" || fail "5gpn-dns.service: no ExecStart=/usr/local/bin/5gpn-dns"
grep -Fq 'ExecReload=/bin/kill -HUP $MAINPID' "$DNS_SVC" || fail "5gpn-dns.service: no ExecReload=HUP"
grep -Fq 'NoNewPrivileges=yes'               "$DNS_SVC" || fail "5gpn-dns.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'              "$DNS_SVC" || fail "5gpn-dns.service: no ProtectSystem=strict"
grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$DNS_SVC" || fail "5gpn-dns.service: RestrictAddressFamilies not AF_INET AF_UNIX"

# --- install.sh: writes /etc/5gpn/dns.env and uses DNS_* vars ---
grep -Fq '/etc/5gpn/dns.env'    "$INSTALL" || fail "install.sh: does not write /etc/5gpn/dns.env"
grep -Fq 'DNS_GATEWAY_IP'       "$INSTALL" || fail "install.sh: no DNS_GATEWAY_IP in dns.env"
grep -Fq 'DNS_CHINA'            "$INSTALL" || fail "install.sh: no DNS_CHINA in dns.env"
grep -Fq 'DNS_TRUST'            "$INSTALL" || fail "install.sh: no DNS_TRUST in dns.env"
grep -Fq 'DNS_RULES_DIR'        "$INSTALL" || fail "install.sh: no DNS_RULES_DIR in dns.env"
grep -Fq 'DNS_CERT'             "$INSTALL" || fail "install.sh: no DNS_CERT in dns.env"
grep -Fq 'DNS_KEY'              "$INSTALL" || fail "install.sh: no DNS_KEY in dns.env"

# --- renewal / cert deploy path reloads 5gpn-dns (not smartdns) ---
grep -Fq 'systemctl reload 5gpn-dns'  "$RENEW" || fail "renew-hook.sh: does not reload 5gpn-dns"
grep -Fq '/etc/5gpn/cert'             "$RENEW" || fail "renew-hook.sh: certs not copied to /etc/5gpn/cert"
grep -Fq 'systemctl reload 5gpn-dns'  "$INSTALL" || fail "install.sh deploy hook: does not reload 5gpn-dns"
grep -Fq '/etc/5gpn/cert'             "$INSTALL" || fail "install.sh: does not copy certs to /etc/5gpn/cert"

# --- no lingering smartdns references in install.sh (migrate-off comment OK) ---
grep -Eq '^\s*install_smartdns\b'            "$INSTALL" \
    && fail "install.sh: still calls install_smartdns (not just disabled/removed)"
grep -Eq '^\s*install_smartdns_unit\b'       "$INSTALL" \
    && fail "install.sh: still calls install_smartdns_unit"
grep -Eq '^\s*(render_smartdns_conf|gen_foreign_cidr)' "$INSTALL" \
    && fail "install.sh: still references render_smartdns_conf/gen_foreign_cidr as a call"

# --- start_services / show_status: 5gpn-dns replaces smartdns ---
grep -Eq '"5gpn-dns"' "$INSTALL" || fail "install.sh: 5gpn-dns not in service list (start_services/show_status)"

# --- setup-firewall.sh: opens udp/tcp 53 + tcp 8443, keeps 853, rate-limits :53 ---
grep -Fq 'udp dport 53 accept'            "$FIREWALL" || fail "setup-firewall.sh: no 'udp dport 53 accept'"
grep -Eq 'tcp dport.*\b53\b'              "$FIREWALL" || fail "setup-firewall.sh: no tcp dport 53"
grep -Fq 'tcp dport 8443 accept'          "$FIREWALL" || fail "setup-firewall.sh: no 'tcp dport 8443 accept'"
grep -Fq '853'                            "$FIREWALL" || fail "setup-firewall.sh: DoT port 853 removed"
grep -Eq 'dns_rate4|dns_rate6'            "$FIREWALL" || fail "setup-firewall.sh: no dns_rate4/dns_rate6 rate meter for :53"
grep -Eq 'udp dport 53 meter dns_rate4'  "$FIREWALL" || fail "setup-firewall.sh: no UDP :53 per-source rate meter (dns_rate4)"
grep -Fq '5gpn-dns.service'              "$FIREWALL" || fail "setup-firewall.sh: does not install 5gpn-dns.service"

# --- update-lists.sh: repurposed (Phase 2) as a manual reload trigger; the in-process
# subscription manager now owns the china_ip_list/chnroute fetch, not this script ---
grep -Fq '/etc/5gpn/rules'               "$UPDATE_LISTS" || fail "update-lists.sh: no /etc/5gpn/rules path"
grep -Fq 'systemctl reload 5gpn-dns'     "$UPDATE_LISTS" || fail "update-lists.sh: does not reload 5gpn-dns"
grep -Fq 'gen_foreign_cidr'              "$UPDATE_LISTS" \
    && fail "update-lists.sh: still references gen_foreign_cidr (should be deleted)"
grep -Fq 'render_smartdns_conf'          "$UPDATE_LISTS" \
    && fail "update-lists.sh: still references render_smartdns_conf (should be deleted)"
grep -Fq 'foreign-cidr'                  "$UPDATE_LISTS" \
    && fail "update-lists.sh: still references foreign-cidr.txt (should be deleted)"
grep -Fq 'systemctl restart smartdns'    "$UPDATE_LISTS" \
    && fail "update-lists.sh: still restarts smartdns (should be deleted)"

# --- install.sh: Phase 2 subscriptions (rules subdirs, subscriptions.json, dns.env ref) ---
grep -Eq '\{adblock,direct,blacklist,chnroute\}' "$INSTALL" || fail "install.sh: does not create rules/{adblock,direct,blacklist,chnroute} subdirs"
grep -Fq 'subscriptions.json'    "$INSTALL" || fail "install.sh: does not write subscriptions.json"
grep -Fq 'DNS_SUBSCRIPTIONS'     "$INSTALL" || fail "install.sh: dns.env does not reference DNS_SUBSCRIPTIONS"

# --- 5gpn-dns.service: sandboxed conf-dir writes allowed under ProtectSystem=strict ---
# The subscription manager + control-plane API write rule caches under
# /etc/5gpn/rules AND rewrite /etc/5gpn/subscriptions.json (atomic temp+rename
# needs the dir writable), so the whole conf dir is RW with the secrets
# (dns.env, cert) re-protected read-only.
grep -Fq 'ReadWritePaths=/etc/5gpn' "$DNS_SVC" || fail "5gpn-dns.service: no ReadWritePaths=/etc/5gpn (subscriptions.json write path)"
grep -Fq 'ReadOnlyPaths=/etc/5gpn/dns.env' "$DNS_SVC" || fail "5gpn-dns.service: dns.env (token) not re-protected read-only"

# --- update-lists.sh: repurposed to a manual refresh trigger (reload only; subscription
# manager in 5gpn-dns now owns the chnroute fetch) ---
grep -Fq 'systemctl reload 5gpn-dns' "$UPDATE_LISTS" || fail "update-lists.sh: does not reload 5gpn-dns"
grep -Fq 'CHINA_IP_URL'              "$UPDATE_LISTS" \
    && fail "update-lists.sh: still fetches china_ip_list directly (should be subscription-owned)"
grep -Fq 'wget'                      "$UPDATE_LISTS" \
    && fail "update-lists.sh: still downloads lists directly (should be subscription-owned)"

# --- install.sh: fresh-install chnroute seed (Task 8 fix A) ---
# A truly fresh box must not crash-loop: the bundled etc/china_ip_list.txt
# snapshot is installed as the manual chnroute file (DNS_CHNROUTE target)
# before start_services, but only when no cache is already present (never
# clobber a fresher subscription-fetched cache on re-install/upgrade).
CHNROUTE_SEED="$ROOT/etc/china_ip_list.txt"
[ -f "$CHNROUTE_SEED" ] || fail "etc/china_ip_list.txt seed does not exist"
if [ -f "$CHNROUTE_SEED" ]; then
    seed_lines="$(grep -cvE '^[[:space:]]*(#|$)' "$CHNROUTE_SEED" 2>/dev/null | head -n1 || echo 0)"
    [ "${seed_lines:-0}" -ge 1000 ] || fail "etc/china_ip_list.txt seed has too few CIDR lines (${seed_lines:-0})"
fi
grep -Fq 'etc/china_ip_list.txt' "$INSTALL" || fail "install.sh: does not reference etc/china_ip_list.txt seed"
grep -Eq '\[\[ -s "\$\{DNS_RULES_DIR_DEFAULT\}/china_ip_list.txt" \]\]' "$INSTALL" \
    || fail "install.sh: does not guard chnroute seed install on cache absence (-s check)"

# --- tgbot.py: SERVICES has 5gpn-dns, no smartdns/xray ---
grep -Fq '"5gpn-dns"'   "$TGBOT" || fail "tgbot.py: SERVICES does not contain 5gpn-dns"
grep -Fq '"smartdns"'   "$TGBOT" \
    && fail "tgbot.py: SERVICES still contains smartdns"
grep -Fq 'xray'         "$TGBOT" \
    && fail "tgbot.py: contains live xray token (obsolete)"

# --- install.sh: Phase 3 Task 6 control-plane token + :9443 firewall gate ---
grep -Fq 'openssl rand'      "$INSTALL" || fail "install.sh: no token auto-gen (openssl rand)"
grep -Fq 'DNS_API_TOKEN'     "$INSTALL" || fail "install.sh: does not write DNS_API_TOKEN into dns.env"
grep -Fq 'DNS_LISTEN_API'    "$INSTALL" || fail "install.sh: does not write DNS_LISTEN_API into dns.env"
grep -Fq 'existing_token'    "$INSTALL" || fail "install.sh: does not preserve an existing token across re-install"

grep -Fq 'ip saddr ${CLIENT_NET} tcp dport 9443 accept' "$FIREWALL" \
    || fail "setup-firewall.sh: no CLIENT_NET-scoped :9443 accept rule"
grep -Eq 'tcp_ports=.*9443' "$FIREWALL" \
    && fail "setup-firewall.sh: :9443 must not be in the public tcp_ports set"
grep -Eq '^\s*tcp dport 9443 accept' "$FIREWALL" \
    && fail "setup-firewall.sh: :9443 must be CLIENT_NET-only, not a bare public accept"

[ $rc -eq 0 ] && echo "5gpn-dns policy: PASS"
exit $rc
