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
export HOME TMPDIR
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
IOSGEN=/opt/5gpn/scripts/gen-ios-profile.sh
LOCK_FILE=/run/5gpn/cert-renew.lock
LE_PRODUCTION_SERVER=https://acme-v02.api.letsencrypt.org/directory
RENEW_BEFORE_SECONDS=$((30 * 86400))
CF_PROPAGATION_SECONDS=30
CERT_ROOT_MARKER=.5gpn-docker-cert-root-owned
CERT_ROOT_MARKER_VALUE=5gpn-docker-cert-root-v1
CERT_ROLE_MARKER=.5gpn-docker-cert-role-owned
CERT_ROLE_VALUE_PREFIX=5gpn-docker-cert-role-v1
LE_MARKER=.5gpn-docker-letsencrypt-owned
LE_MARKER_VALUE=5gpn-docker-letsencrypt-v1
LINEAGE_READY_MARKER=.5gpn-docker-lineage-ready
LINEAGE_READY_VALUE_PREFIX=5gpn-docker-lineage-ready-v1
LINEAGE_READY_CANDIDATE=.5gpn-docker-lineage-ready.new
UI_MARKER=.5gpn-zashboard-owned
UI_MARKER_VALUE=5gpn-zashboard
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

ensure_owned_directory() {
	local path="$1" mode="$2" parent actual_mode
	local -a entries=()
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		parent="$(dirname -- "$path")"
        canonical_directory "$parent" \
            && [[ "$(path_uid "$parent")" == "$EUID" \
               && "$(path_gid "$parent")" == "$CURRENT_GID" ]] \
            || return 1
		mkdir -m "$mode" -- "$path" || return 1
		fsync_directory "$parent" || return 1
	fi
	if owned_directory "$path" "$mode"; then
		return 0
	fi
	# A SIGKILL inside mkdir -m can leave only the umask-restricted 0700
	# directory. Repair that one empty, same-identity state; never broaden a
	# populated or otherwise unexpected directory.
	if [[ "$mode" == 750 ]] && canonical_directory "$path" \
	   && [[ "$(path_uid "$path")" == "$EUID" \
	      && "$(path_gid "$path")" == "$CURRENT_GID" ]]; then
		actual_mode="$(path_mode "$path")"
		directory_entries "$path" entries || return 1
		if [[ "$actual_mode" == 700 && "${#entries[@]}" == 0 ]]; then
			chmod 0750 "$path" || return 1
			fsync_directory "$path" || return 1
		fi
	fi
	owned_directory "$path" "$mode"
}

write_marker_if_absent() {
	local dir="$1" name="$2" value="$3" mode="$4" marker candidate entry tmp parent
	local -a entries=()
	marker="$dir/$name"
	candidate="$dir/${name}.candidate"
	if [[ ! -e "$marker" && ! -L "$marker" ]]; then
		directory_entries "$dir" entries || return 1
		for entry in "${entries[@]}"; do
			[[ "$entry" == "$candidate" ]] || return 1
		done
		if [[ -e "$candidate" || -L "$candidate" ]]; then
			owned_exact_line_file "$candidate" "$mode" "$value" || return 1
		else
			parent="$(dirname -- "$dir")"
			tmp="$(mktemp "$parent/.5gpn-marker-stage.XXXXXX")" || return 1
			printf '%s\n' "$value" > "$tmp" \
				|| { rm -f -- "$tmp"; return 1; }
			chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
			owned_plain_file "$tmp" "$mode" \
				|| { rm -f -- "$tmp"; return 1; }
			fsync_file "$tmp" || { rm -f -- "$tmp"; return 1; }
			directory_entries "$dir" entries \
				|| { rm -f -- "$tmp"; return 1; }
			[[ "${#entries[@]}" == 0 ]] \
				|| { rm -f -- "$tmp"; return 1; }
			mv -Tn -- "$tmp" "$candidate" || { rm -f -- "$tmp"; return 1; }
			[[ ! -e "$tmp" && ! -L "$tmp" ]] \
				|| { rm -f -- "$tmp"; return 1; }
			fsync_directory "$dir" || return 1
		fi
		owned_exact_line_file "$candidate" "$mode" "$value" || return 1
		mv -Tn -- "$candidate" "$marker" || return 1
		[[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
		fsync_directory "$dir" || return 1
	fi
	[[ ! -e "$candidate" && ! -L "$candidate" ]] \
		&& owned_exact_line_file "$marker" "$mode" "$value"
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
    ensure_owned_directory "$LE_ROOT" 700 \
        && write_marker_if_absent "$LE_ROOT" "$LE_MARKER" "$LE_MARKER_VALUE" 600 \
        && ensure_owned_directory "$LE_WORK_ROOT" 700 \
        && ensure_owned_directory "$LE_LOG_ROOT" 700 \
        || { err "The persistent Certbot tree is unsafe."; return 1; }
    ensure_owned_directory "$CERT_ROOT" 700 \
        && write_marker_if_absent "$CERT_ROOT" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" 600 \
        || { err "The public certificate role root is unsafe."; return 1; }
    local role
    for role in dot console; do
        ensure_owned_directory "$CERT_ROOT/$role" 750 \
            && write_marker_if_absent "$CERT_ROOT/$role" "$CERT_ROLE_MARKER" \
                "${CERT_ROLE_VALUE_PREFIX}:${role}" 600 \
            && ensure_owned_directory "$CERT_ROOT/$role/generations" 750 \
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

generation_name_safe() {
    [[ "${1:-}" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
}

generation_safe() {
    local path="$1" entry name count=0
    local -a entries=()
    owned_directory "$path" 750 || return 1
    directory_entries "$path" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            fullchain.pem|privkey.pem) owned_plain_file "$entry" 640 || return 1 ;;
            *) return 1 ;;
        esac
        ((count += 1))
    done
    [[ "$count" == 2 ]]
}

role_tree_safe() {
    local role="$1" entry name target
    local root="$CERT_ROOT/$role"
    local -a entries=()
    owned_directory "$root" 750 \
        && write_marker_if_absent "$root" "$CERT_ROLE_MARKER" \
            "${CERT_ROLE_VALUE_PREFIX}:${role}" 600 \
        && owned_directory "$root/generations" 750 \
        || return 1
    directory_entries "$root" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" && "$(path_uid "$entry")" == "$EUID" \
                   && "$(path_gid "$entry")" == "$CURRENT_GID" ]] || return 1
                target="$(readlink -- "$entry")" || return 1
                [[ "$target" == generations/* ]] \
                    && generation_name_safe "${target#generations/}" \
                    && generation_safe "$root/$target" || return 1 ;;
            *) return 1 ;;
        esac
    done
    directory_entries "$root/generations" entries || return 1
    for entry in "${entries[@]}"; do
        generation_name_safe "$(basename -- "$entry")" && generation_safe "$entry" || return 1
    done
}

role_gc_boundary_safe() {
    local role="$1"
    local root="$CERT_ROOT/$role"
    owned_directory "$root" 750 \
		&& owned_exact_line_file "$root/$CERT_ROLE_MARKER" 600 \
			"${CERT_ROLE_VALUE_PREFIX}:${role}" \
        && owned_directory "$root/generations" 750
}

purge_generation_candidate() {
    local role="$1" name="$2" resolved entry entry_name mode current original
    local root="$CERT_ROOT/$role"
    local -a entries=()
    [[ "$name" =~ ^\.new\.[A-Za-z0-9]+$ \
       || "$name" =~ ^\.delete\.generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] \
        || return 1
    role_gc_boundary_safe "$role" || return 1
    if [[ "$name" == .delete.* ]]; then
        original="${name#.delete.}"
        current="$(readlink -- "$root/current" 2>/dev/null || true)"
        [[ "$current" != "generations/$original" ]] || return 1
    fi
    resolved="$(readlink -f -- "$root/generations/$name" 2>/dev/null || true)"
    [[ "$resolved" == "$root/generations/$name" \
       && -d "$resolved" && ! -L "$resolved" \
       && "$(path_uid "$resolved")" == "$EUID" \
       && "$(path_gid "$resolved")" == "$CURRENT_GID" ]] || return 1
    mode="$(path_mode "$resolved")"
    [[ "$mode" == 700 || "$mode" == 750 ]] || return 1
    directory_entries "$resolved" entries || return 1
    for entry in "${entries[@]}"; do
        entry_name="$(basename -- "$entry")"
        case "$entry_name" in
            fullchain.pem|privkey.pem)
                [[ -f "$entry" && ! -L "$entry" \
                   && "$(path_uid "$entry")" == "$EUID" \
                   && "$(path_gid "$entry")" == "$CURRENT_GID" \
                   && "$(path_nlink "$entry")" == 1 \
                   && "$(path_mode "$entry")" == 640 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    for entry in "${entries[@]}"; do rm -f -- "$entry" || return 1; done
    rmdir -- "$resolved" || return 1
    fsync_directory "$root/generations"
}

remove_generation() {
    local role="$1" name="$2" current tombstone
    local root="$CERT_ROOT/$role"
    if [[ "$name" =~ ^\.new\.[A-Za-z0-9]+$ ]]; then
        purge_generation_candidate "$role" "$name"
        return
    fi
    generation_name_safe "$name" || return 1
    role_gc_boundary_safe "$role" || return 1
    current="$(readlink -- "$root/current" 2>/dev/null || true)"
    [[ "$current" != "generations/$name" ]] || return 1
    generation_safe "$root/generations/$name" || return 1
    tombstone=".delete.${name}"
    [[ ! -e "$root/generations/$tombstone" \
       && ! -L "$root/generations/$tombstone" ]] || return 1
    mv -T -- "$root/generations/$name" "$root/generations/$tombstone" \
        && fsync_directory "$root/generations" || return 1
    purge_generation_candidate "$role" "$tombstone"
}

scrub_role_candidates() {
    local role="$1" entry name target
    local root="$CERT_ROOT/$role"
    local -a entries=()
    directory_entries "$root" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations|current) ;;
            .current.*|.rollback.*)
                [[ -L "$entry" && "$(path_uid "$entry")" == "$EUID" \
                   && "$(path_gid "$entry")" == "$CURRENT_GID" ]] || return 1
                target="$(readlink -- "$entry")" || return 1
                [[ "$target" == generations/* ]] || return 1
                generation_name_safe "${target#generations/}" || return 1
                rm -f -- "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done
    directory_entries "$root/generations" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        if [[ "$name" =~ ^\.new\.[A-Za-z0-9]+$ ]]; then
            remove_generation "$role" "$name" || return 1
        elif [[ "$name" =~ ^\.delete\.generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]; then
            purge_generation_candidate "$role" "$name" || return 1
        else
            generation_name_safe "$name" && generation_safe "$entry" || return 1
        fi
    done
}

roles_match_live() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" role
    for role in dot console; do
        role_tree_safe "$role" || return 1
        [[ -L "$CERT_ROOT/$role/current" ]] || return 1
        cmp -s -- "$live/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" \
            && cmp -s -- "$live/privkey.pem" "$CERT_ROOT/$role/current/privkey.pem" \
            || return 1
    done
}

rollback_role_links() {
    local roles_name="$1" old_name="$2" swapped="$3" i role root rollback
    local -n roles_ref="$roles_name" old_ref="$old_name"
    for ((i = swapped - 1; i >= 0; i--)); do
        role="${roles_ref[$i]}"
        root="$CERT_ROOT/$role"
        if [[ -n "${old_ref[$i]}" ]]; then
            rollback="$root/.rollback.${BASHPID}.${RANDOM}"
            ln -s -- "${old_ref[$i]}" "$rollback" \
                && mv -Tf -- "$rollback" "$root/current" || return 1
        else
            rm -f -- "$root/current" || return 1
        fi
    done
}

cleanup_unreferenced_generations() {
    local role="$1" keep entry name
    local root="$CERT_ROOT/$role"
    local -a entries=()
    keep="$(readlink -- "$root/current")" || return 1
    keep="${keep#generations/}"
    generation_name_safe "$keep" || return 1
    directory_entries "$root/generations" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" == "$keep" ]] && continue
        generation_name_safe "$name" || return 1
        generation_safe "$entry" || return 1
        remove_generation "$role" "$name" || return 1
    done
}

publish_roles() {
    local live="$LE_LIVE_ROOT/$BASE_DOMAIN" role root stage final link old i swapped=0
    local -a roles=(dot console) stages=() links=() old_targets=()
    _ROLES_CHANGED=0
    validate_live_cert_pair "$live" 0 || return 1
    for role in "${roles[@]}"; do
        scrub_role_candidates "$role" || return 1
        role_tree_safe "$role" || return 1
    done
    if roles_match_live; then
        return 0
    fi
    for role in "${roles[@]}"; do
        root="$CERT_ROOT/$role"
        old="$(readlink -- "$root/current" 2>/dev/null || true)"
        if [[ -n "$old" ]]; then
            [[ "$old" == generations/* ]] \
                && generation_name_safe "${old#generations/}" \
                && generation_safe "$root/$old" || return 1
        fi
        old_targets+=("$old")
        stage="$(mktemp -d "$root/generations/.new.XXXXXX")" || return 1
        chmod 0750 "$stage" || return 1
        install -m 0640 "$live/fullchain.pem" "$stage/fullchain.pem" \
            && install -m 0640 "$live/privkey.pem" "$stage/privkey.pem" \
            || return 1
        sync -f "$stage/fullchain.pem" && sync -f "$stage/privkey.pem" || return 1
        validate_role_pair "$stage/fullchain.pem" "$stage/privkey.pem" 0 || return 1
        final="$root/generations/generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
        mv -- "$stage" "$final" \
            && fsync_directory "$root/generations" || return 1
        stages+=("$final")
        link="$root/.current.${BASHPID}.${RANDOM}"
        ln -s -- "generations/$(basename -- "$final")" "$link" || return 1
        links+=("$link")
    done
    for i in "${!roles[@]}"; do
        role="${roles[$i]}"
        root="$CERT_ROOT/$role"
        if ! mv -Tf -- "${links[$i]}" "$root/current"; then
            rollback_role_links roles old_targets "$swapped" || true
            return 1
        fi
        swapped=$((swapped + 1))
        sync -f "$root" || return 1
    done
    roles_match_live || return 1
    for role in "${roles[@]}"; do
        cleanup_unreferenced_generations "$role" || return 1
    done
    _ROLES_CHANGED=1
}

ui_tree_safe() {
    owned_directory "$UI_DIR" 755 \
		&& owned_exact_line_file "$UI_DIR/$UI_MARKER" 644 "$UI_MARKER_VALUE"
}

publish_profiles() {
    local profile profiles_current=1
    ui_tree_safe || { err "The writable Console publication tree is unsafe."; return 1; }
    [[ -x "$IOSGEN" ]] || { err "The iOS profile generator is unavailable."; return 1; }
    if [[ "${FORCE_PROFILE_REFRESH:-0}" == 0 && "${_ROLES_CHANGED:-0}" == 0 ]]; then
        for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
            owned_plain_file "$UI_DIR/$profile" 644 || profiles_current=0
        done
        [[ "$profiles_current" == 1 ]] && return 0
    fi
    bash "$IOSGEN" "$DOT_DOMAIN" "$GATEWAY_IP" "$UI_DIR" || return 1
    for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
        owned_plain_file "$UI_DIR/$profile" 644 || return 1
    done
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
    FORCE_PROFILE_REFRESH=1
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
    # the two-profile transaction retained its last-known-good files. Existence
    # and mode cannot prove the profiles were signed by the current role, so a
    # renewal check always retries the bounded atomic profile transaction.
    FORCE_PROFILE_REFRESH=1
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
    [[ $# == 1 ]] || { err "Usage: $0 bootstrap|renew"; return 2; }
    [[ "$EUID" == "$EXPECTED_UID" && "$CURRENT_GID" == "$EXPECTED_GID" ]] \
        || { err "Docker certificate helpers require fixed UID:GID 10001:10001."; return 1; }
	for command in certbot openssl flock sha256sum sync find sort cmp; do
        command -v "$command" >/dev/null 2>&1 \
            || { err "Required certificate tool is unavailable: $command"; return 1; }
    done
    load_configuration \
        || { err "The fixed Docker bootstrap configuration is missing or invalid."; return 1; }
    ensure_lock || { err "Another certificate operation is running or the lock is unsafe."; return 1; }
    case "$1" in
        bootstrap) bootstrap_public_certificate ;;
        renew) renew_public_certificate ;;
        *) err "Usage: $0 bootstrap|renew"; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
