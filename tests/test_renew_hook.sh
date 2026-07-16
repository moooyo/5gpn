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
source "$HOOK"

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
    printf '%s\n' \
        'DNS_BASE_DOMAIN=EXAMPLE.TEST.' \
        'DNS_DOMAIN=dot.example.test' \
        'DNS_GATEWAY_IP=192.0.2.10' > "$DNS_ENV"
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

write_env
generate_cert "$LE_LIVE_ROOT/example.test" 'DNS:example.test,DNS:*.example.test'
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

# A valid apex+wildcard pair is staged in each destination and published with
# final permissions. Reload happens only after publication succeeds.
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test/"
renew_hook_main >/dev/null
for role in dot web zash; do
    cert="$CERT_ROOT/$role/fullchain.pem"
    key="$CERT_ROOT/$role/privkey.pem"
    [[ -s "$cert" && -s "$key" ]] || fail "$role certificate pair was not published"
    [[ "$(mode_of "$cert")" == 640 && "$(mode_of "$key")" == 640 ]] \
        || fail "$role certificate pair does not have mode 0640"
    validate_cert_pair "$cert" "$key" example.test >/dev/null \
        || fail "$role certificate pair failed post-publication validation"
done
grep -Fxq 'is-active --quiet 5gpn-dns' "$SYSTEMCTL_LOG" \
    || fail "valid deployment did not check daemon state"
grep -Fxq 'reload 5gpn-dns' "$SYSTEMCTL_LOG" \
    || fail "valid deployment did not reload 5gpn-dns"
if find "$CERT_ROOT" -type f \( -name '.fullchain.pem.*' -o -name '.privkey.pem.*' \) \
    | grep -q .; then
    fail "staging files were left behind after successful publication"
fi
pass "valid pair is staged, published, permissioned, and then reloaded"

before="$(cksum "$CERT_ROOT/dot/fullchain.pem" "$CERT_ROOT/dot/privkey.pem")"

# Missing wildcard SAN must fail before any live role is changed or reloaded.
generate_cert "$LE_LIVE_ROOT/example.test" 'DNS:example.test'
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test"
if renew_hook_main >/dev/null 2>&1; then
    fail "certificate without wildcard SAN was accepted"
fi
after="$(cksum "$CERT_ROOT/dot/fullchain.pem" "$CERT_ROOT/dot/privkey.pem")"
[[ "$before" == "$after" ]] || fail "SAN validation failure changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "SAN validation failure reloaded the daemon"
pass "missing apex/wildcard coverage fails closed before publication"

# A valid-SAN leaf paired with a different private key must likewise fail closed.
generate_cert "$LE_LIVE_ROOT/example.test" 'DNS:example.test,DNS:*.example.test'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$LE_LIVE_ROOT/example.test/privkey.pem" >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "mismatched certificate/private key was accepted"
fi
after="$(cksum "$CERT_ROOT/dot/fullchain.pem" "$CERT_ROOT/dot/privkey.pem")"
[[ "$before" == "$after" ]] || fail "key mismatch changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "key mismatch reloaded the daemon"
pass "certificate/private-key mismatch fails closed before publication"

echo "renew hook tests: PASS"
