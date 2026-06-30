#!/usr/bin/env bash
# Policy assertions for the 5gpn-dns installer rollout (Task 8).
# Pure grep — runs on the dev box under Git Bash, no Linux/Python needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
RENEW="$ROOT/scripts/renew-hook.sh"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"

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

[ $rc -eq 0 ] && echo "5gpn-dns policy: PASS"
exit $rc
