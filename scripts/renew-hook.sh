#!/bin/bash
# 5gpn-renew-hook-id: deploy-v1
# Let's Encrypt renewal deploy hook — publish the renewed 5gpn lineage to
# /etc/5gpn/cert/{dot,console}. Cloudflare DNS-01 lineages must cover the apex
# and wildcard; HTTP-01 lineages must cover both derived service names.
# The console role is mihomo TLS controller pair; the panel is served with it.
# The pinned mihomo v1.19.28 build guarantees that mihomo reloads the controller certificate files automatically, so the renewed console copy becomes active without a mihomo restart or reload.
#
# This hook is installed system-wide and certbot may invoke it for unrelated
# lineages. It therefore accepts only the exact lineage named by the validated
# DNS_BASE_DOMAIN, verifies the leaf SANs and private-key match before staging,
# and re-signs only after all role copies were published.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Gum-or-echo status helpers. As a certbot deploy hook this normally runs
# without a TTY, so output stays as plain, journald-friendly lines. ---
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

# Fixed production paths. Tests source the hook in library mode and override
# these globals only after the production defaults have been established.
CERT_ROOT=/etc/5gpn/cert
DNS_ENV=/etc/5gpn/dns.env
LE_LIVE_ROOT=/etc/letsencrypt/live
IOSGEN=/opt/5gpn/scripts/gen-ios-profile.sh
UI_DIR=/opt/5gpn/ui
RENEW_LOCK_FILE=/run/5gpn/cert-renew.lock
INSTALL_LOCK_FILE=/run/5gpn/install.lock
RUNTIME_GATE_HELPER=/opt/5gpn/scripts/configure-runtime-gate.sh
CONFIG_ROOT_MARKER=.5gpn-owned
CONFIG_ROOT_MARKER_VALUE=5gpn-config
CERT_ROOT_MARKER=.5gpn-cert-root-owned
CERT_ROOT_MARKER_VALUE=5gpn-cert-root-v1
CERT_ROLE_MARKER=.5gpn-cert-role-owned
CERT_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
UI_OWNERSHIP_MARKER=.5gpn-zashboard-owned
UI_OWNERSHIP_VALUE=5gpn-ui-generations
FIVEGPN_CERT_GROUP=fivegpn

RENEW_HOOK_SOURCE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
RENEW_HOOK_DIR="$(cd "$(dirname -- "$RENEW_HOOK_SOURCE")" && pwd)"
UI_GENERATION_HELPER=""
UI_GENERATION_HELPER_LOADED=0
CERT_ROLE_HELPERS_LOADED=0

BASE_DOMAIN=""
CERT_MODE=""
CONSOLE_DOMAIN=""
DOT_DOMAIN=""
_CERT_RENEWED=0

bound_script_state() {
    local path="$1" production="$2" metadata digest directory
    [[ -f "$path" && ! -L "$path" && "$(stat -c %h -- "$path" 2>/dev/null)" == 1 ]] \
        || return 1
    if [[ "$path" == "$production" ]]; then
        directory="$(dirname -- "$production")"
        [[ -d "$directory" && ! -L "$directory" \
           && "$(readlink -f -- "$directory")" == "$directory" \
           && "$(stat -Lc '%u:%g:%a' -- "$directory")" == 0:0:755 ]] || return 1
        [[ "$(stat -Lc '%u:%g:%a:%h' -- "$path" 2>/dev/null)" == 0:0:755:1 ]] || return 1
    fi
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$path" 2>/dev/null)" || return 1
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
            if [[ "${RENEW_HOOK_LIB_ONLY:-0}" == 1 \
               && -f "$RENEW_HOOK_DIR/$helper" && ! -L "$RENEW_HOOK_DIR/$helper" ]]; then
                path="$RENEW_HOOK_DIR/$helper"
            else
                path="$production"
            fi
            before="$(bound_script_state "$path" "$production")" \
                || { err "Certificate role helper is missing or unsafe: $path"; return 1; }
            exec {hash_fd}<"$path" || return 1
            exec {source_fd}<"$path" || { exec {hash_fd}<&-; return 1; }
            hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            [[ "$hash_metadata" == "${before%:*}" && "$source_metadata" == "${before%:*}" ]] \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; err "Certificate role helper changed while it was anchored: $path"; return 1; }
            fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            exec {hash_fd}<&-
            [[ "$fd_digest" == "${before##*:}" ]] \
                || { exec {source_fd}<&-; err "Certificate role helper bytes differ from the anchored path: $path"; return 1; }
            # shellcheck source=/dev/null
            source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
            exec {source_fd}<&-
            after="$(bound_script_state "$path" "$production")" || return 1
            [[ "$after" == "$before" ]] \
                || { err "Certificate role helper changed while it was loaded: $path"; return 1; }
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
    CERT_ROLE_CTL_LINEAGE_LIVE_ROOT="$LE_LIVE_ROOT"
    CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT="${LE_LIVE_ROOT%/live}/archive"
    if [[ "${RENEW_HOOK_LIB_ONLY:-0}" == 1 && "$CERT_ROOT" != /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
        CERT_ROLE_CTL_STAGE_PARENT="$(dirname -- "$CERT_ROOT")/.cert-role-staging"
    else
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
        CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
    fi
}

load_ui_generation_helper() {
    local before after hash_fd source_fd hash_metadata source_metadata fd_digest
    [[ "$UI_GENERATION_HELPER_LOADED" == 1 ]] && return 0
    if [[ "${RENEW_HOOK_LIB_ONLY:-0}" == 1 \
       && -f "$RENEW_HOOK_DIR/ui-generation.sh" && ! -L "$RENEW_HOOK_DIR/ui-generation.sh" ]]; then
        UI_GENERATION_HELPER="$RENEW_HOOK_DIR/ui-generation.sh"
    else
        UI_GENERATION_HELPER=/opt/5gpn/scripts/ui-generation.sh
    fi
    before="$(bound_script_state "$UI_GENERATION_HELPER" /opt/5gpn/scripts/ui-generation.sh)" \
        || { err "UI generation helper is missing or unsafe: $UI_GENERATION_HELPER"; return 1; }
    exec {hash_fd}<"$UI_GENERATION_HELPER" || return 1
    exec {source_fd}<"$UI_GENERATION_HELPER" || { exec {hash_fd}<&-; return 1; }
    hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    [[ "$hash_metadata" == "${before%:*}" && "$source_metadata" == "${before%:*}" ]] \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; err "UI generation helper changed while it was anchored."; return 1; }
    fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
        || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
    exec {hash_fd}<&-
    [[ "$fd_digest" == "${before##*:}" ]] \
        || { exec {source_fd}<&-; err "UI generation helper bytes differ from the anchored path."; return 1; }
    # shellcheck source=scripts/ui-generation.sh
    source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
    exec {source_fd}<&-
    after="$(bound_script_state "$UI_GENERATION_HELPER" /opt/5gpn/scripts/ui-generation.sh)" \
        || { err "Could not revalidate the UI generation helper."; return 1; }
    [[ "$after" == "$before" \
       && ( "$UI_DIR" != /opt/5gpn/ui || "$UI_GENERATION_ROOT" == "$UI_DIR" ) \
       && "$UI_GENERATION_MARKER" == "$UI_OWNERSHIP_MARKER" \
       && "$UI_GENERATION_MARKER_VALUE" == "$UI_OWNERSHIP_VALUE" ]] \
        || { err "UI generation helper changed or drifted from the deploy-hook contract."; return 1; }
    UI_GENERATION_HELPER_LOADED=1
}

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
    [[ "${FIVEGPN_CERT_LOCK_HELD:-0}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate deployment exclusion."; return 1; }
    lock_dir="$(dirname -- "$INSTALL_LOCK_FILE")"
    [[ "$lock_dir" == "$(dirname -- "$RENEW_LOCK_FILE")" ]] \
        || { err "Certificate deployment locks must share one private directory."; return 1; }
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
    if [[ -e "$INSTALL_LOCK_FILE" || -L "$INSTALL_LOCK_FILE" ]]; then
        safe_plain_file "$INSTALL_LOCK_FILE" "$root_group" 600 \
            || { err "Unsafe installer lock file: $INSTALL_LOCK_FILE"; return 1; }
    fi
    exec 8>"$INSTALL_LOCK_FILE"
    chmod 0600 "$INSTALL_LOCK_FILE" || { exec 8>&-; return 1; }
    safe_plain_file "$INSTALL_LOCK_FILE" "$root_group" 600 || { exec 8>&-; return 1; }
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/$$/fd/8" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$INSTALL_LOCK_FILE" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]] \
        || { exec 8>&-; err "The installer lock descriptor is unsafe."; return 1; }
    flock -w 10 8 \
        || { err "A 5gpn install/configure transaction is active; deferring certificate deployment."; return 1; }
    assert_no_retained_configure_gate || return 1
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

assert_no_retained_configure_gate() (
    local production=/opt/5gpn/scripts/configure-runtime-gate.sh
    local directory expected_uid=0 expected_gid=0 before_metadata before_digest
    local source_fd hash_fd marker_fd fd metadata digest after_metadata after_digest
    directory="$(dirname -- "$RUNTIME_GATE_HELPER")" || return 1
    if [[ "$RUNTIME_GATE_HELPER" != "$production" ]]; then
        expected_uid="${EUID:-$(id -u)}"
        expected_gid="$(id -g)" || return 1
    fi
    [[ -d "$directory" && ! -L "$directory" \
       && "$(readlink -f -- "$directory" 2>/dev/null)" == "$directory" \
       && "$(stat -Lc '%u:%g:%a' -- "$directory" 2>/dev/null)" \
          == "${expected_uid}:${expected_gid}:755" \
       && -f "$RUNTIME_GATE_HELPER" && ! -L "$RUNTIME_GATE_HELPER" ]] \
        || { err "The configure runtime-gate helper parent or path is unsafe."; return 1; }
    before_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$RUNTIME_GATE_HELPER" 2>/dev/null)" \
        || return 1
    [[ "$before_metadata" == *":${expected_uid}:${expected_gid}:755:1" ]] \
        || { err "The configure runtime-gate helper metadata is unsafe."; return 1; }
    before_digest="$(sha256sum -- "$RUNTIME_GATE_HELPER" | awk '{print $1}')" \
        || return 1
    [[ "$before_digest" =~ ^[0-9a-f]{64}$ ]] || return 1

    exec {source_fd}<"$RUNTIME_GATE_HELPER" || return 1
    exec {hash_fd}<"$RUNTIME_GATE_HELPER" || return 1
    exec {marker_fd}<"$RUNTIME_GATE_HELPER" || return 1
    for fd in "$source_fd" "$hash_fd" "$marker_fd"; do
        metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$fd" 2>/dev/null)" \
            || return 1
        [[ "$metadata" == "$before_metadata" ]] \
            || { err "The configure runtime-gate helper changed while it was opened."; return 1; }
    done
    digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
        || return 1
    [[ "$digest" == "$before_digest" ]] \
        || { err "The configure runtime-gate helper FD digest changed."; return 1; }
    awk '
        $0 == "# 5gpn-configure-runtime-gate-id: v1" { marker = 1 }
        index($0, "wait|validate-ui|assert-clear") { modes = 1 }
        END { exit !(marker && modes) }
    ' "/proc/self/fd/$marker_fd" \
        || { err "The configure runtime-gate helper generation is invalid."; return 1; }
    after_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$RUNTIME_GATE_HELPER" 2>/dev/null)" \
        || return 1
    after_digest="$(sha256sum -- "$RUNTIME_GATE_HELPER" | awk '{print $1}')" \
        || return 1
    [[ "$after_metadata" == "$before_metadata" && "$after_digest" == "$before_digest" ]] \
        || { err "The configure runtime-gate helper path changed before execution."; return 1; }
    bash "/proc/self/fd/$source_fd" assert-clear \
        || { err "A retained configure runtime gate blocks independent certificate deployment until installed '5gpn configure' recovers it."; return 1; }
)

cert_chain_trusted() {
    local cert="$1"
    openssl verify -purpose sslserver -CApath /etc/ssl/certs -untrusted "$cert" "$cert" >/dev/null 2>&1 \
        || { [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
             && openssl verify -purpose sslserver -CAfile /etc/pki/tls/certs/ca-bundle.crt \
                    -untrusted "$cert" "$cert" >/dev/null 2>&1; }
}

# validate_cert_pair <cert> <key> <mode> <base> <console> <dot>
# Require a currently valid leaf certificate with exactly the DNS SAN set for
# its issuance mode and prove that the private key has the same public key.
# Non-DNS SANs do not affect this identity check. Comparing public-key PEM works
# for RSA and EC keys without exposing private material. Debug certificates
# share Cloudflare's apex+wildcard shape, although renew_hook_main never deploys
# debug lineages.
validate_cert_pair() {
    local cert="$1" key="$2" mode="$3" base="$4"
    local console="$5" dot="$6"
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
            required="${console}"$'\n'"${dot}"
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

cert_role_ctl_group_gid_override() {
    group_gid "$1"
}

safe_plain_file() {
    local path="$1" gid="$2" mode="$3"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$gid" \
       && "$(path_mode "$path")" == "$mode" \
       && "$(path_nlink "$path")" == 1 ]]
}

cert_root_is_safe() {
    load_cert_role_helpers || return 1
    cert_role_ctl_root_boundary_is_safe
}

ui_dir_is_safe() {
    ui_generation_current_path "$UI_DIR" >/dev/null
}

renew_role_validate_candidate() {
    validate_cert_pair "$1" "$2" "$RENEW_ROLE_MODE" "$RENEW_ROLE_BASE" \
        "$RENEW_ROLE_CONSOLE" "$RENEW_ROLE_DOT"
}

# deploy_lineage <live-dir>: validate and deploy only the exact current 5gpn
# lineage. No basename-suffix matching and no scan of unrelated live dirs.
deploy_lineage() {
    local live="${1%/}" expected="${LE_LIVE_ROOT}/${BASE_DOMAIN}" rc=0
    [[ "$live" == "$expected" ]] \
        || { err "refusing non-5gpn lineage: $live"; return 1; }
    [[ -d "$live" ]] || { err "5gpn lineage directory is missing: $live"; return 1; }

    validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
        "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$DOT_DOMAIN" \
        || return 1
    load_cert_role_helpers || return 1
    RENEW_ROLE_MODE="$CERT_MODE"
    RENEW_ROLE_BASE="$BASE_DOMAIN"
    RENEW_ROLE_CONSOLE="$CONSOLE_DOMAIN"
    RENEW_ROLE_DOT="$DOT_DOMAIN"
    cert_role_ctl_deploy_lineage "$live" "$BASE_DOMAIN" renew_role_validate_candidate || rc=$?
    if [[ "$rc" != 0 ]]; then
        case "$CERT_ROLE_CTL_COMMIT_STATE" in
            committed-undurable)
                err "renewed role current changed, but durability is unconfirmed; no rollback was attempted" ;;
            committed-partial|committed)
                err "renewed role publication is committed or partial; rerun for forward repair" ;;
        esac
        [[ -z "$CERT_ROLE_CTL_LAST_ERROR" ]] || err "$CERT_ROLE_CTL_LAST_ERROR"
        return "$rc"
    fi
    _CERT_RENEWED=1
    ok "${CERT_MODE} cert for ${BASE_DOMAIN} redeployed to dot/console"
}

deployed_roles_match_lineage() {
    local live="$1" role
    load_cert_role_helpers || return 1
    for role in dot console; do
        cert_role_ctl_validate_current_role "$role" || return 1
        cmp -s "$live/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" || return 1
        cmp -s "$live/privkey.pem" "$CERT_ROOT/$role/current/privkey.pem" || return 1
    done
}

refresh_ios_profile_generation() {
    local gw candidate="" generator_before generator_after generator_hash_fd generator_source_fd
    local generator_hash_metadata generator_source_metadata generator_fd_digest
    load_ui_generation_helper || return 1
    gw="$(cfg_get DNS_GATEWAY_IP)"
    [[ -n "$DOT_DOMAIN" && -n "$gw" ]] || return 1
    if [[ "$UI_DIR" == /opt/5gpn/ui && "$IOSGEN" != /opt/5gpn/scripts/gen-ios-profile.sh ]]; then
        return 1
    fi
    generator_before="$(bound_script_state "$IOSGEN" /opt/5gpn/scripts/gen-ios-profile.sh)" \
        || return 1
    ui_generation_prepare_existing_current "$UI_DIR" || return 1
    ui_dir_is_safe || return 1
    candidate="$(ui_generation_clone_current "$UI_DIR")" || return 1
    exec {generator_hash_fd}<"$IOSGEN" \
        || { ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    exec {generator_source_fd}<"$IOSGEN" \
        || { exec {generator_hash_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    generator_hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' \
        -- "/proc/self/fd/$generator_hash_fd")" \
        || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    generator_source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' \
        -- "/proc/self/fd/$generator_source_fd")" \
        || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    [[ "$generator_hash_metadata" == "${generator_before%:*}" \
       && "$generator_source_metadata" == "${generator_before%:*}" ]] \
        || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    generator_fd_digest="$(sha256sum -- "/proc/self/fd/$generator_hash_fd" | awk '{print $1}')" \
        || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    exec {generator_hash_fd}<&-
    [[ "$generator_fd_digest" == "${generator_before##*:}" ]] \
        || { exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    if ! bash "/proc/self/fd/$generator_source_fd" "$DOT_DOMAIN" "$gw" "$candidate"; then
        exec {generator_source_fd}<&-
        ui_generation_cleanup_candidate "$UI_DIR" "$candidate" \
            || warn "Unpublished profile generation cleanup failed; retained at $candidate."
        return 1
    fi
    exec {generator_source_fd}<&-
    generator_after="$(bound_script_state "$IOSGEN" /opt/5gpn/scripts/gen-ios-profile.sh)" \
        || { ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
    if [[ "$generator_after" != "$generator_before" ]]; then
        ui_generation_cleanup_candidate "$UI_DIR" "$candidate" \
            || warn "Changed-generator candidate cleanup failed; retained at $candidate."
        return 1
    fi
    if ! ui_generation_publish "$UI_DIR" "$candidate"; then
        case "$UI_GENERATION_COMMIT_STATE" in
            committed-undurable)
                warn "UI current already switched to the new profile generation, but directory durability is unconfirmed; no rollback was attempted." ;;
            committed)
                warn "UI current committed, but post-commit validation failed; no rollback was attempted." ;;
            *)
                ui_generation_cleanup_candidate "$UI_DIR" "$candidate" \
                    || warn "Unpublished profile generation cleanup failed; retained at $candidate." ;;
        esac
        return 1
    fi
    [[ "$UI_GENERATION_GC_WARNING" == 0 ]] \
        || warn "The renewed profiles are active, but an older unreferenced UI generation could not be removed."
}

renew_hook_main() {
    local configured raw_mode live expected
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
        && valid_base_domain "$DOT_DOMAIN" \
        || { err "derived service domains are invalid; no certificate was deployed."; return 1; }

    acquire_deploy_lock || return 1

    load_cert_role_helpers || return 1
    cert_role_ctl_scrub_role_root_candidates || return 1
    cert_root_is_safe || return 1
    local role
    for role in dot console; do
        cert_role_ctl_scrub_role "$role" || return 1
    done

    if [[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]]; then
        for role in dot console; do
            cert_role_ctl_validate_role "$role" 1 || return 1
        done
        validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$CERT_MODE" "$BASE_DOMAIN" "$CONSOLE_DOMAIN" "$DOT_DOMAIN"
        return
    fi

    if [[ "${FIVEGPN_PROFILE_ONLY_REFRESH:-0}" == 1 ]]; then
        deployed_roles_match_lineage "$live" \
            || { err "Profile-only refresh requires role copies that already match the live lineage."; return 1; }
        if refresh_ios_profile_generation; then
            ok "iOS profiles repaired in a cloned generation without republishing certificate roles."
            return 0
        fi
        err "Profile-only generation repair failed; the prior current generation remains selected unless a committed-switch warning was reported."
        return 1
    fi

    _CERT_RENEWED=0
    deploy_lineage "$live" || return 1

    # TLS readers detect the atomically replaced files by mtime on the next
    # handshake. SIGHUP is deliberately reserved for rules/chnroute reloads and
    # is not used as a certificate-reload API.
    ok "Certificate files published; TLS readers will load them on the next handshake."

    # Re-sign both iOS profiles in a clone of the complete current generation.
    # The helper validates that clone and performs the only live current switch.
    # Best-effort: certificate deployment is already complete, so profile
    # failure must not fail renewal and the last-known-good generation stays live.
    if [[ "${FIVEGPN_SKIP_PROFILE_REFRESH:-0}" == 1 ]]; then
        info "Profile refresh deferred to the enclosing installer generation transaction."
    elif [[ "$_CERT_RENEWED" == 1 ]]; then
        if refresh_ios_profile_generation; then
            ok "iOS profiles re-signed and atomically activated with the renewed cert."
        else
            warn "iOS profile re-sign failed (non-fatal); the prior current generation remains selected unless a committed-switch warning was reported."
        fi
    fi
}

if [[ "${RENEW_HOOK_LIB_ONLY:-0}" != 1 ]]; then
    renew_hook_main "$@"
fi
