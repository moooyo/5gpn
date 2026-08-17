#!/usr/bin/env bash
# Holds the repository-owned deployment boundary for the monolith resolver.
# Runtime DNS behavior is tested in the mihomo fork. This suite verifies that
# the installer seeds and refreshes the one live DNS document, preserves its
# operator-owned fields, and does not recreate a standalone DNS service.
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
compat_dns_fn="$(sed -n '/^current_dns_document_is_compatible()/,/^}/p' "$INSTALL")"
write_dns_env_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL")"
[[ -n "$seed_dns_fn" ]] || fail "install.sh: seed_dns_document() is missing"
[[ -n "$render_dns_fn" ]] || fail "install.sh: render_fresh_dns_document() is missing"
[[ -n "$compat_dns_fn" ]] || fail "install.sh: current DNS compatibility validator is missing"
[[ -n "$write_dns_env_fn" ]] || fail "install.sh: write_dns_env() is missing"

# --- dns.json is the sole live resolver document ---
grep -Fq 'FIVEGPN_STATE_DIR="/etc/5gpn/mihomo/5gpn"' "$INSTALL" \
    || fail "install.sh: monolith state directory is not /etc/5gpn/mihomo/5gpn"
printf '%s' "$seed_dns_fn" | grep -Fq 'target="${state_dir}/dns.json"' \
    || fail "seed_dns_document does not target the monolith DNS document"
printf '%s' "$seed_dns_fn" | grep -Fq 'dot="$DOT_LISTEN_ADDR" debug="$DEBUG_LISTEN_ADDR"' \
    && grep -Fq 'DOT_LISTEN_ADDR=":853"' "$INSTALL" \
    && grep -Fq 'DEBUG_LISTEN_ADDR="127.0.0.1:5353"' "$INSTALL" \
    || fail "fresh DNS document does not use the fixed DoT/debug listener constants"
printf '%s' "$render_dns_fn" | grep -Fq -- '--arg dot "$dot" --arg debug "$debug" --arg origin "$ORIGIN_LISTEN_ADDR"' \
    && grep -Fq 'ORIGIN_LISTEN_ADDR="127.0.0.1:5354"' "$INSTALL" \
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

    safe_numbers="$(mktemp "${TMPDIR:-/tmp}/5gpn-dns-safe-numbers.XXXXXX")"
    unsafe_numbers="$(mktemp "${TMPDIR:-/tmp}/5gpn-dns-unsafe-numbers.XXXXXX")"
    printf '%s\n' '{"intervalSeconds":9007199254740991}' > "$safe_numbers"
    printf '%s\n' '{"intervalSeconds":9007199254740993}' > "$unsafe_numbers"
    (
        export INSTALL_SH_LIB_ONLY=1
        # shellcheck source=../install.sh
        source "$INSTALL"
        dns_document_is_jq_gateway_update_safe "$safe_numbers" \
            && ! dns_document_is_jq_gateway_update_safe "$unsafe_numbers"
    ) || fail "gateway-only updater accepts a number jq cannot preserve exactly"
    rm -f -- "$safe_numbers" "$unsafe_numbers"
fi

# Reinstall validates all fixed listener/key coordinates and updates only the
# separately checked installation-owned gateway. Drift fails closed instead of
# being repaired by an implicit rewrite.
for check in \
    '.listen.dot == $dot' \
    '.listen.debug == $debug' \
    '.listen.origin == $origin' \
    '.listen.certificate == $cert' \
    '.listen.privateKey == $key'; do
    printf '%s' "$compat_dns_fn" | grep -Fq "$check" \
        || fail "current DNS compatibility validation is missing $check"
done
printf '%s' "$compat_dns_fn" | grep -Eq '\.(upstreams|policy|tuning)' \
    && fail "current DNS compatibility helper duplicates Core-owned schema validation"
[[ "$(printf '%s' "$seed_dns_fn" | grep -Fc 'current_dns_document_is_compatible')" -ge 2 ]] \
    || fail "DNS seeding does not validate both the live document and gateway-update candidate"
printf '%s' "$seed_dns_fn" | grep -Fq 'VALIDATED_DNS_SOURCE_REVISION' \
    && printf '%s' "$seed_dns_fn" | grep -Fq 'DNS document changed while its gateway update was staged.' \
    || fail "DNS publication is not bound to the pre-publication Core-validated source revision"
printf '%s' "$seed_dns_fn" | grep -Fq 'validate_dns_candidate_with_staged_core "$tmp"' \
    || fail "actual DNS publication candidates are not revalidated by the staged Core"
quiescent_line="$(grep -n 'assert_dns_publication_quiescent' <<<"$seed_dns_fn" | head -1 | cut -d: -f1)"
quiesced_validate_line="$(grep -n 'validate_existing_runtime_documents' <<<"$seed_dns_fn" | head -1 | cut -d: -f1)"
existing_line="$(grep -nF 'if [[ -f "$target" ]]' <<<"$seed_dns_fn" | head -1 | cut -d: -f1)"
[[ -n "$quiescent_line" && -n "$quiesced_validate_line" && -n "$existing_line" \
   && "$quiescent_line" -lt "$quiesced_validate_line" \
   && "$quiesced_validate_line" -lt "$existing_line" ]] \
    || fail "runtime documents are not revalidated by the staged Core after writer quiescence"
full_install_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
account_line="$(grep -n '^[[:space:]]*install_service_accounts' <<<"$full_install_fn" | head -1 | cut -d: -f1)"
seed_line="$(grep -n '^[[:space:]]*seed_dns_document' <<<"$full_install_fn" | head -1 | cut -d: -f1)"
[[ -n "$account_line" && -n "$seed_line" && "$account_line" -lt "$seed_line" ]] \
    || fail "DNS publication can run before the service-account quiescence transaction"
validate_runtime_fn="$(sed -n '/^validate_existing_runtime_documents()/,/^}/p' "$INSTALL")"
printf '%s' "$validate_runtime_fn" | grep -Fq 'VALIDATED_DNS_SOURCE_REVISION="$dns_revision_after"' \
    && printf '%s' "$validate_runtime_fn" | grep -Fq 'current_dns_document_is_compatible "$dns_document"' \
    || fail "staged Core validation does not publish the exact DNS source revision dependency"
stage_fn="$(sed -n '/^stage_artifacts()/,/^}/p' "$INSTALL")"
printf '%s' "$stage_fn" | grep -Fq 'state-seed-probe' \
    && printf '%s' "$stage_fn" | grep -Fq 'Staged mihomo rejected the DNS document seed' \
    || fail "fresh DNS seed is not validated by the staged pinned Core before publication"
printf '%s' "$seed_dns_fn" | grep -Fq "'.gateway == \$gw'" \
    || fail "unchanged current DNS documents are not preserved byte-for-byte"
printf '%s' "$seed_dns_fn" | grep -Fq "'.gateway = \$gw'" \
    || fail "existing DNS document does not update the checked gateway"
printf '%s' "$seed_dns_fn" | grep -Eq '\.listen\.(dot|debug|origin)[[:space:]]*=' \
    && fail "reinstall rewrites an operator-owned DNS listener address"
printf '%s' "$seed_dns_fn" | grep -Eq '\.listen\.(certificate|privateKey)[[:space:]]*=' \
    && fail "reinstall silently rewrites a drifted DoT key path"
printf '%s' "$seed_dns_fn" | grep -Eq '\.(upstreams|policy|tuning)[[:space:]]*=' \
    && fail "reinstall rewrites operator-owned live DNS settings"

# The live document is service-owned, mode 0600, and atomically renamed.
printf '%s' "$seed_dns_fn" | grep -Fq 'chown "${FIVEGPN_SERVICE_USER}:${FIVEGPN_SERVICE_GROUP}" "$tmp"' \
    || fail "DNS document candidate is not owned by the monolith identity"
printf '%s' "$seed_dns_fn" | grep -Fq 'chmod 0600 "$tmp"' \
    || fail "DNS document candidate is not mode 0600"
printf '%s' "$seed_dns_fn" | grep -Fq 'mv -Tf -- "$tmp" "$target"' \
    || fail "DNS document is not published by same-directory atomic rename"

# Fresh state is rendered only from current installation inputs. Retired
# resolver-group keys are neither consumed nor persisted.
printf '%s' "$seed_dns_fn" | grep -Eq 'cfg_get DNS_(CHINA|TRUST)' \
    && fail "fresh DNS seeding still consumes retired dns.env resolver groups"
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
grep -Eq '^[[:space:]]*DNS_EGRESS_RESOLVER=' "$INSTALL" \
    && fail "install.sh: retired DNS_EGRESS_RESOLVER is still persisted"
grep -Fq 'XRAY_RESOLVER' "$INSTALL" \
    && fail "install.sh: removed XRAY_RESOLVER key remains"
printf '%s\n' "$write_dns_env_fn" | grep -Eq '^[[:space:]]*DNS_API_TOKEN=' \
    && fail "write_dns_env emits the retired standalone API credential"
grep -Fq 'DNS_API_TOKEN="$(openssl rand' "$INSTALL" \
    && fail "install.sh: generates the retired standalone API credential again"
grep -Eq '^persist_mihomo_secret\(\)|DNS_MIHOMO_SECRET=' "$INSTALL" \
    && fail "install.sh: controller secret is still mirrored into dns.env"
printf '%s' "$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")" \
    | grep -Fq 'mihomo_controller_inspection "$config"' \
    || fail "install.sh: existing controller state is not read through the core inspector"

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
