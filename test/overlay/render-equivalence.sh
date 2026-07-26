#!/usr/bin/env bash
# Proves a change to seed rendering did not change what is rendered.
#
# Several independent renderers expand etc/mihomo/config.yaml.tmpl. Consolidating
# them is worth doing, but the install path has broken repeatedly under changes
# that looked safe, so the consolidation needs a property stronger than review.
#
# The property is narrow on purpose: the same renderer, before and after a
# change, produces the same bytes for the same inputs. It deliberately does not
# carry a reference implementation to compare against — that would be one more
# copy of the logic under test, which is the problem this is meant to help
# retire. Whether the output is *correct* is what `mihomo -t` and the live
# verification answer; this answers only whether it moved.
#
#   test/overlay/render-equivalence.sh capture /tmp/before
#   ...make the change...
#   test/overlay/render-equivalence.sh capture /tmp/after
#   test/overlay/render-equivalence.sh compare /tmp/before /tmp/after
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$ROOT/etc/mihomo/config.yaml.tmpl"

# Fixed inputs, so any difference in output is a difference in the renderer.
V_GATEWAY_IP="10.0.0.1"
V_CONSOLE_DOMAIN="console.example.test"
V_ZASH_DOMAIN="zash.example.test"
V_CONTROLLER_SECRET="equivalence-secret"
V_IN_USER="equivalence-inbound-user"
V_IN_PASS="equivalence-inbound-password-123456"
V_UP_USER="equivalence-upstream-user"
V_UP_PASS="equivalence-upstream-password-123456"
V_LISTENERS='  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.example.test:443}'

substitute_values() {
    local line="$1"
    line="${line//__GATEWAY_IP__/$V_GATEWAY_IP}"
    line="${line//__CONSOLE_DOMAIN__/$V_CONSOLE_DOMAIN}"
    line="${line//__ZASH_DOMAIN__/$V_ZASH_DOMAIN}"
    line="${line//__CONTROLLER_SECRET__/$V_CONTROLLER_SECRET}"
    line="${line//__INTERCEPT_INBOUND_USERNAME__/$V_IN_USER}"
    line="${line//__INTERCEPT_INBOUND_PASSWORD__/$V_IN_PASS}"
    line="${line//__INTERCEPT_UPSTREAM_USERNAME__/$V_UP_USER}"
    line="${line//__INTERCEPT_UPSTREAM_PASSWORD__/$V_UP_PASS}"
    printf '%s\n' "$line"
}

# Exercised through install.sh's real functions rather than a transcription of
# them; a transcription would drift from the thing under test.
render_installer() {
    local overlay="$1" mode="$2" line
    (
        OVERLAY_OWNER="5gpn"
        OVERLAY_CONTROL_SOCKET="/run/mihomo/overlay-control.sock"
        OVERLAY_GENERATION_SOCKET="/run/mihomo/overlay-generation.sock"
        OVERLAY_CONTROL_GROUP="5gpn-overlay-ctl"
        OVERLAY_GENERATION_GROUP="5gpn-overlay-gen"
        DNS_SERVICE_USER="gpn-dns"
        INTERCEPT_SERVICE_USER="gpn-intercept"
        err() { :; }
        eval "$(awk '/^render_overlay_runtime_block\(\) \{/,/^\}/' "$ROOT/install.sh")"
        eval "$(awk '/^render_overlay_placeholder\(\) \{/,/^\}/' "$ROOT/install.sh")"
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                __MIHOMO_LISTENERS__) printf '%s\n' "$V_LISTENERS"; continue ;;
                __OVERLAY_EGRESS_ANCHOR__|__OVERLAY_CLIENT_ANCHOR__|__OVERLAY_RUNTIME_BLOCK__)
                    render_overlay_placeholder "$line" "$overlay" "$mode"; continue ;;
            esac
            substitute_values "$line"
        done < "$TEMPLATE"
    )
}

capture() {
    local out="$1"
    mkdir -p "$out"
    render_installer 1 probe > "$out/installer-anchored-probe.yaml"
    render_installer 0 probe > "$out/installer-plain-probe.yaml"
    echo "captured $(ls -1 "$out"/*.yaml | wc -l) renderings into $out"
}

compare() {
    local a="$1" b="$2" f name rc=0
    for f in "$a"/*.yaml; do
        name="$(basename "$f")"
        if [[ ! -f "$b/$name" ]]; then
            echo "  MISSING in $b: $name"; rc=1; continue
        fi
        if diff -q "$f" "$b/$name" >/dev/null; then
            echo "  identical: $name"
        else
            echo "  DIFFERS:   $name"
            diff "$f" "$b/$name" | head -12
            rc=1
        fi
    done
    (( rc == 0 )) \
        && echo "render-equivalence: rendering is unchanged" \
        || echo "render-equivalence: rendering changed"
    return "$rc"
}

# What can be asserted without a before: every rendering resolves fully. A
# renderer that leaves a placeholder behind produces a config that either fails
# to parse or carries the literal into a live file, which is the failure this
# whole area keeps producing.
selfcheck() {
    local tmp rc=0 f
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    capture "$tmp" >/dev/null
    for f in "$tmp"/*.yaml; do
        if grep -qE '__[A-Z0-9_]+__' "$f"; then
            echo "  FAIL: $(basename "$f") left placeholders unresolved:"
            grep -oE '__[A-Z0-9_]+__' "$f" | sort -u | sed 's/^/    /'
            rc=1
        else
            echo "  ok: $(basename "$f") resolves every placeholder"
        fi
        [[ -s "$f" ]] || { echo "  FAIL: $(basename "$f") is empty"; rc=1; }
    done
    return "$rc"
}

case "${1:-}" in
    capture) capture "${2:?usage: capture <dir>}" ;;
    compare) compare "${2:?usage: compare <before> <after>}" "${3:?}" ;;
    selfcheck) selfcheck ;;
    *) echo "usage: $0 {capture <dir>|compare <before> <after>|selfcheck}" >&2; exit 2 ;;
esac
