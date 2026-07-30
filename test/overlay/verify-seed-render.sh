#!/usr/bin/env bash
# Exercises the installer's seed render on a machine that has neither the
# service accounts nor the socket groups.
#
# Artifact staging validates its candidate before installation has created
# either, so the probe render accepts placeholder identities. A renderer that
# insisted on resolving real ones there would abort every fresh install — which
# is a failure only a clean machine can show, and the reason this exists.
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

render() {
    local mode="$1" out="$2" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            __MIHOMO_LISTENERS__)
                printf '  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.example.test:443}\n'
                continue ;;
            __OVERLAY_RUNTIME_BLOCK__)
                render_overlay_runtime_block "$mode" || return 1
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
if render probe "$runtime/anchored.yaml"; then
    echo "  ok: staging renders the anchored candidate before accounts exist"
else
    echo "  FAIL: staging could not render before accounts exist — every fresh install aborts" >&2
    exit 1
fi
grep -Eq '__[A-Z0-9_]+__' "$runtime/anchored.yaml" \
    && { echo "  FAIL: unresolved placeholder in the probe render" >&2; exit 1; }
echo "  ok: no unresolved placeholders"

# 2. The anchored form is the only form. A core that rejects it cannot run this
#    release, which is exactly what artifact staging refuses to install over.
if "$CORE" -t -f "$runtime/anchored.yaml" -d "$runtime" >/dev/null 2>&1; then
    echo "  ok: this core implements the overlay; the installer would seed anchored"
else
    echo "  FAIL: this core does not implement the overlay, so staging would refuse it" >&2
    exit 1
fi

# 3. The live render must still refuse to invent identities.
if render live "$runtime/live.yaml" 2>/dev/null; then
    echo "  FAIL: the live render invented identities for accounts that do not exist" >&2
    exit 1
fi
echo "  ok: the live render refuses when the accounts are missing"
