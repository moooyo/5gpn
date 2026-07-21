#!/usr/bin/env bash
# 5gpn one-shot entrypoint.
#   curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
#
# Resolve the selected official or beta release once, then obtain every
# installer input from that exact tag. We never fall forward to a branch or
# across channels, and a downloaded bundle is never used without its published
# digest.
set -euo pipefail

readonly RELEASE_REPO="https://github.com/moooyo/5gpn"
readonly LATEST_RELEASE_API="https://api.github.com/repos/moooyo/5gpn/releases/latest"
readonly RELEASES_API="https://api.github.com/repos/moooyo/5gpn/releases"
readonly SOURCE_MARKER=".5gpn-quick-install-owned"
readonly SOURCE_MARKER_VALUE="5gpn-quick-install-v1"
readonly WORK_MARKER=".5gpn-quick-install-work-owned"
readonly WORK_MARKER_VALUE="5gpn-quick-install-work-v1"
readonly BUNDLE_NAME="5gpn-installer.tar.gz"
readonly CHECKSUMS_NAME="checksums.txt"

_QI_SOURCE_DIR=""

# Gum-or-ANSI helpers. This entrypoint runs before install.sh bootstraps Gum, so
# Gum is merely detected here; failure or absence always has a plain fallback.
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
red()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else printf '\033[0;31m%s\033[0m\n' "$*" >&2; fi; }
green() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*";     else printf '\033[0;32m%s\033[0m\n' "$*"; fi; }
info()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*";     else printf '\033[0;34m%s\033[0m\n' "$*"; fi; }

dl() { # dl <url> <out> -- curl or wget, whichever exists
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        red "Need curl or wget to download."
        return 1
    fi
}

# Resolve a path even when its final component does not yet exist. Every source
# directory is stored and rechecked in canonical form before recursive cleanup.
canonical_path() {
    local p="$1" parent leaf cur suffix=""
    [[ -n "$p" && "$p" != *$'\n'* && "$p" != *$'\r'* ]] || return 1
    [[ "$p" == /* ]] || p="$PWD/$p"
    if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
        realpath -m -- "$p"
        return
    fi
    if command -v readlink >/dev/null 2>&1 && readlink -m / >/dev/null 2>&1; then
        readlink -m -- "$p"
        return
    fi
    [[ "$p" != *'/../'* && "$p" != */.. && "$p" != *'/./'* ]] || return 1
    cur="$p"
    while [[ ! -e "$cur" && "$cur" != / ]]; do
        leaf="$(basename -- "$cur")"
        suffix="/${leaf}${suffix}"
        cur="$(dirname -- "$cur")"
    done
    [[ -d "$cur" ]] || return 1
    parent="$(cd -P -- "$cur" && pwd)" || return 1
    printf '%s%s\n' "$parent" "$suffix"
}

safe_source_path() {
    local p="$1"
    [[ -n "$p" && "$p" == /* ]] || return 1
    case "$p" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|\
        /proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var)
            return 1 ;;
        /var/*)
            [[ "$p" == /var/tmp/* ]] || return 1 ;;
    esac
    return 0
}

marker_matches() { # marker_matches <path> <exact-value>
    local marker="$1" value="$2"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    printf '%s\n' "$value" | cmp -s - "$marker"
}

# Create a marker without following or overwriting a raced symlink. The hard
# link succeeds only while the destination name is still absent.
create_marker() { # create_marker <directory> <name> <value>
    local dir="$1" name="$2" value="$3" tmp
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    [[ ! -e "$dir/$name" && ! -L "$dir/$name" ]] || return 1
    tmp="$(mktemp "$dir/.5gpn-marker.XXXXXX")" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if ! printf '%s\n' "$value" > "$tmp" || ! ln -- "$tmp" "$dir/$name"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
    marker_matches "$dir/$name" "$value"
}

source_dir_is_owned() {
    local canonical
    [[ -n "$_QI_SOURCE_DIR" && -d "$_QI_SOURCE_DIR" && ! -L "$_QI_SOURCE_DIR" ]] || return 1
    safe_source_path "$_QI_SOURCE_DIR" || return 1
    canonical="$(canonical_path "$_QI_SOURCE_DIR")" || return 1
    [[ "$canonical" == "$_QI_SOURCE_DIR" ]] || return 1
    marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"
}

# The optional argument is an internal seam used by safety tests. Production
# always passes an empty value and therefore uses a private mktemp directory;
# SRC is deliberately not a public environment override.
prepare_source_dir() {
    local requested="${1:-}" canonical contents
    if [[ -z "$requested" ]]; then
        canonical="$(mktemp -d /tmp/5gpn-installer.XXXXXX)" \
            || { red "Could not allocate a temporary installer directory."; return 1; }
    else
        canonical="$(canonical_path "$requested")" \
            || { red "Invalid installer source path."; return 1; }
        safe_source_path "$canonical" \
            || { red "Refusing unsafe installer source directory: $canonical"; return 1; }
        if [[ -e "$canonical" && ! -d "$canonical" ]]; then
            red "Installer source exists but is not a directory: $canonical"
            return 1
        fi
        mkdir -p -- "$canonical"
    fi

    canonical="$(canonical_path "$canonical")" || return 1
    safe_source_path "$canonical" || return 1
    [[ -d "$canonical" && ! -L "$canonical" ]] || return 1
    _QI_SOURCE_DIR="$canonical"

    if [[ -e "$_QI_SOURCE_DIR/$SOURCE_MARKER" || -L "$_QI_SOURCE_DIR/$SOURCE_MARKER" ]]; then
        marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" \
            || { red "Refusing installer source with an invalid ownership marker: $_QI_SOURCE_DIR"; return 1; }
    else
        contents="$(find "$_QI_SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        [[ -z "$contents" ]] \
            || { red "Refusing to claim a non-empty installer source: $_QI_SOURCE_DIR"; return 1; }
        create_marker "$_QI_SOURCE_DIR" "$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" \
            || { red "Could not claim installer source: $_QI_SOURCE_DIR"; return 1; }
    fi
    source_dir_is_owned
}

clear_source_dir() {
    source_dir_is_owned \
        || { red "Refusing to clear unowned installer directory: ${_QI_SOURCE_DIR:-<empty>}"; return 1; }
    find "$_QI_SOURCE_DIR" -mindepth 1 -maxdepth 1 ! -name "$SOURCE_MARKER" -exec rm -rf -- {} +
    # Revalidate immediately after deletion so a replaced marker cannot be used
    # by a later archive or git publication step.
    source_dir_is_owned \
        || { red "Installer source ownership changed during cleanup."; return 1; }
}

make_work_dir() {
    local dir canonical temp_root
    dir="$(mktemp -d /tmp/5gpn-quick-work.XXXXXX)" || return 1
    canonical="$(canonical_path "$dir")" || return 1
    temp_root="$(canonical_path /tmp)" || return 1
    [[ "$canonical" == "$temp_root"/5gpn-quick-work.* && -d "$canonical" && ! -L "$canonical" ]] || return 1
    create_marker "$canonical" "$WORK_MARKER" "$WORK_MARKER_VALUE" || return 1
    printf '%s\n' "$canonical"
}

remove_work_dir() {
    local dir="$1" canonical temp_root
    canonical="$(canonical_path "$dir")" || return 1
    temp_root="$(canonical_path /tmp)" || return 1
    [[ "$canonical" == "$dir" && "$canonical" == "$temp_root"/5gpn-quick-work.* ]] || return 1
    marker_matches "$canonical/$WORK_MARKER" "$WORK_MARKER_VALUE" || return 1
    find "$canonical" -mindepth 1 -maxdepth 1 ! -name "$WORK_MARKER" -exec rm -rf -- {} +
    marker_matches "$canonical/$WORK_MARKER" "$WORK_MARKER_VALUE" || return 1
    rm -f -- "$canonical/$WORK_MARKER"
    rmdir -- "$canonical"
}

valid_stable_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}$ ]]
}

valid_beta_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}-beta\.([1-9][0-9]*)$ ]]
}

valid_release_tag_for_channel() {
    local channel="$1" tag="$2"
    case "$channel" in
        stable) valid_stable_release_tag "$tag" ;;
        beta)   valid_beta_release_tag "$tag" ;;
        *)      return 1 ;;
    esac
}

resolve_latest_tag() { # optional API URL is an internal test seam
    local api_url="${1:-$LATEST_RELEASE_API}" json tags tag
    json="$(mktemp /tmp/5gpn-release.json.XXXXXX)" || return 1
    if ! dl "$api_url" "$json"; then
        rm -f -- "$json"
        red "Could not resolve the latest 5gpn release."
        return 1
    fi
    tags="$(sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$json")"
    rm -f -- "$json"
    [[ -n "$tags" && "$tags" != *$'\n'* ]] || { red "Latest release response has no unique tag."; return 1; }
    tag="$tags"
    valid_stable_release_tag "$tag" \
        || { red "Latest official release returned an unsafe or non-official tag."; return 1; }
    printf '%s\n' "$tag"
}

release_json_tag() {
    sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$1"
}

beta_tags_from_release_list() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+"' "$1" 2>/dev/null \
        | sed -E 's/^.*"([^"]+)"$/\1/' || true
}

resolve_latest_beta_tag() { # optional list and exact-metadata URLs are internal test seams
    local list_url="${1:-${RELEASES_API}?per_page=100}"
    local metadata_url="${2:-}"
    local list_json metadata_json candidate="" tag metadata_tag

    list_json="$(mktemp /tmp/5gpn-beta-releases.json.XXXXXX)" || return 1
    if ! dl "$list_url" "$list_json"; then
        rm -f -- "$list_json"
        red "Could not list 5gpn prereleases."
        return 1
    fi
    while IFS= read -r tag; do
        if valid_beta_release_tag "$tag"; then
            candidate="$tag"
            break
        fi
    done < <(beta_tags_from_release_list "$list_json")
    rm -f -- "$list_json"
    [[ -n "$candidate" ]] \
        || { red "No published 5gpn beta release is available."; return 1; }

    metadata_url="${metadata_url:-${RELEASES_API}/tags/${candidate}}"
    metadata_json="$(mktemp /tmp/5gpn-beta-release.json.XXXXXX)" || return 1
    if ! dl "$metadata_url" "$metadata_json"; then
        rm -f -- "$metadata_json"
        red "Could not verify beta release ${candidate}."
        return 1
    fi
    metadata_tag="$(release_json_tag "$metadata_json")"
    if [[ "$metadata_tag" != "$candidate" ]] \
       || ! grep -Eq '"draft"[[:space:]]*:[[:space:]]*false' "$metadata_json" \
       || ! grep -Eq '"prerelease"[[:space:]]*:[[:space:]]*true' "$metadata_json"; then
        rm -f -- "$metadata_json"
        red "Latest beta candidate is not a published GitHub prerelease."
        return 1
    fi
    rm -f -- "$metadata_json"
    printf '%s\n' "$candidate"
}

resolve_release_tag() { # resolve_release_tag <stable|beta> [discovery-url] [metadata-url]
    local channel="$1"
    case "$channel" in
        stable) resolve_latest_tag "${2:-}" ;;
        beta)   resolve_latest_beta_tag "${2:-}" "${3:-}" ;;
        *)      red "Unknown 5gpn release channel: $channel"; return 1 ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        red "No SHA-256 utility is available."
        return 1
    fi
}

verify_bundle_digest() { # verify_bundle_digest <bundle> <checksums.txt>
    local bundle="$1" checksums="$2" matches expected actual
    matches="$(awk '$2 == "5gpn-installer.tar.gz" || $2 == "*5gpn-installer.tar.gz" { print $1 }' "$checksums")" \
        || return 1
    [[ -n "$matches" && "$matches" != *$'\n'* && "$matches" =~ ^[0-9A-Fa-f]{64}$ ]] \
        || { red "Release checksums contain no unique valid digest for $BUNDLE_NAME."; return 1; }
    expected="$(printf '%s' "$matches" | tr 'A-F' 'a-f')"
    actual="$(sha256_file "$bundle")" || return 1
    actual="$(printf '%s' "$actual" | tr 'A-F' 'a-f')"
    [[ "$actual" == "$expected" ]] \
        || { red "Installer bundle checksum mismatch; refusing to continue."; return 1; }
}

archive_is_safe() {
    local archive="$1" names verbose entry normalized line first
    declare -A seen=()
    names="$(tar -tzf "$archive" 2>/dev/null)" || { red "Bundle is not a valid archive."; return 1; }
    verbose="$(tar -tvzf "$archive" 2>/dev/null)" || return 1

    while IFS= read -r entry; do
        normalized="$entry"
        while [[ "$normalized" == ./* ]]; do normalized="${normalized#./}"; done
        normalized="${normalized%/}"
        [[ -z "$normalized" ]] && continue
        [[ "$normalized" != /* ]] || { red "Bundle contains an absolute path."; return 1; }
        [[ "$normalized" != *'\'* ]] || { red "Bundle contains a backslash path."; return 1; }
        case "/$normalized/" in
            */../*) red "Bundle contains a parent-directory path."; return 1 ;;
        esac
        [[ "$normalized" != "$SOURCE_MARKER" && "$normalized" != "$WORK_MARKER" ]] \
            || { red "Bundle attempts to replace an ownership marker."; return 1; }
        [[ -z "${seen[$normalized]+x}" ]] \
            || { red "Bundle contains a duplicate path."; return 1; }
        seen[$normalized]=1
    done <<< "$names"

    # Installer bundles contain only directories and ordinary files. Refusing
    # links also prevents a later member from escaping the staging directory.
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        first="${line:0:1}"
        case "$first" in
            -|d) ;;
            *) red "Bundle contains a link or special file; refusing to extract."; return 1 ;;
        esac
    done <<< "$verbose"
}

validate_stage() {
    local stage="$1"
    marker_matches "$stage/$WORK_MARKER" "$WORK_MARKER_VALUE" || return 1
    [[ ! -e "$stage/$SOURCE_MARKER" && ! -L "$stage/$SOURCE_MARKER" ]] || return 1
    [[ -f "$stage/install.sh" && ! -L "$stage/install.sh" ]] || return 1
    [[ -z "$(find "$stage" -path "$stage/.git" -prune -o -type l -print -quit 2>/dev/null)" ]] || return 1
    [[ -z "$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null)" ]] || return 1
    [[ -z "$(find "$stage" -mindepth 1 -type f -links +1 -print -quit 2>/dev/null)" ]] || return 1
}

validate_bundle_release_stamp() { # validate_bundle_release_stamp <stage> <channel> <expected-tag>
    local stage="$1" channel="$2" expected="$3" install assignment_count stamps stamp
    install="$stage/install.sh"
    [[ -f "$install" && ! -L "$install" ]] || return 1

    # The release workflow writes one exact, column-zero literal assignment.
    # Refuse absent, malformed, or repeated declarations without evaluating
    # any downloaded shell content.
    assignment_count="$(awk '/^DNS_VERSION_DEFAULT=/{ count++ } END { print count + 0 }' "$install")" \
        || return 1
    if [[ "$assignment_count" != 1 ]]; then
        red "Installer bundle has no unique DNS_VERSION_DEFAULT release stamp."
        return 1
    fi
    stamps="$(sed -n 's/^DNS_VERSION_DEFAULT="\([^"]*\)"$/\1/p' "$install")" || return 1
    if [[ -z "$stamps" || "$stamps" == *$'\n'* ]]; then
        red "Installer bundle has a malformed DNS_VERSION_DEFAULT release stamp."
        return 1
    fi
    stamp="$stamps"
    if ! valid_release_tag_for_channel "$channel" "$stamp"; then
        red "Installer bundle release stamp does not match the selected channel."
        return 1
    fi
    if [[ "$stamp" != "$expected" ]]; then
        red "Installer bundle release stamp does not match resolved tag ${expected}."
        return 1
    fi
}

publish_stage() {
    local stage="$1" entry base
    validate_stage "$stage" || { red "Staged installer content is unsafe or incomplete."; return 1; }
    clear_source_dir || return 1
    shopt -s dotglob nullglob
    for entry in "$stage"/*; do
        base="$(basename -- "$entry")"
        case "$base" in
            "$WORK_MARKER"|.git) continue ;;
        esac
        mv -- "$entry" "$_QI_SOURCE_DIR/" || { shopt -u dotglob nullglob; return 1; }
    done
    shopt -u dotglob nullglob
    source_dir_is_owned || return 1
    [[ -f "$_QI_SOURCE_DIR/install.sh" && ! -L "$_QI_SOURCE_DIR/install.sh" ]]
}

fetch_bundle() { # fetch_bundle <repo> <channel> <release-tag>; 10=asset absent, 20=hard failure
    local repo="$1" channel="$2" tag="$3" tgz checksums stage bundle_url checksums_url
    valid_release_tag_for_channel "$channel" "$tag" || return 20
    tgz="$(mktemp /tmp/5gpn-installer.tgz.XXXXXX)" || return 20
    checksums="$(mktemp /tmp/5gpn-checksums.txt.XXXXXX)" || { rm -f -- "$tgz"; return 20; }
    bundle_url="${repo}/releases/download/${tag}/${BUNDLE_NAME}"
    checksums_url="${repo}/releases/download/${tag}/${CHECKSUMS_NAME}"

    info "Downloading installer bundle for release ${tag}..."
    if ! dl "$bundle_url" "$tgz"; then
        rm -f -- "$tgz" "$checksums"
        return 10
    fi
    if ! dl "$checksums_url" "$checksums"; then
        red "Could not download ${CHECKSUMS_NAME}; refusing an unverified bundle."
        rm -f -- "$tgz" "$checksums"
        return 20
    fi
    # This detects release corruption and accidental asset skew. The digest is
    # same-origin release metadata, not an independent cryptographic signature.
    if ! verify_bundle_digest "$tgz" "$checksums"; then
        rm -f -- "$tgz" "$checksums"
        return 20
    fi
    archive_is_safe "$tgz" || { rm -f -- "$tgz" "$checksums"; return 20; }
    stage="$(make_work_dir)" || { rm -f -- "$tgz" "$checksums"; return 20; }
    if ! tar --no-same-owner --no-same-permissions --delay-directory-restore \
        -xzf "$tgz" -C "$stage"; then
        red "Could not safely extract the installer bundle."
        rm -f -- "$tgz" "$checksums"
        remove_work_dir "$stage" || true
        return 20
    fi
    rm -f -- "$tgz" "$checksums"
    if ! validate_bundle_release_stamp "$stage" "$channel" "$tag"; then
        remove_work_dir "$stage" || true
        return 20
    fi
    if ! publish_stage "$stage"; then
        remove_work_dir "$stage" || true
        return 20
    fi
    remove_work_dir "$stage" || { red "Could not clean the installer staging directory."; return 20; }
}

usage() {
    cat <<'EOF'
5gpn quick installer
Usage: quick-install.sh [--beta] [installer-command]

  (no channel option)  Download the latest official release.
  --beta              Download the latest published beta prerelease.

Installer command:
  upgrade-reset-mihomo  Explicit TTY-confirmed upgrade that backs up and replaces
                        the complete operator-owned mihomo config.

The selected release is pinned to one exact tag. A missing beta never falls
back to the official channel.
EOF
}

main() {
    local release_tag status install channel=stable
    local -a install_args
    if [[ "${1:-}" == --beta ]]; then
        channel=beta
        shift
    fi
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
    esac
    if [[ "${1:-}" == --beta ]]; then
        red "--beta must be specified exactly once as the first argument."
        return 2
    fi
    install_args=("$@")
    [[ "$channel" == stable ]] || install_args=(--beta "${install_args[@]}")

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        red "Please run as root (e.g. pipe into 'sudo bash')."
        return 1
    fi

    prepare_source_dir "" || return 1
    release_tag="$(resolve_release_tag "$channel")" || return 1

    if fetch_bundle "$RELEASE_REPO" "$channel" "$release_tag"; then
        green "Verified installer bundle ready at ${_QI_SOURCE_DIR}."
    else
        status=$?
        if [[ "$status" != 10 ]]; then
            red "Release installer verification failed; aborting."
            return 1
        fi
        red "The verified installer bundle for release ${release_tag} is unavailable; refusing an unsigned source fallback."
        return 1
    fi

    install="${_QI_SOURCE_DIR}/install.sh"
    [[ -f "$install" && ! -L "$install" ]] \
        || { red "install.sh not found at $install"; return 1; }
    chmod +x "$install" 2>/dev/null || true
    green "Source ready at ${_QI_SOURCE_DIR}. Launching installer..."
    cd "$_QI_SOURCE_DIR"
    exec bash ./install.sh "${install_args[@]}"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
