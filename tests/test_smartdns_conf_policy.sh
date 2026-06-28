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
    CHINA_WHITELIST_FILE=/etc/smartdns/china-whitelist.conf \
    BOGUS_NXDOMAIN_FILE=/etc/smartdns/bogus-nxdomain.conf \
    CACHE_SIZE=20000 || fail "render failed"

grep -Eq '^bind-tls .*:853'                                "$OUT" || fail "no DoT bind on 853"
grep -Eq '^bind-cert-file /etc/smartdns/cert/fullchain.pem' "$OUT" || fail "no bind-cert-file"
grep -Eq '^bind-cert-key-file /etc/smartdns/cert/privkey.pem' "$OUT" || fail "no bind-cert-key-file"
grep -Eq '^force-AAAA-SOA yes'                             "$OUT" || fail "AAAA not disabled"
grep -Eq '^address /domain-set:proxylist/203\.0\.113\.7'  "$OUT" || fail "no address->gateway for proxylist"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$OUT" || fail "no ip-alias foreign->gateway"
grep -Eq '^domain-set -name proxylist'                    "$OUT" || fail "no proxylist domain-set"
grep -Eq '^ip-set -name foreign'                          "$OUT" || fail "no foreign ip-set"
# Anti-pollution (DESIGN §5 constraint 2): domestic resolvers accept only China IPs.
grep -Eq '^server 223\.5\.5\.5 .*-whitelist-ip'           "$OUT" || fail "domestic server not -whitelist-ip (anti-pollution)"
grep -Eq '^conf-file /etc/smartdns/china-whitelist\.conf' "$OUT" || fail "china whitelist include missing"
grep -Eq '^conf-file /etc/smartdns/bogus-nxdomain\.conf'  "$OUT" || fail "bogus-nxdomain include missing"
# Must NOT expose plaintext 53 publicly:
grep -Eq '^bind (\[::\]|0\.0\.0\.0):53'                   "$OUT" && fail "public plaintext :53 must not exist"
# No unresolved placeholders:
grep -Eq '__[A-Z_]+__'                                    "$OUT" && fail "unresolved placeholder remains"

# --- update-lists.sh dry-run end-to-end (no network, no restart) ---
TMPDIR2="$(mktemp -d)"; trap 'rm -f "$OUT"; rm -rf "$TMPDIR2"' EXIT
# Seed a >=100-entry china file so the generator does not refuse.
python3 - "$TMPDIR2/china_ip_list.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(150):
        f.write("%d.0.0.0/8\n" % (i % 223))
PY
printf '# empty\n' > "$TMPDIR2/proxy-domains.txt"
DRY_RUN=1 SMARTDNS_DIR="$TMPDIR2" GATEWAY_IP=203.0.113.7 \
    bash "$ROOT/scripts/update-lists.sh" >/dev/null 2>&1 || fail "update-lists dry-run failed"
[ -s "$TMPDIR2/foreign-cidr.txt" ] || fail "foreign-cidr.txt not generated"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$TMPDIR2/smartdns.conf" \
    || fail "rendered conf missing ip-alias"
# Anti-pollution whitelist must be generated from the china list during update-lists.
[ -s "$TMPDIR2/china-whitelist.conf" ] || fail "china-whitelist.conf not generated"
grep -Eq '^whitelist-ip ' "$TMPDIR2/china-whitelist.conf" || fail "china-whitelist.conf has no whitelist-ip lines"

[ $rc -eq 0 ] && echo "smartdns conf policy: PASS"
exit $rc
