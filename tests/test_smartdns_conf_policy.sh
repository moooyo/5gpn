#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
rc=0
fail(){ echo "FAIL: $1"; rc=1; }

python3 "$ROOT/scripts/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$OUT" \
    GATEWAY_IP=203.0.113.7 \
    BIND_CERT=/etc/smartdns/cert/fullchain.pem \
    BIND_KEY=/etc/smartdns/cert/privkey.pem \
    PROXY_DOMAINS_FILE=/etc/smartdns/proxy-domains.txt \
    FOREIGN_CIDR_FILE=/etc/smartdns/foreign-cidr.txt \
    CHINA_DOMAINS_FILE=/etc/smartdns/china-domains.txt \
    CHINA_IP_FILE=/etc/smartdns/china_ip.conf \
    BOGUS_NXDOMAIN_FILE=/etc/smartdns/bogus-nxdomain.conf \
    CACHE_SIZE=20000 || fail "render failed"

grep -Eq '^bind-tls .*:853'                                 "$OUT" || fail "no DoT bind on 853"
grep -Eq '^bind-cert-file /etc/smartdns/cert/fullchain.pem' "$OUT" || fail "no bind-cert-file"
grep -Eq '^bind-cert-key-file /etc/smartdns/cert/privkey.pem' "$OUT" || fail "no bind-cert-key-file"
grep -Eq '^force-AAAA-SOA yes'                              "$OUT" || fail "AAAA not disabled"
grep -Eq '^speed-check-mode none'                           "$OUT" || fail "speed-check-mode not none"
grep -Eq 'response-mode +first-ping'                        "$OUT" && fail "first-ping speed test must be gone"
# tier 1
grep -Eq '^domain-set -name blacklist'                     "$OUT" || fail "no blacklist domain-set"
grep -Eq '^address /domain-set:blacklist/203\.0\.113\.7'   "$OUT" || fail "no blacklist address->gateway"
# tier 2
grep -Eq '^domain-set -name cnlist'                        "$OUT" || fail "no cnlist domain-set"
grep -Eq '^nameserver /domain-set:cnlist/domestic'         "$OUT" || fail "no cnlist->domestic nameserver"
# tier 3
grep -Eq '^ip-set -name china_ip'                          "$OUT" || fail "no china_ip ip-set"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip'         "$OUT" || fail "no china_ip prefer-CN rule"
grep -Eq '^ip-set -name foreign'                           "$OUT" || fail "no foreign ip-set"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$OUT" || fail "no ip-alias foreign->gateway"
# groups
grep -Eq '^server 223\.5\.5\.5 .*-group domestic'          "$OUT" || fail "domestic group missing"
grep -Eq '^server-tls 8\.8\.8\.8 .*-group foreign'         "$OUT" || fail "foreign group missing"
# includes / safety
grep -Eq '^conf-file /etc/smartdns/bogus-nxdomain\.conf'   "$OUT" || fail "bogus-nxdomain include missing"
grep -Eq '^bind (\[::\]|0\.0\.0\.0):53'                    "$OUT" && fail "public plaintext :53 must not exist"
grep -Eq '__[A-Z_]+__'                                     "$OUT" && fail "unresolved placeholder remains"

# --- update-lists.sh dry-run end-to-end (no network, no restart) ---
TMPDIR2="$(mktemp -d)"; trap 'rm -f "$OUT"; rm -rf "$TMPDIR2"' EXIT
python3 - "$TMPDIR2/china_ip_list.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(150):
        f.write("%d.0.0.0/8\n" % (i % 223))
PY
printf '# empty\n' > "$TMPDIR2/proxy-domains.txt"
printf 'example.cn\nqq.com\n' > "$TMPDIR2/china-domains.txt"   # dry-run skips download; seed it
DRY_RUN=1 SMARTDNS_DIR="$TMPDIR2" GATEWAY_IP=203.0.113.7 \
    bash "$ROOT/scripts/update-lists.sh" >/dev/null 2>&1 || fail "update-lists dry-run failed"
[ -s "$TMPDIR2/foreign-cidr.txt" ] || fail "foreign-cidr.txt not generated"
[ -s "$TMPDIR2/china_ip.conf" ]    || fail "china_ip.conf not generated"
[ -f "$TMPDIR2/china-domains.txt" ] || fail "china-domains.txt missing"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip' "$TMPDIR2/smartdns.conf" || fail "rendered conf missing china_ip rule"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$TMPDIR2/smartdns.conf" || fail "rendered conf missing ip-alias"

[ $rc -eq 0 ] && echo "smartdns conf policy: PASS"
exit $rc
