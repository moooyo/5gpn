#!/usr/bin/env bash
# Current 5gpn identity and one-time legacy-name migration contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TMP="$(mktemp -d /tmp/5gpn-identity-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

[[ "$FIVEGPN_SERVICE_USER" == fivegpn && "$FIVEGPN_SERVICE_GROUP" == fivegpn ]] \
    || fail "the managed Unix identity is not fivegpn:fivegpn"
[[ "$MIHOMO_BIN" == /opt/5gpn/bin/5gpn-mihomo ]] \
    || fail "the installed runtime binary is not 5gpn-prefixed"
[[ "$FIVEGPN_STATE_DIR" == /etc/5gpn/mihomo/5gpn ]] \
    || fail "the current state directory is not 5gpn-prefixed"
[[ "$LEGACY_STATE_DIR" == /etc/5gpn/mihomo/gpn ]] \
    || fail "the exact legacy state migration source changed"
pass "current identity, binary, and state constants are canonical"

# Old-only state is renamed on the same filesystem; it is never copied through
# a partially published second tree.
(
    CONF_DIR="$TMP/state-conf"
    MIHOMO_DIR="$CONF_DIR/mihomo"
    LEGACY_STATE_DIR="$MIHOMO_DIR/gpn"
    FIVEGPN_STATE_DIR="$MIHOMO_DIR/5gpn"
    mkdir -p "$LEGACY_STATE_DIR/dns-rules"
    printf 'state\n' > "$LEGACY_STATE_DIR/dns.json"
    printf 'secret\n' > "$LEGACY_STATE_DIR/intercept.json"
    printf 'request\n' > "$LEGACY_STATE_DIR/certificate-request"
    printf 'cache\n' > "$LEGACY_STATE_DIR/dns-rules/rule.txt"
    chmod 0777 "$LEGACY_STATE_DIR/dns-rules"
    chmod 0666 "$LEGACY_STATE_DIR"/*.json "$LEGACY_STATE_DIR/certificate-request" \
        "$LEGACY_STATE_DIR/dns-rules/rule.txt"
    fixed_owned_dir_is_safe() { return 0; }
    runtime_directory_slot_is_safe() { return 0; }
    runtime_tree_has_only_plain_entries() { return 0; }
    state_directory_metadata_is_reconcilable() { return 0; }
    managed_path_has_no_nested_mounts() { return 0; }
    seal_mihomo_home_for_state_migration() { return 0; }
    seal_state_directory_for_migration() { return 0; }
    restore_mihomo_home_after_state_migration() { return 0; }
    chown() { return 0; }
    sync() { return 0; }
    ok() { return 0; }
    migrate_fivegpn_state_directory
    [[ ! -e "$LEGACY_STATE_DIR" ]]
    [[ "$(cat "$FIVEGPN_STATE_DIR/dns.json")" == state ]]
    [[ "$(stat -c %a "$FIVEGPN_STATE_DIR")" == 711 ]]
    [[ "$(stat -c %a "$FIVEGPN_STATE_DIR/dns-rules")" == 700 ]]
    [[ "$(stat -c %a "$FIVEGPN_STATE_DIR/intercept.json")" == 600 ]]
    [[ "$(stat -c %a "$FIVEGPN_STATE_DIR/certificate-request")" == 644 ]]
) || fail "old-only runtime state was not atomically renamed"
pass "old-only runtime state is renamed to the 5gpn directory"

# Two populated trees are ambiguous and must fail before either is changed.
(
    MIHOMO_DIR="$TMP/conflict-conf/mihomo"
    LEGACY_STATE_DIR="$MIHOMO_DIR/gpn"
    FIVEGPN_STATE_DIR="$MIHOMO_DIR/5gpn"
    mkdir -p "$LEGACY_STATE_DIR" "$FIVEGPN_STATE_DIR"
    printf 'old\n' > "$LEGACY_STATE_DIR/dns.json"
    printf 'new\n' > "$FIVEGPN_STATE_DIR/dns.json"
    state_directory_metadata_is_reconcilable() { return 0; }
    runtime_tree_has_only_plain_entries() { return 0; }
    ! preflight_fivegpn_state_migration >/dev/null 2>&1
    [[ "$(cat "$LEGACY_STATE_DIR/dns.json")" == old ]]
    [[ "$(cat "$FIVEGPN_STATE_DIR/dns.json")" == new ]]
) || fail "conflicting old and current state did not fail before mutation"
pass "two populated state directories fail before mutation"

# The current fivegpn identity is installer-owned. If its shape is incompatible
# but its numeric IDs are exclusive, it is recreated non-interactively with the
# same IDs instead of wedging every reinstall.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    mock_user_exists=1
    mock_group_exists=1
    recreated=0
    calls="$TMP/recreate.log"
    : > "$calls"
    getent() {
        case "$1" in
            passwd) [[ "$mock_user_exists" == 1 ]] && printf 'fivegpn:x:998:999::/wrong:/bin/bash\n' ;;
            group) [[ "$mock_group_exists" == 1 ]] && printf 'fivegpn:x:999:\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    persist_replaced_fivegpn_identity() {
        REPLACED_FIVEGPN_UID="$1"
        REPLACED_FIVEGPN_GID="$2"
        REPLACED_FIVEGPN_NAMED_GID="$3"
    }
    remove_managed_account_identity() {
        printf 'remove\n' >> "$calls"
        mock_user_exists=0
        mock_group_exists=0
    }
    groupadd() {
        printf 'groupadd %s\n' "$*" >> "$calls"
        mock_group_exists=1
    }
    useradd() {
        printf 'useradd %s\n' "$*" >> "$calls"
        mock_user_exists=1
        recreated=1
    }
    userdel() { fail "unexpected userdel rollback"; }
    groupdel() { fail "unexpected groupdel rollback"; }
    created_user=0
    created_group=0
    created_uid=""
    created_gid=""
    ensure_service_account fivegpn fivegpn \
        created_user created_group created_uid created_gid
    [[ "$created_user" == 1 && "$created_group" == 1 ]]
    [[ "$created_uid" == 998 && "$created_gid" == 999 ]]
    grep -Fxq remove "$calls"
    grep -Fq 'groupadd --system --gid 999 fivegpn' "$calls"
    grep -Fq -- '--uid 998 fivegpn' "$calls"
) || fail "an incompatible exclusive fivegpn identity was not recreated"
pass "an incompatible exclusive fivegpn identity is recreated with stable IDs"

# A partial current identity is still ours. User-only and group-only shapes are
# both rebuilt, preserving whichever exclusive system ID already exists.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    mock_user_exists=1
    mock_group_exists=0
    recreated=0
    calls="$TMP/user-only.log"
    : > "$calls"
    getent() {
        case "$1" in
            passwd) [[ "$mock_user_exists" == 1 ]] && printf 'fivegpn:x:998:999::/wrong:/bin/bash\n' ;;
            group) [[ "$mock_group_exists" == 1 ]] && printf 'fivegpn:x:999:\n' ;;
            *) return 1 ;;
        esac
    }
    id() { [[ "$1" == -u ]] && printf '998\n' || { [[ "$1" == -g ]] && printf '999\n'; }; }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    wait_managed_account_quiescent() { return 0; }
    persist_replaced_fivegpn_identity() {
        REPLACED_FIVEGPN_UID="$1"
        REPLACED_FIVEGPN_GID="$2"
        REPLACED_FIVEGPN_NAMED_GID="$3"
    }
    userdel() { printf 'userdel\n' >> "$calls"; mock_user_exists=0; }
    groupdel() { fail "user-only repair deleted an absent group"; }
    groupadd() { printf 'groupadd %s\n' "$*" >> "$calls"; mock_group_exists=1; }
    useradd() { printf 'useradd %s\n' "$*" >> "$calls"; mock_user_exists=1; recreated=1; }
    ensure_service_account fivegpn fivegpn
    grep -Fxq userdel "$calls"
    grep -Fq -- '--uid 998 fivegpn' "$calls"
) || fail "the user-only fivegpn identity was not rebuilt"
pass "a user-only fivegpn identity is rebuilt with its exclusive UID"

(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    mock_user_exists=0
    mock_group_exists=1
    recreated=0
    calls="$TMP/group-only.log"
    : > "$calls"
    getent() {
        case "$1" in
            passwd) [[ "$mock_user_exists" == 1 ]] && printf 'fivegpn:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
            group) [[ "$mock_group_exists" == 1 ]] && printf 'fivegpn:x:999:\n' ;;
            *) return 1 ;;
        esac
    }
    id() { [[ "$1" == -u ]] && printf '998\n' || { [[ "$1" == -g ]] && printf '999\n'; }; }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    persist_replaced_fivegpn_identity() {
        REPLACED_FIVEGPN_GID="$2"
        REPLACED_FIVEGPN_NAMED_GID="$3"
    }
    userdel() { fail "group-only repair deleted an absent user"; }
    groupdel() { printf 'groupdel\n' >> "$calls"; mock_group_exists=0; }
    groupadd() { printf 'groupadd %s\n' "$*" >> "$calls"; mock_group_exists=1; }
    useradd() { printf 'useradd %s\n' "$*" >> "$calls"; mock_user_exists=1; recreated=1; }
    ensure_service_account fivegpn fivegpn
    grep -Fxq groupdel "$calls"
    grep -Fq 'groupadd --system --gid 999 fivegpn' "$calls"
) || fail "the group-only fivegpn identity was not rebuilt"
pass "a group-only fivegpn identity is rebuilt with its exclusive GID"

# Aliased IDs are not safe to delete because they may own unrelated host data.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    getent() {
        case "$1" in
            passwd) printf 'fivegpn:x:998:999::/wrong:/bin/bash\n' ;;
            group) printf 'fivegpn:x:999:\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    managed_user_uid_is_exclusive() { return 1; }
    managed_group_gid_is_exclusive() { return 1; }
    remove_managed_account_identity() { fail "aliased identity was removed"; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "an aliased fivegpn identity reached destructive reconciliation"
pass "aliased numeric ownership fails closed"

(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    getent() {
        case "$1" in
            passwd) return 1 ;;
            group) printf 'fivegpn:x:999:unknown-member\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    managed_group_gid_is_exclusive() { return 1; }
    groupdel() { fail "shared or unknown group membership was deleted"; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "a shared or unknown fivegpn group reached destructive reconciliation"
pass "shared or unknown group membership fails closed"

# Project-specific legacy accounts are sufficient provenance only when their
# complete system-account shape is safe. A generic mihomo account additionally
# needs an owned unit/state or membership in the retired 5gpn overlay groups.
(
    LEGACY_INSTALL_IDENTITY_CONFIRMED=0
    LEGACY_MIHOMO_IDENTITY_CONFIRMED=0
    legacy_mihomo_unit_owned() { return 1; }
    unit_file_has_5gpn_marker() { return 1; }
    fixed_owned_dir_is_safe() { return 0; }
    LEGACY_STATE_DIR="$TMP/no-legacy-state"
    legacy_service_account_is_owned_shape() { return 0; }
    id() { [[ "$1" == -Gn && "$2" == mihomo ]] && printf 'mihomo 5gpn-overlay-ctl\n' || return 1; }
    record_legacy_install_identity_evidence
    [[ "$LEGACY_INSTALL_IDENTITY_CONFIRMED:$LEGACY_MIHOMO_IDENTITY_CONFIRMED" == 1:1 ]]
) || fail "strict project-specific legacy identities did not establish cleanup provenance"
pass "strict gpn accounts and overlay membership establish bounded legacy provenance"

(
    LEGACY_INSTALL_IDENTITY_CONFIRMED=0
    LEGACY_MIHOMO_IDENTITY_CONFIRMED=0
    legacy_mihomo_unit_owned() { return 1; }
    unit_file_has_5gpn_marker() { return 1; }
    fixed_owned_dir_is_safe() { return 0; }
    LEGACY_STATE_DIR="$TMP/no-legacy-state"
    legacy_service_account_is_owned_shape() { [[ "$1" == mihomo ]]; }
    id() { [[ "$1" == -Gn && "$2" == mihomo ]] && printf 'mihomo\n' || return 1; }
    record_legacy_install_identity_evidence
    [[ "$LEGACY_INSTALL_IDENTITY_CONFIRMED:$LEGACY_MIHOMO_IDENTITY_CONFIRMED" == 0:0 ]]
) || fail "an ordinary generic mihomo account was treated as 5gpn-owned"
pass "an ordinary generic mihomo account is not cleanup provenance"

(
    calls="$TMP/disable-before-migrate.log"
    : > "$calls"
    record_legacy_install_identity_evidence() {
        LEGACY_INSTALL_IDENTITY_CONFIRMED=1
        LEGACY_MIHOMO_IDENTITY_CONFIRMED=1
    }
    legacy_mihomo_unit_owned() { return 0; }
    systemctl() {
        case "$1" in
            show) printf 'loaded\n' ;;
            disable) printf 'disable %s\n' "$3" >> "$calls" ;;
            is-enabled) printf 'disabled\n' ;;
            stop) printf 'stop %s\n' "$2" >> "$calls" ;;
            *) return 1 ;;
        esac
    }
    stop_managed_runtime_units
    path_line="$(grep -n '^disable 5gpn-intercept-runtime.path$' "$calls" | cut -d: -f1)"
    sidecar_line="$(grep -n '^disable 5gpn-intercept.service$' "$calls" | cut -d: -f1)"
    [[ -n "$path_line" && -n "$sidecar_line" && "$path_line" -lt "$sidecar_line" ]]
    grep -Fxq 'disable mihomo.service' "$calls"
    grep -Fxq 'stop 5gpn-intercept-cert.service' "$calls"
) || fail "managed triggers/legacy units were not disabled before state migration"
pass "legacy triggers and runtimes are disabled before state migration"

(
    counter="$TMP/transient-process.count"
    printf '0\n' > "$counter"
    ACCOUNT_QUIESCE_TIMEOUT=5
    ACCOUNT_QUIESCE_INTERVAL=1
    getent() { [[ "$1:$2" == passwd:gpn-dns ]]; }
    managed_account_process_snapshot() {
        n="$(cat "$counter")"
        n=$((n + 1))
        printf '%s\n' "$n" > "$counter"
        (( n < 3 )) && printf '101 1 S old-worker old-worker --shutdown\n'
        return 0
    }
    sleep() { return 0; }
    info() { return 0; }
    kill() { fail "quiescence wait sent a signal"; }
    wait_managed_account_quiescent gpn-dns
    [[ "$(cat "$counter")" == 3 ]]
) || fail "a transient managed-account process did not drain within the bounded wait"
pass "transient managed-account processes drain without signals"

(
    ACCOUNT_QUIESCE_TIMEOUT=3
    ACCOUNT_QUIESCE_INTERVAL=1
    getent() { [[ "$1:$2" == passwd:gpn-dns ]]; }
    managed_account_process_snapshot() { printf '202 1 D stuck-worker stuck-worker --stuck\n'; }
    sleep() { return 0; }
    info() { return 0; }
    err() { printf '%s\n' "$*" >&2; }
    kill() { fail "persistent-process timeout sent a signal"; }
    ! wait_managed_account_quiescent gpn-dns 2> "$TMP/persistent-process.err"
    grep -Fq 'still owns running processes after 3s' "$TMP/persistent-process.err"
    grep -Fq '202 1 D stuck-worker stuck-worker --stuck' "$TMP/persistent-process.err"
) || fail "a persistent managed-account process did not fail with PID/command diagnostics"
pass "persistent managed-account processes fail after the bounded wait with diagnostics"

# If account recreation receives different numeric IDs, all installer-managed
# roots must be reconciled before the service may start.
(
    BASE_DIR="$TMP/reconcile/base"
    CONF_DIR="$TMP/reconcile/conf"
    STATE_DIR="$TMP/reconcile/state"
    INTERCEPT_STATE_DIR="$TMP/reconcile/intercept"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR"
    REPLACED_FIVEGPN_UID=998
    REPLACED_FIVEGPN_GID=999
    id() { [[ "$1" == -u ]] && printf '1001\n' || printf '1002\n'; }
    find() { printf '%s\n' "$BASE_DIR/stale-owner"; }
    ! assert_replaced_fivegpn_identity_reconciled >/dev/null 2>&1
) || fail "a managed path carrying the replaced IDs was accepted"
pass "residual replaced numeric ownership blocks startup"

(
    BASE_DIR="$TMP/reconciled/base"
    CONF_DIR="$TMP/reconciled/conf"
    STATE_DIR="$TMP/reconciled/state"
    INTERCEPT_STATE_DIR="$TMP/reconciled/intercept"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR"
    REPLACED_FIVEGPN_UID=998
    REPLACED_FIVEGPN_GID=999
    id() { [[ "$1" == -u ]] && printf '1001\n' || printf '1002\n'; }
    find() { return 0; }
    assert_replaced_fivegpn_identity_reconciled
) || fail "fully reconciled managed roots were rejected"
pass "reconciled managed roots admit startup"

(
    mount_root="$TMP/mounted-root"
    mkdir -p "$mount_root"
    findmnt() { printf '%s\n%s\n' /tmp "$mount_root/nested"; }
    ! managed_path_has_no_nested_mounts "$mount_root" >/dev/null 2>&1
) || fail "a nested managed-root mount was accepted"
pass "nested mounts are rejected before recursive identity mutation"

(
    BASE_DIR="$TMP/find-error/base"
    CONF_DIR="$TMP/find-error/conf"
    STATE_DIR="$TMP/find-error/state"
    INTERCEPT_STATE_DIR="$TMP/find-error/intercept"
    INTERCEPT_CA_DIR="$TMP/find-error/ca"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"
    REPLACED_FIVEGPN_UID=901
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    id() { [[ "$1" == -u ]] && printf '998\n' || printf '999\n'; }
    managed_roots_have_no_nested_mounts() { return 0; }
    find() { return 1; }
    ! assert_replaced_fivegpn_identity_reconciled >/dev/null 2>&1
) || fail "a managed-root scan failure was ignored"
pass "managed-root scan errors fail identity reconciliation closed"

(
    INTERCEPT_CA_DIR="$TMP/ca-live-singleton"
    mkdir -p "$INTERCEPT_CA_DIR"
    printf 'published-root\n' > "$INTERCEPT_CA_DIR/root.crt"
    root_plain_file_metadata_is_safe() { return 0; }
    validate_intercept_ca_pair() { return 1; }
    ! recover_intercept_ca_publication >/dev/null 2>&1
    [[ -f "$INTERCEPT_CA_DIR/root.crt" ]]
) || fail "an incomplete live interception CA was silently replaced"
pass "an incomplete live interception CA fails closed without trust-root replacement"

(
    INTERCEPT_CA_DIR="$TMP/ca-candidate-only"
    mkdir -p "$INTERCEPT_CA_DIR"
    printf 'partial\n' > "$INTERCEPT_CA_DIR/.root.crt.new"
    root_plain_file_metadata_is_safe() { return 0; }
    validate_intercept_ca_pair() { return 1; }
    sync() { return 0; }
    recover_intercept_ca_publication
    [[ ! -e "$INTERCEPT_CA_DIR/.root.crt.new" ]]
) || fail "candidate-only interception CA partial was not safely discarded"
pass "candidate-only interception CA partials are recoverable"

# The replacement IDs and legacy-cleanup provenance survive an interruption.
# A second installer process loads them before claiming account-owned roots,
# completes the numeric-ID sweep, resumes the remaining legacy cleanup, and
# removes the journal only after both phases finish.
journal_state="$TMP/journal-state"
mkdir -p "$journal_state"
(
    STATE_DIR="$journal_state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    IDENTITY_RECONCILE_PREEXISTED=0
    identity_reconcile_state_root_is_safe() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    chown() { return 0; }
    sync() { return 0; }
    persist_replaced_fivegpn_identity 901 902 903
    LEGACY_MIHOMO_IDENTITY_CONFIRMED=1
    persist_legacy_identity_cleanup
    [[ "$(file_mode "$IDENTITY_RECONCILE_FILE")" == 600 ]]
    grep -Fxq 'uid=901' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'gid=902' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'named_gid=903' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'legacy_cleanup=1' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'legacy_mihomo=1' "$IDENTITY_RECONCILE_FILE"
) || fail "the first run did not durably publish identity reconciliation state"

(
    STATE_DIR="$journal_state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    IDENTITY_RECONCILE_PREEXISTED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    IDENTITY_RECONCILE_LEGACY_CLEANUP=0
    IDENTITY_RECONCILE_LEGACY_MIHOMO=0
    LEGACY_INSTALL_IDENTITY_CONFIRMED=0
    LEGACY_MIHOMO_IDENTITY_CONFIRMED=0
    identity_reconcile_state_root_is_safe() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    chown() { return 0; }
    sync() { return 0; }
    load_identity_reconcile_journal
    [[ "$REPLACED_FIVEGPN_UID:$REPLACED_FIVEGPN_GID:$REPLACED_FIVEGPN_NAMED_GID" == 901:902:903 ]]
    [[ "$LEGACY_INSTALL_IDENTITY_CONFIRMED:$LEGACY_MIHOMO_IDENTITY_CONFIRMED" == 1:1 ]]

    mock_runtime_user=0
    mock_runtime_group=0
    runtime_created=0
    reuse_calls="$TMP/resume-reuse.log"
    : > "$reuse_calls"
    getent() {
        case "$1:${2:-}" in
            passwd:fivegpn) [[ "$mock_runtime_user" == 1 ]] && printf 'fivegpn:x:901:903::/nonexistent:/usr/sbin/nologin\n' ;;
            group:fivegpn) [[ "$mock_runtime_group" == 1 ]] && printf 'fivegpn:x:903:\n' ;;
            passwd:901|group:903) return 1 ;;
            passwd:|group:) return 0 ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '901\n' ;;
            -g) printf '903\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { [[ "$runtime_created" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    groupadd() { printf 'groupadd %s\n' "$*" >> "$reuse_calls"; mock_runtime_group=1; }
    useradd() { printf 'useradd %s\n' "$*" >> "$reuse_calls"; mock_runtime_user=1; runtime_created=1; }
    groupdel() { return 0; }
    userdel() { return 0; }
    ensure_service_account fivegpn fivegpn
    grep -Fq 'groupadd --system --gid 903 fivegpn' "$reuse_calls"
    grep -Fq -- '--uid 901 fivegpn' "$reuse_calls"

    BASE_DIR="$TMP/resume/base"
    CONF_DIR="$TMP/resume/conf"
    INTERCEPT_STATE_DIR="$TMP/resume/intercept"
    INTERCEPT_CA_DIR="$TMP/resume/ca"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"
    managed_roots_have_no_nested_mounts() { return 0; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    assert_replaced_fivegpn_identity_reconciled
    complete_replaced_fivegpn_identity_reconciliation
    grep -Fxq 'uid=-' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'legacy_cleanup=1' "$IDENTITY_RECONCILE_FILE"

    LEGACY_SERVICE_USERS=mihomo
    LEGACY_SERVICE_GROUPS='mihomo 5gpn-overlay-ctl'
    mock_user=1
    mock_mihomo_group=1
    mock_overlay_group=1
    getent() {
        case "$1:${2:-}" in
            passwd:mihomo) [[ "$mock_user" == 1 ]] && printf 'mihomo:x:995:987::/nonexistent:/usr/sbin/nologin\n' ;;
            passwd:) [[ "$mock_user" == 0 ]] || printf 'mihomo:x:995:987::/nonexistent:/usr/sbin/nologin\n' ;;
            group:mihomo) [[ "$mock_mihomo_group" == 1 ]] && printf 'mihomo:x:987:\n' ;;
            group:5gpn-overlay-ctl) [[ "$mock_overlay_group" == 1 ]] && printf '5gpn-overlay-ctl:x:985:\n' ;;
            group:)
                [[ "$mock_mihomo_group" == 0 ]] || printf 'mihomo:x:987:\n'
                [[ "$mock_overlay_group" == 0 ]] || printf '5gpn-overlay-ctl:x:985:\n' ;;
            *) return 1 ;;
        esac
    }
    legacy_service_account_is_owned_shape() { return 0; }
    wait_managed_account_quiescent() { return 0; }
    userdel() { mock_user=0; }
    groupdel() {
        if [[ "$1" == mihomo ]]; then mock_mihomo_group=0; fi
        if [[ "$1" == 5gpn-overlay-ctl ]]; then mock_overlay_group=0; fi
        return 0
    }
    account_gid() {
        [[ "$1" == mihomo ]] && printf '987\n' || printf '985\n'
    }
    remove_legacy_service_accounts
    [[ ! -e "$IDENTITY_RECONCILE_FILE" ]]
) || fail "a second run did not resume and finish identity reconciliation"
pass "identity and legacy cleanup resume from the durable journal after interruption"

echo "identity migration policy: PASS"
