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

TMP="$(mktemp -d "$ROOT/.test-installer-safety.XXXXXX")"
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
grep -Fq 'console.example.com: 127.0.0.1' "$config" \
    && grep -Fq 'DOMAIN,console.example.com,DIRECT' "$config" \
    && pass "seed contains public console mapping" \
    || fail "seed lacks public console mapping"
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
DNS_ZASH_DIR=/etc/5gpn-unowned-panel
if safe_zashboard_path >/dev/null 2>&1; then
    fail "system-directory descendant accepted as DNS_ZASH_DIR"
else
    pass "system-directory descendants are rejected as panel cleanup paths"
fi

# Generic sing-box paths and unit names do not prove 5gpn ownership.
SINGBOX_BIN="$TMP/sing-box/bin/sing-box"
SINGBOX_DIR="$TMP/sing-box/config"
SINGBOX_UNIT="$TMP/systemd/sing-box.service"
SINGBOX_SYSTEMCTL_LOG="$TMP/sing-box-systemctl.log"
mkdir -p "$(dirname "$SINGBOX_BIN")" "$SINGBOX_DIR" "$(dirname "$SINGBOX_UNIT")"
touch "$SINGBOX_BIN" "$SINGBOX_DIR/config.json"
cat > "$SINGBOX_UNIT" <<'EOF'
[Unit]
Description=Operator-managed sing-box
EOF
systemctl() {
    printf '%s\n' "$*" >> "$SINGBOX_SYSTEMCTL_LOG"
    return 0
}
if ! declare -F remove_legacy_singbox >/dev/null; then
    fail "sing-box cleanup has no ownership-gated helper"
else
    remove_legacy_singbox >/dev/null
    [[ -e "$SINGBOX_BIN" && -e "$SINGBOX_DIR/config.json" && -e "$SINGBOX_UNIT" \
       && ! -s "$SINGBOX_SYSTEMCTL_LOG" ]] \
        && pass "unowned sing-box installation is preserved" \
        || fail "unowned sing-box installation was modified"

    cat > "$SINGBOX_UNIT" <<'EOF'
[Unit]
Description=5gpn legacy sing-box data plane
EOF
    : > "$SINGBOX_SYSTEMCTL_LOG"
    remove_legacy_singbox >/dev/null
    [[ ! -e "$SINGBOX_UNIT" && -e "$SINGBOX_BIN" && -e "$SINGBOX_DIR/config.json" ]] \
        && grep -qx 'disable --now sing-box.service' "$SINGBOX_SYSTEMCTL_LOG" \
        && pass "fingerprinted legacy 5gpn sing-box unit is removed precisely" \
        || fail "fingerprinted legacy 5gpn sing-box unit cleanup was not precise"
fi
for fn_name in clean_previous_install uninstall; do
    fn_body="$(sed -n "/^${fn_name}()/,/^}/p" "$INSTALL")"
    if ! grep -Fq 'remove_legacy_singbox' <<<"$fn_body"; then
        fail "$fn_name does not route sing-box cleanup through the ownership gate"
    elif grep -Eq '^[[:space:]]*[^#].*(sing-box\.service|/usr/local/bin/sing-box|SINGBOX_(BIN|DIR))' <<<"$fn_body"; then
        fail "$fn_name still mutates generic sing-box artifacts directly"
    else
        pass "$fn_name gates sing-box cleanup by ownership"
    fi
done

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
[[ ! -s "$NFT_LOG" ]] \
    && pass "mixed-ownership legacy inet/filter table is preserved for manual migration" \
    || fail "fingerprinted generic host table was deleted wholesale"

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

# Public/certificate DNS is fail-closed and always uses the independent
# resolver instead of the host's possibly synthetic resolver.
CONSOLE_DOMAIN=console.example.com
PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
DIG_LOG="$TMP/dig.log"
DIG_A=198.51.100.9
DIG_AAAA=""
dig() {
    printf '%s\n' "$*" >> "$DIG_LOG"
    case " $* " in
        *' AAAA '*) [[ -n "$DIG_AAAA" ]] && echo "$DIG_AAAA" ;;
        *' A '*) [[ -n "$DIG_A" ]] && echo "$DIG_A" ;;
    esac
}
CERT_MODE=cloudflare
verify_console_dns >/dev/null \
    && pass "console A matching PUBLIC_IP passes bootstrap verification" \
    || fail "matching console A was rejected"
grep -q '@1.1.1.1' "$DIG_LOG" \
    && pass "console DNS bootstrap uses the fixed 1.1.1.1 resolver" \
    || fail "console DNS bootstrap did not query 1.1.1.1"
DIG_A=203.0.113.8
CERT_DNS_WAIT_TIMEOUT=0
if verify_console_dns >/dev/null 2>&1; then
    fail "mismatched console A passed bootstrap verification"
else
    pass "mismatched console A fails closed"
fi
DIG_A=198.51.100.9
derive_domains example.com
CERT_MODE=http-01
verify_console_dns >/dev/null \
    && pass "HTTP-01 verifies console/zash/dot A and empty AAAA through 1.1.1.1" \
    || fail "valid HTTP-01 service DNS was rejected"
for name in console.example.com zash.example.com dot.example.com; do
    grep -q " A ${name} @1.1.1.1" "$DIG_LOG" \
        || fail "HTTP-01 DNS gate did not query A for ${name} through 1.1.1.1"
    grep -q " AAAA ${name} @1.1.1.1" "$DIG_LOG" \
        || fail "HTTP-01 DNS gate did not query AAAA for ${name} through 1.1.1.1"
done
DIG_AAAA=2001:db8::9
if verify_console_dns >/dev/null 2>&1; then
    fail "HTTP-01 accepted an IPv6 record on the IPv4-only gateway"
else
    pass "HTTP-01 rejects published AAAA records"
fi
DIG_AAAA=""
CERT_MODE=debug
: > "$DIG_LOG"
verify_console_dns >/dev/null \
    && [[ ! -s "$DIG_LOG" ]] \
    && pass "debug mode skips public DNS checks" \
    || fail "debug mode unexpectedly required public DNS"
SKIP_CONSOLE_DNS_CHECK=1
CERT_MODE=cloudflare
DIG_A=203.0.113.8
if verify_console_dns >/dev/null 2>&1; then
    fail "caller environment bypassed the console DNS safety gate"
else
    pass "console DNS gate ignores caller environment bypasses"
fi
unset SKIP_CONSOLE_DNS_CHECK

# Initial HTTP-01 issuance releases :80 only when mihomo was active and always
# restores that original state, including after Certbot failure.
PORT80_LOG="$TMP/http-port80.log"
HTTP_MIHOMO_ACTIVE=1
HTTP_CERTBOT_RC=1
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$PORT80_LOG"
    case "$1" in
        is-active) [[ "$HTTP_MIHOMO_ACTIVE" == 1 ]] ;;
        stop|start) return 0 ;;
        *) return 0 ;;
    esac
}
certbot() {
    printf 'certbot %s\n' "$*" >> "$PORT80_LOG"
    return "$HTTP_CERTBOT_RC"
}
: > "$PORT80_LOG"
if run_http_certbot certonly --standalone >/dev/null 2>&1; then
    fail "HTTP-01 wrapper hid a Certbot failure"
elif grep -q '^systemctl stop mihomo.service$' "$PORT80_LOG" \
  && grep -q '^systemctl start mihomo.service$' "$PORT80_LOG"; then
    pass "HTTP-01 restores an originally active mihomo after Certbot failure"
else
    fail "HTTP-01 did not stop and restore active mihomo around Certbot"
fi
HTTP_MIHOMO_ACTIVE=0
HTTP_CERTBOT_RC=0
: > "$PORT80_LOG"
run_http_certbot certonly --standalone >/dev/null 2>&1 \
    || fail "HTTP-01 wrapper failed with inactive mihomo and successful Certbot"
if grep -Eq '^systemctl (stop|start) mihomo.service$' "$PORT80_LOG"; then
    fail "HTTP-01 changed the state of an originally inactive mihomo"
else
    pass "HTTP-01 leaves an originally inactive mihomo stopped"
fi

# Static gates for operations that are intentionally not executed in a unit
# test (root binary install, systemd, certificate issuance, network fallback).
if grep -Eq 'nft flush ruleset|systemctl disable --now nftables|> /etc/nftables.conf' "$INSTALL"; then
    fail "installer still globally flushes/disables/overwrites nftables"
else
    pass "installer contains no global nftables mutation"
fi
lock_fn="$(sed -n '/^acquire_install_cert_lock()/,/^}/p' "$INSTALL")"
if grep -Fq 'CERT_RENEW_LOCK_FILE="/run/5gpn/cert-renew.lock"' "$INSTALL" \
   && grep -Fq '! -L "$lock_dir"' <<<"$lock_fn" \
   && grep -Fq 'file_uid "$lock_dir"' <<<"$lock_fn" \
   && ! grep -Fq '/run/lock/' "$INSTALL"; then
    pass "certificate lock uses a root-owned private non-symlink runtime directory"
else
    fail "certificate lock can clobber or follow files in a shared runtime directory"
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
grep -Fq 'Release tag ${tag} is unavailable; refusing to use a branch.' "$QUICK" \
    && ! grep -Fq 'origin main' "$QUICK" \
    && pass "quick install fallback stays on the resolved release tag" \
    || fail "quick install can fall forward to a branch"
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
