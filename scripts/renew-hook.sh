#!/bin/bash
# Let's Encrypt renewal deploy hook — copy the renewed WILDCARD lineage
# (*.<DNS_BASE_DOMAIN> + base) to the three 5gpn role dirs
# (/etc/5gpn/cert/dot, /etc/5gpn/cert/web, /etc/5gpn/cert/zash). The zash role
# is shared by the zashboard panel and the mihomo loopback external-controller.
# 5gpn-dns serves the TLS listeners and reloads its own cert cache via SIGHUP;
# mihomo reloads the controller certificate files automatically, so the renewed
# zash copy becomes active without a mihomo restart or reload.
#
# ONE wildcard lineage now covers ALL THREE service subdomains (console/zash/
# dot); the lineage being renewed is matched against dns.env's DNS_BASE_DOMAIN
# before fanning the copy out, so an unrelated lineage on the same box (if any)
# is never mistaken for ours. The data plane is mihomo; no legacy sniproxy is
# touched by this hook.
set -e

# --- Gum-or-echo status helpers. As a certbot deploy hook this runs with no TTY,
# so these always fall back to plain echo (clean lines in journald) — but they keep
# the wording consistent with the rest of the installer when run by hand. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

CERT_ROOT=/etc/5gpn/cert
DNS_ENV=/etc/5gpn/dns.env

cfg_get() { grep -E "^${1}=" "$DNS_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
BASE_DOMAIN="$(cfg_get DNS_BASE_DOMAIN)"
DOT_DOMAIN="$(cfg_get DNS_DOMAIN)"

# deploy_lineage <live-dir>: if the lineage matches our wildcard base domain,
# copy fullchain/privkey to ALL THREE role dirs (dot/web/zash).
deploy_lineage() {
    local live="$1"
    [ -f "${live}/fullchain.pem" ] || { warn "no fullchain.pem in ${live}; skipping"; return 0; }
    local name; name="$(basename "$live")"
    name="${name%-[0-9][0-9][0-9][0-9]}"   # certbot duplicate-lineage suffix
    if [ -z "$BASE_DOMAIN" ] || [ "$name" != "$BASE_DOMAIN" ]; then
        warn "lineage ${name} does not match DNS_BASE_DOMAIN (${BASE_DOMAIN:-unset}); skipping"
        return 0
    fi
    local r
    for r in dot web zash; do
        install -d -m 0750 "${CERT_ROOT}/${r}"
        cp "${live}/fullchain.pem" "${CERT_ROOT}/${r}/fullchain.pem"
        cp "${live}/privkey.pem"   "${CERT_ROOT}/${r}/privkey.pem"
        chmod 640 "${CERT_ROOT}/${r}"/*.pem
    done
    ok "wildcard cert for ${name} redeployed to dot/web/zash"
    _WILDCARD_RENEWED=1
}

_WILDCARD_RENEWED=0
# certbot exports RENEWED_LINEAGE (the lineage being renewed) to deploy hooks —
# prefer it for a deterministic choice. Fall back to deploying every live dir
# only if the hook is run manually (no RENEWED_LINEAGE in the environment).
if [ -n "${RENEWED_LINEAGE:-}" ]; then
    deploy_lineage "$RENEWED_LINEAGE"
else
    found=0
    for d in /etc/letsencrypt/live/*/; do
        [ -d "$d" ] || continue
        deploy_lineage "${d%/}"
        found=1
    done
    if [ "$found" = 0 ]; then
        err "No certificate live directory found"
        exit 1
    fi
fi

# SIGHUP reloads the rule sets; the redeployed cert is loaded lazily on the next
# TLS handshake (certGetter mtime check), so the dot/web/zash copies take effect
# without a daemon restart.
if systemctl is-active --quiet 5gpn-dns; then
    systemctl reload 5gpn-dns
fi
ok "5gpn-dns reloaded (SIGHUP; cert applies on next handshake)"

# NOTE: mihomo is deliberately NOT restarted or reloaded here. It remains the
# raw L4 forwarder for client traffic, while the loopback external-controller
# uses the shared zash role certificate. Renewal only needs the file copies
# above; restarting mihomo would add avoidable churn for live forwarded sessions.

# Re-sign the iOS .mobileconfig with the freshly-renewed DoT cert. The profile is
# S/MIME-signed at generation time with the THEN-current cert (gen-ios-profile.sh);
# without this, ~90 days after install the signing cert expires and iOS shows the
# profile as unverified. Best-effort: a failure here must never fail the renewal
# (certs are already deployed + reloaded above). Only relevant when our wildcard
# (which also covers the dot/ role) was among the renewed lineages.
IOSGEN="/opt/5gpn/scripts/gen-ios-profile.sh"
WWW_DIR="/opt/5gpn/www"
_gw="$(cfg_get DNS_GATEWAY_IP)"
if [ "$_WILDCARD_RENEWED" = 1 ] && [ -x "$IOSGEN" ] && [ -n "$DOT_DOMAIN" ] && [ -n "$_gw" ]; then
    if CERT_DIR="${CERT_ROOT}/dot" bash "$IOSGEN" "$DOT_DOMAIN" "$_gw" "$WWW_DIR" >/dev/null 2>&1; then
        ok "iOS profile re-signed with the renewed cert."
    else
        warn "iOS profile re-sign failed (non-fatal); it may show as unverified until 'install.sh --ios' is re-run."
    fi
fi
