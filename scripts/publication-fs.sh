#!/usr/bin/env bash
# Shared filesystem primitives for durable generation publication.
#
# This helper deliberately knows nothing about certificate roles, UI manifests,
# or product ownership markers. Domain callers validate those contracts first,
# hold the appropriate transaction lock, and pass only exact managed paths.
# Every pointer commit is revalidated at its immediate mutation boundary. A
# post-rename sync failure is reported as committed but durability-unconfirmed;
# this helper never rolls a visible pointer back.

PUBLICATION_FS_COMMIT_STATE="not-started"

publication_fs_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
publication_fs_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
publication_fs_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

publication_fs_absolute_lexical_path_is_safe() {
    local path="$1"
    [[ -n "$path" && "$path" =~ ^/[-A-Za-z0-9._+/]+$ ]] || return 1
    case "/${path#/}/" in
        */../*|*/./*|*//* ) return 1 ;;
    esac
    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1 ;;
    esac
}

publication_fs_absolute_path_is_safe() {
    local path="$1" canonical
    publication_fs_absolute_lexical_path_is_safe "$path" || return 1
    canonical="$(readlink -m -- "$path" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path" ]]
}

publication_fs_directory_is_canonical() {
    local path="$1" canonical
    publication_fs_absolute_path_is_safe "$path" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path" ]]
}

publication_fs_relative_path_is_safe() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" =~ ^[-A-Za-z0-9._+/]+$ ]] || return 1
    case "/$path/" in
        */../*|*/./*|*//* ) return 1 ;;
    esac
}

publication_fs_sync_path() {
    local path="$1"
    [[ ( -f "$path" || -d "$path" ) && ! -L "$path" ]] || return 1
    sync -f "$path"
}

publication_fs_mount_id() {
    local path="$1" value
    command -v findmnt >/dev/null 2>&1 || return 1
    value="$(findmnt -r -n -o ID --target "$path" 2>/dev/null)" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

publication_fs_mount_target_text_is_safe() {
    [[ "${1:-}" == / || "${1:-}" =~ ^/[-A-Za-z0-9._+/]+$ ]]
}

publication_fs_containing_mount_target() {
    local path="$1" value
    command -v findmnt >/dev/null 2>&1 || return 1
    value="$(findmnt -r -n -o TARGET --target "$path" 2>/dev/null)" || return 1
    publication_fs_mount_target_text_is_safe "$value" || return 1
    printf '%s\n' "$value"
}

# Require a descendant to remain on the managed root's exact mount instance.
# This catches a bind-mounted intermediate scope even when the final target and
# its immediate parent share one mount ID.
publication_fs_same_mount_boundary() {
    local root="$1" path="$2" root_id path_id root_mount path_mount
    publication_fs_directory_is_canonical "$root" || return 1
    publication_fs_directory_is_canonical "$path" || return 1
    [[ "$path" == "$root" || "$path" == "$root"/* ]] || return 1
    root_id="$(publication_fs_mount_id "$root")" || return 1
    path_id="$(publication_fs_mount_id "$path")" || return 1
    [[ "$root_id" == "$path_id" ]] || return 1
    root_mount="$(publication_fs_containing_mount_target "$root")" || return 1
    path_mount="$(publication_fs_containing_mount_target "$path")" || return 1
    [[ "$root_mount" != "$root" && "$path_mount" == "$root_mount" ]]
}

# Refuse a target that is itself a mountpoint, crosses from its parent mount,
# or contains any nested mount. `findmnt` absence or ambiguous output is fatal.
publication_fs_mount_boundary_is_safe() {
    local target="$1" parent="$2" target_id parent_id containing output mount
    publication_fs_directory_is_canonical "$target" || return 1
    publication_fs_directory_is_canonical "$parent" || return 1
    [[ "$(dirname -- "$target")" == "$parent" ]] || return 1
    parent_id="$(publication_fs_mount_id "$parent")" || return 1
    target_id="$(publication_fs_mount_id "$target")" || return 1
    [[ "$target_id" == "$parent_id" ]] || return 1
    containing="$(publication_fs_containing_mount_target "$target")" || return 1
    [[ "$containing" != "$target" ]] || return 1
    output="$(findmnt -R -r -n -o TARGET --target "$target" 2>/dev/null)" || return 1
    [[ -n "$output" ]] || return 1
    while IFS= read -r mount; do
        [[ "$mount" == "$containing" ]] && continue
        case "$mount" in
            "$target"|"$target"/*)
                publication_fs_mount_target_text_is_safe "$mount" || return 1
                return 1
                ;;
            *) continue ;;
        esac
    done <<< "$output"
}

publication_fs_pointer_target() {
    local root="$1" pointer="$2" expected_uid="$3" expected_gid="$4"
    local target canonical
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    publication_fs_directory_is_canonical "$root" || return 1
    publication_fs_absolute_lexical_path_is_safe "$pointer" || return 1
    [[ "$(dirname -- "$pointer")" == "$root" ]] || return 1
    if [[ ! -e "$pointer" && ! -L "$pointer" ]]; then
        # Empty is the only sentinel: it cannot collide with a valid relative
        # target because publication_fs_relative_path_is_safe rejects it.
        printf '\n'
        return 0
    fi
    [[ -L "$pointer" \
       && "$(publication_fs_uid "$pointer")" == "$expected_uid" \
       && "$(publication_fs_gid "$pointer")" == "$expected_gid" \
       && "$(publication_fs_nlink "$pointer")" == 1 ]] || return 1
    target="$(readlink -- "$pointer")" || return 1
    publication_fs_relative_path_is_safe "$target" || return 1
    canonical="$(readlink -f -- "$root/$target" 2>/dev/null)" || return 1
    [[ "$canonical" == "$root/$target" && -d "$canonical" && ! -L "$canonical" ]] \
        || return 1
    printf '%s\n' "$target"
}

publication_fs_set_symlink_owner() {
    local path="$1" expected_uid="$2" expected_gid="$3"
    [[ -L "$path" && "$(publication_fs_nlink "$path")" == 1 ]] || return 1
    if [[ "$(publication_fs_uid "$path")" == "$expected_uid" \
       && "$(publication_fs_gid "$path")" == "$expected_gid" ]]; then
        return 0
    fi
    [[ "${EUID:-$(id -u)}" == 0 ]] || return 1
    chown -h "$expected_uid:$expected_gid" "$path"
}

publication_fs_temp_pointer_prefix_is_safe() {
    [[ "${1:-}" =~ ^\.[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]
}

publication_fs_orphan_pointer_is_safe() {
    local root="$1" pointer="$2" prefix="$3" expected_uid="$4" expected_gid="$5"
    local name suffix relative target_path
    publication_fs_directory_is_canonical "$root" || return 1
    publication_fs_temp_pointer_prefix_is_safe "$prefix" || return 1
    publication_fs_absolute_lexical_path_is_safe "$pointer" || return 1
    [[ "$(dirname -- "$pointer")" == "$root" ]] || return 1
    name="$(basename -- "$pointer")" || return 1
    [[ "$name" == "$prefix."* ]] || return 1
    suffix="${name#"$prefix."}"
    [[ "$suffix" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    relative="$(publication_fs_pointer_target \
        "$root" "$pointer" "$expected_uid" "$expected_gid")" || return 1
    [[ -n "$relative" ]] || return 1
    target_path="$root/$relative"
    publication_fs_same_mount_boundary "$root" "$target_path" || return 1
    publication_fs_mount_boundary_is_safe "$target_path" "$(dirname -- "$target_path")"
}

publication_fs_cleanup_orphan_pointer() {
    local root="$1" pointer="$2" prefix="$3" expected_uid="$4" expected_gid="$5"
    publication_fs_orphan_pointer_is_safe \
        "$root" "$pointer" "$prefix" "$expected_uid" "$expected_gid" || return 1
    rm -f -- "$pointer" || return 1
    [[ ! -e "$pointer" && ! -L "$pointer" ]] || return 1
    publication_fs_sync_path "$root"
}

# Atomically replace one relative pointer and make the directory entry durable.
# The target generation must already be complete and durably renamed by the
# domain caller. `expected_old` is empty for no pointer or the exact prior target.
# `temp_prefix` defaults to `.<pointer>.new`; a domain with an existing orphan
# grammar may pass its own prefix and must enumerate and clean that exact prefix
# with publication_fs_cleanup_orphan_pointer on the next locked transaction.
publication_fs_commit_relative_pointer() {
    local root="$1" pointer_name="$2" relative_target="$3" expected_old="$4"
    local expected_uid="$5" expected_gid="$6" temp_prefix="${7:-.${2}.new}"
    local pointer current target_path temp
    PUBLICATION_FS_COMMIT_STATE="not-committed"
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    [[ -z "$expected_old" ]] || publication_fs_relative_path_is_safe "$expected_old" \
        || return 1
    publication_fs_temp_pointer_prefix_is_safe "$temp_prefix" || return 1
    publication_fs_directory_is_canonical "$root" || return 1
    [[ "$pointer_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1
    publication_fs_relative_path_is_safe "$relative_target" || return 1
    target_path="$root/$relative_target"
    publication_fs_directory_is_canonical "$target_path" || return 1
    [[ "$target_path" == "$root"/* ]] || return 1
    publication_fs_same_mount_boundary "$root" "$target_path" || return 1
    publication_fs_mount_boundary_is_safe "$target_path" "$(dirname -- "$target_path")" \
        || return 1
    pointer="$root/$pointer_name"
    current="$(publication_fs_pointer_target "$root" "$pointer" "$expected_uid" "$expected_gid")" \
        || return 1
    [[ "$current" == "$expected_old" ]] || return 1
    temp="$root/${temp_prefix}.$$.$RANDOM"
    [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
    ln -s -- "$relative_target" "$temp" || return 1
    publication_fs_set_symlink_owner "$temp" "$expected_uid" "$expected_gid" \
        || { rm -f -- "$temp"; return 1; }
    [[ "$(readlink -- "$temp")" == "$relative_target" ]] \
        || { rm -f -- "$temp"; return 1; }
    publication_fs_directory_is_canonical "$target_path" \
        || { rm -f -- "$temp"; return 1; }
    publication_fs_same_mount_boundary "$root" "$target_path" \
        || { rm -f -- "$temp"; return 1; }
    publication_fs_mount_boundary_is_safe "$target_path" "$(dirname -- "$target_path")" \
        || { rm -f -- "$temp"; return 1; }
    current="$(publication_fs_pointer_target "$root" "$pointer" "$expected_uid" "$expected_gid")" \
        || { rm -f -- "$temp"; return 1; }
    [[ "$current" == "$expected_old" ]] || { rm -f -- "$temp"; return 1; }
    mv -Tf -- "$temp" "$pointer" || { rm -f -- "$temp"; return 1; }
    PUBLICATION_FS_COMMIT_STATE="committed-undurable"
    publication_fs_sync_path "$root" || return 1
    PUBLICATION_FS_COMMIT_STATE="committed"
    [[ "$(publication_fs_pointer_target "$root" "$pointer" "$expected_uid" "$expected_gid")" \
        == "$relative_target" ]]
}
