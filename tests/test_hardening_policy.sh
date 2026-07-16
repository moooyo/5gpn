#!/usr/bin/env bash
# Policy assertions for the §4 security-hardening batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

MIHOMO_SVC="$ROOT/etc/systemd/mihomo.service"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"
INSTALL="$ROOT/install.sh"
GO_DIR="$ROOT/cmd/5gpn-dns"

# --- systemd sandboxing ---
grep -Fq 'NoNewPrivileges=yes'   "$MIHOMO_SVC" || fail "mihomo.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'  "$MIHOMO_SVC" || fail "mihomo.service: no ProtectSystem=strict"
grep -Fq 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' "$MIHOMO_SVC" \
    || fail "mihomo.service: unexpected ExecStart"
# mihomo dials IPv4+IPv6 AND needs AF_NETLINK: its UDP/QUIC DIRECT dial does a
# route-table lookup (netlinkrib) that fatals the forward without it (test-env-confirmed).
grep -Fq 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' "$MIHOMO_SVC" || fail "mihomo.service: address families must be AF_INET AF_INET6 AF_NETLINK AF_UNIX (AF_NETLINK required for QUIC/UDP forward)"
# mihomo writes provider caches under its own dir, unlike xray's read-only config mount.
grep -Fq 'ReadWritePaths=/etc/5gpn/mihomo' "$MIHOMO_SVC" || fail "mihomo.service must have ReadWritePaths=/etc/5gpn/mihomo (provider caches)"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/acme' "$MIHOMO_SVC" \
    || fail "mihomo.service must not read the Cloudflare Zone:DNS:Edit token"
grep -Fq 'Environment=SAFE_PATHS=/etc/5gpn/cert/zash' "$MIHOMO_SVC" \
    || fail "mihomo.service must scope SAFE_PATHS to /etc/5gpn/cert/zash for the shared controller certificate"

# Phase 5: the Telegram bot + iOS profile responder are in-process goroutines of
# 5gpn-dns (the separate python tgbot/iosprofile heredoc units are gone), so the
# deployed daemon unit is the one that must stay hardened.
grep -Fq 'NoNewPrivileges=yes'  "$DNS_SVC" || fail "5gpn-dns.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict' "$DNS_SVC" || fail "5gpn-dns.service: no ProtectSystem=strict"
# 5gpn-dns soft-orders after the mihomo data-plane forwarder (was xray).
grep -Fq 'After=network-online.target mihomo.service' "$DNS_SVC" || fail "5gpn-dns.service must order After=...mihomo.service"

# --- public console keeps token authentication; zashboard keeps the IP ACL ---
# The daemon still binds loopback behind mihomo. The old in-process token lockout
# and PROXY-protocol support are removed; /api/* remains bearer-authenticated.
[ ! -f "$GO_DIR/authblock.go" ]  || fail "authblock.go must be removed (no in-process lockout)"
[ ! -f "$GO_DIR/proxyproto.go" ] || fail "proxyproto.go must be removed (console is loopback-bound, no PROXY protocol)"
grep -Fq '127.0.0.1:443' "$GO_DIR/config.go" || fail "config.go: control plane must default to loopback 127.0.0.1:443"

# --- 5gpn-dns binary integrity (mandatory release checksum) ---
grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/5gpn-dns"' "$INSTALL" \
    || fail "no mandatory 5gpn-dns sha256 verification"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
