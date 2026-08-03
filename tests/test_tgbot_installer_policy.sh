#!/usr/bin/env bash
# The Telegram bot is configured in the console now, not in dns.env.
#
# It has its own document beside the resolver's and the engine's
# (<mihomo-home>/gpn/bot.json, written 0600 by the core because it carries a
# token), and gpn/bot owns the live path with its own Go tests. What this suite
# holds is the installer's half of that decision:
#
#   - the five TGBOT_* keys are RETIRED, not merely absent. An upgraded host has
#     them in its dns.env; naming them in DNS_ENV_RETIRED_KEYS is what strips
#     them. Dropping them from that list instead would make an upgraded dns.env
#     fail validation on a key this installer wrote itself.
#   - nothing writes them any more, and the example does not document them.
#   - the setup-tgbot command stays gone. It sourced a helper deleted with the
#     three-process layout, so it could only ever have failed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
EXAMPLE="$ROOT/etc/5gpn-dns/dns.env.example"
FAIL=0
fail(){ echo "FAIL: $1"; FAIL=1; }
write_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"
retired="$(sed -n '/^readonly DNS_ENV_RETIRED_KEYS=/,/"$/p' "$INSTALL")"
active="$(sed -n '/^readonly DNS_ENV_KEYS=/,/"$/p' "$INSTALL")"

if grep -Eq 'setup_tgbot\(\)|setup-tgbot\)' "$INSTALL"; then
    fail "install.sh advertises a setup-tgbot command whose helper does not exist"
fi

for key in TGBOT_TOKEN TGBOT_ADMINS DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS DNS_MARKETPLACES_FILE; do
    printf '%s' "$retired" | grep -Fq "$key" \
        || fail "$key is not listed as retired, so an upgraded dns.env carrying it fails validation"
    printf '%s' "$active" | grep -Fq "$key" \
        && fail "$key is still an accepted dns.env key"
    printf '%s' "$write_fn" | grep -Fq "${key}=" \
        && fail "the dns.env writer still emits $key"
    grep -Eq "^${key}=" "$EXAMPLE" \
        && fail "the example still documents $key"
done

# The bot document is the core's to create, not the installer's: gpn/bot opens
# it at startup and writes a disabled default if it is absent. An installer that
# seeded it would be a second writer for a file holding a credential.
#
# Comments are excluded deliberately -- install.sh says where the document
# lives, which is exactly the pointer an operator reading dns.env needs.
grep -v '^[[:space:]]*#' "$INSTALL" | grep -Fq 'gpn/bot.json' \
    && fail "install.sh writes gpn/bot.json, which the core owns"

# The retired files are still removed, and that has to stay true. An upgraded
# host has /etc/5gpn/tgbot.json and extension-marketplaces.json from the layout
# that wrote them; the removal list is the only record they were ever ours, and
# dropping an entry strands whatever it names on every host that has not
# upgraded yet.
for stale in tgbot.json extension-marketplaces.json; do
    grep -Fq "\${CONF_DIR}/${stale}" "$INSTALL" \
        || fail "uninstall no longer removes the retired ${stale}"
done

[[ "$FAIL" == 0 ]] && echo "tgbot installer policy: PASS" || exit 1
