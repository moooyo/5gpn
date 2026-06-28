#!/usr/bin/env bash
# Run all 5gpn P1 tests. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
rc=0

echo "== python unit tests =="
python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v || rc=1

echo "== shell policy tests =="
for t in "$HERE"/test_*.sh; do
    [ -e "$t" ] || continue
    [ "$t" = "$HERE/run-tests.sh" ] && continue
    echo "--- $t ---"
    bash "$t" || rc=1
done

[ $rc -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
