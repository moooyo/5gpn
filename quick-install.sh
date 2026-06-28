#!/usr/bin/env bash
# 5gpn one-shot entrypoint.
#   curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# Fetches the repo, then runs install.sh with any args you pass through.
set -euo pipefail

REPO="${REPO:-https://github.com/moooyo/5gpn}"
BRANCH="${BRANCH:-main}"
SRC="${SRC:-/opt/5gpn-src}"

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

fetch() {
    # Prefer a shallow git clone; fall back to a release tarball if git is absent.
    if command -v git >/dev/null 2>&1; then
        info "Cloning ${REPO} (branch ${BRANCH})..."
        rm -rf "$SRC"
        git clone --depth=1 --branch "$BRANCH" "$REPO" "$SRC" && return 0
        red "git clone failed; trying tarball..."
    fi
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
        red "Need git, or curl/wget, to download. Install one and retry."; exit 1; }
    info "Downloading tarball..."
    local tgz="/tmp/5gpn-src.$$.tgz"
    local url="${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tgz"
    else
        wget -qO "$tgz" "$url"
    fi
    gzip -t "$tgz" 2>/dev/null || { red "Downloaded archive is not valid."; rm -f "$tgz"; exit 1; }
    rm -rf "$SRC"; mkdir -p "$SRC"
    tar -xzf "$tgz" --strip-components=1 -C "$SRC"
    rm -f "$tgz"
}

fetch

INSTALL="${SRC}/install.sh"
[[ -f "$INSTALL" ]] || { red "install.sh not found at $INSTALL"; exit 1; }
chmod +x "$INSTALL" 2>/dev/null || true

green "Source ready at ${SRC}. Launching installer..."
cd "${SRC}"
exec bash ./install.sh "$@"
