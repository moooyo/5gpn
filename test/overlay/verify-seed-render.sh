#!/usr/bin/env bash
# Exercises both of the installer's seed renders on a machine that has neither
# the service accounts nor the socket groups.
#
# Artifact staging validates an anchored candidate before installation has
# created either, because whether the core parses the anchors is what decides
# whether they are emitted at all. A renderer that insisted on resolving real
# identities there would abort every fresh install — which is a failure only a
# clean machine can show, and the reason this exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="${1:-}"
[[ -n "$CORE" && -x "$CORE" ]] || { echo "usage: $0 /path/to/mihomo" >&2; exit 2; }

# Source the installer's rendering helpers without running it.
DNS_SERVICE_USER="no-such-user-$$"
INTERCEPT_SERVICE_USER="no-such-user-2-$$"
OVERLAY_CONTROL_GROUP="no-such-group-$$"
OVERLAY_GENERATION_GROUP="no-such-group-2-$$"
OVERLAY_OWNER="5gpn"
OVERLAY_CONTROL_SOCKET="/run/mihomo/overlay-control.sock"
OVERLAY_GENERATION_SOCKET="/run/mihomo/overlay-generation.sock"
err() { echo "  err: $*" >&2; }

eval "$(awk '/^render_overlay_runtime_block\(\) \{/,/^\}/' "$ROOT/install.sh")"
eval "$(awk '/^render_overlay_placeholder\(\) \{/,/^\}/' "$ROOT/install.sh")"

render() {
    local overlay="$1" mode="$2" out="$3" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            __MIHOMO_LISTENERS__)
                printf '  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.example.test:443}\n'
                continue ;;
            __OVERLAY_EGRESS_ANCHOR__|__OVERLAY_CLIENT_ANCHOR__|__OVERLAY_RUNTIME_BLOCK__)
                render_overlay_placeholder "$line" "$overlay" "$mode" || return 1
                continue ;;
        esac
        line="${line//__GATEWAY_IP__/10.0.0.1}"
        line="${line//__CONSOLE_DOMAIN__/console.example.test}"
        line="${line//__ZASH_DOMAIN__/zash.example.test}"
        line="${line//__CONTROLLER_SECRET__/probe-secret}"
        line="${line//__INTERCEPT_INBOUND_USERNAME__/probe-inbound-user}"
        line="${line//__INTERCEPT_INBOUND_PASSWORD__/probe-inbound-password-123456}"
        line="${line//__INTERCEPT_UPSTREAM_USERNAME__/probe-upstream-user}"
        line="${line//__INTERCEPT_UPSTREAM_PASSWORD__/probe-upstream-password-123456}"
        printf '%s\n' "$line"
    done < "$ROOT/etc/mihomo/config.yaml.tmpl" > "$out"
}

runtime="$(mktemp -d)"
trap 'rm -rf "$runtime"' EXIT
printf '127.0.0.1/32\n' > "$runtime/whitelist.txt"

# 1. The probe: anchored, before any account or group exists.
if render 1 probe "$runtime/anchored.yaml"; then
    echo "  ok: staging renders the anchored candidate before accounts exist"
else
    echo "  FAIL: staging could not render before accounts exist — every fresh install aborts" >&2
    exit 1
fi
grep -Eq '__[A-Z0-9_]+__' "$runtime/anchored.yaml" \
    && { echo "  FAIL: unresolved placeholder in the probe render" >&2; exit 1; }
echo "  ok: no unresolved placeholders"

# 2. The fallback: unanchored, which is what a core without the overlay gets.
render 0 probe "$runtime/plain.yaml"
if "$CORE" -t -f "$runtime/plain.yaml" -d "$runtime" >/dev/null 2>&1; then
    echo "  ok: the unanchored fallback validates against this core"
else
    echo "  FAIL: the unanchored fallback does not validate" >&2
    exit 1
fi

# 3. Whether the anchored form validates depends on the core, and that is the
#    whole point of the probe — report it rather than assert it.
if "$CORE" -t -f "$runtime/anchored.yaml" -d "$runtime" >/dev/null 2>&1; then
    echo "  note: this core implements the overlay; the installer would seed anchored"
else
    echo "  note: this core does not implement the overlay; the installer would fall back"
fi

# 4. The live render must still refuse to invent identities.
if render 1 live "$runtime/live.yaml" 2>/dev/null; then
    echo "  FAIL: the live render invented identities for accounts that do not exist" >&2
    exit 1
fi
echo "  ok: the live render refuses when the accounts are missing"
