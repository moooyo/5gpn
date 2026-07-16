#!/usr/bin/env bash
# Run all 5gpn tests. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"
rc=0

echo "== go unit tests =="
if command -v go >/dev/null 2>&1; then
    if [ -f "$ROOT/cmd/5gpn-dns/go.mod" ]; then
        ( cd "$ROOT/cmd/5gpn-dns" && go test ./... ) || rc=1
    else
        echo "SKIP: cmd/5gpn-dns/go.mod not found"
    fi
else
    if [ -f "$ROOT/cmd/5gpn-dns/go.mod" ]; then
        echo "WARN: go.mod exists but go not on PATH -- skipping Go tests"
    else
        echo "SKIP: go toolchain not on PATH"
    fi
fi

echo "== shell policy tests =="
for t in "$HERE"/test_*.sh; do
    [ -e "$t" ] || continue
    [ "$t" = "$HERE/run-tests.sh" ] && continue
    echo "--- $t ---"
    bash "$t" || rc=1
done

echo "== frontend unit tests =="
if [ -d "$ROOT/web" ] && command -v npm >/dev/null 2>&1; then
    ( cd "$ROOT/web" && npm run test -- --run ) || rc=1
else
    echo "SKIP: web dir or npm not found"
fi

echo "== frontend typecheck =="
if [ -d "$ROOT/web" ] && command -v npm >/dev/null 2>&1; then
    ( cd "$ROOT/web" && npm run typecheck ) || rc=1
else
    echo "SKIP: web dir or npm not found"
fi

echo "== frontend build =="
if [ -d "$ROOT/web" ] && command -v npm >/dev/null 2>&1; then
    ( cd "$ROOT/web" && npm run build ) || rc=1
else
    echo "SKIP: web dir or npm not found"
fi

echo "== frontend bundle check =="
if [ -d "$ROOT/web/dist" ] && command -v node >/dev/null 2>&1; then
    ( cd "$ROOT/web" && node scripts/check-bundle.mjs ) || rc=1
else
    echo "SKIP: dist not built or node not found"
fi

[ $rc -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
