#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$ROOT/install.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "installer interception leaf v2: SKIP (jq unavailable in the development shell)"
    exit 0
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP="$(mktemp -d /tmp/5gpn-installer-leaf-v2.XXXXXX)"
case "$TMP" in
    /tmp/*|/var/tmp/*) ;;
    *) fail "unexpected temporary directory: $TMP" ;;
esac
trap 'rm -rf -- "$TMP"' EXIT

INTERCEPT_CA_DIR="$TMP/intercept-ca"
INTERCEPT_DIR="$TMP/intercept"
CERT_REQUEST_FILE="$TMP/certificate-request"
mkdir -p "$INTERCEPT_CA_DIR" "$INTERCEPT_DIR/tls"

openssl req -x509 -newkey rsa:2048 -nodes -days 397 -sha256 \
    -subj '/CN=Installer Test Root' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$INTERCEPT_CA_DIR/root.key" -out "$INTERCEPT_CA_DIR/root.crt" \
    >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=api.example.com' \
    -keyout "$INTERCEPT_DIR/tls/privkey.pem" -out "$TMP/leaf.csr" >/dev/null 2>&1
printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth' \
    'subjectAltName=DNS:api.example.com' > "$TMP/leaf.ext"
openssl x509 -req -sha256 -days 397 -in "$TMP/leaf.csr" \
    -CA "$INTERCEPT_CA_DIR/root.crt" -CAkey "$INTERCEPT_CA_DIR/root.key" \
    -CAcreateserial -extfile "$TMP/leaf.ext" -out "$INTERCEPT_DIR/tls/leaf.crt" \
    >/dev/null 2>&1
cat "$INTERCEPT_DIR/tls/leaf.crt" "$INTERCEPT_CA_DIR/root.crt" \
    > "$INTERCEPT_DIR/tls/fullchain.pem"

target="$(printf 'api.example.com\n' | sha256sum | awk '{print $1}')"
attempt='0123456789abcdef0123456789abcdef'
jq -nc --arg target "$target" --arg attempt "$attempt" \
    '{version:1,target_digest:$target,attempt:$attempt,hosts:["api.example.com"]}' \
    > "$CERT_REQUEST_FILE"
certificate_hash="$(sha256sum "$INTERCEPT_DIR/tls/fullchain.pem" | awk '{print $1}')"
private_key_hash="$(sha256sum "$INTERCEPT_DIR/tls/privkey.pem" | awk '{print $1}')"
jq -nc --arg target "$target" --arg attempt "$attempt" \
    --arg certificate "$certificate_hash" --arg key "$private_key_hash" \
    '{version:1,target_digest:$target,attempt:$attempt,status:"ready",certificate_sha256:$certificate,private_key_sha256:$key}' \
    > "$INTERCEPT_DIR/cert-state"

validate_intercept_leaf || fail "matching fenced JSON request/result was rejected"
cp "$INTERCEPT_DIR/tls/leaf.crt" "$TMP/valid-leaf.crt"
cp "$INTERCEPT_DIR/tls/fullchain.pem" "$TMP/valid-fullchain.pem"
cp "$INTERCEPT_DIR/cert-state" "$TMP/valid-state.json"

write_leaf_variant() {
    local common_name="$1" san="$2"
    openssl req -new -sha256 -key "$INTERCEPT_DIR/tls/privkey.pem" \
        -subj "/CN=${common_name}" -out "$TMP/variant.csr" >/dev/null 2>&1
    printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature,keyEncipherment' \
        'extendedKeyUsage=serverAuth' \
        "subjectAltName=${san}" > "$TMP/variant.ext"
    openssl x509 -req -sha256 -days 397 -in "$TMP/variant.csr" \
        -CA "$INTERCEPT_CA_DIR/root.crt" -CAkey "$INTERCEPT_CA_DIR/root.key" \
        -set_serial "0x$(openssl rand -hex 16)" -extfile "$TMP/variant.ext" \
        -out "$INTERCEPT_DIR/tls/leaf.crt" >/dev/null 2>&1
    cat "$INTERCEPT_DIR/tls/leaf.crt" "$INTERCEPT_CA_DIR/root.crt" \
        > "$INTERCEPT_DIR/tls/fullchain.pem"
    certificate_hash="$(sha256sum "$INTERCEPT_DIR/tls/fullchain.pem" | awk '{print $1}')"
    jq --arg certificate "$certificate_hash" '.certificate_sha256 = $certificate' \
        "$TMP/valid-state.json" > "$INTERCEPT_DIR/cert-state"
}

write_leaf_variant api.example.com 'DNS:api.example.com,DNS:extra.example.com'
if validate_intercept_leaf; then
    fail "a certificate with an extra SAN was accepted as the exact generation"
fi
write_leaf_variant '*.example.com' 'DNS:*.example.com'
if validate_intercept_leaf; then
    fail "a wildcard covering an exact requested host was accepted as the exact generation"
fi
cp "$TMP/valid-leaf.crt" "$INTERCEPT_DIR/tls/leaf.crt"
cp "$TMP/valid-fullchain.pem" "$INTERCEPT_DIR/tls/fullchain.pem"
cp "$TMP/valid-state.json" "$INTERCEPT_DIR/cert-state"

jq '.attempt = "ffffffffffffffffffffffffffffffff"' "$INTERCEPT_DIR/cert-state" \
    > "$TMP/mismatched-state"
mv "$TMP/mismatched-state" "$INTERCEPT_DIR/cert-state"
if validate_intercept_leaf; then
    fail "mismatched request/result attempts were accepted"
fi

printf '%s\napi.example.com\n' "$target" > "$CERT_REQUEST_FILE"
printf '%s\n' "$target" > "$INTERCEPT_DIR/cert-state"
if validate_intercept_leaf; then
    fail "retired plaintext certificate control files were accepted"
fi

echo "installer interception leaf v2: PASS"
