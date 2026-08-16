#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
CERT_RENEW="$ROOT/scripts/cert-renew.sh"
FAIL=0
pass(){ echo "ok: $*"; }
fail(){ echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

BASE_DOMAIN=env.example
PUBLIC_IP=203.0.113.9
CERT_MODE=debug
DNS_BASE_DOMAIN=attacker.example
DNS_GATEWAY_IP=203.0.113.10
DNS_MIHOMO_SECRET=attacker-secret
clear_external_config_env
if [[ -z "${BASE_DOMAIN+x}" && -z "${PUBLIC_IP+x}" && -z "${CERT_MODE+x}" \
   && -z "${DNS_BASE_DOMAIN+x}" && -z "${DNS_GATEWAY_IP+x}" \
   && -z "${DNS_MIHOMO_SECRET+x}" && "${UI_DIR:-}" == "/opt/5gpn/ui" ]]; then
    pass "caller configuration environment is discarded"
else
    fail "caller configuration survived or the fixed UI_DIR changed"
fi

if grep -Fq 'CERT_DNS_PROPAGATION_SECONDS="${CERT_DNS_PROPAGATION_SECONDS:-' "$INSTALL"; then
    fail "certificate propagation timing still accepts caller environment"
elif grep -Eq '^CERT_DNS_PROPAGATION_SECONDS=[0-9]+$' "$INSTALL"; then
    pass "certificate propagation timing is an installer constant"
else
    fail "certificate propagation timing has no fixed installer value"
fi

deps_fn="$(sed -n '/^install_deps()/,/^}/p' "$INSTALL")"
if grep -Fq 'findmnt jq' <<<"$deps_fn" \
   && grep -Fq 'Could not install required host packages.' <<<"$deps_fn" \
   && grep -Fq 'QR display will use the plain URL fallback.' <<<"$deps_fn"; then
    pass "required jq and optional qrencode have separate fail-hard/fallback paths"
else
    fail "host dependency installation can defer a missing jq until publication"
fi

main_fn="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
[[ "$(grep -n 'attach_tty' <<<"$main_fn" | head -1 | cut -d: -f1)" -lt \
   "$(grep -n 'case "\$cmd"' <<<"$main_fn" | head -1 | cut -d: -f1)" ]] \
    && pass "TTY reattachment precedes command dispatch" \
    || fail "main dispatch can prompt before TTY reattachment"

ect="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
if grep -Eq 'CF_API_TOKEN|CLOUDFLARE_API_TOKEN' <<<"$ect"; then
    fail "Cloudflare token still accepts caller environment"
else
    pass "Cloudflare token is TUI/saved-file only"
fi

stage_line="$(grep -n '^[[:space:]]*stage_artifacts' "$INSTALL" | tail -1 | cut -d: -f1)"
publish_line="$(grep -n '^[[:space:]]*install_mihomo' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$stage_line" && -n "$publish_line" && "$stage_line" -lt "$publish_line" ]]; then
    pass "artifact verification precedes publication"
else
    fail "artifacts are published before they are staged and verified"
fi

full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
claim_line="$(grep -n 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_fn" | head -1 | cut -d: -f1)"
root_line="$(grep -n 'claim_project_roots' <<<"$full_fn" | head -1 | cut -d: -f1)"
if [[ -n "$claim_line" && -n "$root_line" && "$claim_line" -lt "$root_line" ]] \
   && grep -Fq 'if [[ "${INSTALL_PUBLICATION_STARTED:-0}" == 1 ]]' "$INSTALL"; then
    pass "failure reporting enters the explicit project-root publication phase"
else
    fail "publication failure reporting is not tied to the explicit publication phase"
fi

# The installer reports a failure and unwinds its locks; it does not undo a
# partial publication. Anything that restores or quarantines is a regression.
grep -Fq 'trap install_transaction_error ERR' "$INSTALL" \
    && grep -Fq 'report_install_failure' "$INSTALL" \
    && pass "publication failures are trapped and reported" \
    || fail "publication failure reporting is not wired"
grep -Eq '^(rollback_install|capture_install_rollback|restore_managed_unit_states)\(\)' "$INSTALL" \
    && fail "the install rollback subsystem came back" \
    || pass "a failed install does not restore or quarantine the host"

# The interception credentials used to exist in two places: intercept/config.json
# rendered them and the operator's YAML carried a copy, so a reseeded document
# stranded the preserved YAML in credential-mismatch and the installer had to
# realign the two. In one process there is no second copy to drift from -- the
# engine holds the document and nothing interception-shaped is written into
# config.yaml at all. Neither the realignment nor the seed inputs may come back.
grep -Eq '^align_preserved_intercept_credentials\(\)' "$INSTALL" \
    && fail "the credential realignment subsystem came back" \
    || pass "no interception credential is copied into the operator mihomo config"
render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
grep -Fqi 'intercept' <<<"$render_fn" \
    && fail "the mihomo seed renderer still reaches for interception credentials" \
    || pass "the mihomo seed renderer has no interception inputs"

ic="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
grep -Fq 'validate_cert_pair' <<<"$ic" \
    && grep -Fq 'production' <<<"$ic" \
    && grep -Fq 'Reusing valid matching debug certificate' <<<"$ic" \
    && pass "production/debug certificate reuse paths are validated and isolated" \
    || fail "certificate reuse validation/mode isolation missing"

if grep -Fq -- '--cert-name "$base"' <<<"$ic" \
   && grep -Fq 'certbot_args=(renew --cert-name "$base" --non-interactive)' "$CERT_RENEW" \
   && grep -Fq '[[ -z "$requested_name" || "$requested_name" == "$base" ]]' "$CERT_RENEW"; then
    pass "issuance and helper renewal are strictly scoped to the configured cert name"
else
    fail "certificate issuance/renewal is not cert-name scoped"
fi

cert_ownership_tmp="$(mktemp -d)"
if (
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$cert_ownership_tmp/cert"
    certbot_lineage_owned_by_5gpn() { return 1; }
    certbot_lineage_artifacts_exist() { return 0; }
    pause_global_certbot_timer() { return 0; }
    validate_cert_pair() { return 1; }
    certbot() { : > "$cert_ownership_tmp/certbot-called"; }
    ! install_cert example.com >/dev/null 2>&1 \
        && [[ ! -e "$cert_ownership_tmp/certbot-called" ]]
); then
    pass "invalid unowned canonical lineage fails before any Certbot mutation"
else
    fail "invalid unowned canonical lineage can reach Certbot"
fi

: > "$cert_ownership_tmp/external.log"
if (
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$cert_ownership_tmp/cert"
    certbot_lineage_owned_by_5gpn() { return 1; }
    certbot_lineage_artifacts_exist() { return 0; }
    pause_global_certbot_timer() { return 0; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { return 0; }
    deploy_cert_roles() { printf '%s\n' deploy >> "$cert_ownership_tmp/external.log"; }
    write_cert_provenance() { printf 'provenance:%s\n' "$3" >> "$cert_ownership_tmp/external.log"; }
    install_cert_deploy_hook() { printf '%s\n' hook >> "$cert_ownership_tmp/external.log"; }
    remove_owned_renewal_automation() { printf '%s\n' no-project-timer >> "$cert_ownership_tmp/external.log"; }
    certbot() { : > "$cert_ownership_tmp/certbot-called"; }
    install_cert example.com >/dev/null \
        && grep -qx 'provenance:reused' "$cert_ownership_tmp/external.log" \
        && grep -qx 'hook' "$cert_ownership_tmp/external.log" \
        && grep -qx 'no-project-timer' "$cert_ownership_tmp/external.log" \
        && [[ ! -e "$cert_ownership_tmp/certbot-called" ]]
); then
    pass "valid external lineage is reused read-only with deploy hook but no project timer"
else
    fail "external lineage reuse claimed renewal ownership or lost role deployment"
fi

mkdir -p "$cert_ownership_tmp/le/live/example.com" \
    "$cert_ownership_tmp/le/archive/example.com" "$cert_ownership_tmp/le/renewal"
: > "$cert_ownership_tmp/le/renewal/example.com.conf"
if (
    LE_LIVE_ROOT="$cert_ownership_tmp/le/live"
    LE_ARCHIVE_ROOT="$cert_ownership_tmp/le/archive"
    LE_RENEWAL_ROOT="$cert_ownership_tmp/le/renewal"
    certbot_lineage_set_is_exclusive example.com >/dev/null
); then
    pass "owned canonical lineage can exclusively replace the distro timer"
else
    fail "exclusive canonical lineage was rejected"
fi
: > "$cert_ownership_tmp/le/renewal/other.example.conf"
if (
    LE_LIVE_ROOT="$cert_ownership_tmp/le/live"
    LE_ARCHIVE_ROOT="$cert_ownership_tmp/le/archive"
    LE_RENEWAL_ROOT="$cert_ownership_tmp/le/renewal"
    ! certbot_lineage_set_is_exclusive example.com >/dev/null 2>&1
); then
    pass "unrelated Certbot lineage blocks global timer takeover"
else
    fail "installer can disable renewal needed by an unrelated lineage"
fi
: > "$cert_ownership_tmp/timer.log"
if (
    systemctl() {
        case "${1:-}:${2:-}:${3:-}" in
            cat:certbot.timer:*) return 0 ;;
            stop:certbot.timer:*) printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            is-active:certbot.timer:*) printf '%s\n' active; return 0 ;;
            is-active:--quiet:certbot.timer) return 1 ;;
            is-enabled:certbot.timer:*) printf '%s\n' enabled; return 0 ;;
            is-active:--quiet:certbot.service) return 0 ;;
            *) return 1 ;;
        esac
    }
    ! pause_global_certbot_timer >/dev/null 2>&1
) && grep -qx stopped "$cert_ownership_tmp/timer.log"; then
    pass "installer stops the distro timer and rejects an already running certbot service"
else
    fail "active external Certbot can race the lineage snapshot"
fi

# `pause_global_certbot_timer` snapshots both active and enabled state. Until
# scoped 5gpn renewal is committed, every success, failure, and signal path must
# restore both values exactly.
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=""
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=""
    timer_active=active
    timer_enabled=enabled
    certbot_lineage_set_is_exclusive() { return 0; }
    systemctl() {
        case "${1:-}" in
            cat) return 0 ;;
            show) printf 'loaded\n' ;;
            stop) timer_active=inactive ;;
            start) timer_active=active ;;
            enable)
                if [[ "$*" == *--runtime* ]]; then
                    timer_enabled=enabled-runtime
                else
                    timer_enabled=enabled
                fi ;;
            disable)
                timer_enabled=disabled
                [[ "$*" != *--now* ]] || timer_active=inactive ;;
            is-active)
                [[ "$*" == *--quiet* ]] || printf '%s\n' "$timer_active"
                [[ "$timer_active" == active ]] ;;
            is-enabled)
                printf '%s\n' "$timer_enabled"
                [[ "$timer_enabled" == enabled || "$timer_enabled" == enabled-runtime ]] ;;
            *) return 0 ;;
        esac
    }
    pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$timer_active" == inactive \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE" == active \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == enabled ]] \
        && disable_global_certbot_timer_for_owned_lineage example.com >/dev/null 2>&1 \
        && [[ "$timer_enabled" == disabled && "$KEEP_GLOBAL_CERTBOT_TIMER_DISABLED" == 0 ]] \
        && restore_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$timer_active" == active && "$timer_enabled" == enabled \
           && "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
); then
    pass "an uncommitted timer takeover restores original active and enabled state"
else
    fail "a failed or non-owning transaction can strand the distro certbot.timer"
fi
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=active
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=enabled
    systemctl() {
        case "${1:-}" in
            show) printf 'loaded\n' ;;
            is-active) printf 'inactive\n'; return 3 ;;
            is-enabled) printf 'disabled\n'; return 1 ;;
            *) return 0 ;;
        esac
    }
    restore_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
); then
    pass "an owned-lineage takeover keeps the distro timer disabled"
else
    fail "owned-lineage takeover restarted the timer it deliberately disabled"
fi
rm -rf -- "$cert_ownership_tmp"

if grep -Eq 'swapoff[[:space:]]+/swapfile|rm -f[[:space:]]+/swapfile' "$INSTALL"; then
    fail "generic host /swapfile is still touched"
elif grep -Fq 'SWAP_FILE="${STATE_DIR}/swapfile"' "$INSTALL"; then
    pass "swap uses a project-owned private path"
else
    fail "project-private swap path missing"
fi

if grep -Eq 'xray\.service|smartdns\.service|sing-box\.service|^remove_legacy_service_accounts\(\)' "$INSTALL"; then
    fail "historical service-account teardown remains"
else
    pass "installer contains no historical service-account teardown"
fi

renew_remove="$(sed -n '/^remove_owned_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq 'remove_unit 5gpn-certbot-renew.timer' <<<"$renew_remove" \
    && grep -Fq 'remove_unit 5gpn-certbot-renew.service' <<<"$renew_remove" \
    && pass "renewal timer and service are both torn down" \
    || fail "renewal teardown misses a unit"

if grep -Fxq 'MIHOMO_BIN="${BIN_DIR}/5gpn-mihomo"' "$INSTALL" \
   && ! grep -Fxq 'MIHOMO_BIN="${BIN_DIR}/mihomo"' "$INSTALL" \
   && grep -Fxq 'GUM_BIN="${BIN_DIR}/gum"' "$INSTALL"; then
    pass "the runtime binary is 5gpn-prefixed under the project root"
else
    fail "the runtime binary still uses an unprefixed or global path"
fi
uninstall_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
grep -Fq 'remove_runtime_preserving_gum' <<<"$uninstall_fn" \
    && ! grep -Fq 'remove_fixed_owned_dir "$BASE_DIR"' <<<"$uninstall_fn" \
    && pass "uninstall preserves Gum through the dedicated runtime cleanup" \
    || fail "uninstall still removes Gum with the whole runtime"

grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/mihomo.gz"' "$INSTALL" \
    && grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/zash.zip"' "$INSTALL" \
    && pass "all staged runtime artifacts are digest verified" \
    || fail "mandatory artifact digest verification missing"

if command -v openssl >/dev/null 2>&1; then
    cert_tmp="$(mktemp -d)"
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$cert_tmp/key.pem" -out "$cert_tmp/cert.pem" \
        -subj /CN=example.com \
        -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' >/dev/null 2>&1; then
        validate_cert_pair "$cert_tmp/cert.pem" "$cert_tmp/key.pem" example.com 0 debug \
            && pass "matching debug wildcard validates in debug mode" \
            || fail "matching debug wildcard was rejected"
        if validate_cert_pair "$cert_tmp/cert.pem" "$cert_tmp/key.pem" example.com 0 production; then
            fail "self-signed debug wildcard was accepted for production reuse"
        else
            pass "self-signed debug wildcard cannot enter production reuse"
        fi
        # -checkend answers only "does this expire soon" and says nothing about
        # notBefore, so a certificate that is not valid YET used to pass the
        # non-production path, which ran no verification at all. It would then
        # be rejected by every client that saw it.
        if openssl req -x509 -newkey rsa:2048 -nodes             -not_before "$(date -u -d '+2 days' +%Y%m%d%H%M%SZ)"             -not_after "$(date -u -d '+800 days' +%Y%m%d%H%M%SZ)"             -keyout "$cert_tmp/future-key.pem" -out "$cert_tmp/future-cert.pem"             -subj /CN=example.com             -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' >/dev/null 2>&1; then
            if validate_cert_pair "$cert_tmp/future-cert.pem" "$cert_tmp/future-key.pem" example.com 0 debug; then
                fail "a not-yet-valid debug certificate was accepted"
            else
                pass "a not-yet-valid debug certificate is rejected"
            fi
        else
            # Older OpenSSL has no req -x509 -not_before; skip rather than fail,
            # the assertion above still covers the accept path.
            pass "skipped not-yet-valid check (OpenSSL lacks req -not_before)"
        fi
    else
        fail "test OpenSSL cannot generate a SAN certificate"
    fi
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$cert_tmp/http-key.pem" -out "$cert_tmp/http-cert.pem" \
        -subj /CN=console.example.com \
        -addext 'subjectAltName=DNS:console.example.com,DNS:dot.example.com' >/dev/null 2>&1; then
        cert_chain_trusted() { return 0; }
        validate_cert_pair "$cert_tmp/http-cert.pem" "$cert_tmp/http-key.pem" example.com 0 production http-01 \
            && pass "HTTP-01 exact console/dot SAN shape validates" \
            || fail "HTTP-01 exact service SAN certificate was rejected"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
            -keyout "$cert_tmp/http-extra-key.pem" -out "$cert_tmp/http-extra-cert.pem" \
            -subj /CN=console.example.com \
            -addext 'subjectAltName=DNS:console.example.com,DNS:dot.example.com,DNS:extra.example.com' >/dev/null 2>&1
        if validate_cert_pair "$cert_tmp/http-extra-cert.pem" "$cert_tmp/http-extra-key.pem" example.com 0 production http-01; then
            fail "HTTP-01 certificate with an extra DNS SAN was accepted"
        else
            pass "HTTP-01 reuse requires the exact two-service DNS SAN set"
        fi
    else
        fail "test OpenSSL cannot generate an HTTP-01 SAN certificate"
    fi

    # A later-role staging failure must remove every earlier unpublished
    # generation and temporary current link. The live role remains absent.
    cert_failure_root="$(mktemp -d)"
    DEBUG_CERT_DIR="$cert_failure_root/debug-cert"
    DNS_CERT_DIR="$cert_failure_root/cert"
    FIVEGPN_SERVICE_USER="$(id -un)"
    FIVEGPN_SERVICE_GROUP="$(id -gn)"
    mkdir -p "$DEBUG_CERT_DIR/example.com" "$DNS_CERT_DIR"
    cp "$cert_tmp/cert.pem" "$DEBUG_CERT_DIR/example.com/fullchain.pem"
    cp "$cert_tmp/key.pem" "$DEBUG_CERT_DIR/example.com/privkey.pem"
    touch "$DNS_CERT_DIR/console"
    if deploy_cert_roles example.com "$DEBUG_CERT_DIR/example.com" debug >/dev/null 2>&1; then
        fail "certificate deployment succeeded despite an invalid later role path"
    elif find "$DNS_CERT_DIR/dot" -mindepth 1 \
            \( -name '.current.*' -o -name '.new.*' -o -name 'generation-*' -o -name current \) \
            -print -quit 2>/dev/null | grep -q .; then
        fail "failed certificate staging left an unpublished generation or link"
    else
        pass "failed certificate staging cleans every unpublished generation and link"
    fi
    rm -rf -- "$cert_failure_root"
    rm -rf -- "$cert_tmp"
fi

ownership_tmp="$(mktemp -d)"
if (
    DNS_CERT_DIR="$ownership_tmp/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    mkdir -p "$DNS_CERT_DIR"
    ensure_dns_cert_root() { return 0; }
    cert_root_is_safe() { return 0; }
    chown() { return 0; }
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    persist_certbot_lineage_ownership example.com \
        && write_cert_provenance cloudflare example.com owned \
        && write_cert_provenance debug example.com none \
        && certbot_lineage_owned_by_5gpn example.com
); then
    pass "production-to-debug switch preserves independent Certbot ownership proof"
else
    fail "debug mode overwrote the only proof needed to return to production or decommission"
fi
rm -rf -- "$ownership_tmp"

cert_state_tmp="$(mktemp -d)"
DNS_CERT_DIR="$cert_state_tmp/cert"
DOT_CERT_DIR="$DNS_CERT_DIR/dot"
CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
DEBUG_CERT_DIR="$cert_state_tmp/debug-cert"
ACME_DIR="$cert_state_tmp/acme"
LE_LIVE_ROOT="$cert_state_tmp/letsencrypt/live"
LE_ARCHIVE_ROOT="$cert_state_tmp/letsencrypt/archive"
LE_RENEWAL_ROOT="$cert_state_tmp/letsencrypt/renewal"
mkdir -p "$DOT_CERT_DIR/current" "$LE_LIVE_ROOT/example.com" "$LE_ARCHIVE_ROOT" "$LE_RENEWAL_ROOT"
# This fixture exercises provenance semantics, not the separately covered fixed
# certificate-root ownership boundary.
ensure_dns_cert_root() { mkdir -p "$DNS_CERT_DIR"; }
cert_root_is_safe() { return 0; }
persist_certbot_lineage_ownership() { return 0; }

write_cert_provenance cloudflare example.com reused
if certbot_lineage_owned_by_5gpn example.com; then
    fail "a reused Certbot lineage was treated as 5gpn-owned"
else
    pass "reused Certbot lineage provenance is non-owning"
fi
write_cert_provenance cloudflare example.com owned
certbot_lineage_owned_by_5gpn example.com \
    && pass "newly issued Certbot lineage provenance records ownership" \
    || fail "owned Certbot lineage provenance was not recognized"

certbot_log="$cert_state_tmp/certbot.log"
certbot() { printf '%s\n' "$*" >> "$certbot_log"; }
printf 'dns_cloudflare_credentials = %s/cloudflare.ini\n' "$ACME_DIR" \
    > "$LE_RENEWAL_ROOT/example.com.conf"
write_cert_provenance cloudflare example.com reused
decommission_certbot_lineage example.com >/dev/null
if [[ -s "$certbot_log" || "$DECOMMISSION_PRESERVE_ACME" != 1 ]]; then
    fail "decommission sent a reused external lineage to certbot delete"
else
    pass "decommission preserves a reused external lineage and its referenced credential"
fi
write_cert_provenance cloudflare example.com owned
decommission_lineage_safe() { return 0; }
decommission_certbot_lineage example.com >/dev/null
grep -qx -- 'delete --non-interactive --cert-name example.com' "$certbot_log" \
    && pass "decommission deletes only a provenance-confirmed owned lineage" \
    || fail "owned lineage was not deleted with the exact cert name"

# Simulate a lost Certbot live lineage with a still-valid preserved dot role.
rm -rf -- "$LE_LIVE_ROOT/example.com"
rm -rf -- "$LE_ARCHIVE_ROOT/example.com"
rm -f -- "$LE_RENEWAL_ROOT/example.com.conf"
touch "$DOT_CERT_DIR/current/fullchain.pem" "$DOT_CERT_DIR/current/privkey.pem"
: > "$certbot_log"
reuse_log="$cert_state_tmp/reuse.log"
validate_cert_pair() { [[ "$1" == "$DOT_CERT_DIR/current/fullchain.pem" ]]; }
deploy_cert_roles() { printf 'deploy:%s:%s\n' "$1" "${2:-}" >> "$reuse_log"; }
remove_owned_renew_hook() { printf '%s\n' hook-removed >> "$reuse_log"; }
remove_owned_renewal_automation() { printf '%s\n' units-removed >> "$reuse_log"; }
ensure_cf_token() { printf '%s\n' token-requested >> "$reuse_log"; return 1; }
write_cert_provenance cloudflare example.com reused
CERT_MODE=cloudflare
if install_cert example.com >/dev/null \
   && grep -qx "deploy:example.com:${DOT_CERT_DIR}/current" "$reuse_log" \
   && grep -qx 'units-removed' "$reuse_log" \
   && [[ "$(cert_provenance_get certbot_lineage)" == missing ]] \
   && ! grep -q 'token-requested' "$reuse_log" \
   && [[ ! -s "$certbot_log" ]]; then
    pass "missing lineage reuses the preserved role cert without issuance and disables renewal"
else
    fail "preserved role certificate fallback is incomplete"
fi
rm -rf -- "$cert_state_tmp"

# Retired certificate and profile fields are unsupported footprints. The
# current-only installer must reject them without rewriting the file.
retired_env="$(mktemp)"
cat > "$retired_env" <<'RETIRED_ENV'
DNS_BASE_DOMAIN=env.example
DNS_CERT=/etc/5gpn/cert/dot/current/fullchain.pem
DNS_KEY=/etc/5gpn/cert/dot/current/privkey.pem
DNS_WEB_CERT=/etc/5gpn/cert/web/current/fullchain.pem
DNS_WEB_KEY=/etc/5gpn/cert/web/current/privkey.pem
WWW_DIR=/opt/5gpn/www
RETIRED_ENV
if validate_dns_env_schema "$retired_env" 2>/dev/null; then
    fail "retired certificate/profile keys were accepted"
else
    pass "retired certificate/profile keys fail closed"
fi

# Arbitrary unknown keys also fail closed.
unsupported_env="$(mktemp)"
printf 'DNS_BASE_DOMAIN=env.example\nDNS_NOT_A_REAL_KEY=x\n' > "$unsupported_env"
if validate_dns_env_schema "$unsupported_env" 2>/dev/null; then
    fail "a genuinely unsupported dns.env key was accepted"
else
    pass "a genuinely unsupported dns.env key is still rejected"
fi
rm -f "$retired_env" "$unsupported_env"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer review regressions: PASS"
else
    echo "installer review regressions: FAIL"
    exit 1
fi
