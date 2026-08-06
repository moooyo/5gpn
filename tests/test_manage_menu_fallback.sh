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
TAB_TMP="$(mktemp -d)"
trap 'rm -f -- "$QUEUE"; rm -rf -- "$TAB_TMP"' EXIT
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

# Drive the terminal renderer with cursor movement and a tab change. Renderer
# calls are recorded outside command-substitution state so this proves that
# up/down only rebuild the frame from cached facts and that a tab change runs
# only the destination renderer.
MANAGE_SCREENS=(
    "A|render_a|A one|A two"
    "B|render_b|B one|B two"
)
RENDER_CALLS="$TAB_TMP/render-calls"
KEY_QUEUE="$TAB_TMP/key-queue"
render_a() { echo A >> "$RENDER_CALLS"; echo "facts A"; }
render_b() { echo B >> "$RENDER_CALLS"; echo "facts B"; }
card() { cat; }
manage_read_key() {
    local answer
    answer="$(head -n 1 "$KEY_QUEUE" 2>/dev/null || true)"
    sed -i '1d' "$KEY_QUEUE" 2>/dev/null || true
    printf '%s' "$answer"
}
printf '%s\n' down right up quit > "$KEY_QUEUE"
tab_output="$(manage_menu_tabs)"
[[ "$(tr '\n' ' ' < "$RENDER_CALLS")" == 'A B ' ]] \
    || fail "cursor movement reran a renderer or the tab switch rendered the wrong side: $(tr '\n' ' ' < "$RENDER_CALLS")"
[[ "$tab_output" != *$'\033[2J'* ]] \
    || fail "terminal navigation still performs a full 2J clear"
repaint_prefix=$'\033[0m\033[H\033[J'
[[ "$tab_output" == "${repaint_prefix}"* && "$tab_output" == "${repaint_prefix}"*'facts A'* ]] \
    || fail "the ready frame is not painted immediately after reset/home/erase"
without_repaints="${tab_output//"$repaint_prefix"/}"
[[ "$without_repaints" != *$'\033[H'* && "$without_repaints" != *$'\033[J'* ]] \
    || fail "a terminal paint still writes content before erasing the old visible frame"
[[ "$tab_output" == *'facts A'* && "$tab_output" == *'facts B'* ]] \
    || fail "the terminal frames omitted a cached renderer snapshot"
pass "tab frames are complete before paint and cursor movement reuses cached facts"

# Every unit displayed in one services snapshot must have at most one
# systemctl query. The public renewal timer is interpreted through certificate
# provenance rather than treating every intentional inactive state as failure.
UNIT_CALLS="$TAB_TMP/unit-calls"
INACTIVE_UNIT=5gpn-certbot-renew.timer
systemctl() {
    [[ "$1" == is-active ]] || return 1
    echo "$2" >> "$UNIT_CALLS"
    if [[ "$2" == "$INACTIVE_UNIT" ]]; then
        printf 'inactive\n'
        return 3
    fi
    printf 'active\n'
}
CERT_MODE_TEST=cloudflare
CERT_LINEAGE_TEST=owned
cert_provenance_get() {
    case "$1" in
        mode) printf '%s' "$CERT_MODE_TEST" ;;
        certbot_lineage) printf '%s' "$CERT_LINEAGE_TEST" ;;
    esac
}
owned_output="$(manage_screen_services)"
grep -Fq '❌ 5gpn-certbot-renew.timer' <<< "$owned_output" \
    && grep -Fq 'inactive (5gpn-owned renewal)' <<< "$owned_output" \
    || fail "an inactive owned renewal timer is not reported as an actionable failure"
for unit in 5gpn-mihomo.service 5gpn-intercept-cert.path \
            5gpn-intercept-cert.timer 5gpn-certbot-renew.timer; do
    [[ "$(grep -Fxc "$unit" "$UNIT_CALLS")" == 1 ]] \
        || fail "$unit was queried more or less than once in one services snapshot"
done

for case_value in 'debug|none|不适用' \
                  'cloudflare|reused|外部续期' \
                  'http-01|missing|需修复'; do
    IFS='|' read -r CERT_MODE_TEST CERT_LINEAGE_TEST expected <<< "$case_value"
    : > "$UNIT_CALLS"
    service_output="$(manage_screen_services)"
    grep -Fq "$expected" <<< "$service_output" \
        || fail "$CERT_MODE_TEST/$CERT_LINEAGE_TEST renewal state omitted '$expected'"
    ! grep -Fqx '5gpn-certbot-renew.timer' "$UNIT_CALLS" \
        || fail "$CERT_MODE_TEST/$CERT_LINEAGE_TEST needlessly queried the inapplicable renewal timer"
done
cert_provenance_get() { return 1; }
: > "$UNIT_CALLS"
service_output="$(manage_screen_services)" \
    || fail "missing certificate provenance aborted the services screen under set -e"
grep -Fq 'provenance unknown' <<< "$service_output" \
    || fail "missing certificate provenance was not shown as unknown"
pass "service status queries each applicable unit once and explains renewal provenance"

echo "management menu fallback: PASS"
