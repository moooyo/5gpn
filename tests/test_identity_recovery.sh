#!/usr/bin/env bash
# Current fivegpn identity repair and interrupted-reconciliation contracts.
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
pass "current identity, binary, and state constants are canonical"

full_install_body="$(sed -n '/^full_install()/,/^}/p' "$ROOT/install.sh")"
install_line_of() {
    local pattern="$1"
    grep -nE "$pattern" <<<"$full_install_body" | head -1 | cut -d: -f1
}
publication_line="$(install_line_of 'INSTALL_PUBLICATION_STARTED=1')"
account_line="$(install_line_of '^[[:space:]]*install_service_accounts([[:space:]]|$)')"
reconcile_line="$(install_line_of '^[[:space:]]*reconcile_fivegpn_state_directory([[:space:]]|$)')"
permissions_line="$(install_line_of '^[[:space:]]*prepare_runtime_permissions([[:space:]]|$)')"
assert_line="$(install_line_of '^[[:space:]]*assert_replaced_fivegpn_identity_reconciled([[:space:]]|$)')"
complete_line="$(install_line_of '^[[:space:]]*complete_replaced_fivegpn_identity_reconciliation([[:space:]]|$)')"
start_line="$(install_line_of '^[[:space:]]*start_services_with_cert_lock_handoff([[:space:]]|$)')"
[[ -n "$publication_line" && -n "$account_line" && -n "$reconcile_line" \
   && -n "$permissions_line" && -n "$assert_line" && -n "$complete_line" \
   && -n "$start_line" && "$publication_line" -lt "$account_line" \
   && "$account_line" -lt "$reconcile_line" \
   && "$reconcile_line" -lt "$permissions_line" \
   && "$permissions_line" -lt "$assert_line" \
   && "$assert_line" -lt "$complete_line" \
   && "$complete_line" -lt "$start_line" ]] \
    || fail "full install can clear identity recovery state or start services before reconciliation"
pass "full install clears the identity journal only after reconciliation and before service start"

provenance_fn="$(sed -n '/^current_deployment_proves_identity_repair()/,/^}/p' "$ROOT/install.sh")"
[[ -n "$provenance_fn" ]] || fail "current identity provenance helper is missing"
grep -Fq 'current_root_marker_proves_deployment' <<<"$provenance_fn" \
    || fail "current root markers do not participate in identity provenance"
grep -Eq 'current_managed_unit_file_is_safe|preflight_current_managed_unit_definition' \
    <<<"$provenance_fn" \
    || fail "the marked current main unit does not participate in identity provenance"
pass "identity repair provenance is limited to current markers or the marked main unit"

for proof in marker unit; do
    (
        PROOF="$proof"
        current_root_marker_proves_deployment() { [[ "$PROOF" == marker ]]; }
        current_managed_unit_file_is_safe() {
            [[ "$PROOF" == unit && "$1" == 5gpn-mihomo.service ]]
        }
        preflight_current_managed_unit_definition() {
            [[ "$PROOF" == unit && "$1" == 5gpn-mihomo.service ]]
        }
        current_deployment_proves_identity_repair
    ) || fail "$proof provenance did not authorize current identity recovery"
done
pass "either safe current marker or marked main-unit provenance is sufficient"

(
    current_root_marker_proves_deployment() { return 1; }
    current_managed_unit_file_is_safe() { return 1; }
    preflight_current_managed_unit_definition() { return 1; }
    ! current_deployment_proves_identity_repair
) || fail "identity provenance accepted a fresh host without current proof"
pass "identity repair provenance fails when neither current proof exists"

for proof in marker unit; do
    (
        PROOF="$proof"
        FIVEGPN_SERVICE_USER=fivegpn
        FIVEGPN_SERVICE_GROUP=fivegpn
        FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
        REPLACED_FIVEGPN_UID=""
        REPLACED_FIVEGPN_GID=""
        REPLACED_FIVEGPN_NAMED_GID=""
        current_root_marker_proves_deployment() { [[ "$PROOF" == marker ]]; }
        current_managed_unit_file_is_safe() {
            [[ "$PROOF" == unit && "$1" == 5gpn-mihomo.service ]]
        }
        getent() {
            case "$1" in
                passwd) printf 'fivegpn:x:498:499::/wrong:/bin/bash\n' ;;
                group) printf 'fivegpn:x:499:\n' ;;
                *) return 1 ;;
            esac
        }
        id() {
            case "$1" in
                -u) printf '498\n' ;;
                -g|-G) printf '499\n' ;;
                *) return 1 ;;
            esac
        }
        service_account_is_safe() { return 1; }
        managed_user_uid_is_exclusive() { return 0; }
        managed_primary_gid_is_exclusive_for_user() { return 0; }
        managed_group_gid_is_exclusive() { return 0; }
        identity_id_is_in_system_range() { return 0; }
        preload_fivegpn_identity_for_claim
        [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 1 ]]
        [[ "$REPLACED_FIVEGPN_UID:$REPLACED_FIVEGPN_GID:$REPLACED_FIVEGPN_NAMED_GID" == 498:499:499 ]]
    ) || fail "$proof provenance did not authorize pre-publication identity repair"
done
pass "preload authorizes repair only after current provenance and ID checks"

# A same-named account on a fresh host is foreign. Name and exclusive numeric
# IDs alone never authorize deletion or adoption.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    getent() {
        case "$1" in
            passwd) printf 'fivegpn:x:498:499::/wrong:/bin/bash\n' ;;
            group) printf 'fivegpn:x:499:\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '498\n' ;;
            -g|-G) printf '499\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    current_deployment_proves_identity_repair() { return 1; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    persist_replaced_fivegpn_identity() { fail "foreign identity was journaled"; }
    remove_managed_account_identity() { fail "foreign identity was removed"; }
    ! preload_fivegpn_identity_for_claim >/dev/null 2>&1
    [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 0 ]]
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "a foreign same-named fivegpn identity was adopted or changed"
pass "foreign fivegpn identity without current provenance is rejected unchanged"

(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=0
    getent() {
        case "$1" in
            passwd) printf 'fivegpn:x:498:499::/wrong:/bin/bash\n' ;;
            group) printf 'fivegpn:x:499:\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '498\n' ;;
            -g|-G) printf '499\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    persist_replaced_fivegpn_identity() { fail "pre-publication repair wrote a journal"; }
    remove_managed_account_identity() { fail "pre-publication repair removed an identity"; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "identity repair crossed the publication boundary early"
pass "destructive current identity repair cannot start before publication"

(
    STATE_DIR="$TMP/journal-sync-failure"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
    user_exists=1
    group_exists=1
    recreated=0
    removed=0
    mkdir -p "$STATE_DIR"
    identity_reconcile_state_root_is_safe() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    chown() { return 0; }
    sync() { [[ "$*" != "-f $STATE_DIR" ]]; }
    getent() {
        case "$1" in
            passwd) [[ "$user_exists" == 1 ]] && printf 'fivegpn:x:498:499::/wrong:/bin/bash\n' ;;
            group) [[ "$group_exists" == 1 ]] && printf 'fivegpn:x:499:\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '498\n' ;;
            -g|-G) printf '499\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    remove_managed_account_identity() {
        removed=1
        user_exists=0
        group_exists=0
    }
    groupadd() { group_exists=1; }
    useradd() { user_exists=1; recreated=1; }
    userdel() { return 0; }
    groupdel() { return 0; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
    [[ "$removed" == 0 ]]
) || fail "identity repair continued after reconciliation-journal directory sync failure"
pass "identity removal waits for durable journal directory synchronization"

for non_system_kind in uid gid; do
    (
        FIVEGPN_SERVICE_USER=fivegpn
        FIVEGPN_SERVICE_GROUP=fivegpn
        FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
        REPLACED_FIVEGPN_UID=""
        REPLACED_FIVEGPN_GID=""
        REPLACED_FIVEGPN_NAMED_GID=""
        getent() {
            case "$1" in
                passwd) printf 'fivegpn:x:1500:1600::/wrong:/bin/bash\n' ;;
                group) printf 'fivegpn:x:1600:\n' ;;
                *) return 1 ;;
            esac
        }
        id() {
            case "$1" in
                -u) printf '1500\n' ;;
                -g|-G) printf '1600\n' ;;
                *) return 1 ;;
            esac
        }
        service_account_is_safe() { return 1; }
        current_deployment_proves_identity_repair() { return 0; }
        managed_user_uid_is_exclusive() { return 0; }
        managed_group_gid_is_exclusive() { return 0; }
        identity_id_is_in_system_range() {
            [[ "$1" != "$non_system_kind" ]]
        }
        persist_replaced_fivegpn_identity() { fail "normal-range identity was journaled"; }
        remove_managed_account_identity() { fail "normal-range identity was removed"; }
        ! preload_fivegpn_identity_for_claim >/dev/null 2>&1
        [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 0 ]]
    ) || fail "a non-system $non_system_kind was authorized for identity repair"
done
pass "normal-range UIDs and GIDs are never eligible for current identity repair"

(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
    INSTALL_PUBLICATION_STARTED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    getent() {
        case "$1" in
            passwd) printf 'fivegpn:x:498:499::/wrong:/bin/bash\n' ;;
            group) printf 'fivegpn:x:499:\nunrelated:x:777:fivegpn\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -u) printf '498\n' ;;
            -g) printf '499\n' ;;
            -G) printf '499 777\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    current_deployment_proves_identity_repair() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    persist_replaced_fivegpn_identity() { fail "supplementary-group identity was journaled"; }
    remove_managed_account_identity() { fail "supplementary-group identity was removed"; }
    ! preload_fivegpn_identity_for_claim >/dev/null 2>&1
    [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 0 ]]
) || fail "destructive repair accepted an identity with unrelated supplementary groups"
pass "supplementary group membership blocks current identity repair"

# Current runtime state may be left with inherited special bits after an
# interrupted permission pass. Recovery restores the exact state contract.
(
    state="$TMP/state-modes"
    mkdir -p "$state/dns-rules"
    printf 'private\n' > "$state/dns.json"
    printf 'request\n' > "$state/certificate-request"
    printf 'cache\n' > "$state/dns-rules/cache.txt"
    chmod 02711 "$state"
    chmod 02770 "$state/dns-rules"
    chmod 0666 "$state/dns.json" "$state/certificate-request" "$state/dns-rules/cache.txt"
    normalize_fivegpn_state_tree_permissions "$state"
    [[ "$(file_mode "$state")" == 711 ]]
    [[ "$(file_mode "$state/dns-rules")" == 700 ]]
    [[ "$(file_mode "$state/dns.json")" == 600 ]]
    [[ "$(file_mode "$state/dns-rules/cache.txt")" == 600 ]]
    [[ "$(file_mode "$state/certificate-request")" == 644 ]]
) || fail "current state permission recovery did not restore exact modes"
pass "current state permission recovery clears special bits and restores exact modes"

# Once current provenance, system-range IDs, and exclusivity have been proven
# before publication, an incompatible current identity can be recreated with
# stable numeric IDs.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
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
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    persist_replaced_fivegpn_identity() {
        printf 'persist\n' >> "$calls"
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
    [[ "$(sed -n '1p' "$calls")" == persist ]]
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
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
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
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { [[ "$recreated" == 1 ]]; }
    service_group_is_exclusive_for_user() { return 0; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    identity_id_is_in_system_range() { return 0; }
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
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
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
    identity_id_is_in_system_range() { return 0; }
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

# Aliased IDs or shared membership are not safe to delete because they may own
# unrelated host data.
(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
    getent() {
        case "$1" in
            passwd) printf 'fivegpn:x:998:999::/wrong:/bin/bash\n' ;;
            group) printf 'fivegpn:x:999:\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    managed_user_uid_is_exclusive() { return 1; }
    managed_primary_gid_is_exclusive_for_user() { return 1; }
    managed_group_gid_is_exclusive() { return 1; }
    identity_id_is_in_system_range() { return 0; }
    remove_managed_account_identity() { fail "aliased identity was removed"; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "an aliased fivegpn identity reached destructive reconciliation"
pass "aliased numeric ownership fails closed"

(
    FIVEGPN_SERVICE_USER=fivegpn
    FIVEGPN_SERVICE_GROUP=fivegpn
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
    INSTALL_PUBLICATION_STARTED=1
    getent() {
        case "$1" in
            passwd) return 1 ;;
            group) printf 'fivegpn:x:999:unknown-member\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe() { return 1; }
    managed_group_gid_is_exclusive() { return 1; }
    identity_id_is_in_system_range() { return 0; }
    groupdel() { fail "shared or unknown group membership was deleted"; }
    ! ensure_service_account fivegpn fivegpn >/dev/null 2>&1
) || fail "a shared or unknown fivegpn group reached destructive reconciliation"
pass "shared or unknown group membership fails closed"

# Current-account processes receive a bounded passive drain period. The
# installer never sends signals to force identity replacement.
(
    counter="$TMP/transient-process.count"
    printf '0\n' > "$counter"
    ACCOUNT_QUIESCE_TIMEOUT=5
    ACCOUNT_QUIESCE_INTERVAL=1
    getent() { [[ "$1:$2" == passwd:fivegpn ]]; }
    managed_account_process_snapshot() {
        n="$(cat "$counter")"
        n=$((n + 1))
        printf '%s\n' "$n" > "$counter"
        (( n < 3 )) && printf '101 1 S current-worker current-worker --shutdown\n'
        return 0
    }
    sleep() { return 0; }
    info() { return 0; }
    kill() { fail "quiescence wait sent a signal"; }
    wait_managed_account_quiescent fivegpn
    [[ "$(cat "$counter")" == 3 ]]
) || fail "a transient managed-account process did not drain within the bounded wait"
pass "transient fivegpn processes drain without signals"

(
    ACCOUNT_QUIESCE_TIMEOUT=3
    ACCOUNT_QUIESCE_INTERVAL=1
    getent() { [[ "$1:$2" == passwd:fivegpn ]]; }
    managed_account_process_snapshot() { printf '202 1 D stuck-worker stuck-worker --stuck\n'; }
    sleep() { return 0; }
    info() { return 0; }
    err() { printf '%s\n' "$*" >&2; }
    kill() { fail "persistent-process timeout sent a signal"; }
    ! wait_managed_account_quiescent fivegpn 2> "$TMP/persistent-process.err"
    grep -Fq 'still owns running processes after 3s' "$TMP/persistent-process.err"
    grep -Fq '202 1 D stuck-worker stuck-worker --stuck' "$TMP/persistent-process.err"
) || fail "a persistent managed-account process did not fail with PID/command diagnostics"
pass "persistent fivegpn processes fail after the bounded wait with diagnostics"

# If account recreation receives different numeric IDs, all installer-managed
# roots must be reconciled before the service may start.
(
    BASE_DIR="$TMP/reconcile/base"
    CONF_DIR="$TMP/reconcile/conf"
    STATE_DIR="$TMP/reconcile/state"
    INTERCEPT_STATE_DIR="$TMP/reconcile/intercept"
    INTERCEPT_CA_DIR="$TMP/reconcile/ca"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"
    REPLACED_FIVEGPN_UID=998
    REPLACED_FIVEGPN_GID=999
    id() { [[ "$1" == -u ]] && printf '1001\n' || printf '1002\n'; }
    managed_roots_have_no_nested_mounts() { return 0; }
    find() { printf '%s\n' "$BASE_DIR/stale-owner"; }
    ! assert_replaced_fivegpn_identity_reconciled >/dev/null 2>&1
) || fail "a managed path carrying the replaced IDs was accepted"
pass "residual replaced numeric ownership blocks startup"

(
    BASE_DIR="$TMP/reconciled/base"
    CONF_DIR="$TMP/reconciled/conf"
    STATE_DIR="$TMP/reconciled/state"
    INTERCEPT_STATE_DIR="$TMP/reconciled/intercept"
    INTERCEPT_CA_DIR="$TMP/reconciled/ca"
    mkdir -p "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"
    REPLACED_FIVEGPN_UID=998
    REPLACED_FIVEGPN_GID=999
    id() { [[ "$1" == -u ]] && printf '1001\n' || printf '1002\n'; }
    managed_roots_have_no_nested_mounts() { return 0; }
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

# CA publication recovery distinguishes an incomplete live trust root from an
# unpublished candidate. It never replaces bytes already visible to clients.
(
    INTERCEPT_CA_DIR="$TMP/ca-live-singleton"
    mkdir -p "$INTERCEPT_CA_DIR"
    printf 'published-root\n' > "$INTERCEPT_CA_DIR/root.crt"
    cp "$INTERCEPT_CA_DIR/root.crt" "$TMP/ca-live-singleton.before"
    root_plain_file_metadata_is_safe() { return 0; }
    validate_intercept_ca_pair() { return 1; }
    ! recover_intercept_ca_publication >/dev/null 2>&1
    cmp -s "$TMP/ca-live-singleton.before" "$INTERCEPT_CA_DIR/root.crt"
) || fail "an incomplete live interception CA was silently replaced"
pass "an incomplete live interception CA fails closed without changing trust-root bytes"

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

for partial_shape in user_only group_only; do
    (
        if [[ "$partial_shape" == user_only ]]; then
            REPLACED_FIVEGPN_UID=901
            REPLACED_FIVEGPN_GID=902
            REPLACED_FIVEGPN_NAMED_GID=""
        else
            REPLACED_FIVEGPN_UID=""
            REPLACED_FIVEGPN_GID=902
            REPLACED_FIVEGPN_NAMED_GID=902
        fi
        load_identity_reconcile_journal() { return 0; }
        current_deployment_proves_identity_repair() { return 0; }
        identity_reconcile_journal_file_is_safe() { return 0; }
        identity_id_is_in_system_range() { return 0; }
        getent() { return 1; }
        managed_group_gid_is_exclusive() { return 0; }
        journaled_identity_recovery_is_safe
    ) || fail "$partial_shape journal cannot recover after account removal"
done
pass "safe user-only and group-only journals retain an account-removal recovery path"

(
    REPLACED_FIVEGPN_UID=901
    REPLACED_FIVEGPN_GID=902
    REPLACED_FIVEGPN_NAMED_GID=""
    load_identity_reconcile_journal() { return 0; }
    current_deployment_proves_identity_repair() { return 0; }
    identity_reconcile_journal_file_is_safe() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    getent() {
        [[ "$1:${2:-}" == group:902 ]] && printf 'foreign:x:902:\n'
    }
    ! journaled_identity_recovery_is_safe
) || fail "user-only journal adopted a foreign primary-GID group"
pass "user-only journal recovery rejects a primary GID claimed by another group"

# The replacement IDs survive an interruption. A second installer process
# loads them before claiming account-owned roots and removes the journal only
# after the numeric-ID sweep finishes.
journal_state="$TMP/journal-state"
mkdir -p "$journal_state"
(
    fake_bin="$TMP/journal-fake-bin"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/chown"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/sync"
    chmod 0755 "$fake_bin/chown" "$fake_bin/sync"
    PATH="$fake_bin:$PATH"
    export PATH
    hash -r
    STATE_DIR="$journal_state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    identity_reconcile_state_root_is_safe() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    persist_replaced_fivegpn_identity 901 902 902
    [[ "$(file_mode "$IDENTITY_RECONCILE_FILE")" == 600 ]]
    grep -Fxq 'uid=901' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'gid=902' "$IDENTITY_RECONCILE_FILE"
    grep -Fxq 'named_gid=902' "$IDENTITY_RECONCILE_FILE"
    ! grep -Fq 'legacy_' "$IDENTITY_RECONCILE_FILE"
) || fail "the first run did not durably publish identity reconciliation state"

# Simulate a crash after the proven current account and group were removed but
# before they were recreated. The safe current deployment provenance and
# durable journal must both survive; the recorded IDs must remain unclaimed.
(
    STATE_DIR="$journal_state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
    INSTALL_PUBLICATION_STARTED=1
    user_exists=0
    group_exists=0
    calls="$TMP/journal-account-recovery.log"
    : > "$calls"
    identity_reconcile_state_root_is_safe() { return 0; }
    identity_reconcile_journal_file_is_safe() { return 0; }
    current_deployment_proves_identity_repair() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    getent() {
        local database="$1" key="${2:-}"
        case "$database:$key" in
            passwd:fivegpn|passwd:901)
                [[ "$user_exists" == 1 ]] \
                    && printf 'fivegpn:x:901:902::/nonexistent:/usr/sbin/nologin\n' ;;
            group:fivegpn|group:902)
                [[ "$group_exists" == 1 ]] && printf 'fivegpn:x:902:\n' ;;
            passwd:)
                [[ "$user_exists" == 1 ]] \
                    && printf 'fivegpn:x:901:902::/nonexistent:/usr/sbin/nologin\n' ;;
            group:)
                [[ "$group_exists" == 1 ]] && printf 'fivegpn:x:902:\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        [[ "$user_exists" == 1 ]] || return 1
        case "$1" in
            -u) printf '901\n' ;;
            -g) printf '902\n' ;;
            -gn) printf 'fivegpn\n' ;;
            -G) printf '902\n' ;;
            *) return 1 ;;
        esac
    }
    service_group_is_exclusive_for_user() { [[ "$group_exists" == 1 ]]; }
    service_account_is_safe() { [[ "$user_exists" == 1 && "$group_exists" == 1 ]]; }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    managed_group_gid_is_exclusive() { return 0; }
    groupadd() {
        printf 'groupadd %s\n' "$*" >> "$calls"
        [[ "$*" == *'--gid 902 fivegpn'* ]]
        group_exists=1
    }
    useradd() {
        printf 'useradd %s\n' "$*" >> "$calls"
        [[ "$*" == *'--uid 901'* && "$*" == *'fivegpn'* ]]
        user_exists=1
    }
    userdel() { fail "journal recovery deleted the recreated user"; }
    groupdel() { fail "journal recovery deleted the recreated group"; }
    load_identity_reconcile_journal
    [[ "$REPLACED_FIVEGPN_UID:$REPLACED_FIVEGPN_GID:$REPLACED_FIVEGPN_NAMED_GID" == 901:902:902 ]]
    preload_fivegpn_identity_for_claim
    [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 1 ]]
    ensure_service_account fivegpn fivegpn
    [[ "$user_exists" == 1 && "$group_exists" == 1 ]]
    grep -Fq 'groupadd --system --gid 902 fivegpn' "$calls"
    grep -Fq -- '--uid 901' "$calls"
) || fail "account-absent journal recovery did not require provenance or preserve IDs"
pass "current journal recovery recreates an interrupted identity with the recorded IDs"

for recovery_failure in provenance occupied_uid; do
    (
        STATE_DIR="$journal_state"
        IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
        IDENTITY_RECONCILE_LOADED=0
        REPLACED_FIVEGPN_UID=""
        REPLACED_FIVEGPN_GID=""
        REPLACED_FIVEGPN_NAMED_GID=""
        FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
        identity_reconcile_state_root_is_safe() { return 0; }
        identity_reconcile_journal_file_is_safe() { return 0; }
        current_deployment_proves_identity_repair() { [[ "$recovery_failure" != provenance ]]; }
        identity_id_is_in_system_range() { return 0; }
        file_uid() { printf '0\n'; }
        file_gid() { printf '0\n'; }
        file_mode() { stat -c %a -- "$1"; }
        file_nlink() { stat -c %h -- "$1"; }
        managed_group_gid_is_exclusive() { return 0; }
        getent() {
            case "$1:${2:-}" in
                passwd:901)
                    [[ "$recovery_failure" == occupied_uid ]] \
                        && printf 'foreign:x:901:777::/srv/foreign:/bin/false\n' ;;
                passwd:fivegpn|group:fivegpn|group:902|passwd:|group:) return 1 ;;
                *) return 1 ;;
            esac
        }
        groupadd() { fail "unsafe journal recovery created a group"; }
        useradd() { fail "unsafe journal recovery created a user"; }
        load_identity_reconcile_journal
        ! preload_fivegpn_identity_for_claim >/dev/null 2>&1
        [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 0 ]]
    ) || fail "journal recovery ignored missing $recovery_failure safety"
done
pass "journal recovery refuses missing provenance and reused numeric identities"

(
    STATE_DIR="$journal_state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    IDENTITY_RECONCILE_LOADED=0
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=""
    REPLACED_FIVEGPN_NAMED_GID=""
    identity_reconcile_state_root_is_safe() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { stat -c %a -- "$1"; }
    file_nlink() { stat -c %h -- "$1"; }
    chown() { return 0; }
    sync() { return 0; }
    load_identity_reconcile_journal
    [[ "$REPLACED_FIVEGPN_UID:$REPLACED_FIVEGPN_GID:$REPLACED_FIVEGPN_NAMED_GID" == 901:902:902 ]]

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
    find() { return 0; }
    assert_replaced_fivegpn_identity_reconciled
    complete_replaced_fivegpn_identity_reconciliation
    [[ ! -e "$IDENTITY_RECONCILE_FILE" ]]
) || fail "a second run did not resume and finish identity reconciliation"
pass "current identity reconciliation resumes from the durable journal after interruption"

echo "identity recovery policy: PASS"
