#!/usr/bin/env bash
# Pure grep — runs on the dev box under Git Bash and in CI.
# Asserts the three-tier DNS split shape in the raw template + update-lists pipeline.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

T="$ROOT/etc/smartdns.conf.template"
U="$ROOT/scripts/update-lists.sh"

# --- groups: domestic + foreign, BOTH in default (no -exclude-default-group) ---
grep -Eq '^server 223\.5\.5\.5 .*-group domestic'   "$T" || fail "domestic group missing"
grep -Eq '^server-tls 8\.8\.8\.8 .*-group foreign'  "$T" || fail "foreign group missing"
grep -Eq 'exclude-default-group'                    "$T" && fail "groups must stay in default (no -exclude-default-group)"
# --- tier 1 blacklist: address -> gateway (no resolution) ---
grep -Eq '^domain-set -name blacklist .*__PROXY_DOMAINS_FILE__' "$T" || fail "blacklist domain-set missing"
grep -Eq '^address /domain-set:blacklist/__GATEWAY_IP__'        "$T" || fail "blacklist address->gateway missing"
# --- tier 2 whitelist: cnlist -> domestic only ---
grep -Eq '^domain-set -name cnlist .*__CHINA_DOMAINS_FILE__'    "$T" || fail "cnlist domain-set missing"
grep -Eq '^nameserver /domain-set:cnlist/domestic'             "$T" || fail "cnlist -> domestic nameserver missing"
# --- tier 3: prefer-CN content filter (no speed test) + foreign ip-alias ---
grep -Eq '^ip-set -name china_ip .*__CHINA_IP_FILE__'          "$T" || fail "china_ip ip-set missing"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip'            "$T" || fail "china_ip prefer-CN whitelist rule missing"
grep -Eq '^ip-set -name foreign .*__FOREIGN_CIDR_FILE__'      "$T" || fail "foreign ip-set missing"
grep -Eq '^ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__'  "$T" || fail "foreign ip-alias missing"
grep -Eq '^speed-check-mode none'                            "$T" || fail "speed-check-mode must be none (no latency test)"
grep -Eq 'response-mode +first-ping'                         "$T" && fail "response-mode first-ping must be removed"
# --- DoT only; no public plaintext :53; no stale xray ---
grep -Eq '^bind-tls .*:853'                                  "$T" || fail "DoT :853 bind missing"
grep -Eq '^bind(-tls)? (\[::\]|0\.0\.0\.0):53'               "$T" && fail "no public :53 bind allowed"
grep -Eq 'xray'                                              "$T" && fail "stale xray reference in template"
# --- update-lists generates the new lists; drops china-whitelist ---
grep -Eq 'china-domains\.txt'    "$U" || fail "update-lists must generate china-domains.txt"
grep -Eq 'china_ip\.conf'        "$U" || fail "update-lists must generate china_ip.conf"
grep -Eq 'CHINA_DOMAINS_FILE='   "$U" || fail "update-lists must pass CHINA_DOMAINS_FILE to render"
grep -Eq 'CHINA_IP_FILE='        "$U" || fail "update-lists must pass CHINA_IP_FILE to render"
grep -Eq 'CHINA_WHITELIST_FILE=' "$U" && fail "CHINA_WHITELIST_FILE removed (replaced by china_ip ip-set)"
# --- dualstack-ip-selection must be disabled (no IPv6 preference interference) ---
grep -Eq '^dualstack-ip-selection no' "$T" || fail "dualstack-ip-selection must be no"
# --- install.sh must reference DOT_RATE/DOT_BURST (forward/help) ---
I="$ROOT/install.sh"
grep -Eq 'DOT_RATE'  "$I" || fail "install.sh must reference DOT_RATE (forward/help)"
grep -Eq 'DOT_BURST' "$I" || fail "install.sh must reference DOT_BURST (forward/help)"

[ $rc -eq 0 ] && echo "dns split policy: PASS"
exit $rc
