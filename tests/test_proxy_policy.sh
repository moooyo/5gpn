#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

XRAY="$ROOT/etc/xray/config.json"
FW="$ROOT/scripts/setup-firewall.sh"
SS="$ROOT/etc/systemd/xray.service"

# --- xray: loop-avoidance + shape ---
grep -Eq '"22\.22\.22\.22"'                          "$XRAY" || fail "xray dns resolver not 22.22.22.22"
grep -Eq '127\.0\.0\.1:853|:5353|"::1"([^/]|$)'      "$XRAY" && fail "xray dns must not point at local smartdns"
grep -Eq '"dokodemo-door"'                           "$XRAY" || fail "xray not using dokodemo-door"
grep -Eq '"port":[[:space:]]*443'                    "$XRAY" || fail "xray missing 443 inbound"
grep -Eq '"network":[[:space:]]*"tcp,udp"'           "$XRAY" || fail "xray 443 must handle tcp+udp (QUIC)"
grep -Eq '"quic"'                                    "$XRAY" || fail "xray must sniff quic"
grep -Eq '"tls"'                                     "$XRAY" || fail "xray must sniff tls"
grep -Eq '"port":[[:space:]]*80'                     "$XRAY" || fail "xray missing 80 inbound"
grep -Eq '"http"'                                    "$XRAY" || fail "xray must sniff http on :80"
grep -Eq '"enabled":[[:space:]]*true'               "$XRAY" || fail "xray sniffing not enabled"
grep -Eq '"domainStrategy":[[:space:]]*"ForceIPv4"'  "$XRAY" || fail "xray freedom not ForceIPv4 (IPv4-only)"
grep -Eq '"blackhole"'                               "$XRAY" || fail "xray missing blackhole (anti-loop sink)"
grep -Eq '"address":[[:space:]]*"127\.0\.0\.1"'      "$XRAY" || fail "xray dokodemo placeholder not 127.0.0.1 (sniff-fail sink)"
grep -Eq '127\.0\.0\.0/8'                            "$XRAY" || fail "xray missing private->block anti-loop rule"

# --- firewall: DoT-only inbound; exit/mark layer GONE; QUIC now proxied ---
grep -Eq 'tcp_ports="22, 853"'                   "$FW" || fail "inbound not limited to 22/853"
grep -Eq 'udp dport 53 accept'                   "$FW" && fail "public plaintext :53 must not be opened"
grep -Eq 'pgw_exit|fwmark|table 100|skuid'       "$FW" && fail "exit/mark layer must be removed (direct egress only)"
grep -Eq 'udp dport 443 reject'                  "$FW" && fail "UDP 443 must NOT be rejected (QUIC now proxied)"
grep -Fq 'ip saddr ${CLIENT_NET} udp dport 443 accept' "$FW" || fail "UDP 443 (QUIC) from CLIENT_NET must be accepted"
grep -Fq 'CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}"' "$FW" || fail "CLIENT_NET default is not the NPN 172.22.0.0/16"
grep -Eq 'quic-proxy'                            "$FW" && fail "no separate quic-proxy (xray handles QUIC inline)"

# --- systemd: xray config path ---
grep -Eq -- '-c /usr/local/etc/xray/config.json' "$SS" || fail "xray.service missing config path"

[ $rc -eq 0 ] && echo "proxy policy: PASS"
exit $rc
