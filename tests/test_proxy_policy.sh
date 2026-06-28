#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SNI="$ROOT/etc/sniproxy.conf"
FW="$ROOT/scripts/setup-firewall.sh"
SS="$ROOT/etc/systemd/sniproxy.service"

# --- sniproxy: loop-avoidance + shape ---
grep -Eq '^[[:space:]]*nameserver 22\.22\.22\.22' "$SNI" || fail "sniproxy resolver not 22.22.22.22"
grep -Eq '127\.0\.0\.1|::1|:853|:5353'            "$SNI" && fail "sniproxy resolver must not point at local smartdns"
grep -Eq '^user pxout'                            "$SNI" || fail "sniproxy not running as pxout"
grep -Eq 'listener 0\.0\.0\.0:443'                "$SNI" || fail "sniproxy missing 443 listener"
grep -Eq 'mode ipv4_only'                         "$SNI" || fail "sniproxy not ipv4_only"

# --- firewall: DoT-only inbound; exit/mark layer GONE; QUIC/UDP 443 disabled ---
grep -Eq 'tcp_ports="22, 853"'             "$FW" || fail "inbound not limited to 22/853"
grep -Eq 'udp dport 53 accept'             "$FW" && fail "public plaintext :53 must not be opened"
grep -Eq 'pgw_exit|fwmark|table 100|skuid' "$FW" && fail "exit/mark layer must be removed (direct egress only)"
grep -Eq 'udp dport 443 accept'            "$FW" && fail "UDP 443 (QUIC) must not be accepted"
grep -Eq 'udp dport 443 reject'            "$FW" || fail "UDP 443 should be explicitly rejected (fast TCP fallback)"
grep -Eq 'quic-proxy'                      "$FW" && fail "quic-proxy reference must be removed (QUIC dropped)"

# --- systemd: sniproxy config path ---
grep -Eq -- '-c /etc/sniproxy.conf'        "$SS" || fail "sniproxy.service missing config path"

[ $rc -eq 0 ] && echo "proxy policy: PASS"
exit $rc
