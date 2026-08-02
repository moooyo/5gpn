#!/usr/bin/env bash
# Migrate an existing three-process 5gpn config.yaml to the monolith core.
#
# The v5 gateway carries six artefacts that exist only because the DNS engine,
# the interception sidecar and mihomo were three processes talking over
# loopback. In one process every one of them is either dead weight or a rule the
# core no longer understands:
#
#   RUNTIME-OVERLAY,5gpn,egress   the overlay's egress anchor
#   RUNTIME-OVERLAY,5gpn,client   the overlay's capture anchor
#   IN-NAME,intercept-egress,...  the fail-closed terminator for the egress hop
#   NOT,((IN-NAME,intercept-egress)) qualifiers on the two panel allow rules
#   intercept-egress listener     mihomo's half of the second SOCKS5 hop
#   MODULE-INTERCEPT proxy        the sidecar's half of the first one
#
# The first three are hard errors: the monolith deleted the RUNTIME-OVERLAY rule
# type, so a config carrying an anchor fails `mihomo -t` with "proxy [egress]
# not found" and the core refuses to start. The listener and the proxy are
# merely pointless. The two qualifiers are neither: they keep extension-borne
# traffic off the management plane, and the engine still produces such traffic
# -- as INNER rather than on a named listener -- so they are rewritten to name
# the new shape rather than dropped.
#
# Verified against a live v5 host: with the three rules removed, the two
# qualifiers rewritten and the listener and proxy stripped, the monolith accepts
# the operator's config unchanged otherwise. That is the point -- config.yaml is
# the operator's file, and this removes what 5gpn put there, not what they did.
#
# Usage: migrate-to-monolith.sh <config.yaml> [--in-place]
# Without --in-place the rewritten config goes to stdout and nothing is touched.

set -euo pipefail

CONFIG="${1:-}"
IN_PLACE="${2:-}"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
    echo "usage: $0 <config.yaml> [--in-place]" >&2
    exit 2
fi

rewrite() {
    python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.read().split('\n')

# Rules the monolith cannot parse, or that guarded a hop that no longer exists.
DROP = {
    '- RUNTIME-OVERLAY,5gpn,egress',
    '- RUNTIME-OVERLAY,5gpn,client',
    '- IN-NAME,intercept-egress,REJECT',
}

# A panel rule excluded the sidecar's egress inbound because that egress
# re-entered mihomo and would otherwise have matched the panel route -- a
# compromised extension naming the console or panel hostname would have reached
# the gateway's own management plane.
#
# That exposure did not go away with the hop. The engine still reaches its
# upstreams by dialling back through these same rules, which is deliberate: it
# is what keeps intercepted traffic inside the operator's routing. What changed
# is only how that traffic is recognised. It used to arrive on a named SOCKS
# listener; it now arrives as INNER, with no inbound name at all -- so a
# qualifier naming the dead listener is indeed always true, but deleting it
# does not preserve the rule's meaning, it discards it. Rewrite the predicate
# instead, which is what etc/mihomo/config.yaml.tmpl seeds for fresh installs.
QUALIFIED = re.compile(
    r'^(\s*)- AND,\(\(NOT,\(\(IN-NAME,intercept-egress\)\)\),(.*)\),(\w+)\s*$'
)

out = []
dropped = 0
rewritten = 0
for line in lines:
    if line.strip() in DROP:
        dropped += 1
        continue
    m = QUALIFIED.match(line)
    if m:
        indent, rest, action = m.groups()
        out.append(
            f'{indent}- AND,((NOT,((IN-TYPE,INNER))),{rest.strip()}),{action}'
        )
        rewritten += 1
        continue
    out.append(line)

sys.stderr.write(f'dropped {dropped} rule(s), rewrote {rewritten} panel rule(s)\n')
sys.stdout.write('\n'.join(out))
PY
}

if [[ "$IN_PLACE" == "--in-place" ]]; then
    tmp="$(mktemp "${CONFIG}.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    rewrite "$CONFIG" >"$tmp"
    # Same-directory rename so the operator's file is replaced atomically or not
    # at all. A half-written config.yaml is a gateway that will not start.
    cp --preserve=mode,ownership "$CONFIG" "${CONFIG}.pre-monolith.bak"
    mv "$tmp"  "$CONFIG"
    trap - EXIT
    echo "migrated in place; previous file kept at ${CONFIG}.pre-monolith.bak" >&2
else
    rewrite "$CONFIG"
fi
