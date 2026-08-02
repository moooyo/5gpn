#!/usr/bin/env bash
# What the installer still owes the resolver: dns.env, and the things that must
# not come back into it.
#
# The file keeps its name because that is what it grew from -- the policy suite
# for a daemon called 5gpn-dns -- but the daemon, its unit, its Go source, its
# API routes and its bot are all gone, and with them roughly two thirds of what
# was here. Those assertions were not weakened, they moved: the resolver's own
# behaviour is tested in gpn/dns in the fork, where the code is.
#
# What is left is the half that was always about this repository. dns.env is
# the resolver's entire configuration surface and install.sh is its only
# writer, so the schema, the token handling, the listener pins, and the
# subscriptions seed are still this suite's to hold. So are the negative
# assertions -- a retired key or a resurrected xray-era path reappearing in the
# writer is exactly the regression a grep suite is good at catching.
#
# Pure grep — runs on the dev box under Git Bash, no Linux/Python needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
RENEW="$ROOT/scripts/renew-hook.sh"

grep -Fq 'moooyo/5gpn'                      "$INSTALL" || fail "install.sh: release URL not from moooyo/5gpn"

# --- install.sh: writes /etc/5gpn/dns.env and uses DNS_* vars ---
grep -Fq '/etc/5gpn/dns.env'    "$INSTALL" || fail "install.sh: does not write /etc/5gpn/dns.env"
grep -Fq 'DNS_GATEWAY_IP'       "$INSTALL" || fail "install.sh: no DNS_GATEWAY_IP in dns.env"
grep -Fq 'DNS_CHINA'            "$INSTALL" || fail "install.sh: no DNS_CHINA in dns.env"
grep -Fq 'DNS_TRUST'            "$INSTALL" || fail "install.sh: no DNS_TRUST in dns.env"
grep -Fq 'DNS_RULES_DIR'        "$INSTALL" || fail "install.sh: no DNS_RULES_DIR in dns.env"
grep -Fq 'DNS_CERT'             "$INSTALL" || fail "install.sh: no DNS_CERT in dns.env"
grep -Fq 'DNS_KEY'              "$INSTALL" || fail "install.sh: no DNS_KEY in dns.env"

# --- renewal publishes cert files; SIGHUP remains rules/chnroute-only ---
grep -Fq '/etc/5gpn/cert'             "$RENEW" || fail "renew-hook.sh: certs not copied to /etc/5gpn/cert"
grep -Eq 'systemctl reload 5gpn-dns|kill -HUP' "$RENEW" \
    && fail "renew-hook.sh: certificate publication must not misuse the rules-only SIGHUP API"
grep -Fq '/etc/5gpn/cert'             "$INSTALL" || fail "install.sh: does not copy certs to /etc/5gpn/cert"

# --- no smartdns implementation in install.sh ---
grep -Eq '^\s*install_smartdns\b'            "$INSTALL" \
    && fail "install.sh: still calls install_smartdns (not just disabled/removed)"
grep -Eq '^\s*install_smartdns_unit\b'       "$INSTALL" \
    && fail "install.sh: still calls install_smartdns_unit"
grep -Eq '^\s*(render_smartdns_conf|gen_foreign_cidr)' "$INSTALL" \
    && fail "install.sh: still references render_smartdns_conf/gen_foreign_cidr as a call"

# --- DoT-only ingress (2026-07-10): no DoH/plain-53 listeners, no host firewall ---
[ -e "$ROOT/scripts/setup-firewall.sh" ] && fail "scripts/setup-firewall.sh must stay removed (no host firewall management)"
grep -Eq '^DNS_LISTEN_DOH='   "$INSTALL" && fail "install.sh: dns.env must not emit DNS_LISTEN_DOH (DoH removed)"
grep -Eq '^DNS_LISTEN_PLAIN=' "$INSTALL" && fail "install.sh: dns.env must not emit DNS_LISTEN_PLAIN (plain :53 removed)"
grep -Fq 'DNS_LISTEN_DOT=:853' "$INSTALL" || fail "install.sh: dns.env must pin the DoT listener :853"
grep -Fq 'install_units'       "$INSTALL" || fail "install.sh: no install_units (unit install moved out of the removed setup-firewall.sh)"
grep -Eq '(^|[[:space:]])nft([[:space:]]|$)' "$INSTALL" && fail "install.sh: must not manage host nftables"

# --- install.sh: stages etc/systemd into the installed tree (install_units
# falls back to it on a piped curl|bash install with no checkout) ---
grep -Fq '${BASE_DIR}/etc/systemd' "$INSTALL" || fail "install.sh: install_files does not stage etc/systemd into /opt/5gpn"
grep -Fq 'mihomo.service' "$INSTALL" || fail "install.sh: install_units does not install mihomo.service"
grep -Fq '${BASE_DIR}/etc/mihomo' "$INSTALL" || fail "install.sh: installed management runtime has no mihomo asset directory"
grep -Fq 'config.yaml.tmpl whitelist.seed.txt' "$INSTALL" \
    || fail "install.sh: installed management runtime does not retain every mihomo reset asset"

# --- install.sh: control-plane token + loopback :443 pin ---
grep -Fq 'openssl rand'      "$INSTALL" || fail "install.sh: no token auto-gen (openssl rand)"
grep -Fq 'DNS_API_TOKEN'     "$INSTALL" || fail "install.sh: does not write DNS_API_TOKEN into dns.env"
grep -Fq 'DNS_LISTEN_API=127.0.0.1:443' "$INSTALL" \
    || fail "install.sh: dns.env must pin the control plane to 127.0.0.1:443 (webui behind the mihomo SNI split)"
grep -Fq 'DNS_LISTEN_API=:9443' "$INSTALL" \
    && fail "install.sh: the old :9443 control-plane port must not come back"
grep -Fq 'DNS_LISTEN_API=:18443' "$INSTALL" \
    && fail "install.sh: the old xray-era :18443 control-plane port must not come back"
grep -Fq 'existing_token'    "$INSTALL" || fail "install.sh: does not preserve an existing token across re-install"

grep -Fq 'DNS_EGRESS_BROKER=127.0.0.1:5354' "$ROOT/etc/5gpn-dns/dns.env.example" \
    || fail "dns.env.example: DNS_EGRESS_BROKER not documented with default 127.0.0.1:5354"

INSTALL_SH="$ROOT/install.sh"
grep -Fq 'Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER' "$INSTALL_SH" \
    || fail "install.sh: retired DNS_EGRESS_RESOLVER is not rejected explicitly"
grep -Eq '^[[:space:]]*DNS_EGRESS_RESOLVER=' "$INSTALL_SH" \
    && fail "install.sh: retired DNS_EGRESS_RESOLVER is still persisted"
grep -Fq 'XRAY_RESOLVER' "$INSTALL_SH" \
    && fail "install.sh: removed XRAY_RESOLVER key remains"

grep -Fq '${CONF_DIR}/policy.json' "$INSTALL" || fail "install.sh: does not seed /etc/5gpn/policy.json"

# No superseded policy/egress state helper or path remains.
grep -Fq 'remove_legacy_policy_state' "$INSTALL" \
    && fail "install.sh: old policy-state migration helper remains"
grep -Eq 'egress(-nodes)?\.(json|enc)' "$INSTALL" \
    && fail "install.sh: removed structured-egress state path remains"


# chnroute STAYS in subscriptions.json (system arbitration input, NOT a policy rule)
grep -Fq '"category": "chnroute"' "$INSTALL" || fail "install.sh: chnroute subscription must stay in subscriptions.json"
grep -Fq 'china_ip_list'          "$INSTALL" || fail "install.sh: china_ip_list chnroute source must stay"

# Policy-owned subscriptions stay in policy.json rather than subscriptions.json.
grep -Fq '"category": "block"'   "$INSTALL" && fail "install.sh: block subscription must move to policy.json"
grep -Fq '"category": "proxy"'     "$INSTALL" && fail "install.sh: proxy(gfw) subscription must move to policy.json"
grep -Fq '"category": "direct"'    "$INSTALL" && fail "install.sh: direct(china-list) subscription must move to policy.json"

# Current cache directories use the block/direct/proxy vocabulary; there is no
# shell-managed category file.
grep -Fq '"${DNS_RULES_DIR_DEFAULT}"/{block,direct,proxy,chnroute}' "$INSTALL" \
    || fail "install.sh: current subscription cache directories are incomplete"
grep -Eq '(block|direct|proxy|blacklist)(\.keyword|\.prefix|\.suffix)?\.txt' "$INSTALL" \
    && fail "install.sh: shell-managed DNS category file remains"
grep -Fq 'blacklist' "$INSTALL" && fail "install.sh: removed blacklist category remains"

true  # ensure the block's last command never sets rc via a && short-circuit

[ $rc -eq 0 ] && echo "5gpn-dns policy: PASS"
exit $rc
