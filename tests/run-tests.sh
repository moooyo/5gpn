#!/usr/bin/env bash
# Run all 5gpn tests. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$HERE"
rc=0

echo "== go unit tests =="
if command -v go >/dev/null 2>&1; then
    # The Go module lives under cmd/5gpn-dns/ (not the repo root), so run the tests
    # from there. This is the suite that now covers the in-daemon bot + iOS server.
    if [ -f "$ROOT/cmd/5gpn-dns/go.mod" ]; then
        ( cd "$ROOT/cmd/5gpn-dns" && go test ./... ) || rc=1
    else
        echo "SKIP: cmd/5gpn-dns/go.mod not found"
    fi
else
    echo "SKIP: go toolchain not on PATH (run 'go test ./...' in CI / on the dev box)"
fi

echo "== shell policy tests =="
for t in "$HERE"/test_*.sh; do
    [ -e "$t" ] || continue
    [ "$t" = "$HERE/run-tests.sh" ] && continue
    echo "--- $t ---"
    bash "$t" || rc=1
done

[ $rc -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
