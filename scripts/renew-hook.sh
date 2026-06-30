#!/bin/bash
# Let's Encrypt renewal deploy hook — copy certs to /etc/5gpn/cert and
# hot-reload 5gpn-dns via SIGHUP (ExecReload=/bin/kill -HUP $MAINPID).
# 5gpn-dns watches cert mtime and reloads TLS context on SIGHUP; no restart needed.
set -e

# --- Gum-or-echo status helpers. As a certbot deploy hook this runs with no TTY,
# so these always fall back to plain echo (clean lines in journald) — but they keep
# the wording consistent with the rest of the installer when run by hand. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

CERT_DIR=/etc/5gpn/cert

# certbot exports RENEWED_LINEAGE (the lineage being renewed) to deploy hooks —
# prefer it for a deterministic choice. Fall back to the newest live dir only if
# the hook is run manually (no RENEWED_LINEAGE in the environment).
LIVE_DIR="${RENEWED_LINEAGE:-}"
if [ -z "$LIVE_DIR" ]; then
    LIVE_DIR=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | head -n1)
fi
if [ -z "$LIVE_DIR" ] || [ ! -f "${LIVE_DIR}/fullchain.pem" ]; then
    err "No certificate live directory found"
    exit 1
fi

mkdir -p "$CERT_DIR"
cp "${LIVE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp "${LIVE_DIR}/privkey.pem"   "${CERT_DIR}/privkey.pem"
chmod 640 "${CERT_DIR}"/*.pem

# Hot-reload 5gpn-dns: SIGHUP triggers cert file mtime check + TLS context reload.
# No restart needed — zero interruption to in-flight DoT/DoH connections.
if systemctl is-active --quiet 5gpn-dns; then
    systemctl reload 5gpn-dns
fi
ok "cert redeployed to ${CERT_DIR}; 5gpn-dns reloaded (SIGHUP)"
