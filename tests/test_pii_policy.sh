#!/usr/bin/env bash
# PII policy (review #33): the DNS query hot path must NOT log per-query client
# data (q.Name / Question / RemoteAddr / the query *dns.Msg) to journald. This
# locks the audited "no per-query PII in logs" privacy invariant so a future
# debug log can't silently regress it. Heuristic: single-line log.* calls only
# — a multi-line log call splitting the arg onto its own line would slip past,
# which is an accepted limit of a pure-grep gate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
SRC="$ROOT/cmd/5gpn-dns"
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

# Query-path files that see per-client data and must stay log-silent about it.
for f in handler.go arbitrate.go upstream.go server.go cache.go; do
    p="$SRC/$f"
    [ -f "$p" ] || { fail "missing $f"; continue; }
    if grep -nE 'log\.(Printf|Println|Print|Fatal|Fatalf|Fatalln)' "$p" \
         | grep -qE 'q\.Name|\.Question|RemoteAddr|\bqName\b'; then
        fail "$f logs per-query PII (q.Name/Question/RemoteAddr) — privacy invariant broken"
    fi
done

[ $rc -eq 0 ] && echo "pii policy: PASS"
exit $rc
