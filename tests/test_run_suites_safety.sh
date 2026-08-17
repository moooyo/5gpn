#!/usr/bin/env bash
# Safety checks for the Linux LF suite workspace.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-suites.sh"
FAIL=0

pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

TEST_TMP="$(mktemp -d /tmp/5gpn-run-suites-test.XXXXXX)" || exit 1
TEST_TMP="$(realpath -e -- "$TEST_TMP")" || exit 1
TEST_MARKER="$TEST_TMP/.5gpn-run-suites-test-owner"
TEST_MARKER_VALUE="5gpn-run-suites-test-v1:$TEST_TMP:$$"
printf '%s\n' "$TEST_MARKER_VALUE" > "$TEST_MARKER" || exit 1
chmod 0600 "$TEST_MARKER" || exit 1

test_tmp_has_no_nested_mounts() {
    local target output
    output="$(findmnt -R -r -n -o TARGET --target "$TEST_TMP" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in
            "$TEST_TMP"|"$TEST_TMP"/*) return 1 ;;
        esac
    done <<< "$output"
}

cleanup_test_tmp() {
    local status=$?
    trap - EXIT
    if [[ "$TEST_TMP" =~ ^/tmp/5gpn-run-suites-test\.[[:alnum:]]{6}$ ]] \
       && [[ "$(realpath -e -- "$TEST_TMP" 2>/dev/null)" == "$TEST_TMP" ]] \
       && [[ -d "$TEST_TMP" && ! -L "$TEST_TMP" ]] \
       && [[ "$(stat -c %u -- "$TEST_TMP" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] \
       && [[ "$(stat -c %a -- "$TEST_TMP" 2>/dev/null)" == 700 ]] \
       && [[ -f "$TEST_MARKER" && ! -L "$TEST_MARKER" ]] \
       && [[ "$(stat -c %u -- "$TEST_MARKER" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] \
       && [[ "$(stat -c %a -- "$TEST_MARKER" 2>/dev/null)" == 600 ]] \
       && [[ "$(stat -c %h -- "$TEST_MARKER" 2>/dev/null)" == 1 ]] \
       && printf '%s\n' "$TEST_MARKER_VALUE" | cmp -s - "$TEST_MARKER" \
       && test_tmp_has_no_nested_mounts; then
        rm -rf -- "$TEST_TMP"
    else
        printf 'WARNING: refusing unsafe test cleanup: %s\n' "$TEST_TMP" >&2
        ((status != 0)) || status=1
    fi
    exit "$status"
}
trap cleanup_test_tmp EXIT

if grep -Fq 'mktemp -d /tmp/5gpn-lf.XXXXXX' "$RUNNER" \
   && ! grep -Eq '^LF=/tmp/5gpn-lf$|rm -rf[[:space:]]+"?/tmp/5gpn-lf"?' "$RUNNER"; then
    pass "suite workspaces use unique names and never clear the fixed path"
else
    fail "suite workspace allocation still uses or clears the fixed path"
fi

if grep -Fq 'workspace_is_owned' "$RUNNER" \
   && grep -Fq 'realpath -e -- "$LF"' "$RUNNER" \
   && grep -Fq 'path_identity "$LF"' "$RUNNER" \
   && grep -Fq 'LF_MARKER_ID' "$RUNNER" \
   && grep -Fq 'stat -c %h -- "$marker"' "$RUNNER" \
   && grep -Fq 'workspace_has_no_nested_mounts' "$RUNNER" \
   && grep -Fq 'trap cleanup_workspace EXIT' "$RUNNER" \
   && grep -Fq "trap 'exit_for_signal 143' TERM" "$RUNNER"; then
    pass "cleanup is gated by canonical path, inode, marker, metadata, mount, and signal checks"
else
    fail "suite cleanup is missing an ownership or interruption boundary"
fi

fixture="$TEST_TMP/fixture"
mkdir -p "$fixture/scripts" "$fixture/tests"
cp -- "$RUNNER" "$fixture/scripts/run-suites.sh"
cat > "$fixture/tests/test_probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$(pwd -P)" > "$PROBE_PATH"
sleep "${PROBE_DELAY:-0}"
PROBE
chmod 0755 "$fixture/scripts/run-suites.sh" "$fixture/tests/test_probe.sh"

wait_for_path() {
    local path="$1" attempt
    for attempt in $(seq 1 200); do
        [[ -s "$path" ]] && return 0
        sleep 0.02
    done
    return 1
}

fixed_before="$(stat -Lc '%F:%d:%i:%s:%Y' /tmp/5gpn-lf 2>/dev/null || printf 'absent')"
PROBE_PATH="$TEST_TMP/parallel-one.path" PROBE_DELAY=0.4 \
    bash "$fixture/scripts/run-suites.sh" probe > "$TEST_TMP/parallel-one.log" 2>&1 &
parallel_one_pid=$!
PROBE_PATH="$TEST_TMP/parallel-two.path" PROBE_DELAY=0.4 \
    bash "$fixture/scripts/run-suites.sh" probe > "$TEST_TMP/parallel-two.log" 2>&1 &
parallel_two_pid=$!

parallel_ready=1
wait_for_path "$TEST_TMP/parallel-one.path" || parallel_ready=0
wait_for_path "$TEST_TMP/parallel-two.path" || parallel_ready=0
parallel_one="$(cat "$TEST_TMP/parallel-one.path" 2>/dev/null || true)"
parallel_two="$(cat "$TEST_TMP/parallel-two.path" 2>/dev/null || true)"
if [[ "$parallel_ready" == 1 && "$parallel_one" != "$parallel_two" \
   && -d "$parallel_one" && -d "$parallel_two" \
   && "$parallel_one" =~ ^/tmp/5gpn-lf\.[[:alnum:]]{6}$ \
   && "$parallel_two" =~ ^/tmp/5gpn-lf\.[[:alnum:]]{6}$ ]]; then
    pass "parallel runs use distinct live workspaces"
else
    fail "parallel runs did not receive distinct private workspaces"
fi

wait "$parallel_one_pid" || fail "first parallel suite run failed"
wait "$parallel_two_pid" || fail "second parallel suite run failed"
fixed_after="$(stat -Lc '%F:%d:%i:%s:%Y' /tmp/5gpn-lf 2>/dev/null || printf 'absent')"
if [[ ! -e "$parallel_one" && ! -L "$parallel_one" \
   && ! -e "$parallel_two" && ! -L "$parallel_two" \
   && "$fixed_after" == "$fixed_before" ]]; then
    pass "normal cleanup removes only each run's workspace and preserves the fixed path"
else
    fail "normal cleanup touched the wrong path or left a suite workspace"
fi

PROBE_PATH="$TEST_TMP/interrupted.path" PROBE_DELAY=0.4 \
    bash "$fixture/scripts/run-suites.sh" probe > "$TEST_TMP/interrupted.log" 2>&1 &
interrupted_pid=$!
if wait_for_path "$TEST_TMP/interrupted.path"; then
    interrupted_path="$(cat "$TEST_TMP/interrupted.path")"
    kill -TERM "$interrupted_pid" 2>/dev/null || true
    wait "$interrupted_pid"
    interrupted_status=$?
    if [[ "$interrupted_status" == 143 \
       && ! -e "$interrupted_path" && ! -L "$interrupted_path" ]]; then
        pass "TERM cleanup removes only the interrupted run's validated workspace"
    else
        fail "TERM returned $interrupted_status or left $interrupted_path"
    fi
else
    kill -TERM "$interrupted_pid" 2>/dev/null || true
    wait "$interrupted_pid" 2>/dev/null || true
    fail "interrupted run did not publish its workspace path"
fi

printf '%s\n' '----'
if [[ "$FAIL" == 0 ]]; then
    printf '%s\n' 'test_run_suites_safety: PASS'
else
    printf '%s\n' 'test_run_suites_safety: FAIL'
    exit 1
fi
