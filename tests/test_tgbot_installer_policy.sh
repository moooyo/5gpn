#!/usr/bin/env bash
# Telegram configuration belongs only to the core-owned bot document.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
EXAMPLE="$ROOT/etc/5gpn/dns.env.example"
FAIL=0

fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "ok: $1"; }

write_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"
active="$(sed -n '/^readonly DNS_ENV_KEYS=/,/"$/p' "$INSTALL")"

if grep -Eq 'setup_tgbot\(\)|setup-tgbot\)' "$INSTALL"; then
    fail "install.sh advertises a setup-tgbot command whose helper does not exist"
fi

for key in TGBOT_TOKEN TGBOT_ADMINS DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS DNS_MARKETPLACES_FILE; do
    printf '%s' "$active" | grep -Fq "$key" \
        && fail "$key is still an accepted dns.env key"
    printf '%s' "$write_fn" | grep -Fq "${key}=" \
        && fail "the dns.env writer still emits $key"
    grep -Eq "^${key}=" "$EXAMPLE" \
        && fail "the example still documents $key"
done

(
    export INSTALL_SH_LIB_ONLY=1
    # shellcheck source=../install.sh
    source "$INSTALL"
    retired_env="$(mktemp)"
    trap 'rm -f -- "$retired_env"' EXIT
    printf '%s\n' \
        'DNS_BASE_DOMAIN=example.test' \
        'TGBOT_TOKEN=retired-token' \
        > "$retired_env"
    ! validate_dns_env_schema "$retired_env" >/dev/null 2>&1
) || fail "retired Telegram dns.env keys are not rejected"

if grep -Eq 'DNS_ENV_RETIRED_KEYS|remove_retired_installer_state_files\(\)' "$INSTALL"; then
    fail "legacy Telegram or marketplace compatibility teardown remains"
else
    pass "legacy Telegram and marketplace footprints have no compatibility path"
fi

# The bot document is the core's to create, not the installer's: 5gpn/bot opens
# it at startup and writes a disabled default if it is absent. An installer that
# seeded it would be a second writer for a file holding a credential.
grep -v '^[[:space:]]*#' "$INSTALL" | grep -Fq '5gpn/bot.json' \
    && fail "install.sh writes 5gpn/bot.json, which the core owns"

if [[ "$FAIL" == 0 ]]; then
    echo "tgbot installer policy: PASS"
else
    exit 1
fi
