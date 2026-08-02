#!/usr/bin/env bash
# Run the installer suites the way CI does: an LF copy, under Linux.
#
# The Windows worktree is CRLF and the git index is LF, so the suites cannot be
# run in place -- `grep -q 'foo$'` fails against a CR-terminated line and the
# failure looks like a real assertion break. Copy, strip CR, run there.
#
#   scripts/run-suites.sh              # every suite
#   scripts/run-suites.sh install_policy tui_policy   # named suites only
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LF=/tmp/5gpn-lf

rm -rf "$LF" && mkdir -p "$LF"
tar --exclude=./.git --exclude=./dist --exclude=./test-results -cf - -C "$SRC" . | (cd "$LF" && tar xf -)
grep -rIl $'\r' "$LF" 2>/dev/null | xargs -r sed -i 's/\r$//'

cd "$LF" || exit 1

if [[ $# -gt 0 ]]; then
    suites=()
    for name in "$@"; do suites+=("tests/test_${name#test_}.sh"); done
else
    suites=(tests/test_*.sh)
fi

pass=0; fail=0; failed=()
for t in "${suites[@]}"; do
    [[ -f "$t" ]] || { printf 'MISSING %s\n' "$t"; fail=$((fail + 1)); failed+=("$t"); continue; }
    if out="$(bash "$t" 2>&1)"; then
        printf 'PASS %s\n' "$t"; pass=$((pass + 1))
    else
        printf 'FAIL %s\n' "$t"; fail=$((fail + 1)); failed+=("$t")
        printf '%s\n' "$out" | tail -n "${SUITE_TAIL:-6}" | sed 's/^/     | /'
    fi
done

printf '\n%d passed, %d failed (of %d)\n' "$pass" "$fail" "$((pass + fail))"
((fail == 0)) || { printf 'failed: %s\n' "${failed[*]}"; exit 1; }
