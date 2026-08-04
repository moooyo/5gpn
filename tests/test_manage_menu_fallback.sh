#!/usr/bin/env bash
# The non-terminal fallback actually works.
#
# The tab UI is gated on stdout being a terminal, so everything else -- output
# piped to a file, TERM=dumb, a CI shell -- lands in manage_menu_list. That path
# is the one nobody looks at, which is exactly why it needs driving rather than
# grepping: a list that offers a screen it cannot dispatch is the same class of
# bug as a label with no branch, and this one would only ever appear to someone
# who had already lost their terminal.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$ROOT/install.sh"

[[ "${#MANAGE_SCREENS[@]}" -ge 4 ]] || fail "MANAGE_SCREENS did not load"

# Drive the list with a scripted operator: pick each screen in turn, then quit.
# ask_choice is the only input the fallback has, so stubbing it is the seam.
#
# The queue lives in a FILE, not an array. ask_choice is called inside $( ),
# which is a subshell, so an array shift inside it is discarded and every call
# returns the same answer -- an infinite loop, which is how this harness first
# behaved. File state is the only kind that survives a subshell.
QUEUE="$(mktemp)"
trap 'rm -f -- "$QUEUE"' EXIT
declare -a DISPATCHED=()

ask_choice() {
    local answer
    answer="$(head -n 1 "$QUEUE" 2>/dev/null || true)"
    sed -i '1d' "$QUEUE" 2>/dev/null || true
    printf '%s' "$answer"
}
# manage_screen is covered by its own path; here we only need to know which
# screen the list resolved to and what it handed over.
manage_screen() {
    local title="$1" render="$2"; shift 2
    DISPATCHED+=("${title}|${render}|$*")
    # A harness that stops consuming answers would spin forever, and a test that
    # hangs reports nothing. Bound it: more dispatches than rows is a bug here.
    [[ "${#DISPATCHED[@]}" -le $(( ${#MANAGE_SCREENS[@]} + 2 )) ]] \
        || fail "the list dispatched more screens than the table has rows; the stub is not consuming answers"
}

for row in "${MANAGE_SCREENS[@]}"; do
    printf '%s\n' "${row%%|*}" >> "$QUEUE"
done
printf '%s\n' "退出 Quit" >> "$QUEUE"

manage_menu_list

[[ "${#DISPATCHED[@]}" == "${#MANAGE_SCREENS[@]}" ]] \
    || fail "the list dispatched ${#DISPATCHED[@]} screens for ${#MANAGE_SCREENS[@]} rows"

for i in "${!MANAGE_SCREENS[@]}"; do
    row="${MANAGE_SCREENS[$i]}"
    want_title="${row%%|*}"
    want_render="${row#*|}"; want_render="${want_render%%|*}"
    IFS='|' read -r -a want_labels <<< "${row#*|*|}"

    got="${DISPATCHED[$i]}"
    got_title="${got%%|*}"
    got_render="${got#*|}"; got_render="${got_render%%|*}"
    got_labels="${got#*|*|}"

    [[ "$got_title" == "$want_title" ]] \
        || fail "row $i dispatched title '$got_title', expected '$want_title'"
    [[ "$got_render" == "$want_render" ]] \
        || fail "screen '$want_title' dispatched renderer '$got_render', expected '$want_render'"
    [[ "$got_labels" == "${want_labels[*]}" ]] \
        || fail "screen '$want_title' dispatched labels '$got_labels', expected '${want_labels[*]}'"
done
pass "the non-terminal list offers every screen and hands over the table's own renderer and labels"

# Quitting must return rather than loop. An empty answer is what ask_choice
# yields when the operator escapes, and it has to mean the same thing.
DISPATCHED=()
: > "$QUEUE"
manage_menu_list
[[ "${#DISPATCHED[@]}" == 0 ]] || fail "an escaped selection dispatched a screen"
pass "an escaped selection leaves the list rather than dispatching"

echo "management menu fallback: PASS"
