#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SB="$ROOT/etc/sing-box/config.json"
FW="$ROOT/scripts/setup-firewall.sh"
SS="$ROOT/etc/systemd/sing-box.service"

# --- sing-box: loop-avoidance + shape ---
# NOTE: pure grep cannot bind a field to a specific inbound (e.g. that "network":"tcp"
# is on :80, or that :443 OMITS "network" so it binds tcp+udp). The inbound<->network
# pairing + actual tcp/udp listeners are verified by the test-env boot check (`ss`),
# which is authoritative; these greps only assert the shapes are present.
grep -Eq '"22\.22\.22\.22"'                         "$SB" || fail "sing-box resolver not 22.22.22.22"
grep -Eq '127\.0\.0\.1:853|:5353|"::1"([^/]|$)'     "$SB" && fail "sing-box dns must not point at local smartdns"
grep -Eq '"type":[[:space:]]*"direct"'              "$SB" || fail "sing-box not using direct inbound/outbound"
grep -Eq '"listen_port":[[:space:]]*443'            "$SB" || fail "sing-box missing 443 inbound"
grep -Eq '"listen_port":[[:space:]]*80'             "$SB" || fail "sing-box missing 80 inbound"
grep -Eq '"network":[[:space:]]*"tcp"'              "$SB" || fail "sing-box :80 must be tcp-only"
grep -Eq '"action":[[:space:]]*"sniff"'             "$SB" || fail "sing-box missing sniff action"
grep -Eq '"quic"'                                   "$SB" || fail "sing-box must sniff quic (UDP 443/HTTP3)"
grep -Eq '"tls"'                                    "$SB" || fail "sing-box must sniff tls"
grep -Eq '"http"'                                   "$SB" || fail "sing-box must sniff http (:80)"
grep -Eq '"action":[[:space:]]*"resolve"'           "$SB" || fail "sing-box missing resolve action (ForceIPv4 egress)"
grep -Eq '"strategy":[[:space:]]*"ipv4_only"'       "$SB" || fail "sing-box not IPv4-only"
grep -Eq '"method":[[:space:]]*"drop"'              "$SB" || fail "sing-box missing reject drop (anti-loop sink)"
grep -Eq '"ip_is_private":[[:space:]]*true'         "$SB" || fail "sing-box missing ip_is_private reject (sniff-fail/private sink)"
grep -Eq '"ip_cidr"'                                "$SB" || fail "sing-box missing self-IP reject rule (sniff-fail-to-gateway anti-loop)"

# --- firewall: DoT-only inbound; exit/mark layer GONE; QUIC proxied (UNCHANGED) ---
grep -Eq 'tcp_ports="22, 853"'                   "$FW" || fail "inbound not limited to 22/853"
grep -Eq 'udp dport 53 accept'                   "$FW" && fail "public plaintext :53 must not be opened"
grep -Eq 'pgw_exit|fwmark|table 100|skuid'       "$FW" && fail "exit/mark layer must be removed (direct egress only)"
grep -Eq 'udp dport 443 reject'                  "$FW" && fail "UDP 443 must NOT be rejected (QUIC now proxied)"
grep -Fq 'ip saddr ${CLIENT_NET} udp dport 443 accept' "$FW" || fail "UDP 443 (QUIC) from CLIENT_NET must be accepted"
grep -Fq 'CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}"' "$FW" || fail "CLIENT_NET default is not the NPN 172.22.0.0/16"
grep -Eq 'quic-proxy'                            "$FW" && fail "no separate quic-proxy (sing-box handles QUIC inline)"

# --- systemd: sing-box config path ---
grep -Eq -- '-c /usr/local/etc/sing-box/config.json' "$SS" || fail "sing-box.service missing config path"

[ $rc -eq 0 ] && echo "proxy policy: PASS"
exit $rc
