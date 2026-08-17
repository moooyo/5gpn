#!/bin/bash -p
# Cloudflare-only public certificate lifecycle for the single-container runtime.
# This helper always runs as the same fixed fivegpn UID/GID as 5gpn-mihomo.
set +x +v
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    while IFS= read -r exported_name; do
        unset "$exported_name" 2>/dev/null || true
    done < <(compgen -e)
fi
LANG=C
LC_ALL=C
export LANG LC_ALL
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
HOME=/nonexistent
TMPDIR=/tmp
FIVEGPN_RUNTIME=container
export HOME TMPDIR FIVEGPN_RUNTIME
CURRENT_GID="$(id -g)"
EXPECTED_UID=10001
EXPECTED_GID=10001

CONFIG_FILE=/run/5gpn-bootstrap/config.env
CF_CREDENTIAL=/run/5gpn/cloudflare.ini
LE_ROOT=/etc/5gpn/letsencrypt
LE_LIVE_ROOT=/etc/5gpn/letsencrypt/live
LE_ARCHIVE_ROOT=/etc/5gpn/letsencrypt/archive
LE_RENEWAL_ROOT=/etc/5gpn/letsencrypt/renewal
LE_WORK_ROOT=/etc/5gpn/letsencrypt/work
LE_LOG_ROOT=/etc/5gpn/letsencrypt/log
CERT_ROOT=/etc/5gpn/cert
UI_DIR=/opt/5gpn/ui
UI_SOURCE=/usr/share/5gpn/ui
COMPONENT_MANIFEST=/usr/share/5gpn/components.env
UI_GENERATION_HELPER=/opt/5gpn/scripts/ui-generation.sh
PUBLICATION_FS_HELPER=/opt/5gpn/scripts/publication-fs.sh
CERT_ROLE_HELPER=/opt/5gpn/scripts/cert-role-ctl.sh
IOSGEN=/opt/5gpn/scripts/gen-ios-profile.sh
LOCK_FILE=/run/5gpn/cert-renew.lock
LE_PRODUCTION_SERVER=https://acme-v02.api.letsencrypt.org/directory
RENEW_BEFORE_SECONDS=$((30 * 86400))
CF_PROPAGATION_SECONDS=30
CERT_ROOT_MARKER=.5gpn-cert-root-owned
CERT_ROOT_MARKER_VALUE=5gpn-cert-root-v1
CERT_ROLE_MARKER=.5gpn-cert-role-owned
CERT_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
LE_MARKER=.5gpn-docker-letsencrypt-owned
LE_MARKER_VALUE=5gpn-docker-letsencrypt-v1
LINEAGE_READY_MARKER=.5gpn-docker-lineage-ready
LINEAGE_READY_VALUE_PREFIX=5gpn-docker-lineage-ready-v1
LINEAGE_READY_CANDIDATE=.5gpn-docker-lineage-ready.new
UI_HELPER_LOADED=0
CERT_ROLE_HELPERS_LOADED=0
LIVE_GENERATION=""
declare -a COMPLETE_ARCHIVE_GENERATIONS=()

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
warn() { printf '[!]    %s\n' "$*" >&2; }
err() { printf '[ERR]  %s\n' "$*" >&2; }

path_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
path_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
path_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
path_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }
path_size() { stat -c %s -- "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || true; }

directory_entries() {
    local directory="$1" output_name="$2" scan map_rc=0
    local -n output_ref="$output_name"
    output_ref=()
    scan="$(mktemp "${TMPDIR}/5gpn-directory-entries.XXXXXX")" || return 1
    chmod 0600 "$scan" || { rm -f -- "$scan" 2>/dev/null || true; return 1; }
    owned_plain_file "$scan" 600 \
        || { rm -f -- "$scan" 2>/dev/null || true; return 1; }
    if ! find "$directory" -mindepth 1 -maxdepth 1 -print0 > "$scan" 2>/dev/null; then
        rm -f -- "$scan" 2>/dev/null || true
        return 1
    fi
    mapfile -d '' -t output_ref < "$scan" || map_rc=$?
    rm -f -- "$scan" || return 1
    [[ "$map_rc" == 0 ]]
}

canonical_directory() {
    local path="$1" canonical
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$canonical" && "$canonical" == "$path" ]]
}

fsync_directory() {
    canonical_directory "$1" || return 1
    sync -f -- "$1"
}

fsync_file() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    sync -f -- "$1"
}

owned_directory() {
    local path="$1" mode="$2"
    canonical_directory "$path" \
        && [[ "$(path_uid "$path")" == "$EUID" \
           && "$(path_gid "$path")" == "$CURRENT_GID" \
           && "$(path_mode "$path")" == "$mode" ]]
}

owned_plain_file() {
    local path="$1" mode="$2"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_mode "$path")" == "$mode" \
       && "$(path_nlink "$path")" == 1 ]]
}

owned_exact_line_file() {
	local path="$1" mode="$2" value="$3" size expected
	owned_plain_file "$path" "$mode" || return 1
	size="$(path_size "$path")"
	expected=$((${#value} + 1))
	[[ "$size" =~ ^[0-9]+$ && "$size" == "$expected" ]] || return 1
	printf '%s\n' "$value" | cmp -s - "$path"
}

valid_domain() {
    local domain="${1:-}"
    [[ ${#domain} -ge 1 && ${#domain} -le 253 \
       && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_ipv4() {
    local ip="${1:-}" octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [[ ${#octet} -gt 1 && "$octet" == 0* ]] && return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

config_file_safe() {
    local mode uid size
    [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" && -r "$CONFIG_FILE" \
       && "$(path_nlink "$CONFIG_FILE")" == 1 ]] || return 1
    uid="$(path_uid "$CONFIG_FILE")"
    mode="$(path_mode "$CONFIG_FILE")"
    size="$(wc -c < "$CONFIG_FILE" | tr -d '[:space:]')"
    [[ ( "$uid" == 0 || "$uid" == "$EUID" ) \
       && "$mode" =~ ^[0-7]{3,4}$ \
       && "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 65536 ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

config_get() {
    local key="$1" line count
    config_file_safe || return 1
    count="$(grep -cE "^${key}=" "$CONFIG_FILE" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    line="$(grep -E "^${key}=" "$CONFIG_FILE")" || return 1
    printf '%s\n' "${line#*=}"
}

load_configuration() {
    local configured mode
    configured="$(config_get DNS_BASE_DOMAIN)" || return 1
    configured="${configured%.}"
    BASE_DOMAIN="$(printf '%s' "$configured" | tr '[:upper:]' '[:lower:]')"
    valid_domain "$BASE_DOMAIN" || return 1
    mode="$(config_get CERT_MODE 2>/dev/null || true)"
    [[ -n "$mode" ]] || mode=cloudflare
    [[ "$mode" == cloudflare ]] || return 1
    CERT_EMAIL="$(config_get CERT_EMAIL)" || return 1
    [[ "$CERT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ \
       && "$CERT_EMAIL" != -* \
       && ${#CERT_EMAIL} -le 254 ]] || return 1
    GATEWAY_IP="$(config_get DNS_GATEWAY_IP)" || return 1
    valid_ipv4 "$GATEWAY_IP" || return 1
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
    CONSOLE_DOMAIN="console.${BASE_DOMAIN}"
    valid_domain "$DOT_DOMAIN" && valid_domain "$CONSOLE_DOMAIN"
}

credential_safe() {
    local line count
    owned_plain_file "$CF_CREDENTIAL" 600 || return 1
    count="$(wc -l < "$CF_CREDENTIAL" | tr -d '[:space:]')"
    [[ "$count" == 1 ]] || return 1
    IFS= read -r line < "$CF_CREDENTIAL" || return 1
    [[ "$line" =~ ^dns_cloudflare_api_token[[:space:]]*=[[:space:]]*[A-Za-z0-9_-]{20,200}$ ]]
}

ensure_layout() {
    canonical_directory /etc/5gpn \
        && [[ "$(path_uid /etc/5gpn)" == "$EUID" \
           && "$(path_gid /etc/5gpn)" == "$CURRENT_GID" ]] \
        || { err "The persistent /etc/5gpn root is unsafe or belongs to another identity."; return 1; }
    owned_directory "$LE_ROOT" 700 \
        && owned_exact_line_file "$LE_ROOT/$LE_MARKER" 600 "$LE_MARKER_VALUE" \
        && owned_directory "$LE_WORK_ROOT" 700 \
        && owned_directory "$LE_LOG_ROOT" 700 \
        || { err "The persistent Certbot tree is unsafe."; return 1; }
    owned_directory "$CERT_ROOT" 751 \
        && owned_exact_line_file "$CERT_ROOT/$CERT_ROOT_MARKER" 644 "$CERT_ROOT_MARKER_VALUE" \
        || { err "The public certificate role root is unsafe."; return 1; }
    local role
    for role in dot console; do
        owned_directory "$CERT_ROOT/$role" 750 \
            && owned_exact_line_file "$CERT_ROOT/$role/$CERT_ROLE_MARKER" 644 \
                "${CERT_ROLE_VALUE_PREFIX}:${role}" \
            && owned_directory "$CERT_ROOT/$role/generations" 750 \
            || { err "The ${role} certificate role tree is unsafe."; return 1; }
    done
}

lineage_set_is_exclusive() {
    local directory entry name
    local -a entries=()
    for directory in "$LE_LIVE_ROOT" "$LE_ARCHIVE_ROOT"; do
        [[ ! -e "$directory" && ! -L "$directory" ]] && continue
        canonical_directory "$directory" \
            && [[ "$(path_uid "$directory")" == "$EUID" \
               && "$(path_gid "$directory")" == "$CURRENT_GID" ]] \
            || return 1
        directory_entries "$directory" entries || return 1
        for entry in "${entries[@]}"; do
            name="$(basename -- "$entry")"
            case "$name" in
                README) [[ -f "$entry" && ! -L "$entry" ]] || return 1 ;;
                "$BASE_DOMAIN") [[ -d "$entry" && ! -L "$entry" ]] || return 1 ;;
                *) return 1 ;;
            esac
        done
    done
    if [[ -e "$LE_RENEWAL_ROOT" || -L "$LE_RENEWAL_ROOT" ]]; then
        canonical_directory "$LE_RENEWAL_ROOT" \
            && [[ "$(path_uid "$LE_RENEWAL_ROOT")" == "$EUID" \
               && "$(path_gid "$LE_RENEWAL_ROOT")" == "$CURRENT_GID" ]] \
            || return 1
        directory_entries "$LE_RENEWAL_ROOT" entries || return 1
        for entry in "${entries[@]}"; do
            [[ "$(basename -- "$entry")" == "${BASE_DOMAIN}.conf" \
               && -f "$entry" && ! -L "$entry" ]] || return 1
        done
    fi
    [[ ! -e "$LE_ROOT/cli.ini" && ! -L "$LE_ROOT/cli.ini" ]]
}

renewal_value() {
    local conf="$1" key="$2" count
    count="$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null \
        | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

renewal_conf_safe() {
    local conf="$LE_RENEWAL_ROOT/${BASE_DOMAIN}.conf" key expected value mode domains
    [[ -f "$conf" && ! -L "$conf" \
       && "$(path_uid "$conf")" == "$EUID" \
       && "$(path_gid "$conf")" == "$CURRENT_GID" \
       && "$(path_nlink "$conf")" == 1 ]] || return 1
    mode="$(path_mode "$conf")"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || return 1
    for key in archive_dir cert privkey chain fullchain; do
        value="$(renewal_value "$conf" "$key")"
        case "$key" in
            archive_dir) expected="$LE_ARCHIVE_ROOT/$BASE_DOMAIN" ;;
            *) expected="$LE_LIVE_ROOT/$BASE_DOMAIN/${key}.pem" ;;
        esac
        [[ "$value" == "$expected" ]] || return 1
    done
    [[ "$(renewal_value "$conf" server | tr -d '[:space:]')" == "$LE_PRODUCTION_SERVER" \
       && "$(renewal_value "$conf" authenticator | tr -d '[:space:]')" == dns-cloudflare \
       && "$(renewal_value "$conf" dns_cloudflare_credentials | tr -d '[:space:]')" == "$CF_CREDENTIAL" ]] \
        || return 1
    domains="$(renewal_value "$conf" domains | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)" || return 1
    [[ "$domains" == "$(printf '%s\n' "$BASE_DOMAIN" "*.${BASE_DOMAIN}" | sort)" ]] \
        || return 1
    ! grep -Eq '^[[:space:]]*(pre_hook|post_hook|deploy_hook|renew_hook)[[:space:]]*=' "$conf"
}

archive_lineage_safe() {
    local archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN" entry name number stem mode complete path part_key
    local -A generations=()
    local -A generation_parts=()
    local -a entries=()
    canonical_directory "$archive" \
        && [[ "$(path_uid "$archive")" == "$EUID" \
           && "$(path_gid "$archive")" == "$CURRENT_GID" ]] || return 1
    directory_entries "$archive" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^(cert|chain|fullchain|privkey)([1-9][0-9]{0,8})\.pem$ ]] || return 1
        stem="${BASH_REMATCH[1]}"
        number="${BASH_REMATCH[2]}"
        mode=644
        [[ "$stem" != privkey ]] || mode=600
        owned_plain_file "$entry" "$mode" || return 1
        generations["$number"]=1
        generation_parts["${number}:${stem}"]=1
    done
    [[ "${#generations[@]}" -gt 0 ]] || return 1
    [[ "${LIVE_GENERATION:-}" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    for number in "${!generations[@]}"; do
        complete=1
        for stem in cert chain fullchain privkey; do
            part_key="${number}:${stem}"
            [[ -n "${generation_parts[$part_key]+present}" ]] || complete=0
        done
        if [[ "$complete" == 1 ]] && archive_generation_structurally_safe "$number"; then
            continue
        fi
        [[ "$number" != "$LIVE_GENERATION" ]] || return 1
		owned_exact_line_file "$LE_ROOT/$LE_MARKER" 600 "$LE_MARKER_VALUE" \
			|| return 1
        # Certbot writes archive members before switching the four live links.
        # An interrupted, unreferenced partial generation is safe to discard
        # only inside this same-UID marker-owned lineage root.
        for stem in cert chain fullchain privkey; do
            path="$archive/${stem}${number}.pem"
            [[ ! -e "$path" && ! -L "$path" ]] || rm -f -- "$path" || return 1
        done
        fsync_directory "$archive" || return 1
    done
}

live_link_generation() {
    local path="$1" stem="$2" expected_mode="$3" raw prefix number resolved
    [[ -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_nlink "$path")" == 1 ]] || return 1
    raw="$(readlink -- "$path")" || return 1
    prefix="../../archive/${BASE_DOMAIN}/${stem}"
    [[ "$raw" == "$prefix"*.pem ]] || return 1
    number="${raw#"$prefix"}"
    number="${number%.pem}"
    [[ "$number" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    resolved="$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}${number}.pem"
    [[ "$(readlink -f -- "$path" 2>/dev/null || true)" == "$resolved" ]] || return 1
    owned_plain_file "$resolved" "$expected_mode" || return 1
    printf '%s\n' "$number"
}

live_lineage_tree_safe() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" entry name count=0 generation value
    local combined_digest fullchain_digest
    local -a entries=()
    canonical_directory "$live" \
        && [[ "$(path_uid "$live")" == "$EUID" \
           && "$(path_gid "$live")" == "$CURRENT_GID" ]] || return 1
    directory_entries "$live" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            cert.pem|chain.pem|fullchain.pem|privkey.pem) ;;
            *) return 1 ;;
        esac
        ((count += 1))
    done
    [[ "$count" == 4 ]] || return 1
    generation="$(live_link_generation "$live/cert.pem" cert 644)" || return 1
    value="$(live_link_generation "$live/chain.pem" chain 644)" || return 1
    [[ "$value" == "$generation" ]] || return 1
    value="$(live_link_generation "$live/fullchain.pem" fullchain 644)" || return 1
    [[ "$value" == "$generation" ]] || return 1
    value="$(live_link_generation "$live/privkey.pem" privkey 600)" || return 1
    [[ "$value" == "$generation" ]] || return 1
    combined_digest="$(cat "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert${generation}.pem" \
        "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/chain${generation}.pem" | sha256sum)" || return 1
    fullchain_digest="$(sha256sum \
        "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/fullchain${generation}.pem")" || return 1
    [[ "${combined_digest%% *}" == "${fullchain_digest%% *}" ]] || return 1
    LIVE_GENERATION="$generation"
}

keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

cert_chain_trusted() {
    local cert="$1" chain="$2"
    openssl verify -purpose sslserver -CApath /etc/ssl/certs \
        -untrusted "$chain" "$cert" >/dev/null 2>&1 \
        || { [[ -f /etc/ssl/certs/ca-certificates.crt ]] \
             && openssl verify -purpose sslserver \
                    -CAfile /etc/ssl/certs/ca-certificates.crt \
                    -untrusted "$chain" "$cert" >/dev/null 2>&1; } \
        || { [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
             && openssl verify -purpose sslserver \
                    -CAfile /etc/pki/tls/certs/ca-bundle.crt \
                    -untrusted "$chain" "$cert" >/dev/null 2>&1; }
}

cert_chain_structurally_trusted() {
    local cert="$1" chain="$2"
    openssl verify -no_check_time -purpose sslserver -CApath /etc/ssl/certs \
        -untrusted "$chain" "$cert" >/dev/null 2>&1 \
        || { [[ -f /etc/ssl/certs/ca-certificates.crt ]] \
             && openssl verify -no_check_time -purpose sslserver \
                    -CAfile /etc/ssl/certs/ca-certificates.crt \
                    -untrusted "$chain" "$cert" >/dev/null 2>&1; } \
        || { [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
             && openssl verify -no_check_time -purpose sslserver \
                    -CAfile /etc/pki/tls/certs/ca-bundle.crt \
                    -untrusted "$chain" "$cert" >/dev/null 2>&1; }
}

certificate_sans_are_exact() {
    local cert="$1" sans normalized entry dns_sans="" expected
    sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)" || return 1
    normalized="$(printf '%s\n' "$sans" | tail -n +2 | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        [[ "$entry" == DNS:* ]] || return 1
        dns_sans="${dns_sans}${dns_sans:+$'\n'}${entry#DNS:}"
    done <<< "$normalized"
    dns_sans="$(printf '%s\n' "$dns_sans" | sort)"
    expected="$(printf '%s\n' "$BASE_DOMAIN" "*.${BASE_DOMAIN}" | sort)"
    [[ "$dns_sans" == "$expected" ]]
}

validate_role_pair() {
    local cert="$1" key="$2" check_seconds="${3:-0}"
    [[ -s "$cert" && -s "$key" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend "$check_seconds" >/dev/null 2>&1 \
        && certificate_sans_are_exact "$cert" \
        && keypair_matches "$cert" "$key"
}

validate_live_cert_pair() {
    local live="$1" check_seconds="${2:-0}"
    validate_role_pair "$live/fullchain.pem" "$live/privkey.pem" "$check_seconds" \
        && cert_chain_trusted "$live/cert.pem" "$live/chain.pem"
}

archive_generation_structurally_safe() {
    local number="$1" archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    local combined_digest fullchain_digest
    [[ "$number" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    owned_plain_file "$archive/cert${number}.pem" 644 \
        && owned_plain_file "$archive/chain${number}.pem" 644 \
        && owned_plain_file "$archive/fullchain${number}.pem" 644 \
        && owned_plain_file "$archive/privkey${number}.pem" 600 || return 1
    combined_digest="$(cat "$archive/cert${number}.pem" "$archive/chain${number}.pem" \
        | sha256sum)" || return 1
    fullchain_digest="$(sha256sum "$archive/fullchain${number}.pem")" || return 1
    [[ "${combined_digest%% *}" == "${fullchain_digest%% *}" ]] \
        && certificate_sans_are_exact "$archive/cert${number}.pem" \
        && keypair_matches "$archive/cert${number}.pem" "$archive/privkey${number}.pem" \
        && cert_chain_structurally_trusted "$archive/cert${number}.pem" \
            "$archive/chain${number}.pem"
}

scan_complete_archive_generations() {
    local archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN" entry name stem number mode key
    local -A seen=()
    local -A generations=()
    local -a entries=()
    COMPLETE_ARCHIVE_GENERATIONS=()
    canonical_directory "$archive" \
        && [[ "$(path_uid "$archive")" == "$EUID" \
           && "$(path_gid "$archive")" == "$CURRENT_GID" ]] || return 1
    directory_entries "$archive" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^(cert|chain|fullchain|privkey)([1-9][0-9]{0,8})\.pem$ ]] || return 1
        stem="${BASH_REMATCH[1]}"
        number="${BASH_REMATCH[2]}"
        mode=644
        [[ "$stem" != privkey ]] || mode=600
        owned_plain_file "$entry" "$mode" || return 1
        generations["$number"]=1
        seen["${number}:${stem}"]=1
    done
    for number in "${!generations[@]}"; do
        for stem in cert chain fullchain privkey; do
            key="${number}:${stem}"
            [[ -n "${seen[$key]+present}" ]] || continue 2
        done
        if archive_generation_structurally_safe "$number"; then
            COMPLETE_ARCHIVE_GENERATIONS+=("$number")
        fi
    done
    [[ "${#COMPLETE_ARCHIVE_GENERATIONS[@]}" -gt 0 ]]
}

live_repair_link_safe() {
    local path="$1" raw prefix tail
    [[ -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_nlink "$path")" == 1 ]] || return 1
    raw="$(readlink -- "$path")" || return 1
    prefix="../../archive/${BASE_DOMAIN}/"
    [[ "$raw" == "$prefix"* ]] || return 1
    tail="${raw#"$prefix"}"
    [[ "$tail" =~ ^(cert|chain|fullchain|privkey)([1-9][0-9]{0,8})\.pem$ ]]
}

repair_live_links_to_generation() {
    local generation="$1" live="$LE_LIVE_ROOT/$BASE_DOMAIN" entry name stem candidate
    local -a entries=() stems=(cert chain fullchain privkey) candidates=()
    if [[ ! -e "$live" && ! -L "$live" ]]; then
        canonical_directory "$LE_LIVE_ROOT" \
            && [[ "$(path_uid "$LE_LIVE_ROOT")" == "$EUID" \
               && "$(path_gid "$LE_LIVE_ROOT")" == "$CURRENT_GID" ]] || return 1
        mkdir -- "$live" && chmod 0700 "$live" || return 1
    fi
    canonical_directory "$live" \
        && [[ "$(path_uid "$live")" == "$EUID" \
           && "$(path_gid "$live")" == "$CURRENT_GID" ]] || return 1
    directory_entries "$live" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            cert.pem|chain.pem|fullchain.pem|privkey.pem)
                live_repair_link_safe "$entry" || return 1 ;;
            .repair.*)
                live_repair_link_safe "$entry" || return 1
                rm -f -- "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done
    for stem in "${stems[@]}"; do
        candidate="$live/.repair.${stem}.${BASHPID}.${RANDOM}"
        ln -s -- "../../archive/${BASE_DOMAIN}/${stem}${generation}.pem" "$candidate" \
            || return 1
        live_repair_link_safe "$candidate" || return 1
        candidates+=("$candidate")
    done
    for stem in "${!stems[@]}"; do
        mv -Tf -- "${candidates[$stem]}" "$live/${stems[$stem]}.pem" || return 1
    done
    fsync_directory "$live" || return 1
    live_lineage_tree_safe
}

recover_live_lineage() {
    local current_ok=0 generation best=0
    live_lineage_tree_safe && current_ok=1
    scan_complete_archive_generations || return 1
    for generation in "${COMPLETE_ARCHIVE_GENERATIONS[@]}"; do
        if (( 10#$generation > best )); then
            best=$((10#$generation))
        fi
    done
    (( best > 0 )) || return 1
    if [[ "$current_ok" == 1 && "$LIVE_GENERATION" == "$best" ]]; then
        return 0
    fi
    repair_live_links_to_generation "$best"
}

unpublished_partial_lineage_is_safe() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    local conf="$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" entry name stem mode
    local -a entries=()
    ! lineage_ready_exists || return 1
    lineage_set_is_exclusive || return 1
    if [[ -e "$LE_ROOT/$LINEAGE_READY_CANDIDATE" \
       || -L "$LE_ROOT/$LINEAGE_READY_CANDIDATE" ]]; then
        owned_plain_file "$LE_ROOT/$LINEAGE_READY_CANDIDATE" 600 || return 1
    fi
    [[ ! -e "$CERT_ROOT/dot/current" && ! -L "$CERT_ROOT/dot/current" \
       && ! -e "$CERT_ROOT/console/current" && ! -L "$CERT_ROOT/console/current" ]] \
        || return 1
    owned_exact_line_file "$LE_ROOT/$LE_MARKER" 600 "$LE_MARKER_VALUE" || return 1
    if [[ -e "$archive" || -L "$archive" ]]; then
        canonical_directory "$archive" \
            && [[ "$(path_uid "$archive")" == "$EUID" \
               && "$(path_gid "$archive")" == "$CURRENT_GID" ]] || return 1
        directory_entries "$archive" entries || return 1
        for entry in "${entries[@]}"; do
            name="$(basename -- "$entry")"
            [[ "$name" =~ ^(cert|chain|fullchain|privkey)([1-9][0-9]{0,8})\.pem$ ]] || return 1
            stem="${BASH_REMATCH[1]}"
            mode=644
            [[ "$stem" != privkey ]] || mode=600
            owned_plain_file "$entry" "$mode" || return 1
        done
    fi
    if [[ -e "$live" || -L "$live" ]]; then
        canonical_directory "$live" \
            && [[ "$(path_uid "$live")" == "$EUID" \
               && "$(path_gid "$live")" == "$CURRENT_GID" ]] || return 1
        directory_entries "$live" entries || return 1
        for entry in "${entries[@]}"; do
            case "$(basename -- "$entry")" in
                cert.pem|chain.pem|fullchain.pem|privkey.pem|.repair.*)
                    live_repair_link_safe "$entry" || return 1 ;;
                *) return 1 ;;
            esac
        done
    fi
    if [[ -e "$conf" || -L "$conf" ]]; then
        [[ -f "$conf" && ! -L "$conf" \
           && "$(path_uid "$conf")" == "$EUID" \
           && "$(path_gid "$conf")" == "$CURRENT_GID" \
           && "$(path_nlink "$conf")" == 1 ]] || return 1
        mode="$(path_mode "$conf")"
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || return 1
    fi
}

ready_lineage_is_recoverable_read_only() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    local generation best=0 entry
    local -a entries=()
    lineage_ready_safe \
        && lineage_set_is_exclusive \
        && renewal_conf_safe \
        && archive_lineage_safe \
        || return 1
    scan_complete_archive_generations || return 1
    for generation in "${COMPLETE_ARCHIVE_GENERATIONS[@]}"; do
        (( 10#$generation > best )) && best=$((10#$generation))
    done
    (( best > 0 )) || return 1
    validate_role_pair "$archive/fullchain${best}.pem" "$archive/privkey${best}.pem" 0 \
        && cert_chain_structurally_trusted "$archive/cert${best}.pem" "$archive/chain${best}.pem" \
        || return 1
    if [[ -e "$live" || -L "$live" ]]; then
        canonical_directory "$live" \
            && [[ "$(path_uid "$live")" == "$EUID" \
               && "$(path_gid "$live")" == "$CURRENT_GID" ]] || return 1
        directory_entries "$live" entries || return 1
        for entry in "${entries[@]}"; do
            case "$(basename -- "$entry")" in
                cert.pem|chain.pem|fullchain.pem|privkey.pem|.repair.*)
                    live_repair_link_safe "$entry" || return 1 ;;
                *) return 1 ;;
            esac
        done
    else
        canonical_directory "$LE_LIVE_ROOT" \
            && [[ "$(path_uid "$LE_LIVE_ROOT")" == "$EUID" \
               && "$(path_gid "$LE_LIVE_ROOT")" == "$CURRENT_GID" ]] || return 1
    fi
}

preflight_public_certificate_state() {
    ensure_layout || return 1
    load_cert_role_helpers || return 1
    cert_role_ctl_tree_is_recoverable || return 1
    if lineage_ready_exists; then
        ready_lineage_is_recoverable_read_only
    else
        unpublished_partial_lineage_is_safe
    fi
}

reset_unpublished_partial_lineage() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" archive="$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    local conf="$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" entry name stem mode
    local -a live_entries=() archive_entries=()
    ! lineage_ready_exists || return 1
    if [[ -e "$LE_ROOT/$LINEAGE_READY_CANDIDATE" \
       || -L "$LE_ROOT/$LINEAGE_READY_CANDIDATE" ]]; then
        owned_plain_file "$LE_ROOT/$LINEAGE_READY_CANDIDATE" 600 || return 1
        rm -f -- "$LE_ROOT/$LINEAGE_READY_CANDIDATE" || return 1
    fi
    [[ ! -e "$CERT_ROOT/dot/current" && ! -L "$CERT_ROOT/dot/current" \
       && ! -e "$CERT_ROOT/console/current" && ! -L "$CERT_ROOT/console/current" ]] \
        || return 1
	owned_exact_line_file "$LE_ROOT/$LE_MARKER" 600 "$LE_MARKER_VALUE" \
		|| return 1
    if [[ -e "$archive" || -L "$archive" ]]; then
        canonical_directory "$archive" \
            && [[ "$(path_uid "$archive")" == "$EUID" \
               && "$(path_gid "$archive")" == "$CURRENT_GID" ]] || return 1
        directory_entries "$archive" archive_entries || return 1
        for entry in "${archive_entries[@]}"; do
            name="$(basename -- "$entry")"
            [[ "$name" =~ ^(cert|chain|fullchain|privkey)([1-9][0-9]{0,8})\.pem$ ]] || return 1
            stem="${BASH_REMATCH[1]}"
            mode=644
            [[ "$stem" != privkey ]] || mode=600
            owned_plain_file "$entry" "$mode" || return 1
        done
    fi
    if [[ -e "$live" || -L "$live" ]]; then
        canonical_directory "$live" \
            && [[ "$(path_uid "$live")" == "$EUID" \
               && "$(path_gid "$live")" == "$CURRENT_GID" ]] || return 1
        directory_entries "$live" live_entries || return 1
        for entry in "${live_entries[@]}"; do
            name="$(basename -- "$entry")"
            case "$name" in
                cert.pem|chain.pem|fullchain.pem|privkey.pem|.repair.*)
                    live_repair_link_safe "$entry" || return 1 ;;
                *) return 1 ;;
            esac
        done
    fi
    if [[ -e "$conf" || -L "$conf" ]]; then
        [[ -f "$conf" && ! -L "$conf" \
           && "$(path_uid "$conf")" == "$EUID" \
           && "$(path_gid "$conf")" == "$CURRENT_GID" \
           && "$(path_nlink "$conf")" == 1 ]] || return 1
        mode="$(path_mode "$conf")"
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || return 1
    fi
    for entry in "${live_entries[@]}"; do rm -f -- "$entry" || return 1; done
    [[ ! -d "$live" ]] || rmdir -- "$live" || return 1
    for entry in "${archive_entries[@]}"; do rm -f -- "$entry" || return 1; done
    [[ ! -d "$archive" ]] || rmdir -- "$archive" || return 1
    [[ ! -e "$conf" && ! -L "$conf" ]] || rm -f -- "$conf" || return 1
    [[ ! -d "$LE_LIVE_ROOT" ]] || fsync_directory "$LE_LIVE_ROOT" || return 1
    [[ ! -d "$LE_ARCHIVE_ROOT" ]] || fsync_directory "$LE_ARCHIVE_ROOT" || return 1
    [[ ! -d "$LE_RENEWAL_ROOT" ]] || fsync_directory "$LE_RENEWAL_ROOT" || return 1
}

live_lineage_safe() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN"
    lineage_set_is_exclusive \
        && renewal_conf_safe \
        && recover_live_lineage \
        && archive_lineage_safe \
        && validate_live_cert_pair "$live" 0
}

lineage_artifacts_exist() {
    [[ -e "$LE_LIVE_ROOT/$BASE_DOMAIN" || -L "$LE_LIVE_ROOT/$BASE_DOMAIN" \
       || -e "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" || -L "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" \
       || -e "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" || -L "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" ]]
}

lineage_ready_exists() {
    [[ -e "$LE_ROOT/$LINEAGE_READY_MARKER" || -L "$LE_ROOT/$LINEAGE_READY_MARKER" ]]
}

lineage_ready_safe() {
	owned_exact_line_file "$LE_ROOT/$LINEAGE_READY_MARKER" 600 \
		"${LINEAGE_READY_VALUE_PREFIX}:${BASE_DOMAIN}"
}

commit_lineage_ready() {
    local candidate="$LE_ROOT/$LINEAGE_READY_CANDIDATE"
    if lineage_ready_exists; then
        lineage_ready_safe
        return
    fi
    if [[ -e "$candidate" || -L "$candidate" ]]; then
        owned_plain_file "$candidate" 600 || return 1
        rm -f -- "$candidate" || return 1
    fi
    printf '%s\n' "${LINEAGE_READY_VALUE_PREFIX}:${BASE_DOMAIN}" > "$candidate" || return 1
    chmod 0600 "$candidate" \
        && owned_plain_file "$candidate" 600 \
        && fsync_file "$candidate" \
        && mv -Tf -- "$candidate" "$LE_ROOT/$LINEAGE_READY_MARKER" \
        && fsync_directory "$LE_ROOT" \
        && lineage_ready_safe
}

lineage_structure_safe() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN"
    lineage_set_is_exclusive \
        && renewal_conf_safe \
        && recover_live_lineage \
        && archive_lineage_safe \
        && openssl x509 -in "$live/fullchain.pem" -noout >/dev/null 2>&1 \
        && certificate_sans_are_exact "$live/fullchain.pem" \
        && keypair_matches "$live/fullchain.pem" "$live/privkey.pem" \
        && cert_chain_structurally_trusted "$live/cert.pem" "$live/chain.pem"
}

roles_match_live() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" role
    cert_role_ctl_validate_current || return 1
    for role in dot console; do
        cmp -s -- "$live/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" \
            && cmp -s -- "$live/privkey.pem" "$CERT_ROOT/$role/current/privkey.pem" \
            || return 1
    done
}

load_cert_role_helpers() {
    local helper mode
    [[ "$CERT_ROLE_HELPERS_LOADED" == 0 ]] || return 0
    for helper in "$PUBLICATION_FS_HELPER" "$CERT_ROLE_HELPER"; do
        [[ -f "$helper" && ! -L "$helper" && "$(path_nlink "$helper")" == 1 ]] || return 1
        if [[ "$helper" == /opt/5gpn/scripts/* ]]; then
            [[ "$(path_uid "$helper")" == 0 \
               && "$(path_gid "$helper")" == 0 \
               && "$(path_mode "$helper")" == 755 ]] || return 1
        else
            mode="$(path_mode "$helper")"
            [[ "${DOCKER_PUBLIC_CERT_LIB_ONLY:-0}" == 1 \
               && "${BASH_SOURCE[0]}" != "$0" \
               && "$(path_uid "$helper")" == "$EUID" \
               && "$(path_gid "$helper")" == "$CURRENT_GID" \
               && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
        # shellcheck source=/dev/null
        source "$helper" || return 1
    done
    [[ "${CERT_ROLE_CTL_API_VERSION:-0}" == 1 ]] \
        && declare -F cert_role_ctl_publish_pair >/dev/null 2>&1 \
        || return 1
    CERT_ROLE_CTL_ROOT="$CERT_ROOT"
    CERT_ROLE_CTL_CONFIG_MARKER=.5gpn-owned
    CERT_ROLE_CTL_CONFIG_MARKER_VALUE=5gpn-config
    CERT_ROLE_CTL_ROOT_MARKER="$CERT_ROOT_MARKER"
    CERT_ROLE_CTL_ROOT_MARKER_VALUE="$CERT_ROOT_MARKER_VALUE"
    CERT_ROLE_CTL_ROLE_MARKER="$CERT_ROLE_MARKER"
    CERT_ROLE_CTL_ROLE_VALUE_PREFIX="$CERT_ROLE_VALUE_PREFIX"
    CERT_ROLE_CTL_SERVICE_GROUP=fivegpn
    CERT_ROLE_CTL_SERVICE_GID="$CURRENT_GID"
    CERT_ROLE_CTL_ALLOW_CREATE=0
    CERT_ROLE_CTL_ADDITIONAL_GIDS=""
    if [[ "$CERT_ROOT" == /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
        CERT_ROLE_CTL_CONTAINER_MODE=1
        CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
    else
        [[ "${DOCKER_PUBLIC_CERT_LIB_ONLY:-0}" == 1 \
           && "${BASH_SOURCE[0]}" != "$0" ]] || return 1
        case "$CERT_ROOT" in /tmp/5gpn-*|/var/tmp/5gpn-*) ;; *) return 1 ;; esac
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
        CERT_ROLE_CTL_CONTAINER_MODE=0
        CERT_ROLE_CTL_STAGE_PARENT="$(dirname -- "$CERT_ROOT")/.cert-role-staging"
    fi
    CERT_ROLE_HELPERS_LOADED=1
}

validate_shared_role_candidate() {
    local cert="$1" key="$2" role="$3"
    [[ "$role" == dot || "$role" == console ]] \
        && validate_role_pair "$cert" "$key" 0
}

publish_roles() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN"
    _ROLES_CHANGED=0
    validate_live_cert_pair "$live" 0 || return 1
    load_cert_role_helpers || return 1
    cert_role_ctl_tree_is_recoverable \
        && cert_role_ctl_repair_recoverable_tree \
        && cert_role_ctl_scrub_source_snapshots \
        || { err "The certificate-role tree is not safely recoverable."; return 1; }
    if roles_match_live && cert_role_ctl_validate_current; then
        publication_fs_sync_path "$CERT_ROOT/dot" \
            && publication_fs_sync_path "$CERT_ROOT/console" \
            && publication_fs_sync_path "$CERT_ROOT" \
            || { err "Could not repair certificate-role pointer durability."; return 1; }
        local role
        for role in dot console; do
            cert_role_ctl_gc_role "$role" \
                || warn "Certificate-role stale-generation cleanup needs a later retry."
        done
        return 0
    fi
    if ! cert_role_ctl_publish_pair "$live/fullchain.pem" "$live/privkey.pem" \
            validate_shared_role_candidate; then
        err "Certificate-role publication state: ${CERT_ROLE_CTL_COMMIT_STATE:-unknown}."
        [[ -z "${CERT_ROLE_CTL_LAST_ERROR:-}" ]] \
            || err "Certificate-role publisher: ${CERT_ROLE_CTL_LAST_ERROR}."
        return 1
    fi
    roles_match_live && cert_role_ctl_validate_current || return 1
    [[ "${CERT_ROLE_CTL_GC_WARNING:-0}" == 0 ]] \
        || warn "Public certificate roles are live, but post-commit cleanup needs a later retry."
    _ROLES_CHANGED=1
}

component_value() {
    local key="$1" value count
    [[ -f "$COMPONENT_MANIFEST" && ! -L "$COMPONENT_MANIFEST" \
       && "$(path_uid "$COMPONENT_MANIFEST")" == 0 \
       && "$(path_gid "$COMPONENT_MANIFEST")" == 0 \
       && "$(path_mode "$COMPONENT_MANIFEST")" == 644 \
       && "$(path_nlink "$COMPONENT_MANIFEST")" == 1 ]] || return 1
    count="$(grep -c "^${key}=" "$COMPONENT_MANIFEST" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    value="$(sed -n "s/^${key}=//p" "$COMPONENT_MANIFEST")"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    printf '%s' "$value"
}

load_ui_generation_helper() {
    [[ "$UI_HELPER_LOADED" == 0 ]] || return 0
    [[ -f "$UI_GENERATION_HELPER" && ! -L "$UI_GENERATION_HELPER" \
       && "$(path_uid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_gid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_mode "$UI_GENERATION_HELPER")" == 755 \
       && "$(path_nlink "$UI_GENERATION_HELPER")" == 1 ]] || return 1
    # shellcheck source=/dev/null
    source "$UI_GENERATION_HELPER" || return 1
    declare -F ui_generation_stage_tree >/dev/null 2>&1 \
        && declare -F ui_generation_clone_current >/dev/null 2>&1 \
        && declare -F ui_generation_publish >/dev/null 2>&1 \
        || return 1
    UI_HELPER_LOADED=1
}

profile_manifest_value() {
    local manifest="$1" key="$2" count value
    count="$(grep -c "^${key}=" "$manifest" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    value="$(sed -n "s/^${key}=//p" "$manifest")"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    printf '%s' "$value"
}

profiles_match_live_inputs() {
    local current="$1" manifest="$1/.5gpn-profile-inputs"
    local leaf_digest public_key_digest ca_digest
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    leaf_digest="$(openssl x509 -in "$CERT_ROOT/dot/current/fullchain.pem" -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    public_key_digest="$(openssl x509 -in "$CERT_ROOT/dot/current/fullchain.pem" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    ca_digest="$(openssl x509 -in /etc/5gpn/intercept-ca/root.crt -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    [[ "$leaf_digest" =~ ^[0-9a-f]{64}$ \
       && "$public_key_digest" =~ ^[0-9a-f]{64}$ \
       && "$ca_digest" =~ ^[0-9a-f]{64}$ \
       && "$(profile_manifest_value "$manifest" version)" == 1 \
       && "$(profile_manifest_value "$manifest" dot_signer_leaf_sha256)" == "$leaf_digest" \
       && "$(profile_manifest_value "$manifest" dot_public_key_sha256)" == "$public_key_digest" \
       && "$(profile_manifest_value "$manifest" intercept_ca_der_sha256)" == "$ca_digest" \
       && "$(profile_manifest_value "$manifest" domain)" == "$DOT_DOMAIN" \
       && "$(profile_manifest_value "$manifest" gateway_ipv4)" == "$GATEWAY_IP" ]]
}

scrub_profile_stages() {
    local entry name stage_file stage_name marker_seen=0 marker_exact=0 mode size
    local -a root_entries=() stage_entries=()
    directory_entries /run/5gpn root_entries || return 1
    for entry in "${root_entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^\.ios-profile\.[0-9A-Za-z]{6}$ ]] || continue
        canonical_directory "$entry" \
            && [[ "$(path_uid "$entry")" == "$EUID" \
               && "$(path_gid "$entry")" == "$CURRENT_GID" \
               && "$(path_mode "$entry")" == 700 ]] || return 1
        directory_entries "$entry" stage_entries || return 1
        marker_seen=0
        marker_exact=0
        for stage_file in "${stage_entries[@]}"; do
            stage_name="$(basename -- "$stage_file")"
            case "$stage_name" in
                .5gpn-profile-stage) marker_seen=1 ;;
                ios-dot.mobileconfig|ios-dot.mobileconfig.unsigned|ios-dot.mobileconfig.verified|\
                ios-intercept-ca.mobileconfig|ios-intercept-ca.mobileconfig.unsigned|\
                ios-intercept-ca.mobileconfig.verified|signing-chain.pem|intercept-ca.der|\
                .5gpn-profile-inputs|signing-fullchain.pem|signing-privkey.pem|\
                signing-intercept-ca.crt) ;;
                *) return 1 ;;
            esac
            [[ -f "$stage_file" && ! -L "$stage_file" \
               && "$(path_uid "$stage_file")" == "$EUID" \
               && "$(path_gid "$stage_file")" == "$CURRENT_GID" \
               && "$(path_nlink "$stage_file")" == 1 ]] || return 1
            mode="$(path_mode "$stage_file")"
            size="$(path_size "$stage_file")"
            [[ ( "$mode" == 600 || "$mode" == 644 ) \
               && "$size" =~ ^[0-9]+$ && "$size" -le 16777216 ]] || return 1
        done
        if (( marker_seen == 1 )); then
            owned_exact_line_file "$entry/.5gpn-profile-stage" 600 5gpn-profile-stage-v1 \
                && marker_exact=1 || true
            if (( marker_exact == 0 && ${#stage_entries[@]} != 1 )); then
                return 1
            fi
        elif ((${#stage_entries[@]} != 0)); then
            return 1
        fi
        for stage_file in "${stage_entries[@]}"; do rm -f -- "$stage_file" || return 1; done
        rmdir -- "$entry" || return 1
        sync -f /run/5gpn || return 1
    done
}

publish_profiles() {
    local candidate current version current_version=""
    load_ui_generation_helper \
        || { err "The immutable UI generation helper is unavailable."; return 1; }
    scrub_profile_stages \
        || { err "Private profile-signing scratch is not safely recoverable."; return 1; }
    [[ -x "$IOSGEN" ]] || { err "The iOS profile generator is unavailable."; return 1; }
    version="$(component_value ZASH_VERSION)" \
        || { err "The image does not identify its pinned Console release."; return 1; }
    [[ -d "$UI_SOURCE" && ! -L "$UI_SOURCE" \
       && -f "$UI_SOURCE/index.html" && ! -L "$UI_SOURCE/index.html" ]] \
        || { err "The image Console source is missing or unsafe."; return 1; }
    ui_generation_claim_root "$UI_DIR" \
        && ui_generation_cleanup_orphan_candidates "$UI_DIR" \
        || { err "The Console generation volume is not safely recoverable."; return 1; }

    if ui_generation_prepare_existing_current "$UI_DIR"; then
        current="$(ui_generation_current_path "$UI_DIR")" || return 1
        if [[ -f "$current/.zash_version" && ! -L "$current/.zash_version" ]]; then
            IFS= read -r current_version < "$current/.zash_version" || return 1
        fi
    fi
    if [[ "${FORCE_PROFILE_REFRESH:-0}" == 0 \
       && "$current_version" == "$version" ]] \
       && profiles_match_live_inputs "$current"; then
        sync -f "$current" \
            && sync -f "$UI_DIR/generations" \
            && sync -f "$UI_DIR" \
            || { err "Could not repair Console current-pointer durability."; return 1; }
        return 0
    fi
    if [[ "$current_version" == "$version" ]]; then
        candidate="$(ui_generation_clone_current "$UI_DIR")" \
            || { err "Could not clone the current Console generation."; return 1; }
    else
        candidate="$(ui_generation_stage_tree "$UI_DIR" "$UI_SOURCE" "$version")" \
            || { err "Could not stage the pinned Console generation."; return 1; }
    fi
    if ! bash "$IOSGEN" "$DOT_DOMAIN" "$GATEWAY_IP" "$candidate"; then
        ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true
        return 1
    fi
    if ! ui_generation_publish "$UI_DIR" "$candidate"; then
        err "Console-generation publication state: ${UI_GENERATION_COMMIT_STATE:-unknown}."
        [[ "${UI_GENERATION_COMMIT_STATE:-not-committed}" == committed* ]] \
            || ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true
        return 1
    fi
    [[ "${UI_GENERATION_GC_WARNING:-0}" == 0 ]] \
        || warn "The new Console generation is active, but stale-generation cleanup needs a later retry."
    ui_generation_prepare_existing_current "$UI_DIR"
}

ensure_lock() {
    local lock_dir fd_identity file_identity
    command -v flock >/dev/null 2>&1 || return 1
    lock_dir="$(dirname -- "$LOCK_FILE")"
    owned_directory "$lock_dir" 700 || return 1
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        owned_plain_file "$LOCK_FILE" 600 || return 1
    fi
    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" || { exec 9>&-; return 1; }
    owned_plain_file "$LOCK_FILE" 600 || { exec 9>&-; return 1; }
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/9" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$LOCK_FILE" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]] \
        || { exec 9>&-; return 1; }
    flock -w 10 9
}

run_certbot_bootstrap() {
    local force="$1"
    local -a args=(certonly
        --config-dir "$LE_ROOT"
        --work-dir "$LE_WORK_ROOT"
        --logs-dir "$LE_LOG_ROOT"
        --server "$LE_PRODUCTION_SERVER"
        --cert-name "$BASE_DOMAIN"
        --agree-tos
        --non-interactive
        --no-eff-email
        --email "$CERT_EMAIL"
        --dns-cloudflare
        --dns-cloudflare-credentials "$CF_CREDENTIAL"
        --dns-cloudflare-propagation-seconds "$CF_PROPAGATION_SECONDS"
        --no-directory-hooks
        -d "$BASE_DOMAIN"
        -d "*.${BASE_DOMAIN}")
    if [[ "$force" == 1 ]]; then
        args+=(--force-renewal --renew-with-new-domains)
    else
        args+=(--keep-until-expiring)
    fi
    certbot "${args[@]}"
}

run_certbot_renew() {
    certbot renew \
        --config-dir "$LE_ROOT" \
        --work-dir "$LE_WORK_ROOT" \
        --logs-dir "$LE_LOG_ROOT" \
        --cert-name "$BASE_DOMAIN" \
        --non-interactive \
        --no-directory-hooks
}

bootstrap_public_certificate() {
    local force=0 ready=0
    FORCE_PROFILE_REFRESH=0
    ensure_layout && credential_safe && lineage_set_is_exclusive \
        || { err "Docker certificate configuration or persistent state is unsafe."; return 1; }
    if lineage_ready_exists; then
        lineage_ready_safe \
            || { err "The committed Docker lineage marker is unsafe or names another base."; return 1; }
        ready=1
    fi
    if ! live_lineage_safe; then
        if lineage_artifacts_exist; then
            if lineage_structure_safe; then
                force=1
            elif [[ "$ready" == 0 ]] && reset_unpublished_partial_lineage; then
                info "Removed a safe unpublished partial first-boot Certbot lineage."
            else
                err "Existing Certbot lineage state is incomplete or unsafe."
                return 1
            fi
        elif [[ "$ready" == 1 ]]; then
            err "The committed Docker lineage is missing; refusing silent replacement."
            return 1
        fi
        info "Obtaining the single Cloudflare DNS-01 lineage for ${BASE_DOMAIN}."
        run_certbot_bootstrap "$force" \
            || { err "Cloudflare DNS-01 certificate issuance failed transiently."; return 75; }
    fi
    live_lineage_safe \
        || { err "The issued lineage failed its exact SAN, key, or provenance checks."; return 1; }
    commit_lineage_ready \
        || { err "Could not commit the Docker lineage ready marker."; return 1; }
    publish_roles || { err "Could not publish the dot and console certificate roles."; return 1; }
    publish_profiles || { err "Could not publish signed iOS profiles."; return 1; }
    ok "Public certificate roles and signed profiles are current."
}

renew_public_certificate() {
    local cert="$LE_LIVE_ROOT/$BASE_DOMAIN/fullchain.pem"
    # A prior run may have published a renewed role pair and then failed while
    # The generation helper validates profile bytes and their bound input
    # manifest. Unchanged inputs remain byte-stable; any drift stages and signs
    # one complete replacement generation.
    FORCE_PROFILE_REFRESH=0
    ensure_layout && credential_safe && lineage_ready_safe && lineage_structure_safe \
        || { err "The single Cloudflare lineage is missing or unsafe."; return 1; }
    if ! openssl x509 -in "$cert" -noout -checkend "$RENEW_BEFORE_SECONDS" >/dev/null 2>&1; then
        info "The public certificate is due; running the scoped Cloudflare renewal."
        run_certbot_renew || { err "Scoped Cloudflare DNS-01 renewal failed."; return 1; }
        openssl x509 -in "$cert" -noout -checkend "$RENEW_BEFORE_SECONDS" >/dev/null 2>&1 \
            || { err "Certbot returned without a fresh valid exact-SAN lineage."; return 1; }
    fi
    live_lineage_safe \
        || { err "The current public lineage failed validity or system trust verification."; return 1; }
    publish_roles || { err "Could not repair or update the public certificate roles."; return 1; }
    publish_profiles || { err "Could not re-sign the iOS profiles."; return 1; }
    ok "Scoped public certificate renewal check completed."
}

main() {
    [[ $# == 1 ]] || { err "Usage: $0 preflight|bootstrap|renew"; return 2; }
    [[ "$EUID" == "$EXPECTED_UID" && "$CURRENT_GID" == "$EXPECTED_GID" ]] \
        || { err "Docker certificate helpers require fixed UID:GID 10001:10001."; return 1; }
	for command in certbot openssl flock sha256sum sync find sort cmp grep sed; do
        command -v "$command" >/dev/null 2>&1 \
            || { err "Required certificate tool is unavailable: $command"; return 1; }
    done
    load_configuration \
        || { err "The fixed Docker bootstrap configuration is missing or invalid."; return 1; }
    ensure_lock || { err "Another certificate operation is running or the lock is unsafe."; return 1; }
    case "$1" in
        preflight) preflight_public_certificate_state ;;
        bootstrap) bootstrap_public_certificate ;;
        renew) renew_public_certificate ;;
        *) err "Usage: $0 preflight|bootstrap|renew"; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
