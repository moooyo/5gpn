"""Migrate a rendered mihomo config to the runtime-overlay arrangement.

The legacy driver writes three managed regions into the operator's config: the
extension policy rules, the processor egress selectors, and the capture rules.
Under the overlay none of them live in the file — they are compiled into a typed
generation and committed over a socket — so migrating means removing all three
and leaving the two anchors that resolve them.

What must NOT be touched is everything else in the rule list. Those are the
operator's own rules, including the panel guards and the private-range denies,
and the whole point of the overlay is that a routing change stops perturbing
them.
"""

import io
import re
import sys

CONFIG = "/etc/5gpn/mihomo/config.yaml"
OUT = "/tmp/config-anchored.yaml"

OWNER = "5gpn"
CLIENT_ANCHOR = "  - RUNTIME-OVERLAY,%s,client" % OWNER
EGRESS_ANCHOR = "  - RUNTIME-OVERLAY,%s,egress" % OWNER
TERMINATOR = "- IN-NAME,intercept-egress,REJECT"
UDP_DENY = "- AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"

OVERLAY_BLOCK = """
runtime-overlay:
  owner: 5gpn
  control-socket: /run/mihomo/overlay-control.sock
  generation-socket: /run/mihomo/overlay-generation.sock
  control-peer-uid: 999
  control-peer-gid: 989
  generation-peer-uid: 994
  generation-peer-gid: 985
"""

text = io.open(CONFIG, encoding="utf-8").read()
lines = text.split("\n")
start = next(i for i, l in enumerate(lines) if l.strip() == "rules:")

head = lines[: start + 1]
rules = lines[start + 1 :]

# The capture rules steer at the processor's outbound; the egress rules are the
# ones whose selector is qualified by the processor's inbound. The panel guards
# also mention that inbound, but negated — they are operator rules and stay.
def is_capture(line):
    return line.strip().endswith(",MODULE-INTERCEPT")


def is_egress_selector(line):
    body = line.strip()
    if body == TERMINATOR:
        return False
    if "NOT,((IN-NAME,intercept-egress))" in body:
        return False
    return "(IN-NAME,intercept-egress)" in body


kept = []
removed = {"capture": 0, "egress": 0, "policy": 0}
requalified = 0

match_index = max(i for i, l in enumerate(rules) if l.strip().startswith("- MATCH,"))
udp_index = max(i for i, l in enumerate(rules) if l.strip() == UDP_DENY)


def requalify(line):
    """Excludes processor traffic from a panel allow rule.

    These two rules must stay above the loopback deny — the console resolves to
    127.0.0.1 — and therefore above the egress anchor. Unqualified, they are a
    path a processor-originated connection can take to the gateway's own
    management plane without ever meeting the anchor, which is exactly what the
    core's bypass check refuses. The seed template already ships them qualified;
    a box installed before that does not, so migrating has to fix them.
    """
    body = line.strip()[2:]
    if not body.endswith(",DIRECT"):
        return line, False
    if "NOT,((IN-NAME,intercept-egress))" in body:
        return line, False
    matcher = body[: -len(",DIRECT")]
    if matcher.startswith("AND,((") and matcher.endswith("))"):
        inner = matcher[len("AND,((") : -len("))")]
    elif re.match(r"^[A-Z-]+,", matcher):
        inner = matcher
    else:
        return line, False
    indent = line[: len(line) - len(line.lstrip())]
    return "%s- AND,((NOT,((IN-NAME,intercept-egress))),(%s)),DIRECT" % (indent, inner), True


for index, line in enumerate(rules):
    if is_capture(line):
        removed["capture"] += 1
        continue
    if is_egress_selector(line):
        removed["egress"] += 1
        continue
    # Extension policy rules occupy the span between the UDP deny and the
    # terminal MATCH. Everything there is daemon-rendered; the operator's own
    # rules sit above the deny.
    if udp_index < index < match_index and line.strip().startswith("- "):
        removed["policy"] += 1
        continue
    if line.strip().startswith("- ") and line.strip().endswith(",DIRECT"):
        line, changed = requalify(line)
        if changed:
            requalified += 1
    kept.append(line)

# Re-locate the landmarks in the surviving list and splice the anchors in.
term_at = max(i for i, l in enumerate(kept) if l.strip() == TERMINATOR)
kept.insert(term_at, EGRESS_ANCHOR)
match_at = max(i for i, l in enumerate(kept) if l.strip().startswith("- MATCH,"))
kept.insert(match_at, CLIENT_ANCHOR)

body = "\n".join(head + kept).rstrip("\n") + "\n" + OVERLAY_BLOCK
io.open(OUT, "w", encoding="utf-8", newline="\n").write(body)

print("removed: capture=%d egress=%d policy=%d; requalified %d panel allow rules"
      % (removed["capture"], removed["egress"], removed["policy"], requalified))
print("rules before=%d after=%d" % (len(rules), len(kept)))
print("wrote", OUT)
