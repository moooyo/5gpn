#!/usr/bin/env bash
# 5gpn one-shot entrypoint.
#   curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
#
# Downloads the RELEASE installer bundle — install.sh plus the config templates
# and scripts it needs — all version-matched to the 5gpn-dns binary and web SPA
# in the SAME release, then runs install.sh. Nothing is COMPILED on the box:
# install.sh only downloads prebuilt release artifacts (binary + SPA + xray/gum).
#
# Why a release bundle instead of a git checkout: the old path cloned `main` for
# the config templates while install.sh downloaded a PINNED release binary — so a
# main that had drifted ahead of the release shipped config newer than the binary
# (the skew that once broke the :443 webui). Fetching install.sh + configs from
# the same release as the binary eliminates that class of bug.
#
# Pin a specific release with DNS_VERSION=dns-vX.Y.Z; otherwise the newest
# published release is used. Falls back to a version-matched git checkout ONLY
# if the bundle cannot be fetched (e.g. an older release cut before the bundle
# existed). A pinned request never silently falls forward to main.
set -euo pipefail

REPO="${REPO:-https://github.com/moooyo/5gpn}"
SRC_REQUESTED="${SRC:-}"
SRC=""
SRC_MARKER=".5gpn-quick-install-owned"

# Gum-or-ANSI helpers. NOTE: this entrypoint runs BEFORE install.sh's install_gum()
# bootstrap, so gum is normally absent here and these fall back to plain ANSI. They
# light up only on a re-run where gum is already on PATH — we deliberately do NOT
# install gum here (that is the excluded "install gum dependency" step).
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
red()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else printf '\033[0;31m%s\033[0m\n' "$*" >&2; fi; }
green() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*";     else printf '\033[0;32m%s\033[0m\n' "$*"; fi; }
info()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*";     else printf '\033[0;34m%s\033[0m\n' "$*"; fi; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    red "Please run as root (e.g. pipe into 'sudo bash')."
    exit 1
fi

dl() { # dl <url> <out> — curl or wget, whichever exists
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    else red "Need curl or wget to download."; return 1; fi
}

# Resolve a path even when its final component does not exist. quick-install
# runs as root, so an unchecked `rm -rf "$SRC"` turns a typo such as SRC=/etc
# into a host-destroying operation. Every directory we clear must be both a
# non-system path and explicitly owned by this script via SRC_MARKER.
canonical_path() {
    local p="$1" parent leaf cur suffix=""
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
        leaf="$(basename -- "$cur")"; suffix="/${leaf}${suffix}"
        cur="$(dirname -- "$cur")"
    done
    [[ -d "$cur" ]] || return 1
    parent="$(cd -P -- "$cur" && pwd)" || return 1
    printf '%s%s\n' "$parent" "$suffix"
}

prepare_source_dir() {
    if [[ -z "$SRC_REQUESTED" ]]; then
        SRC="$(mktemp -d /tmp/5gpn-installer.XXXXXX)" \
            || { red "Could not allocate a temporary installer directory."; return 1; }
    else
        [[ "$SRC_REQUESTED" != *$'\n'* && "$SRC_REQUESTED" != *$'\r'* ]] \
            || { red "SRC contains a newline and is unsafe."; return 1; }
        SRC="$(canonical_path "$SRC_REQUESTED")" || return 1
        case "$SRC" in
            /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
                red "Refusing unsafe SRC directory: $SRC"; return 1 ;;
        esac
        if [[ -e "$SRC" && ! -d "$SRC" ]]; then
            red "SRC exists but is not a directory: $SRC"; return 1
        fi
        if [[ -d "$SRC" && ! -f "$SRC/$SRC_MARKER" ]] \
           && [[ -n "$(find "$SRC" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            red "Refusing to clear non-empty SRC without $SRC_MARKER: $SRC"
            return 1
        fi
        mkdir -p -- "$SRC"
    fi
    printf '%s\n' '5gpn-quick-install-v1' > "$SRC/$SRC_MARKER"
}

clear_source_dir() {
    [[ -d "$SRC" && -f "$SRC/$SRC_MARKER" ]] \
        && [[ "$(cat "$SRC/$SRC_MARKER" 2>/dev/null || true)" == '5gpn-quick-install-v1' ]] \
        || { red "Refusing to clear unowned installer directory: ${SRC:-<empty>}"; return 1; }
    find "$SRC" -mindepth 1 -maxdepth 1 ! -name "$SRC_MARKER" -exec rm -rf -- {} +
}

prepare_source_dir || exit 1

# The release path. A pinned DNS_VERSION -> that tag's asset; otherwise GitHub's
# /releases/latest/download/<asset> shortcut, which always resolves to the newest
# release. The bundle's install.sh is self-stamped to its own release (its
# DNS_VERSION_DEFAULT is set at package time), so the binary + SPA it downloads
# later always match these config templates.
if [[ -n "${DNS_VERSION:-}" ]]; then
    BUNDLE_URL="${REPO}/releases/download/${DNS_VERSION}/5gpn-installer.tar.gz"
    export DNS_VERSION
else
    BUNDLE_URL="${REPO}/releases/latest/download/5gpn-installer.tar.gz"
fi

fetch_bundle() {
    local tgz
    tgz="$(mktemp /tmp/5gpn-installer.XXXXXX.tgz)" \
        || { red "Could not allocate a temporary bundle file."; return 1; }
    info "Downloading release installer bundle..."
    dl "$BUNDLE_URL" "$tgz" || { rm -f "$tgz"; return 1; }
    gzip -t "$tgz" 2>/dev/null || { red "Bundle is not a valid archive."; rm -f "$tgz"; return 1; }
    clear_source_dir || { rm -f "$tgz"; return 1; }
    tar -xzf "$tgz" -C "$SRC" || { rm -f "$tgz"; return 1; }
    rm -f "$tgz"
    # A release archive must not be able to transfer ownership of some other
    # path merely by supplying its own marker contents.
    printf '%s\n' '5gpn-quick-install-v1' > "$SRC/$SRC_MARKER"
    [[ -f "$SRC/install.sh" ]]
}

fetch_git() {
    command -v git >/dev/null 2>&1 || { red "git unavailable for the fallback checkout."; return 1; }
    clear_source_dir || return 1
    if [[ -n "${DNS_VERSION:-}" ]]; then
        info "Falling back to a shallow git checkout of pinned tag ${DNS_VERSION}..."
        git -C "$SRC" init -q
        git -C "$SRC" remote add origin "$REPO"
        git -C "$SRC" fetch -q --depth=1 origin "refs/tags/${DNS_VERSION}:refs/tags/${DNS_VERSION}" \
            || { red "Pinned tag ${DNS_VERSION} is unavailable; refusing to use main."; return 1; }
        git -C "$SRC" checkout -q --detach "refs/tags/${DNS_VERSION}"
    else
        info "Falling back to a shallow git checkout of main (no version was pinned)..."
        git -C "$SRC" init -q
        git -C "$SRC" remote add origin "$REPO"
        git -C "$SRC" fetch -q --depth=1 origin main
        git -C "$SRC" checkout -q --detach FETCH_HEAD
    fi
    printf '%s\n' '5gpn-quick-install-v1' > "$SRC/$SRC_MARKER"
    [[ -f "$SRC/install.sh" ]]
}

if fetch_bundle; then
    green "Installer bundle ready at ${SRC}."
else
    red "Release installer bundle unavailable; using a git checkout instead."
    fetch_git || { red "Could not obtain the installer."; exit 1; }
fi

INSTALL="${SRC}/install.sh"
[[ -f "$INSTALL" ]] || { red "install.sh not found at $INSTALL"; exit 1; }
chmod +x "$INSTALL" 2>/dev/null || true

green "Source ready at ${SRC}. Launching installer..."
cd "${SRC}"
exec bash ./install.sh "$@"
