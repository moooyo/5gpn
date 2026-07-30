#!/usr/bin/env bash
# Reproduces the CI mihomo-config job locally.
#
# That job renders the seed with its own awk — not install.sh's — and then
# refuses any unresolved placeholder before handing the result to a pinned core.
# Running it here is the difference between finding a template change that breaks
# it now and finding out from a failed release run.
set -euo pipefail

CORE="${1:-/tmp/ci-mihomo}"
runtime="$(mktemp -d)"
trap 'rm -rf "$runtime"' EXIT

awk '
  $0 == "__MIHOMO_LISTENERS__" {
    print "  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.example.test:443}"
    print "  - {name: gateway80, type: tunnel, listen: 203.0.113.10, port: 80, network: [tcp], target: console.example.test:80}"
    print "  - {name: gateway8080, type: tunnel, listen: 203.0.113.10, port: 8080, network: [tcp], target: console.example.test:8080}"
    print "  - {name: gateway8443, type: tunnel, listen: 203.0.113.10, port: 8443, network: [tcp], target: console.example.test:8443}"
    print "  - {name: gateway5060, type: tunnel, listen: 203.0.113.10, port: 5060, network: [tcp, udp], target: console.example.test:5060}"
    next
  }
  # Mirrors the workflow: the anchors are literal, and the runtime block is
  # substituted rather than dropped -- an anchor with no block behind it is a
  # config mihomo refuses to parse.
  $0 == "__OVERLAY_RUNTIME_BLOCK__" {
    print ""
    print "runtime-overlay:"
    print "  owner: 5gpn"
    print "  control-socket: /run/mihomo/overlay-control.sock"
    print "  generation-socket: /run/mihomo/overlay-generation.sock"
    print "  control-peer-uid: 65534"
    print "  control-peer-gid: 65534"
    print "  control-socket-gid: 65534"
    print "  generation-peer-uid: 65534"
    print "  generation-peer-gid: 65534"
    print "  generation-socket-gid: 65534"
    next
  }
  {
    gsub(/__GATEWAY_IP__/, "10.0.0.1")
    gsub(/__CONSOLE_DOMAIN__/, "console.example.test")
    gsub(/__ZASH_DOMAIN__/, "zash.example.test")
    gsub(/__CONTROLLER_SECRET__/, "ci-controller-secret")
    gsub(/__INTERCEPT_INBOUND_USERNAME__/, "ci-module-inbound-user")
    gsub(/__INTERCEPT_INBOUND_PASSWORD__/, "ci-module-inbound-password-123456")
    gsub(/__INTERCEPT_UPSTREAM_USERNAME__/, "ci-module-upstream-user")
    gsub(/__INTERCEPT_UPSTREAM_PASSWORD__/, "ci-module-upstream-password-123456")
    print
  }
' etc/mihomo/config.yaml.tmpl > "$runtime/config.yaml"
printf '127.0.0.1/32\n' > "$runtime/whitelist.txt"

if grep -Eq '__[A-Z0-9_]+__' "$runtime/config.yaml"; then
  echo "  FAIL: unresolved placeholder(s):" >&2
  grep -oE '__[A-Z0-9_]+__' "$runtime/config.yaml" | sort -u >&2
  exit 1
fi
echo "  ok: no unresolved placeholders"

if "$CORE" -t -f "$runtime/config.yaml" -d "$runtime" >/dev/null 2>&1; then
  echo "  ok: the pinned core validates the rendered seed"
else
  echo "  FAIL: the pinned core rejected the rendered seed" >&2
  "$CORE" -t -f "$runtime/config.yaml" -d "$runtime" 2>&1 | tail -3 >&2
  exit 1
fi

# The 5060 ingress is optional; the job checks the seed survives its removal.
sed -e '/name: gateway5060/d' -e 's/, 5060//g' -e '/DST-PORT,5060/d' \
  "$runtime/config.yaml" > "$runtime/config-no-5060.yaml"
grep -Fq '5060' "$runtime/config-no-5060.yaml" && { echo "  FAIL: 5060 survived removal" >&2; exit 1; }
"$CORE" -t -f "$runtime/config-no-5060.yaml" -d "$runtime" >/dev/null 2>&1 \
  && echo "  ok: the seed validates with the 5060 ingress removed" \
  || { echo "  FAIL: the core rejected the seed without 5060" >&2; exit 1; }
