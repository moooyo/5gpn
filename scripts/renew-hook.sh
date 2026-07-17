#!/bin/bash
# 5gpn-renew-hook-id: deploy-v1
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
CERT_ROLE_MARKER=.5gpn-cert-role-owned
CERT_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
DNS_CERT_GROUP=5gpn-dns
MIHOMO_CERT_GROUP=mihomo

BASE_DOMAIN=""
CERT_MODE=""
CONSOLE_DOMAIN=""
ZASH_DOMAIN=""
DOT_DOMAIN=""
_CERT_RENEWED=0

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
        http-01) printf '%s\n' http-01 ;;
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

role_group() {
    local role="$1" group="$DNS_CERT_GROUP"
    [[ "$role" == zash ]] && group="$MIHOMO_CERT_GROUP"
    if getent group "$group" >/dev/null 2>&1; then
        printf '%s\n' "$group"
    elif [[ "$CERT_ROOT" != /etc/5gpn/cert ]]; then
        id -gn
    else
        err "required certificate group is missing: $group"
        return 1
    fi
}

write_role_marker() {
    local role="$1" dest="$2" tmp
    [[ -d "$dest" && ! -L "$dest" ]] || return 1
    tmp="$(mktemp "${dest}/.${CERT_ROLE_MARKER}.XXXXXX")" || return 1
    printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:${role}" > "$tmp" \
        && chmod 0644 "$tmp" \
        && mv -f -- "$tmp" "${dest}/${CERT_ROLE_MARKER}" \
        || { rm -f -- "$tmp"; return 1; }
}

role_is_owned() {
    local role="$1" dest="$2" marker="${dest}/${CERT_ROLE_MARKER}"
    [[ -d "$dest" && ! -L "$dest" && -f "$marker" && ! -L "$marker" ]] \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == "${CERT_ROLE_VALUE_PREFIX}:${role}" ]]
}

remove_role_generation() {
    local role="$1" dest="$2" generation="$3" cert_root_real dest_real gen_real
    [[ -n "$generation" && "$generation" != */* ]] || return 1
    role_is_owned "$role" "$dest" || return 1
    cert_root_real="$(readlink -f -- "$CERT_ROOT")" || return 1
    dest_real="$(readlink -f -- "$dest")" || return 1
    [[ "$dest_real" == "$cert_root_real/$role" ]] || return 1
    gen_real="$(readlink -f -- "${dest}/generations/${generation}")" || return 1
    [[ "$gen_real" == "$dest_real/generations/$generation" && -d "$gen_real" && ! -L "$gen_real" ]] || return 1
    rm -rf -- "$gen_real"
}

cleanup_role_generations() {
    local role="$1" dest="$2" keep="$3" entry name
    role_is_owned "$role" "$dest" || return 1
    [[ "$keep" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="$(basename -- "$entry")"
        [[ "$name" == "$keep" ]] && continue
        remove_role_generation "$role" "$dest" "$name" || return 1
    done < <(find "${dest}/generations" -mindepth 1 -maxdepth 1 -type d -print)
}

# publish_roles <cert> <key> <mode> <base> <console> <zash> <dot>
# Stage complete generations for all roles, then atomically swap each role's
# single current symlink. A TLS reader can never observe a mixed keypair.
publish_roles() {
    local cert="$1" key="$2" mode="$3" base="$4"
    local console="$5" zash="$6" dot="$7" r dest group generation final link_tmp old i j rollback_link
    local -a roles=(dot web zash) dests=() generations=() links=() old_targets=()

    for r in "${roles[@]}"; do
        dest="${CERT_ROOT}/${r}"
        group="$(role_group "$r")" || return 1
        if ! install -d -g "$group" -m 0750 "$dest"; then
            err "cannot create certificate role directory: $dest"
            return 1
        fi
        write_role_marker "$r" "$dest" || return 1
        install -d -g "$group" -m 0750 "${dest}/generations" || return 1
        if [[ -e "${dest}/current" || -L "${dest}/current" ]]; then
            [[ -L "${dest}/current" ]] || { err "unsafe current path in $dest"; return 1; }
            old="$(readlink -- "${dest}/current")"
            [[ "$old" =~ ^generations/[A-Za-z0-9._-]+$ && -d "${dest}/${old}" ]] \
                || { err "unsafe current symlink in $dest"; return 1; }
        else
            old=""
        fi
        generation="$(mktemp -d "${dest}/generations/.new.XXXXXX")" || return 1
        chgrp "$group" "$generation" && chmod 0750 "$generation" || return 1
        if ! install -g "$group" -m 0640 "$cert" "${generation}/fullchain.pem" \
           || ! install -g "$group" -m 0640 "$key" "${generation}/privkey.pem"; then
            err "cannot stage certificate pair in $dest"
            remove_role_generation "$r" "$dest" "$(basename -- "$generation")" || true
            return 1
        fi
        if ! validate_cert_pair "${generation}/fullchain.pem" "${generation}/privkey.pem" "$mode" "$base" \
            "$console" "$zash" "$dot"; then
            remove_role_generation "$r" "$dest" "$(basename -- "$generation")" || true
            return 1
        fi
        final="${dest}/generations/generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
        [[ ! -e "$final" ]] || return 1
        mv -- "$generation" "$final" || return 1
        link_tmp="${dest}/.current.${BASHPID}.${RANDOM}"
        [[ ! -e "$link_tmp" && ! -L "$link_tmp" ]] || return 1
        ln -s "generations/$(basename -- "$final")" "$link_tmp" || return 1
        dests+=("$dest")
        generations+=("$final")
        links+=("$link_tmp")
        old_targets+=("$old")
    done

    for i in "${!roles[@]}"; do
        if ! mv -Tf -- "${links[$i]}" "${dests[$i]}/current"; then
            for ((j = 0; j < i; j++)); do
                if [[ -n "${old_targets[$j]}" ]]; then
                    rollback_link="${dests[$j]}/.rollback.${BASHPID}.${RANDOM}"
                    ln -s "${old_targets[$j]}" "$rollback_link" \
                        && mv -Tf -- "$rollback_link" "${dests[$j]}/current" || true
                else
                    rm -f -- "${dests[$j]}/current"
                fi
            done
            rm -f -- "${links[@]}"
            err "cannot atomically publish certificate role ${roles[$i]}"
            return 1
        fi
        links[$i]=""
    done
    for i in "${!roles[@]}"; do
        cleanup_role_generations "${roles[$i]}" "${dests[$i]}" \
            "$(basename -- "${generations[$i]}")" || return 1
        rm -f -- "${dests[$i]}/fullchain.pem" "${dests[$i]}/privkey.pem"
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
    _CERT_RENEWED=1
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
    CONSOLE_DOMAIN="console.${BASE_DOMAIN}"
    ZASH_DOMAIN="zash.${BASE_DOMAIN}"
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
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

    valid_base_domain "$CONSOLE_DOMAIN" \
        && valid_base_domain "$ZASH_DOMAIN" \
        && valid_base_domain "$DOT_DOMAIN" \
        || { err "derived service domains are invalid; no certificate was deployed."; return 1; }

    if [[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]]; then
        validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN"
        return
    fi

    _CERT_RENEWED=0
    deploy_lineage "$live" || return 1

    # TLS readers detect the atomically replaced files by mtime on the next
    # handshake. SIGHUP is deliberately reserved for rules/chnroute reloads and
    # is not used as a certificate-reload API.
    ok "Certificate files published; TLS readers will load them on the next handshake."

    # Re-sign the iOS profile with the renewed DoT role. Best-effort: certificate
    # deployment is already complete, so profile failure must not fail renewal.
    gw="$(cfg_get DNS_GATEWAY_IP)"
    if [[ "$_CERT_RENEWED" == 1 && -x "$IOSGEN" && -n "$DOT_DOMAIN" && -n "$gw" ]]; then
        if bash "$IOSGEN" "$DOT_DOMAIN" "$gw" "$WWW_DIR" >/dev/null 2>&1; then
            ok "iOS profile re-signed with the renewed cert."
        else
            warn "iOS profile re-sign failed (non-fatal); it may show as unverified until 'install.sh ios' is re-run."
        fi
    fi
}

if [[ "${RENEW_HOOK_LIB_ONLY:-0}" != 1 ]]; then
    renew_hook_main "$@"
fi
