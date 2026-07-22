#!/usr/bin/env bash
set -euo pipefail

PINNED_MIHOMO_BIN="${1:-}"
[[ -x "$PINNED_MIHOMO_BIN" ]] || { echo "usage: $0 /path/to/mihomo" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$(mktemp -d)"
trap 'rm -rf -- "$RUNTIME"' EXIT

awk '
  $0 == "__MIHOMO_LISTENERS__" {
    print "  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.example.test:443}"
    next
  }
  {
    gsub(/__GATEWAY_IP__/, "10.0.0.1")
    gsub(/__CONSOLE_DOMAIN__/, "console.example.test")
    gsub(/__ZASH_DOMAIN__/, "zash.example.test")
    gsub(/__CONTROLLER_SECRET__/, "compact-controller-secret")
    gsub(/__INTERCEPT_INBOUND_USERNAME__/, "compact-module-inbound-user")
    gsub(/__INTERCEPT_INBOUND_PASSWORD__/, "compact-module-inbound-password-123456")
    gsub(/__INTERCEPT_UPSTREAM_USERNAME__/, "compact-module-upstream-user")
    gsub(/__INTERCEPT_UPSTREAM_PASSWORD__/, "compact-module-upstream-password-123456")
    print
  }
' "$ROOT/etc/mihomo/config.yaml.tmpl" \
  | sed '/  - IN-NAME,intercept-egress,REJECT/i\  - AND,((IN-NAME,intercept-egress),(DOMAIN-SUFFIX,compact.example.test),(DST-PORT,443)),Proxies' \
  | sed '/  - MATCH,Proxies/i\  - AND,((DOMAIN-SUFFIX,compact.example.test),(DST-PORT,443)),MODULE-INTERCEPT' \
  > "$RUNTIME/config.yaml"

printf '127.0.0.1/32\n' > "$RUNTIME/whitelist.txt"
grep -Fq 'AND,((IN-NAME,intercept-egress),(DOMAIN-SUFFIX,compact.example.test),(DST-PORT,443)),Proxies' "$RUNTIME/config.yaml"
grep -Fq 'AND,((DOMAIN-SUFFIX,compact.example.test),(DST-PORT,443)),MODULE-INTERCEPT' "$RUNTIME/config.yaml"
"$PINNED_MIHOMO_BIN" -t -f "$RUNTIME/config.yaml" -d "$RUNTIME"

echo "mihomo compact suffix regression: PASS"
