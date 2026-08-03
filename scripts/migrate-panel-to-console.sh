#!/usr/bin/env bash
# Migrate an existing 5gpn config.yaml onto the single console panel.
#
# The panel used to have no domain at all. zash.<base> was in the hosts block,
# in five reject rules, in the one allow rule that carried a source allowlist,
# and in the controller's certificate path -- and nothing ever listened for it,
# because the controller sat on loopback :9090 reachable only by SSH tunnel.
#
# The panel is https://console.<base>/ui/ now, and it is not source-restricted.
# That requires four things of an operator-owned config, and this script does
# exactly those four and nothing else:
#
#   1. the controller moves to 127.0.0.1:443, because that is the port a browser
#      reaching the console name arrives on. The name resolves to 127.0.0.1
#      through the hosts block, so the allow rule's DIRECT dial lands on this
#      same process through a different listener. Leave it on :9090 and the rule
#      still matches, the dial still succeeds against nothing, and the panel
#      simply does not answer.
#   2. the controller's certificate role is renamed zash -> console, following
#      the directory the installer renames.
#   3. the source allowlist is removed: the RULE-SET,whitelist,DIRECT,src
#      qualifier comes off the console allow rule, and the rule-provider that
#      read whitelist.txt goes with it. These two must move together -- the
#      installer no longer ships whitelist.txt, so a rule referencing a provider
#      whose file is gone is a config mihomo refuses to load. The fail-closed
#      DOMAIN,console,REJECT below the allow rule stays: it is what a captured
#      extension hits, since IN-TYPE,INNER excludes it from the allow above.
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
# Both shapes of the allow rule: with the retired allowlist qualifier, and the
# plain one a config from before the panel move carries.
ALLOW = re.compile(
    r'^(\s*)- AND,\(\(NOT,\(\(IN-TYPE,INNER\)\)\),\(DOMAIN,' + console_re +
    r'\)(?:,\(RULE-SET,whitelist,DIRECT,src\))?\),\s*DIRECT\s*$'
)
DENY = re.compile(r'^\s*- DOMAIN,' + console_re + r',\s*REJECT\s*$')
PROVIDER = re.compile(r'^(\s+)whitelist:\s*\{[^}]*\}\s*$')

has_deny = any(DENY.match(l) for l in lines)
out = []
moved = renamed = allowed = dropped = unrestricted = providers = 0

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    if stripped == 'external-controller-tls: 127.0.0.1:9090':
        out.append(line.replace('127.0.0.1:9090', '127.0.0.1:443'))
        moved += 1
        i += 1
        continue

    if '/etc/5gpn/cert/zash/current/' in line:
        out.append(line.replace('/etc/5gpn/cert/zash/current/',
                                '/etc/5gpn/cert/console/current/'))
        renamed += 1
        i += 1
        continue

    # Every zash line goes: the hosts mapping and each rule naming it.
    if re.search(r'\bzash\.[A-Za-z0-9.-]+', line) and (
            stripped.startswith('- ') or re.match(r'^\s*zash\.', line)):
        dropped += 1
        i += 1
        continue

    # The rule-providers block. The whitelist provider goes; the key itself goes
    # with it only when it has no other child, because an operator may have
    # added providers of their own and "rule-providers:" with nothing under it
    # is not the same document as no key at all.
    if stripped == 'rule-providers:':
        indent = len(line) - len(line.lstrip())
        block = []
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            if nxt.strip() == '':
                block.append(nxt)
                j += 1
                continue
            if len(nxt) - len(nxt.lstrip()) <= indent:
                break
            block.append(nxt)
            j += 1
        kept = []
        for b in block:
            if PROVIDER.match(b):
                providers += 1
                continue
            kept.append(b)
        # Trailing blanks belong to whatever follows, not to this block.
        while kept and kept[-1].strip() == '':
            kept.pop()
        if any(b.strip() for b in kept):
            out.append(line)
            out.extend(kept)
        out.append('')
        i = j
        continue

    m = ALLOW.match(line)
    if m:
        indent = m.group(1)
        if 'RULE-SET,whitelist' in line:
            unrestricted += 1
        out.append(
            indent + '- AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,' + console +
            ')),DIRECT'
        )
        allowed += 1
        if not has_deny:
            # Fail closed directly below the allow, so a captured extension --
            # excluded from the rule above by IN-TYPE,INNER -- is denied
            # explicitly rather than falling through to the loopback deny, which
            # is the right answer today only because the console happens to
            # resolve to 127.0.0.1.
            out.append(indent + '- DOMAIN,' + console + ',REJECT')
            has_deny = True
        i += 1
        continue

    out.append(line)
    i += 1

leftover = [l for l in out if 'RULE-SET' in l and 'whitelist' in l]
if leftover:
    sys.stderr.write('refusing to write: %d rule(s) still reference the '
                     'whitelist provider\n' % len(leftover))
    for l in leftover:
        sys.stderr.write('  %s\n' % l.strip())
    raise SystemExit(1)

sys.stderr.write(
    'controller moved: %d, cert role renamed: %d, panel rule rewritten: %d '
    '(allowlist qualifier removed: %d), whitelist provider dropped: %d, '
    'zash lines dropped: %d\n'
    % (moved, renamed, allowed, unrestricted, providers, dropped))
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
