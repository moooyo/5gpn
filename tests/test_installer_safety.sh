#!/usr/bin/env bash
# Behaviour-level regression checks for destructive installer operations.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
FAIL=0
pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Fake a host with one assigned non-loopback IPv4 and a matching default route.
ip() {
    case "$*" in
        '-o -4 addr show')
            echo '2: eth0    inet 10.20.30.40/24 brd 10.20.30.255 scope global eth0' ;;
        'route get 1.1.1.1')
            echo '1.1.1.1 via 10.20.30.1 dev eth0 src 10.20.30.40 uid 0' ;;
        *) return 1 ;;
    esac
}

PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
got="$(resolve_mihomo_listen_ips '')" || got=""
[[ "$got" == 10.20.30.40 ]] && pass "listener defaults keep only locally assigned addresses" \
    || fail "listener default = '$got', want 10.20.30.40"
got="$(resolve_mihomo_listen_ips '10.20.30.40,10.20.30.40')" || got=""
[[ "$got" == 10.20.30.40 ]] && pass "listener addresses are deduplicated" \
    || fail "listener dedupe = '$got'"
if resolve_mihomo_listen_ips '203.0.113.7' >/dev/null 2>&1; then
    fail "non-local listener address was accepted"
else
    pass "non-local listener address is rejected"
fi
if resolve_mihomo_listen_ips '127.0.0.1' >/dev/null 2>&1; then
    fail "panel loopback listener address was accepted"
else
    pass "panel loopback listener address is rejected"
fi
listeners="$(render_mihomo_listeners '10.20.30.40,10.20.30.41')"
[[ "$(grep -c 'port: 443' <<<"$listeners")" == 2 \
   && "$(grep -c 'port: 80' <<<"$listeners")" == 2 ]] \
    && pass "two bind IPs render independent :80/:443 listener pairs" \
    || fail "dynamic listener renderer did not emit two listener pairs"

# Seed -> preserve byte-for-byte -> explicit validated reset with backup.
MIHOMO_DIR="$TMP/mihomo"
CONF_DIR="$TMP/conf"
MIHOMO_BIN="$TMP/fake-mihomo"
MIHOMO_TEST_LOG="$TMP/mihomo.log"; export MIHOMO_TEST_LOG
cat > "$MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIHOMO_TEST_LOG"
exit 0
EOF
chmod +x "$MIHOMO_BIN"
mkdir -p "$CONF_DIR"
BASE_DOMAIN=example.com
MIHOMO_LISTEN_IPS=10.20.30.40
render_mihomo_config >/dev/null
config="$MIHOMO_DIR/config.yaml"
[[ -s "$config" && "$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")" == 600 ]] \
    && pass "first install seeds a private mihomo config" \
    || fail "first-install mihomo config missing or not mode 0600"
grep -Fq 'profile.example.com: 127.0.0.1' "$config" \
    && pass "seed contains isolated profile host mapping" \
    || fail "seed lacks profile host mapping"
printf '%s\n' '# operator edit must survive' >> "$config"
before="$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')"
render_mihomo_config >/dev/null
after="$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')"
[[ "$before" == "$after" ]] && pass "normal render validates and preserves operator config bytes" \
    || fail "normal render overwrote operator config"
render_mihomo_config --reset >/dev/null
if grep -Fq '# operator edit must survive' "$config"; then
    fail "explicit reset did not replace operator config"
elif compgen -G "$config.bak.*" >/dev/null; then
    pass "explicit reset replaces only after retaining a backup"
else
    fail "explicit reset did not retain a backup"
fi
grep -q '\.config\.yaml\.' "$MIHOMO_TEST_LOG" \
    && pass "mihomo validates a staged candidate before publication" \
    || fail "mihomo never validated a staged config candidate"

# External zashboard directories need a marker before recursive cleanup.
BASE_DIR="$TMP/base"
DNS_ZASH_DIR="$TMP/external/zash"
mkdir -p "$DNS_ZASH_DIR"; echo foreign > "$DNS_ZASH_DIR/file"
if claim_zashboard_dir >/dev/null 2>&1; then
    fail "non-empty unowned zashboard directory was claimed"
else
    pass "non-empty unowned zashboard directory is refused"
fi
rm -f "$DNS_ZASH_DIR/file"
claim_zashboard_dir >/dev/null
echo owned > "$DNS_ZASH_DIR/file"
clear_zashboard_dir >/dev/null
[[ -f "$DNS_ZASH_DIR/$ZASH_OWNERSHIP_MARKER" && ! -e "$DNS_ZASH_DIR/file" ]] \
    && pass "marker-owned zashboard directory can be cleared safely" \
    || fail "marker-owned zashboard clear failed"
remove_zashboard_dir >/dev/null
[[ ! -e "$DNS_ZASH_DIR" ]] && pass "marker-owned zashboard directory can be removed" \
    || fail "marker-owned zashboard removal failed"
DNS_ZASH_DIR=/
if safe_zashboard_path >/dev/null 2>&1; then
    fail "filesystem root accepted as DNS_ZASH_DIR"
else
    pass "system root is rejected as DNS_ZASH_DIR"
fi

# A generic host filter table must survive; only the legacy multi-fingerprint
# table is eligible for precise deletion.
NFT_LOG="$TMP/nft.log"; export NFT_LOG
NFT_MODE=generic
nft() {
    if [[ "$1" == list && "$2" == table ]]; then
        if [[ "$3" == inet && "$4" == filter ]]; then
            if [[ "$NFT_MODE" == fingerprint ]]; then
                echo 'table inet filter { dot_rate4 dot_rate6 doh_rate4 doh_rate6 tcp dport 9443 }'
            else
                echo 'table inet filter { chain input { type filter hook input priority 0; } }'
            fi
            return 0
        fi
        return 1
    fi
    if [[ "$1" == delete && "$2" == table ]]; then
        printf '%s\n' "$*" >> "$NFT_LOG"; return 0
    fi
    return 1
}
SCRIPTS_DIR="$TMP/scripts"; mkdir -p "$SCRIPTS_DIR"
remove_legacy_firewall >/dev/null
[[ ! -s "$NFT_LOG" ]] && pass "ordinary nftables inet/filter table is preserved" \
    || fail "ordinary nftables table was deleted"
NFT_MODE=fingerprint
remove_legacy_firewall >/dev/null
grep -qx 'delete table inet filter' "$NFT_LOG" \
    && pass "strongly fingerprinted legacy 5gpn table is deleted precisely" \
    || fail "fingerprinted legacy table was not deleted precisely"

# Service activation errors must propagate instead of falling through to the
# final "install complete" card.
systemctl() {
    case "$1" in
        daemon-reload|enable|is-active) return 0 ;;
        restart|start) return 1 ;;
    esac
    return 1
}
MIHOMO_LISTEN_IPS=10.20.30.40
if start_services >/dev/null 2>&1; then
    fail "start_services returned success after both service starts failed"
else
    pass "service start failure propagates as a non-zero installer result"
fi

# Profile DNS is fail-closed unless the explicit staged-deployment bypass is
# selected.
PROFILE_DOMAIN=profile.example.com
PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
dig() { echo 198.51.100.9; }
verify_profile_dns >/dev/null \
    && pass "profile A matching PUBLIC_IP passes bootstrap verification" \
    || fail "matching profile A was rejected"
dig() { echo 203.0.113.8; }
if verify_profile_dns >/dev/null 2>&1; then
    fail "mismatched profile A passed bootstrap verification"
else
    pass "mismatched profile A fails closed"
fi
SKIP_PROFILE_DNS_CHECK=1
verify_profile_dns >/dev/null \
    && pass "explicit SKIP_PROFILE_DNS_CHECK bypass works" \
    || fail "explicit profile DNS bypass was rejected"
unset SKIP_PROFILE_DNS_CHECK

# Static gates for operations that are intentionally not executed in a unit
# test (root binary install, systemd, certificate issuance, network fallback).
if grep -Eq 'nft flush ruleset|systemctl disable --now nftables|> /etc/nftables.conf' "$INSTALL"; then
    fail "installer still globally flushes/disables/overwrites nftables"
else
    pass "installer contains no global nftables mutation"
fi
debug_fn="$(sed -n '/^issue_selfsigned_wildcard()/,/^}/p' "$INSTALL")"
if grep -Fq '/etc/letsencrypt/live' <<<"$debug_fn"; then
    fail "debug certificate writer still targets a Certbot lineage"
elif grep -Fq 'DEBUG_CERT_DIR' <<<"$debug_fn"; then
    pass "debug certificate writer is isolated from Certbot lineages"
else
    fail "debug certificate writer does not use DEBUG_CERT_DIR"
fi
grep -Fq 'checksum is missing or invalid; refusing to install' "$INSTALL" \
    && pass "gum missing/invalid checksum fails closed to plain output" \
    || fail "gum checksum absence is not fail-closed"
grep -Fq 'Pinned tag ${DNS_VERSION} is unavailable; refusing to use main.' "$QUICK" \
    && pass "pinned quick install never falls forward to main" \
    || fail "pinned quick install can fall forward to main"
grep -Fq '5gpn-quick-install-v1' "$QUICK" \
    && ! grep -Eq '^[[:space:]]*rm -rf "\$SRC"' "$QUICK" \
    && pass "quick-install cleanup is ownership-marker gated" \
    || fail "quick-install still deletes arbitrary SRC"
grep -Eq '^wait_service_ready\(\)' "$INSTALL" \
    && grep -Fq 'full_install must never print success' "$INSTALL" \
    && pass "install success is gated on service readiness" \
    || fail "service readiness gate is absent"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "test_installer_safety: PASS"
else
    echo "test_installer_safety: FAIL"
    exit 1
fi
