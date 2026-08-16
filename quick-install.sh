#!/usr/bin/env bash
# 5gpn one-shot entrypoint.
#   curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
#
# Resolve the selected official or beta release once, then obtain every
# installer input from that exact tag. We never fall forward to a branch or
# across channels, and a downloaded bundle is never used without its published
# digest.
set -euo pipefail
# Descriptor variables must remain open across `exec bash ./install.sh`; an
# inherited varredir_close shell option would otherwise defeat the lease.
shopt -u varredir_close 2>/dev/null || true

readonly RELEASE_REPO="https://github.com/moooyo/5gpn"
readonly LATEST_RELEASE_API="https://api.github.com/repos/moooyo/5gpn/releases/latest"
readonly RELEASES_API="https://api.github.com/repos/moooyo/5gpn/releases"
readonly SOURCE_MARKER=".5gpn-quick-install-owned"
readonly SOURCE_MARKER_VALUE="5gpn-quick-install-v1"
readonly SOURCE_LEASE=".5gpn-quick-install-lease"
readonly SOURCE_LEASE_VALUE="5gpn-quick-install-lease-v1"
readonly WORK_MARKER=".5gpn-quick-install-work-owned"
readonly WORK_MARKER_VALUE="5gpn-quick-install-work-v1"
readonly BUNDLE_NAME="5gpn-installer.tar.gz"
readonly CHECKSUMS_NAME="checksums.txt"
readonly MIN_WORKER_KERNEL_MAJOR=5
readonly MIN_WORKER_KERNEL_MINOR=7
readonly MIN_WORKER_SYSTEMD_VERSION=257

_QI_SOURCE_DIR=""
_QI_SOURCE_LEASE_FD=""

# Gum-or-ANSI helpers. This entrypoint runs before install.sh bootstraps Gum, so
# Gum is merely detected here; failure or absence always has a plain fallback.
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
red()   { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level error -- "$*" >&2; else printf '\033[0;31m%s\033[0m\n' "$*" >&2; fi; }
green() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "$*";     else printf '\033[0;32m%s\033[0m\n' "$*"; fi; }
info()  { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "$*";     else printf '\033[0;34m%s\033[0m\n' "$*"; fi; }

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

# The lease and mount boundary protects source cleanup before the verified
# installer is available, so these util-linux tools cannot be installed by that
# installer retroactively. Fail before allocating or claiming any source path;
# this bootstrap never mutates the host package set itself.
require_quick_prerequisites() {
    local cmd
    local -a missing=()
    for cmd in flock findmnt; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    red "Quick install requires flock and findmnt before any installer files are created (missing: ${missing[*]})."
    red "Install util-linux first: apt-get install -y util-linux, dnf install -y util-linux, or yum install -y util-linux."
    return 1
}

quick_kernel_release_supported() {
    local release="$1" major minor
    [[ "$release" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    (( 10#$major > MIN_WORKER_KERNEL_MAJOR \
       || (10#$major == MIN_WORKER_KERNEL_MAJOR \
           && 10#$minor >= MIN_WORKER_KERNEL_MINOR) ))
}

quick_systemd_version_supported() {
    local version="$1" major
    [[ "$version" =~ ^([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    (( 10#$major >= MIN_WORKER_SYSTEMD_VERSION ))
}

quick_host_uses_pure_cgroup_v2() {
    local line left right fstype mountpoint
    local v2_root_count=0 v1_count=0
    [[ -r /proc/self/mountinfo && -r /sys/fs/cgroup/cgroup.controllers ]] \
        || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *' - '* ]] || continue
        left="${line%% - *}"
        right="${line#* - }"
        fstype="${right%% *}"
        read -r _ _ _ _ mountpoint _ <<< "$left"
        if [[ "$fstype" == cgroup2 && "$mountpoint" == /sys/fs/cgroup ]]; then
            v2_root_count=$((v2_root_count + 1))
        elif [[ "$fstype" == cgroup ]]; then
            v1_count=$((v1_count + 1))
        fi
    done < /proc/self/mountinfo
    (( v2_root_count == 1 && v1_count == 0 ))
}

quick_host_has_worker_controllers() {
    local controller have_memory=0 have_pids=0
    local -a controllers=()
    [[ -r /sys/fs/cgroup/cgroup.controllers ]] || return 1
    read -r -a controllers < /sys/fs/cgroup/cgroup.controllers || return 1
    for controller in "${controllers[@]}"; do
        case "$controller" in
            memory) have_memory=1 ;;
            pids) have_pids=1 ;;
        esac
    done
    (( have_memory == 1 && have_pids == 1 ))
}

# Reject an unsupported worker-isolation host before allocating the verified
# installer source directory. install.sh repeats this authoritative gate and
# additionally verifies the candidate unit and installed drop-in boundary.
require_worker_isolation_prerequisites() {
    local kernel_name kernel_release machine systemd_version
    kernel_name="$(uname -s 2>/dev/null || true)"
    kernel_release="$(uname -r 2>/dev/null || true)"
    machine="$(uname -m 2>/dev/null || true)"
    [[ "$kernel_name" == Linux && "$machine" == x86_64 ]] \
        || { red "5gpn requires a Linux amd64 gateway; found '${kernel_name:-unknown}/${machine:-unknown}'."; return 1; }
    quick_kernel_release_supported "$kernel_release" \
        || { red "Linux kernel ${MIN_WORKER_KERNEL_MAJOR}.${MIN_WORKER_KERNEL_MINOR} or newer is required for extension worker isolation; found '${kernel_release:-unknown}'."; return 1; }
    quick_host_uses_pure_cgroup_v2 \
        || { red "A pure cgroup v2 hierarchy at /sys/fs/cgroup is required before quick install."; return 1; }
    quick_host_has_worker_controllers \
        || { red "The cgroup-v2 memory and pids controllers must both be available before quick install."; return 1; }
    command -v systemctl >/dev/null 2>&1 \
        && command -v systemd-analyze >/dev/null 2>&1 \
        || { red "systemctl and systemd-analyze are required before quick install."; return 1; }
    systemd_version="$(systemctl show --property=Version --value 2>/dev/null || true)"
    quick_systemd_version_supported "$systemd_version" \
        || { red "A running systemd ${MIN_WORKER_SYSTEMD_VERSION} or newer manager is required; found '${systemd_version:-unknown}'."; return 1; }
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

quick_uid() { stat -c %u -- "$1" 2>/dev/null; }
quick_mode() { stat -c %a -- "$1" 2>/dev/null; }
quick_nlink() { stat -c %h -- "$1" 2>/dev/null; }

private_source_dir_safe() {
    local dir="$1" expected_uid="${EUID:-$(id -u)}"
    [[ -d "$dir" && ! -L "$dir" ]] \
        && [[ "$(quick_uid "$dir")" == "$expected_uid" ]] \
        && [[ "$(quick_mode "$dir")" == 700 ]]
}

private_control_file_safe() {
    local file="$1" expected_uid="${EUID:-$(id -u)}"
    [[ -f "$file" && ! -L "$file" ]] \
        && [[ "$(quick_uid "$file")" == "$expected_uid" ]] \
        && [[ "$(quick_mode "$file")" == 600 ]] \
        && [[ "$(quick_nlink "$file")" == 1 ]]
}

source_dir_has_no_nested_mounts() {
    local dir="$1" target output
    command -v findmnt >/dev/null 2>&1 || return 1
    output="$(findmnt -R -r -n -o TARGET --target "$dir" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in
            "$dir"|"$dir"/*) return 1 ;;
        esac
    done <<< "$output"
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
    [[ -n "$_QI_SOURCE_DIR" ]] && private_source_dir_safe "$_QI_SOURCE_DIR" || return 1
    safe_source_path "$_QI_SOURCE_DIR" || return 1
    canonical="$(canonical_path "$_QI_SOURCE_DIR")" || return 1
    [[ "$canonical" == "$_QI_SOURCE_DIR" ]] || return 1
    private_control_file_safe "$_QI_SOURCE_DIR/$SOURCE_MARKER" \
        && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"
}

source_lease_is_safe() {
    local lease="${1:-${_QI_SOURCE_DIR:+$_QI_SOURCE_DIR/$SOURCE_LEASE}}"
    [[ -n "$lease" ]] && private_control_file_safe "$lease" \
        && marker_matches "$lease" "$SOURCE_LEASE_VALUE"
}

release_source_lease() {
    [[ -n "${_QI_SOURCE_LEASE_FD:-}" ]] || return 0
    exec {_QI_SOURCE_LEASE_FD}>&-
    _QI_SOURCE_LEASE_FD=""
}

# Hold one descriptor across `exec bash ./install.sh`. flock locks belong to the
# open file description, so a later quick installer cannot reclaim this source
# tree while the installed script is still reading templates and helper files
# from it. Bash preserves the descriptor across exec; no EXIT trap owns it.
acquire_source_lease() {
    local lease="$_QI_SOURCE_DIR/$SOURCE_LEASE"
    command -v flock >/dev/null 2>&1 \
        || { red "flock is required to protect the installer source lease."; return 1; }
    private_source_dir_safe "$_QI_SOURCE_DIR" || return 1
    if [[ -e "$lease" || -L "$lease" ]]; then
        source_lease_is_safe "$lease" \
            || { red "Refusing installer source with an invalid lease file: $_QI_SOURCE_DIR"; return 1; }
    else
        # A directory with the public ownership marker is already sweepable.
        # Never publish a lease into that state before holding its lock: another
        # quick run could acquire the new inode in the gap and remove this tree.
        [[ ! -e "$_QI_SOURCE_DIR/$SOURCE_MARKER" && ! -L "$_QI_SOURCE_DIR/$SOURCE_MARKER" ]] \
            || { red "Refusing a claimed installer source with no lease: $_QI_SOURCE_DIR"; return 1; }
        create_marker "$_QI_SOURCE_DIR" "$SOURCE_LEASE" "$SOURCE_LEASE_VALUE" \
            || { red "Could not create installer source lease: $_QI_SOURCE_DIR"; return 1; }
    fi
    release_source_lease
    exec {_QI_SOURCE_LEASE_FD}<>"$lease" || return 1
    if ! flock -n "$_QI_SOURCE_LEASE_FD"; then
        exec {_QI_SOURCE_LEASE_FD}>&-
        _QI_SOURCE_LEASE_FD=""
        red "Installer source is already active: $_QI_SOURCE_DIR"
        return 1
    fi
    source_lease_is_safe "$lease"
}

# sweep_stale_source_dirs — remove only private directories whose lease proves
# no quick installer or exec'd install.sh is still using them.
#
# This entrypoint `exec`s install.sh, so the lease descriptor intentionally
# survives. A later run may remove a directory only after obtaining that exact
# lease non-blockingly. Lease-less directories from older installers are kept:
# absence is not proof that an old process stopped using one.
#
# Only directories carrying this entrypoint's own ownership marker are touched:
# /tmp is world-writable, and a name match alone would let anyone hand root an
# rm -rf target.
sweep_stale_source_dirs() {
    local keep="$1" dir canonical lease candidate_fd
    for dir in /tmp/5gpn-installer.*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        [[ "$dir" != "$keep" ]] || continue
        safe_source_path "$dir" && private_source_dir_safe "$dir" || continue
        canonical="$(canonical_path "$dir" 2>/dev/null)" || continue
        [[ "$canonical" == "$dir" ]] || continue
        private_control_file_safe "$dir/$SOURCE_MARKER" \
            && marker_matches "$dir/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" || continue
        source_dir_has_no_nested_mounts "$dir" || continue
        lease="$dir/$SOURCE_LEASE"
        source_lease_is_safe "$lease" || continue
        exec {candidate_fd}<>"$lease" 2>/dev/null || continue
        if ! flock -n "$candidate_fd" 2>/dev/null; then
            exec {candidate_fd}>&-
            continue
        fi
        private_source_dir_safe "$dir" \
            && private_control_file_safe "$dir/$SOURCE_MARKER" \
            && marker_matches "$dir/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" \
            && source_lease_is_safe "$lease" \
            && source_dir_has_no_nested_mounts "$dir" \
            || { exec {candidate_fd}>&-; continue; }
        rm -rf -- "$dir" 2>/dev/null || true
        exec {candidate_fd}>&-
    done
}

# The optional argument is an internal seam used by safety tests. Production
# always passes an empty value and therefore uses a private mktemp directory;
# SRC is deliberately not a public environment override.
prepare_source_dir() {
    local requested="${1:-}" canonical contents allocated=0
    if [[ -z "$requested" ]]; then
        canonical="$(mktemp -d /tmp/5gpn-installer.XXXXXX)" \
            || { red "Could not allocate a temporary installer directory."; return 1; }
        allocated=1
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
        private_source_dir_safe "$_QI_SOURCE_DIR" \
            && private_control_file_safe "$_QI_SOURCE_DIR/$SOURCE_MARKER" \
            && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" \
            || { red "Refusing installer source with an invalid ownership marker: $_QI_SOURCE_DIR"; return 1; }
        acquire_source_lease || return 1
    else
        contents="$(find "$_QI_SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
        [[ -z "$contents" ]] \
            || { red "Refusing to claim a non-empty installer source: $_QI_SOURCE_DIR"; return 1; }
        chmod 0700 "$_QI_SOURCE_DIR" \
            || { red "Could not make installer source private: $_QI_SOURCE_DIR"; return 1; }
        private_source_dir_safe "$_QI_SOURCE_DIR" \
            || { red "Installer source metadata is unsafe: $_QI_SOURCE_DIR"; return 1; }
        # Hold the lease before publishing SOURCE_MARKER. The sweep requires
        # both names, so no other run can observe a sweepable-but-unlocked tree.
        acquire_source_lease || return 1
        create_marker "$_QI_SOURCE_DIR" "$SOURCE_MARKER" "$SOURCE_MARKER_VALUE" \
            || { red "Could not claim installer source: $_QI_SOURCE_DIR"; return 1; }
    fi
    source_dir_is_owned || return 1
    if [[ "$allocated" == 1 ]]; then
        sweep_stale_source_dirs "$canonical"
    fi
}

clear_source_dir() {
    source_dir_is_owned \
        || { red "Refusing to clear unowned installer directory: ${_QI_SOURCE_DIR:-<empty>}"; return 1; }
    source_dir_has_no_nested_mounts "$_QI_SOURCE_DIR" \
        || { red "Refusing installer source containing a nested mount: $_QI_SOURCE_DIR"; return 1; }
    find "$_QI_SOURCE_DIR" -mindepth 1 -maxdepth 1 \
        ! -name "$SOURCE_MARKER" ! -name "$SOURCE_LEASE" -exec rm -rf -- {} +
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

stable_tags_from_release_list() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
        | sed -E 's/^.*"([^"]+)"$/\1/' || true
}

latest_stable_tag_from_list() {
    stable_tags_from_release_list "$1" \
        | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)$/\1 \2 \3 &/' \
        | sort -k1,1n -k2,2n -k3,3n \
        | tail -n 1 \
        | awk '{print $4}'
}

decimal_component_is_greater() {
    local left="$1" right="$2" LC_ALL=C
    ((${#left} > ${#right})) && return 0
    ((${#left} < ${#right})) && return 1
    [[ "$left" > "$right" ]]
}

beta_base_is_newer_than_stable() {
    local beta="$1" stable="$2" beta_base
    local b_major b_minor b_patch s_major s_minor s_patch
    valid_beta_release_tag "$beta" && valid_stable_release_tag "$stable" || return 1
    beta_base="${beta%%-beta.*}"
    IFS=. read -r b_major b_minor b_patch <<< "$beta_base"
    IFS=. read -r s_major s_minor s_patch <<< "$stable"
    decimal_component_is_greater "$b_major" "$s_major" && return 0
    [[ "$b_major" == "$s_major" ]] || return 1
    decimal_component_is_greater "$b_minor" "$s_minor" && return 0
    [[ "$b_minor" == "$s_minor" ]] || return 1
    decimal_component_is_greater "$b_patch" "$s_patch"
}

# The highest beta tag, ordered numerically on all four components.
#
# Not "the first one the API listed". GitHub does not return releases newest
# first -- the order is lexicographic on the tag, so 0.0.62-beta.9 sorts above
# 0.0.62-beta.11 exactly the way "9" sorts above "11" as text. Taking the first
# match therefore worked for nine betas and then silently pinned every --beta
# install to beta.9 forever, downloading a bundle older than the one the
# operator asked for and reporting no error at all.
latest_beta_tag_from_list() {
    beta_tags_from_release_list "$1" \
        | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)-beta\.([0-9]+)$/\1 \2 \3 \4 &/' \
        | sort -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -n 1 \
        | awk '{print $5}'
}

resolve_latest_beta_tag() { # optional list and exact-metadata URLs are internal test seams
    local list_url="${1:-${RELEASES_API}?per_page=100}"
    local metadata_url="${2:-}"
    local list_json metadata_json candidate="" latest_stable="" metadata_tag

    list_json="$(mktemp /tmp/5gpn-beta-releases.json.XXXXXX)" || return 1
    if ! dl "$list_url" "$list_json"; then
        rm -f -- "$list_json"
        red "Could not list 5gpn prereleases."
        return 1
    fi
    candidate="$(latest_beta_tag_from_list "$list_json")"
    latest_stable="$(latest_stable_tag_from_list "$list_json")"
    rm -f -- "$list_json"
    [[ -n "$candidate" ]] \
        || { red "No published 5gpn beta release is available."; return 1; }
    [[ -n "$latest_stable" ]] \
        || { red "Could not establish the latest official release before selecting beta."; return 1; }
    beta_base_is_newer_than_stable "$candidate" "$latest_stable" \
        || { red "Latest beta ${candidate} is not newer than official ${latest_stable}; refusing a channel downgrade."; return 1; }

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
        [[ "$normalized" != "$SOURCE_MARKER" && "$normalized" != "$SOURCE_LEASE" \
           && "$normalized" != "$WORK_MARKER" ]] \
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
    assignment_count="$(awk '/^RELEASE_TAG=/{ count++ } END { print count + 0 }' "$install")" \
        || return 1
    if [[ "$assignment_count" != 1 ]]; then
        red "Installer bundle has no unique RELEASE_TAG release stamp."
        return 1
    fi
    stamps="$(sed -n 's/^RELEASE_TAG="\([^"]*\)"$/\1/p' "$install")" || return 1
    if [[ -z "$stamps" || "$stamps" == *$'\n'* ]]; then
        red "Installer bundle has a malformed RELEASE_TAG release stamp."
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
    source_dir_is_owned && source_lease_is_safe \
        || { red "Installer source lease is unavailable before download."; return 20; }
    tgz="$(mktemp "$_QI_SOURCE_DIR/.bundle.tgz.XXXXXX")" || return 20
    checksums="$(mktemp "$_QI_SOURCE_DIR/.checksums.txt.XXXXXX")" \
        || { rm -f -- "$tgz"; return 20; }
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
Usage: quick-install.sh [--beta] [configure]

  (no channel option)  Download the latest official release.
  --beta              Download the latest beta only when its base version is
                      newer than latest official; never downgrade to an older line.

  configure            Open the selected release's installation TUI.

The selected release is pinned to one exact tag. A missing or older beta never
falls back to the official channel and never downgrades it.

Host baseline: Linux amd64, kernel 5.7+, systemd 257+, and pure cgroup v2 with
the memory and pids controllers. Unsupported hosts fail before source allocation.
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
    if (( $# > 1 )); then
        red "The quick installer accepts at most one command."
        return 2
    fi
    case "${1:-}" in
        ''|configure) ;;
        *) red "Unsupported quick-installer command: ${1}"; return 2 ;;
    esac
    install_args=("$@")
    [[ "$channel" == stable ]] || install_args=(--beta "${install_args[@]}")

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        red "Please run as root (e.g. pipe into 'sudo bash')."
        return 1
    fi

    require_quick_prerequisites || return 1
    require_worker_isolation_prerequisites || return 1
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
