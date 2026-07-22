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
DNS_TRUST=203.0.113.53
CERT_MODE=debug
TGBOT_TOKEN=123:secret
clear_external_config_env
if [[ -z "${BASE_DOMAIN+x}" && -z "${PUBLIC_IP+x}" && -z "${DNS_TRUST+x}" \
   && -z "${CERT_MODE+x}" && -z "${TGBOT_TOKEN+x}" \
   && "${WWW_DIR:-}" == "${BASE_DIR}/www" ]]; then
    pass "caller configuration environment is discarded"
else
    fail "caller configuration survived or the fixed WWW_DIR was cleared"
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
capture_line="$(grep -n '^[[:space:]]*capture_install_rollback' "$INSTALL" | tail -1 | cut -d: -f1)"
publish_line="$(grep -n '^[[:space:]]*install_5gpndns' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$stage_line" && -n "$capture_line" && -n "$publish_line" \
   && "$stage_line" -lt "$capture_line" && "$capture_line" -lt "$publish_line" ]]; then
    pass "artifact verification and rollback capture precede publication"
else
    fail "install publication order is not transactional"
fi

grep -Fq 'trap install_transaction_error ERR' "$INSTALL" \
    && grep -Fq 'rollback_install' "$INSTALL" \
    && pass "publication failures have a rollback trap" \
    || fail "publication rollback is not wired"

capture_fn="$(sed -n '/^capture_install_rollback()/,/^}/p' "$INSTALL")"
rollback_fn="$(sed -n '/^rollback_install()/,/^}/p' "$INSTALL")"
if grep -Fq '/etc/letsencrypt/renewal/${b}.conf' <<<"$capture_fn" \
   && grep -Fq '/etc/letsencrypt/live/${b}' <<<"$capture_fn" \
   && grep -Fq '/etc/letsencrypt/archive/${b}' <<<"$capture_fn" \
   && grep -Fq 'certbot delete --non-interactive --cert-name "$renewal_base"' <<<"$rollback_fn" \
   && grep -Fq 'ROLLBACK_DIR/le-live/${renewal_base}' <<<"$rollback_fn"; then
    pass "certificate mode switches snapshot and restore the exact scoped lineage"
else
    fail "transaction rollback can leave cert mode/authenticator/lineage split-brain"
fi
unit_capture_fn="$(sed -n '/^capture_managed_unit_states()/,/^}/p' "$INSTALL")"
unit_restore_fn="$(sed -n '/^restore_managed_unit_states()/,/^}/p' "$INSTALL")"
if grep -Fq 'TRANSACTION_STATE_UNITS' <<<"$unit_capture_fn" \
   && grep -Fq '.enabled-state' <<<"$unit_capture_fn" \
   && grep -Fq '.active-state' <<<"$unit_capture_fn" \
   && grep -Fq 'restore_unit_enablement' <<<"$unit_restore_fn" \
   && grep -Fq 'restore_unit_activity' <<<"$unit_restore_fn" \
   && grep -Fq '5gpn-certbot-renew.timer' "$INSTALL"; then
    pass "rollback preserves certificate timer enabled/active state"
else
    fail "certificate timer state is lost across a failed mode switch"
fi
if grep -Fq 'ROLLBACK_DIR/polkit/50-5gpn.rules' <<<"$capture_fn" \
   && grep -Fq 'ROLLBACK_DIR/polkit/50-5gpn.rules' <<<"$rollback_fn" \
   && grep -Fq '50-5gpn.rules.absent' <<<"$rollback_fn" \
   && grep -Fq 'polkit_rule_owned_by_5gpn' <<<"$rollback_fn"; then
    pass "rollback restores the exact prior 5gpn polkit rule or its absence"
else
    fail "failed publication can leave a new or changed polkit authorization behind"
fi

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
            is-active:--quiet:certbot.timer) return 1 ;;
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

printf '%s\n' 'version=1' 'exists=1' 'enabled=enabled' 'active=active' \
    > "$cert_ownership_tmp/certbot.timer.state"
if (
    GLOBAL_CERTBOT_TIMER_STATE="$cert_ownership_tmp/certbot.timer.state"
    ACME_DIR="$cert_ownership_tmp"
    timer_enabled=disabled
    timer_active=inactive
    global_certbot_timer_state_is_safe() { return 0; }
    systemctl() {
        case "${1:-}" in
            stop) timer_active=inactive ;;
            start) timer_active=active ;;
            enable) timer_enabled=enabled ;;
            disable) timer_enabled=disabled ;;
            is-enabled) printf '%s\n' "$timer_enabled"; [[ "$timer_enabled" == enabled ]] ;;
            is-active) printf '%s\n' "$timer_active"; [[ "$timer_active" == active ]] ;;
            *) return 1 ;;
        esac
    }
    restore_persisted_global_certbot_timer \
        && [[ "$timer_enabled" == enabled && "$timer_active" == active \
           && ! -e "$GLOBAL_CERTBOT_TIMER_STATE" ]]
); then
    pass "released ownership restores and clears the original distro timer state"
else
    fail "debug/external/uninstall can strand the distro timer disabled"
fi
disable_global_fn="$(sed -n '/^disable_global_certbot_timer_for_owned_lineage()/,/^}/p' "$INSTALL")"
persist_line="$(grep -nF 'persist_global_certbot_timer_state' <<<"$disable_global_fn" | head -1 | cut -d: -f1)"
disable_line="$(grep -nF 'systemctl disable --now certbot.timer' <<<"$disable_global_fn" | head -1 | cut -d: -f1)"
[[ -n "$persist_line" && -n "$disable_line" && "$persist_line" -lt "$disable_line" ]] \
    && pass "first global-timer takeover persists restorable state before disable" \
    || fail "global-timer takeover can lose its pre-disable state"
printf '%s\n' original-state > "$cert_ownership_tmp/existing-timer-state"
if (
    GLOBAL_CERTBOT_TIMER_STATE="$cert_ownership_tmp/existing-timer-state"
    global_certbot_timer_state_is_safe() { return 0; }
    persist_global_certbot_timer_state \
        && grep -qx original-state "$GLOBAL_CERTBOT_TIMER_STATE"
); then
    pass "owned reinstall never overwrites the first global-timer takeover state"
else
    fail "owned reinstall replaced the only record of the original distro timer state"
fi
rm -rf -- "$cert_ownership_tmp"

if grep -Eq 'swapoff[[:space:]]+/swapfile|rm -f[[:space:]]+/swapfile' "$INSTALL"; then
    fail "generic host /swapfile is still touched"
elif grep -Fq 'SWAP_FILE="${STATE_DIR}/swapfile"' "$INSTALL"; then
    pass "swap uses a project-owned private path"
else
    fail "project-private swap path missing"
fi

if grep -Eq '^remove_legacy_|xray\.service|smartdns\.service|sing-box\.service' "$INSTALL"; then
    fail "old-release service teardown remains"
else
    pass "installer has no old-release service teardown"
fi

renew_install="$(sed -n '/^install_renewal_automation()/,/^}/p' "$INSTALL")"
renew_remove="$(sed -n '/^remove_owned_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq 'preflight_renewal_unit_ownership' <<<"$renew_install" \
    && grep -Fq 'remove_owned_unit 5gpn-certbot-renew.timer' <<<"$renew_remove" \
    && grep -Fq 'remove_owned_unit 5gpn-certbot-renew.service' <<<"$renew_remove" \
    && pass "renewal units are ownership-gated before replacement and removal" \
    || fail "renewal unit ownership gates are incomplete"

grep -Fq 'MIHOMO_BIN="${BIN_DIR}/mihomo"' "$INSTALL" \
    && grep -Fq 'GUM_BIN="${BIN_DIR}/gum"' "$INSTALL" \
    && pass "generic mihomo/gum binaries moved under the project root" \
    || fail "generic global binary collision remains"
uninstall_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
grep -Fq 'remove_runtime_preserving_gum' <<<"$uninstall_fn" \
    && ! grep -Fq 'remove_fixed_owned_dir "$BASE_DIR"' <<<"$uninstall_fn" \
    && pass "uninstall preserves Gum through the dedicated runtime cleanup" \
    || fail "uninstall still removes Gum with the whole runtime"

grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/5gpn-dns"' "$INSTALL" \
    && grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/mihomo.gz"' "$INSTALL" \
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
    else
        fail "test OpenSSL cannot generate a SAN certificate"
    fi
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$cert_tmp/http-key.pem" -out "$cert_tmp/http-cert.pem" \
        -subj /CN=console.example.com \
        -addext 'subjectAltName=DNS:console.example.com,DNS:zash.example.com,DNS:dot.example.com' >/dev/null 2>&1; then
        cert_chain_trusted() { return 0; }
        validate_cert_pair "$cert_tmp/http-cert.pem" "$cert_tmp/http-key.pem" example.com 0 production http-01 \
            && pass "HTTP-01 exact console/zash/dot SAN shape validates" \
            || fail "HTTP-01 exact service SAN certificate was rejected"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
            -keyout "$cert_tmp/http-extra-key.pem" -out "$cert_tmp/http-extra-cert.pem" \
            -subj /CN=console.example.com \
            -addext 'subjectAltName=DNS:console.example.com,DNS:zash.example.com,DNS:dot.example.com,DNS:extra.example.com' >/dev/null 2>&1
        if validate_cert_pair "$cert_tmp/http-extra-cert.pem" "$cert_tmp/http-extra-key.pem" example.com 0 production http-01; then
            fail "HTTP-01 certificate with an extra DNS SAN was accepted"
        else
            pass "HTTP-01 reuse requires the exact three-service DNS SAN set"
        fi
    else
        fail "test OpenSSL cannot generate an HTTP-01 SAN certificate"
    fi

    # A later-role staging failure must remove every earlier unpublished
    # generation and temporary current link. The live role remains absent.
    cert_failure_root="$(mktemp -d)"
    DEBUG_CERT_DIR="$cert_failure_root/debug-cert"
    DNS_CERT_DIR="$cert_failure_root/cert"
    DNS_SERVICE_USER="$(id -gn)"
    MIHOMO_SERVICE_USER="$DNS_SERVICE_USER"
    mkdir -p "$DEBUG_CERT_DIR/example.com" "$DNS_CERT_DIR"
    cp "$cert_tmp/cert.pem" "$DEBUG_CERT_DIR/example.com/fullchain.pem"
    cp "$cert_tmp/key.pem" "$DEBUG_CERT_DIR/example.com/privkey.pem"
    touch "$DNS_CERT_DIR/web"
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
WEB_CERT_DIR="$DNS_CERT_DIR/web"
ZASH_CERT_DIR="$DNS_CERT_DIR/zash"
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

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer review regressions: PASS"
else
    echo "installer review regressions: FAIL"
    exit 1
fi
