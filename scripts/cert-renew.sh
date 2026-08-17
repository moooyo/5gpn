#!/bin/bash
# Scoped 5gpn certificate renewal entrypoint.
#
# Cloudflare DNS-01 renews without touching mihomo. HTTP-01 first waits until
# every public service name resolves through 1.1.1.1 to DNS_PUBLIC_IP, then
# briefly releases mihomo's TCP :80 listeners for Certbot's standalone server.
# The service is restored after both successful and failed renewal attempts.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Gum-or-echo status helpers. Timer runs have no TTY and stay journal-safe. ---
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "✔ $*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

DNS_ENV=/etc/5gpn/dns.env
LE_LIVE_ROOT=/etc/letsencrypt/live
LE_RENEWAL_ROOT=/etc/letsencrypt/renewal
LE_ARCHIVE_ROOT=/etc/letsencrypt/archive
LE_PRODUCTION_SERVER=https://acme-v02.api.letsencrypt.org/directory
CERT_ROOT=/etc/5gpn/cert
CERTBOT_OWNERSHIP_FILE="$CERT_ROOT/.certbot-ownership"
DEPLOY_HOOK=/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
UI_GENERATION_HELPER=/opt/5gpn/scripts/ui-generation.sh
UI_ROOT=/opt/5gpn/ui
PROFILE_INPUTS_FILE=/opt/5gpn/ui/current/.5gpn-profile-inputs
INTERCEPT_CA=/etc/5gpn/intercept-ca/root.crt
INTERCEPT_CA_ROOT=/etc/5gpn/intercept-ca
INTERCEPT_CA_MARKER=.5gpn-intercept-ca-owned
INTERCEPT_CA_MARKER_VALUE=5gpn-intercept-ca-v1
ACME_DIR=/etc/5gpn/acme
DNS_RESOLVER=1.1.1.1
DNS_WAIT_TIMEOUT=600
DNS_WAIT_INTERVAL=10
RENEW_BEFORE_SECONDS=$((30 * 86400))
MIHOMO_RESTORE_NEEDED=0
RENEW_LOCK_FILE=/run/5gpn/cert-renew.lock
INSTALL_LOCK_FILE=/run/5gpn/install.lock
FIVEGPN_CERT_GROUP=fivegpn
CONFIG_ROOT_MARKER=.5gpn-owned
CONFIG_ROOT_MARKER_VALUE=5gpn-config
CERT_ROOT_MARKER=.5gpn-cert-root-owned
CERT_ROOT_MARKER_VALUE=5gpn-cert-root-v1
CERT_ROLE_MARKER=.5gpn-cert-role-owned
CERT_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
CERT_RENEW_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
CERT_RENEW_SOURCE_DIR="$(cd "$(dirname -- "$CERT_RENEW_SOURCE")" && pwd)"
CERT_ROLE_HELPERS_LOADED=0

cfg_get() {
    [[ -f "$DNS_ENV" && ! -L "$DNS_ENV" ]] || return 0
    grep -E "^${1}=" "$DNS_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

valid_domain() {
    local d="${1:-}"
    [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_ipv4() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ ${#o} -gt 1 && "$o" == 0* ]] && return 1
        [[ "$((10#$o))" -le 255 ]] || return 1
    done
}

file_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
file_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
file_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

path_has_no_nested_mounts() {
    local root="$1" target output
    command -v findmnt >/dev/null 2>&1 || return 1
    output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in "$root"/*) return 1 ;; esac
    done <<< "$output"
}

# Resolve by name but compare numeric IDs so aliases or NSS display behavior
# cannot make a certificate copy appear to belong to the required role group.
# Kept as a helper so tests can provide deterministic synthetic group IDs.
named_group_gid() {
    local entry gid
    entry="$(getent group "$1" 2>/dev/null)" || return 1
    IFS=: read -r _ _ gid _ <<<"$entry"
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

cert_role_ctl_group_gid_override() {
    named_group_gid "$1"
}

cert_renew_bound_helper_state() {
    local path="$1" production="$2" parent metadata digest
    [[ -f "$path" && ! -L "$path" && "$(file_nlink "$path")" == 1 ]] || return 1
    if [[ "$path" == "$production" ]]; then
        parent="$(dirname -- "$production")"
        [[ -d "$parent" && ! -L "$parent" \
           && "$(readlink -f -- "$parent")" == "$parent" \
           && "$(stat -Lc '%u:%g:%a' -- "$parent")" == 0:0:755 \
           && "$(stat -Lc '%u:%g:%a:%h' -- "$path")" == 0:0:755:1 ]] || return 1
    fi
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$path")" || return 1
    digest="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$metadata" "$digest"
}

load_cert_role_helpers() {
    local helper path production before after hash_fd source_fd hash_metadata source_metadata fd_digest
    local -a helpers=(publication-fs.sh cert-role-ctl.sh)
    if [[ "$CERT_ROLE_HELPERS_LOADED" != 1 ]]; then
        for helper in "${helpers[@]}"; do
            production="/opt/5gpn/scripts/$helper"
            if [[ "${CERT_RENEW_LIB_ONLY:-0}" == 1 \
               && -f "$CERT_RENEW_SOURCE_DIR/$helper" && ! -L "$CERT_RENEW_SOURCE_DIR/$helper" ]]; then
                path="$CERT_RENEW_SOURCE_DIR/$helper"
            else
                path="$production"
            fi
            before="$(cert_renew_bound_helper_state "$path" "$production")" || return 1
            exec {hash_fd}<"$path" || return 1
            exec {source_fd}<"$path" || { exec {hash_fd}<&-; return 1; }
            hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            exec {hash_fd}<&-
            [[ "$hash_metadata" == "${before%:*}" \
               && "$source_metadata" == "${before%:*}" \
               && "$fd_digest" == "${before##*:}" ]] \
                || { exec {source_fd}<&-; return 1; }
            # shellcheck source=/dev/null
            source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
            exec {source_fd}<&-
            after="$(cert_renew_bound_helper_state "$path" "$production")" || return 1
            [[ "$after" == "$before" ]] || return 1
        done
        declare -F publication_fs_commit_relative_pointer >/dev/null 2>&1 \
            && [[ "${CERT_ROLE_CTL_API_VERSION:-0}" == 1 ]] || return 1
        CERT_ROLE_HELPERS_LOADED=1
    fi
    CERT_ROLE_CTL_ROOT="$CERT_ROOT"
    CERT_ROLE_CTL_CONFIG_MARKER="$CONFIG_ROOT_MARKER"
    CERT_ROLE_CTL_CONFIG_MARKER_VALUE="$CONFIG_ROOT_MARKER_VALUE"
    CERT_ROLE_CTL_ROOT_MARKER="$CERT_ROOT_MARKER"
    CERT_ROLE_CTL_ROOT_MARKER_VALUE="$CERT_ROOT_MARKER_VALUE"
    CERT_ROLE_CTL_ROLE_MARKER="$CERT_ROLE_MARKER"
    CERT_ROLE_CTL_ROLE_VALUE_PREFIX="$CERT_ROLE_VALUE_PREFIX"
    CERT_ROLE_CTL_SERVICE_GROUP="$FIVEGPN_CERT_GROUP"
    CERT_ROLE_CTL_SERVICE_GID=""
    CERT_ROLE_CTL_ALLOW_CREATE=0
    CERT_ROLE_CTL_ADDITIONAL_GIDS=""
    if [[ "${CERT_RENEW_LIB_ONLY:-0}" == 1 && "$CERT_ROOT" != /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
        CERT_ROLE_CTL_STAGE_PARENT="$(dirname -- "$CERT_ROOT")/.cert-role-staging"
    else
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
        CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
    fi
}

normalized_mode() {
    case "${1:-}" in
        cloudflare) printf '%s\n' cloudflare ;;
        http-01) printf '%s\n' http-01 ;;
        debug) printf '%s\n' debug ;;
        *) return 1 ;;
    esac
}

cert_provenance_selects_owned() {
    local base="$1" mode="$2" file="${CERT_ROOT}/.provenance"
    local -a lines=()
    [[ -f "$file" && ! -L "$file" \
       && "$(file_uid "$file")" == 0 \
       && "$(file_gid "$file")" == 0 \
       && "$(file_mode "$file")" == 640 \
       && "$(file_nlink "$file")" == 1 ]] || return 1
    mapfile -t lines < "$file" || return 1
    [[ "${#lines[@]}" == 3 \
       && "${lines[0]}" == "mode=${mode}" \
       && "${lines[1]}" == "base=${base}" \
       && "${lines[2]}" == 'certbot_lineage=owned' ]]
}

certbot_ownership_record_has() {
    local wanted="$1" file="$CERTBOT_OWNERSHIP_FILE" line base previous="" index
    local -a lines=()
    [[ -f "$file" && ! -L "$file" \
       && "$(file_uid "$file")" == 0 \
       && "$(file_gid "$file")" == 0 \
       && "$(file_mode "$file")" == 640 \
       && "$(file_nlink "$file")" == 1 ]] || return 1
    mapfile -t lines < "$file" || return 1
    [[ "${#lines[@]}" -ge 2 && "${#lines[@]}" -le 17 \
       && "${lines[0]}" == version=1 ]] || return 1
    for ((index = 1; index < ${#lines[@]}; index++)); do
        line="${lines[$index]}"
        [[ "$line" == owned=* ]] || return 1
        base="${line#owned=}"
        valid_domain "$base" || return 1
        [[ -z "$previous" || "$previous" < "$base" ]] || return 1
        previous="$base"
    done
    grep -Fqx -- "owned=${wanted}" "$file"
}

cert_provenance_owned() {
    local base="$1" mode="$2"
    cert_provenance_selects_owned "$base" "$mode" \
        && certbot_ownership_record_has "$base"
}

cf_credential_safe() {
    local credential="${ACME_DIR}/cloudflare.ini"
    [[ -d "$ACME_DIR" && ! -L "$ACME_DIR" \
       && "$(readlink -f -- "$ACME_DIR" 2>/dev/null || true)" == "$ACME_DIR" \
       && "$(file_uid "$ACME_DIR")" == 0 \
       && "$(file_mode "$ACME_DIR")" == 700 \
       && -f "$credential" && ! -L "$credential" \
       && "$(file_uid "$credential")" == 0 \
       && "$(file_mode "$credential")" == 600 ]]
}

renewal_conf_safe() {
    local base="$1" mode="$2"
    local conf="${LE_RENEWAL_ROOT}/${base}.conf"
    local key value expected auth server
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    for key in archive_dir cert privkey chain fullchain; do
        value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null \
            | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$key" in
            archive_dir) expected="${LE_ARCHIVE_ROOT}/${base}" ;;
            *) expected="${LE_LIVE_ROOT}/${base}/${key}.pem" ;;
        esac
        [[ "$value" == "$expected" ]] || return 1
    done
    ! grep -Eq '^[[:space:]]*(pre_hook|post_hook|deploy_hook|renew_hook)[[:space:]]*=[[:space:]]*[^[:space:]]' "$conf" \
        || return 1
    server="$(grep -E '^[[:space:]]*server[[:space:]]*=' "$conf" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    [[ "$server" == "$LE_PRODUCTION_SERVER" ]] || return 1
    auth="$(grep -E '^[[:space:]]*authenticator[[:space:]]*=' "$conf" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    case "$mode" in
        cloudflare)
            [[ "$auth" == dns-cloudflare ]] || return 1
            value="$(grep -E '^[[:space:]]*dns_cloudflare_credentials[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ "$value" == "$ACME_DIR/cloudflare.ini" ]] || return 1
            cf_credential_safe ;;
        http-01)
            [[ "$auth" == standalone ]] || return 1
            value="$(grep -E '^[[:space:]]*http01_port[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ -z "$value" || "$value" == 80 ]] || return 1
            value="$(grep -E '^[[:space:]]*http01_address[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ -z "$value" ]] ;;
        *) return 1 ;;
    esac
}

# http_cert_domains <base> prints the exact HTTP-01 SAN set.
http_cert_domains() {
    local base="$1"
    valid_domain "$base" || return 1
    printf 'console.%s\ndot.%s\n' "$base" "$base"
}

deploy_hook_owned() {
    local parent expected_gid
    [[ -f "$DEPLOY_HOOK" && ! -L "$DEPLOY_HOOK" && -x "$DEPLOY_HOOK" \
       && "$(file_nlink "$DEPLOY_HOOK")" == 1 ]] || return 1
    if [[ "$DEPLOY_HOOK" == /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh ]]; then
        parent="$(dirname -- "$DEPLOY_HOOK")"
        [[ -d "$parent" && ! -L "$parent" \
           && "$(readlink -f -- "$parent")" == "$parent" \
           && "$(stat -Lc '%u:%g' -- "$parent")" == 0:0 ]] || return 1
        mode_has_no_group_or_other_write "$(file_mode "$parent")" || return 1
        [[ "$(stat -Lc '%u:%g:%a:%h' -- "$DEPLOY_HOOK")" == 0:0:755:1 ]] || return 1
    fi
    grep -Fqx '# 5gpn-renew-hook-id: deploy-v1' "$DEPLOY_HOOK" \
        && grep -qF "Let's Encrypt renewal deploy hook" "$DEPLOY_HOOK" \
        && grep -qF 'DNS_BASE_DOMAIN' "$DEPLOY_HOOK" 2>/dev/null \
        && grep -qF '/etc/5gpn/cert' "$DEPLOY_HOOK" 2>/dev/null
}

mode_has_no_group_or_other_write() {
    local mode="$1" value
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    value=$((8#$mode))
    (( (value & 0022) == 0 ))
}

deploy_hook_state() {
    local metadata digest
    deploy_hook_owned || return 1
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$DEPLOY_HOOK")" || return 1
    digest="$(sha256sum -- "$DEPLOY_HOOK" | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$metadata" "$digest"
}

run_bound_deploy_hook() { # <mode:validate|profile|deploy> <live>
    local mode="$1" live="$2" before after hash_fd source_fd hash_metadata source_metadata fd_digest rc=0
    before="$(deploy_hook_state)" || return 1
    exec {hash_fd}<"$DEPLOY_HOOK" || return 1
    exec {source_fd}<"$DEPLOY_HOOK" || { exec {hash_fd}<&-; return 1; }
    hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    exec {hash_fd}<&-
    [[ "$hash_metadata" == "${before%:*}" \
       && "$source_metadata" == "${before%:*}" \
       && "$fd_digest" == "${before##*:}" ]] \
        || { exec {source_fd}<&-; return 1; }
    case "$mode" in
        validate)
            FIVEGPN_CERT_LOCK_HELD=1 RENEW_HOOK_VALIDATE_ONLY=1 \
                RENEWED_LINEAGE="$live" bash "/proc/self/fd/$source_fd" >/dev/null || rc=$? ;;
        profile)
            FIVEGPN_CERT_LOCK_HELD=1 FIVEGPN_PROFILE_ONLY_REFRESH=1 \
                RENEWED_LINEAGE="$live" bash "/proc/self/fd/$source_fd" || rc=$? ;;
        deploy)
            FIVEGPN_CERT_LOCK_HELD=1 RENEWED_LINEAGE="$live" \
                bash "/proc/self/fd/$source_fd" || rc=$? ;;
        *) rc=2 ;;
    esac
    exec {source_fd}<&-
    after="$(deploy_hook_state)" || return 1
    [[ "$after" == "$before" && "$rc" == 0 ]]
}

certificate_role_current_safe() {
    load_cert_role_helpers || return 1
    cert_role_ctl_validate_current
}

role_copies_match_live() {
    local live="$1" role cert key target_before target_after
    certificate_role_current_safe || return 1
    for role in dot console; do
        target_before="$(cert_role_ctl_current_target "$role" 0)" || return 1
        cert="${CERT_ROOT}/${role}/${target_before}/fullchain.pem"
        key="${CERT_ROOT}/${role}/${target_before}/privkey.pem"
        cmp -s "${live}/fullchain.pem" "$cert" || return 1
        cmp -s "${live}/privkey.pem" "$key" || return 1
        target_after="$(cert_role_ctl_current_target "$role" 0)" || return 1
        [[ "$target_after" == "$target_before" ]] || return 1
    done
}

intercept_ca_boundary_is_safe() {
    local marker="$INTERCEPT_CA_ROOT/$INTERCEPT_CA_MARKER"
    local not_before not_before_epoch now_epoch
    path_has_no_nested_mounts "$INTERCEPT_CA_ROOT" || return 1
    [[ -d "$INTERCEPT_CA_ROOT" && ! -L "$INTERCEPT_CA_ROOT" \
       && "$(readlink -f -- "$INTERCEPT_CA_ROOT")" == "$INTERCEPT_CA_ROOT" \
       && "$(file_uid "$INTERCEPT_CA_ROOT")" == 0 \
       && "$(file_gid "$INTERCEPT_CA_ROOT")" == 0 \
       && ( "$(file_mode "$INTERCEPT_CA_ROOT")" == 700 \
            || "$(file_mode "$INTERCEPT_CA_ROOT")" == 755 ) \
       && -f "$marker" && ! -L "$marker" \
       && "$(file_uid "$marker")" == 0 && "$(file_gid "$marker")" == 0 \
       && "$(file_mode "$marker")" == 644 && "$(file_nlink "$marker")" == 1 \
       && "$(cat "$marker")" == "$INTERCEPT_CA_MARKER_VALUE" \
       && -f "$INTERCEPT_CA" && ! -L "$INTERCEPT_CA" \
       && "$(file_uid "$INTERCEPT_CA")" == 0 && "$(file_gid "$INTERCEPT_CA")" == 0 \
       && "$(file_mode "$INTERCEPT_CA")" == 644 && "$(file_nlink "$INTERCEPT_CA")" == 1 ]] \
        || return 1
    openssl x509 -in "$INTERCEPT_CA" -noout -checkend 0 >/dev/null 2>&1 || return 1
    not_before="$(openssl x509 -in "$INTERCEPT_CA" -noout -startdate 2>/dev/null)" || return 1
    not_before="${not_before#notBefore=}"
    not_before_epoch="$(date -u -d "$not_before" +%s 2>/dev/null)" || return 1
    now_epoch="$(date -u +%s)" || return 1
    [[ "$not_before_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ \
       && "$not_before_epoch" -le "$now_epoch" ]] || return 1
    openssl x509 -in "$INTERCEPT_CA" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' \
        && openssl verify -CAfile "$INTERCEPT_CA" "$INTERCEPT_CA" >/dev/null 2>&1
}

bound_ui_helper_validate_current() {
    local directory before after metadata digest hash_fd source_fd hash_metadata source_metadata fd_digest rc=0
    [[ "$UI_GENERATION_HELPER" == /opt/5gpn/scripts/ui-generation.sh ]] || return 1
    directory="$(dirname -- "$UI_GENERATION_HELPER")"
    [[ -d "$directory" && ! -L "$directory" \
       && "$(readlink -f -- "$directory")" == "$directory" \
       && "$(stat -Lc '%u:%g:%a' -- "$directory")" == 0:0:755 \
       && -f "$UI_GENERATION_HELPER" && ! -L "$UI_GENERATION_HELPER" \
       && "$(readlink -f -- "$UI_GENERATION_HELPER")" == "$UI_GENERATION_HELPER" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$UI_GENERATION_HELPER")" == 0:0:755:1 ]] \
        || return 1
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$UI_GENERATION_HELPER")" || return 1
    digest="$(sha256sum -- "$UI_GENERATION_HELPER" | awk '{print $1}')" || return 1
    before="${metadata}:${digest}"
    exec {hash_fd}<"$UI_GENERATION_HELPER" || return 1
    exec {source_fd}<"$UI_GENERATION_HELPER" || { exec {hash_fd}<&-; return 1; }
    hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    exec {hash_fd}<&-
    [[ "$hash_metadata" == "$metadata" && "$source_metadata" == "$metadata" \
       && "$fd_digest" == "$digest" ]] || { exec {source_fd}<&-; return 1; }
    bash "/proc/self/fd/$source_fd" validate-current || rc=$?
    exec {source_fd}<&-
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$UI_GENERATION_HELPER")" || return 1
    digest="$(sha256sum -- "$UI_GENERATION_HELPER" | awk '{print $1}')" || return 1
    after="${metadata}:${digest}"
    [[ "$rc" == 0 && "$after" == "$before" ]]
}

profile_inputs_match_live() {
    local live="$1" base domain gateway leaf_sha public_key_sha ca_sha dot_sha intercept_sha
    local -a lines=()
    certificate_role_current_safe || return 1
    intercept_ca_boundary_is_safe || return 1
    bound_ui_helper_validate_current || return 1
    [[ -f "$PROFILE_INPUTS_FILE" && ! -L "$PROFILE_INPUTS_FILE" \
       && "$(file_uid "$PROFILE_INPUTS_FILE")" == 0 \
       && "$(file_gid "$PROFILE_INPUTS_FILE")" == 0 \
       && "$(file_mode "$PROFILE_INPUTS_FILE")" == 644 \
       && "$(file_nlink "$PROFILE_INPUTS_FILE")" == 1 ]] || return 1
    mapfile -t lines < "$PROFILE_INPUTS_FILE" || return 1
    [[ "${#lines[@]}" == 8 ]] || return 1
    base="$(cfg_get DNS_BASE_DOMAIN)"
    base="${base%.}"
    base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    valid_domain "$base" || return 1
    domain="dot.${base}"
    gateway="$(cfg_get DNS_GATEWAY_IP)"
    valid_ipv4 "$gateway" || return 1
    leaf_sha="$(openssl x509 -in "$live/fullchain.pem" -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    public_key_sha="$(openssl x509 -in "$live/fullchain.pem" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    ca_sha="$(openssl x509 -in "$INTERCEPT_CA" -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')" || return 1
    dot_sha="$(sha256sum "$UI_ROOT/current/ios-dot.mobileconfig" | awk '{print $1}')" || return 1
    intercept_sha="$(sha256sum "$UI_ROOT/current/ios-intercept-ca.mobileconfig" | awk '{print $1}')" || return 1
    [[ "${lines[0]}" == version=1 \
       && "${lines[1]}" == "dot_signer_leaf_sha256=${leaf_sha}" \
       && "${lines[2]}" == "dot_public_key_sha256=${public_key_sha}" \
       && "${lines[3]}" == "intercept_ca_der_sha256=${ca_sha}" \
       && "${lines[4]}" == "domain=${domain}" \
       && "${lines[5]}" == "gateway_ipv4=${gateway}" \
       && "${lines[6]}" == "ios_dot_sha256=${dot_sha}" \
       && "${lines[7]}" == "ios_intercept_ca_sha256=${intercept_sha}" ]]
}

# Validate the live lineage with the deploy hook's single mode-aware validator,
# then repair stale/missing role copies if a previous hook run was interrupted.
ensure_live_deployed() {
    local live="$1"
    deploy_hook_owned \
        || { err "Owned 5gpn certificate deploy hook is missing or invalid: ${DEPLOY_HOOK}."; return 1; }
    run_bound_deploy_hook validate "$live" \
        || { err "Live lineage failed the configured mode/SAN/key validation."; return 1; }
    if role_copies_match_live "$live"; then
        if profile_inputs_match_live "$live"; then
            return 0
        fi
        warn "UI profile inputs differ from the live lineage, DNS coordinates, or interception CA; repairing only the profile generation."
        run_bound_deploy_hook profile "$live" || return 1
    else
        warn "Certificate role copies differ from the live lineage; redeploying them before returning."
        run_bound_deploy_hook deploy "$live" || return 1
    fi
    role_copies_match_live "$live" \
        || { err "Certificate role copies still differ after deploy-hook recovery."; return 1; }
    profile_inputs_match_live "$live" \
        || { err "UI profile inputs still differ after deploy-hook recovery."; return 1; }
}

dns_records_match() {
    local expected="$1" domain raw ips aaaa aaaa_raw raw_count ip_count
    shift
    command -v dig >/dev/null 2>&1 \
        || { err "dig is required for the 1.1.1.1 certificate DNS check."; return 1; }
    for domain in "$@"; do
        raw="$(dig +time=3 +tries=1 +short A "$domain" @"$DNS_RESOLVER" 2>/dev/null || true)"
        ips="$(printf '%s\n' "$raw" | awk '/^[0-9]+(\.[0-9]+){3}$/' || true)"
        raw_count="$(printf '%s\n' "$raw" | awk 'NF { n++ } END { print n+0 }')"
        ip_count="$(printf '%s\n' "$ips" | awk 'NF { n++ } END { print n+0 }')"
        if [[ "$raw_count" != 1 || "$ip_count" != 1 ]]; then
            warn "DNS not ready via ${DNS_RESOLVER}: ${domain} must have exactly one direct A record (raw: ${raw:-none})."
            return 1
        fi
        if [[ "$ips" != "$expected" ]]; then
            warn "DNS mismatch via ${DNS_RESOLVER}: ${domain} A [${ips}] (want ${expected})."
            return 1
        fi
        # Let's Encrypt prefers a published IPv6 route when one exists. This
        # gateway is IPv4-only, so a stale AAAA would make HTTP-01 nondeterministic.
        # Absence must be OBSERVED: dig prints nothing on stdout when it gets no
        # reply, and piping it into awk replaces dig's exit status with awk's, so
        # the earlier `dig ... | awk '/:/' || true` read a failed lookup as
        # "no AAAA" and passed. This gate runs unattended from the renewal timer
        # and is what keeps a due renewal from stopping mihomo for a challenge
        # that cannot succeed, so an unanswered query must fail closed and be
        # retried by wait_for_http_dns rather than assumed away.
        if aaaa_raw="$(dig +time=3 +tries=1 +short AAAA "$domain" @"$DNS_RESOLVER" 2>/dev/null)"; then
            aaaa="$(printf '%s\n' "$aaaa_raw" | awk '/:/')"
        else
            warn "DNS not ready via ${DNS_RESOLVER}: ${domain} AAAA lookup did not answer; refusing to assume it has none."
            return 1
        fi
        if [[ -n "$aaaa" ]]; then
            warn "DNS mismatch via ${DNS_RESOLVER}: ${domain} has unsupported AAAA [${aaaa//$'\n'/, }]."
            return 1
        fi
    done
}

wait_for_http_dns() {
    local expected="$1"; shift
    local -a domains=("$@")
    local started=$SECONDS elapsed domain
    info "Waiting for HTTP-01 DNS through ${DNS_RESOLVER}: ${domains[*]} -> ${expected} (no AAAA)."
    while true; do
        if dns_records_match "$expected" "${domains[@]}"; then
            for domain in "${domains[@]}"; do ok "DNS verified via ${DNS_RESOLVER}: ${domain} A ${expected}"; done
            return 0
        fi
        elapsed=$((SECONDS - started))
        if (( elapsed >= DNS_WAIT_TIMEOUT )); then
            err "DNS did not converge through ${DNS_RESOLVER} within ${DNS_WAIT_TIMEOUT}s."
            err "Every HTTP-01 name must have only A ${expected} and no AAAA record."
            return 1
        fi
        info "DNS not ready yet; retrying in ${DNS_WAIT_INTERVAL}s (${elapsed}/${DNS_WAIT_TIMEOUT}s)."
        sleep "$DNS_WAIT_INTERVAL"
    done
}

restore_mihomo() {
    [[ "$MIHOMO_RESTORE_NEEDED" == 1 ]] || return 0
    MIHOMO_RESTORE_NEEDED=0
    if systemctl start 5gpn-mihomo.service; then
        ok "5gpn-mihomo restored after the HTTP-01 renewal attempt."
        return 0
    fi
    err "Could not restore 5gpn-mihomo after the HTTP-01 renewal attempt."
    return 1
}

run_http_renewal() (
    local -a certbot_args=("$@")
    local certbot_rc=0 restore_rc=0
    trap 'restore_mihomo || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if systemctl is-active --quiet 5gpn-mihomo.service 2>/dev/null; then
        info "Temporarily stopping 5gpn-mihomo to release TCP :80 for HTTP-01."
        MIHOMO_RESTORE_NEEDED=1
        systemctl stop 5gpn-mihomo.service \
            || { err "Could not stop 5gpn-mihomo; refusing to start Certbot with :80 still occupied."; return 1; }
    fi
    FIVEGPN_CERT_LOCK_HELD=1 certbot "${certbot_args[@]}" || certbot_rc=$?
    restore_mihomo || restore_rc=$?
    trap - EXIT INT TERM
    [[ "$certbot_rc" == 0 ]] || return "$certbot_rc"
    [[ "$restore_rc" == 0 ]] || return "$restore_rc"
)

private_lock_dir_safe() {
    local lock_dir="$1" root_gid
    root_gid="$(named_group_gid root)" || return 1
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(file_uid "$lock_dir")" == 0 \
       && "$(file_gid "$lock_dir")" == "$root_gid" \
       && "$(file_mode "$lock_dir")" == 700 ]]
}

private_lock_file_safe() {
    local lock_file="$1" root_gid
    root_gid="$(named_group_gid root)" || return 1
    [[ -f "$lock_file" && ! -L "$lock_file" \
       && "$(file_uid "$lock_file")" == 0 \
       && "$(file_gid "$lock_file")" == "$root_gid" \
       && "$(file_mode "$lock_file")" == 600 \
       && "$(file_nlink "$lock_file")" == 1 ]]
}

lock_fd_targets_file() {
    local fd="$1" lock_file="$2" fd_identity file_identity
    [[ -e "/proc/$$/fd/${fd}" ]] || return 1
    private_lock_file_safe "$lock_file" || return 1
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/$$/fd/${fd}" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$lock_file" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]]
}

ensure_private_lock_dir() {
    local lock_dir="$1"
    if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" || return 1
    fi
    private_lock_dir_safe "$lock_dir"
}

acquire_install_gate() {
    local lock_dir
    [[ "$EUID" == 0 ]] || { err "Certificate renewal must run as root."; return 1; }
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate-renewal exclusion."; return 1; }
    lock_dir="$(dirname -- "$INSTALL_LOCK_FILE")"
    ensure_private_lock_dir "$lock_dir" \
        || { err "Unsafe installer lock directory: ${lock_dir}"; return 1; }
    if [[ -e "$INSTALL_LOCK_FILE" || -L "$INSTALL_LOCK_FILE" ]]; then
        private_lock_file_safe "$INSTALL_LOCK_FILE" \
            || { err "Unsafe installer lock file: ${INSTALL_LOCK_FILE}"; return 1; }
    fi
    exec 8>"$INSTALL_LOCK_FILE"
    chmod 0600 "$INSTALL_LOCK_FILE" \
        || { exec 8>&-; err "Could not protect the installer lock file."; return 1; }
    lock_fd_targets_file 8 "$INSTALL_LOCK_FILE" \
        || { exec 8>&-; err "The installer lock descriptor is unsafe."; return 1; }
    flock -n 8 \
        || { err "A 5gpn install/configure transaction is active; deferring certificate renewal."; return 1; }
}

acquire_renew_lock() {
    local lock_dir
    [[ "$EUID" == 0 ]] || { err "Certificate renewal must run as root."; return 1; }
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate-renewal exclusion."; return 1; }
    lock_dir="$(dirname -- "$RENEW_LOCK_FILE")"
    ensure_private_lock_dir "$lock_dir" \
        || { err "Unsafe certificate-renewal lock directory: ${lock_dir}"; return 1; }
    if [[ -e "$RENEW_LOCK_FILE" || -L "$RENEW_LOCK_FILE" ]]; then
        private_lock_file_safe "$RENEW_LOCK_FILE" \
            || { err "Unsafe certificate-renewal lock file: ${RENEW_LOCK_FILE}"; return 1; }
    fi
    exec 9>"$RENEW_LOCK_FILE"
    chmod 0600 "$RENEW_LOCK_FILE" \
        || { exec 9>&-; err "Could not protect the certificate-renewal lock file."; return 1; }
    lock_fd_targets_file 9 "$RENEW_LOCK_FILE" \
        || { exec 9>&-; err "The certificate-renewal lock descriptor is unsafe."; return 1; }
    flock -n 9 \
        || { err "Another 5gpn certificate renewal is already running."; return 1; }
}

cert_renew_main() {
    local requested_name="" quiet=0 arg
    while (($#)); do
        arg="$1"; shift
        case "$arg" in
            --cert-name)
                (($#)) || { err "--cert-name requires a value."; return 2; }
                requested_name="$1"; shift ;;
            --quiet) quiet=1 ;;
            *) err "Unknown argument: $arg"; return 2 ;;
        esac
    done

    # Preserve the global lock order used by the installer. The public timer and
    # Bot action must not enter the certificate-lock handoff window.
    acquire_install_gate || return 1
    acquire_renew_lock || return 1

    local configured base mode public cert
    configured="$(cfg_get DNS_BASE_DOMAIN)"
    base="$(printf '%s' "${configured%.}" | tr '[:upper:]' '[:lower:]')"
    valid_domain "$base" \
        || { err "DNS_BASE_DOMAIN is missing or invalid; refusing unscoped renewal."; return 1; }
    [[ -z "$requested_name" || "$requested_name" == "$base" ]] \
        || { err "Requested cert name does not match DNS_BASE_DOMAIN; refusing renewal."; return 1; }
    mode="$(normalized_mode "$(cfg_get CERT_MODE)")" \
        || { err "CERT_MODE must be cloudflare, http-01, or debug."; return 1; }
    if [[ "$mode" == debug ]]; then
        info "No renewals were attempted: CERT_MODE=debug has no ACME renewal."
        return 0
    fi
    cert_provenance_owned "$base" "$mode" \
        || { err "The canonical lineage is not provenance-confirmed as 5gpn-owned; refusing project-managed renewal."; return 1; }
    renewal_conf_safe "$base" "$mode" \
        || { err "Certbot renewal config is missing, unscoped, mode-mismatched, or contains persistent hooks."; return 1; }

    cert="${LE_LIVE_ROOT}/${base}/fullchain.pem"
    if [[ -s "$cert" ]] && openssl x509 -checkend "$RENEW_BEFORE_SECONDS" -noout -in "$cert" >/dev/null 2>&1; then
        ensure_live_deployed "${LE_LIVE_ROOT}/${base}" || return 1
        info "Cert not yet due for renewal (more than 30 days remain)."
        return 0
    fi

    local -a certbot_args=(renew --cert-name "$base" --non-interactive)
    [[ "$quiet" == 1 ]] && certbot_args+=(--quiet)
    if [[ "$mode" == http-01 ]]; then
        public="$(cfg_get DNS_PUBLIC_IP)"
        valid_ipv4 "$public" \
            || { err "DNS_PUBLIC_IP is missing or invalid; cannot verify HTTP-01 DNS."; return 1; }
        local -a domains=()
        mapfile -t domains < <(http_cert_domains "$base")
        # Two names: console.<base> and dot.<base>. It was three while the panel
        # had an origin of its own. A count that outlives the list it counts
        # aborts renewal before the DNS gate ever runs, which reads as a DNS
        # failure and is not one.
        [[ ${#domains[@]} == 2 ]] || return 1
        wait_for_http_dns "$public" "${domains[@]}" || return 1
        run_http_renewal "${certbot_args[@]}" \
            || { err "Scoped HTTP-01 certificate renewal failed."; return 1; }
    else
        FIVEGPN_CERT_LOCK_HELD=1 certbot "${certbot_args[@]}" \
            || { err "Scoped Cloudflare DNS-01 certificate renewal failed."; return 1; }
    fi
    ensure_live_deployed "${LE_LIVE_ROOT}/${base}" || return 1
    ok "Scoped certificate renewal check completed for ${base}."
}

if [[ "${CERT_RENEW_LIB_ONLY:-0}" != 1 ]]; then
    cert_renew_main "$@"
fi
