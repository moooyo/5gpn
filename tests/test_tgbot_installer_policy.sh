#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
HELPER="$ROOT/scripts/setup-tgbot.sh"
EXAMPLE="$ROOT/etc/5gpn-dns/dns.env.example"
FAIL=0
fail(){ echo "FAIL: $1"; FAIL=1; }
setup_fn="$(sed -n '/^setup_tgbot_live()/,/^}/p' "$HELPER")"
write_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"

grep -Fq 'source "$helper"' "$INSTALL" || fail "install.sh does not source Telegram helper"
grep -Fq 'setup_tgbot_live "$@"' "$INSTALL" || fail "public setup command does not delegate"
grep -Fq 'Telegram configuration requires the TUI' "$INSTALL" || fail "public setup is not TUI-gated"
grep -Fq 'unset TGBOT_TOKEN TGBOT_ADMINS DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS' "$INSTALL" \
    || fail "public setup does not discard Telegram environment values"
printf '%s' "$setup_fn" | grep -Fq 'tgbot_api_call GET' || fail "redacted live token cannot be retained"
printf '%s' "$setup_fn" | grep -Fq 'tgbot_api_call PUT' || fail "validated live apply path missing"
printf '%s' "$setup_fn" | grep -Fq 'persist_tgbot_startup_settings' || fail "proxy/alerts are not atomically persisted"
printf '%s' "$setup_fn" | grep -Fq 'systemctl restart 5gpn-dns' || fail "startup settings do not restart"
printf '%s' "$setup_fn" | grep -Eq '\$\{TGBOT_(TOKEN|ADMINS|PROXY_URL|ALERTS)(:-|\+x)' \
    && fail "Telegram helper accepts caller environment"
for line in 'DNS_TGBOT_FILE=${tg_file}' 'TGBOT_PROXY_URL=${tg_proxy}' 'TGBOT_ALERTS=${tg_alerts}'; do
    printf '%s' "$write_fn" | grep -Fq "$line" || fail "dns.env writer omits $line"
done
printf '%s' "$write_fn" | grep -Eq '\$\{TGBOT_(TOKEN|ADMINS|PROXY_URL|ALERTS)(:-|\+x)' \
    && fail "dns.env writer accepts Telegram environment overrides"
grep -Fxq 'DNS_TGBOT_FILE=/etc/5gpn/tgbot.json' "$EXAMPLE" || fail "example lacks DNS_TGBOT_FILE"
grep -Fxq 'TGBOT_PROXY_URL=' "$EXAMPLE" || fail "example lacks TGBOT_PROXY_URL"
grep -Fxq 'TGBOT_ALERTS=false' "$EXAMPLE" || fail "example lacks default-off alerts"

[[ "$FAIL" == 0 ]] && echo "tgbot installer policy: PASS" || exit 1
