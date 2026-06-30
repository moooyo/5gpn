#!/usr/bin/env bash
# Refresh china_ip_list for 5gpn-dns split-horizon routing, then hot-reload.
# DRY_RUN=1 skips download (uses existing china file) and skips reload.
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
# Spinner only wraps the opaque download (its stdout is not operator-facing).
gum_spin() { local t="$1"; shift; if [ "$_HAVE_GUM" = 1 ] && [ -t 1 ]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }

RULES_DIR="${RULES_DIR:-/etc/5gpn/rules}"
CHINA_IP_URL="${CHINA_IP_URL:-https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt}"
MIN_CN_SIZE="${MIN_CN_SIZE:-1000}"    # min lines in china_ip_list; keep old if smaller
DRY_RUN="${DRY_RUN:-0}"

china="$RULES_DIR/china_ip_list.txt"
mkdir -p "$RULES_DIR"

if [ "$DRY_RUN" != "1" ]; then
    tmp="$china.tmp"
    if gum_spin "下载 china_ip_list…" wget -qO "$tmp" "$CHINA_IP_URL"; then
        n=$(grep -c . "$tmp" 2>/dev/null || echo 0)
        if [ "$n" -ge "$MIN_CN_SIZE" ]; then
            mv "$tmp" "$china"
        else
            warn "china_ip_list too small ($n < $MIN_CN_SIZE lines); keeping existing $china"
            rm -f "$tmp"
        fi
    else
        warn "china_ip_list download failed; keeping existing $china"
        rm -f "$tmp"
    fi
fi

if [ "$DRY_RUN" != "1" ]; then
    systemctl reload 5gpn-dns 2>/dev/null || true
fi
ok "lists updated (rules_dir=$RULES_DIR, dry_run=$DRY_RUN)"
