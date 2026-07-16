#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
FAIL=0
pass(){ echo "ok: $*"; }
fail(){ echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

BASE_DOMAIN=env.example
PUBLIC_IP=203.0.113.9
CF_API_TOKEN=secret
DNS_VERSION=untrusted
TGBOT_TOKEN=123:secret
clear_external_config_env
if [[ -z "${BASE_DOMAIN+x}" && -z "${PUBLIC_IP+x}" && -z "${CF_API_TOKEN+x}" \
   && -z "${DNS_VERSION+x}" && -z "${TGBOT_TOKEN+x}" ]]; then
    pass "caller configuration environment is discarded"
else
    fail "caller configuration environment survived clear_external_config_env"
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

stage_line="$(grep -n '^[[:space:]]*stage_artifacts$' "$INSTALL" | tail -1 | cut -d: -f1)"
capture_line="$(grep -n '^[[:space:]]*capture_install_rollback$' "$INSTALL" | tail -1 | cut -d: -f1)"
clean_line="$(grep -n '^[[:space:]]*clean_previous_install$' "$INSTALL" | tail -1 | cut -d: -f1)"
publish_line="$(grep -n '^[[:space:]]*install_5gpndns$' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$stage_line" && -n "$capture_line" && -n "$clean_line" && -n "$publish_line" \
   && "$stage_line" -lt "$capture_line" && "$capture_line" -lt "$clean_line" \
   && "$clean_line" -lt "$publish_line" ]]; then
    pass "artifact verification and rollback capture precede publication"
else
    fail "install publication order is not transactional"
fi

grep -Fq 'trap install_transaction_error ERR' "$INSTALL" \
    && grep -Fq 'rollback_install' "$INSTALL" \
    && pass "publication failures have a rollback trap" \
    || fail "publication rollback is not wired"

ic="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
grep -Fq 'validate_cert_pair' <<<"$ic" \
    && grep -Fq 'production' <<<"$ic" \
    && grep -Fq 'Reusing valid matching debug certificate' <<<"$ic" \
    && pass "production/debug certificate reuse paths are validated and isolated" \
    || fail "certificate reuse validation/mode isolation missing"

grep -Fq -- '--cert-name "$base"' <<<"$ic" \
    && grep -Fq -- '--cert-name "$DNS_BASE_DOMAIN"' "$INSTALL" \
    && pass "issuance and renewal are scoped to the 5gpn cert name" \
    || fail "certbot operation is not cert-name scoped"

if grep -Eq 'swapoff[[:space:]]+/swapfile|rm -f[[:space:]]+/swapfile' "$INSTALL"; then
    fail "generic host /swapfile is still touched"
elif grep -Fq 'SWAP_FILE="${STATE_DIR}/swapfile"' "$INSTALL"; then
    pass "swap uses a project-owned private path"
else
    fail "project-private swap path missing"
fi

grep -Fq 'remove_legacy_xray' "$INSTALL" \
    && grep -Fq 'unit_file_owned_by_5gpn' "$INSTALL" \
    && pass "legacy services are ownership gated" \
    || fail "legacy service ownership gate missing"

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
    rm -rf -- "$cert_tmp"
fi

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
mkdir -p "$DOT_CERT_DIR" "$LE_LIVE_ROOT/example.com" "$LE_ARCHIVE_ROOT" "$LE_RENEWAL_ROOT"

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
decommission_certbot_lineage example.com >/dev/null
grep -qx -- 'delete --non-interactive --cert-name example.com' "$certbot_log" \
    && pass "decommission deletes only a provenance-confirmed owned lineage" \
    || fail "owned lineage was not deleted with the exact cert name"

# Simulate a lost Certbot live lineage with a still-valid preserved dot role.
rm -rf -- "$LE_LIVE_ROOT/example.com"
touch "$DOT_CERT_DIR/fullchain.pem" "$DOT_CERT_DIR/privkey.pem"
: > "$certbot_log"
reuse_log="$cert_state_tmp/reuse.log"
validate_cert_pair() { [[ "$1" == "$DOT_CERT_DIR/fullchain.pem" ]]; }
deploy_cert_roles() { printf 'deploy:%s:%s\n' "$1" "${2:-}" >> "$reuse_log"; }
remove_owned_renew_hook() { printf '%s\n' hook-removed >> "$reuse_log"; }
remove_owned_renewal_automation() { printf '%s\n' units-removed >> "$reuse_log"; }
ensure_cf_token() { printf '%s\n' token-requested >> "$reuse_log"; return 1; }
write_cert_provenance cloudflare example.com reused
CERT_MODE=cloudflare
if install_cert example.com >/dev/null \
   && grep -qx "deploy:example.com:${DOT_CERT_DIR}" "$reuse_log" \
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
