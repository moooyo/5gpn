#!/usr/bin/env bash
# Migrate an existing three-process gateway's DNS state into the monolith's one
# document.
#
# The v5 gateway kept its resolver state in four places: policy.json,
# upstreams.json, ecs.json, and the DNS-shaped half of dns.env. Splitting them
# was not a filing decision -- dns.env is installer-owned and read-only to the
# sandboxed daemon, so the console could not repair the file it most needed to,
# and every cross-cutting edit was two writes with no way to name the pair.
#
# The monolith reads one document, <mihomo-home>/gpn/dns.json, with one
# revision. This script writes it from what is already on the box. It does not
# touch the sources: an operator who runs it and then decides to roll back has
# lost nothing.
#
# Usage: migrate-state-to-monolith.sh [--dry-run] [conf-dir] [mihomo-home]
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

CONF_DIR="${1:-/etc/5gpn}"
MIHOMO_HOME="${2:-/etc/5gpn/mihomo}"
STATE_DIR="${MIHOMO_HOME}/gpn"

DNS_ENV="${CONF_DIR}/dns.env"
POLICY="${CONF_DIR}/policy.json"
UPSTREAMS="${CONF_DIR}/upstreams.json"
ECS_FILE="${CONF_DIR}/ecs.json"
RULES_DIR="${CONF_DIR}/rules"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -r "$DNS_ENV" ]] || { echo "cannot read $DNS_ENV" >&2; exit 1; }

# Read only the keys this migration needs, and read them by exact match rather
# than by sourcing the file. Sourcing would execute whatever is in it, and this
# script is frequently run as root against a file the installer wrote.
env_get() {
    local key="$1" line
    line="$(grep -m1 -E "^${key}=" -- "$DNS_ENV" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 0
    line="${line#*=}"
    # The installer quotes values that need it; strip one matched pair.
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

LISTEN_DOT="$(env_get DNS_LISTEN_DOT)"
LISTEN_DEBUG="$(env_get DNS_LISTEN_DEBUG)"
GATEWAY_IP="$(env_get DNS_GATEWAY_IP)"
CHINA_ECS="$(env_get DNS_CHINA_ECS)"

: "${LISTEN_DOT:=:853}"
: "${LISTEN_DEBUG:=127.0.0.1:5353}"

# The origin boundary has no v5 counterpart to migrate: it was a listener inside
# the retired daemon, and the deployed mihomo config already names
# 127.0.0.1:5354 as its nameserver. Reading that port out of the operator's own
# config rather than assuming it is what keeps a non-default deployment working.
ORIGIN="$(grep -oE '127\.0\.0\.1:[0-9]+' "${MIHOMO_HOME}/config.yaml" 2>/dev/null \
    | grep -vE ':(9090|443|80)$' | head -1 || true)"
: "${ORIGIN:=127.0.0.1:5354}"

# ecs.json wins over dns.env when present: the file is what the console writes,
# so it is the later of the two by construction. An explicitly empty subnet in
# it means the operator turned ECS off, which is not the same as never having
# set one -- so the emptiness is honoured rather than filled in from the env.
ECS="$CHINA_ECS"
if [[ -r "$ECS_FILE" ]]; then
    ECS="$(jq -r '.subnet // ""' "$ECS_FILE" 2>/dev/null || printf '%s' "$CHINA_ECS")"
fi

china_json='["223.5.5.5"]'
trust_json='["22.22.22.22"]'
if [[ -r "$UPSTREAMS" ]]; then
    china_json="$(jq -c '.china // ["223.5.5.5"]' "$UPSTREAMS")"
    trust_json="$(jq -c '.trust // ["22.22.22.22"]' "$UPSTREAMS")"
fi

# The rule shape changed in two ways, both removals. The nested matcher object
# is flattened, because it only ever held three fields and one of them was only
# valid for one kind. And the explicit Order field is gone: validation required
# it to equal the rule's own index, which made it a second name for the same
# fact and one more thing a caller could set inconsistently. Slice position is
# the order now.
POLICY_JSON='{"rules":[],"fallback":"auto"}'
if [[ -r "$POLICY" ]]; then
    POLICY_JSON="$(jq -c '
        def dursecs:
            if . == null or . == "" then 0
            else ([scan("([0-9]+)([hms])")]
                  | map((.[0] | tonumber) * (if .[1] == "h" then 3600 elif .[1] == "m" then 60 else 1 end))
                  | add) // 0
            end;
        {
          fallback: (.fallback.policy // "auto"),
          rules: [ (.rules // []) | sort_by(.order) | .[]
                   | { id: .id,
                       kind: .matcher.kind,
                       value: .matcher.value,
                       intent: .intent,
                       enabled: (.enabled // false) }
                     + (if .matcher.kind == "subscription"
                        then { format: (.matcher.format // "plain"),
                               intervalSeconds: (.matcher.interval | dursecs) }
                        else {} end) ]
        }' "$POLICY")"
fi

DOC="$(jq -n \
    --arg dot "$LISTEN_DOT" \
    --arg debug "$LISTEN_DEBUG" \
    --arg origin "$ORIGIN" \
    --arg cert "${CONF_DIR}/cert/dot/current/fullchain.pem" \
    --arg key "${CONF_DIR}/cert/dot/current/privkey.pem" \
    --arg gateway "$GATEWAY_IP" \
    --arg ecs "$ECS" \
    --argjson china "$china_json" \
    --argjson trust "$trust_json" \
    --argjson policy "$POLICY_JSON" \
    '{
        listen:    { dot: $dot, debug: $debug, origin: $origin, certificate: $cert, privateKey: $key },
        gateway:   $gateway,
        upstreams: { china: $china, trust: $trust, ecs: $ecs },
        policy:    $policy,
        tuning:    {}
    }')"

if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s\n' "$DOC"
    exit 0
fi

install -d -m 0700 "$STATE_DIR"
install -d -m 0700 "${STATE_DIR}/dns-rules"

# A subscription cache is keyed on the rule id alone now. The v5 layout put it
# under an intent-named directory, which meant changing a rule's intent orphaned
# a list that was still perfectly good -- the names in it never depended on what
# the operator did with them.
if [[ -d "$RULES_DIR" ]]; then
    for category in block direct proxy; do
        [[ -d "${RULES_DIR}/${category}" ]] || continue
        for cache in "${RULES_DIR}/${category}"/pol_*.txt; do
            [[ -e "$cache" ]] || continue
            base="$(basename -- "$cache")"
            base="${base#pol_}"
            install -m 0600 "$cache" "${STATE_DIR}/dns-rules/${base}"
        done
    done
fi

tmp="$(mktemp "${STATE_DIR}/.dns.json.XXXXXX")"
printf '%s\n' "$DOC" > "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "${STATE_DIR}/dns.json"

rules_migrated="$(printf '%s' "$POLICY_JSON" | jq '.rules | length')"
caches="$(find "${STATE_DIR}/dns-rules" -name '*.txt' 2>/dev/null | wc -l)"
echo "wrote ${STATE_DIR}/dns.json: ${rules_migrated} rule(s), ${caches} subscription cache(s)"
