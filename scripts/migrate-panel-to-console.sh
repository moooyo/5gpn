#!/usr/bin/env bash
# Migrate an existing 5gpn config.yaml onto the single console panel.
#
# The panel used to have no domain at all. zash.<base> was in the hosts block,
# in five reject rules, in the one allow rule that carried the source allowlist,
# and in the controller's certificate path -- and nothing ever listened for it,
# because the controller sat on loopback :9090 reachable only by SSH tunnel.
#
# The panel is https://console.<base>/ui/ now. That requires four things of an
# operator-owned config, and this script does exactly those four and nothing
# else:
#
#   1. the controller moves to 127.0.0.1:443, because that is the port a browser
#      reaching the console name arrives on. The name resolves to 127.0.0.1
#      through the hosts block, so the allow rule's DIRECT dial lands on this
#      same process through a different listener. Leave it on :9090 and the rule
#      still matches, the dial still succeeds against nothing, and the panel
#      simply does not answer.
#   2. the controller's certificate role is renamed zash -> console, following
#      the directory the installer renames.
#   3. the panel allow rule gains (RULE-SET,whitelist,DIRECT,src), and a
#      fail-closed DOMAIN,console,REJECT is inserted below it. This is the part
#      that is not cosmetic: zash.<base> carried the allowlist while the console
#      rule was unrestricted, which was harmless only because nothing listened
#      for either. With the panel answering on the console name, an unrestricted
#      rule opens the management plane to every client whose DNS points here.
#   4. every zash.<base> line is dropped -- the hosts mapping and the rules.
#
# What it does not do is touch anything the operator put there. config.yaml is
# their file; this removes what 5gpn put in it and rewrites what 5gpn owns.
#
# Usage: migrate-panel-to-console.sh <config.yaml> [--in-place]
# Without --in-place the rewritten config goes to stdout and nothing is touched.
set -euo pipefail

CONFIG="${1:-}"
IN_PLACE="${2:-}"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
    echo "usage: migrate-panel-to-console.sh <config.yaml> [--in-place]" >&2
    exit 2
fi
if [[ -n "$IN_PLACE" && "$IN_PLACE" != "--in-place" ]]; then
    echo "unknown argument: $IN_PLACE" >&2
    exit 2
fi

rewrite() {
    python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.read().split('\n')

# The console name is read from the config rather than derived from a base the
# script does not have. Any rule naming it will do; the hosts mapping is the
# most reliable because it is one line with one name on it.
console = None
for line in lines:
    m = re.match(r'^\s*(console\.[A-Za-z0-9.-]+):\s*127\.0\.0\.1\s*$', line)
    if m:
        console = m.group(1)
        break
if console is None:
    sys.stderr.write('no "console.<base>: 127.0.0.1" hosts mapping; nothing to migrate\n')
    sys.stdout.write('\n'.join(lines))
    raise SystemExit(0)

console_re = re.escape(console)
ALLOW = re.compile(
    r'^(\s*)- AND,\(\(NOT,\(\(IN-TYPE,INNER\)\)\),\(DOMAIN,' + console_re + r'\)\),\s*DIRECT\s*$'
)
ALREADY = re.compile(
    r'^\s*- AND,\(\(NOT,\(\(IN-TYPE,INNER\)\)\),\(DOMAIN,' + console_re +
    r'\),\(RULE-SET,whitelist,DIRECT,src\)\),\s*DIRECT\s*$'
)
DENY = re.compile(r'^\s*- DOMAIN,' + console_re + r',\s*REJECT\s*$')

has_deny = any(DENY.match(l) for l in lines)
out = []
moved = renamed = allowed = dropped = 0
for line in lines:
    stripped = line.strip()

    if stripped == 'external-controller-tls: 127.0.0.1:9090':
        out.append(line.replace('127.0.0.1:9090', '127.0.0.1:443'))
        moved += 1
        continue

    if '/etc/5gpn/cert/zash/current/' in line:
        out.append(line.replace('/etc/5gpn/cert/zash/current/',
                                '/etc/5gpn/cert/console/current/'))
        renamed += 1
        continue

    # Every zash line goes: the hosts mapping and each rule naming it.
    if re.search(r'\bzash\.[A-Za-z0-9.-]+', line) and (
            stripped.startswith('- ') or re.match(r'^\s*zash\.', line)):
        dropped += 1
        continue

    m = ALLOW.match(line)
    if m:
        indent = m.group(1)
        out.append(
            indent + '- AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,' + console +
            '),(RULE-SET,whitelist,DIRECT,src)),DIRECT'
        )
        allowed += 1
        if not has_deny:
            # Fail closed directly below the allow, so an unallowlisted client
            # is denied explicitly rather than falling through to the loopback
            # deny -- which is the right answer today only because the console
            # happens to resolve to 127.0.0.1.
            out.append(indent + '- DOMAIN,' + console + ',REJECT')
            has_deny = True
        continue

    out.append(line)

if allowed == 0 and any(ALREADY.match(l) for l in lines):
    sys.stderr.write('panel allow rule is already allowlisted\n')

sys.stderr.write(
    'controller moved: %d, cert role renamed: %d, panel rule allowlisted: %d, '
    'zash lines dropped: %d\n' % (moved, renamed, allowed, dropped))
sys.stdout.write('\n'.join(out))
PY
}

if [[ "$IN_PLACE" == "--in-place" ]]; then
    tmp="$(mktemp "${CONFIG}.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    rewrite "$CONFIG" >"$tmp"
    # Same-directory rename so the operator's file is replaced atomically or not
    # at all. A half-written config.yaml is a gateway that will not start.
    cp --preserve=mode,ownership "$CONFIG" "${CONFIG}.pre-console.bak"
    mv "$tmp" "$CONFIG"
    trap - EXIT
    echo "migrated in place; previous file kept at ${CONFIG}.pre-console.bak" >&2
else
    rewrite "$CONFIG"
fi
