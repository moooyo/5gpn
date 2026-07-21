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
capture_fn="$(sed -n '/^capture_install_rollback()/,/^}/p' "$INSTALL")"
rollback_fn="$(sed -n '/^rollback_install()/,/^}/p' "$INSTALL")"
finish_fn="$(sed -n '/^finish_install_transaction()/,/^}/p' "$INSTALL")"
quarantine_fn="$(sed -n '/^quarantine_managed_units_after_failed_rollback()/,/^}/p' "$INSTALL")"
disable_unit_fn="$(sed -n '/^disable_and_verify_quarantined_unit()/,/^}/p' "$INSTALL")"

line_of() {
    local text="$1" pattern="$2"
    grep -nF "$pattern" <<<"$text" | head -1 | cut -d: -f1
}

install_lock_line="$(line_of "$full_fn" 'acquire_install_lock')"
cert_lock_line="$(line_of "$full_fn" 'acquire_install_cert_lock')"
capture_line="$(line_of "$full_fn" 'capture_install_rollback')"
if [[ -n "$install_lock_line" && -n "$cert_lock_line" && -n "$capture_line" \
   && "$install_lock_line" -lt "$cert_lock_line" \
   && "$cert_lock_line" -lt "$capture_line" ]]; then
    pass "full install holds the independent install lock before the certificate lock"
else
    fail "install/certificate lock order is not explicit"
fi

active_line="$(line_of "$capture_fn" 'INSTALL_TRANSACTION_ACTIVE=1')"
stop_line="$(line_of "$capture_fn" 'stop_units_for_install_snapshot || return 1')"
recheck_line="$(line_of "$capture_fn" 'mihomo_config_matches_install_config')"
snapshot_line="$(line_of "$capture_fn" 'cp -a -- "$BASE_DIR" "$ROLLBACK_DIR/base" || return 1')"
if [[ -n "$active_line" && -n "$stop_line" && -n "$recheck_line" && -n "$snapshot_line" \
   && "$active_line" -lt "$stop_line" && "$stop_line" -lt "$recheck_line" \
   && "$recheck_line" -lt "$snapshot_line" ]]; then
    pass "transaction is armed before the service fence and snapshots only revalidated stopped state"
else
    fail "service fence and snapshot ordering is unsafe"
fi

grep -Fq 'PRESERVE_ROLLBACK_STAGE=1' <<<"$finish_fn" \
    || fail "incomplete rollback does not retain its recovery snapshot"
grep -Fq 'rollback_install || true' "$INSTALL" \
    && fail "rollback still runs in an errexit-suppressing OR-list" \
    || pass "rollback is not invoked through an errexit-suppressing OR-list"
grep -Fq 'rollback_created_service_accounts rollback_account_failed' <<<"$rollback_fn" \
    || fail "rollback does not remove every service account created by the transaction"

release_line="$(line_of "$rollback_fn" 'release_install_cert_lock || rollback_lock_failed=1')"
restore_line="$(line_of "$rollback_fn" 'restore_managed_unit_states rollback_service_failed 0 1')"
if [[ -n "$release_line" && -n "$restore_line" && "$release_line" -lt "$restore_line" ]]; then
    pass "rollback releases the certificate lock before restoring active services"
else
    fail "rollback can deadlock a service that requires the certificate oneshot"
fi

commit_line="$(line_of "$full_fn" 'INSTALL_TRANSACTION_ACTIVE=0 ROLLBACK_SNAPSHOT_READY=0')"
timer_restore_line="$(line_of "$full_fn" 'restore_global_certbot_timer_after_success')"
cleanup_line="$(line_of "$full_fn" 'cleanup_artifact_stage')"
if [[ -n "$commit_line" && -n "$timer_restore_line" && -n "$cleanup_line" \
   && "$commit_line" -lt "$timer_restore_line" && "$commit_line" -lt "$cleanup_line" ]]; then
    pass "verified deployment commits before global-timer restore and stage cleanup"
else
    fail "post-commit timer or cleanup failure can trigger rollback without a snapshot"
fi

grep -Fq 'systemctl disable --now "$unit"' <<<"$disable_unit_fn" \
    || fail "incomplete rollback does not remove reboot enablement"
grep -Fq 'restore_managed_unit_states rollback_service_failed "$rollback_cert_failed" 0' <<<"$rollback_fn" \
    || fail "incomplete rollback can restore enabled-on-boot state"
grep -Fq 'restore_unit_enablement certbot.timer' <<<"$quarantine_fn" \
    || fail "incomplete rollback can disable unrelated Certbot renewal"
pass "incomplete rollback quarantines project units without sacrificing unrelated Certbot renewal"

# Exercise both locks and prove that a stale boolean cannot masquerade as a
# live certificate-lock descriptor.
lock_root="$TMP/locks"
mkdir -m 0700 "$lock_root"
INSTALL_LOCK_FILE="$lock_root/install.lock"
CERT_RENEW_LOCK_FILE="$lock_root/cert.lock"
INSTALL_LOCK_HELD=0
INSTALL_CERT_LOCK_HELD=0
file_uid() { printf '0\n'; }
info() { :; }
err() { printf '%s\n' "$*" >&2; }

acquire_install_lock || fail "could not acquire the test install lock"
acquire_install_cert_lock || fail "could not acquire the test certificate lock"
if flock -n "$INSTALL_LOCK_FILE" -c true 2>/dev/null \
   || flock -n "$CERT_RENEW_LOCK_FILE" -c true 2>/dev/null; then
    fail "a competing process entered a held transaction lock"
fi
exec 8>&-
INSTALL_CERT_LOCK_HELD=1
ensure_install_cert_lock_for_rollback \
    || fail "rollback trusted a stale boolean instead of reopening descriptor 8"
lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" \
    || fail "rollback did not restore a live certificate-lock descriptor"
flock -n "$CERT_RENEW_LOCK_FILE" -c true 2>/dev/null \
    && fail "reacquired certificate lock is not exclusive"
release_install_cert_lock || fail "could not release the test certificate lock"
flock -n "$CERT_RENEW_LOCK_FILE" -c true \
    || fail "certificate lock remained held after release"
flock -n "$INSTALL_LOCK_FILE" -c true 2>/dev/null \
    && fail "install lock was released during certificate-lock handoff"
release_install_lock || fail "could not release the test install lock"
flock -n "$INSTALL_LOCK_FILE" -c true \
    || fail "install lock remained held after transaction completion"
pass "lock descriptors are independently exclusive and rollback revalidates the real FD"

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

# Fresh fixed roots are pre-transaction state, not an installation artifact.
# A failure before the immutable snapshot must remove roots created by claim.
fresh_root="$TMP/fresh-roots"
BASE_DIR="$fresh_root/opt"
CONF_DIR="$fresh_root/etc"
STATE_DIR="$fresh_root/state"
file_gid() { printf '0\n'; }
record_project_root_prestate
install() {
    if [[ "$#" == 9 && "$1" == -d && "$2" == -o && "$3" == root \
       && "$4" == -g && "$5" == root && "$6" == -m && "$7" == 0755 \
       && "$8" == -- ]]; then
        command install -d -m 0755 -- "$9"
        return
    fi
    command install "$@"
}
claim_project_roots || fail "could not claim fresh project roots in the regression fixture"
unset -f install
[[ -d "$BASE_DIR" && -d "$CONF_DIR" && -d "$STATE_DIR" ]] \
    || fail "fresh root fixture was not created"
fresh_cleanup_failed=0
cleanup_pretransaction_project_roots fresh_cleanup_failed
[[ "$fresh_cleanup_failed" == 0 && ! -e "$BASE_DIR" && ! -e "$CONF_DIR" \
   && ! -e "$STATE_DIR" && "$PRETRANSACTION_ROOTS_ACTIVE" == 0 ]] \
    || fail "pre-snapshot failure left newly claimed project roots behind"
pass "fresh BASE/CONF/STATE claims restore to absence before snapshot publication"

# With interception enabled, its readiness probe depends on mihomo's
# authenticated SOCKS listeners. Prove that the lifecycle loop establishes the
# data plane before probing the sidecar, then starts DNS last.
intercept_stub="$TMP/intercept-check"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$intercept_stub"
chmod 0755 "$intercept_stub"
service_order="$TMP/service-order"
mihomo_ready="$TMP/mihomo-ready"
INTERCEPT_BIN="$intercept_stub"
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
systemctl() {
    local action="$1" unit="${*: -1}"
    case "$action" in
        daemon-reload|enable) return 0 ;;
        restart|start)
            case "$unit" in
                mihomo) : > "$mihomo_ready"; printf 'mihomo\n' >> "$service_order" ;;
                5gpn-intercept)
                    [[ -e "$mihomo_ready" ]] || return 91
                    printf 'intercept\n' >> "$service_order" ;;
                5gpn-dns) printf 'dns\n' >> "$service_order" ;;
            esac ;;
        stop) return 0 ;;
        *) return 0 ;;
    esac
}
wait_service_ready() {
    [[ "$1" != 5gpn-intercept || -e "$mihomo_ready" ]] || return 92
    return 0
}
start_services || fail "enabled interception was probed before mihomo became ready"
[[ "$(tr '\n' ' ' < "$service_order")" == 'mihomo intercept dns ' ]] \
    || fail "service start order is not mihomo -> intercept -> DNS"
pass "active interception starts and probes only after the mihomo data plane"
unset -f systemctl wait_service_ready resolve_mihomo_listen_ips

# A failed removal must never be followed by a copy over the live external
# tree. The pristine snapshot remains available for a manual recovery.
ROLLBACK_DIR="$TMP/rollback-tree"
mkdir -p "$ROLLBACK_DIR/external-web" "$TMP/live-web"
printf '%s\n' old > "$TMP/live-web/content"
printf '%s\n' marker > "$TMP/live-web/.owned"
printf '%s\n' snapshot > "$ROLLBACK_DIR/external-web/content"
printf '%s\n' marker > "$ROLLBACK_DIR/external-web/.owned"
remove_public_owned_tree() { return 1; }
tree_failed=0
restore_external_owned_tree "$TMP/live-web" .owned marker external-web tree_failed
[[ "$tree_failed" == 1 && "$(cat "$TMP/live-web/content")" == old ]] \
    || fail "external rollback copied over a tree whose removal failed"
pass "external asset rollback stops after a failed live-tree removal"

static_publish_parent_is_safe() { return 0; }
ROLLBACK_DIR="$TMP/external-three-state"
mkdir -p "$ROLLBACK_DIR/external-web.empty-unowned" "$TMP/empty-live"
chmod 0711 "$ROLLBACK_DIR/external-web.empty-unowned"
empty_restore_failed=0
restore_external_owned_tree "$TMP/empty-live" .owned marker external-web empty_restore_failed
[[ "$empty_restore_failed" == 0 && -d "$TMP/empty-live" \
   && "$(file_mode "$TMP/empty-live")" == 711 \
   && -z "$(find "$TMP/empty-live" -mindepth 1 -print -quit)" ]] \
    || fail "empty-unowned external tree metadata was not restored"
rm -rf -- "$ROLLBACK_DIR" "$TMP/empty-live"
mkdir -p "$ROLLBACK_DIR" "$TMP/empty-live"
: > "$ROLLBACK_DIR/external-web.absent"
absent_restore_failed=0
restore_external_owned_tree "$TMP/empty-live" .owned marker external-web absent_restore_failed
[[ "$absent_restore_failed" == 0 && ! -e "$TMP/empty-live" ]] \
    || fail "originally absent external tree was left behind"
pass "external web/zashboard rollback distinguishes absent and empty-unowned trees"
unset -f static_publish_parent_is_safe

# Invoke capture from an if-condition (the exact Bash context that suppresses
# errexit in called functions) and inject an I/O failure. Explicit guards must
# prevent a partial snapshot from ever becoming publication-ready.
fault_root="$TMP/capture-fault"
ARTIFACT_STAGE="$fault_root/stage"
BASE_DIR="$fault_root/base"
CONF_DIR="$fault_root/conf"
STATE_DIR="$fault_root/state"
INTERCEPT_CA_DIR="$fault_root/intercept-ca"
INTERCEPT_STATE_DIR="$fault_root/intercept-state"
POLKIT_RULE_PATH="$fault_root/polkit-rule"
DNS_WEB_DIR="$BASE_DIR/web"
DNS_ZASH_DIR="$BASE_DIR/zash"
mkdir -p "$ARTIFACT_STAGE" "$BASE_DIR" "$CONF_DIR" "$STATE_DIR"
printf '%s\n' rule > "$POLKIT_RULE_PATH"
TRANSACTION_UNIT_FILES=()
TRANSACTION_STATE_UNITS=()
TRANSACTION_STOP_UNITS=()
BASE_ROOT_WAS_ABSENT=0
CONF_ROOT_WAS_ABSENT=0
STATE_ROOT_WAS_ABSENT=0
ROLLBACK_SNAPSHOT_READY=0
systemctl() { [[ "$1" != is-active ]]; }
mihomo_config_matches_install_config() { return 0; }
polkit_rule_owned_by_5gpn() { return 0; }
cfg_get() { return 0; }
cp() {
    local dest="${!#}"
    [[ "$dest" != "$ROLLBACK_DIR/polkit/50-5gpn.rules" ]] || return 73
    command cp "$@"
}
if capture_install_rollback >/dev/null 2>&1; then
    fail "capture succeeded after an injected rollback-snapshot write failure"
fi
[[ "$ROLLBACK_SNAPSHOT_READY" == 0 && ! -e "$ROLLBACK_DIR/.complete" ]] \
    || fail "partial rollback snapshot was marked ready"
pass "snapshot I/O failure cannot be masked by Bash conditional errexit semantics"
INSTALL_TRANSACTION_ACTIVE=0
unset -f systemctl mihomo_config_matches_install_config polkit_rule_owned_by_5gpn cfg_get cp

# Project units are always quarantined. The distro timer is restored when other
# lineages may depend on it, and disabled only when exclusivity is proven.
ROLLBACK_DIR="$TMP/quarantine-rollback"
mkdir -p "$ROLLBACK_DIR/unit-state" "$ROLLBACK_DIR/conf"
printf '%s\n' 'DNS_BASE_DOMAIN=example.com' > "$ROLLBACK_DIR/conf/dns.env"
: > "$ROLLBACK_DIR/unit-state/certbot.timer.exists"
: > "$ROLLBACK_DIR/unit-state/certbot.timer.active"
printf '%s\n' enabled > "$ROLLBACK_DIR/unit-state/certbot.timer.enabled-state"
: > "$ROLLBACK_DIR/unit-state/certbot.timer.fragment-path"
declare -A q_active=([core.service]=1 [certbot.timer]=0)
declare -A q_enabled=([core.service]=1 [certbot.timer]=0)
TRANSACTION_UNIT_FILES=(core.service)
systemctl() {
    local action="$1" unit="${*: -1}"
    case "$action" in
        enable) q_enabled["$unit"]=1 ;;
        disable) q_active["$unit"]=0; q_enabled["$unit"]=0 ;;
        start) q_active["$unit"]=1 ;;
        stop) q_active["$unit"]=0 ;;
        show) printf 'loaded\n' ;;
        is-active)
            if [[ "${q_active[$unit]:-0}" == 1 ]]; then
                [[ "$*" == *--quiet* ]] || printf 'active\n'
            else
                [[ "$*" == *--quiet* ]] || printf 'inactive\n'
                return 3
            fi ;;
        is-enabled)
            if [[ "${q_enabled[$unit]:-0}" == 1 ]]; then
                [[ "$*" == *--quiet* ]] || printf 'enabled\n'
            else
                [[ "$*" == *--quiet* ]] || printf 'disabled\n'
                return 1
            fi ;;
        *) return 0 ;;
    esac
}
certbot_lineage_set_is_exclusive() { return 1; }
quarantine_failed=0
quarantine_managed_units_after_failed_rollback quarantine_failed 1
[[ "$quarantine_failed" == 0 && "${q_active[core.service]}" == 0 \
   && "${q_enabled[core.service]}" == 0 && "${q_active[certbot.timer]}" == 1 \
   && "${q_enabled[certbot.timer]}" == 1 ]] \
    || fail "failed rollback sacrificed an unrelated Certbot timer"
q_active[core.service]=1
q_enabled[core.service]=1
certbot_lineage_set_is_exclusive() { return 0; }
quarantine_failed=0
quarantine_managed_units_after_failed_rollback quarantine_failed 1
[[ "$quarantine_failed" == 0 && "${q_active[core.service]}" == 0 \
   && "${q_enabled[core.service]}" == 0 && "${q_active[certbot.timer]}" == 0 \
   && "${q_enabled[certbot.timer]}" == 0 ]] \
    || fail "exclusive failed lineage left its global renewal timer enabled"
pass "rollback preserves shared Certbot renewal and quarantines an exclusive failed lineage"
unset -f systemctl
unset -f certbot_lineage_set_is_exclusive

# Exact restore covers both boot enablement and current activity, not only the
# certificate timer special case from the previous implementation.
ROLLBACK_DIR="$TMP/unit-restore"
mkdir -p "$ROLLBACK_DIR/unit-state"
for unit in core.service watcher.timer; do
    : > "$ROLLBACK_DIR/unit-state/${unit}.exists"
    : > "$ROLLBACK_DIR/unit-state/${unit}.fragment-path"
done
printf '%s\n' enabled > "$ROLLBACK_DIR/unit-state/core.service.enabled-state"
: > "$ROLLBACK_DIR/unit-state/core.service.active"
printf '%s\n' disabled > "$ROLLBACK_DIR/unit-state/watcher.timer.enabled-state"
: > "$ROLLBACK_DIR/unit-state/watcher.timer.inactive"
TRANSACTION_STATE_UNITS=(core.service watcher.timer)
declare -A r_active=([core.service]=0 [watcher.timer]=1)
declare -A r_enabled=([core.service]=0 [watcher.timer]=1)
systemctl() {
    local action="$1" unit="${*: -1}"
    case "$action" in
        enable) r_enabled["$unit"]=1 ;;
        disable) r_enabled["$unit"]=0; [[ "$*" != *--now* ]] || r_active["$unit"]=0 ;;
        start) r_active["$unit"]=1 ;;
        stop) r_active["$unit"]=0 ;;
        is-active)
            if [[ "${r_active[$unit]:-0}" == 1 ]]; then
                [[ "$*" == *--quiet* ]] || printf 'active\n'
            else
                [[ "$*" == *--quiet* ]] || printf 'inactive\n'
                return 3
            fi ;;
        is-enabled)
            if [[ "${r_enabled[$unit]:-0}" == 1 ]]; then
                [[ "$*" == *--quiet* ]] || printf 'enabled\n'
            else
                [[ "$*" == *--quiet* ]] || printf 'disabled\n'
                return 1
            fi ;;
        *) return 0 ;;
    esac
}
restore_failed=0
restore_managed_unit_states restore_failed 0 1
[[ "$restore_failed" == 0 && "${r_active[core.service]}" == 1 \
   && "${r_enabled[core.service]}" == 1 && "${r_active[watcher.timer]}" == 0 \
   && "${r_enabled[watcher.timer]}" == 0 ]] \
    || fail "rollback did not restore exact enabled/active state for every managed unit"
pass "rollback restores exact boot enablement and activity state for managed units"
unset -f systemctl

# The transaction finalizer must leave the stage untouched when rollback is
# incomplete, even though it still releases both lock classes before exiting.
cleanup_marker="$TMP/cleanup-called"
set +e
(
    INSTALL_TRANSACTION_ACTIVE=1
    ROLLBACK_IN_PROGRESS=0
    PRESERVE_ROLLBACK_STAGE=0
    ARTIFACT_STAGE="$TMP/retained-stage"
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    mkdir -p "$ROLLBACK_DIR"
    ensure_install_cert_lock_for_rollback() { return 0; }
    rollback_install() { return 1; }
    cleanup_artifact_stage() { : > "$cleanup_marker"; return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 47
)
finish_rc=$?
set -e
[[ "$finish_rc" == 47 && ! -e "$cleanup_marker" && -d "$TMP/retained-stage/rollback" ]] \
    || fail "incomplete rollback cleaned or lost its retained snapshot"
pass "incomplete rollback preserves the recovery stage and original failure status"

# An uncommitted EXIT with status zero is still a failed installation. This
# also proves that post-commit (ACTIVE=0) cleanup failure never calls rollback.
set +e
(
    INSTALL_TRANSACTION_ACTIVE=1
    ROLLBACK_IN_PROGRESS=0
    PRESERVE_ROLLBACK_STAGE=0
    ARTIFACT_STAGE="$TMP/uncommitted-stage"
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    mkdir -p "$ROLLBACK_DIR"
    ensure_install_cert_lock_for_rollback() { return 0; }
    rollback_install() { return 0; }
    cleanup_artifact_stage() { return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 0
)
uncommitted_rc=$?
rollback_marker="$TMP/postcommit-rollback-called"
(
    INSTALL_TRANSACTION_ACTIVE=0
    PRESERVE_ROLLBACK_STAGE=0
    ARTIFACT_STAGE="$TMP/postcommit-stage"
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    mkdir -p "$ROLLBACK_DIR"
    rollback_install() { : > "$rollback_marker"; return 0; }
    cleanup_artifact_stage() { return 1; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 0
)
postcommit_rc=$?
set -e
[[ "$uncommitted_rc" == 1 && "$postcommit_rc" == 1 && ! -e "$rollback_marker" ]] \
    || fail "transaction finalizer reported uncommitted success or rolled back a committed deployment"
pass "uncommitted zero-status exits fail, while post-commit cleanup never invokes rollback"

# HUP/INT/TERM are ignored after finalization starts so a second signal cannot
# reenter or interrupt the bounded rollback.
reentry_marker="$TMP/rollback-signal-reentered"
set +e
(
    INSTALL_TRANSACTION_ACTIVE=1
    ROLLBACK_IN_PROGRESS=0
    PRESERVE_ROLLBACK_STAGE=0
    ARTIFACT_STAGE="$TMP/signal-stage"
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    mkdir -p "$ROLLBACK_DIR"
    trap ': > "$reentry_marker"' HUP
    ensure_install_cert_lock_for_rollback() { return 0; }
    rollback_install() { kill -HUP "$BASHPID"; return 0; }
    cleanup_artifact_stage() { return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 0
)
signal_rc=$?
set -e
[[ "$signal_rc" == 1 && ! -e "$reentry_marker" ]] \
    || fail "HUP interrupted or reentered an in-progress rollback"
pass "HUP cannot interrupt or reenter an in-progress rollback"

timer_restore_marker="$TMP/postcommit-timer-restored"
set +e
(
    INSTALL_TRANSACTION_ACTIVE=0
    POSTCOMMIT_TIMER_RESTORE_PENDING=1
    PRETRANSACTION_ROOTS_ACTIVE=0
    PRESERVE_ROLLBACK_STAGE=0
    ARTIFACT_STAGE="$TMP/postcommit-signal-stage"
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    mkdir -p "$ROLLBACK_DIR"
    restore_global_certbot_timer_after_success() { : > "$timer_restore_marker"; return 0; }
    cleanup_artifact_stage() { return 0; }
    release_install_cert_lock() { return 0; }
    release_install_lock() { return 0; }
    err() { :; }
    finish_install_transaction 129
)
postcommit_signal_rc=$?
set -e
[[ "$postcommit_signal_rc" == 129 && -e "$timer_restore_marker" ]] \
    || fail "post-commit signal left the pre-existing global Certbot timer stopped"
pass "post-commit signal finalization completes global Certbot timer restoration"

printf '%s\n' "test_install_transaction_safety: PASS"
