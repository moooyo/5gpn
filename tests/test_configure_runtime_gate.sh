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
grep -Fq 'wait|validate-ui|assert-clear' "$SOURCE" \
    || fail "runtime gate helper does not expose the shared retained-state assertion"

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

"$HELPER" assert-clear || fail "empty runtime gate state was not accepted"
printf 'retained\n' > "$record"
chmod 0600 "$record"
if "$HELPER" assert-clear >/dev/null 2>&1; then
    fail "shared retained-state assertion accepted a named gate file"
fi
rm -f -- "$record"
temp_residue="$LOCK_ROOT/.configure-runtime-gate.abc123"
printf 'retained\n' > "$temp_residue"
chmod 0600 "$temp_residue"
if "$HELPER" assert-clear >/dev/null 2>&1; then
    fail "shared retained-state assertion accepted a private gate residue"
fi
rm -f -- "$temp_residue"
pass "shared retained-state assertion rejects named and temporary gate state"

mount_fake_bin="$TMP/mount-fake-bin"
mkdir "$mount_fake_bin"
cat > "$mount_fake_bin/findmnt" <<FAKE_FINDMNT
#!/usr/bin/env bash
set -eu
case "\$*" in
    *'-T $TMP/run '*) printf '%s\n' '$TMP/run 0:42 /sandbox-run' ;;
    *'-T $LOCK_ROOT '*) printf '%s %s %s\n' '$LOCK_ROOT' '0:42' "\${TEST_GATE_FSROOT:-/sandbox-run/5gpn}" ;;
    *) exit 1 ;;
esac
FAKE_FINDMNT
chmod 0755 "$mount_fake_bin/findmnt"
PATH="$mount_fake_bin:$PATH" TEST_GATE_FSROOT=/sandbox-run/5gpn \
    "$HELPER" assert-clear \
    || fail "exact systemd self-bind of the private runtime directory was rejected"
if PATH="$mount_fake_bin:$PATH" TEST_GATE_FSROOT=/foreign-root \
    "$HELPER" assert-clear >/dev/null 2>&1; then
    fail "an unrelated nested mount was accepted as the systemd runtime self-bind"
fi
pass "runtime gate accepts only the exact same-device systemd self-bind"

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

stop_fake_bin="$TMP/stop-fake-bin"
mkdir "$stop_fake_bin"
cat > "$stop_fake_bin/busctl" <<'STOP_BUSCTL'
#!/usr/bin/env bash
set -eu
case "$*" in
    *' GetUnit s 5gpn-mihomo.service')
        printf '{"type":"o","data":["/org/freedesktop/systemd1/unit/5gpn_2dmihomo_2eservice"]}\n' ;;
    *' org.freedesktop.systemd1.Unit Job')
        printf '{"type":"(uo)","data":[77,"/org/freedesktop/systemd1/job/77"]}\n' ;;
    *' org.freedesktop.systemd1.Job JobType')
        printf '{"type":"s","data":"stop"}\n' ;;
    *' org.freedesktop.systemd1.Job State')
        printf '{"type":"s","data":"running"}\n' ;;
    *) exit 1 ;;
esac
STOP_BUSCTL
cat > "$stop_fake_bin/systemctl" <<'STOP_SYSTEMCTL'
#!/usr/bin/env bash
set -eu
case "$*" in
    'show -p ActiveState --value 5gpn-mihomo.service') printf 'deactivating\n' ;;
    'show -p SubState --value 5gpn-mihomo.service') printf 'stop-sigterm\n' ;;
    *) exit 1 ;;
esac
STOP_SYSTEMCTL
chmod 0755 "$stop_fake_bin/busctl" "$stop_fake_bin/systemctl"
printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token" > "$record"
chmod 0600 "$record"
PATH="$stop_fake_bin:$PATH" \
    INVOCATION_ID=00112233445566778899aabbccddeeff "$HELPER" wait &
gate_pid=$!
deadline=$((SECONDS + 10))
while [[ ! -f "$ack" && "$SECONDS" -lt "$deadline" ]]; do
    sleep 0.05
done
[[ -f "$ack" ]] \
    || { kill -TERM "$gate_pid" 2>/dev/null || true; fail "stop-job gate did not acknowledge"; }
kill -TERM "$gate_pid"
wait "$gate_pid" \
    || fail "an exact PID1 stop job did not terminate the gate helper cleanly"
rm -f -- "$record" "$ack"
pass "an exact PID1 stop job cleanly terminates the gate helper"

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
    configure_runtime_is_stably_active_without_job() { :; }
    configure_runtime_is_confirmed_inactive_success() { return 1; }
    residue="$private/.configure-runtime-gate.abc123"
    refuse_retained_configure_runtime_gate_state \
        || fail "an empty private gate directory was treated as retained state"
    for state_path in \
        "$CONFIGURE_RUNTIME_GATE_RECORD" "$CONFIGURE_RUNTIME_GATE_JOB" \
        "$CONFIGURE_RUNTIME_GATE_ACK" "$CONFIGURE_RUNTIME_GATE_RELEASE" "$residue"; do
        printf 'retained\n' > "$state_path"
        chmod 0600 "$state_path"
        if refuse_retained_configure_runtime_gate_state >/dev/null 2>&1; then
            fail "a non-configure entry accepted retained gate state: $state_path"
        fi
        rm -f -- "$state_path"
    done

    acquire_install_lock() { INSTALL_LOCK_HELD=1; }
    release_install_lock() { INSTALL_LOCK_HELD=0; }
    assert_installed_backend_revision() { :; }
    require_completed_runtime_identity() { :; }
    blocked_callback="$TMP/retained-gate-callback"
    retained_record_contents="$(printf 'version=1\ntoken=%s\nunit=5gpn-mihomo.service\n' "$token")"
    printf '%s\n' "$retained_record_contents" > "$CONFIGURE_RUNTIME_GATE_RECORD"
    chmod 0600 "$CONFIGURE_RUNTIME_GATE_RECORD"
    retained_gate_callback() { : > "$blocked_callback"; }
    if run_management_with_install_lock retained_gate_callback >/dev/null 2>&1; then
        fail "the locked management wrapper accepted retained gate state"
    fi
    [[ ! -e "$blocked_callback" ]] \
        || fail "a retained gate reached the management mutation callback"
    configure_recovery_callback="$TMP/configure-recovery-callback"
    configure_installation() { : > "$configure_recovery_callback"; }
    run_management_with_install_lock configure_installation \
        || fail "the configure recovery entry was blocked by its own retained gate"
    [[ -f "$configure_recovery_callback" ]] \
        || fail "the configure recovery callback did not run"
    rm -f -- "$CONFIGURE_RUNTIME_GATE_RECORD" "$configure_recovery_callback"

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
