#!/usr/bin/env bash
# Policy assertions for installer cert-renewal automation + control-plane status.
# Pure grep (no Python/Linux needed); runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
WEBUI="$ROOT/webui/index.html"

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

# --- webui must reflect REAL service state, not "any non-empty string is up" ---
# is_active() returns 'active'/'inactive'/'failed'/'unknown' (always non-empty),
# so !!svc[k] renders a crashed service as green. Must compare === 'active'.
grep -Eq "svc\[k\] === 'active'" "$WEBUI" || fail "webui status must compare === 'active'"
grep -Eq '!!svc\[k\]'            "$WEBUI" && fail "webui still uses truthy !!svc[k] (failed/inactive render as up)"

FW="$ROOT/scripts/setup-firewall.sh"
API="$ROOT/api-server.py"

# ===== 2.6 — API port unified to 8443 (installer default must match code/UI/docs) =====
grep -Eq '\b8080\b'  "$INSTALL" && fail "installer still references 8080 (API port must default to 8443)"
grep -Eq 'echo 8443' "$INSTALL" || fail "setup_api fallback port not 8443"
# api-server honors systemd Environment= (env first, file/default fallback) — no dead config.
grep -Eq 'os\.environ' "$API" || fail "api-server.py ignores Environment= (should read env with fallback)"

# ===== 2.4/2.5 — NPN-only: iOS profile reachable internally; :8111 limited to 172.22 =====
grep -Eq 'IOS_PORT' "$FW" || fail "firewall does not handle IOS_PORT (:8111 never opened)"
grep -Eq 'ip saddr 172\.22\.0\.0/16 tcp dport \{ 80, 443, .*\} accept' "$FW" \
    || fail ":8111 not allowed from 172.22 (NPN profile fetch breaks)"
grep -Eq 'tcp_ports=.*8111' "$FW" && fail ":8111 must NOT be in the public tcp set (NPN-only = 172.22 only)"
# installer uses a client-facing GATEWAY_IP (default = PUBLIC_IP) for ip-alias + iOS profile;
# NPN operators export GATEWAY_IP=<internal 172.22 addr> so clients reach the internal gateway.
grep -Eq 'GATEWAY_IP:-\$PUBLIC_IP' "$INSTALL" \
    || fail "no client-facing GATEWAY_IP (default PUBLIC_IP) for ip-alias/iOS profile"

# ===== 2.7 — API hardening: bounded threads + keep-alive correctness + unit caps =====
grep -Eq 'BoundedSemaphore'       "$API" || fail "api has no concurrency cap (thread exhaustion on public 8443)"
grep -Eq 'close_connection = True' "$API" || fail "api does not close conn on errors (keep-alive desync)"
grep -Eq '^[[:space:]]*timeout = [0-9]' "$API" || fail "api Handler has no read timeout (slowloris)"
grep -Eq 'TasksMax='  "$INSTALL" || fail "api systemd unit missing TasksMax"
grep -Eq 'MemoryMax=' "$INSTALL" || fail "api systemd unit missing MemoryMax"

[ $rc -eq 0 ] && echo "install policy: PASS"
exit $rc
