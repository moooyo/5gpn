#!/usr/bin/env bash
# Run the portable installer suites from an LF copy under Linux. CI additionally
# repeats the root-only configure and certificate recovery branches with sudo.
#
# The Windows worktree is CRLF and the git index is LF, so the suites cannot be
# run in place -- `grep -q 'foo$'` fails against a CR-terminated line and the
# failure looks like a real assertion break. Copy, strip CR, run there.
#
#   scripts/run-suites.sh              # every suite
#   scripts/run-suites.sh install_policy tui_policy   # named suites only
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LF=""
LF_ID=""
LF_MARKER_ID=""
LF_MARKER_VALUE=""
TMP_ROOT=""
readonly LF_MARKER_NAME=.5gpn-run-suites-owner

path_identity() {
    stat -c '%d:%i' -- "$1" 2>/dev/null
}

workspace_has_no_nested_mounts() {
    local target output
    output="$(findmnt -R -r -n -o TARGET --target "$LF" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in
            "$LF"|"$LF"/*) return 1 ;;
        esac
    done <<< "$output"
}

workspace_is_owned() {
    local canonical leaf marker="$LF/$LF_MARKER_NAME"
    [[ -n "$LF" && -n "$LF_ID" && -n "$LF_MARKER_ID" && -n "$LF_MARKER_VALUE" ]] || return 1
    [[ -d "$LF" && ! -L "$LF" ]] || return 1
    canonical="$(realpath -e -- "$LF" 2>/dev/null)" || return 1
    [[ "$canonical" == "$LF" ]] || return 1
    leaf="${LF#"$TMP_ROOT"/}"
    [[ "$LF" == "$TMP_ROOT"/* && "$leaf" =~ ^5gpn-lf\.[[:alnum:]]{6}$ ]] || return 1
    [[ "$(path_identity "$LF")" == "$LF_ID" ]] || return 1
    [[ "$(stat -c %u -- "$LF" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] || return 1
    [[ "$(stat -c %a -- "$LF" 2>/dev/null)" == 700 ]] || return 1
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(path_identity "$marker")" == "$LF_MARKER_ID" ]] || return 1
    [[ "$(stat -c %u -- "$marker" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] || return 1
    [[ "$(stat -c %a -- "$marker" 2>/dev/null)" == 600 ]] || return 1
    [[ "$(stat -c %h -- "$marker" 2>/dev/null)" == 1 ]] || return 1
    printf '%s\n' "$LF_MARKER_VALUE" | cmp -s - "$marker" || return 1
    workspace_has_no_nested_mounts
}

cleanup_workspace() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -z "$LF" ]]; then
        exit "$status"
    fi
    if workspace_is_owned; then
        if ! cd -- "$TMP_ROOT"; then
            printf 'WARNING: could not leave suite workspace before cleanup: %s\n' "$LF" >&2
            ((status != 0)) || status=1
        elif ! rm -rf -- "$LF"; then
            printf 'WARNING: could not remove suite workspace: %s\n' "$LF" >&2
            ((status != 0)) || status=1
        fi
    else
        printf 'WARNING: refusing to remove unowned suite workspace: %s\n' "$LF" >&2
        ((status != 0)) || status=1
    fi
    exit "$status"
}

exit_for_signal() {
    trap - HUP INT TERM
    exit "$1"
}

for command_name in cmp findmnt mktemp realpath stat; do
    command -v "$command_name" >/dev/null 2>&1 \
        || { printf 'Missing required command: %s\n' "$command_name" >&2; exit 1; }
done

TMP_ROOT="$(realpath -e -- /tmp)" || exit 1
LF="$(mktemp -d /tmp/5gpn-lf.XXXXXX)" || exit 1
LF="$(realpath -e -- "$LF")" || exit 1
LF_ID="$(path_identity "$LF")" || exit 1
LF_MARKER_VALUE="5gpn-run-suites-workspace-v1:$LF:$LF_ID:$$"
printf '%s\n' "$LF_MARKER_VALUE" > "$LF/$LF_MARKER_NAME" || exit 1
chmod 0600 "$LF/$LF_MARKER_NAME" || exit 1
LF_MARKER_ID="$(path_identity "$LF/$LF_MARKER_NAME")" || exit 1
workspace_is_owned || exit 1

trap cleanup_workspace EXIT
trap 'exit_for_signal 129' HUP
trap 'exit_for_signal 130' INT
trap 'exit_for_signal 143' TERM

if ! tar --exclude=./.git --exclude=./dist --exclude=./test-results \
        --exclude="./$LF_MARKER_NAME" -cf - -C "$SRC" . \
        | (cd "$LF" && tar --no-overwrite-dir -xf -); then
    printf 'Could not populate suite workspace: %s\n' "$LF" >&2
    exit 1
fi
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
