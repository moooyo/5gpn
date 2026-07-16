#!/usr/bin/env bash
# Policy assertions for the P2/3.x cleanup batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

RENEW="$ROOT/scripts/renew-hook.sh"; README="$ROOT/README.md"

# 3.7 — renew-hook uses certbot's $RENEWED_LINEAGE (deterministic cert selection).
grep -Fq 'RENEWED_LINEAGE' "$RENEW" || fail "3.7: renew-hook not using \$RENEWED_LINEAGE"

# 3.10 — README reflects the implemented status and documents install/usage.
grep -Fq '设计阶段'      "$README" && fail "3.10: README still says 设计阶段"
grep -Fq 'quick-install' "$README" || fail "3.10: README missing install/usage"

[ $rc -eq 0 ] && echo "cleanup policy: PASS"
exit $rc
