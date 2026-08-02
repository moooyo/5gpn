#!/usr/bin/env bash
# The bot is not ported yet, so what this suite can still hold honest is the
# installer half: dns.env carries the bot's configuration, and neither the
# writer nor the example may take those values from the caller's environment.
#
# The live-configuration assertions went with scripts/setup-tgbot.sh. install.sh
# no longer advertises a setup-tgbot command either -- it sourced that helper,
# so once the helper went the command could only ever have failed. When the bot
# lands in the fork, the live path needs its own coverage there; this file is
# not where it goes.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
EXAMPLE="$ROOT/etc/5gpn-dns/dns.env.example"
FAIL=0
fail(){ echo "FAIL: $1"; FAIL=1; }
write_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"

if grep -Eq 'setup_tgbot\(\)|setup-tgbot\)' "$INSTALL"; then
    fail "install.sh advertises a setup-tgbot command whose helper does not exist"
fi
for line in 'DNS_TGBOT_FILE=${tg_file}' 'TGBOT_PROXY_URL=${tg_proxy}' 'TGBOT_ALERTS=${tg_alerts}'; do
    printf '%s' "$write_fn" | grep -Fq "$line" || fail "dns.env writer omits $line"
done
printf '%s' "$write_fn" | grep -Eq '\$\{TGBOT_(TOKEN|ADMINS|PROXY_URL|ALERTS)(:-|\+x)' \
    && fail "dns.env writer accepts Telegram environment overrides"
grep -Fxq 'DNS_TGBOT_FILE=/etc/5gpn/tgbot.json' "$EXAMPLE" || fail "example lacks DNS_TGBOT_FILE"
grep -Fxq 'TGBOT_PROXY_URL=' "$EXAMPLE" || fail "example lacks TGBOT_PROXY_URL"
grep -Fxq 'TGBOT_ALERTS=false' "$EXAMPLE" || fail "example lacks default-off alerts"

[[ "$FAIL" == 0 ]] && echo "tgbot installer policy: PASS" || exit 1
