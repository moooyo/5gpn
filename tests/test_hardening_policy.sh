#!/usr/bin/env bash
# Policy assertions for the §4 security-hardening batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SB_SVC="$ROOT/etc/systemd/sing-box.service"
INSTALL="$ROOT/install.sh"; FW="$ROOT/scripts/setup-firewall.sh"

# --- systemd sandboxing ---
grep -Fq 'NoNewPrivileges=yes'   "$SB_SVC" || fail "sing-box.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'  "$SB_SVC" || fail "sing-box.service: no ProtectSystem=strict"
grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK' "$SB_SVC" || fail "sing-box.service: address families not the expected AF_INET AF_UNIX AF_NETLINK (no AF_INET6; AF_NETLINK needed for route subscribe)"
# The DEPLOYED units are heredocs in install.sh (tgbot/iosprofile) — guard those,
# not any static file. iosprofile (root, public, per-connection) must get ProtectSystem=strict.
[ "$(grep -c 'NoNewPrivileges=yes' "$INSTALL")" -ge 2 ] || fail "install.sh units not all hardened (NoNewPrivileges <2)"
grep -Fq 'ProtectSystem=strict' "$INSTALL" || fail "deployed iosprofile heredoc not hardened (ProtectSystem=strict)"

# --- DoT :853 per-source rate limit ---
grep -Fq 'dot_rate4' "$FW" || fail "no DoT 853 per-source rate limit (dot_rate4 meter)"
grep -Eq 'tcp dport 853 ct state new meter .*limit rate over' "$FW" || fail "853 rate-limit rule malformed"
# The blanket DoT-only inbound set must still allow 853 (rate rule only drops excess).
grep -Fq 'tcp_ports="22, 853"' "$FW" || fail "DoT 853 no longer in the accept set"

# --- 5gpn-dns binary integrity (opt-in sha256) ---
grep -Fq 'DNS_SHA256' "$INSTALL" || fail "no opt-in 5gpn-dns sha256 verify"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
