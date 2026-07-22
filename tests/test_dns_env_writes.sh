#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

CONF_DIR="$TMP/etc-5gpn"
mkdir -p "$CONF_DIR"
printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
printf 'DNS_API_TOKEN=old-token\n' > "$CONF_DIR/dns.env"
cp "$CONF_DIR/dns.env" "$TMP/original.env"

fixed_owned_dir_is_safe() { return 0; }
runtime_file_slot_is_safe() { return 0; }
validate_dns_env_schema() { return 0; }
chown() { return 0; }
sync() { return 0; }
mv() { return 73; }

if set_dns_env_kv "$CONF_DIR/dns.env" DNS_API_TOKEN new-token >/dev/null 2>&1; then
    fail "set_dns_env_kv swallowed an atomic rename failure"
fi
cmp -s "$CONF_DIR/dns.env" "$TMP/original.env" \
    || fail "set_dns_env_kv changed the live file after rename failure"
pass "set_dns_env_kv propagates publication failure and preserves live bytes"

unset -f mv
BASE_DOMAIN=example.com
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
CERT_MODE=debug
CERT_EMAIL=admin@example.com
CHINA_ECS=112.96.32.0/24
CACHE_SIZE=20000
DNS_ZASH_DIR="$TMP/zash"
DNS_WEB_DIR="$TMP/web"
MIHOMO_DIR="$CONF_DIR/mihomo"
INTERCEPT_DIR="$CONF_DIR/intercept"
DNS_RULES_DIR_DEFAULT="$CONF_DIR/rules"
DOT_CERT_DIR="$CONF_DIR/cert/dot"
WEB_CERT_DIR="$CONF_DIR/cert/web"
ZASH_CERT_DIR="$CONF_DIR/cert/zash"
WWW_DIR="$TMP/www"
cfg_get() {
    case "$1" in
        DNS_API_TOKEN) printf '%s' existing-token ;;
        DNS_MIHOMO_SECRET) printf '%s' 'controller"secret' ;;
        *) return 0 ;;
    esac
}
mktemp() { return 74; }

if write_dns_env >/dev/null 2>&1; then
    fail "write_dns_env swallowed candidate creation failure"
fi
cmp -s "$CONF_DIR/dns.env" "$TMP/original.env" \
    || fail "write_dns_env changed live bytes after candidate creation failure"
pass "write_dns_env propagates candidate creation failure"

echo "dns.env write safety: PASS"
