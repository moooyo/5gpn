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
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "✔ $*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

DNS_ENV=/etc/5gpn/dns.env
LE_LIVE_ROOT=/etc/letsencrypt/live
LE_RENEWAL_ROOT=/etc/letsencrypt/renewal
LE_ARCHIVE_ROOT=/etc/letsencrypt/archive
LE_PRODUCTION_SERVER=https://acme-v02.api.letsencrypt.org/directory
CERT_ROOT=/etc/5gpn/cert
DEPLOY_HOOK=/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
ACME_DIR=/etc/5gpn/acme
DNS_RESOLVER=1.1.1.1
DNS_WAIT_TIMEOUT=600
DNS_WAIT_INTERVAL=10
RENEW_BEFORE_SECONDS=$((30 * 86400))
MIHOMO_RESTORE_NEEDED=0
RENEW_LOCK_FILE=/run/5gpn/cert-renew.lock

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
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }

normalized_mode() {
    case "${1:-}" in
        cloudflare) printf '%s\n' cloudflare ;;
        http-01) printf '%s\n' http-01 ;;
        debug) printf '%s\n' debug ;;
        *) return 1 ;;
    esac
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
    local base="$1" mode="$2" conf="${LE_RENEWAL_ROOT}/${base}.conf"
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
    printf 'console.%s\nzash.%s\ndot.%s\n' "$base" "$base" "$base"
}

deploy_hook_owned() {
    [[ -f "$DEPLOY_HOOK" && ! -L "$DEPLOY_HOOK" && -x "$DEPLOY_HOOK" ]] || return 1
    grep -Fqx '# 5gpn-renew-hook-id: deploy-v1' "$DEPLOY_HOOK" \
        && grep -qF "Let's Encrypt renewal deploy hook" "$DEPLOY_HOOK" \
        && grep -qF 'DNS_BASE_DOMAIN' "$DEPLOY_HOOK" 2>/dev/null \
        && grep -qF '/etc/5gpn/cert' "$DEPLOY_HOOK" 2>/dev/null
}

role_copies_match_live() {
    local live="$1" role cert key current
    for role in dot web zash; do
        current="${CERT_ROOT}/${role}/current"
        [[ -L "$current" && "$(readlink -- "$current")" =~ ^generations/[A-Za-z0-9._-]+$ ]] \
            || return 1
        cert="${CERT_ROOT}/${role}/current/fullchain.pem"
        key="${CERT_ROOT}/${role}/current/privkey.pem"
        [[ -f "$cert" && ! -L "$cert" && -f "$key" && ! -L "$key" \
           && "$(file_uid "$cert")" == "$EUID" \
           && "$(file_uid "$key")" == "$EUID" \
           && "$(file_mode "$cert")" == 640 \
           && "$(file_mode "$key")" == 640 ]] || return 1
        cmp -s "${live}/fullchain.pem" "$cert" || return 1
        cmp -s "${live}/privkey.pem" "$key" || return 1
    done
}

# Validate the live lineage with the deploy hook's single mode-aware validator,
# then repair stale/missing role copies if a previous hook run was interrupted.
ensure_live_deployed() {
    local live="$1"
    deploy_hook_owned \
        || { err "Owned 5gpn certificate deploy hook is missing or invalid: ${DEPLOY_HOOK}."; return 1; }
    RENEW_HOOK_VALIDATE_ONLY=1 RENEWED_LINEAGE="$live" "$DEPLOY_HOOK" >/dev/null \
        || { err "Live lineage failed the configured mode/SAN/key validation."; return 1; }
    role_copies_match_live "$live" && return 0
    warn "Certificate role copies differ from the live lineage; redeploying them before returning."
    RENEWED_LINEAGE="$live" "$DEPLOY_HOOK" || return 1
    role_copies_match_live "$live" \
        || { err "Certificate role copies still differ after deploy-hook recovery."; return 1; }
}

dns_records_match() {
    local expected="$1" domain raw ips aaaa raw_count ip_count
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
        aaaa="$(dig +time=3 +tries=1 +short AAAA "$domain" @"$DNS_RESOLVER" 2>/dev/null \
            | awk '/:/' || true)"
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
    if systemctl start mihomo; then
        ok "mihomo restored after the HTTP-01 renewal attempt."
        return 0
    fi
    err "Could not restore mihomo after the HTTP-01 renewal attempt."
    return 1
}

run_http_renewal() (
    local -a certbot_args=("$@")
    local certbot_rc=0 restore_rc=0
    trap 'restore_mihomo || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if systemctl is-active --quiet mihomo 2>/dev/null; then
        info "Temporarily stopping mihomo to release TCP :80 for HTTP-01."
        MIHOMO_RESTORE_NEEDED=1
        systemctl stop mihomo \
            || { err "Could not stop mihomo; refusing to start Certbot with :80 still occupied."; return 1; }
    fi
    certbot "${certbot_args[@]}" || certbot_rc=$?
    restore_mihomo || restore_rc=$?
    trap - EXIT INT TERM
    [[ "$certbot_rc" == 0 ]] || return "$certbot_rc"
    [[ "$restore_rc" == 0 ]] || return "$restore_rc"
)

acquire_renew_lock() {
    local lock_dir
    [[ "$EUID" == 0 ]] || { err "Certificate renewal must run as root."; return 1; }
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate-renewal exclusion."; return 1; }
    lock_dir="$(dirname -- "$RENEW_LOCK_FILE")"
    if [[ ! -e "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" || return 1
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(file_uid "$lock_dir")" == 0 \
       && "$(file_mode "$lock_dir")" == 700 ]] \
        || { err "Unsafe certificate-renewal lock directory: ${lock_dir}"; return 1; }
    if [[ -e "$RENEW_LOCK_FILE" ]]; then
        [[ -f "$RENEW_LOCK_FILE" && ! -L "$RENEW_LOCK_FILE" \
           && "$(file_uid "$RENEW_LOCK_FILE")" == 0 ]] \
            || { err "Unsafe certificate-renewal lock file: ${RENEW_LOCK_FILE}"; return 1; }
    fi
    exec 9>"$RENEW_LOCK_FILE"
    chmod 0600 "$RENEW_LOCK_FILE" \
        || { exec 9>&-; err "Could not protect the certificate-renewal lock file."; return 1; }
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
        [[ ${#domains[@]} == 3 ]] || return 1
        wait_for_http_dns "$public" "${domains[@]}" || return 1
        run_http_renewal "${certbot_args[@]}" \
            || { err "Scoped HTTP-01 certificate renewal failed."; return 1; }
    else
        certbot "${certbot_args[@]}" \
            || { err "Scoped Cloudflare DNS-01 certificate renewal failed."; return 1; }
    fi
    ensure_live_deployed "${LE_LIVE_ROOT}/${base}" || return 1
    ok "Scoped certificate renewal check completed for ${base}."
}

if [[ "${CERT_RENEW_LIB_ONLY:-0}" != 1 ]]; then
    cert_renew_main "$@"
fi
