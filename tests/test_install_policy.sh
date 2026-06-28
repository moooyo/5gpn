#!/usr/bin/env bash
# Policy assertions for installer cert-renewal automation + control-plane status.
# Pure grep (no Python/Linux needed); runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"

# --- certbot auto-renewal must survive the DoT-only (drop) firewall + xray:80 ---
# The cert backs DoT :853; if renewal silently fails the whole gateway goes dark
# (no plaintext :53 fallback). Renewal uses --standalone, which needs :80 free,
# but the firewall drops :80 AND xray binds :80 at runtime.
# (1) pre-renewal hook frees port 80 (open firewall + stop xray).
grep -Eq 'renewal-hooks/pre'      "$INSTALL" || fail "no certbot pre-renewal hook installed"
grep -Eq 'systemctl stop xray' "$INSTALL" || fail "renewal must stop xray to free :80 for --standalone"
# (2) post-renewal hook restores the DoT-only firewall + restarts xray (runs win-or-lose).
grep -Eq 'renewal-hooks/post'       "$INSTALL" || fail "no certbot post-renewal hook installed"
grep -Eq 'systemctl start xray' "$INSTALL" || fail "post-renewal must restart xray"
# (3) a renewal timer so renewal actually runs unattended, and catches up missed runs.
grep -Eq '5gpn-certbot-renew\.timer' "$INSTALL" || fail "no certbot renewal timer installed"
grep -Eq '^Persistent=true'             "$INSTALL" || fail "renewal timer not Persistent (missed runs won't catch up)"
grep -Eq 'certbot renew'                "$INSTALL" || fail "renewal timer does not run 'certbot renew'"

FW="$ROOT/scripts/setup-firewall.sh"

# ===== 2.4/2.5 — NPN-only: iOS profile reachable internally; :8111 limited to 172.22 =====
grep -Eq 'IOS_PORT' "$FW" || fail "firewall does not handle IOS_PORT (:8111 never opened)"
grep -Eq 'ip saddr 172\.22\.0\.0/16 tcp dport \{ 80, 443, .*\} accept' "$FW" \
    || fail ":8111 not allowed from 172.22 (NPN profile fetch breaks)"
grep -Eq 'tcp_ports=.*8111' "$FW" && fail ":8111 must NOT be in the public tcp set (NPN-only = 172.22 only)"
# installer uses a client-facing GATEWAY_IP (default = PUBLIC_IP) for ip-alias + iOS profile;
# NPN operators export GATEWAY_IP=<internal 172.22 addr> so clients reach the internal gateway.
grep -Eq 'GATEWAY_IP:-\$PUBLIC_IP' "$INSTALL" \
    || fail "no client-facing GATEWAY_IP (default PUBLIC_IP) for ip-alias/iOS profile"

[ $rc -eq 0 ] && echo "install policy: PASS"
exit $rc
