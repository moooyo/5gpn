#!/usr/bin/env bash
# Policy assertions for the §4 security-hardening batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SB_SVC="$ROOT/etc/systemd/sing-box.service"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"
INSTALL="$ROOT/install.sh"; FW="$ROOT/scripts/setup-firewall.sh"

# --- systemd sandboxing ---
grep -Fq 'NoNewPrivileges=yes'   "$SB_SVC" || fail "sing-box.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'  "$SB_SVC" || fail "sing-box.service: no ProtectSystem=strict"
grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX AF_NETLINK' "$SB_SVC" || fail "sing-box.service: address families not the expected AF_INET AF_UNIX AF_NETLINK (no AF_INET6; AF_NETLINK needed for route subscribe)"
# Phase 5: the Telegram bot + iOS profile responder are in-process goroutines of
# 5gpn-dns (the separate python tgbot/iosprofile heredoc units are gone), so the
# deployed daemon unit is the one that must stay hardened.
grep -Fq 'NoNewPrivileges=yes'  "$DNS_SVC" || fail "5gpn-dns.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict' "$DNS_SVC" || fail "5gpn-dns.service: no ProtectSystem=strict"

# --- DoT :853 per-source rate limit ---
grep -Fq 'dot_rate4' "$FW" || fail "no DoT 853 per-source rate limit (dot_rate4 meter)"
grep -Eq 'tcp dport 853 ct state new meter .*limit rate over' "$FW" || fail "853 rate-limit rule malformed"
# The inbound accept set must include 853 (rate rule only drops excess).
grep -Fq '853' "$FW" || fail "DoT 853 no longer in the accept set"

# --- 5gpn-dns binary integrity (opt-in sha256) ---
grep -Fq 'DNS_SHA256' "$INSTALL" || fail "no opt-in 5gpn-dns sha256 verify"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
