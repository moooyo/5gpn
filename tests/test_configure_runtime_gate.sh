#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/scripts/configure-runtime-gate.sh"
TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/5gpn-configure-runtime-gate.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

grep -Fxq '# 5gpn-configure-runtime-gate-id: v1' "$SOURCE" \
    || fail "runtime gate ownership marker is missing"
grep -Fq 'trap on_term TERM' "$SOURCE" \
    && grep -Fq 'cleanup_ack_tmp' "$SOURCE" \
    && grep -Fq 'systemd_stop_job_owns_unit' "$SOURCE" \
    || fail "operator stop can leave a signaled ExecStartPre failure"
grep -Fq 'GATE_MAX_WAIT_SECONDS=2100' "$SOURCE" \
    || fail "runtime gate wait is not explicitly bounded"

if [[ "${EUID:-$(id -u)}" != 0 ]]; then
    pass "root-owned gate behavior is covered by the disposable root acceptance"
    printf 'all configure runtime gate tests passed\n'
    exit 0
fi

LOCK_ROOT="$TMP/run/5gpn"
mkdir -p "$LOCK_ROOT"
chmod 0700 "$LOCK_ROOT"
HELPER="$TMP/configure-runtime-gate.sh"
VALIDATOR="$TMP/ui-generation.sh"
cat > "$VALIDATOR" <<'VALIDATOR'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == validate-current && "$#" == 1 ]] || exit 2
if [[ -n "${TEST_UI_STARTED:-}" ]]; then
    : > "$TEST_UI_STARTED"
    sleep 30
fi
VALIDATOR
chmod 0755 "$VALIDATOR"
sed -e "s|^LOCK_ROOT=/run/5gpn$|LOCK_ROOT=$LOCK_ROOT|" \
    -e "s|^UI_VALIDATOR=/opt/5gpn/scripts/ui-generation.sh$|UI_VALIDATOR=$VALIDATOR|" \
    "$SOURCE" > "$HELPER"
chmod 0755 "$HELPER"

record="$LOCK_ROOT/configure-runtime-gate"
ack="$LOCK_ROOT/configure-runtime-gate.ack"
job="$LOCK_ROOT/configure-runtime-gate.job"
release="$LOCK_ROOT/configure-runtime-gate.release"
token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

rm -f -- "$record" "$ack" "$job" "$release"
"$HELPER" wait || fail "normal start did not pass without gate state"
pass "normal service starts pass the configure gate immediately"

"$HELPER" validate-ui || fail "valid current UI wrapper failed"
ui_started="$TMP/ui-started"
setsid env TEST_UI_STARTED="$ui_started" "$HELPER" validate-ui \
    > "$TMP/ui-term.log" 2>&1 &
ui_pid=$!
deadline=$((SECONDS + 10))
while [[ ! -f "$ui_started" && "$SECONDS" -lt "$deadline" ]]; do
    sleep 0.05
done
[[ -f "$ui_started" ]] \
    || { kill -TERM -- "-$ui_pid" 2>/dev/null || true; fail "UI validator did not enter its TERM fixture"; }
kill -TERM -- "-$ui_pid"
if wait "$ui_pid"; then
    fail "a bare TERM bypassed the UI validation wrapper without a PID1 stop job"
fi
pass "a bare TERM cannot bypass the UI validation wrapper"

printf 'orphan\n' > "$ack"
chmod 0600 "$ack"
if "$HELPER" wait >/dev/null 2>&1; then
    fail "orphan gate state was accepted without an ownership record"
fi
rm -f -- "$ack"
pass "orphan gate state fails closed"

printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" > "$record"
printf 'version=1\ntoken=%s\n' "$token" > "$release"
chmod 0600 "$record" "$release"
INVOCATION_ID=0123456789abcdef0123456789abcdef "$HELPER" wait \
    || fail "matching gate release was rejected"
[[ "$(stat -Lc '%u:%g:%a:%h' -- "$ack")" == 0:0:600:1 ]] \
    || fail "gate acknowledgement metadata is unsafe"
grep -Fxq "token=$token" "$ack" \
    && grep -Fxq 'invocation_id=0123456789abcdef0123456789abcdef' "$ack" \
    || fail "gate acknowledgement did not bind the nonce and invocation"
rm -f -- "$record" "$ack" "$release"
pass "matching release unblocks one acknowledged invocation"

fake_bin="$TMP/fake-bin"
mkdir "$fake_bin"
real_ln="$(command -v ln)"
cat > "$fake_bin/ln" <<FAKE_LN
#!/usr/bin/env bash
set -eu
"$real_ln" "\$@"
kill -TERM "\$PPID"
sleep 1
FAKE_LN
chmod 0755 "$fake_bin/ln"
printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" > "$record"
chmod 0600 "$record"
if PATH="$fake_bin:$PATH" INVOCATION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$HELPER" wait; then
    fail "a bare TERM during acknowledgement publication bypassed the gate"
fi
[[ -f "$ack" && "$(stat -Lc '%u:%g:%a:%h' -- "$ack")" == 0:0:600:1 ]] \
    || fail "TERM during acknowledgement publication left a hardlink residue"
if compgen -G "$LOCK_ROOT/.configure-runtime-gate.ack.*" >/dev/null; then
    fail "TERM during acknowledgement publication retained its private link"
fi
rm -f -- "$record" "$ack"
pass "bare TERM fails closed while repairing the acknowledgement hardlink window"

printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" > "$record"
chmod 0600 "$record"
INVOCATION_ID=fedcba9876543210fedcba9876543210 "$HELPER" wait &
gate_pid=$!
deadline=$((SECONDS + 10))
while [[ ! -f "$ack" && "$SECONDS" -lt "$deadline" ]]; do
    sleep 0.05
done
[[ -f "$ack" ]] || { kill -TERM "$gate_pid" 2>/dev/null || true; fail "gate did not acknowledge before TERM test"; }
kill -TERM "$gate_pid"
if wait "$gate_pid"; then
    fail "a bare TERM bypassed the gate without a PID1 stop job"
fi
rm -f -- "$record" "$ack"
pass "a bare TERM cannot bypass the gate helper"

(
    INSTALL_SH_LIB_ONLY=1
    export INSTALL_SH_LIB_ONLY
    # shellcheck source=../install.sh
    source "$ROOT/install.sh"
    collector_root="$TMP/collector"
    private="$collector_root/private"
    mkdir -p "$private"
    chmod 0700 "$private"
    INSTALL_LOCK_FILE="$private/install.lock"
    CONFIGURE_RUNTIME_GATE_RECORD="$private/configure-runtime-gate"
    CONFIGURE_RUNTIME_GATE_JOB="$private/configure-runtime-gate.job"
    CONFIGURE_RUNTIME_GATE_ACK="$private/configure-runtime-gate.ack"
    CONFIGURE_RUNTIME_GATE_RELEASE="$private/configure-runtime-gate.release"
    configure_unit_has_no_job() { :; }
    residue="$private/.configure-runtime-gate.abc123"
    printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" > "$residue"
    chmod 0600 "$residue"
    ln -- "$residue" "$CONFIGURE_RUNTIME_GATE_RECORD"
    configure_repair_runtime_gate_link_residue \
        || fail "installer could not repair a committed hardlink publication residue"
    [[ ! -e "$residue" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$CONFIGURE_RUNTIME_GATE_RECORD")" == 0:0:600:1 ]] \
        || fail "installer hardlink repair did not retain one exact published target"
    rm -f -- "$CONFIGURE_RUNTIME_GATE_RECORD"

    printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" \
        > "$CONFIGURE_RUNTIME_GATE_RECORD"
    chmod 0600 "$CONFIGURE_RUNTIME_GATE_RECORD"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    configure_release_runtime_start_fence \
        || fail "record-only arm failure could not clean its unbound gate state"
    [[ ! -e "$CONFIGURE_RUNTIME_GATE_RECORD" ]] \
        || fail "record-only arm failure retained a gate ownership record"
)
pass "installer repairs hardlink residues and cleans a record-only arm failure"

printf 'all configure runtime gate tests passed\n'
