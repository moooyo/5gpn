#!/usr/bin/env bash
# Holds the repository-owned deployment boundary for the monolith resolver.
# Runtime DNS behavior is tested in the mihomo fork. This suite verifies that
# the installer seeds and refreshes the one live DNS document, preserves its
# operator-owned fields, and does not recreate a standalone DNS service.
#
# Legacy dns.env values may be read once while creating a missing document.
# They are migration input, not a second live resolver configuration surface.
#
# Pure grep — runs on the dev box under Git Bash, no Linux/Python needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
RENEW="$ROOT/scripts/renew-hook.sh"

grep -Fq 'moooyo/5gpn' "$INSTALL" \
    || fail "install.sh: release URL not from moooyo/5gpn"

seed_dns_fn="$(sed -n '/^seed_dns_document()/,/^}/p' "$INSTALL")"
render_dns_fn="$(sed -n '/^render_fresh_dns_document()/,/^}/p' "$INSTALL")"
write_dns_env_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"
full_install_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
[[ -n "$seed_dns_fn" ]] || fail "install.sh: seed_dns_document() is missing"
[[ -n "$render_dns_fn" ]] || fail "install.sh: render_fresh_dns_document() is missing"
[[ -n "$write_dns_env_fn" ]] || fail "install.sh: write_dns_env() is missing"

# --- dns.json is the sole live resolver document ---
grep -Fq 'FIVEGPN_STATE_DIR="/etc/5gpn/mihomo/5gpn"' "$INSTALL" \
    || fail "install.sh: monolith state directory is not /etc/5gpn/mihomo/5gpn"
printf '%s' "$seed_dns_fn" | grep -Fq 'target="${state_dir}/dns.json"' \
    || fail "seed_dns_document does not target the monolith DNS document"
printf '%s' "$seed_dns_fn" | grep -Fq 'dot="${dot:-:853}"' \
    || fail "fresh DNS document does not default client ingress to DoT :853"
printf '%s' "$seed_dns_fn" | grep -Fq 'debug="${debug:-127.0.0.1:5353}"' \
    || fail "fresh DNS document does not keep debug DNS on loopback :5353"
printf '%s' "$render_dns_fn" | grep -Fq -- '--arg dot "$dot" --arg debug "$debug" --arg origin "127.0.0.1:5354"' \
    || fail "fresh DNS document does not pin the origin resolver to loopback :5354"
printf '%s' "$render_dns_fn" | grep -Fq 'certificate: $cert, privateKey: $key' \
    || fail "fresh DNS document does not carry the installer-owned DoT keypair"
printf '%s' "$render_dns_fn" | grep -Fq 'gateway:   $gw' \
    || fail "fresh DNS document does not carry the selected gateway address"
printf '%s' "$render_dns_fn" | grep -Fq 'upstreams: {china: ($china | addrs), trust: ($trust | addrs), ecs: $ecs}' \
    || fail "fresh DNS document does not seed both resolver groups and ECS"
printf '%s' "$render_dns_fn" | grep -Fq 'id: "china-domains", kind: "subscription"' \
    && printf '%s' "$render_dns_fn" | grep -Fq 'intent: "direct", enabled: true, format: "clash"' \
    && printf '%s' "$render_dns_fn" | grep -Fq 'id: "gfwlist", kind: "subscription"' \
    && printf '%s' "$render_dns_fn" | grep -Fq 'intent: "proxy", enabled: true, format: "plain"' \
    && printf '%s' "$render_dns_fn" | grep -Fq 'fallback: "auto"' \
    || fail "fresh DNS document does not seed the two core default subscriptions and auto fallback"
grep -Fq 'DNS_SUBSCRIPTION_INTERVAL_DEFAULT=86400' "$INSTALL" \
    || fail "fresh DNS subscription interval drifted from the core default"
grep -Fq 'blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml' "$INSTALL" \
    && grep -Fq 'Loyalsoldier/v2ray-rules-dat/release/gfw.txt' "$INSTALL" \
    || fail "fresh DNS subscription sources drifted from the core defaults"
printf '%s' "$render_dns_fn" | grep -Fq 'tuning:    {}' \
    || fail "fresh DNS document does not seed the tuning object"

if command -v jq >/dev/null 2>&1; then
    rendered_dns="$(
        export INSTALL_SH_LIB_ONLY=1
        # shellcheck source=../install.sh
        source "$INSTALL"
        render_fresh_dns_document ':853' '127.0.0.1:5353' \
            '/cert.pem' '/key.pem' '192.0.2.1' '112.96.32.0/24' \
            '223.5.5.5' '22.22.22.22'
    )" || fail "fresh DNS renderer failed"
    printf '%s' "$rendered_dns" | jq -e '
        .listen == {dot:":853",debug:"127.0.0.1:5353",origin:"127.0.0.1:5354",certificate:"/cert.pem",privateKey:"/key.pem"}
        and .gateway == "192.0.2.1"
        and .upstreams == {china:["223.5.5.5:53"],trust:["22.22.22.22:53"],ecs:"112.96.32.0/24"}
        and (.policy.rules | length) == 2
        and .policy.rules[0].id == "china-domains"
        and .policy.rules[1].id == "gfwlist"
        and .policy.fallback == "auto"
        and .tuning == {}
    ' >/dev/null || fail "fresh DNS renderer produced an invalid document"
fi

# Reinstall refreshes only installation-owned fields. Policy, upstreams,
# listener addresses, and tuning remain the operator's current document.
for assignment in \
    '.listen.certificate = $cert' \
    '.listen.privateKey = $key' \
    '.gateway = $gw'; do
    printf '%s' "$seed_dns_fn" | grep -Fq "$assignment" \
        || fail "existing DNS document does not refresh $assignment"
done
printf '%s' "$seed_dns_fn" | grep -Eq '\.listen\.(dot|debug|origin)[[:space:]]*=' \
    && fail "reinstall rewrites an operator-owned DNS listener address"
printf '%s' "$seed_dns_fn" | grep -Eq '\.(upstreams|policy|tuning)[[:space:]]*=' \
    && fail "reinstall rewrites operator-owned live DNS settings"

# The live document is service-owned, mode 0600, and atomically renamed.
printf '%s' "$seed_dns_fn" | grep -Fq 'chown "${FIVEGPN_SERVICE_USER}:${FIVEGPN_SERVICE_GROUP}" "$tmp"' \
    || fail "DNS document candidate is not owned by the monolith identity"
printf '%s' "$seed_dns_fn" | grep -Fq 'chmod 0600 "$tmp"' \
    || fail "DNS document candidate is not mode 0600"
printf '%s' "$seed_dns_fn" | grep -Fq 'mv -Tf -- "$tmp" "$target"' \
    || fail "DNS document is not published by same-directory atomic rename"

# A missing document is seeded before dns.env is rewritten, so exact retired
# upstream values can be consumed once and then dropped from the current file.
printf '%s' "$seed_dns_fn" | grep -Fq 'cfg_get DNS_CHINA' \
    || fail "first seed no longer carries the legacy China upstream input"
printf '%s' "$seed_dns_fn" | grep -Fq 'cfg_get DNS_TRUST' \
    || fail "first seed no longer carries the legacy trust upstream input"
seed_call_line="$(printf '%s\n' "$full_install_fn" | grep -nE '^[[:space:]]*seed_dns_document([[:space:]]|$)' | cut -d: -f1)"
env_call_line="$(printf '%s\n' "$full_install_fn" | grep -nE '^[[:space:]]*write_dns_env([[:space:]]|$)' | cut -d: -f1)"
if [[ -z "$seed_call_line" || -z "$env_call_line" || "$seed_call_line" -ge "$env_call_line" ]]; then
    fail "full_install must seed dns.json before rewriting migration inputs in dns.env"
fi
printf '%s\n' "$write_dns_env_fn" | grep -Eq '^[[:space:]]*DNS_(CHINA|TRUST)=' \
    && fail "write_dns_env still persists retired resolver-group keys"

# dns.env remains an installer-owned, root-only deployment record. It is not
# the live resolver document, but its safe publication contract is current.
printf '%s' "$write_dns_env_fn" | grep -Fq 'validate_dns_env_schema "$dns_env_tmp"' \
    || fail "dns.env candidate is not schema-validated before publication"
printf '%s' "$write_dns_env_fn" | grep -Fq 'chown root:root "$dns_env_tmp"' \
    || fail "dns.env candidate is not root-owned"
printf '%s' "$write_dns_env_fn" | grep -Fq 'chmod 0600 "$dns_env_tmp"' \
    || fail "dns.env candidate is not mode 0600"
printf '%s' "$write_dns_env_fn" | grep -Fq 'mv -f -- "$dns_env_tmp" "${CONF_DIR}/dns.env"' \
    || fail "dns.env is not atomically published"

# --- Explicit retired-input and removed-component guards ---
grep -Fq 'Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER' "$INSTALL" \
    || fail "install.sh: retired DNS_EGRESS_RESOLVER is not rejected explicitly"
grep -Eq '^[[:space:]]*DNS_EGRESS_RESOLVER=' "$INSTALL" \
    && fail "install.sh: retired DNS_EGRESS_RESOLVER is still persisted"
grep -Fq 'XRAY_RESOLVER' "$INSTALL" \
    && fail "install.sh: removed XRAY_RESOLVER key remains"
printf '%s\n' "$write_dns_env_fn" | grep -Eq '^[[:space:]]*DNS_API_TOKEN=' \
    && fail "write_dns_env emits the retired standalone API credential"
grep -Fq 'DNS_API_TOKEN="$(openssl rand' "$INSTALL" \
    && fail "install.sh: generates the retired standalone API credential again"
grep -Fq 'persist_mihomo_secret "$secret"' "$INSTALL" \
    || fail "install.sh: controller secret is not mirrored after rendering mihomo"

grep -Eq '^DNS_LISTEN_DOH=' "$INSTALL" \
    && fail "install.sh: public DoH ingress returned"
grep -Eq '^DNS_LISTEN_PLAIN=' "$INSTALL" \
    && fail "install.sh: plain :53 ingress returned"
[[ ! -e "$ROOT/etc/systemd/5gpn-dns.service" ]] \
    || fail "retired standalone DNS unit is shipped again"
grep -Eq 'systemctl reload 5gpn-dns|kill -HUP' "$RENEW" \
    && fail "renew-hook.sh: certificate publication calls the retired DNS reload API"
[[ ! -e "$ROOT/scripts/setup-firewall.sh" ]] \
    || fail "scripts/setup-firewall.sh returned (5gpn does not manage the host firewall)"
grep -Eq '(^|[[:space:]])nft([[:space:]]|$)' "$INSTALL" \
    && fail "install.sh: host nftables management returned"
grep -Fq 'remove_legacy_policy_state' "$INSTALL" \
    && fail "install.sh: superseded policy-state helper remains"
grep -Eq 'egress(-nodes)?\.(json|enc)' "$INSTALL" \
    && fail "install.sh: removed structured-egress state path remains"

# Release bundles retain only the current mihomo seed asset and unit.
grep -Fq '${BASE_DIR}/etc/systemd' "$INSTALL" \
    || fail "install.sh: systemd assets are not staged"
grep -Fq '5gpn-mihomo.service' "$INSTALL" \
    || fail "install.sh: current monolith unit is not installed"
grep -Fq '${BASE_DIR}/etc/mihomo' "$INSTALL" \
    || fail "install.sh: mihomo reset assets are not staged"
grep -Fq 'for asset in config.yaml.tmpl; do' "$INSTALL" \
    || fail "install.sh: current mihomo reset template is not retained"

true  # Keep a trailing successful command after intentional && guards.

[[ $rc -eq 0 ]] && echo "5gpn installer policy: PASS"
exit "$rc"
