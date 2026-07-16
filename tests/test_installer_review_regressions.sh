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

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer review regressions: PASS"
else
    echo "installer review regressions: FAIL"
    exit 1
fi
