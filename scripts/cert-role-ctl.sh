#!/bin/bash
# Shared public-certificate role validator and publisher.
#
# This source-only library owns only the /etc/5gpn/cert/{dot,console}
# generation schema. It does not issue certificates, manage Certbot, edit
# provenance, render profiles, operate systemd, or decide service lifecycle.

declare -F publication_fs_commit_relative_pointer >/dev/null 2>&1 \
    && declare -F publication_fs_mount_id >/dev/null 2>&1 || {
    printf '%s\n' 'cert-role-ctl.sh requires the bundled publication-fs.sh' >&2
    return 1 2>/dev/null || exit 1
}
CERT_ROLE_CTL_API_LOADED=1
CERT_ROLE_CTL_API_VERSION=1

# Certificate-domain adapters over the shared publication-fs primitives. The
# common helper deliberately does not know certificate file metadata or expose
# a generic find collector; those remain narrow schema concerns here.
publication_fs_canonical_directory() { publication_fs_directory_is_canonical "$1"; }
publication_fs_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
publication_fs_mode_is_nonwritable() {
    local mode="$1" value
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    value=$((8#$mode))
    (( (value & 0022) == 0 ))
}
publication_fs_plain_file_is_safe() {
    local path="$1" uid="$2" gid="$3" mode="$4"
    [[ -f "$path" && ! -L "$path" \
       && "$(publication_fs_uid "$path")" == "$uid" \
       && "$(publication_fs_gid "$path")" == "$gid" \
       && "$(publication_fs_mode "$path")" == "$mode" \
       && "$(publication_fs_nlink "$path")" == 1 ]]
}
cert_role_ctl_marker_is_safe() {
    local root="$1" name="$2" value="$3" uid="$4" gid="$5" marker="$1/$2"
    publication_fs_directory_is_canonical "$root" || return 1
    publication_fs_plain_file_is_safe "$marker" "$uid" "$gid" 644 \
        && [[ "$(cat -- "$marker" 2>/dev/null || true)" == "$value" ]]
}
publication_fs_find_entries() {
    local output_name="$1" fd item completed=0
    local -a collected=()
    shift
    exec {fd}< <(find "$@" -print0 && printf '\0') || return 1
    while IFS= read -r -d '' -u "$fd" item; do
        if [[ -z "$item" ]]; then
            [[ "$completed" == 0 ]] || { exec {fd}<&-; return 1; }
            completed=1
        else
            [[ "$completed" == 0 ]] || { exec {fd}<&-; return 1; }
            collected+=("$item")
        fi
    done
    exec {fd}<&-
    [[ "$completed" == 1 ]] || return 1
    local -n output_ref="$output_name"
    output_ref=("${collected[@]}")
}
publication_fs_no_nested_mounts() {
    local root="$1" containing output mount
    publication_fs_directory_is_canonical "$root" || return 1
    containing="$(publication_fs_containing_mount_target "$root")" || return 1
    [[ "$containing" != "$root" ]] || return 1
    output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" || return 1
    [[ -n "$output" ]] || return 1
    while IFS= read -r mount; do
        [[ "$mount" == "$containing" ]] && continue
        case "$mount" in
            "$root"|"$root"/*)
                publication_fs_mount_target_text_is_safe "$mount" || return 1
                return 1
                ;;
        esac
    done <<< "$output"
}
publication_fs_remove_prepared_pointer() {
    local root="$1" pointer="$2" name prefix
    name="$(basename -- "$pointer")" || return 1
    case "$name" in
        .current.*) prefix=.current ;;
        *) return 1 ;;
    esac
    publication_fs_cleanup_orphan_pointer "$root" "$pointer" "$prefix" \
        "$(cert_role_ctl_expected_uid)" "$(cert_role_ctl_expected_root_gid)"
}
PUBLICATION_FS_DELETE_STATE=unchanged

CERT_ROLE_CTL_PRODUCTION_ROOT=/etc/5gpn/cert
CERT_ROLE_CTL_ROOT="$CERT_ROLE_CTL_PRODUCTION_ROOT"
CERT_ROLE_CTL_CONFIG_MARKER=.5gpn-owned
CERT_ROLE_CTL_CONFIG_MARKER_VALUE=5gpn-config
CERT_ROLE_CTL_ROOT_MARKER=.5gpn-cert-root-owned
CERT_ROLE_CTL_ROOT_MARKER_VALUE=5gpn-cert-root-v1
CERT_ROLE_CTL_ROLE_MARKER=.5gpn-cert-role-owned
CERT_ROLE_CTL_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
CERT_ROLE_CTL_SERVICE_GROUP=fivegpn
CERT_ROLE_CTL_SERVICE_GID=""
CERT_ROLE_CTL_ALLOW_CREATE=0
CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
CERT_ROLE_CTL_ADDITIONAL_GIDS=""
CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
CERT_ROLE_CTL_LINEAGE_LIVE_ROOT=/etc/letsencrypt/live
CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT=/etc/letsencrypt/archive
CERT_ROLE_CTL_COMMIT_STATE=uncommitted
CERT_ROLE_CTL_COMMITTED_ROLES=""
CERT_ROLE_CTL_GC_WARNING=0
CERT_ROLE_CTL_GC_STATE=unchanged
CERT_ROLE_CTL_LAST_ERROR=""
CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=unchanged

cert_role_ctl_error() {
    CERT_ROLE_CTL_LAST_ERROR="$*"
    return 1
}

cert_role_ctl_root_is_permitted() {
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        return 0
    fi
    [[ "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
    case "$CERT_ROLE_CTL_ROOT" in
        /tmp/5gpn-*|/var/tmp/5gpn-*|/fixture/*) return 0 ;;
        *) return 1 ;;
    esac
}

cert_role_ctl_expected_uid() {
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        printf '0\n'
    else
        [[ "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
        printf '%s\n' "${EUID:-$(id -u)}"
    fi
}

cert_role_ctl_expected_root_gid() {
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        printf '0\n'
    else
        [[ "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
        id -g
    fi
}

cert_role_ctl_group_name() {
    case "$1" in
        dot|console) printf '%s\n' "$CERT_ROLE_CTL_SERVICE_GROUP" ;;
        *) return 1 ;;
    esac
}

cert_role_ctl_group_gid() {
    local group="$1" entry gid
    if declare -F cert_role_ctl_group_gid_override >/dev/null 2>&1; then
        cert_role_ctl_group_gid_override "$group"
        return
    fi
    if [[ -n "${CERT_ROLE_CTL_SERVICE_GID:-}" && "$group" == "$CERT_ROLE_CTL_SERVICE_GROUP" ]]; then
        [[ "$CERT_ROLE_CTL_SERVICE_GID" =~ ^[0-9]+$ ]] || return 1
        printf '%s\n' "$CERT_ROLE_CTL_SERVICE_GID"
        return
    fi
    entry="$(getent group "$group" 2>/dev/null)" || return 1
    IFS=: read -r _ _ gid _ <<< "$entry"
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

cert_role_ctl_gid_is_allowed() {
    local role="$1" gid="$2" group expected candidate
    local -a _cert_role_ctl_extra_gids=()
    IFS=: read -r -a _cert_role_ctl_extra_gids <<< "$CERT_ROLE_CTL_ADDITIONAL_GIDS"
    for candidate in "${_cert_role_ctl_extra_gids[@]}"; do
        [[ -n "$candidate" && "$candidate" == "$gid" ]] && return 0
    done
    group="$(cert_role_ctl_group_name "$role")" || return 1
    expected="$(cert_role_ctl_group_gid "$group")" || return 1
    [[ "$gid" == "$expected" ]] && return 0
    return 1
}

cert_role_ctl_generation_name_is_safe() {
    [[ "${1:-}" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
}

cert_role_ctl_candidate_name_is_safe() {
    [[ "${1:-}" =~ ^\.new\.[A-Za-z0-9]+$ ]]
}

cert_role_ctl_generation_is_safe() { # <generation> <expected-gid> [candidate]
    local generation="$1" expected_gid="$2" candidate="${3:-0}"
    local expected_uid entry name count=0 mode
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    publication_fs_canonical_directory "$generation" || return 1
    publication_fs_no_nested_mounts "$generation" || return 1
    [[ "$(publication_fs_uid "$generation")" == "$expected_uid" \
       && "$(publication_fs_gid "$generation")" == "$expected_gid" ]] || return 1
    mode="$(publication_fs_mode "$generation")" || return 1
    if [[ "$candidate" == 1 ]]; then
        [[ "$mode" == 700 || "$mode" == 750 ]] || return 1
    else
        [[ "$mode" == 750 ]] || return 1
    fi
    publication_fs_find_entries entries "$generation" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        publication_fs_plain_file_is_safe "$entry" "$expected_uid" "$expected_gid" 640 || return 1
        count=$((count + 1))
    done
    if [[ "$candidate" == 1 ]]; then
        (( count == 0 || count == 1 || count == 2 ))
    else
        (( count == 2 ))
    fi
}

cert_role_ctl_generation_is_recoverable() { # <role> <generation>
    local role="$1" generation="$2" expected_uid entry name gid count=0
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    publication_fs_canonical_directory "$generation" || return 1
    publication_fs_no_nested_mounts "$generation" || return 1
    [[ "$(publication_fs_uid "$generation")" == "$expected_uid" \
       && "$(publication_fs_mode "$generation")" == 750 ]] || return 1
    gid="$(publication_fs_gid "$generation")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
    publication_fs_find_entries entries "$generation" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        [[ -f "$entry" && ! -L "$entry" \
           && "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_mode "$entry")" == 640 \
           && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
        gid="$(publication_fs_gid "$entry")" || return 1
        cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
        count=$((count + 1))
    done
    (( count == 2 ))
}

cert_role_ctl_empty_preclaim_candidate_is_safe() { # <candidate> <role-gid>
    local candidate="$1" role_gid="$2" expected_uid expected_root_gid entry
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$candidate" || return 1
    publication_fs_no_nested_mounts "$candidate" || return 1
    [[ "$(publication_fs_uid "$candidate")" == "$expected_uid" \
       && ( "$(publication_fs_gid "$candidate")" == "$expected_root_gid" \
            || "$(publication_fs_gid "$candidate")" == "$role_gid" ) \
       && "$(publication_fs_mode "$candidate")" == 700 ]] || return 1
    entry="$(find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 1
    [[ -z "$entry" ]]
}

cert_role_ctl_candidate_is_recoverable() { # <role> <candidate>
    local role="$1" candidate="$2" expected_uid expected_root_gid dir_gid mode entry gid count=0
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$candidate" || return 1
    publication_fs_no_nested_mounts "$candidate" || return 1
    [[ "$(publication_fs_uid "$candidate")" == "$expected_uid" ]] || return 1
    dir_gid="$(publication_fs_gid "$candidate")" || return 1
    mode="$(publication_fs_mode "$candidate")" || return 1
    publication_fs_find_entries entries "$candidate" -mindepth 1 -maxdepth 1 || return 1
    if [[ "$dir_gid" == "$expected_root_gid" ]]; then
        [[ "$mode" == 700 && "${#entries[@]}" == 0 ]]
        return
    fi
    cert_role_ctl_gid_is_allowed "$role" "$dir_gid" || return 1
    [[ "$mode" == 700 || "$mode" == 750 ]] || return 1
    (( ${#entries[@]} <= 2 )) || return 1
    for entry in "${entries[@]}"; do
        case "$(basename -- "$entry")" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        [[ -f "$entry" && ! -L "$entry" \
           && "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_mode "$entry")" == 640 \
           && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
        gid="$(publication_fs_gid "$entry")" || return 1
        cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
        count=$((count + 1))
    done
    (( count <= 2 ))
}

cert_role_ctl_tombstone_is_recoverable() { # <role> <tombstone>
    local role="$1" target="$2" expected_uid dir_gid mode entry gid count=0
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    publication_fs_canonical_directory "$target" || return 1
    publication_fs_no_nested_mounts "$target" || return 1
    [[ "$(publication_fs_uid "$target")" == "$expected_uid" ]] || return 1
    dir_gid="$(publication_fs_gid "$target")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$dir_gid" || return 1
    mode="$(publication_fs_mode "$target")" || return 1
    [[ "$mode" == 700 || "$mode" == 750 ]] || return 1
    publication_fs_find_entries entries "$target" -mindepth 1 -maxdepth 1 || return 1
    (( ${#entries[@]} <= 2 )) || return 1
    for entry in "${entries[@]}"; do
        case "$(basename -- "$entry")" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        [[ -f "$entry" && ! -L "$entry" \
           && "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_mode "$entry")" == 640 \
           && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
        gid="$(publication_fs_gid "$entry")" || return 1
        cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
        count=$((count + 1))
    done
    (( count <= 2 ))
}

cert_role_ctl_config_root_is_safe() {
    local config_root expected_uid expected_gid actual_gid mode
    cert_role_ctl_root_is_permitted || return 1
    config_root="$(dirname -- "$CERT_ROLE_CTL_ROOT")" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$config_root" || return 1
    [[ "$(publication_fs_uid "$config_root")" == "$expected_uid" ]] || return 1
    mode="$(publication_fs_mode "$config_root")" || return 1
    actual_gid="$(publication_fs_gid "$config_root")" || return 1
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        if [[ "$mode" == 755 ]]; then
            [[ "$actual_gid" == "$expected_gid" ]] || return 1
        elif [[ "$mode" == 3771 ]]; then
            cert_role_ctl_gid_is_allowed dot "$actual_gid" || return 1
        else
            return 1
        fi
    else
        publication_fs_mode_is_nonwritable "$mode" || return 1
    fi
    cert_role_ctl_marker_is_safe "$config_root" "$CERT_ROLE_CTL_CONFIG_MARKER" \
        "$CERT_ROLE_CTL_CONFIG_MARKER_VALUE" "$expected_uid" "$expected_gid"
}

cert_role_ctl_root_metadata_is_safe() {
    local expected_uid expected_gid
    cert_role_ctl_config_root_is_safe || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$CERT_ROLE_CTL_ROOT" || return 1
    publication_fs_no_nested_mounts "$CERT_ROLE_CTL_ROOT" || return 1
    [[ "$(publication_fs_uid "$CERT_ROLE_CTL_ROOT")" == "$expected_uid" \
       && "$(publication_fs_gid "$CERT_ROLE_CTL_ROOT")" == "$expected_gid" \
       && "$(publication_fs_mode "$CERT_ROLE_CTL_ROOT")" == 751 ]] || return 1
    cert_role_ctl_marker_is_safe "$CERT_ROLE_CTL_ROOT" "$CERT_ROLE_CTL_ROOT_MARKER" \
        "$CERT_ROLE_CTL_ROOT_MARKER_VALUE" "$expected_uid" "$expected_gid"
}

cert_role_ctl_root_recoverable_metadata_is_safe() {
    local expected_uid expected_gid mode
    cert_role_ctl_config_root_is_safe || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$CERT_ROLE_CTL_ROOT" || return 1
    publication_fs_no_nested_mounts "$CERT_ROLE_CTL_ROOT" || return 1
    mode="$(publication_fs_mode "$CERT_ROLE_CTL_ROOT")" || return 1
    [[ "$(publication_fs_uid "$CERT_ROLE_CTL_ROOT")" == "$expected_uid" \
       && "$(publication_fs_gid "$CERT_ROLE_CTL_ROOT")" == "$expected_gid" \
       && ( "$mode" == 750 || "$mode" == 751 ) ]] || return 1
    cert_role_ctl_marker_is_safe "$CERT_ROLE_CTL_ROOT" "$CERT_ROLE_CTL_ROOT_MARKER" \
        "$CERT_ROLE_CTL_ROOT_MARKER_VALUE" "$expected_uid" "$expected_gid"
}

cert_role_ctl_root_boundary_is_safe() {
    local expected_uid expected_gid entry name
    local -a entries=()
    cert_role_ctl_root_metadata_is_safe || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_find_entries entries "$CERT_ROLE_CTL_ROOT" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROOT_MARKER") ;;
            .provenance|.certbot-ownership)
                publication_fs_plain_file_is_safe "$entry" "$expected_uid" "$expected_gid" 640 || return 1 ;;
            dot|console) [[ -d "$entry" && ! -L "$entry" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

cert_role_ctl_role_candidate_scope_is_safe() { # <candidate> <role>
    local candidate="$1" role="$2" name candidate_role
    case "$role" in dot|console) ;; *) return 1 ;; esac
    name="$(basename -- "$candidate")" || return 1
    [[ "$name" =~ ^\.role\.new\.(dot|console)\.[A-Za-z0-9]+$ ]] || return 1
    candidate_role="${BASH_REMATCH[1]}"
    [[ "$candidate_role" == "$role" \
       && "$candidate" == "$CERT_ROLE_CTL_ROOT/$name" \
       && "$(dirname -- "$candidate")" == "$CERT_ROLE_CTL_ROOT" ]] || return 1
    cert_role_ctl_root_recoverable_metadata_is_safe \
        && publication_fs_canonical_directory "$candidate" \
        && publication_fs_same_mount_boundary "$CERT_ROLE_CTL_ROOT" "$candidate"
}

cert_role_ctl_remove_role_candidate_exact() { # <candidate> <role>
    local candidate="$1" role="$2" expected_uid expected_root_gid candidate_gid
    local entry name marker
    local -a entries=() generation_entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
    publication_fs_no_nested_mounts "$candidate" || return 1
    candidate_gid="$(publication_fs_gid "$candidate")" || return 1
    [[ "$(publication_fs_uid "$candidate")" == "$expected_uid" \
       && ( "$(publication_fs_mode "$candidate")" == 700 \
            || "$(publication_fs_mode "$candidate")" == 750 ) ]] || return 1
    [[ "$candidate_gid" == "$expected_root_gid" ]] \
        || cert_role_ctl_gid_is_allowed "$role" "$candidate_gid" || return 1
    publication_fs_find_entries entries "$candidate" -mindepth 1 -maxdepth 1 || return 1
    if [[ "${#entries[@]}" == 0 ]]; then
        cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
        rmdir -- "$candidate" || return 1
        publication_fs_sync_path "$CERT_ROLE_CTL_ROOT"
        return
    fi
    if [[ "${#entries[@]}" == 1 ]]; then
        entry="${entries[0]}"
        name="$(basename -- "$entry")"
        if [[ "$name" =~ ^\.\.5gpn-cert-role-owned\.[A-Za-z0-9]+$ ]]; then
            [[ -f "$entry" && ! -L "$entry" \
               && "$(publication_fs_uid "$entry")" == "$expected_uid" \
               && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                && ( "$(publication_fs_mode "$entry")" == 600 \
                     || "$(publication_fs_mode "$entry")" == 644 ) \
               && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
            cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
            [[ "$entry" == "$candidate/$name" ]] || return 1
            rm -f -- "$entry" || return 1
            cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
            rmdir -- "$candidate" || return 1
            publication_fs_sync_path "$CERT_ROLE_CTL_ROOT"
            return
        fi
    fi
    marker="$candidate/$CERT_ROLE_CTL_ROLE_MARKER"
    publication_fs_plain_file_is_safe "$marker" "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$marker")" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER") ;;
            generations)
                publication_fs_canonical_directory "$entry" || return 1
                publication_fs_no_nested_mounts "$entry" || return 1
                [[ "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_mode "$entry")" == 750 ]] || return 1
                cert_role_ctl_gid_is_allowed "$role" "$(publication_fs_gid "$entry")" || return 1
                publication_fs_find_entries generation_entries "$entry" -mindepth 1 -maxdepth 1 || return 1
                [[ "${#generation_entries[@]}" == 0 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    if [[ -d "$candidate/generations" ]]; then
        cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
        publication_fs_canonical_directory "$candidate/generations" || return 1
        publication_fs_no_nested_mounts "$candidate/generations" || return 1
        publication_fs_find_entries generation_entries "$candidate/generations" \
            -mindepth 1 -maxdepth 1 || return 1
        [[ "${#generation_entries[@]}" == 0 ]] || return 1
        rmdir -- "$candidate/generations" || return 1
    fi
    cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
    publication_fs_plain_file_is_safe "$marker" "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$marker")" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] || return 1
    rm -f -- "$marker" || return 1
    cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
    publication_fs_find_entries entries "$candidate" -mindepth 1 -maxdepth 1 || return 1
    [[ "${#entries[@]}" == 0 ]] || return 1
    rmdir -- "$candidate" || return 1
    publication_fs_sync_path "$CERT_ROLE_CTL_ROOT"
}

cert_role_ctl_scrub_role_root_candidates() {
    local entry name role
    local -a entries=()
    cert_role_ctl_root_metadata_is_safe || return 1
    publication_fs_find_entries entries "$CERT_ROLE_CTL_ROOT" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROOT_MARKER"|.provenance|.certbot-ownership|dot|console) ;;
            .role.new.dot.*) role=dot ;;
            .role.new.console.*) role=console ;;
            *) return 1 ;;
        esac
        case "$name" in
            .role.new.dot.*|.role.new.console.*)
                [[ "$name" =~ ^\.role\.new\.(dot|console)\.[A-Za-z0-9]+$ ]] || return 1
                cert_role_ctl_remove_role_candidate_exact "$entry" "$role" || return 1 ;;
        esac
    done
}

cert_role_ctl_role_candidate_is_recoverable() { # <candidate> <role>
    local candidate="$1" role="$2" expected_uid expected_root_gid candidate_gid
    local entry name marker
    local -a entries=() nested=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    cert_role_ctl_role_candidate_scope_is_safe "$candidate" "$role" || return 1
    publication_fs_no_nested_mounts "$candidate" || return 1
    candidate_gid="$(publication_fs_gid "$candidate")" || return 1
    [[ "$(publication_fs_uid "$candidate")" == "$expected_uid" \
       && ( "$(publication_fs_mode "$candidate")" == 700 \
            || "$(publication_fs_mode "$candidate")" == 750 ) ]] || return 1
    [[ "$candidate_gid" == "$expected_root_gid" ]] \
        || cert_role_ctl_gid_is_allowed "$role" "$candidate_gid" || return 1
    publication_fs_find_entries entries "$candidate" -mindepth 1 -maxdepth 1 || return 1
    [[ "${#entries[@]}" == 0 ]] && return 0
    if [[ "${#entries[@]}" == 1 ]]; then
        entry="${entries[0]}"
        name="$(basename -- "$entry")"
        if [[ "$name" =~ ^\.\.5gpn-cert-role-owned\.[A-Za-z0-9]+$ ]]; then
            [[ -f "$entry" && ! -L "$entry" \
               && "$(publication_fs_uid "$entry")" == "$expected_uid" \
               && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
               && ( "$(publication_fs_mode "$entry")" == 600 \
                    || "$(publication_fs_mode "$entry")" == 644 ) \
               && "$(publication_fs_nlink "$entry")" == 1 ]]
            return
        fi
    fi
    marker="$candidate/$CERT_ROLE_CTL_ROLE_MARKER"
    publication_fs_plain_file_is_safe "$marker" "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$marker")" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER") ;;
            generations)
                publication_fs_canonical_directory "$entry" || return 1
                publication_fs_no_nested_mounts "$entry" || return 1
                [[ "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_mode "$entry")" == 750 ]] || return 1
                cert_role_ctl_gid_is_allowed "$role" "$(publication_fs_gid "$entry")" || return 1
                publication_fs_find_entries nested "$entry" -mindepth 1 -maxdepth 1 || return 1
                [[ "${#nested[@]}" == 0 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

cert_role_ctl_role_is_recoverable() { # <role>
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" expected_uid expected_root_gid
    local role_gid generations_gid entry_gid entry name target current=""
    local -a root_entries=() generation_entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$role_root" || return 1
    publication_fs_no_nested_mounts "$role_root" || return 1
    [[ "$(publication_fs_uid "$role_root")" == "$expected_uid" \
       && "$(publication_fs_mode "$role_root")" == 750 ]] || return 1
    role_gid="$(publication_fs_gid "$role_root")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$role_gid" || return 1
    publication_fs_plain_file_is_safe "$role_root/$CERT_ROLE_CTL_ROLE_MARKER" \
        "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$role_root/$CERT_ROLE_CTL_ROLE_MARKER")" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] \
        || return 1
    publication_fs_canonical_directory "$role_root/generations" || return 1
    publication_fs_no_nested_mounts "$role_root/generations" || return 1
    [[ "$(publication_fs_uid "$role_root/generations")" == "$expected_uid" \
       && "$(publication_fs_mode "$role_root/generations")" == 750 ]] || return 1
    generations_gid="$(publication_fs_gid "$role_root/generations")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$generations_gid" || return 1
    if [[ -e "$role_root/current" || -L "$role_root/current" ]]; then
        [[ -L "$role_root/current" \
           && "$(publication_fs_uid "$role_root/current")" == "$expected_uid" \
           && "$(publication_fs_gid "$role_root/current")" == "$expected_root_gid" \
           && "$(publication_fs_nlink "$role_root/current")" == 1 ]] || return 1
        current="$(readlink -- "$role_root/current")" || return 1
        [[ "$current" == generations/* ]] || return 1
        cert_role_ctl_generation_name_is_safe "${current#generations/}" || return 1
    fi
    publication_fs_find_entries root_entries "$role_root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER"|generations|current) ;;
            .current.*)
                [[ "$name" =~ ^\.current\.[0-9]+\.[0-9]+$ \
                   && -L "$entry" \
                   && "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                   && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
                publication_fs_orphan_pointer_is_safe "$role_root" "$entry" .current \
                    "$expected_uid" "$expected_root_gid" || return 1
                target="$(readlink -- "$entry")" || return 1
                [[ "$target" == generations/* ]] || return 1
                cert_role_ctl_generation_name_is_safe "${target#generations/}" || return 1 ;;
            *) return 1 ;;
        esac
    done
    publication_fs_find_entries generation_entries "$role_root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${generation_entries[@]}"; do
        name="$(basename -- "$entry")"
        entry_gid="$(publication_fs_gid "$entry")" || return 1
        if cert_role_ctl_generation_name_is_safe "$name"; then
            cert_role_ctl_gid_is_allowed "$role" "$entry_gid" || return 1
            cert_role_ctl_generation_is_recoverable "$role" "$entry" || return 1
        elif cert_role_ctl_candidate_name_is_safe "$name"; then
            cert_role_ctl_candidate_is_recoverable "$role" "$entry" || return 1
        elif [[ "$name" =~ ^\.delete\.[0-9]+\.[0-9]+$ ]]; then
            cert_role_ctl_tombstone_is_recoverable "$role" "$entry" || return 1
        else
            return 1
        fi
    done
    if [[ -n "$current" ]]; then
        entry="$role_root/$current"
        entry_gid="$(publication_fs_gid "$entry")" || return 1
        cert_role_ctl_gid_is_allowed "$role" "$entry_gid" || return 1
        cert_role_ctl_generation_is_recoverable "$role" "$entry" || return 1
    fi
}

cert_role_ctl_tree_is_recoverable() {
    local entry name role
    local -a entries=()
    cert_role_ctl_root_recoverable_metadata_is_safe || return 1
    publication_fs_find_entries entries "$CERT_ROLE_CTL_ROOT" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROOT_MARKER") ;;
            .provenance|.certbot-ownership)
                publication_fs_plain_file_is_safe "$entry" "$(cert_role_ctl_expected_uid)" \
                    "$(cert_role_ctl_expected_root_gid)" 640 || return 1 ;;
            dot|console)
                cert_role_ctl_role_is_recoverable "$name" || return 1 ;;
            .role.new.dot.*) role=dot; cert_role_ctl_role_candidate_is_recoverable "$entry" "$role" || return 1 ;;
            .role.new.console.*) role=console; cert_role_ctl_role_candidate_is_recoverable "$entry" "$role" || return 1 ;;
            *) return 1 ;;
        esac
    done
}

cert_role_ctl_normalize_recoverable_role() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" expected_uid expected_gid entry
    local -a directories=() files=()
    cert_role_ctl_role_is_recoverable "$role" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_group_gid "$(cert_role_ctl_group_name "$role")")" || return 1
    [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    publication_fs_find_entries directories "$role_root/generations" -mindepth 1 -type d || return 1
    publication_fs_find_entries files "$role_root/generations" -mindepth 1 -type f || return 1
    for entry in "${files[@]}"; do
        chown "$expected_uid:$expected_gid" "$entry" || return 1
    done
    for entry in "${directories[@]}"; do
        chown "$expected_uid:$expected_gid" "$entry" || return 1
    done
    chown "$expected_uid:$expected_gid" "$role_root/generations" || return 1
    chown "$expected_uid:$expected_gid" "$role_root" || return 1
    publication_fs_sync_path "$role_root/generations" || return 1
    publication_fs_sync_path "$role_root" || return 1
}

cert_role_ctl_repair_recoverable_tree() {
    local role root_mode
    cert_role_ctl_tree_is_recoverable || return 1
    root_mode="$(publication_fs_mode "$CERT_ROLE_CTL_ROOT")" || return 1
    if [[ "$root_mode" == 750 ]]; then
        chmod 0751 "$CERT_ROLE_CTL_ROOT" || return 1
        publication_fs_sync_path "$CERT_ROLE_CTL_ROOT" || return 1
    fi
    cert_role_ctl_root_metadata_is_safe || return 1
    cert_role_ctl_scrub_role_root_candidates || return 1
    for role in dot console; do
        [[ -e "$CERT_ROLE_CTL_ROOT/$role" || -L "$CERT_ROLE_CTL_ROOT/$role" ]] || continue
        cert_role_ctl_normalize_recoverable_role "$role" || return 1
        cert_role_ctl_scrub_role "$role" || return 1
        cert_role_ctl_validate_role "$role" 0 || return 1
    done
    cert_role_ctl_root_boundary_is_safe
}

cert_role_ctl_role_boundary_is_safe() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local expected_uid expected_root_gid expected_gid actual_gid marker generations
    cert_role_ctl_root_boundary_is_safe || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$role_root" || return 1
    publication_fs_no_nested_mounts "$role_root" || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    expected_gid="$(cert_role_ctl_group_gid "$(cert_role_ctl_group_name "$role")")" || return 1
    [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    [[ "$actual_gid" == "$expected_gid" ]] || return 1
    [[ "$(publication_fs_uid "$role_root")" == "$expected_uid" \
       && "$(publication_fs_mode "$role_root")" == 750 ]] || return 1
    marker="$role_root/$CERT_ROLE_CTL_ROLE_MARKER"
    publication_fs_plain_file_is_safe "$marker" "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$marker" 2>/dev/null || true)" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] \
        || return 1
    generations="$role_root/generations"
    publication_fs_canonical_directory "$generations" || return 1
    publication_fs_no_nested_mounts "$generations" || return 1
    [[ "$(publication_fs_uid "$generations")" == "$expected_uid" \
       && "$(publication_fs_gid "$generations")" == "$actual_gid" \
       && "$(publication_fs_mode "$generations")" == 750 ]]
}

# A group repair may be interrupted between two chown calls. During that
# narrow recovery state each role entry may use either the current service GID
# or one of the caller-authorized old GIDs, but every other schema property
# remains exact. This predicate never authorizes a name, mode, link, mount, or
# file shape that the steady-state validator would reject.
cert_role_ctl_role_is_normalizable() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local expected_uid expected_root_gid entry name gid target
    local -a root_entries=() generations=() generation_entries=()
    cert_role_ctl_root_boundary_is_safe || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$role_root" || return 1
    publication_fs_no_nested_mounts "$role_root" || return 1
    [[ "$(publication_fs_uid "$role_root")" == "$expected_uid" \
       && "$(publication_fs_mode "$role_root")" == 750 ]] || return 1
    gid="$(publication_fs_gid "$role_root")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
    publication_fs_plain_file_is_safe "$role_root/$CERT_ROLE_CTL_ROLE_MARKER" \
        "$expected_uid" "$expected_root_gid" 644 \
        && [[ "$(cat -- "$role_root/$CERT_ROLE_CTL_ROLE_MARKER")" == "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" ]] \
        || return 1
    publication_fs_canonical_directory "$role_root/generations" || return 1
    publication_fs_no_nested_mounts "$role_root/generations" || return 1
    [[ "$(publication_fs_uid "$role_root/generations")" == "$expected_uid" \
       && "$(publication_fs_mode "$role_root/generations")" == 750 ]] || return 1
    gid="$(publication_fs_gid "$role_root/generations")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
    publication_fs_find_entries root_entries "$role_root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" \
                   && "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                   && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    publication_fs_find_entries generations "$role_root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${generations[@]}"; do
        name="$(basename -- "$entry")"
        cert_role_ctl_generation_name_is_safe "$name" || return 1
        publication_fs_canonical_directory "$entry" || return 1
        publication_fs_no_nested_mounts "$entry" || return 1
        [[ "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_mode "$entry")" == 750 ]] || return 1
        gid="$(publication_fs_gid "$entry")" || return 1
        cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
        publication_fs_find_entries generation_entries "$entry" -mindepth 1 -maxdepth 1 || return 1
        [[ "${#generation_entries[@]}" == 2 ]] || return 1
        for target in "${generation_entries[@]}"; do
            name="$(basename -- "$target")"
            case "$name" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
            [[ -f "$target" && ! -L "$target" \
               && "$(publication_fs_uid "$target")" == "$expected_uid" \
               && "$(publication_fs_mode "$target")" == 640 \
               && "$(publication_fs_nlink "$target")" == 1 ]] || return 1
            gid="$(publication_fs_gid "$target")" || return 1
            cert_role_ctl_gid_is_allowed "$role" "$gid" || return 1
        done
    done
    if [[ -e "$role_root/current" || -L "$role_root/current" ]]; then
        [[ -L "$role_root/current" ]] || return 1
        target="$(readlink -- "$role_root/current")" || return 1
        [[ "$target" == generations/* ]] || return 1
        cert_role_ctl_generation_name_is_safe "${target#generations/}" || return 1
        [[ -d "$role_root/$target" && ! -L "$role_root/$target" ]] || return 1
    fi
}

cert_role_ctl_current_target() { # <role> [allow-absent]
    local role="$1" allow_absent="${2:-0}" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local expected_uid expected_root_gid actual_gid current target
    cert_role_ctl_role_boundary_is_safe "$role" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    current="$role_root/current"
    if [[ ! -e "$current" && ! -L "$current" ]]; then
        [[ "$allow_absent" == 1 ]] || return 1
        printf '__absent__\n'
        return
    fi
    [[ -L "$current" \
       && "$(publication_fs_uid "$current")" == "$expected_uid" \
       && "$(publication_fs_gid "$current")" == "$expected_root_gid" \
       && "$(publication_fs_nlink "$current")" == 1 ]] || return 1
    target="$(readlink -- "$current")" || return 1
    [[ "$target" == generations/* ]] || return 1
    cert_role_ctl_generation_name_is_safe "${target#generations/}" || return 1
    cert_role_ctl_generation_is_safe "$role_root/$target" "$actual_gid" || return 1
    printf '%s\n' "$target"
}

cert_role_ctl_validate_role() {
    local role="$1" require_current="${2:-1}" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local expected_uid expected_root_gid actual_gid entry name current_target target
    local -a entries=() generations=()
    cert_role_ctl_role_boundary_is_safe "$role" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    publication_fs_find_entries entries "$role_root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" \
                   && "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                   && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    publication_fs_find_entries generations "$role_root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${generations[@]}"; do
        name="$(basename -- "$entry")"
        cert_role_ctl_generation_name_is_safe "$name" || return 1
        cert_role_ctl_generation_is_safe "$entry" "$actual_gid" || return 1
    done
    if [[ "$require_current" == 1 ]]; then
        current_target="$(cert_role_ctl_current_target "$role" 0)" || return 1
        [[ "$current_target" != __absent__ ]]
    else
        target="$(cert_role_ctl_current_target "$role" 1)" || return 1
        [[ "$target" == __absent__ || "$target" == generations/* ]]
    fi
}

cert_role_ctl_validate_current() {
    cert_role_ctl_root_boundary_is_safe \
        && cert_role_ctl_validate_current_role dot \
        && cert_role_ctl_validate_current_role console
}

cert_role_ctl_validate_current_role() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local expected_uid expected_root_gid entry name target
    local -a entries=()
    cert_role_ctl_role_boundary_is_safe "$role" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_find_entries entries "$role_root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" \
                   && "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                   && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    target="$(cert_role_ctl_current_target "$role" 0)" || return 1
    [[ "$target" == generations/* ]]
}

cert_role_ctl_validate_tree() {
    cert_role_ctl_root_boundary_is_safe \
        && cert_role_ctl_validate_role dot 1 \
        && cert_role_ctl_validate_role console 1
}

cert_role_ctl_root_is_steady_allow_missing_roles() {
    local role
    cert_role_ctl_root_boundary_is_safe || return 1
    for role in dot console; do
        [[ -e "$CERT_ROLE_CTL_ROOT/$role" || -L "$CERT_ROLE_CTL_ROOT/$role" ]] || continue
        cert_role_ctl_validate_role "$role" 0 || return 1
    done
}

cert_role_ctl_write_marker() { # <directory> <name> <value>
    local directory="$1" name="$2" value="$3" temp expected_uid expected_gid
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    temp="$(mktemp "$directory/.${name}.XXXXXX")" || return 1
    if ! printf '%s\n' "$value" > "$temp" \
       || ! chown "$expected_uid:$expected_gid" "$temp" \
       || ! chmod 0644 "$temp" \
       || ! publication_fs_sync_path "$temp" \
       || ! mv -Tf -- "$temp" "$directory/$name" \
       || ! publication_fs_sync_path "$directory" \
       || ! publication_fs_plain_file_is_safe "$directory/$name" "$expected_uid" "$expected_gid" 644 \
       || [[ "$(cat -- "$directory/$name" 2>/dev/null || true)" != "$value" ]]; then
        rm -f -- "$temp"
        return 1
    fi
}

cert_role_ctl_initialize_role() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" group expected_uid expected_gid candidate
    cert_role_ctl_scrub_role_root_candidates || return 1
    cert_role_ctl_root_boundary_is_safe || return 1
    group="$(cert_role_ctl_group_name "$role")" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_group_gid "$group")" || return 1
    [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    if [[ -e "$role_root" || -L "$role_root" ]]; then
        cert_role_ctl_role_boundary_is_safe "$role" \
            || cert_role_ctl_role_is_normalizable "$role"
        return
    fi
    [[ "$CERT_ROLE_CTL_ALLOW_CREATE" == 1 ]] || return 1
    candidate="$(mktemp -d "$CERT_ROLE_CTL_ROOT/.role.new.$role.XXXXXX")" || return 1
    if ! chown "$expected_uid:$expected_gid" "$candidate" \
       || ! chmod 0750 "$candidate" \
       || ! cert_role_ctl_write_marker "$candidate" "$CERT_ROLE_CTL_ROLE_MARKER" \
            "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" \
       || ! install -d -o "$expected_uid" -g "$expected_gid" -m 0750 "$candidate/generations" \
       || ! publication_fs_sync_path "$candidate/generations" \
       || ! publication_fs_sync_path "$candidate" \
       || [[ -e "$role_root" || -L "$role_root" ]] \
       || ! mv -T -- "$candidate" "$role_root" \
       || ! publication_fs_sync_path "$CERT_ROLE_CTL_ROOT"; then
        [[ ! -d "$candidate" ]] || cert_role_ctl_remove_role_candidate_exact "$candidate" "$role" || true
        return 1
    fi
    cert_role_ctl_validate_role "$role" 0
}

cert_role_ctl_normalize_role_group() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" group expected_uid expected_gid
    local actual_gid entry name
    local -a generations=() files=()
    group="$(cert_role_ctl_group_name "$role")" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_group_gid "$group")" || return 1
    [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    if cert_role_ctl_validate_role "$role" 0 \
       && [[ "$(publication_fs_gid "$role_root")" == "$expected_gid" ]]; then
        return 0
    fi
    cert_role_ctl_role_is_normalizable "$role" || return 1
    publication_fs_find_entries generations "$role_root/generations" -mindepth 1 -maxdepth 1 -type d || return 1
    publication_fs_find_entries files "$role_root/generations" -mindepth 1 -type f || return 1
    for entry in "${files[@]}"; do
        chown "$expected_uid:$expected_gid" "$entry" || return 1
    done
    for entry in "${generations[@]}"; do
        chown "$expected_uid:$expected_gid" "$entry" || return 1
    done
    chown "$expected_uid:$expected_gid" "$role_root/generations" || return 1
    chown "$expected_uid:$expected_gid" "$role_root" || return 1
    publication_fs_sync_path "$role_root/generations" || return 1
    publication_fs_sync_path "$role_root" || return 1
    cert_role_ctl_validate_role "$role" 0
}

cert_role_ctl_tombstone_is_safe() { # <tombstone> <expected-gid>
    local target="$1" expected_gid="$2" expected_uid entry mode
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    publication_fs_canonical_directory "$target" || return 1
    publication_fs_no_nested_mounts "$target" || return 1
    mode="$(publication_fs_mode "$target")" || return 1
    [[ "$(publication_fs_uid "$target")" == "$expected_uid" \
       && "$(publication_fs_gid "$target")" == "$expected_gid" \
       && ( "$mode" == 700 || "$mode" == 750 ) ]] || return 1
    publication_fs_find_entries entries "$target" -mindepth 1 -maxdepth 1 || return 1
    (( ${#entries[@]} <= 2 )) || return 1
    for entry in "${entries[@]}"; do
        case "$(basename -- "$entry")" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        [[ -f "$entry" && ! -L "$entry" \
           && "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_gid "$entry")" == "$expected_gid" \
           && "$(publication_fs_mode "$entry")" == 640 \
           && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
    done
}

cert_role_ctl_tombstone_scope_is_safe() { # <role> <tombstone>
    local role="$1" target="$2" role_root="$CERT_ROLE_CTL_ROOT/$1" name
    name="$(basename -- "$target")" || return 1
    [[ "$name" =~ ^\.delete\.[0-9]+\.[0-9]+$ \
       && "$target" == "$role_root/generations/$name" \
       && "$(dirname -- "$target")" == "$role_root/generations" ]] || return 1
    publication_fs_canonical_directory "$role_root" \
        && publication_fs_canonical_directory "$role_root/generations" \
        && publication_fs_canonical_directory "$target" \
        && publication_fs_same_mount_boundary "$role_root" "$role_root/generations" \
        && publication_fs_same_mount_boundary "$role_root" "$target"
}

cert_role_ctl_remove_tombstone_exact() { # <role> <tombstone-path>
    local role="$1" target="$2" role_root="$CERT_ROLE_CTL_ROOT/$1" expected_gid file current
    PUBLICATION_FS_DELETE_STATE=unchanged
    cert_role_ctl_tombstone_scope_is_safe "$role" "$target" || return 1
    expected_gid="$(publication_fs_gid "$target")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$expected_gid" || return 1
    cert_role_ctl_tombstone_is_safe "$target" "$expected_gid" || return 1
    cert_role_ctl_marker_is_safe "$role_root" "$CERT_ROLE_CTL_ROLE_MARKER" \
        "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" "$(cert_role_ctl_expected_uid)" \
        "$(cert_role_ctl_expected_root_gid)" || return 1
    for file in fullchain.pem privkey.pem; do
        cert_role_ctl_tombstone_scope_is_safe "$role" "$target" || return 1
        cert_role_ctl_tombstone_is_safe "$target" "$expected_gid" || return 1
        publication_fs_no_nested_mounts "$role_root" \
            && publication_fs_no_nested_mounts "$role_root/generations" \
            && publication_fs_no_nested_mounts "$target" || return 1
        current="$(cert_role_ctl_current_target "$role" 1)" || return 1
        [[ "$current" != "generations/$(basename -- "$target")" ]] || return 1
        if [[ -e "$target/$file" || -L "$target/$file" ]]; then
            publication_fs_plain_file_is_safe "$target/$file" \
                "$(cert_role_ctl_expected_uid)" "$expected_gid" 640 || return 1
            rm -f -- "$target/$file" || return 1
            PUBLICATION_FS_DELETE_STATE=partial
            if ! publication_fs_sync_path "$target"; then
                PUBLICATION_FS_DELETE_STATE=partial-undurable
                return 1
            fi
            cert_role_ctl_tombstone_is_safe "$target" "$expected_gid" || return 1
            current="$(cert_role_ctl_current_target "$role" 1)" || return 1
            [[ "$current" != "generations/$(basename -- "$target")" ]] || return 1
        fi
    done
    cert_role_ctl_tombstone_scope_is_safe "$role" "$target" || return 1
    cert_role_ctl_tombstone_is_safe "$target" "$expected_gid" || return 1
    publication_fs_no_nested_mounts "$target" || return 1
    current="$(cert_role_ctl_current_target "$role" 1)" || return 1
    [[ "$current" != "generations/$(basename -- "$target")" ]] || return 1
    rmdir -- "$target" || return 1
    PUBLICATION_FS_DELETE_STATE=removed
    if ! publication_fs_sync_path "$role_root/generations"; then
        PUBLICATION_FS_DELETE_STATE=removed-undurable
        return 1
    fi
}

cert_role_ctl_remove_generation() { # <role> <name> [candidate]
    local role="$1" name="$2" candidate="${3:-0}" role_root="$CERT_ROLE_CTL_ROOT/$1"
    local current actual_gid target tombstone target_gid
    PUBLICATION_FS_DELETE_STATE=unchanged
    cert_role_ctl_role_boundary_is_safe "$role" || return 1
    if [[ "$candidate" == 1 ]]; then
        cert_role_ctl_candidate_name_is_safe "$name" || return 1
    else
        cert_role_ctl_generation_name_is_safe "$name" || return 1
    fi
    current="$(cert_role_ctl_current_target "$role" 1)" || return 1
    [[ "$current" != "generations/$name" ]] || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    target="$role_root/generations/$name"
    target_gid="$(publication_fs_gid "$target")" || return 1
    cert_role_ctl_gid_is_allowed "$role" "$target_gid" || return 1
    cert_role_ctl_generation_is_safe "$target" "$target_gid" "$candidate" || return 1
    cert_role_ctl_marker_is_safe "$role_root" "$CERT_ROLE_CTL_ROLE_MARKER" \
        "$CERT_ROLE_CTL_ROLE_VALUE_PREFIX:$role" "$(cert_role_ctl_expected_uid)" \
        "$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_no_nested_mounts "$role_root" \
        && publication_fs_no_nested_mounts "$role_root/generations" \
        && publication_fs_no_nested_mounts "$target" || return 1
    current="$(cert_role_ctl_current_target "$role" 1)" || return 1
    [[ "$current" != "generations/$name" ]] || return 1
    tombstone="$role_root/generations/.delete.${BASHPID}.${RANDOM}"
    [[ ! -e "$tombstone" && ! -L "$tombstone" ]] || return 1
    mv -T -- "$target" "$tombstone" || return 1
    PUBLICATION_FS_DELETE_STATE=tombstoned
    if ! publication_fs_sync_path "$role_root/generations"; then
        PUBLICATION_FS_DELETE_STATE=tombstoned-undurable
        return 1
    fi
    cert_role_ctl_remove_tombstone_exact "$role" "$tombstone"
}

cert_role_ctl_scrub_role() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" expected_uid expected_root_gid
    local actual_gid entry_gid current entry name target
    local -a root_entries=() generation_entries=()
    cert_role_ctl_role_boundary_is_safe "$role" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_root_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    current="$(cert_role_ctl_current_target "$role" 1)" || return 1
    publication_fs_find_entries root_entries "$role_root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_CTL_ROLE_MARKER"|generations|current) ;;
            .current.*)
                [[ "$name" =~ ^\.current\.[0-9]+\.[0-9]+$ \
                   && -L "$entry" \
                   && "$(publication_fs_uid "$entry")" == "$expected_uid" \
                   && "$(publication_fs_gid "$entry")" == "$expected_root_gid" \
                   && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
                target="$(readlink -- "$entry")" || return 1
                [[ "$target" == generations/* ]] || return 1
                cert_role_ctl_generation_name_is_safe "${target#generations/}" || return 1
                publication_fs_remove_prepared_pointer "$role_root" "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done
    publication_fs_find_entries generation_entries "$role_root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${generation_entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "generations/$name" == "$current" ]] && continue
        if [[ "$name" =~ ^\.delete\.[0-9]+\.[0-9]+$ ]]; then
            entry_gid="$(publication_fs_gid "$entry")" || return 1
            cert_role_ctl_gid_is_allowed "$role" "$entry_gid" || return 1
            cert_role_ctl_tombstone_is_safe "$entry" "$entry_gid" || return 1
            cert_role_ctl_remove_tombstone_exact "$role" "$entry" || return 1
        elif cert_role_ctl_candidate_name_is_safe "$name"; then
            entry_gid="$(publication_fs_gid "$entry")" || return 1
            cert_role_ctl_gid_is_allowed "$role" "$entry_gid" \
                || [[ "$entry_gid" == "$(cert_role_ctl_expected_root_gid)" ]] \
                || return 1
            if cert_role_ctl_empty_preclaim_candidate_is_safe "$entry" "$entry_gid"; then
                rmdir -- "$entry" && publication_fs_sync_path "$role_root/generations" || return 1
            else
                cert_role_ctl_generation_is_safe "$entry" "$entry_gid" 1 || return 1
                cert_role_ctl_remove_generation "$role" "$name" 1 || return 1
            fi
        else
            cert_role_ctl_generation_name_is_safe "$name" || return 1
            entry_gid="$(publication_fs_gid "$entry")" || return 1
            cert_role_ctl_gid_is_allowed "$role" "$entry_gid" || return 1
            cert_role_ctl_generation_is_safe "$entry" "$entry_gid" || return 1
            cert_role_ctl_remove_generation "$role" "$name" 0 || return 1
        fi
    done
}

cert_role_ctl_cleanup_uncommitted() { # array names: roles generations links
    local roles_name="$1" generations_name="$2" links_name="$3"
    local -n roles_ref="$roles_name" generations_ref="$generations_name" links_ref="$links_name"
    local i role generation link name current candidate=0
    for i in "${!roles_ref[@]}"; do
        role="${roles_ref[$i]}"
        generation="${generations_ref[$i]:-}"
        link="${links_ref[$i]:-}"
        if [[ -n "$link" && ( -e "$link" || -L "$link" ) ]]; then
            publication_fs_remove_prepared_pointer "$CERT_ROLE_CTL_ROOT/$role" "$link" || true
        fi
        [[ -n "$generation" && -d "$generation" && ! -L "$generation" ]] || continue
        name="$(basename -- "$generation")"
        current="$(cert_role_ctl_current_target "$role" 1 2>/dev/null || true)"
        [[ "$current" != "generations/$name" ]] || continue
        cert_role_ctl_candidate_name_is_safe "$name" && candidate=1 || candidate=0
        cert_role_ctl_remove_generation "$role" "$name" "$candidate" || true
    done
}

cert_role_ctl_gc_role() {
    local role="$1" role_root="$CERT_ROLE_CTL_ROOT/$1" current entry name actual_gid
    local -a generations=()
    cert_role_ctl_validate_role "$role" 1 || return 1
    current="$(cert_role_ctl_current_target "$role" 0)" || return 1
    actual_gid="$(publication_fs_gid "$role_root")" || return 1
    publication_fs_find_entries generations "$role_root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${generations[@]}"; do
        name="$(basename -- "$entry")"
        [[ "generations/$name" == "$current" ]] && continue
        cert_role_ctl_generation_name_is_safe "$name" || return 1
        cert_role_ctl_generation_is_safe "$entry" "$actual_gid" || return 1
        current="$(cert_role_ctl_current_target "$role" 0)" || return 1
        [[ "generations/$name" != "$current" ]] || continue
        cert_role_ctl_remove_generation "$role" "$name" 0 || return 1
    done
}

cert_role_ctl_stage_parent_is_safe() {
    local expected_uid expected_gid
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        [[ "$CERT_ROLE_CTL_STAGE_PARENT" == /run/5gpn ]] || return 1
    else
        [[ "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
        case "$CERT_ROLE_CTL_STAGE_PARENT" in
            /tmp/5gpn-*|/var/tmp/5gpn-*|/fixture/*) ;;
            *) return 1 ;;
        esac
    fi
    publication_fs_canonical_directory "$CERT_ROLE_CTL_STAGE_PARENT" || return 1
    [[ "$(publication_fs_uid "$CERT_ROLE_CTL_STAGE_PARENT")" == "$expected_uid" \
       && "$(publication_fs_gid "$CERT_ROLE_CTL_STAGE_PARENT")" == "$expected_gid" \
       && "$(publication_fs_mode "$CERT_ROLE_CTL_STAGE_PARENT")" == 700 ]]
}

cert_role_ctl_prepare_stage_parent() {
    local expected_uid expected_gid parent
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    if [[ -e "$CERT_ROLE_CTL_STAGE_PARENT" || -L "$CERT_ROLE_CTL_STAGE_PARENT" ]]; then
        cert_role_ctl_stage_parent_is_safe
        return
    fi
    [[ "$CERT_ROLE_CTL_ROOT" != "$CERT_ROLE_CTL_PRODUCTION_ROOT" \
       && "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
    parent="$(dirname -- "$CERT_ROLE_CTL_STAGE_PARENT")" || return 1
    publication_fs_canonical_directory "$parent" || return 1
    install -d -o "$expected_uid" -g "$expected_gid" -m 0700 "$CERT_ROLE_CTL_STAGE_PARENT" || return 1
    publication_fs_sync_path "$parent" || return 1
    cert_role_ctl_stage_parent_is_safe
}

cert_role_ctl_source_snapshot_is_safe() {
    local stage="$1" expected_uid expected_gid entry name count=0 marker_seen=0
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    cert_role_ctl_stage_parent_is_safe || return 1
    publication_fs_canonical_directory "$stage" || return 1
    [[ "$stage" == "$CERT_ROLE_CTL_STAGE_PARENT/.cert-role-stage."* \
       && "$(publication_fs_uid "$stage")" == "$expected_uid" \
       && "$(publication_fs_gid "$stage")" == "$expected_gid" \
       && "$(publication_fs_mode "$stage")" == 700 ]] || return 1
    publication_fs_no_nested_mounts "$stage" || return 1
    publication_fs_find_entries entries "$stage" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            .5gpn-cert-role-stage-owned)
                publication_fs_plain_file_is_safe "$entry" "$expected_uid" "$expected_gid" 600 \
                    && [[ "$(cat -- "$entry")" == 5gpn-cert-role-source-v1 ]] || return 1
                marker_seen=1 ;;
            fullchain.pem|privkey.pem)
                publication_fs_plain_file_is_safe "$entry" "$expected_uid" "$expected_gid" 600 || return 1 ;;
            *) return 1 ;;
        esac
        count=$((count + 1))
    done
    (( marker_seen == 1 && count >= 1 && count <= 3 ))
}

cert_role_ctl_preclaim_source_snapshot_is_safe() {
    local stage="$1" expected_uid expected_gid entry name
    local -a entries=()
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    publication_fs_canonical_directory "$stage" || return 1
    publication_fs_no_nested_mounts "$stage" || return 1
    [[ "$stage" == "$CERT_ROLE_CTL_STAGE_PARENT/.cert-role-stage."* \
       && "$(publication_fs_uid "$stage")" == "$expected_uid" \
       && "$(publication_fs_gid "$stage")" == "$expected_gid" \
       && "$(publication_fs_mode "$stage")" == 700 ]] || return 1
    publication_fs_find_entries entries "$stage" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^\.marker\.new\.[A-Za-z0-9]+$ \
           && -f "$entry" && ! -L "$entry" \
           && "$(publication_fs_uid "$entry")" == "$expected_uid" \
           && "$(publication_fs_gid "$entry")" == "$expected_gid" \
           && "$(publication_fs_mode "$entry")" == 600 \
           && "$(publication_fs_nlink "$entry")" == 1 ]] || return 1
    done
}

cert_role_ctl_remove_preclaim_source_snapshot() {
    local stage="$1" entry
    local -a entries=()
    cert_role_ctl_preclaim_source_snapshot_is_safe "$stage" || return 1
    publication_fs_find_entries entries "$stage" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        rm -f -- "$entry" || return 1
    done
    rmdir -- "$stage" || return 1
    CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=removed
    if ! publication_fs_sync_path "$CERT_ROLE_CTL_STAGE_PARENT"; then
        CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=removed-undurable
        return 1
    fi
}

cert_role_ctl_write_source_snapshot_marker() {
    local stage="$1" temp expected_uid expected_gid marker="$1/.5gpn-cert-role-stage-owned"
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    temp="$(mktemp "$stage/.marker.new.XXXXXX")" || return 1
    if ! printf '%s\n' 5gpn-cert-role-source-v1 > "$temp" \
       || ! chown "$expected_uid:$expected_gid" "$temp" \
       || ! chmod 0600 "$temp" \
       || ! publication_fs_sync_path "$temp" \
       || ! mv -Tf -- "$temp" "$marker" \
       || ! publication_fs_sync_path "$stage"; then
        rm -f -- "$temp"
        return 1
    fi
    publication_fs_plain_file_is_safe "$marker" "$expected_uid" "$expected_gid" 600 \
        && [[ "$(cat -- "$marker")" == 5gpn-cert-role-source-v1 ]]
}

cert_role_ctl_remove_source_snapshot() {
    local stage="$1" marker="$1/.5gpn-cert-role-stage-owned"
    CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=unchanged
    cert_role_ctl_source_snapshot_is_safe "$stage" || return 1
    [[ ! -e "$stage/fullchain.pem" ]] || rm -f -- "$stage/fullchain.pem" || return 1
    [[ ! -e "$stage/privkey.pem" ]] || rm -f -- "$stage/privkey.pem" || return 1
    rm -f -- "$marker" || return 1
    rmdir -- "$stage" || return 1
    CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=removed
    if ! publication_fs_sync_path "$CERT_ROLE_CTL_STAGE_PARENT"; then
        CERT_ROLE_CTL_SOURCE_CLEANUP_STATE=removed-undurable
        return 1
    fi
}

cert_role_ctl_scrub_source_snapshots() {
    local entry name
    local -a entries=()
    cert_role_ctl_stage_parent_is_safe || return 1
    publication_fs_find_entries entries "$CERT_ROLE_CTL_STAGE_PARENT" \
        -mindepth 1 -maxdepth 1 -name '.cert-role-stage.*' || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^\.cert-role-stage\.[A-Za-z0-9]+$ ]] || return 1
        if cert_role_ctl_source_snapshot_is_safe "$entry"; then
            cert_role_ctl_remove_source_snapshot "$entry" || return 1
        else
            cert_role_ctl_remove_preclaim_source_snapshot "$entry" || return 1
        fi
    done
}

cert_role_ctl_source_cleanup_is_recoverable() {
    local stage="$1"
    cert_role_ctl_source_snapshot_is_safe "$stage" \
        || cert_role_ctl_preclaim_source_snapshot_is_safe "$stage" \
        || [[ "$CERT_ROLE_CTL_SOURCE_CLEANUP_STATE" == removed-undurable \
              && ! -e "$stage" && ! -L "$stage" ]]
}

cert_role_ctl_capture_source_pair() { # <cert> <key> <output-variable>
    local cert="$1" key="$2" output_name="$3" stage expected_uid expected_gid
    local cert_before key_before cert_after key_after
    [[ -f "$cert" && -f "$key" ]] || return 1
    cert_role_ctl_prepare_stage_parent || return 1
    cert_role_ctl_scrub_source_snapshots || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    expected_gid="$(cert_role_ctl_expected_root_gid)" || return 1
    cert_before="$(sha256sum -- "$cert" 2>/dev/null | awk '{print $1}')" || return 1
    key_before="$(sha256sum -- "$key" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$cert_before" =~ ^[0-9a-f]{64}$ && "$key_before" =~ ^[0-9a-f]{64}$ ]] || return 1
    stage="$(mktemp -d "$CERT_ROLE_CTL_STAGE_PARENT/.cert-role-stage.XXXXXX")" || return 1
    chown "$expected_uid:$expected_gid" "$stage" && chmod 0700 "$stage" \
        && cert_role_ctl_write_source_snapshot_marker "$stage" \
        && install -o "$expected_uid" -g "$expected_gid" -m 0600 "$cert" "$stage/fullchain.pem" \
        && install -o "$expected_uid" -g "$expected_gid" -m 0600 "$key" "$stage/privkey.pem" \
        && publication_fs_sync_path "$stage" || {
            if cert_role_ctl_source_snapshot_is_safe "$stage"; then
                cert_role_ctl_remove_source_snapshot "$stage" || true
            else
                cert_role_ctl_remove_preclaim_source_snapshot "$stage" || true
            fi
            return 1
        }
    cert_after="$(sha256sum -- "$cert" 2>/dev/null | awk '{print $1}')" || {
        cert_role_ctl_remove_source_snapshot "$stage" || true
        return 1
    }
    key_after="$(sha256sum -- "$key" 2>/dev/null | awk '{print $1}')" || {
        cert_role_ctl_remove_source_snapshot "$stage" || true
        return 1
    }
    [[ "$cert_after" == "$cert_before" && "$key_after" == "$key_before" \
       && "$(sha256sum -- "$stage/fullchain.pem" | awk '{print $1}')" == "$cert_before" \
       && "$(sha256sum -- "$stage/privkey.pem" | awk '{print $1}')" == "$key_before" ]] || {
        cert_role_ctl_remove_source_snapshot "$stage" || true
        return 1
    }
    printf -v "$output_name" '%s' "$stage"
}

cert_role_ctl_lineage_pair_is_safe() { # <live-directory> <exact-lineage-name>
    local live="${1%/}" name="$2" live_root archive_root
    local cert_link key_link cert_raw key_raw cert_real key_real cert_leaf key_leaf cert_n key_n expected_uid
    [[ -n "$name" && "$name" != */* && "$name" != .* \
       && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || return 1
    live_root="$CERT_ROLE_CTL_LINEAGE_LIVE_ROOT"
    archive_root="$CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT"
    if [[ "$CERT_ROLE_CTL_ROOT" == "$CERT_ROLE_CTL_PRODUCTION_ROOT" ]]; then
        [[ "$live_root" == /etc/letsencrypt/live \
           && "$archive_root" == /etc/letsencrypt/archive ]] || return 1
    else
        [[ "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 1 ]] || return 1
    fi
    publication_fs_canonical_directory "$live_root" || return 1
    publication_fs_canonical_directory "$archive_root" || return 1
    publication_fs_canonical_directory "$live" || return 1
    publication_fs_canonical_directory "$archive_root/$name" || return 1
    expected_uid="$(cert_role_ctl_expected_uid)" || return 1
    publication_fs_no_nested_mounts "$live" || return 1
    publication_fs_no_nested_mounts "$archive_root/$name" || return 1
    [[ "$live" == "$live_root/$name" ]] || return 1
    cert_link="$live/fullchain.pem"
    key_link="$live/privkey.pem"
    [[ -L "$cert_link" && -L "$key_link" \
       && "$(publication_fs_uid "$cert_link")" == "$expected_uid" \
       && "$(publication_fs_uid "$key_link")" == "$expected_uid" \
       && "$(publication_fs_gid "$cert_link")" == "$(cert_role_ctl_expected_root_gid)" \
       && "$(publication_fs_gid "$key_link")" == "$(cert_role_ctl_expected_root_gid)" \
       && "$(publication_fs_nlink "$cert_link")" == 1 \
       && "$(publication_fs_nlink "$key_link")" == 1 ]] || return 1
    cert_raw="$(readlink -- "$cert_link")" || return 1
    key_raw="$(readlink -- "$key_link")" || return 1
    [[ "$cert_raw" =~ ^\.\./\.\./archive/([^/]+)/fullchain([1-9][0-9]*)\.pem$ \
       && "${BASH_REMATCH[1]}" == "$name" ]] || return 1
    cert_n="${BASH_REMATCH[2]}"
    [[ "$key_raw" =~ ^\.\./\.\./archive/([^/]+)/privkey([1-9][0-9]*)\.pem$ \
       && "${BASH_REMATCH[1]}" == "$name" ]] || return 1
    key_n="${BASH_REMATCH[2]}"
    [[ "$key_n" == "$cert_n" ]] || return 1
    cert_real="$(readlink -f -- "$cert_link")" || return 1
    key_real="$(readlink -f -- "$key_link")" || return 1
    cert_leaf="$(basename -- "$cert_real")"
    key_leaf="$(basename -- "$key_real")"
    [[ "$cert_real" == "$archive_root/$name/$cert_leaf" \
       && "$key_real" == "$archive_root/$name/$key_leaf" \
       && "$cert_leaf" == "fullchain${cert_n}.pem" \
       && "$key_leaf" == "privkey${key_n}.pem" \
       && -f "$cert_real" && ! -L "$cert_real" \
       && -f "$key_real" && ! -L "$key_real" \
       && "$(publication_fs_uid "$cert_real")" == "$expected_uid" \
       && "$(publication_fs_uid "$key_real")" == "$expected_uid" \
       && "$(publication_fs_nlink "$cert_real")" == 1 \
       && "$(publication_fs_nlink "$key_real")" == 1 \
       && "$(publication_fs_mode "$cert_real")" == 644 \
       && "$(publication_fs_mode "$key_real")" == 600 ]] || return 1
}

_cert_role_ctl_publish_snapshot_pair() { # <cert> <key> <validator-function>
    local cert="$1" key="$2" validator="$3" role role_root group expected_gid
    local generation final target temp expected i source_cert_sha source_key_sha current_sha
    local -a roles=(dot console) generations=() links=() old_targets=()
    CERT_ROLE_CTL_COMMIT_STATE=uncommitted
    CERT_ROLE_CTL_COMMITTED_ROLES=""
    CERT_ROLE_CTL_GC_WARNING=0
    CERT_ROLE_CTL_GC_STATE=unchanged
    CERT_ROLE_CTL_LAST_ERROR=""
    [[ -f "$cert" && -f "$key" && -n "$validator" ]] \
        || cert_role_ctl_error "unsafe certificate source pair" || return 1
    source_cert_sha="$(sha256sum -- "$cert" 2>/dev/null | awk '{print $1}')" || return 1
    source_key_sha="$(sha256sum -- "$key" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$source_cert_sha" =~ ^[0-9a-f]{64}$ && "$source_key_sha" =~ ^[0-9a-f]{64}$ ]] \
        || cert_role_ctl_error "could not bind certificate source bytes" || return 1
    cert_role_ctl_tree_is_recoverable \
        || cert_role_ctl_error "certificate role tree is not safely recoverable" || return 1
    cert_role_ctl_repair_recoverable_tree \
        || cert_role_ctl_error "could not repair interrupted certificate role state" || return 1
    cert_role_ctl_root_boundary_is_safe || cert_role_ctl_error "unsafe certificate root" || return 1
    for role in "${roles[@]}"; do
        cert_role_ctl_initialize_role "$role" || cert_role_ctl_error "could not establish $role role" || return 1
        cert_role_ctl_scrub_role "$role" || cert_role_ctl_error "could not scrub $role role" || return 1
        cert_role_ctl_normalize_role_group "$role" || cert_role_ctl_error "could not normalize $role role" || return 1
    done

    for role in "${roles[@]}"; do
        role_root="$CERT_ROLE_CTL_ROOT/$role"
        group="$(cert_role_ctl_group_name "$role")" || return 1
        expected_gid="$(cert_role_ctl_group_gid "$group")" || return 1
        [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
        expected="$(cert_role_ctl_current_target "$role" 1)" || return 1
        generation="$(mktemp -d "$role_root/generations/.new.XXXXXX")" || {
            cert_role_ctl_cleanup_uncommitted roles generations links
            return 1
        }
        generations+=("$generation")
        links+=("")
        old_targets+=("$expected")
        chown "$(cert_role_ctl_expected_uid):$expected_gid" "$generation" \
            && chmod 0750 "$generation" \
            && install -o "$(cert_role_ctl_expected_uid)" -g "$expected_gid" -m 0640 \
                "$cert" "$generation/fullchain.pem" \
            && install -o "$(cert_role_ctl_expected_uid)" -g "$expected_gid" -m 0640 \
                "$key" "$generation/privkey.pem" \
            && cert_role_ctl_generation_is_safe "$generation" "$expected_gid" \
            && [[ "$(sha256sum -- "$generation/fullchain.pem" | awk '{print $1}')" == "$source_cert_sha" ]] \
            && [[ "$(sha256sum -- "$generation/privkey.pem" | awk '{print $1}')" == "$source_key_sha" ]] \
            && "$validator" "$generation/fullchain.pem" "$generation/privkey.pem" "$role" \
            && publication_fs_sync_path "$generation" || {
                cert_role_ctl_cleanup_uncommitted roles generations links
                cert_role_ctl_error "could not stage durable $role role generation"
                return 1
            }
        final="$role_root/generations/generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
        [[ ! -e "$final" && ! -L "$final" ]] \
            && mv -T -- "$generation" "$final" \
            && publication_fs_sync_path "$role_root/generations" || {
                cert_role_ctl_cleanup_uncommitted roles generations links
                cert_role_ctl_error "could not publish durable $role generation"
                return 1
            }
        generations[$((${#generations[@]} - 1))]="$final"
    done

    current_sha="$(sha256sum -- "$cert" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$current_sha" == "$source_cert_sha" ]] || {
        cert_role_ctl_cleanup_uncommitted roles generations links
        cert_role_ctl_error "certificate source changed while roles were staged"
        return 1
    }
    current_sha="$(sha256sum -- "$key" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$current_sha" == "$source_key_sha" ]] || {
        cert_role_ctl_cleanup_uncommitted roles generations links
        cert_role_ctl_error "private-key source changed while roles were staged"
        return 1
    }

    cert_role_ctl_root_boundary_is_safe || {
        cert_role_ctl_cleanup_uncommitted roles generations links
        cert_role_ctl_error "certificate root changed before current publication"
        return 1
    }
    for i in "${!roles[@]}"; do
        role="${roles[$i]}"
        role_root="$CERT_ROLE_CTL_ROOT/$role"
        target="generations/$(basename -- "${generations[$i]}")"
        expected="${old_targets[$i]}"
        [[ "$expected" != __absent__ ]] || expected=""
        if ! publication_fs_commit_relative_pointer "$role_root" current "$target" "$expected" \
            "$(cert_role_ctl_expected_uid)" "$(cert_role_ctl_expected_root_gid)" .current; then
            case "$PUBLICATION_FS_COMMIT_STATE" in
                committed-undurable)
                    CERT_ROLE_CTL_COMMIT_STATE=committed-undurable
                    CERT_ROLE_CTL_COMMITTED_ROLES="${CERT_ROLE_CTL_COMMITTED_ROLES}${CERT_ROLE_CTL_COMMITTED_ROLES:+,}$role" ;;
                committed)
                    CERT_ROLE_CTL_COMMIT_STATE=committed-partial
                    if [[ "$(cert_role_ctl_current_target "$role" 0 2>/dev/null || true)" == "$target" ]]; then
                        CERT_ROLE_CTL_COMMITTED_ROLES="${CERT_ROLE_CTL_COMMITTED_ROLES}${CERT_ROLE_CTL_COMMITTED_ROLES:+,}$role"
                    fi ;;
                *)
                    if [[ -n "$CERT_ROLE_CTL_COMMITTED_ROLES" ]]; then
                        CERT_ROLE_CTL_COMMIT_STATE=committed-partial
                    fi ;;
            esac
            cert_role_ctl_error "could not durably commit $role current pointer"
            return 1
        fi
        CERT_ROLE_CTL_COMMITTED_ROLES="${CERT_ROLE_CTL_COMMITTED_ROLES}${CERT_ROLE_CTL_COMMITTED_ROLES:+,}$role"
        CERT_ROLE_CTL_COMMIT_STATE=committed-partial
    done

    for role in "${roles[@]}"; do
        cert_role_ctl_validate_current_role "$role" || {
            CERT_ROLE_CTL_COMMIT_STATE=committed-partial
            cert_role_ctl_error "committed $role role failed validation"
            return 1
        }
    done
    CERT_ROLE_CTL_COMMIT_STATE=committed
    for role in "${roles[@]}"; do
        if ! cert_role_ctl_gc_role "$role"; then
            CERT_ROLE_CTL_GC_WARNING=1
            CERT_ROLE_CTL_GC_STATE="$PUBLICATION_FS_DELETE_STATE"
        fi
    done
    cert_role_ctl_validate_current || {
        CERT_ROLE_CTL_COMMIT_STATE=committed-partial
        cert_role_ctl_error "committed certificate roles failed final validation"
        return 1
    }
}

cert_role_ctl_publish_pair() { # <cert-or-lineage-link> <key-or-lineage-link> <validator-function>
    local cert="$1" key="$2" validator="$3" snapshot="" rc=0
    cert_role_ctl_capture_source_pair "$cert" "$key" snapshot \
        || { cert_role_ctl_error "could not capture one immutable certificate source pair"; return 1; }
    _cert_role_ctl_publish_snapshot_pair "$snapshot/fullchain.pem" "$snapshot/privkey.pem" "$validator" \
        || rc=$?
    if ! cert_role_ctl_remove_source_snapshot "$snapshot"; then
        if [[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed* ]] \
           && cert_role_ctl_source_cleanup_is_recoverable "$snapshot"; then
            CERT_ROLE_CTL_GC_WARNING=1
            CERT_ROLE_CTL_LAST_ERROR="certificate roles are live, but private source-snapshot cleanup failed"
            return "$rc"
        fi
        return 1
    fi
    return "$rc"
}

cert_role_ctl_deploy_lineage() { # <live-dir> <exact-lineage-name> <validator-function>
    local live="${1%/}" name="$2" validator="$3"
    cert_role_ctl_lineage_pair_is_safe "$live" "$name" || return 1
    cert_role_ctl_publish_pair "$live/fullchain.pem" "$live/privkey.pem" "$validator"
}
