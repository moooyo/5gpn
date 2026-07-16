#!/usr/bin/env bash
# Behaviour checks for scoped, validated, non-truncating certificate deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/renew-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

export RENEW_HOOK_LIB_ONLY=1
# shellcheck source=../scripts/renew-hook.sh
TEST_PATH="$PATH"
source "$HOOK"
PATH="$TEST_PATH"

# Fixtures are intentionally self-signed; production chain verification itself
# is locked structurally below while SAN/key/publication behavior stays real.
cert_chain_trusted() { return 0; }
grep -Fq 'certificate chain is not trusted for production TLS' "$HOOK" \
    || fail "renew hook does not enforce a trusted production chain"

CERT_ROOT="$TMP/cert"
DNS_ENV="$TMP/dns.env"
LE_LIVE_ROOT="$TMP/live"
IOSGEN="$TMP/no-ios-generator"
WWW_DIR="$TMP/www"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$LE_LIVE_ROOT"

systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$1" in
        is-active|reload) return 0 ;;
        *) return 1 ;;
    esac
}

write_env() {
    local mode="${1:-cloudflare}"
    printf '%s\n' \
        'DNS_BASE_DOMAIN=EXAMPLE.TEST.' \
        'DNS_GATEWAY_IP=192.0.2.10' \
        "CERT_MODE=${mode}" > "$DNS_ENV"
}

generate_cert() {
    local dir="$1" sans="$2"
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
        -subj '/CN=example.test' -addext "subjectAltName=${sans}" \
        >/dev/null 2>&1
}

mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

role_checksums() {
    cksum \
        "$CERT_ROOT/dot/fullchain.pem" "$CERT_ROOT/dot/privkey.pem" \
        "$CERT_ROOT/web/fullchain.pem" "$CERT_ROOT/web/privkey.pem" \
        "$CERT_ROOT/zash/fullchain.pem" "$CERT_ROOT/zash/privkey.pem"
}

write_env
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,IP:192.0.2.10'
generate_cert "$LE_LIVE_ROOT/other.test" 'DNS:other.test,DNS:*.other.test'

# A system-wide certbot deploy hook receives every renewed lineage. An unrelated
# lineage must be a successful no-op: no role files and no daemon reload.
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/other.test"
renew_hook_main >/dev/null
[[ ! -e "$CERT_ROOT" ]] || fail "unrelated lineage created role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "unrelated lineage touched systemd: $(cat "$SYSTEMCTL_LOG")"
pass "unrelated lineage is ignored without reload"

# Certbot duplicate suffixes are not accepted as aliases for the configured
# cert-name; bot renewal and hook deployment both target the exact base name.
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test-0001"
renew_hook_main >/dev/null
[[ ! -e "$CERT_ROOT" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "duplicate/foreign cert-name was treated as the current lineage"
pass "only the exact configured cert-name is accepted"

# Even broken 5gpn mode configuration must not break an unrelated system-wide
# Certbot deploy hook invocation.
write_env nonsense
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/other.test"
renew_hook_main >/dev/null
[[ ! -e "$CERT_ROOT" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "unrelated lineage was not a no-op with an invalid CERT_MODE"
pass "unrelated lineage remains a no-op with invalid 5gpn certificate mode"

# The production hook must fail closed for debug and unknown modes when Certbot
# presents the configured lineage. Debug certificate installation is owned by
# the explicit installer path, never by an ACME deploy hook.
for mode in debug http nonsense; do
    write_env "$mode"
    : > "$SYSTEMCTL_LOG"
    RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test"
    if renew_hook_main >/dev/null 2>&1; then
        fail "configured lineage was accepted with CERT_MODE=$mode"
    fi
    [[ ! -e "$CERT_ROOT" && ! -s "$SYSTEMCTL_LOG" ]] \
        || fail "CERT_MODE=$mode published or reloaded before failing"
done
pass "debug, aliases, and invalid production deploy-hook modes fail closed"

# A valid Cloudflare apex+wildcard pair is staged in each destination and
# published with final permissions. Reload happens only after publication.
write_env cloudflare
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test/"
renew_hook_main >/dev/null
for role in dot web zash; do
    cert="$CERT_ROOT/$role/fullchain.pem"
    key="$CERT_ROOT/$role/privkey.pem"
    [[ -s "$cert" && -s "$key" ]] || fail "$role certificate pair was not published"
    [[ "$(mode_of "$cert")" == 640 && "$(mode_of "$key")" == 640 ]] \
        || fail "$role certificate pair does not have mode 0640"
    validate_cert_pair "$cert" "$key" cloudflare example.test \
        console.example.test zash.example.test dot.example.test >/dev/null \
        || fail "$role certificate pair failed post-publication validation"
done
[[ ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "valid certificate publication incorrectly used SIGHUP/systemctl"
if find "$CERT_ROOT" -type f \( -name '.fullchain.pem.*' -o -name '.privkey.pem.*' \) \
    | grep -q .; then
    fail "staging files were left behind after successful publication"
fi
pass "valid Cloudflare pair is staged/published without misusing SIGHUP"

before="$(role_checksums)"

# Cloudflare still requires both the apex and wildcard SANs.
generate_cert "$LE_LIVE_ROOT/example.test" 'DNS:example.test'
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test"
if renew_hook_main >/dev/null 2>&1; then
    fail "certificate without wildcard SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "Cloudflare SAN failure changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "SAN validation failure reloaded the daemon"
pass "Cloudflare certificate missing wildcard fails closed before publication"

# Cloudflare DNS-01 also rejects DNS identities beyond the exact apex+wildcard
# set, while the IP SAN in the successful fixture above remains irrelevant.
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,DNS:extra.example.test'
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "Cloudflare certificate with an extra DNS SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "extra Cloudflare DNS SAN changed roles or reloaded the daemon"
pass "Cloudflare certificate with an extra DNS SAN fails before publication"

# HTTP-01 uses a non-wildcard lineage containing exactly the three
# derived service DNS names. Non-DNS SANs do not change that identity set.
write_env http-01
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:zash.example.test,DNS:dot.example.test,IP:192.0.2.10'
: > "$SYSTEMCTL_LOG"
renew_hook_main >/dev/null
for role in dot web zash; do
    validate_cert_pair "$CERT_ROOT/$role/fullchain.pem" "$CERT_ROOT/$role/privkey.pem" \
        http-01 example.test console.example.test zash.example.test dot.example.test >/dev/null \
        || fail "$role HTTP-01 certificate failed post-publication validation"
done
[[ ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "valid HTTP-01 publication incorrectly used SIGHUP/systemctl"
pass "HTTP-01 publishes a certificate covering all three service SANs"

# An extra HTTP-01 DNS identity must fail before any live role is changed.
write_env http-01
before="$(role_checksums)"
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:zash.example.test,DNS:dot.example.test,DNS:extra.example.test'
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "HTTP-01 certificate with an extra DNS SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "extra HTTP-01 DNS SAN changed roles or reloaded the daemon"
pass "HTTP-01 certificate with an extra DNS SAN fails before publication"

# Every required HTTP-01 SAN is independently mandatory. Validation happens
# against the lineage before any of the three live roles is touched.
for missing in console zash dot; do
    case "$missing" in
        console) sans='DNS:zash.example.test,DNS:dot.example.test' ;;
        zash) sans='DNS:console.example.test,DNS:dot.example.test' ;;
        dot) sans='DNS:console.example.test,DNS:zash.example.test' ;;
    esac
    generate_cert "$LE_LIVE_ROOT/example.test" "$sans"
    : > "$SYSTEMCTL_LOG"
    if renew_hook_main >/dev/null 2>&1; then
        fail "HTTP-01 certificate missing $missing SAN was accepted"
    fi
    after="$(role_checksums)"
    [[ "$before" == "$after" ]] \
        || fail "HTTP-01 certificate missing $missing SAN changed live role files"
    [[ ! -s "$SYSTEMCTL_LOG" ]] \
        || fail "HTTP-01 certificate missing $missing SAN reloaded the daemon"
done
pass "HTTP-01 certificate missing any required service SAN fails before publication"

# A valid-SAN leaf paired with a different private key must likewise fail closed.
write_env http-01
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:zash.example.test,DNS:dot.example.test'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$LE_LIVE_ROOT/example.test/privkey.pem" >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "mismatched certificate/private key was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "key mismatch changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "key mismatch reloaded the daemon"
pass "certificate/private-key mismatch fails closed before publication"

echo "renew hook tests: PASS"
