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
# not found" and the core refuses to start. The rest are merely pointless -- a
# qualifier excluding an inbound that no longer exists can only ever be true.
#
# Verified against a live v5 host: with the three rules removed and the two
# qualifiers stripped, the monolith accepts the operator's config unchanged
# otherwise. That is the point -- config.yaml is the operator's file, and this
# removes what 5gpn put there, not what they did.
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
# re-entered mihomo and would otherwise have matched the panel route. With the
# hop gone the inbound cannot exist, so the qualifier is always true -- and
# leaving it in place would keep a config referencing a listener the operator is
# about to delete.
QUALIFIED = re.compile(
    r'^(\s*)- AND,\(\(NOT,\(\(IN-NAME,intercept-egress\)\)\),(.*)\),(\w+)\s*$'
)

out = []
dropped = 0
simplified = 0
for line in lines:
    if line.strip() in DROP:
        dropped += 1
        continue
    m = QUALIFIED.match(line)
    if m:
        indent, rest, action = m.groups()
        out.append(f'{indent}- AND,({rest.strip()}),{action}')
        simplified += 1
        continue
    out.append(line)

sys.stderr.write(f'dropped {dropped} rule(s), simplified {simplified} panel rule(s)\n')
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
