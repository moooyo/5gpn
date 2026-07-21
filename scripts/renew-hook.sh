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
RENEW_LOCK_FILE=/run/5gpn/cert-renew.lock
CONFIG_ROOT_MARKER=.5gpn-owned
CONFIG_ROOT_MARKER_VALUE=5gpn-config-v1
CERT_ROOT_MARKER=.5gpn-cert-root-owned
CERT_ROOT_MARKER_VALUE=5gpn-cert-root-v1
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

acquire_deploy_lock() {
    local lock_dir root_group fd_identity file_identity
    [[ "$EUID" == 0 ]] || { err "Certificate deployment must run as root."; return 1; }
    # The installer and the scoped renewal helper already hold this lock while
    # invoking Certbot. Their root-only internal marker avoids recursively
    # locking from the Certbot child hook. A distro-wide Certbot invocation has
    # no marker and must serialize its role publication here.
    [[ "${GPN_CERT_LOCK_HELD:-0}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate deployment exclusion."; return 1; }
    lock_dir="$(dirname -- "$RENEW_LOCK_FILE")"
    root_group="$(group_gid root)" || return 1
    if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" || return 1
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(path_uid "$lock_dir")" == "$EUID" \
       && "$(path_gid "$lock_dir")" == "$root_group" \
       && "$(path_mode "$lock_dir")" == 700 ]] \
        || { err "Unsafe certificate deployment lock directory: $lock_dir"; return 1; }
    if [[ -e "$RENEW_LOCK_FILE" || -L "$RENEW_LOCK_FILE" ]]; then
        safe_plain_file "$RENEW_LOCK_FILE" "$root_group" 600 \
            || { err "Unsafe certificate deployment lock file: $RENEW_LOCK_FILE"; return 1; }
    fi
    exec 9>"$RENEW_LOCK_FILE"
    chmod 0600 "$RENEW_LOCK_FILE" || { exec 9>&-; return 1; }
    safe_plain_file "$RENEW_LOCK_FILE" "$root_group" 600 || { exec 9>&-; return 1; }
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/$$/fd/9" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$RENEW_LOCK_FILE" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]] \
        || { exec 9>&-; err "The certificate deployment lock descriptor is unsafe."; return 1; }
    flock -w 10 9 \
        || { err "Another 5gpn certificate operation is running."; return 1; }
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

path_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
path_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
path_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
path_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

group_gid() {
    local group="$1" entry gid
    if [[ "$CERT_ROOT" != /etc/5gpn/cert ]]; then
        id -g
        return
    fi
    entry="$(getent group "$group" 2>/dev/null)" || return 1
    gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

root_gid() {
    group_gid root
}

canonical_directory() {
    local path="$1" canonical
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$canonical" && "$canonical" == "$path" ]]
}

safe_plain_file() {
    local path="$1" gid="$2" mode="$3"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$gid" \
       && "$(path_mode "$path")" == "$mode" \
       && "$(path_nlink "$path")" == 1 ]]
}

safe_marker() {
    local dir="$1" name="$2" value="$3" gid marker="${1}/${2}"
    gid="$(root_gid)" || return 1
    safe_plain_file "$marker" "$gid" 644 \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == "$value" ]]
}

cert_root_is_safe() {
    local config_root root_group config_group entry name
    config_root="$(dirname -- "$CERT_ROOT")"
    [[ "$(basename -- "$CERT_ROOT")" == cert ]] || return 1
    root_group="$(root_gid)" || return 1
    config_group="$(group_gid "$DNS_CERT_GROUP")" || return 1
    canonical_directory "$config_root" \
        && [[ "$(path_uid "$config_root")" == "$EUID" \
           && "$(path_gid "$config_root")" == "$config_group" \
           && "$(path_mode "$config_root")" == 3771 ]] \
        && safe_marker "$config_root" "$CONFIG_ROOT_MARKER" "$CONFIG_ROOT_MARKER_VALUE" \
        || return 1
    canonical_directory "$CERT_ROOT" \
        && [[ "$(path_uid "$CERT_ROOT")" == "$EUID" \
           && "$(path_gid "$CERT_ROOT")" == "$root_group" \
           && "$(path_mode "$CERT_ROOT")" == 751 ]] \
        && safe_marker "$CERT_ROOT" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
        || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROOT_MARKER") ;;
            .provenance) safe_plain_file "$entry" "$root_group" 640 || return 1 ;;
            .certbot-ownership) safe_plain_file "$entry" "$root_group" 640 || return 1 ;;
            dot|web|zash) [[ -d "$entry" && ! -L "$entry" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$CERT_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

generation_name_is_safe() {
    [[ "${1:-}" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
}

generation_candidate_is_safe() {
    local path="$1" expected_gid="$2" entry name count=0
    canonical_directory "$path" || return 1
    [[ "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$expected_gid" \
       && "$(path_mode "$path")" == 750 ]] || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            fullchain.pem|privkey.pem)
                safe_plain_file "$entry" "$expected_gid" 640 || return 1 ;;
            *) return 1 ;;
        esac
        ((count += 1))
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    (( count <= 2 ))
}

interrupted_empty_generation_is_safe() {
    local path="$1" expected_gid="$2" actual_gid root_group entry
    canonical_directory "$path" || return 1
    actual_gid="$(path_gid "$path")"
    root_group="$(root_gid)" || return 1
    [[ "$(path_uid "$path")" == "$EUID" \
       && "$(path_mode "$path")" == 700 \
       && ( "$actual_gid" == "$root_group" || "$actual_gid" == "$expected_gid" ) ]] \
        || return 1
    entry="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 1
    [[ -z "$entry" ]]
}

generation_is_safe() {
    local path="$1" expected_gid="$2" count
    generation_candidate_is_safe "$path" "$expected_gid" || return 1
    count="$(find "$path" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')" \
        || return 1
    [[ "$count" == 2 ]]
}

role_boundary_is_safe() {
    local role="$1" dest="$2" group expected_gid root_group marker generations
    [[ "$dest" == "$CERT_ROOT/$role" ]] || return 1
    group="$(role_group "$role")" || return 1
    expected_gid="$(group_gid "$group")" || return 1
    root_group="$(root_gid)" || return 1
    canonical_directory "$dest" \
        && [[ "$(path_uid "$dest")" == "$EUID" \
           && "$(path_gid "$dest")" == "$expected_gid" \
           && "$(path_mode "$dest")" == 750 ]] \
        || return 1
    marker="${dest}/${CERT_ROLE_MARKER}"
    safe_plain_file "$marker" "$root_group" 644 \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == "${CERT_ROLE_VALUE_PREFIX}:${role}" ]] \
        || return 1
    generations="${dest}/generations"
    canonical_directory "$generations" \
        && [[ "$(path_uid "$generations")" == "$EUID" \
           && "$(path_gid "$generations")" == "$expected_gid" \
           && "$(path_mode "$generations")" == 750 ]] \
        || return 1
}

role_tree_is_safe() {
    local role="$1" dest="$2" group expected_gid root_group entry name current target
    role_boundary_is_safe "$role" "$dest" || return 1
    group="$(role_group "$role")" || return 1
    expected_gid="$(group_gid "$group")" || return 1
    root_group="$(root_gid)" || return 1
    current="${dest}/current"
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" \
                   && "$(path_uid "$entry")" == "$EUID" \
                   && "$(path_gid "$entry")" == "$root_group" \
                   && "$(path_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        generation_name_is_safe "$name" || return 1
        generation_is_safe "$entry" "$expected_gid" || return 1
    done < <(find "${dest}/generations" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [[ -e "$current" || -L "$current" ]]; then
        [[ -L "$current" ]] || return 1
        target="$(readlink -- "$current")" || return 1
        [[ "$target" == generations/* ]] || return 1
        generation_name_is_safe "${target#generations/}" || return 1
        generation_is_safe "${dest}/${target}" "$expected_gid"
    fi
}

remove_role_generation() {
    local role="$1" dest="$2" generation="$3" cert_root_real dest_real gen_real group expected_gid entry name
    [[ -n "$generation" && "$generation" != */* ]] || return 1
    generation_name_is_safe "$generation" \
        || [[ "$generation" =~ ^\.new\.[A-Za-z0-9]+$ ]] \
        || return 1
    role_boundary_is_safe "$role" "$dest" || return 1
    cert_root_real="$(readlink -f -- "$CERT_ROOT")" || return 1
    dest_real="$(readlink -f -- "$dest")" || return 1
    [[ "$dest_real" == "$cert_root_real/$role" ]] || return 1
    gen_real="$(readlink -f -- "${dest}/generations/${generation}")" || return 1
    [[ "$gen_real" == "$dest_real/generations/$generation" && -d "$gen_real" && ! -L "$gen_real" ]] || return 1
    group="$(role_group "$role")" || return 1
    expected_gid="$(group_gid "$group")" || return 1
    if [[ "$generation" =~ ^\.new\.[A-Za-z0-9]+$ ]]; then
        generation_candidate_is_safe "$gen_real" "$expected_gid" \
            || interrupted_empty_generation_is_safe "$gen_real" "$expected_gid" \
            || return 1
    else
        generation_candidate_is_safe "$gen_real" "$expected_gid" || return 1
    fi
    rm -rf -- "$gen_real"
}

cleanup_role_generations() {
    local role="$1" dest="$2" keep="$3" entry name
    role_tree_is_safe "$role" "$dest" || return 1
    generation_name_is_safe "$keep" || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="$(basename -- "$entry")"
        [[ "$name" == "$keep" ]] && continue
        remove_role_generation "$role" "$dest" "$name" || return 1
    done < <(find "${dest}/generations" -mindepth 1 -maxdepth 1 -type d -print)
}

cleanup_role_candidates() {
    local roles_name="$1" dests_name="$2" generations_name="$3" links_name="$4"
    local -n roles_ref="$roles_name" dests_ref="$dests_name"
    local -n generations_ref="$generations_name" links_ref="$links_name"
    local i role dest generation link current target
    for i in "${!generations_ref[@]}"; do
        role="${roles_ref[$i]}"
        dest="${dests_ref[$i]}"
        generation="${generations_ref[$i]}"
        link="${links_ref[$i]:-}"
        [[ -z "$link" ]] || rm -f -- "$link" 2>/dev/null || true
        [[ -n "$generation" && -d "$generation" && ! -L "$generation" ]] || continue
        target="generations/$(basename -- "$generation")"
        current="$(readlink -- "${dest}/current" 2>/dev/null || true)"
        [[ "$current" == "$target" ]] \
            || remove_role_generation "$role" "$dest" "$(basename -- "$generation")" 2>/dev/null \
            || true
    done
}

scrub_interrupted_role_candidates() {
    local role="$1" dest="$2" current target entry name root_group group expected_gid
    cert_root_is_safe || return 1
    role_boundary_is_safe "$role" "$dest" || return 1
    root_group="$(root_gid)" || return 1
    group="$(role_group "$role")" || return 1
    expected_gid="$(group_gid "$group")" || return 1
    current="$(readlink -- "$dest/current" 2>/dev/null || true)"
    if [[ -n "$current" ]]; then
        [[ "$current" == generations/* ]] || return 1
        generation_name_is_safe "${current#generations/}" || return 1
        generation_is_safe "$dest/$current" "$expected_gid" || return 1
    elif [[ -e "$dest/current" || -L "$dest/current" ]]; then
        return 1
    fi
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations|current) ;;
            .current.*|.rollback.*)
                [[ "$name" =~ ^\.(current|rollback)\.[0-9]+\.[0-9]+$ \
                   && -L "$entry" \
                   && "$(path_uid "$entry")" == "$EUID" \
                   && "$(path_gid "$entry")" == "$root_group" \
                   && "$(path_nlink "$entry")" == 1 ]] || return 1
                target="$(readlink -- "$entry")" || return 1
                [[ "$target" == generations/* ]] || return 1
                generation_name_is_safe "${target#generations/}" || return 1
                rm -f -- "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        [[ "generations/$name" == "$current" ]] && continue
        if [[ "$name" =~ ^\.new\.[A-Za-z0-9]+$ ]]; then
            generation_candidate_is_safe "$entry" "$expected_gid" \
                || interrupted_empty_generation_is_safe "$entry" "$expected_gid" \
                || return 1
        else
            generation_name_is_safe "$name" || return 1
            generation_is_safe "$entry" "$expected_gid" || return 1
        fi
        remove_role_generation "$role" "$dest" "$name" || return 1
    done < <(find "$dest/generations" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# publish_roles <cert> <key> <mode> <base> <console> <zash> <dot>
# Stage complete generations for all roles, then atomically swap each role's
# single current symlink. A TLS reader can never observe a mixed keypair.
publish_roles() {
    local cert="$1" key="$2" mode="$3" base="$4"
    local console="$5" zash="$6" dot="$7" r dest group expected_gid root_group generation final link_tmp old i j rollback_link
    local -a roles=(dot web zash) dests=() generations=() links=() old_targets=()

    cert_root_is_safe \
        || { err "certificate publication root is unsafe: $CERT_ROOT"; return 1; }
    root_group="$(root_gid)" || return 1
    for r in "${roles[@]}"; do
        dest="${CERT_ROOT}/${r}"
        role_tree_is_safe "$r" "$dest" \
            || { err "certificate role tree is unsafe: $dest"; return 1; }
    done
    for r in "${roles[@]}"; do
        dest="${CERT_ROOT}/${r}"
        group="$(role_group "$r")" || return 1
        expected_gid="$(group_gid "$group")" || return 1
        if [[ -e "${dest}/current" || -L "${dest}/current" ]]; then
            [[ -L "${dest}/current" ]] || { err "unsafe current path in $dest"; return 1; }
            old="$(readlink -- "${dest}/current")"
            [[ "$old" == generations/* ]] \
                && generation_name_is_safe "${old#generations/}" \
                && generation_is_safe "${dest}/${old}" "$expected_gid" \
                || { err "unsafe current symlink in $dest"; return 1; }
        else
            old=""
        fi
        generation="$(mktemp -d "${dest}/generations/.new.XXXXXX")" || return 1
        dests+=("$dest")
        generations+=("$generation")
        links+=("")
        old_targets+=("$old")
        i=$((${#generations[@]} - 1))
        chgrp "$group" "$generation" && chmod 0750 "$generation" \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        if ! install -g "$group" -m 0640 "$cert" "${generation}/fullchain.pem" \
           || ! install -g "$group" -m 0640 "$key" "${generation}/privkey.pem"; then
            err "cannot stage certificate pair in $dest"
            cleanup_role_candidates roles dests generations links
            return 1
        fi
        generation_is_safe "$generation" "$expected_gid" \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        if ! validate_cert_pair "${generation}/fullchain.pem" "${generation}/privkey.pem" "$mode" "$base" \
            "$console" "$zash" "$dot"; then
            cleanup_role_candidates roles dests generations links
            return 1
        fi
        final="${dest}/generations/generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
        [[ ! -e "$final" && ! -L "$final" ]] \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        mv -- "$generation" "$final" \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        generations[$i]="$final"
        generation_is_safe "$final" "$expected_gid" \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        link_tmp="${dest}/.current.${BASHPID}.${RANDOM}"
        [[ ! -e "$link_tmp" && ! -L "$link_tmp" ]] \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        links[$i]="$link_tmp"
        ln -s "generations/$(basename -- "$final")" "$link_tmp" \
            || { cleanup_role_candidates roles dests generations links; return 1; }
        [[ "$(path_uid "$link_tmp")" == "$EUID" \
           && "$(path_gid "$link_tmp")" == "$root_group" \
           && "$(path_nlink "$link_tmp")" == 1 ]] \
            || { cleanup_role_candidates roles dests generations links; return 1; }
    done

    cert_root_is_safe \
        || { cleanup_role_candidates roles dests generations links; return 1; }

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
            cleanup_role_candidates roles dests generations links
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

    acquire_deploy_lock || return 1

    cert_root_is_safe || return 1
    local role
    for role in dot web zash; do
        scrub_interrupted_role_candidates "$role" "$CERT_ROOT/$role" || return 1
    done

    if [[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]]; then
        for role in dot web zash; do
            role_tree_is_safe "$role" "$CERT_ROOT/$role" || return 1
        done
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

    # Re-sign both iOS profiles with the renewed DoT role. The generator stages
    # and signs both payloads before atomically replacing either live file.
    # Best-effort: certificate deployment is already complete, so profile
    # failure must not fail renewal and the last-known-good profiles stay live.
    gw="$(cfg_get DNS_GATEWAY_IP)"
    if [[ "$_CERT_RENEWED" == 1 && -x "$IOSGEN" && -n "$DOT_DOMAIN" && -n "$gw" ]]; then
        if bash "$IOSGEN" "$DOT_DOMAIN" "$gw" "$WWW_DIR"; then
            ok "iOS profiles re-signed with the renewed cert."
        else
            warn "iOS profile re-sign failed (non-fatal); inspect the preceding generator error and any retained recovery path before rerunning 'install.sh ios'."
        fi
    fi
}

if [[ "${RENEW_HOOK_LIB_ONLY:-0}" != 1 ]]; then
    renew_hook_main "$@"
fi
