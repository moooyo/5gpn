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
MIHOMO_DIR="$CONF_DIR/mihomo"
INTERCEPT_DIR="$CONF_DIR/intercept"
DNS_RULES_DIR_DEFAULT="$CONF_DIR/rules"
DOT_CERT_DIR="$CONF_DIR/cert/dot"
WEB_CERT_DIR="$CONF_DIR/cert/web"
CONSOLE_CERT_DIR="$CONF_DIR/cert/console"
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

# The dns.env heredoc is unquoted by design: it interpolates ${var} for every
# value it writes. That also makes backticks and $( ) live command substitution,
# so a *comment* carrying either runs at install time.
#
# It has happened: a comment ending "see the `catalogs` field" made the
# installer try to execute `catalogs`, which failed the publication phase with
# exit 127 on a real upgrade. Prose is the one thing nobody proofreads for shell
# metacharacters, and it is the one thing in this heredoc that is pure prose.
#
# Every value is computed into a local beforehand, so ${var} is the only
# substitution the body needs and the other two forms are always a mistake.
heredoc_body="$(sed -n '/^    if ! cat > "\$dns_env_tmp" <<EOF$/,/^EOF$/p' "$ROOT/install.sh")"
[[ -n "$heredoc_body" ]] || fail "could not extract the dns.env heredoc"
if printf '%s' "$heredoc_body" | grep -q '`'; then
    printf '%s' "$heredoc_body" | grep -n '`' >&2
    fail "the dns.env heredoc contains a backtick, which the shell runs as a command"
fi
if printf '%s' "$heredoc_body" | grep -qF '$('; then
    printf '%s' "$heredoc_body" | grep -nF '$(' >&2
    fail "the dns.env heredoc contains \$( ), which the shell runs as a command"
fi
pass "the dns.env heredoc carries no live command substitution"

echo "dns.env write safety: PASS"
