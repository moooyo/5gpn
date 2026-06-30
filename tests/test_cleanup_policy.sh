#!/usr/bin/env bash
# Policy assertions for the P2/3.x cleanup batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

GEN="$ROOT/scripts/gen_foreign_cidr.py"; RENEW="$ROOT/scripts/renew-hook.sh"
INSTALL="$ROOT/install.sh";         README="$ROOT/README.md"

# 3.2 — restore must cap per-member size (decompression bomb), not read unbounded.
# (api-server.py was removed; this check is now obsolete)

# 3.3 — reject chunked / Transfer-Encoding (smuggling / silent-empty body).
# (api-server.py was removed; this check is now obsolete)

# 3.7 — renew-hook uses certbot's $RENEWED_LINEAGE (deterministic cert selection).
grep -Fq 'RENEWED_LINEAGE' "$RENEW" || fail "3.7: renew-hook not using \$RENEWED_LINEAGE"

# 3.8 — gen_foreign_cidr.py was removed in Task 8 (smartdns -> 5gpn-dns migration).
# These checks are now obsolete.
# grep -Fq 'prefixlen'   "$GEN" || fail "3.8: generator does not guard over-broad (e.g. /0) entries"
# grep -Fq 'not foreign' "$GEN" || fail "3.8: generator does not refuse an empty foreign set"

# 3.9 — status foreign count consistent with API (skip comments/blanks, not raw wc -l).
grep -Fq 'wc -l < "${SMARTDNS_DIR}/foreign-cidr.txt"' "$INSTALL" && fail "3.9: foreign count still raw wc -l"

# 3.10 — README reflects the implemented status and documents install/usage.
grep -Fq '设计阶段'      "$README" && fail "3.10: README still says 设计阶段"
grep -Fq 'quick-install' "$README" || fail "3.10: README missing install/usage"

[ $rc -eq 0 ] && echo "cleanup policy: PASS"
exit $rc
