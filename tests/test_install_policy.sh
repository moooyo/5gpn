#!/usr/bin/env bash
# Policy assertions for installer cert-renewal automation + control-plane status.
# Pure grep (no Python/Linux needed); runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"

# --- certbot auto-renewal must survive the DoT-only (drop) firewall + sing-box:80 ---
# The cert backs DoT :853; if renewal silently fails the whole gateway goes dark
# (no plaintext :53 fallback). Renewal uses --standalone, which needs :80 free,
# but the firewall drops :80 AND sing-box binds :80 at runtime.
# (1) pre-renewal hook frees port 80 (open firewall + stop sing-box).
grep -Eq 'renewal-hooks/pre'      "$INSTALL" || fail "no certbot pre-renewal hook installed"
grep -Eq 'systemctl stop sing-box' "$INSTALL" || fail "renewal must stop sing-box to free :80 for --standalone"
# (2) post-renewal hook restores the DoT-only firewall + restarts sing-box (runs win-or-lose).
grep -Eq 'renewal-hooks/post'       "$INSTALL" || fail "no certbot post-renewal hook installed"
grep -Eq 'systemctl start sing-box' "$INSTALL" || fail "post-renewal must restart sing-box"
# (3) a renewal timer so renewal actually runs unattended, and catches up missed runs.
grep -Eq '5gpn-certbot-renew\.timer' "$INSTALL" || fail "no certbot renewal timer installed"
grep -Eq '^Persistent=true'             "$INSTALL" || fail "renewal timer not Persistent (missed runs won't catch up)"
grep -Eq 'certbot renew'                "$INSTALL" || fail "renewal timer does not run 'certbot renew'"

FW="$ROOT/scripts/setup-firewall.sh"

# ===== 2.4/2.5 — NPN-only: iOS profile reachable internally; :8111 limited to CLIENT_NET =====
grep -Eq 'IOS_PORT' "$FW" || fail "firewall does not handle IOS_PORT (:8111 never opened)"
grep -Fq 'ip saddr ${CLIENT_NET} tcp dport { 80, 443,' "$FW" \
    || fail "proxy/iOS ports (80/443/:8111) not gated to CLIENT_NET"
# CLIENT_NET must default to the NPN client subnet (NPN-only by design).
grep -Fq 'CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}"' "$FW" \
    || fail "CLIENT_NET default is not the NPN 172.22.0.0/16"
grep -Eq 'tcp_ports=.*8111' "$FW" && fail ":8111 must NOT be in the public tcp set (NPN-only = CLIENT_NET only)"
# installer uses a client-facing GATEWAY_IP (default = PUBLIC_IP) for ip-alias + iOS profile;
# NPN operators export GATEWAY_IP=<internal 172.22 addr> so clients reach the internal gateway.
grep -Eq 'GATEWAY_IP:-\$PUBLIC_IP' "$INSTALL" \
    || fail "no client-facing GATEWAY_IP (default PUBLIC_IP) for ip-alias/iOS profile"

# P0: install-time SNI resolver is prompted, persisted, and env-overridable.
grep -Eq '\.singbox_resolver'                  "$INSTALL" || fail "resolver not persisted to /etc/5gpn/.singbox_resolver"
grep -Eq 'SINGBOX_RESOLVER'                    "$INSTALL" || fail "SINGBOX_RESOLVER not wired in install flow"
grep -Eq 'ask_text .*(解析器|resolver)'         "$INSTALL" || fail "no resolver prompt"

[ $rc -eq 0 ] && echo "install policy: PASS"
exit $rc
