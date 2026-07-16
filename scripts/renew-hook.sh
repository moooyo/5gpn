#!/bin/bash
# Let's Encrypt renewal deploy hook — publish the renewed 5gpn lineage to
# /etc/5gpn/cert/{dot,web,zash}. Cloudflare DNS-01 lineages must cover the apex
# and wildcard; HTTP-01 lineages must cover all three derived service names.
# The zash role is shared by the zashboard panel and mihomo's TLS controller.
# The pinned mihomo v1.19.28 build guarantees that mihomo reloads the controller certificate files automatically, so the renewed zash copy becomes active without a mihomo restart or reload.
#
# This hook is installed system-wide and certbot may invoke it for unrelated
# lineages. It therefore accepts only the exact lineage named by the validated
# DNS_BASE_DOMAIN, verifies the leaf SANs and private-key match before staging,
# and re-signs only after all three role copies were published.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Gum-or-echo status helpers. As a certbot deploy hook this normally runs
# without a TTY, so output stays as plain, journald-friendly lines. ---
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

# Fixed production paths. Tests source the hook in library mode and override
# these globals only after the production defaults have been established.
CERT_ROOT=/etc/5gpn/cert
DNS_ENV=/etc/5gpn/dns.env
LE_LIVE_ROOT=/etc/letsencrypt/live
IOSGEN=/opt/5gpn/scripts/gen-ios-profile.sh
WWW_DIR=/opt/5gpn/www

BASE_DOMAIN=""
CERT_MODE=""
CONSOLE_DOMAIN=""
ZASH_DOMAIN=""
DOT_DOMAIN=""
_WILDCARD_RENEWED=0

cfg_get() { grep -E "^${1}=" "$DNS_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

valid_base_domain() {
    local d="$1"
    [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

normalized_base_domain() {
    local d="$1"
    d="${d%.}"
    d="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
    valid_base_domain "$d" || return 1
    printf '%s\n' "$d"
}

normalized_cert_mode() {
    case "${1:-}" in
        cloudflare) printf '%s\n' cloudflare ;;
        http|http-01) printf '%s\n' http-01 ;;
        debug) printf '%s\n' debug ;;
        *) return 1 ;;
    esac
}

cert_chain_trusted() {
    local cert="$1"
    openssl verify -purpose sslserver -CApath /etc/ssl/certs -untrusted "$cert" "$cert" >/dev/null 2>&1 \
        || { [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
             && openssl verify -purpose sslserver -CAfile /etc/pki/tls/certs/ca-bundle.crt \
                    -untrusted "$cert" "$cert" >/dev/null 2>&1; }
}

# validate_cert_pair <cert> <key> <mode> <base> <console> <zash> <dot>
# Require a currently valid leaf certificate with exactly the DNS SAN set for
# its issuance mode and prove that the private key has the same public key.
# Non-DNS SANs do not affect this identity check. Comparing public-key PEM works
# for RSA and EC keys without exposing private material. Debug certificates
# share Cloudflare's apex+wildcard shape, although renew_hook_main never deploys
# debug lineages.
validate_cert_pair() {
    local cert="$1" key="$2" mode="$3" base="$4"
    local console="$5" zash="$6" dot="$7"
    local sans normalized_sans dns_sans cert_pub key_pub required name
    [[ -s "$cert" ]] || { err "certificate is missing or empty: $cert"; return 1; }
    [[ -s "$key" ]]  || { err "private key is missing or empty: $key"; return 1; }

    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 \
        || { err "certificate is invalid or expired: $cert"; return 1; }
    sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)" \
        || { err "cannot read certificate SANs: $cert"; return 1; }
    normalized_sans="$(printf '%s\n' "$sans" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    dns_sans="$(printf '%s\n' "$normalized_sans" | sed -n 's/^DNS://p')"
    case "$mode" in
        cloudflare|debug)
            required="${base}"$'\n'"*.${base}"
            ;;
        http-01)
            required="${console}"$'\n'"${zash}"$'\n'"${dot}"
            ;;
        *)
            err "unsupported certificate mode: $mode"
            return 1
            ;;
    esac
    while IFS= read -r name; do
        grep -Fqx -- "$name" <<<"$dns_sans" \
            || { err "certificate does not cover required SAN ${name}"; return 1; }
    done <<<"$required"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        grep -Fqx -- "$name" <<<"$required" \
            || { err "certificate has unexpected DNS SAN ${name}"; return 1; }
    done <<<"$dns_sans"

    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null)" \
        || { err "cannot read certificate public key: $cert"; return 1; }
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null)" \
        || { err "cannot read private key: $key"; return 1; }
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] \
        || { err "certificate/private-key mismatch for ${base}"; return 1; }
    [[ "$mode" == debug ]] || cert_chain_trusted "$cert" \
        || { err "certificate chain is not trusted for production TLS"; return 1; }
}

cleanup_staged() {
    local f
    for f in "$@"; do
        if [[ -n "$f" ]]; then
            rm -f -- "$f" 2>/dev/null || true
        fi
    done
    return 0
}

# publish_roles <cert> <key> <mode> <base> <console> <zash> <dot>
# Stage and validate every role before publishing any of them. Each temporary
# file is created beside its destination, receives final permissions, and is
# then renamed over the live path. A two-file pair cannot be switched with one
# portable filesystem operation, but same-directory rename prevents readers
# from ever seeing a truncated file and keeps the publication window minimal.
publish_roles() {
    local cert="$1" key="$2" mode="$3" base="$4"
    local console="$5" zash="$6" dot="$7" r dest cert_tmp key_tmp i
    local -a roles=(dot web zash) dests=() cert_tmps=() key_tmps=()

    for r in "${roles[@]}"; do
        dest="${CERT_ROOT}/${r}"
        if ! install -d -m 0750 "$dest"; then
            err "cannot create certificate role directory: $dest"
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        fi
        cert_tmp="$(mktemp "${dest}/.fullchain.pem.XXXXXX")" || {
            err "cannot stage certificate in $dest"
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        }
        key_tmp="$(mktemp "${dest}/.privkey.pem.XXXXXX")" || {
            err "cannot stage private key in $dest"
            cleanup_staged "$cert_tmp" "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        }
        dests+=("$dest")
        cert_tmps+=("$cert_tmp")
        key_tmps+=("$key_tmp")

        if ! install -m 0640 "$cert" "$cert_tmp" \
           || ! install -m 0640 "$key" "$key_tmp" \
           || ! chmod 0640 "$cert_tmp" "$key_tmp"; then
            err "cannot stage certificate pair in $dest"
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        fi
        if ! validate_cert_pair "$cert_tmp" "$key_tmp" "$mode" "$base" \
            "$console" "$zash" "$dot"; then
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        fi
    done

    # Publish key first and certificate immediately after it. Both moves stay on
    # the destination filesystem and are atomic for the individual file.
    for i in "${!roles[@]}"; do
        if ! mv -f -- "${key_tmps[$i]}" "${dests[$i]}/privkey.pem"; then
            err "cannot publish private key for role ${roles[$i]}"
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        fi
        key_tmps[$i]=""
        if ! mv -f -- "${cert_tmps[$i]}" "${dests[$i]}/fullchain.pem"; then
            err "cannot publish certificate for role ${roles[$i]}"
            cleanup_staged "${cert_tmps[@]}" "${key_tmps[@]}"
            return 1
        fi
        cert_tmps[$i]=""
    done
}

# deploy_lineage <live-dir>: validate and deploy only the exact current 5gpn
# lineage. No basename-suffix matching and no scan of unrelated live dirs.
deploy_lineage() {
    local live="${1%/}" expected="${LE_LIVE_ROOT}/${BASE_DOMAIN}"
    [[ "$live" == "$expected" ]] \
        || { err "refusing non-5gpn lineage: $live"; return 1; }
    [[ -d "$live" ]] || { err "5gpn lineage directory is missing: $live"; return 1; }

    validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
        "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN" \
        || return 1
    publish_roles "${live}/fullchain.pem" "${live}/privkey.pem" \
        "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN" \
        || return 1
    _WILDCARD_RENEWED=1
    ok "${CERT_MODE} cert for ${BASE_DOMAIN} redeployed to dot/web/zash"
}

renew_hook_main() {
    local configured raw_mode live expected gw
    configured="$(cfg_get DNS_BASE_DOMAIN)"
    if ! BASE_DOMAIN="$(normalized_base_domain "$configured")"; then
        err "DNS_BASE_DOMAIN is missing or invalid; no certificate was deployed."
        # A system-wide certbot hook must not make an unrelated lineage renewal
        # fail merely because 5gpn identity is unavailable. Manual invocation,
        # however, returns failure so the operator sees the broken configuration.
        [[ -n "${RENEWED_LINEAGE:-}" ]] && return 0
        return 1
    fi
    expected="${LE_LIVE_ROOT}/${BASE_DOMAIN}"

    if [[ -n "${RENEWED_LINEAGE:-}" ]]; then
        live="${RENEWED_LINEAGE%/}"
        if [[ "$live" != "$expected" ]]; then
            info "Ignoring unrelated renewed lineage: $live"
            return 0
        fi
    else
        # Manual recovery invocation: target exactly the configured cert name.
        live="$expected"
    fi

    raw_mode="$(cfg_get CERT_MODE)"
    if ! CERT_MODE="$(normalized_cert_mode "$raw_mode")"; then
        err "CERT_MODE must be cloudflare or http-01; no certificate was deployed."
        return 1
    fi
    if [[ "$CERT_MODE" == debug ]]; then
        err "CERT_MODE=debug has no ACME deploy-hook lineage; no certificate was deployed."
        return 1
    fi

    CONSOLE_DOMAIN="$(cfg_get DNS_CONSOLE_DOMAIN)"
    ZASH_DOMAIN="$(cfg_get DNS_ZASH_DOMAIN)"
    DOT_DOMAIN="$(cfg_get DNS_DOMAIN)"
    if [[ "$CONSOLE_DOMAIN" != "console.${BASE_DOMAIN}" \
       || "$ZASH_DOMAIN" != "zash.${BASE_DOMAIN}" \
       || "$DOT_DOMAIN" != "dot.${BASE_DOMAIN}" ]]; then
        err "service domains in ${DNS_ENV} do not match DNS_BASE_DOMAIN=${BASE_DOMAIN}; no certificate was deployed."
        return 1
    fi
    valid_base_domain "$CONSOLE_DOMAIN" \
        && valid_base_domain "$ZASH_DOMAIN" \
        && valid_base_domain "$DOT_DOMAIN" \
        || { err "derived service domains are invalid; no certificate was deployed."; return 1; }

    if [[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]]; then
        validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN"
        return
    fi

    _WILDCARD_RENEWED=0
    deploy_lineage "$live" || return 1

    # TLS readers detect the atomically replaced files by mtime on the next
    # handshake. SIGHUP is deliberately reserved for rules/chnroute reloads and
    # is not used as a certificate-reload API.
    ok "Certificate files published; TLS readers will load them on the next handshake."

    # Re-sign the iOS profile with the renewed DoT role. Best-effort: certificate
    # deployment is already complete, so profile failure must not fail renewal.
    gw="$(cfg_get DNS_GATEWAY_IP)"
    if [[ "$_WILDCARD_RENEWED" == 1 && -x "$IOSGEN" && -n "$DOT_DOMAIN" && -n "$gw" ]]; then
        if bash "$IOSGEN" "$DOT_DOMAIN" "$gw" "$WWW_DIR" >/dev/null 2>&1; then
            ok "iOS profile re-signed with the renewed cert."
        else
            warn "iOS profile re-sign failed (non-fatal); it may show as unverified until 'install.sh --ios' is re-run."
        fi
    fi
}

if [[ "${RENEW_HOOK_LIB_ONLY:-0}" != 1 ]]; then
    renew_hook_main "$@"
fi
