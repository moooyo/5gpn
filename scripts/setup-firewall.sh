#!/usr/bin/env bash
# 5gpn firewall + proxy service install. Direct egress only — no packet
# marking, no policy routing, no tunnels, no exit layer. sing-box egresses
# straight out the gateway's default route. QUIC/HTTP3 IS proxied: sing-box
# sniffs the QUIC SNI, so UDP 443 from NPN clients is allowed.
# Inbound DNS: plain 53 (udp+tcp), DoT 853, DoH 8443 — all with per-source
# rate limiting to limit abuse from the public internet.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."

# --- Gum-or-echo status helpers (gum when on PATH + interactive; else plain echo).
# Installing gum is install.sh's job (install_gum); here we only detect + use it. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

IOS_PORT="${IOS_PORT:-8111}"   # iOS profile fetch; NPN-only -> reachable from CLIENT_NET only
DOT_RATE="${DOT_RATE:-30/second}"   # per-source new-conn rate for DoT/plain-DNS; raise for CGNAT
DOT_BURST="${DOT_BURST:-60}"
# Source net allowed to reach the proxy data path (80/443/udp443) + iOS profile.
# Default = the 5G NPN client subnet (NPN-only by design). A public/non-NPN
# deployment that wants internet clients to use the proxy must widen this
# (e.g. CLIENT_NET=0.0.0.0/0) — at the cost of running an OPEN proxy; size the
# DoT rate limits and accept the abuse exposure before doing so.
CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}"

# DoT/DoH/plain-DNS inbound (22/53/853/8443) + client proxy ports from the NPN.
tcp_ports="22, 53, 853"
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
        # Plain DNS 53 anti-abuse: same per-source rate meter as DoT.
        tcp dport 53 ct state new meter tcp53_rate4 { ip saddr  limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        tcp dport 53 ct state new meter tcp53_rate6 { ip6 saddr limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        # Public UDP :53 has no conntrack NEW state; rate-limit per-SOURCE packets
        # instead (drop over-rate) to blunt DNS amplification/reflection abuse.
        udp dport 53 meter dns_rate4 { ip saddr  limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        udp dport 53 meter dns_rate6 { ip6 saddr limit rate over ${DOT_RATE} burst ${DOT_BURST} packets } drop
        udp dport 53 accept
        tcp dport { ${tcp_ports} } accept
        tcp dport 8443 accept
        ip saddr ${CLIENT_NET} tcp dport { 80, 443, ${IOS_PORT} } accept
        # QUIC/HTTP3 proxied by sing-box: allow UDP 443 from NPN clients (same scope as TCP 443).
        ip saddr ${CLIENT_NET} udp dport 443 accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
chmod +x /etc/nftables.conf
info "Applying DoT/DoH/plain-DNS nftables ruleset (direct egress; QUIC/UDP 443 proxied)…"
nft -f /etc/nftables.conf
systemctl enable nftables 2>/dev/null || true

# Migrate off sniproxy / xray if a previous install left them behind.
systemctl disable --now sniproxy 2>/dev/null || true
rm -f /etc/systemd/system/sniproxy.service
systemctl disable --now xray 2>/dev/null || true
rm -f /etc/systemd/system/xray.service
install -m 0644 "${ROOT}/etc/systemd/sing-box.service" /etc/systemd/system/sing-box.service
install -m 0644 "${ROOT}/etc/systemd/5gpn-dns.service" /etc/systemd/system/5gpn-dns.service
systemctl daemon-reload
ok "firewall + sing-box + 5gpn-dns units installed (direct egress; DoT/DoH/plain DNS; QUIC/UDP 443 proxied)"
