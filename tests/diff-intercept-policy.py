#!/usr/bin/env python3
"""Diff the policy band in mihomo's config.yaml against what intercept/config.json
declares, reproducing renderInterceptPolicyRule from cmd/5gpn-dns/intercept_mihomo.go.

The installer's preflight only reports a reason code
(interception-policy-rules-out-of-sync); this prints the actual divergence, so an
operator can see which rules to restore before rerunning the install.

usage: diff-intercept-policy.py [mihomo-config.yaml] [intercept-config.json]
"""

import json
import sys

MIHOMO = sys.argv[1] if len(sys.argv) > 1 else "/etc/5gpn/mihomo/config.yaml"
INTERCEPT = sys.argv[2] if len(sys.argv) > 2 else "/etc/5gpn/intercept/config.json"

REJECT_TERMINATOR = "IN-NAME,intercept-egress,REJECT"
BLOCK_QUIC_BASE = "AND,((NETWORK,UDP),(DST-PORT,443))"
PROXY_NAME = "MODULE-INTERCEPT"


def render_policy_rule(rule):
    """Mirror of renderInterceptPolicyRule (intercept_mihomo.go:130)."""
    matchers = []
    if rule.get("domain"):
        matchers.append("(DOMAIN,%s)" % rule["domain"])
    if rule.get("domain_suffix"):
        matchers.append("(DOMAIN-SUFFIX,%s)" % rule["domain_suffix"])
    if rule.get("ip_cidr"):
        kind = "IP-CIDR6" if ":" in rule["ip_cidr"] else "IP-CIDR"
        matchers.append("(%s,%s,no-resolve)" % (kind, rule["ip_cidr"]))
    keywords = rule.get("domain_keywords") or []
    if len(keywords) == 1:
        matchers.append("(DOMAIN-KEYWORD,%s)" % keywords[0])
    elif len(keywords) > 1:
        matchers.append("(OR,(%s))" % ",".join("(DOMAIN-KEYWORD,%s)" % k for k in keywords))
    for keyword in rule.get("all_domain_keywords") or []:
        matchers.append("(DOMAIN-KEYWORD,%s)" % keyword)
    if rule.get("network"):
        matchers.append("(NETWORK,%s)" % rule["network"].upper())
    if rule.get("destination_port"):
        matchers.append("(DST-PORT,%d)" % rule["destination_port"])

    target = rule["action"].upper()
    if len(matchers) == 1:
        matcher = matchers[0][1:-1]
        parts = matcher.split(",")
        if len(parts) >= 2:
            if parts[0] == "OR":
                return matcher + "," + target
            if parts[0].startswith("IP-CIDR"):
                return "%s,%s,%s,no-resolve" % (parts[0], parts[1], target)
            return matcher + "," + target
    return "AND,(%s),%s" % (",".join(matchers), target)


def expected_policy(document):
    """Mirror of interceptMihomoRouting's policy section (intercept_mihomo.go:88)."""
    if not document.get("mitm", {}).get("enabled"):
        return []
    by_id = {m["id"]: m for m in document.get("modules") or []}
    order = list(document.get("execution_order") or [])
    seen = set(order)
    for module in document.get("modules") or []:
        if module["id"] not in seen:
            order.append(module["id"])

    policy, seen_rules = [], set()
    for module_id in order:
        module = by_id.get(module_id)
        if not module or not module.get("enabled"):
            continue
        for route in module.get("routing_rules") or []:
            rendered = render_policy_rule(route)
            if rendered in seen_rules:
                continue
            seen_rules.add(rendered)
            policy.append((rendered, module_id))
    return policy


def actual_policy(path):
    """Extract the band between the egress terminator (plus the optional
    block-quic rule) and the first capture rule."""
    rules, in_rules = [], False
    for line in open(path, encoding="utf-8"):
        stripped = line.strip()
        if stripped.startswith("rules:"):
            in_rules = True
            continue
        if in_rules:
            if not stripped.startswith("- "):
                if stripped and not line.startswith(" "):
                    break
                continue
            rules.append(stripped[2:].strip())

    try:
        start = rules.index(REJECT_TERMINATOR) + 1
    except ValueError:
        sys.exit("no '%s' in %s — a different failure than a policy drift" % (REJECT_TERMINATOR, path))
    if start < len(rules) and rules[start].startswith(BLOCK_QUIC_BASE):
        start += 1

    end = start
    while end < len(rules) and not rules[end].endswith("," + PROXY_NAME):
        if rules[end].startswith("MATCH,"):
            break
        end += 1
    return rules[start:end]


def main():
    document = json.load(open(INTERCEPT, encoding="utf-8"))
    want = expected_policy(document)
    have = actual_policy(MIHOMO)

    print("expected policy rules (from intercept/config.json): %d" % len(want))
    print("actual policy rules   (from mihomo/config.yaml):    %d" % len(have))
    print()

    have_set = set(have)
    want_set = {rule for rule, _ in want}

    missing = [(rule, owner) for rule, owner in want if rule not in have_set]
    extra = [rule for rule in have if rule not in want_set]

    if missing:
        print("MISSING from config.yaml (%d) — config.json declares these, the file does not have them:" % len(missing))
        for rule, owner in missing:
            print("  [%s]  %s" % (owner, rule))
        print()
    if extra:
        print("UNEXPECTED in config.yaml (%d) — not declared by any enabled extension:" % len(extra))
        for rule in extra:
            print("  %s" % rule)
        print()

    if not missing and not extra:
        # Same set: the divergence must be ordering.
        for index, ((rule, owner), got) in enumerate(zip(want, have)):
            if rule != got:
                print("ORDER divergence at policy index %d:" % index)
                print("  expected [%s]  %s" % (owner, rule))
                print("  actual              %s" % got)
                break
        else:
            print("policy band matches exactly — the failure is elsewhere")
            return 0

    print("Insert the MISSING rules at their declared position, or toggle the owning")
    print("extension off and on in the console to re-render config.yaml.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
