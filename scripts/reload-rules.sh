#!/usr/bin/env bash
# Reload local 5gpn-dns policy and chnroute state. Subscription fetching keeps
# its own in-process schedule; this command performs no network update.
set -euo pipefail

# Gum-or-echo status helpers. install.sh owns Gum installation; this script only
# detects an already installed binary.
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

systemctl reload 5gpn-dns 2>/dev/null \
    || { err "systemctl reload 5gpn-dns failed (not running or not installed)."; exit 1; }
ok "5gpn-dns rules reloaded from disk."
