#!/usr/bin/env bash
# 5gpn firewall + proxy service install. Direct egress only — no packet
# marking, no policy routing, no tunnels, no exit layer. xray egresses
# straight out the gateway's default route. QUIC/HTTP3 IS proxied: xray
# sniffs the QUIC SNI, so UDP 443 from NPN clients is allowed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
PROXY_USER="${PROXY_USER:-pxout}"
API_PORT="${API_PORT:-}"
IOS_PORT="${IOS_PORT:-8111}"   # iOS profile fetch; NPN-only -> reachable from 172.22 only
DOT_RATE="${DOT_RATE:-30/second}"   # per-source new-DoT-conn rate; raise for CGNAT-heavy bases
DOT_BURST="${DOT_BURST:-60}"

# Unprivileged account that sniproxy drops to.
if ! id -u "${PROXY_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${PROXY_USER}"
fi

# DoT-only inbound (22/853, NO public 53) + client proxy ports from the NPN.
tcp_ports="22, 853"
[ -n "${API_PORT}" ] && tcp_ports="${tcp_ports}, ${API_PORT}"
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        # DoT 853 anti-abuse: drop NEW connections from a source over the rate.
        # Per-SOURCE-IP limit with a SILENT drop — clients behind one NAT/CGNAT share a
        # bucket; raise DOT_RATE/DOT_BURST (env) for CGNAT-heavy deployments.
        tcp dport 853 ct state new meter dot_rate4 { ip saddr  limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        tcp dport 853 ct state new meter dot_rate6 { ip6 saddr limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        tcp dport { ${tcp_ports} } accept
        ip saddr 172.22.0.0/16 tcp dport { 80, 443, ${IOS_PORT} } accept
        # QUIC/HTTP3 proxied by xray: allow UDP 443 from NPN clients (same scope as TCP 443).
        ip saddr 172.22.0.0/16 udp dport 443 accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
chmod +x /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables 2>/dev/null || true

# Migrate off sniproxy if a previous install left it behind.
systemctl disable --now sniproxy 2>/dev/null || true
rm -f /etc/systemd/system/sniproxy.service
install -m 0644 "${ROOT}/etc/systemd/xray.service"   /etc/systemd/system/xray.service
systemctl daemon-reload
echo "[OK] firewall + xray unit installed (direct egress; QUIC/UDP 443 proxied)"
