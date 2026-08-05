#!/usr/bin/env bash
# Run all 5gpn tests. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
rc=0

echo "== shell policy tests =="
for t in "$HERE"/test_*.sh; do
    [ -e "$t" ] || continue
    [ "$t" = "$HERE/run-tests.sh" ] && continue
    echo "--- $t ---"
    bash "$t" || rc=1
done

[ $rc -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
