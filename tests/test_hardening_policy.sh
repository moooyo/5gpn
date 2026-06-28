#!/usr/bin/env bash
# Policy assertions for the §4 security-hardening batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SNI_SVC="$ROOT/etc/systemd/sniproxy.service"
INSTALL="$ROOT/install.sh"; FW="$ROOT/scripts/setup-firewall.sh"
API="$ROOT/api-server.py";  WEBUI="$ROOT/webui/index.html"

# --- systemd sandboxing ---
grep -Fq 'NoNewPrivileges=yes'   "$SNI_SVC" || fail "sniproxy.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'  "$SNI_SVC" || fail "sniproxy.service: no ProtectSystem=strict"
grep -Fq 'ReadWritePaths=/run'   "$SNI_SVC" || fail "sniproxy.service: pidfile path not writable under strict"
# The DEPLOYED units are heredocs in install.sh (smartdns/api/tgbot/iosprofile) — guard those,
# not any static file. iosprofile (root, public, per-connection) must get ProtectSystem=strict.
[ "$(grep -c 'NoNewPrivileges=yes' "$INSTALL")" -ge 4 ] || fail "install.sh units not all hardened (NoNewPrivileges <4)"
grep -Fq 'ProtectSystem=strict' "$INSTALL" || fail "deployed iosprofile heredoc not hardened (ProtectSystem=strict)"

# --- DoT :853 per-source rate limit ---
grep -Fq 'dot_rate4' "$FW" || fail "no DoT 853 per-source rate limit (dot_rate4 meter)"
grep -Eq 'tcp dport 853 ct state new meter .*limit rate over' "$FW" || fail "853 rate-limit rule malformed"
# The blanket DoT-only inbound set must still allow 853 (rate rule only drops excess).
grep -Fq 'tcp_ports="22, 853"' "$FW" || fail "DoT 853 no longer in the accept set"

# --- API auth-failure logging ---
grep -Fq 'auth failure from' "$API" || fail "no auth-failure logging on the public API"

# --- webui CSP (block external resource loads / object/frame) ---
grep -Fq 'Content-Security-Policy' "$WEBUI" || fail "no CSP meta in webui"

# --- smartdns archive integrity (opt-in sha256) ---
grep -Fq 'SMARTDNS_SHA256' "$INSTALL" || fail "no opt-in smartdns sha256 verify"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
