#!/usr/bin/env bash
# Filesystem-only helper for the atomic 5gpn Console/profile generation tree.
#
# Production callers use /opt/5gpn/ui. Tests may pass another absolute root to
# individual functions, but this file never reads a caller environment variable
# as a production path. Certificate issuance, profile signing, controller calls,
# secrets, locks, and systemd lifecycle remain the caller's responsibility.

UI_GENERATION_ROOT="/opt/5gpn/ui"
UI_GENERATION_IMAGE_SOURCE="/usr/share/5gpn/ui"
UI_GENERATION_MARKER=".5gpn-zashboard-owned"
UI_GENERATION_MARKER_VALUE="5gpn-ui-generations"
UI_GENERATION_PRIMARY_ASSETS=".zash_primary_files"
UI_GENERATION_COMPAT_FILES=".zash_compat_files"
UI_GENERATION_VERSION_FILE=".zash_version"
UI_GENERATION_BASE_FILE=".5gpn-ui-base-target"
UI_GENERATION_ENTRY_MARKER=".5gpn-ui-generation-owned"
UI_GENERATION_ENTRY_MARKER_VALUE="5gpn-ui-generation-v1"
UI_GENERATION_PROFILE_INPUTS=".5gpn-profile-inputs"
UI_GENERATION_DOT_PROFILE="ios-dot.mobileconfig"
UI_GENERATION_INTERCEPT_PROFILE="ios-intercept-ca.mobileconfig"
UI_GENERATION_COMMIT_STATE="not-started"
UI_GENERATION_GC_WARNING=0
declare -gar UI_GENERATION_STABLE_URL_PATHS=(
    apple-touch-icon.png
    favicon.ico
    favicon.svg
    favicon-dark.svg
    icon.svg
    pwa-192x192.png
    pwa-512x512.png
    pwa-maskable-192x192.png
    pwa-maskable-512x512.png
    manifest.webmanifest
    registerSW.js
    sw.js
    pwa-no-cache.js
)

_ui_generation_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
_ui_generation_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
_ui_generation_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
_ui_generation_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

_ui_generation_container_identity() {
    [[ "$1" == "$UI_GENERATION_ROOT" \
       && "${FIVEGPN_RUNTIME:-}" == container \
       && "${EUID:-$(id -u)}" == 10001 \
       && "$(id -g)" == 10001 ]]
}

_ui_generation_expected_uid() {
    if _ui_generation_container_identity "$1"; then
        printf '10001\n'
    elif [[ "$1" == "$UI_GENERATION_ROOT" ]]; then
        printf '0\n'
    else
        printf '%s\n' "${EUID:-$(id -u)}"
    fi
}

_ui_generation_expected_gid() {
    if _ui_generation_container_identity "$1"; then
        printf '10001\n'
    elif [[ "$1" == "$UI_GENERATION_ROOT" ]]; then
        printf '0\n'
    else
        id -g
    fi
}

_ui_generation_set_owner() {
    local root="$1" path="$2" no_dereference="${3:-0}" expected_uid expected_gid
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    if [[ "$(_ui_generation_uid "$path")" == "$expected_uid" \
       && "$(_ui_generation_gid "$path")" == "$expected_gid" ]]; then
        return 0
    fi
    [[ "${EUID:-$(id -u)}" == 0 ]] || return 1
    if [[ "$no_dereference" == 1 ]]; then
        chown -h "$expected_uid:$expected_gid" "$path"
    else
        chown "$expected_uid:$expected_gid" "$path"
    fi
}

_ui_generation_install_directory() {
    local root="$1" path="$2" mode="$3"
    mkdir -- "$path" || return 1
    chmod "$mode" "$path" || return 1
    _ui_generation_set_owner "$root" "$path"
}

_ui_generation_mode_is_nonwritable() {
    local mode="$1" value
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    value=$((8#$mode))
    (( (value & 0022) == 0 ))
}

_ui_generation_path_is_absolute_safe() {
    local path="$1" canonical
    [[ -n "$path" && "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    canonical="$(readlink -m -- "$path" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1 ;;
    esac
}

_ui_generation_directory_is_exact() {
    local root="$1" path="$2" mode="$3" expected_uid expected_gid canonical
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null)" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$(_ui_generation_uid "$path")" == "$expected_uid" \
       && "$(_ui_generation_gid "$path")" == "$expected_gid" \
       && "$(_ui_generation_mode "$path")" == "$mode" ]]
}

_ui_generation_parent_is_safe() {
    local root="$1" parent expected_uid expected_gid canonical
    parent="$(dirname -- "$root")" || return 1
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    canonical="$(readlink -f -- "$parent" 2>/dev/null)" || return 1
    [[ "$canonical" == "$parent" ]] || return 1
    if _ui_generation_container_identity "$root"; then
        [[ "$(_ui_generation_uid "$parent")" == 0 \
           && "$(_ui_generation_gid "$parent")" == 0 ]] || return 1
        _ui_generation_mode_is_nonwritable "$(_ui_generation_mode "$parent")"
        return
    fi
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$(_ui_generation_uid "$parent")" == "$expected_uid" \
       && "$(_ui_generation_gid "$parent")" == "$expected_gid" ]] || return 1
    _ui_generation_mode_is_nonwritable "$(_ui_generation_mode "$parent")"
}

_ui_generation_preflight_ancestor_is_safe() {
    local root="$1" ancestor expected_uid expected_gid canonical
    ancestor="$(dirname -- "$root")" || return 1
    while [[ ! -e "$ancestor" && ! -L "$ancestor" && "$ancestor" != / ]]; do
        ancestor="$(dirname -- "$ancestor")" || return 1
    done
    [[ -d "$ancestor" && ! -L "$ancestor" ]] || return 1
    canonical="$(readlink -f -- "$ancestor" 2>/dev/null)" || return 1
    [[ "$canonical" == "$ancestor" ]] || return 1
    if _ui_generation_container_identity "$root"; then
        [[ "$(_ui_generation_uid "$ancestor")" == 0 \
           && "$(_ui_generation_gid "$ancestor")" == 0 ]] || return 1
        _ui_generation_mode_is_nonwritable "$(_ui_generation_mode "$ancestor")"
        return
    fi
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$(_ui_generation_uid "$ancestor")" == "$expected_uid" \
       && "$(_ui_generation_gid "$ancestor")" == "$expected_gid" ]] || return 1
    _ui_generation_mode_is_nonwritable "$(_ui_generation_mode "$ancestor")"
}

_ui_generation_no_nested_mounts() {
    local root="$1" target output
    command -v findmnt >/dev/null 2>&1 || return 1
    [[ -d "$root" && ! -L "$root" ]] || return 0
    output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in "$root"/*) return 1 ;; esac
    done <<< "$output"
}

_ui_generation_same_mount_boundary() {
    local root="$1" path="$2" root_mount path_mount
    command -v findmnt >/dev/null 2>&1 || return 1
    root_mount="$(findmnt -r -n -o TARGET --target "$root" 2>/dev/null | head -n 1)" \
        || return 1
    path_mount="$(findmnt -r -n -o TARGET --target "$path" 2>/dev/null | head -n 1)" \
        || return 1
    [[ -n "$root_mount" && "$path_mount" == "$root_mount" ]]
}

_ui_generation_sync_tree() {
    sync -f "$1"
}

# Source-level test seam for a deterministic final-current CAS race. Production
# callers do not override it; no path or data is accepted through the environment.
_ui_generation_before_current_commit() { :; }

_ui_generation_find_entries() { # <array-name> <find arguments before -print0>
    local array_name="$1" fd item completed=0
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
    local -n entries_ref="$array_name"
    entries_ref=("${collected[@]}")
}

_ui_generation_relative_path_is_safe() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* \
       && "$path" != *$'\r'* && "$path" != *$'\t'* && "$path" != *'\\'* ]] || return 1
    case "/$path/" in */../*|*/./*) return 1 ;; esac
}

_ui_generation_plain_tree_is_safe() {
    local root="$1" tree="$2" strict="$3" allowed_private="${4:-}"
    local expected_uid expected_gid entry mode
    local root_mode
    local -a entries=()
    [[ -d "$tree" && ! -L "$tree" ]] || return 1
    [[ "$(readlink -f -- "$tree" 2>/dev/null)" == "$tree" ]] || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$(_ui_generation_uid "$tree")" == "$expected_uid" \
       && "$(_ui_generation_gid "$tree")" == "$expected_gid" ]] || return 1
    root_mode="$(_ui_generation_mode "$tree")"
    if [[ "$strict" == 1 ]]; then
        [[ "$root_mode" == 755 ]] || return 1
    else
        [[ "$root_mode" == 700 || "$root_mode" == 755 ]] || return 1
    fi
    _ui_generation_no_nested_mounts "$tree" || return 1
    _ui_generation_find_entries entries "$tree" -mindepth 1 || return 1
    for entry in "${entries[@]}"; do
        _ui_generation_relative_path_is_safe "${entry#"$tree"/}" || return 1
        [[ "$(_ui_generation_uid "$entry")" == "$expected_uid" \
           && "$(_ui_generation_gid "$entry")" == "$expected_gid" ]] || return 1
        if [[ -d "$entry" && ! -L "$entry" ]]; then
            mode="$(_ui_generation_mode "$entry")"
            if [[ "$strict" == 1 ]]; then
                [[ "$mode" == 755 ]] || return 1
            elif [[ "$root_mode" == 755 ]]; then
                _ui_generation_mode_is_nonwritable "$mode" || return 1
            fi
        elif [[ -f "$entry" && ! -L "$entry" ]]; then
            [[ "$(_ui_generation_nlink "$entry")" == 1 ]] || return 1
            mode="$(_ui_generation_mode "$entry")"
            if [[ "$strict" == 1 ]]; then
                if [[ -n "$allowed_private" && "$entry" == "$allowed_private" ]]; then
                    [[ "$mode" == 600 ]] || return 1
                else
                    [[ "$mode" == 644 ]] || return 1
                fi
            elif [[ "$root_mode" == 755 ]]; then
                _ui_generation_mode_is_nonwritable "$mode" || return 1
            fi
        else
            return 1
        fi
    done
}

_ui_generation_plain_file_is_safe() {
    local root="$1" path="$2" mode="$3" expected_uid expected_gid
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ -f "$path" && ! -L "$path" \
       && "$(_ui_generation_uid "$path")" == "$expected_uid" \
       && "$(_ui_generation_gid "$path")" == "$expected_gid" \
       && "$(_ui_generation_mode "$path")" == "$mode" \
       && "$(_ui_generation_nlink "$path")" == 1 ]]
}

_ui_generation_marker_is_safe() {
    local root="$1" marker="$1/$UI_GENERATION_MARKER"
    _ui_generation_plain_file_is_safe "$root" "$marker" 644 \
        && printf '%s\n' "$UI_GENERATION_MARKER_VALUE" | cmp -s - "$marker"
}

_ui_generation_marker_candidate_is_safe() {
    local root="$1" candidate="$2" name mode size expected_uid expected_gid
    name="$(basename -- "$candidate")" || return 1
    [[ "$candidate" == "$root/$name" \
       && "$name" =~ ^\.5gpn-ui-marker\.[0-9A-Za-z]{6}$ \
       && -f "$candidate" && ! -L "$candidate" \
       && "$(_ui_generation_nlink "$candidate")" == 1 ]] || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    mode="$(_ui_generation_mode "$candidate")"
    size="$(stat -c %s -- "$candidate" 2>/dev/null || true)"
    [[ "$(_ui_generation_uid "$candidate")" == "$expected_uid" \
       && "$(_ui_generation_gid "$candidate")" == "$expected_gid" \
       && ( "$mode" == 600 || "$mode" == 644 ) \
       && "$size" =~ ^[0-9]+$ && "$size" -le 128 ]]
}

_ui_generation_name_is_safe() {
    [[ "${1:-}" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9A-Za-z]{6}$ ]]
}

_ui_generation_candidate_name_is_safe() {
    [[ "${1:-}" =~ ^\.candidate-generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9A-Za-z]{6}$ ]]
}

_ui_generation_current_target() {
    local root="$1" current="$1/current" target name expected_uid expected_gid
    [[ -e "$current" || -L "$current" ]] || { printf 'absent\n'; return 0; }
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ -L "$current" \
       && "$(_ui_generation_uid "$current")" == "$expected_uid" \
       && "$(_ui_generation_gid "$current")" == "$expected_gid" \
       && "$(_ui_generation_nlink "$current")" == 1 ]] || return 1
    target="$(readlink -- "$current")" || return 1
    [[ "$target" == generations/* ]] || return 1
    name="${target#generations/}"
    _ui_generation_name_is_safe "$name" || return 1
    [[ "$target" == "generations/$name" ]] || return 1
    printf '%s\n' "$target"
}

_ui_generation_temp_link_is_safe() {
    local root="$1" entry="$2" name target expected_uid expected_gid
    name="$(basename -- "$entry")" || return 1
    [[ "$entry" == "$root/$name" \
       && "$name" =~ ^\.current\.new\.[0-9]+\.[0-9]+$ \
       && -L "$entry" ]] || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$(_ui_generation_uid "$entry")" == "$expected_uid" \
       && "$(_ui_generation_gid "$entry")" == "$expected_gid" \
       && "$(_ui_generation_nlink "$entry")" == 1 ]] || return 1
    target="$(readlink -- "$entry")" || return 1
    [[ "$target" == generations/* ]] || return 1
    _ui_generation_name_is_safe "${target#generations/}" || return 1
    _ui_generation_complete_is_safe "$root" "$root/$target"
}

_ui_generation_primary_manifest_is_safe() {
    local root="$1" generation="$2" manifest="$2/$UI_GENERATION_PRIMARY_ASSETS"
    local digest path extra previous="" actual LC_ALL=C
    _ui_generation_plain_file_is_safe "$root" "$manifest" 644 || return 1
    while IFS=$'\t' read -r digest path extra || [[ -n "$digest$path$extra" ]]; do
        [[ -z "$extra" && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        _ui_generation_relative_path_is_safe "$path" || return 1
        [[ "$path" == assets/* && "$path" != assets/ ]] || return 1
        [[ -z "$previous" || "$previous" < "$path" ]] || return 1
        _ui_generation_plain_file_is_safe "$root" "$generation/$path" 644 || return 1
        actual="$(sha256sum -- "$generation/$path" 2>/dev/null | awk '{print $1}')" || return 1
        [[ "$actual" == "$digest" ]] || return 1
        previous="$path"
    done < "$manifest"
}

_ui_generation_primary_manifest_contains_path() {
    local generation="$1" needle="$2" digest path extra
    while IFS=$'\t' read -r digest path extra || [[ -n "$digest$path$extra" ]]; do
        [[ -z "$extra" ]] || return 1
        [[ "$path" == "$needle" ]] && return 0
    done < "$generation/$UI_GENERATION_PRIMARY_ASSETS"
    return 1
}

_ui_generation_compat_manifest_is_safe() {
    local root="$1" generation="$2" manifest="$2/$UI_GENERATION_COMPAT_FILES"
    local digest path extra previous="" actual LC_ALL=C
    _ui_generation_plain_file_is_safe "$root" "$manifest" 644 || return 1
    while IFS=$'\t' read -r digest path extra || [[ -n "$digest$path$extra" ]]; do
        [[ -z "$extra" && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        _ui_generation_relative_path_is_safe "$path" || return 1
        [[ "$path" == assets/* && "$path" != assets/ ]] || return 1
        [[ -z "$previous" || "$previous" < "$path" ]] || return 1
        ! _ui_generation_primary_manifest_contains_path "$generation" "$path" || return 1
        _ui_generation_plain_file_is_safe "$root" "$generation/$path" 644 || return 1
        actual="$(sha256sum -- "$generation/$path" 2>/dev/null | awk '{print $1}')" || return 1
        [[ "$actual" == "$digest" ]] || return 1
        previous="$path"
    done < "$manifest"
}

_ui_generation_ipv4_is_safe() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" == 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

_ui_generation_profile_manifest_bytes_are_safe() {
    local path="$1" size bytes invalid
    size="$(stat -c %s -- "$path" 2>/dev/null)" || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge 1 && "$size" -le 2048 ]] || return 1
    bytes="$(LC_ALL=C od -An -tu1 -v -- "$path" 2>/dev/null)" || return 1
    invalid="$(awk \
        '{ for (i = 1; i <= NF; i++) if ($i != 10 && ($i < 32 || $i > 126)) { print $i; exit } }' \
        <<< "$bytes")" \
        || return 1
    [[ -z "$invalid" ]]
}

_ui_generation_profile_inputs_are_safe() {
    local root="$1" generation="$2" manifest="$2/$UI_GENERATION_PROFILE_INPUTS"
    local -a lines=()
    local domain gateway dot_profile_sha intercept_profile_sha actual
    _ui_generation_plain_file_is_safe "$root" "$manifest" 644 || return 1
    _ui_generation_profile_manifest_bytes_are_safe "$manifest" || return 1
    mapfile -t lines < "$manifest" || return 1
    [[ "${#lines[@]}" == 8 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" =~ ^dot_signer_leaf_sha256=[0-9a-f]{64}$ \
       && "${lines[2]}" =~ ^dot_public_key_sha256=[0-9a-f]{64}$ \
       && "${lines[3]}" =~ ^intercept_ca_der_sha256=[0-9a-f]{64}$ \
       && "${lines[4]}" == domain=* \
       && "${lines[5]}" == gateway_ipv4=* \
       && "${lines[6]}" =~ ^ios_dot_sha256=[0-9a-f]{64}$ \
       && "${lines[7]}" =~ ^ios_intercept_ca_sha256=[0-9a-f]{64}$ ]] || return 1
    domain="${lines[4]#domain=}"
    gateway="${lines[5]#gateway_ipv4=}"
    [[ ${#domain} -ge 1 && ${#domain} -le 253 \
       && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        && _ui_generation_ipv4_is_safe "$gateway" || return 1
    dot_profile_sha="${lines[6]#ios_dot_sha256=}"
    intercept_profile_sha="${lines[7]#ios_intercept_ca_sha256=}"
    actual="$(sha256sum -- "$generation/$UI_GENERATION_DOT_PROFILE" | awk '{print $1}')" \
        || return 1
    [[ "$actual" == "$dot_profile_sha" ]] || return 1
    actual="$(sha256sum -- "$generation/$UI_GENERATION_INTERCEPT_PROFILE" | awk '{print $1}')" \
        || return 1
    [[ "$actual" == "$intercept_profile_sha" ]]
}

_ui_generation_path_is_stable_url() {
    local needle="$1" path
    for path in "${UI_GENERATION_STABLE_URL_PATHS[@]}"; do
        [[ "$path" == "$needle" ]] && return 0
    done
    return 1
}

_ui_generation_web_manifest_is_safe() {
    local root="$1" generation="$2" manifest="$2/manifest.webmanifest"
    local sources source normalized
    [[ ! -e "$manifest" && ! -L "$manifest" ]] && return 0
    _ui_generation_plain_file_is_safe "$root" "$manifest" 644 \
        && [[ -s "$manifest" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e '
        type == "object"
        and (.icons | type == "array" and length > 0)
        and all(.icons[];
            type == "object"
            and (.src | type == "string")
            and (.src | test("^(\\./)?[A-Za-z0-9][A-Za-z0-9._-]*$")))
    ' "$manifest" >/dev/null 2>&1 || return 1
    sources="$(jq -er '.icons[].src' "$manifest")" || return 1
    while IFS= read -r source; do
        [[ -n "$source" ]] || return 1
        normalized="${source#./}"
        [[ "$source" == "$normalized" || "$source" == "./$normalized" ]] || return 1
        _ui_generation_relative_path_is_safe "$normalized" || return 1
        _ui_generation_path_is_stable_url "$normalized" || return 1
        _ui_generation_plain_file_is_safe "$root" "$generation/$normalized" 644 \
            && [[ -s "$generation/$normalized" ]] || return 1
    done <<< "$sources"
}

_ui_generation_complete_is_safe() {
    local root="$1" generation="$2" allow_base="${3:-0}"
    local version transient stable_path base base_name
    local allowed_private=""
    [[ "$allow_base" != 1 ]] \
        || allowed_private="$generation/$UI_GENERATION_BASE_FILE"
    _ui_generation_plain_tree_is_safe "$root" "$generation" 1 "$allowed_private" || return 1
    transient="$(find "$generation" -mindepth 1 -name '.ios-profile.*' -print -quit 2>/dev/null)" \
        || return 1
    [[ -z "$transient" ]] || return 1
    _ui_generation_plain_file_is_safe "$root" "$generation/$UI_GENERATION_ENTRY_MARKER" 644 \
        && printf '%s\n' "$UI_GENERATION_ENTRY_MARKER_VALUE" \
            | cmp -s - "$generation/$UI_GENERATION_ENTRY_MARKER" || return 1
    _ui_generation_plain_file_is_safe "$root" "$generation/index.html" 644 \
        && [[ -s "$generation/index.html" ]] || return 1
    _ui_generation_plain_file_is_safe "$root" "$generation/$UI_GENERATION_VERSION_FILE" 644 || return 1
    IFS= read -r version < "$generation/$UI_GENERATION_VERSION_FILE" || return 1
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$ \
       && "$(wc -l < "$generation/$UI_GENERATION_VERSION_FILE" | tr -d '[:space:]')" == 1 ]] || return 1
    _ui_generation_primary_manifest_is_safe "$root" "$generation" || return 1
    _ui_generation_compat_manifest_is_safe "$root" "$generation" || return 1
    _ui_generation_plain_file_is_safe "$root" "$generation/$UI_GENERATION_DOT_PROFILE" 644 \
        && [[ -s "$generation/$UI_GENERATION_DOT_PROFILE" ]] || return 1
    _ui_generation_plain_file_is_safe "$root" "$generation/$UI_GENERATION_INTERCEPT_PROFILE" 644 \
        && [[ -s "$generation/$UI_GENERATION_INTERCEPT_PROFILE" ]] || return 1
    _ui_generation_profile_inputs_are_safe "$root" "$generation" || return 1
    for stable_path in "${UI_GENERATION_STABLE_URL_PATHS[@]}"; do
        [[ ! -e "$generation/$stable_path" && ! -L "$generation/$stable_path" ]] && continue
        _ui_generation_plain_file_is_safe "$root" "$generation/$stable_path" 644 \
            && [[ -s "$generation/$stable_path" ]] || return 1
    done
    _ui_generation_web_manifest_is_safe "$root" "$generation" || return 1
    if [[ "$allow_base" == 1 ]]; then
        _ui_generation_plain_file_is_safe \
            "$root" "$generation/$UI_GENERATION_BASE_FILE" 600 || return 1
        IFS= read -r base < "$generation/$UI_GENERATION_BASE_FILE" || return 1
        printf '%s\n' "$base" \
            | cmp -s - "$generation/$UI_GENERATION_BASE_FILE" || return 1
        if [[ "$base" != absent ]]; then
            [[ "$base" == generations/* ]] || return 1
            base_name="${base#generations/}"
            _ui_generation_name_is_safe "$base_name" || return 1
            [[ "$base" == "generations/$base_name" ]] || return 1
        fi
        return 0
    fi
    [[ ! -e "$generation/$UI_GENERATION_BASE_FILE" \
       && ! -L "$generation/$UI_GENERATION_BASE_FILE" ]]
}

_ui_generation_candidate_is_safe() {
    local root="$1" candidate="$2" generations="$1/generations" name canonical marker_mode
    name="$(basename -- "$candidate")" || return 1
    _ui_generation_candidate_name_is_safe "$name" || return 1
    [[ "$candidate" == "$generations/$name" ]] || return 1
    canonical="$(readlink -f -- "$candidate" 2>/dev/null)" || return 1
    [[ "$canonical" == "$candidate" ]] || return 1
    _ui_generation_plain_tree_is_safe "$root" "$candidate" 0 || return 1
    marker_mode="$(_ui_generation_mode "$candidate/$UI_GENERATION_ENTRY_MARKER")"
    [[ "$marker_mode" == 600 || "$marker_mode" == 644 ]] || return 1
    _ui_generation_plain_file_is_safe "$root" "$candidate/$UI_GENERATION_ENTRY_MARKER" "$marker_mode" \
        && printf '%s\n' "$UI_GENERATION_ENTRY_MARKER_VALUE" \
            | cmp -s - "$candidate/$UI_GENERATION_ENTRY_MARKER"
}

_ui_generation_candidate_preclaim_is_safe() {
    local root="$1" candidate="$2" generations="$1/generations" name canonical entry size
    local -a entries=()
    name="$(basename -- "$candidate")" || return 1
    _ui_generation_candidate_name_is_safe "$name" || return 1
    [[ "$candidate" == "$generations/$name" ]] || return 1
    canonical="$(readlink -f -- "$candidate" 2>/dev/null)" || return 1
    [[ "$canonical" == "$candidate" \
       && -d "$candidate" && ! -L "$candidate" \
       && "$(_ui_generation_uid "$candidate")" == "$(_ui_generation_expected_uid "$root")" \
       && "$(_ui_generation_gid "$candidate")" == "$(_ui_generation_expected_gid "$root")" \
       && "$(_ui_generation_mode "$candidate")" == 700 ]] || return 1
    _ui_generation_find_entries entries "$candidate" -mindepth 1 -maxdepth 1 || return 1
    (( ${#entries[@]} <= 1 )) || return 1
    ((${#entries[@]} == 0)) && return 0
    entry="${entries[0]}"
    [[ "$(basename -- "$entry")" == "$UI_GENERATION_ENTRY_MARKER" \
       && -f "$entry" && ! -L "$entry" \
       && "$(_ui_generation_uid "$entry")" == "$(_ui_generation_expected_uid "$root")" \
       && "$(_ui_generation_gid "$entry")" == "$(_ui_generation_expected_gid "$root")" \
       && "$(_ui_generation_mode "$entry")" == 600 \
       && "$(_ui_generation_nlink "$entry")" == 1 ]] || return 1
    size="$(stat -c %s -- "$entry" 2>/dev/null || true)"
    [[ "$size" =~ ^[0-9]+$ && "$size" -le 128 ]]
}

ui_generation_candidate_is_safe() {
    _ui_generation_candidate_is_safe "$1" "$2"
}

_ui_generation_root_boundary_is_safe() {
    local root="$1" allow_incomplete="${2:-0}" allowed_temp="${3:-}"
    local allow_orphan_temps="${4:-0}" entry name current target
    local -a root_entries=() generation_entries=()
    _ui_generation_path_is_absolute_safe "$root" || return 1
    _ui_generation_directory_is_exact "$root" "$root" 755 || return 1
    _ui_generation_no_nested_mounts "$root" || return 1
    _ui_generation_marker_is_safe "$root" || return 1
    _ui_generation_find_entries root_entries "$root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$UI_GENERATION_MARKER") ;;
            generations)
                [[ -d "$entry" && ! -L "$entry" ]] || return 1 ;;
            current)
                [[ -L "$entry" ]] || return 1 ;;
            *)
                [[ ( -n "$allowed_temp" && "$entry" == "$allowed_temp" ) \
                   || "$allow_orphan_temps" == 1 ]] || return 1
                _ui_generation_temp_link_is_safe "$root" "$entry" || return 1
                ;;
        esac
    done
    if [[ ! -e "$root/generations" && ! -L "$root/generations" ]]; then
        [[ "$allow_incomplete" == 1 \
           && ! -e "$root/current" && ! -L "$root/current" ]] || return 1
        return 0
    fi
    _ui_generation_directory_is_exact "$root" "$root/generations" 755 || return 1
    _ui_generation_no_nested_mounts "$root/generations" || return 1
    _ui_generation_find_entries generation_entries "$root/generations" -mindepth 1 -maxdepth 1 \
        || return 1
    for entry in "${generation_entries[@]}"; do
        name="$(basename -- "$entry")"
        if _ui_generation_name_is_safe "$name"; then
            _ui_generation_complete_is_safe "$root" "$entry" || return 1
        elif _ui_generation_candidate_name_is_safe "$name"; then
            _ui_generation_candidate_is_safe "$root" "$entry" \
                || { [[ "$allow_incomplete" == 1 ]] \
                     && _ui_generation_candidate_preclaim_is_safe "$root" "$entry"; } \
                || return 1
        else
            return 1
        fi
    done
    current="$root/current"
    target="$(_ui_generation_current_target "$root")" || return 1
    if [[ "$target" != absent ]]; then
        _ui_generation_complete_is_safe "$root" "$root/$target" || return 1
    elif [[ -e "$current" || -L "$current" ]]; then
        return 1
    fi
}

_ui_generation_current_only_is_safe() {
    local root="$1" entry name target
    local -a root_entries=()
    _ui_generation_path_is_absolute_safe "$root" || return 1
    _ui_generation_directory_is_exact "$root" "$root" 755 || return 1
    _ui_generation_marker_is_safe "$root" || return 1
    _ui_generation_directory_is_exact "$root" "$root/generations" 755 || return 1
    _ui_generation_same_mount_boundary "$root" "$root/generations" || return 1
    _ui_generation_find_entries root_entries "$root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$UI_GENERATION_MARKER"|generations) ;;
            current) [[ -L "$entry" ]] || return 1 ;;
            .current.new.*) _ui_generation_temp_link_is_safe "$root" "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done
    target="$(_ui_generation_current_target "$root")" || return 1
    [[ "$target" != absent ]] || return 1
    _ui_generation_same_mount_boundary "$root" "$root/$target" || return 1
    _ui_generation_complete_is_safe "$root" "$root/$target"
}

ui_generation_preflight() {
    local root="${1:-$UI_GENERATION_ROOT}" parent entry count=0
    local -a entries=()
    _ui_generation_path_is_absolute_safe "$root" || return 1
    _ui_generation_preflight_ancestor_is_safe "$root" || return 1
    [[ ! -e "$root" && ! -L "$root" ]] && return 0
    [[ -d "$root" && ! -L "$root" ]] || return 1
    parent="$(dirname -- "$root")" || return 1
    if _ui_generation_container_identity "$root"; then
        [[ "$(findmnt -r -n -o TARGET --target "$root" 2>/dev/null | head -n 1)" == "$root" ]] \
            || return 1
    else
        _ui_generation_same_mount_boundary "$parent" "$root" || return 1
    fi
    if [[ -e "$root/$UI_GENERATION_MARKER" || -L "$root/$UI_GENERATION_MARKER" ]]; then
        _ui_generation_root_boundary_is_safe "$root" 1 "" 1
        return
    fi
    _ui_generation_directory_is_exact "$root" "$root" 755 || return 1
    _ui_generation_no_nested_mounts "$root" || return 1
    _ui_generation_find_entries entries "$root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        _ui_generation_marker_candidate_is_safe "$root" "$entry" || return 1
        count=$((count + 1))
    done
    (( count <= 1 ))
}

_ui_generation_write_marker() {
    local root="$1" parent tmp expected_uid expected_gid
    parent="$(dirname -- "$root")" || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    if _ui_generation_container_identity "$root"; then
        tmp="$(mktemp "$root/.5gpn-ui-marker.XXXXXX")" || return 1
    else
        tmp="$(mktemp "$parent/.5gpn-ui-marker.XXXXXX")" || return 1
    fi
    if ! printf '%s\n' "$UI_GENERATION_MARKER_VALUE" > "$tmp" \
       || ! _ui_generation_set_owner "$root" "$tmp" \
       || ! chmod 0644 "$tmp" \
       || ! mv -Tf -- "$tmp" "$root/$UI_GENERATION_MARKER"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -f "$root" || return 1
    _ui_generation_marker_is_safe "$root"
}

ui_generation_cleanup_marker_candidates() {
    local root="${1:-$UI_GENERATION_ROOT}" entry removed=0
    local -a entries=()
    [[ ! -e "$root/$UI_GENERATION_MARKER" && ! -L "$root/$UI_GENERATION_MARKER" ]] \
        || return 0
    ui_generation_preflight "$root" || return 1
    _ui_generation_find_entries entries "$root" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        _ui_generation_marker_candidate_is_safe "$root" "$entry" || return 1
        rm -f -- "$entry" || return 1
        removed=1
    done
    [[ "$removed" == 0 ]] || sync -f "$root"
}

ui_generation_claim_root() {
    local root="${1:-$UI_GENERATION_ROOT}" expected_uid expected_gid
    ui_generation_preflight "$root" || return 1
    _ui_generation_parent_is_safe "$root" || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    if [[ ! -e "$root" && ! -L "$root" ]]; then
        _ui_generation_install_directory "$root" "$root" 0755 || return 1
    fi
    ui_generation_cleanup_marker_candidates "$root" || return 1
    if [[ ! -e "$root/$UI_GENERATION_MARKER" && ! -L "$root/$UI_GENERATION_MARKER" ]]; then
        _ui_generation_write_marker "$root" || return 1
    fi
    if [[ ! -e "$root/generations" && ! -L "$root/generations" ]]; then
        _ui_generation_install_directory "$root" "$root/generations" 0755 || return 1
        sync -f "$root" || return 1
    fi
    ui_generation_cleanup_orphan_candidates "$root" || return 1
    ui_generation_cleanup_orphan_current_links "$root" || return 1
    _ui_generation_root_boundary_is_safe "$root" 0
}

ui_generation_prepare_existing_current() {
    local root="${1:-$UI_GENERATION_ROOT}"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    _ui_generation_parent_is_safe "$root" || return 1
    ui_generation_preflight "$root" || return 1
    _ui_generation_marker_is_safe "$root" || return 1
    [[ -d "$root/generations" && ! -L "$root/generations" ]] || return 1
    ui_generation_cleanup_orphan_current_links "$root" || return 1
    _ui_generation_current_only_is_safe "$root"
}

ui_generation_cleanup_orphan_current_links() {
    local root="$1" entry found=0
    local -a entries=()
    _ui_generation_root_boundary_is_safe "$root" 0 "" 1 || return 1
    _ui_generation_find_entries entries "$root" -mindepth 1 -maxdepth 1 -name '.current.new.*' \
        || return 1
    for entry in "${entries[@]}"; do
        _ui_generation_temp_link_is_safe "$root" "$entry" || return 1
        rm -f -- "$entry" || return 1
        found=1
    done
    [[ "$found" == 0 ]] || sync -f "$root"
}

_ui_generation_new_candidate() {
    local root="$1" stamp candidate expected_uid expected_gid marker
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    candidate="$(mktemp -d "$root/generations/.candidate-generation-${stamp}-$$-XXXXXX")" || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    _ui_generation_set_owner "$root" "$candidate" \
        && chmod 0700 "$candidate" \
        || { rmdir -- "$candidate" 2>/dev/null || true; return 1; }
    marker="$candidate/$UI_GENERATION_ENTRY_MARKER"
    if ! printf '%s\n' "$UI_GENERATION_ENTRY_MARKER_VALUE" > "$marker" \
       || ! _ui_generation_set_owner "$root" "$marker" \
       || ! chmod 0600 "$marker"; then
        rm -f -- "$marker"
        rmdir -- "$candidate" 2>/dev/null || true
        return 1
    fi
    _ui_generation_candidate_is_safe "$root" "$candidate" \
        || { rm -f -- "$marker"; rmdir -- "$candidate" 2>/dev/null || true; return 1; }
    printf '%s\n' "$candidate"
}

_ui_generation_write_base_target() {
    local root="$1" candidate="$2" target="$3" path="$2/$UI_GENERATION_BASE_FILE"
    local expected_uid expected_gid
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    [[ "$target" == absent || "$target" == generations/* ]] || return 1
    printf '%s\n' "$target" > "$path" \
        && _ui_generation_set_owner "$root" "$path" \
        && chmod 0600 "$path"
}

_ui_generation_normalize_candidate() {
    local root="$1" candidate="$2" expected_uid expected_gid
    local entry
    local -a entries=()
    _ui_generation_candidate_is_safe "$root" "$candidate" || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    if [[ "${EUID:-$(id -u)}" == 0 ]]; then
        find "$candidate" -mindepth 1 -exec chown "$expected_uid:$expected_gid" {} + || return 1
    else
        _ui_generation_find_entries entries "$candidate" -mindepth 1 || return 1
        for entry in "${entries[@]}"; do
            _ui_generation_set_owner "$root" "$entry" || return 1
        done
    fi
    find "$candidate" -mindepth 1 -type d -exec chmod 0755 {} + \
        && find "$candidate" -mindepth 1 -type f -exec chmod 0644 {} + \
        && _ui_generation_set_owner "$root" "$candidate" \
        && chmod 0755 "$candidate"
}

_ui_generation_source_tree_is_safe() {
    local source="$1" entry name transient
    local -a entries=()
    [[ -d "$source" && ! -L "$source" \
       && "$(readlink -f -- "$source" 2>/dev/null)" == "$source" ]] || return 1
    _ui_generation_no_nested_mounts "$source" || return 1
    _ui_generation_find_entries entries "$source" -mindepth 1 || return 1
    for entry in "${entries[@]}"; do
        _ui_generation_relative_path_is_safe "${entry#"$source"/}" || return 1
        if [[ -f "$entry" && ! -L "$entry" ]]; then
            [[ "$(_ui_generation_nlink "$entry")" == 1 ]] || return 1
        elif [[ -d "$entry" && ! -L "$entry" ]]; then
            :
        else
            return 1
        fi
    done
    transient="$(find "$source" -mindepth 1 -name '.ios-profile.*' -print -quit 2>/dev/null)" \
        || return 1
    [[ -z "$transient" ]] || return 1
    for name in "$UI_GENERATION_MARKER" "$UI_GENERATION_PRIMARY_ASSETS" \
                "$UI_GENERATION_COMPAT_FILES" \
                "$UI_GENERATION_VERSION_FILE" "$UI_GENERATION_BASE_FILE" \
                "$UI_GENERATION_ENTRY_MARKER" \
                "$UI_GENERATION_PROFILE_INPUTS" \
                "$UI_GENERATION_DOT_PROFILE" "$UI_GENERATION_INTERCEPT_PROFILE"; do
        [[ ! -e "$source/$name" && ! -L "$source/$name" ]] || return 1
    done
    [[ -f "$source/index.html" && ! -L "$source/index.html" && -s "$source/index.html" ]]
}

_ui_generation_write_primary_manifest() {
    local root="$1" candidate="$2" source="$3" manifest="$2/$UI_GENERATION_PRIMARY_ASSETS"
    local entry relative digest expected_uid expected_gid sorted_text
    local -a source_files=() sorted_files=()
    expected_uid="$(_ui_generation_expected_uid "$root")" || return 1
    expected_gid="$(_ui_generation_expected_gid "$root")" || return 1
    : > "$manifest" || return 1
    if [[ -d "$source/assets" && ! -L "$source/assets" ]]; then
        _ui_generation_find_entries source_files "$source/assets" -type f || return 1
    fi
    if ((${#source_files[@]} > 0)); then
        sorted_text="$(printf '%s\n' "${source_files[@]}" | LC_ALL=C sort)" || return 1
        mapfile -t sorted_files <<< "$sorted_text"
    fi
    for entry in "${sorted_files[@]}"; do
        relative="${entry#"$source"/}"
        _ui_generation_relative_path_is_safe "$relative" || return 1
        [[ "$relative" == assets/* && "$relative" != assets/ ]] || return 1
        digest="$(sha256sum -- "$entry" 2>/dev/null | awk '{print $1}')" || return 1
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s\t%s\n' "$digest" "$relative" >> "$manifest" || return 1
    done
    _ui_generation_set_owner "$root" "$manifest" \
        && chmod 0644 "$manifest"
}

_ui_generation_copy_source() {
    local root="$1" source="$2" candidate="$3"
    if _ui_generation_container_identity "$root"; then
        cp -R --no-preserve=ownership -- "$source/." "$candidate/"
    else
        cp -a -- "$source/." "$candidate/"
    fi
}

_ui_generation_merge_previous_primary_assets() {
    local root="$1" candidate="$2" current="$3" manifest
    local digest relative extra source destination destination_parent actual
    [[ "$current" != absent ]] || return 0
    current="$root/$current"
    _ui_generation_complete_is_safe "$root" "$current" || return 1
    manifest="$current/$UI_GENERATION_PRIMARY_ASSETS"
    while IFS=$'\t' read -r digest relative extra || [[ -n "$digest$relative$extra" ]]; do
        [[ -z "$extra" && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        _ui_generation_relative_path_is_safe "$relative" || return 1
        [[ "$relative" == assets/* && "$relative" != assets/ ]] || return 1
        source="$current/$relative"
        destination="$candidate/$relative"
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" \
               && "$(_ui_generation_nlink "$destination")" == 1 \
               && "$(sha256sum -- "$destination" | awk '{print $1}')" == "$digest" ]] \
                || return 1
            continue
        fi
        destination_parent="$(dirname -- "$destination")" || return 1
        mkdir -p -- "$destination_parent" || return 1
        install -m 0644 -- "$source" "$destination" || return 1
        actual="$(sha256sum -- "$destination" | awk '{print $1}')" || return 1
        [[ "$actual" == "$digest" ]] || return 1
        printf '%s\t%s\n' "$digest" "$relative" >> "$candidate/$UI_GENERATION_COMPAT_FILES" \
            || return 1
    done < "$manifest"
}

_ui_generation_stable_urls_remain_available() {
    local root="$1" current="$2" candidate="$3" stable_path
    _ui_generation_web_manifest_is_safe "$root" "$candidate" || return 1
    [[ "$current" != absent ]] || return 0
    for stable_path in "${UI_GENERATION_STABLE_URL_PATHS[@]}"; do
        [[ ! -e "$root/$current/$stable_path" && ! -L "$root/$current/$stable_path" ]] && continue
        _ui_generation_plain_file_is_safe "$root" "$root/$current/$stable_path" 644 \
            && [[ -s "$root/$current/$stable_path" ]] || return 1
        [[ -f "$candidate/$stable_path" && ! -L "$candidate/$stable_path" \
           && "$(_ui_generation_nlink "$candidate/$stable_path")" == 1 \
           && -s "$candidate/$stable_path" ]] || return 1
    done
}

ui_generation_stage_tree() {
    local root="$1" source="$2" version="$3" current candidate
    ui_generation_claim_root "$root" || return 1
    _ui_generation_source_tree_is_safe "$source" || return 1
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$ ]] || return 1
    current="$(_ui_generation_current_target "$root")" || return 1
    candidate="$(_ui_generation_new_candidate "$root")" || return 1
    if ! _ui_generation_write_base_target "$root" "$candidate" "$current" \
       || ! _ui_generation_copy_source "$root" "$source" "$candidate" \
       || ! printf '%s\n' "$version" > "$candidate/$UI_GENERATION_VERSION_FILE" \
       || ! _ui_generation_write_primary_manifest "$root" "$candidate" "$source" \
       || ! : > "$candidate/$UI_GENERATION_COMPAT_FILES" \
       || ! _ui_generation_merge_previous_primary_assets "$root" "$candidate" "$current" \
       || ! _ui_generation_normalize_candidate "$root" "$candidate" \
       || ! _ui_generation_stable_urls_remain_available "$root" "$current" "$candidate"; then
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    fi
    # The base-target file is transaction metadata and intentionally remains
    # 0644 after normalization; publish validates and removes it before the
    # generation can become reachable.
    chmod 0600 "$candidate/$UI_GENERATION_BASE_FILE" || {
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    }
    _ui_generation_candidate_is_safe "$root" "$candidate" || {
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    }
    printf '%s\n' "$candidate"
}

ui_generation_clone_current() {
    local root="${1:-$UI_GENERATION_ROOT}" current candidate
    _ui_generation_root_boundary_is_safe "$root" 0 || return 1
    current="$(_ui_generation_current_target "$root")" || return 1
    [[ "$current" != absent ]] || return 1
    candidate="$(_ui_generation_new_candidate "$root")" || return 1
    if ! _ui_generation_write_base_target "$root" "$candidate" "$current" \
       || ! cp -a -- "$root/$current/." "$candidate/" \
       || ! _ui_generation_normalize_candidate "$root" "$candidate"; then
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    fi
    chmod 0600 "$candidate/$UI_GENERATION_BASE_FILE" || {
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    }
    _ui_generation_candidate_is_safe "$root" "$candidate" || {
        ui_generation_cleanup_candidate "$root" "$candidate" || true
        return 1
    }
    printf '%s\n' "$candidate"
}

ui_generation_cleanup_candidate() {
    local root="$1" candidate="${2:-}"
    [[ -n "$candidate" ]] || return 0
    [[ ! -e "$candidate" && ! -L "$candidate" ]] && return 0
    _ui_generation_root_boundary_is_safe "$root" 0 || return 1
    _ui_generation_candidate_is_safe "$root" "$candidate" || return 1
    _ui_generation_no_nested_mounts "$candidate" || return 1
    rm -rf -- "$candidate" || return 1
    sync -f "$root/generations"
}

ui_generation_cleanup_orphan_candidates() {
    local root="${1:-$UI_GENERATION_ROOT}" entry name
    local -a entries=()
    _ui_generation_root_boundary_is_safe "$root" 1 "" 1 || return 1
    [[ -d "$root/generations" && ! -L "$root/generations" ]] || return 0
    _ui_generation_find_entries entries "$root/generations" -mindepth 1 -maxdepth 1 \
        || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")" || return 1
        _ui_generation_candidate_name_is_safe "$name" || continue
        if _ui_generation_candidate_is_safe "$root" "$entry"; then
            _ui_generation_no_nested_mounts "$entry" || return 1
            rm -rf -- "$entry" || return 1
            sync -f "$root/generations" || return 1
        elif _ui_generation_candidate_preclaim_is_safe "$root" "$entry"; then
            rm -f -- "$entry/$UI_GENERATION_ENTRY_MARKER" || return 1
            rmdir -- "$entry" || return 1
            sync -f "$root/generations" || return 1
        else
            return 1
        fi
    done
}

_ui_generation_remove_entry() {
    local root="$1" entry="$2" protected_current="${3:-}" name relative live
    name="$(basename -- "$entry")" || return 1
    if _ui_generation_candidate_name_is_safe "$name"; then
        _ui_generation_candidate_is_safe "$root" "$entry" || return 1
    elif _ui_generation_name_is_safe "$name"; then
        _ui_generation_complete_is_safe "$root" "$entry" || return 1
    else
        return 1
    fi
    _ui_generation_no_nested_mounts "$entry" || return 1
    if [[ -n "$protected_current" ]]; then
        live="$(_ui_generation_current_target "$root")" || return 1
        relative="generations/$name"
        [[ "$live" == "$protected_current" && "$relative" != "$live" ]] || return 1
    fi
    rm -rf -- "$entry"
}

_ui_generation_cleanup_after_publish() {
    local root="$1" current="$2" previous="$3" entry name relative live
    local -a entries=()
    _ui_generation_find_entries entries "$root/generations" -mindepth 1 -maxdepth 1 || return 1
    for entry in "${entries[@]}"; do
        live="$(_ui_generation_current_target "$root")" || return 1
        [[ "$live" == "$current" ]] || return 1
        name="$(basename -- "$entry")"
        relative="generations/$name"
        [[ "$relative" == "$live" || "$relative" == "$previous" ]] && continue
        _ui_generation_remove_entry "$root" "$entry" "$current" || return 1
    done
    sync -f "$root/generations"
}

ui_generation_publish() {
    local root="$1" candidate="$2" base current name final target link expected_uid expected_gid
    UI_GENERATION_COMMIT_STATE="not-committed"
    UI_GENERATION_GC_WARNING=0
    _ui_generation_root_boundary_is_safe "$root" 0 || return 1
    _ui_generation_candidate_is_safe "$root" "$candidate" || return 1
    _ui_generation_plain_file_is_safe "$root" "$candidate/$UI_GENERATION_BASE_FILE" 600 || return 1
    IFS= read -r base < "$candidate/$UI_GENERATION_BASE_FILE" || return 1
    [[ "$base" == absent || "$base" == generations/* ]] || return 1
    current="$(_ui_generation_current_target "$root")" || return 1
    [[ "$current" == "$base" ]] || return 1
    _ui_generation_complete_is_safe "$root" "$candidate" 1 || return 1
    rm -f -- "$candidate/$UI_GENERATION_BASE_FILE" || return 1
    _ui_generation_normalize_candidate "$root" "$candidate" || return 1
    _ui_generation_complete_is_safe "$root" "$candidate" || return 1
    _ui_generation_sync_tree "$candidate" || return 1
    name="$(basename -- "$candidate")"
    name="${name#.candidate-}"
    _ui_generation_name_is_safe "$name" || return 1
    final="$root/generations/$name"
    [[ ! -e "$final" && ! -L "$final" ]] || return 1
    mv -T -- "$candidate" "$final" || return 1
    sync -f "$root/generations" || return 1
    _ui_generation_complete_is_safe "$root" "$final" || return 1
    target="generations/$name"
    link="$root/.current.new.$$.$RANDOM"
    [[ ! -e "$link" && ! -L "$link" ]] || return 1
    ln -s -- "$target" "$link" || return 1
    expected_uid="$(_ui_generation_expected_uid "$root")" || { rm -f -- "$link"; return 1; }
    expected_gid="$(_ui_generation_expected_gid "$root")" || { rm -f -- "$link"; return 1; }
    _ui_generation_set_owner "$root" "$link" 1 || { rm -f -- "$link"; return 1; }
    [[ "$(readlink -- "$link")" == "$target" ]] || { rm -f -- "$link"; return 1; }
    _ui_generation_before_current_commit "$root" "$link" "$base" "$target" \
        || { rm -f -- "$link"; return 1; }
    _ui_generation_root_boundary_is_safe "$root" 0 "$link" \
        || { rm -f -- "$link"; return 1; }
    current="$(_ui_generation_current_target "$root")" \
        || { rm -f -- "$link"; return 1; }
    [[ "$current" == "$base" ]] \
        || { rm -f -- "$link"; return 1; }
    mv -Tf -- "$link" "$root/current" || { rm -f -- "$link"; return 1; }
    UI_GENERATION_COMMIT_STATE="committed-undurable"
    sync -f "$root" || return 1
    UI_GENERATION_COMMIT_STATE="committed"
    [[ "$(_ui_generation_current_target "$root")" == "$target" ]] || return 1
    if ! _ui_generation_cleanup_after_publish "$root" "$target" "$base"; then
        UI_GENERATION_GC_WARNING=1
    fi
    _ui_generation_current_only_is_safe "$root"
}

ui_generation_current_path() {
    local root="${1:-$UI_GENERATION_ROOT}" target
    _ui_generation_root_boundary_is_safe "$root" 0 || return 1
    target="$(_ui_generation_current_target "$root")" || return 1
    [[ "$target" != absent ]] || return 1
    printf '%s\n' "$root/$target"
}

ui_generation_remove_root() {
    local root="${1:-$UI_GENERATION_ROOT}" entry parent
    local -a generation_entries=()
    [[ ! -e "$root" && ! -L "$root" ]] && return 0
    _ui_generation_parent_is_safe "$root" || return 1
    parent="$(dirname -- "$root")" || return 1
    _ui_generation_same_mount_boundary "$parent" "$root" || return 1
    _ui_generation_root_boundary_is_safe "$root" 1 "" 1 || return 1
    if [[ -d "$root/generations" && ! -L "$root/generations" ]]; then
        ui_generation_cleanup_orphan_current_links "$root" || return 1
    fi
    # Validate the complete tree before the first unlink. Every recursive
    # target below carries its own generation marker and is revalidated again
    # immediately before deletion.
    if [[ -e "$root/current" || -L "$root/current" ]]; then
        _ui_generation_current_target "$root" >/dev/null || return 1
        rm -f -- "$root/current" || return 1
    fi
    if [[ -d "$root/generations" && ! -L "$root/generations" ]]; then
        _ui_generation_find_entries generation_entries "$root/generations" -mindepth 1 -maxdepth 1 \
            || return 1
        for entry in "${generation_entries[@]}"; do
            _ui_generation_remove_entry "$root" "$entry" || return 1
        done
        rmdir -- "$root/generations" || return 1
    fi
    _ui_generation_marker_is_safe "$root" || return 1
    rm -f -- "$root/$UI_GENERATION_MARKER" || return 1
    rmdir -- "$root" || return 1
    sync -f "$parent"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        validate-image-source)
            [[ "$#" == 1 \
               && "${FIVEGPN_RUNTIME:-}" == container \
               && "${EUID:-$(id -u)}" == 10001 \
               && "$(id -g)" == 10001 ]] || exit 2
            _ui_generation_source_tree_is_safe "$UI_GENERATION_IMAGE_SOURCE"
            ;;
        preflight)
            [[ "$#" == 1 ]] || exit 2
            ui_generation_preflight "$UI_GENERATION_ROOT"
            ;;
        validate-current)
            [[ "$#" == 1 ]] || exit 2
            _ui_generation_current_only_is_safe "$UI_GENERATION_ROOT"
            ;;
        *)
            printf 'Usage: ui-generation.sh validate-image-source|preflight|validate-current\n' >&2
            exit 2
            ;;
    esac
fi
