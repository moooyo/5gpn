#!/usr/bin/env bash
# Manual refresh trigger for 5gpn-dns rule/chnroute caches.
#
# Phase 2: fetching lives in-process in 5gpn-dns (the subscription manager
# reads /etc/5gpn/subscriptions.json, fetches each remote list on its own
# interval, and writes caches to <rules-dir>/<category>/<name>.txt). This
# script no longer downloads anything itself — it just asks the running
# resolver to reload (SIGHUP re-reads all rule caches from disk), for
# operators who want an on-demand refresh between ticks (e.g. after editing
# a manual rules/*.txt file).
#
# DRY_RUN=1 skips the reload (useful for testing the gum-or-echo preamble).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."

# --- Gum-or-echo status helpers (gum when on PATH + interactive; else plain echo).
# Installing gum is install.sh's job (install_gum); here we only detect + use it. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

RULES_DIR="${RULES_DIR:-/etc/5gpn/rules}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$RULES_DIR"

if [ "$DRY_RUN" != "1" ]; then
    if systemctl reload 5gpn-dns 2>/dev/null; then
        ok "5gpn-dns reloaded (rule caches re-read from disk)."
    else
        warn "systemctl reload 5gpn-dns failed (not running / not installed?); caches unchanged."
    fi
else
    info "DRY_RUN=1: skipping reload."
fi

ok "lists refresh trigger done (rules_dir=$RULES_DIR, dry_run=$DRY_RUN)"
