#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/5gpn-install-transaction.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$INSTALL"

full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
finish_fn="$(sed -n '/^finish_install_transaction()/,/^}/p' "$INSTALL")"

line_of() {
    local text="$1" pattern="$2"
    grep -nF "$pattern" <<<"$text" | head -1 | cut -d: -f1
}

install_lock_line="$(line_of "$full_fn" 'acquire_install_lock')"
cert_lock_line="$(line_of "$full_fn" 'acquire_install_cert_lock')"
publish_line="$(line_of "$full_fn" 'install_mihomo')"
if [[ -n "$install_lock_line" && -n "$cert_lock_line" && -n "$publish_line" \
   && "$install_lock_line" -lt "$cert_lock_line" \
   && "$cert_lock_line" -lt "$publish_line" ]]; then
    pass "full install holds the independent install lock before the certificate lock"
else
    fail "install/certificate lock order is not explicit"
fi

# The installer no longer undoes a partial publication. What must survive is the
# unwind path: the failure is reported, both locks come back, and staging goes.
grep -Eq '^(rollback_install|capture_install_rollback|quarantine_managed_units_after_failed_rollback|restore_managed_unit_states)\(\)' "$INSTALL" \
    && fail "the install rollback subsystem came back" \
    || pass "a failed install does not restore or quarantine the host"
grep -Fq 'report_install_failure' <<<"$finish_fn" \
    && fail "finish_install_transaction reports the failure twice" \
    || pass "failure reporting stays with the traps that own it"
grep -Fq 'release_install_cert_lock' <<<"$finish_fn" \
    && grep -Fq 'release_install_lock' <<<"$finish_fn" \
    && grep -Fq 'cleanup_artifact_stage' <<<"$finish_fn" \
    && grep -Fq 'restore_global_certbot_timer' <<<"$finish_fn" \
    && pass "the unwind path restores external timer state, releases both locks, and drops staging" \
    || fail "a failed install can leak a lock or its staging directory"
grep -Fq 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_fn" \
    && grep -Fq 'INSTALL_PUBLICATION_STARTED:-0' <<<"$finish_fn" \
    && pass "partial-install reporting is gated by the explicit publication boundary" \
    || fail "prepublication failures are still reported as partial installs"
deps_line="$(line_of "$full_fn" 'install_deps')"
timer_preflight_line="$(line_of "$full_fn" 'preflight_global_certbot_timer_state')"
timer_pause_line="$(line_of "$full_fn" 'pause_global_certbot_timer')"
timer_pause_final_line="$(grep -nF 'pause_global_certbot_timer' <<<"$full_fn" | tail -1 | cut -d: -f1)"
timer_pause_count="$(grep -Fc 'pause_global_certbot_timer' <<<"$full_fn")"
publication_boundary_line="$(line_of "$full_fn" 'INSTALL_PUBLICATION_STARTED=1')"
[[ -n "$deps_line" && -n "$timer_preflight_line" && -n "$timer_pause_line" \
   && -n "$timer_pause_final_line" && -n "$publication_boundary_line" \
   && "$timer_pause_count" -ge 2 \
   && "$deps_line" -lt "$timer_preflight_line" \
   && "$timer_preflight_line" -lt "$timer_pause_line" \
   && "$timer_pause_line" -le "$timer_pause_final_line" \
   && "$timer_pause_final_line" -lt "$publication_boundary_line" \
   && "$timer_pause_line" -lt "$publication_boundary_line" ]] \
    || fail "distro Certbot timer is not checked and captured before publication"
pass "distro Certbot timer compatibility and snapshot finish before project publication"
claim_root_line="$(line_of "$full_fn" 'claim_project_roots')"
runtime_stop_line="$(line_of "$full_fn" 'stop_managed_runtime_units')"
runtime_revalidate_line="$(grep -nF 'validate_existing_runtime_documents' <<<"$full_fn" | tail -1 | cut -d: -f1)"
first_payload_line="$(line_of "$full_fn" 'publish_verified_gum')"
[[ -n "$claim_root_line" && -n "$runtime_stop_line" \
   && -n "$runtime_revalidate_line" && -n "$first_payload_line" \
   && "$claim_root_line" -lt "$runtime_stop_line" \
   && "$runtime_stop_line" -lt "$runtime_revalidate_line" \
   && "$runtime_revalidate_line" -lt "$first_payload_line" ]] \
    || fail "runtime writers are not stopped and Core state revalidated immediately after publication begins"
pass "runtime writers quiesce before the first payload publication"

finish_timer_line="$(line_of "$finish_fn" 'restore_global_certbot_timer')"
finish_release_line="$(line_of "$finish_fn" 'release_install_cert_lock')"
[[ -n "$finish_timer_line" && -n "$finish_release_line" \
   && "$finish_timer_line" -lt "$finish_release_line" ]] \
    || fail "failure cleanup releases the certificate lock before restoring the distro timer"
pass "failure cleanup restores the distro timer while the certificate lock is held"

timer_restore_line="$(line_of "$full_fn" 'restore_global_certbot_timer')"
cleanup_line="$(line_of "$full_fn" 'cleanup_artifact_stage')"
release_line="$(line_of "$full_fn" 'release_install_cert_lock')"
if [[ -n "$timer_restore_line" && -n "$cleanup_line" && -n "$release_line" \
   && "$timer_restore_line" -lt "$release_line" \
   && "$release_line" -lt "$cleanup_line" ]]; then
    pass "a verified deployment restores the distro timer before releasing the certificate lock"
else
    fail "success-path timer restore and certificate-lock release are out of order"
fi

# Exercise both locks and prove that they are independently exclusive.
lock_root="$TMP/locks"
mkdir -m 0700 "$lock_root"
INSTALL_LOCK_FILE="$lock_root/install.lock"
CERT_RENEW_LOCK_FILE="$lock_root/cert.lock"
INSTALL_LOCK_HELD=0
INSTALL_CERT_LOCK_HELD=0
file_uid() { printf '0\n'; }
file_gid() { printf '0\n'; }
file_mode() { [[ -d "$1" ]] && printf '700\n' || printf '600\n'; }
file_nlink() { printf '1\n'; }
chown() { return 0; }
info() { :; }
err() { printf '%s\n' "$*" >&2; }

acquire_install_lock || fail "could not acquire the test install lock"
acquire_install_cert_lock || fail "could not acquire the test certificate lock"
if flock -n "$INSTALL_LOCK_FILE" -c true 2>/dev/null \
   || flock -n "$CERT_RENEW_LOCK_FILE" -c true 2>/dev/null; then
    fail "a competing process entered a held transaction lock"
fi
flock -n "$CERT_RENEW_LOCK_FILE" -c true 2>/dev/null \
    && fail "held certificate lock is not exclusive"
release_install_cert_lock || fail "could not release the test certificate lock"
flock -n "$CERT_RENEW_LOCK_FILE" -c true \
    || fail "certificate lock remained held after release"
flock -n "$INSTALL_LOCK_FILE" -c true 2>/dev/null \
    && fail "install lock was released during certificate-lock handoff"
release_install_lock || fail "could not release the test install lock"
flock -n "$INSTALL_LOCK_FILE" -c true \
    || fail "install lock remained held after the run completed"
pass "lock descriptors are independently exclusive and each releases cleanly"

# Uncontended locks should be silent. A contended certificate lock must report
# progress in bounded slices rather than hiding a 15-minute flock wait.
lock_wait_log="$TMP/lock-wait.log"
lock_wait_calls="$TMP/lock-wait.calls"
: > "$lock_wait_log"
: > "$lock_wait_calls"
LOCK_WAIT_REPORT_INTERVAL=1
flock() {
    printf '%s\n' "$*" >> "$lock_wait_calls"
    return 1
}
info() { printf '%s\n' "$*" >> "$lock_wait_log"; }
if wait_for_exclusive_lock 8 3 "Another 5gpn certificate update"; then
    fail "contended certificate lock did not honor its timeout"
fi
[[ "$(grep -c '^-w 1 8$' "$lock_wait_calls")" == 3 ]] \
    || fail "certificate lock timeout was not split into bounded progress intervals"
grep -Fq 'waiting up to 3s' "$lock_wait_log" \
    && grep -Fq '1s elapsed, 2s remaining' "$lock_wait_log" \
    && grep -Fq '2s elapsed, 1s remaining' "$lock_wait_log" \
    || fail "certificate lock wait did not report visible progress"
grep -Fq 'CERT_LOCK_WAIT_TIMEOUT=30' "$INSTALL" \
    || fail "installer certificate-lock wait is not capped at 30 seconds"
unset -f flock
info() { :; }
LOCK_WAIT_REPORT_INTERVAL=5
pass "certificate lock contention is visible and capped at 30 seconds"

failure_log="$TMP/install-failure.log"
INSTALL_PHASE="capturing the pre-install rollback snapshot"
INSTALL_FAILURE_REPORTED=0
err() { printf '%s\n' "$*" >> "$failure_log"; }
report_install_failure 73
report_install_failure 74
grep -Fq "phase 'capturing the pre-install rollback snapshot' (exit 73)" "$failure_log" \
    && [[ "$(grep -c '^Installation failed during phase' "$failure_log")" == 1 ]] \
    || fail "installer failure reporting omitted the phase or reported one failure twice"
err() { printf '%s\n' "$*" >&2; }
pass "installer failures report the active phase exactly once"

# A management command launched by a separate process must wait behind the
# installer fence and cannot mutate state or restart services mid-snapshot.
management_runner="$TMP/management-runner.sh"
cat > "$management_runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
source "$TEST_INSTALL"
INSTALL_LOCK_FILE="$TEST_INSTALL_LOCK_FILE"
CERT_RENEW_LOCK_FILE="$TEST_CERT_LOCK_FILE"
file_uid() { printf '0\n'; }
file_gid() { printf '0\n'; }
file_mode() { [[ -d "$1" ]] && printf '700\n' || printf '600\n'; }
file_nlink() { printf '1\n'; }
chown() { return 0; }
info() { :; }
err() { :; }
management_mutation() { : > "$TEST_MANAGEMENT_MARKER"; }
run_management_with_install_lock management_mutation
EOF
chmod 0755 "$management_runner"
management_marker="$TMP/management-mutated"
acquire_install_lock || fail "could not reacquire install lock for management concurrency test"
(
    exec 7>&- 8>&-
    TEST_INSTALL="$INSTALL" \
    TEST_INSTALL_LOCK_FILE="$INSTALL_LOCK_FILE" \
    TEST_CERT_LOCK_FILE="$CERT_RENEW_LOCK_FILE" \
    TEST_MANAGEMENT_MARKER="$management_marker" \
        bash "$management_runner"
) &
management_pid=$!
sleep 0.2
[[ ! -e "$management_marker" ]] \
    || fail "management mutation crossed the active installer fence"
release_install_lock || fail "could not release installer fence for queued management command"
wait "$management_pid" || fail "queued management command did not complete after lock release"
[[ -e "$management_marker" ]] \
    || fail "management command was lost instead of serialized"
pass "separate management processes serialize behind the full install transaction"

cert_management_marker="$TMP/cert-management-locked"
cert_management_probe() {
    flock -n "$INSTALL_LOCK_FILE" -c true 2>/dev/null && return 81
    flock -n "$CERT_RENEW_LOCK_FILE" -c true 2>/dev/null && return 82
    : > "$cert_management_marker"
}
run_management_with_install_and_cert_lock cert_management_probe \
    || fail "certificate-writing management wrapper did not hold both locks"
[[ -e "$cert_management_marker" ]] \
    || fail "certificate management probe did not run"
pass "certificate-writing management commands hold install then certificate locks"

# There is one long-running unit now, so the ordering this used to police is
# gone -- not relaxed. The race it existed for was the interception sidecar's
# readiness probe depending on mihomo's SOCKS listeners, and DNS advertising
# gateway answers before the data plane was live. Inside one process that binds
# everything before it accepts anything, neither can happen.
#
# What must survive is the part that was never about ordering: success is gated
# on readiness, and any failure to enable, start or become ready is fatal. An
# installer that prints success over a dead gateway is the failure this file
# exists to prevent.
service_order="$TMP/service-order"
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
systemctl() {
    local action="$1" unit="${*: -1}"
    case "$action" in
        restart|start) printf '%s\n' "$unit" >> "$service_order" ;;
    esac
    return 0
}
wait_service_ready() { return 0; }
start_services || fail "start_services failed on a healthy host"
[[ "$(tr '\n' ' ' < "$service_order")" == '5gpn-mihomo.service ' ]] \
    || fail "start_services started something other than the one unit: $(tr '\n' ' ' < "$service_order")"
pass "one unit is started, and nothing that was retired with the old layout"

# A unit that never becomes ready must fail the install rather than complete it.
: > "$service_order"
wait_service_ready() { return 92; }
if start_services; then
    fail "start_services reported success for a unit that never became ready"
fi
pass "install success is gated on readiness"
unset -f systemctl wait_service_ready resolve_mihomo_listen_ips

# The unwind path still owns three things: it surfaces its own failures, it
# preserves the original exit status, and a failed run says plainly that the
# published host was left as it stands. External timer state is restored, but
# project publication is never rolled back.
notice="$TMP/unwind-notice"
set +e
(
    ARTIFACT_STAGE="$TMP/unwind-stage"
    mkdir -p "$ARTIFACT_STAGE"
    cleanup_artifact_stage() { return 1; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { printf '%s\n' "$*" >> "$notice"; }
    finish_install_transaction 0
)
cleanup_rc=$?
(
    ARTIFACT_STAGE="$TMP/unwind-stage-2"
    INSTALL_PUBLICATION_STARTED=1
    mkdir -p "$ARTIFACT_STAGE"
    cleanup_artifact_stage() { return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { printf '%s\n' "$*" >> "$notice"; }
    finish_install_transaction 7
)
failed_rc=$?
prepublication_notice="$TMP/prepublication-notice"
(
    ARTIFACT_STAGE="$TMP/unwind-stage-3"
    INSTALL_PUBLICATION_STARTED=0
    mkdir -p "$ARTIFACT_STAGE"
    cleanup_artifact_stage() { return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { printf '%s\n' "$*" >> "$prepublication_notice"; }
    finish_install_transaction 8
)
prepublication_rc=$?
set -e
[[ "$cleanup_rc" == 1 && "$failed_rc" == 7 && "$prepublication_rc" == 8 ]] \
    || fail "the unwind lost a cleanup failure or rewrote the original exit status"
grep -q 'does not roll back' "$notice" \
    || fail "a publication-phase failure never tells the operator the host may be partially installed"
grep -q 'Publication did not start' "$prepublication_notice" \
    || fail "a pre-publication failure is mislabeled as a partial install"
pass "unwind failures surface with distinct pre-publication and may-be-partial notices"

# HUP/INT/TERM are ignored once finalization starts, so a second signal cannot
# cut the unwind short and strand a lock.
reentry_marker="$TMP/finish-signal-reentered"
set +e
(
    ARTIFACT_STAGE="$TMP/signal-stage"
    mkdir -p "$ARTIFACT_STAGE"
    trap ': > "$reentry_marker"' HUP
    cleanup_artifact_stage() { kill -HUP "$BASHPID"; return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 0
)
signal_rc=$?
set -e
[[ "$signal_rc" == 0 && ! -e "$reentry_marker" ]] \
    || fail "a signal reentered or interrupted the unwind path"
pass "signals cannot interrupt or reenter the unwind path"

printf '%s\n' "test_install_transaction_safety: PASS"
