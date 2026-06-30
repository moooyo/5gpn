#!/usr/bin/env bash
# Pure grep — runs on the dev box under Git Bash and in CI.
# Originally asserted the three-tier DNS split shape in the smartdns template.
# NOTE (Task 8): smartdns replaced by 5gpn-dns; etc/smartdns.conf.template deleted.
# Template-specific checks are now obsolete and commented out; the update-lists
# pipeline checks and install.sh DOT_RATE/DOT_BURST are still enforced.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

# T was: $ROOT/etc/smartdns.conf.template — removed in Task 8 (5gpn-dns migration).
U="$ROOT/scripts/update-lists.sh"

# --- smartdns template checks: OBSOLETE (template removed) ---
# grep -Eq '^server 223\.5\.5\.5 .*-group domestic'   "$T" || fail "domestic group missing"
# ... (all template greps elided)

# --- update-lists: pipeline still builds china_ip_list (used by 5gpn-dns DNS_CHNROUTE) ---
grep -Eq 'china_ip_list\.txt|china-ip-list\.txt|china_ip\.conf' "$U" \
    || fail "update-lists must still generate china_ip_list (needed by 5gpn-dns DNS_CHNROUTE)"

# --- install.sh must reference DOT_RATE/DOT_BURST (forward/help) ---
I="$ROOT/install.sh"
grep -Eq 'DOT_RATE'  "$I" || fail "install.sh must reference DOT_RATE (forward/help)"
grep -Eq 'DOT_BURST' "$I" || fail "install.sh must reference DOT_BURST (forward/help)"

[ $rc -eq 0 ] && echo "dns split policy: PASS"
exit $rc
