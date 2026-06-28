#!/usr/bin/env python3
"""Generate the 'foreign' (non-China, non-reserved) IPv4 CIDR set.

Usage: gen_foreign_cidr.py <china_ip_list> <out_file>
Refuses (exit 1, leaves out_file untouched) if the china list looks too small,
so a failed/empty download can never blank the foreign set.
"""
import ipaddress
import os
import sys

# Ranges that must NEVER be 'foreign' (so they are never ip-alias'd to the gateway).
RESERVED = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4",
]
MIN_CHINA_ENTRIES = 100


def load_networks(path):
    nets = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            try:
                net = ipaddress.ip_network(line, strict=False)
            except ValueError:
                continue
            # Drop absurdly-broad entries (e.g. 0.0.0.0/0): a single such line in
            # the china list would otherwise collapse the foreign set to empty.
            if net.version == 4 and net.prefixlen >= 8:
                nets.append(net)
    return nets


def complement_v4(exclude_nets):
    merged = sorted(ipaddress.collapse_addresses(exclude_nets),
                    key=lambda n: int(n.network_address))
    END = (1 << 32) - 1
    result = []
    cursor = 0
    for net in merged:
        start = int(net.network_address)
        if start > cursor:
            result += ipaddress.summarize_address_range(
                ipaddress.IPv4Address(cursor), ipaddress.IPv4Address(start - 1))
        cursor = max(cursor, int(net.broadcast_address) + 1)
    if cursor <= END:
        result += ipaddress.summarize_address_range(
            ipaddress.IPv4Address(cursor), ipaddress.IPv4Address(END))
    return result


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: gen_foreign_cidr.py <china_list> <out_file>\n")
        return 2
    china_path, out_path = argv[1], argv[2]
    china = load_networks(china_path)
    if len(china) < MIN_CHINA_ENTRIES:
        sys.stderr.write("china list too small (%d < %d); refusing to regenerate\n"
                         % (len(china), MIN_CHINA_ENTRIES))
        return 1
    exclude = china + [ipaddress.ip_network(r) for r in RESERVED]
    foreign = complement_v4(exclude)
    if not foreign:
        sys.stderr.write("computed foreign set is empty; refusing to write "
                         "(would make every IP look domestic -> walled sites break)\n")
        return 1
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for cidr in foreign:
            f.write(str(cidr) + "\n")
    os.replace(tmp, out_path)
    sys.stderr.write("wrote %d foreign CIDRs\n" % len(foreign))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
