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
DNS_CHNROUTE=/tmp/attacker-chnroute
CERT_MODE=debug
TGBOT_TOKEN=123:secret
clear_external_config_env
if [[ -z "${BASE_DOMAIN+x}" && -z "${PUBLIC_IP+x}" && -z "${DNS_CHNROUTE+x}" \
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
publish_line="$(grep -n '^[[:space:]]*install_5gpndns' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$stage_line" && -n "$publish_line" && "$stage_line" -lt "$publish_line" ]]; then
    pass "artifact verification precedes publication"
else
    fail "artifacts are published before they are staged and verified"
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

# The interception credentials in a preserved operator config are rendered from
# intercept/config.json, so a reseeded document leaves the YAML stale and the
# routing check aborts publication with `credential-mismatch`. The preserve
# branch must realign them, and must treat "nothing alignable" (exit 3, a legacy
# config with no interception blocks) as fine rather than fatal.
render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
align_fn="$(sed -n '/^align_preserved_intercept_credentials()/,/^}/p' "$INSTALL")"
preserve_line="$(grep -nF 'align_preserved_intercept_credentials "$config"' <<<"$render_fn" | head -1 | cut -d: -f1)"
preserved_ok_line="$(grep -nF 'validated and preserved' <<<"$render_fn" | head -1 | cut -d: -f1)"
if [[ -n "$preserve_line" && -n "$preserved_ok_line" \
   && "$preserve_line" -lt "$preserved_ok_line" ]] \
   && grep -Fq -- '--align-interception-credentials' <<<"$align_fn" \
   && grep -Fq '3) rm -f -- "$candidate"; return 0 ;;' <<<"$align_fn" \
   && grep -Fq '"$MIHOMO_BIN" -t -f "$candidate"' <<<"$align_fn"; then
    pass "a preserved mihomo config is realigned to the interception truth source"
else
    fail "a reseeded interception config can strand a preserved mihomo config in credential-mismatch"
fi
grep -Fq 'cmp -s -- "$candidate" "$config"' <<<"$align_fn" \
    && pass "an already-aligned config is left untouched" \
    || fail "alignment rewrites an operator config that needed no change"

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

# `pause_global_certbot_timer` stops the distro timer on every run. The success
# path must put back exactly what it paused, or a *successful* install silently
# leaves an unrelated machine's renewals stopped forever. A failed install
# deliberately restores nothing -- that is the contract, not an oversight.
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
    GLOBAL_CERTBOT_TIMER_PAUSED_ACTIVE=""
    timer_active=active
    global_certbot_timer_exists() { return 0; }
    systemctl() {
        case "${1:-}" in
            stop) timer_active=inactive ;;
            start) timer_active=active ;;
            is-active)
                [[ "$*" == *--quiet* ]] || printf '%s\n' "$timer_active"
                [[ "$timer_active" == active ]] ;;
            *) return 0 ;;
        esac
    }
    pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$timer_active" == inactive \
           && "$GLOBAL_CERTBOT_TIMER_PAUSED_ACTIVE" == active ]] \
        && restore_global_certbot_timer_after_success >/dev/null 2>&1 \
        && [[ "$timer_active" == active ]]
); then
    pass "a successful install restarts the distro timer it paused"
else
    fail "a successful install can leave the distro certbot.timer stopped"
fi
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
    GLOBAL_CERTBOT_TIMER_PAUSED_ACTIVE=active
    systemctl() {
        case "${1:-}" in
            show) printf 'loaded\n' ;;
            is-active) printf 'inactive\n'; return 3 ;;
            is-enabled) printf 'disabled\n'; return 1 ;;
            *) return 0 ;;
        esac
    }
    restore_global_certbot_timer_after_success >/dev/null 2>&1
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

if grep -Eq '^remove_legacy_|xray\.service|smartdns\.service|sing-box\.service' "$INSTALL"; then
    fail "old-release service teardown remains"
else
    pass "installer has no old-release service teardown"
fi

renew_remove="$(sed -n '/^remove_owned_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq 'remove_unit 5gpn-certbot-renew.timer' <<<"$renew_remove" \
    && grep -Fq 'remove_unit 5gpn-certbot-renew.service' <<<"$renew_remove" \
    && pass "renewal timer and service are both torn down" \
    || fail "renewal teardown misses a unit"

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

# An existing installation's dns.env still contains DNS_CHINA/DNS_TRUST, which
# moved to upstreams.json, and DNS_CHINA_0X20, whose mechanism was removed
# outright. validate_dns_env_schema must TOLERATE all three: it is run against
# the persisted file on every upgrade, and rejecting an unknown key aborts the
# install. This is exactly how the retired DNS_EGRESS_RESOLVER path behaves,
# except these are dropped silently instead of demanding operator action,
# because seed_upstreams_json carries the upstream values across first.
retired_env="$(mktemp)"
cat > "$retired_env" <<'RETIRED_ENV'
DNS_BASE_DOMAIN=env.example
DNS_CHINA=223.5.5.5
DNS_TRUST=dns.google@8.8.8.8
DNS_CHINA_0X20=1
DNS_UPSTREAMS=/etc/5gpn/upstreams.json
RETIRED_ENV
if validate_dns_env_schema "$retired_env" 2>/dev/null; then
    pass "a pre-upgrade dns.env carrying every retired key still validates"
else
    fail "a retired key aborts the upgrade instead of being tolerated"
fi

# Tolerated on read is not the same as writable: nothing may put them back.
unsupported_env="$(mktemp)"
printf 'DNS_BASE_DOMAIN=env.example\nDNS_NOT_A_REAL_KEY=x\n' > "$unsupported_env"
if validate_dns_env_schema "$unsupported_env" 2>/dev/null; then
    fail "an genuinely unsupported dns.env key was accepted"
else
    pass "a genuinely unsupported dns.env key is still rejected"
fi
rm -f "$retired_env" "$unsupported_env"
