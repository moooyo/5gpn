#!/usr/bin/env python3
"""Render smartdns.conf.template by replacing __KEY__ with KEY=VALUE args.

Usage: render_smartdns_conf.py <template> <out_conf> KEY=VALUE [KEY=VALUE ...]
Exits 1 if any __PLACEHOLDER__ remains after substitution.
"""
import re
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: render_smartdns_conf.py <template> <out> KEY=VALUE ...\n")
        return 2
    template, out = argv[1], argv[2]
    subs = {}
    for pair in argv[3:]:
        if "=" not in pair:
            sys.stderr.write("bad KEY=VALUE: %s\n" % pair)
            return 2
        k, v = pair.split("=", 1)
        subs[k] = v
    with open(template, encoding="utf-8") as f:
        content = f.read()
    for k, v in subs.items():
        content = content.replace("__%s__" % k, v)
    leftover = re.search(r"__[A-Z_]+__", content)
    if leftover:
        sys.stderr.write("unresolved placeholder: %s\n" % leftover.group(0))
        return 1
    with open(out, "w", encoding="utf-8") as f:
        f.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
