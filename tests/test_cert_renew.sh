#!/usr/bin/env bash
# Behaviour tests for the mode-aware, cert-name-scoped renewal helper. All
# external effects are mocked; no host certificate, DNS, or service state is
# touched. Kept compatible with Bash 3.2 used by the macOS development runner.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/cert-renew.sh"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export CERT_RENEW_LIB_ONLY=1
# shellcheck source=../scripts/cert-renew.sh
source "$HELPER"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
LOG="$TMP/actions.log"
LE_LIVE_ROOT="$TMP/live"
LE_RENEWAL_ROOT="$TMP/renewal"
LE_ARCHIVE_ROOT="$TMP/archive"
DNS_WAIT_TIMEOUT=0
DNS_WAIT_INTERVAL=0
mkdir -p "$LE_LIVE_ROOT/example.com" "$LE_RENEWAL_ROOT" "$LE_ARCHIVE_ROOT/example.com"
printf 'mock certificate\n' > "$LE_LIVE_ROOT/example.com/fullchain.pem"
printf 'mock private key\n' > "$LE_LIVE_ROOT/example.com/privkey.pem"
CERT_ROOT="$TMP/cert"
DEPLOY_HOOK="$TMP/99-5gpn.sh"
export TEST_CERT_ROOT="$CERT_ROOT"
cat > "$DEPLOY_HOOK" <<'EOF'
#!/usr/bin/env bash
# 5gpn-renew-hook-id: deploy-v1
# Let's Encrypt renewal deploy hook; reads DNS_BASE_DOMAIN; publishes /etc/5gpn/cert.
set -eu
[[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]] && exit 0
for role in dot web zash; do
    mkdir -p "$TEST_CERT_ROOT/$role/generations/fixture"
    cp "$RENEWED_LINEAGE/fullchain.pem" "$TEST_CERT_ROOT/$role/generations/fixture/fullchain.pem"
    cp "$RENEWED_LINEAGE/privkey.pem" "$TEST_CERT_ROOT/$role/generations/fixture/privkey.pem"
    chmod 0640 "$TEST_CERT_ROOT/$role/generations/fixture/fullchain.pem" "$TEST_CERT_ROOT/$role/generations/fixture/privkey.pem"
    ln -sfn generations/fixture "$TEST_CERT_ROOT/$role/current"
done
touch "$TEST_CERT_ROOT/.deploy-ran"
EOF
chmod +x "$DEPLOY_HOOK"

# The production helper resolves the required group names through NSS and
# compares numeric GIDs. Synthetic IDs make the role mapping testable on hosts
# that do not have the gateway service accounts.
MOCK_BAD_GROUP_ROLE=""
MOCK_BAD_GROUP_FILE=""
named_group_gid() {
    case "$1" in
        5gpn-dns) printf '%s\n' 61001 ;;
        mihomo) printf '%s\n' 61002 ;;
        *) return 1 ;;
    esac
}
file_gid() {
    local path="$1" role expected basename
    case "$path" in
        "$CERT_ROOT"/dot/*) role=dot; expected=61001 ;;
        "$CERT_ROOT"/web/*) role=web; expected=61001 ;;
        "$CERT_ROOT"/zash/*) role=zash; expected=61002 ;;
        *) return 1 ;;
    esac
    basename="${path##*/}"
    if [[ "$role" == "$MOCK_BAD_GROUP_ROLE" \
       && ( -z "$MOCK_BAD_GROUP_FILE" || "$basename" == "$MOCK_BAD_GROUP_FILE" ) \
       && ! -e "$CERT_ROOT/.deploy-ran" ]]; then
        printf '%s\n' 61999
    else
        printf '%s\n' "$expected"
    fi
}

sync_role_copies() {
    local role
    for role in dot web zash; do
        mkdir -p "$CERT_ROOT/$role/generations/fixture"
        cp "$LE_LIVE_ROOT/example.com/fullchain.pem" "$CERT_ROOT/$role/generations/fixture/fullchain.pem"
        cp "$LE_LIVE_ROOT/example.com/privkey.pem" "$CERT_ROOT/$role/generations/fixture/privkey.pem"
        chmod 0640 "$CERT_ROOT/$role/generations/fixture/fullchain.pem" "$CERT_ROOT/$role/generations/fixture/privkey.pem"
        ln -sfn generations/fixture "$CERT_ROOT/$role/current"
    done
}
sync_role_copies

write_renewal_conf() {
    local auth extra=""
    case "$CFG_MODE" in
        cloudflare)
            auth=dns-cloudflare
            extra='dns_cloudflare_credentials = /etc/5gpn/acme/cloudflare.ini' ;;
        *) auth=standalone ;;
    esac
    cat > "$LE_RENEWAL_ROOT/example.com.conf" <<EOF
archive_dir = $LE_ARCHIVE_ROOT/example.com
cert = $LE_LIVE_ROOT/example.com/cert.pem
privkey = $LE_LIVE_ROOT/example.com/privkey.pem
chain = $LE_LIVE_ROOT/example.com/chain.pem
fullchain = $LE_LIVE_ROOT/example.com/fullchain.pem
server = https://acme-v02.api.letsencrypt.org/directory
authenticator = $auth
$extra
EOF
}

CFG_BASE=example.com
CFG_MODE=http-01
CFG_PUBLIC=203.0.113.9
MOCK_CERT_FRESH=0
MOCK_DNS_MODE=ready
MOCK_MIHOMO_ACTIVE=1
MOCK_CERTBOT_RC=0
MOCK_STOP_RC=0
MOCK_START_RC=0
MOCK_PROVENANCE=owned
write_renewal_conf

# Keep every case inside the temporary tree and bypass the real global lock.
LOCK_ORDER=""
acquire_install_gate() { LOCK_ORDER=install; }
acquire_renew_lock() {
    [[ "$LOCK_ORDER" == install ]] || return 1
    LOCK_ORDER=install-cert
}
cf_credential_safe() { return 0; }
cert_provenance_owned() { [[ "$MOCK_PROVENANCE" == owned ]]; }
MOCK_ROLE_TREE_SAFE=1
certificate_role_tree_safe() { [[ "$MOCK_ROLE_TREE_SAFE" == 1 ]]; }

cfg_get() {
    case "$1" in
        DNS_BASE_DOMAIN)    printf '%s\n' "$CFG_BASE" ;;
        CERT_MODE)          printf '%s\n' "$CFG_MODE" ;;
        DNS_PUBLIC_IP)      printf '%s\n' "$CFG_PUBLIC" ;;
        *)                  return 0 ;;
    esac
}

# Bash 3.2 has no mapfile builtin. A function shadows the builtin on newer
# Bash too and fills cert_renew_main's dynamically scoped local domains array.
mapfile() {
    local option="${1:-}" target="${2:-}" line
    [[ "$option" == -t && "$target" == domains ]] || return 2
    domains=()
    while IFS= read -r line; do
        domains[${#domains[@]}]="$line"
    done
}

openssl() {
    printf 'openssl %s\n' "$*" >> "$LOG"
    [[ "$MOCK_CERT_FRESH" == 1 ]]
}

dig() {
    local query="${4:-}" domain="${5:-}" resolver="${6:-}"
    printf 'dig %s %s %s\n' "$query" "$domain" "$resolver" >> "$LOG"
    case "$query:$MOCK_DNS_MODE" in
        A:ready|A:aaaa) printf '%s\n' "$CFG_PUBLIC" ;;
        A:mismatch)     printf '198.51.100.77\n' ;;
        A:cname)        printf 'alias.example.net.\n%s\n' "$CFG_PUBLIC" ;;
        A:multi)        printf '%s\n%s\n' "$CFG_PUBLIC" "$CFG_PUBLIC" ;;
        AAAA:aaaa)      printf '2001:db8::9\n' ;;
    esac
    return 0
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$LOG"
    case "${1:-}" in
        is-active) [[ "$MOCK_MIHOMO_ACTIVE" == 1 ]] ;;
        stop)
            [[ "$MOCK_STOP_RC" == 0 ]] || return "$MOCK_STOP_RC"
            MOCK_MIHOMO_ACTIVE=0 ;;
        start)
            [[ "$MOCK_START_RC" == 0 ]] || return "$MOCK_START_RC"
            MOCK_MIHOMO_ACTIVE=1 ;;
        *) return 0 ;;
    esac
}

certbot() {
    printf 'certbot %s\n' "$*" >> "$LOG"
    return "$MOCK_CERTBOT_RC"
}

reset_case() {
    : > "$LOG"
    rm -f -- "$CERT_ROOT/.deploy-ran"
    CFG_BASE=example.com
    CFG_MODE=http-01
    CFG_PUBLIC=203.0.113.9
    MOCK_CERT_FRESH=0
    MOCK_DNS_MODE=ready
    MOCK_MIHOMO_ACTIVE=1
    MOCK_CERTBOT_RC=0
    MOCK_STOP_RC=0
    MOCK_START_RC=0
    MOCK_PROVENANCE=owned
    MOCK_ROLE_TREE_SAFE=1
    MOCK_BAD_GROUP_ROLE=""
    MOCK_BAD_GROUP_FILE=""
    LOCK_ORDER=""
    sync_role_copies
    write_renewal_conf
}

expect_success() {
    local label="$1"; shift
    if "$@" > "$TMP/output" 2>&1; then pass "$label"; else fail "$label"; fi
}

expect_failure() {
    local label="$1"; shift
    if "$@" > "$TMP/output" 2>&1; then fail "$label"; else pass "$label"; fi
}

log_has() {
    grep -Fq -- "$1" "$LOG"
}

expect_log() {
    local text="$1" label="$2"
    log_has "$text" && pass "$label" || fail "$label"
}

expect_no_log() {
    local text="$1" label="$2"
    if log_has "$text"; then fail "$label"; else pass "$label"; fi
}

expect_before() {
    local first="$1" second="$2" label="$3" a b
    a="$(grep -nF -- "$first" "$LOG" | head -1 | cut -d: -f1)"
    b="$(grep -nF -- "$second" "$LOG" | head -1 | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}

# A fresh-enough certificate returns before DNS or service inspection.
reset_case
MOCK_CERT_FRESH=1
expect_success "not-due HTTP certificate exits successfully" cert_renew_main --cert-name example.com
[[ "$LOCK_ORDER" == install-cert ]] \
    && pass "public renewal takes the install gate before the certificate lock" \
    || fail "public renewal lock order is not install then certificate"
expect_no_log "dig " "not-due certificate does not query DNS"
expect_no_log "systemctl " "not-due certificate does not inspect/stop mihomo"
expect_no_log "certbot " "not-due certificate does not invoke Certbot"
[[ ! -e "$CERT_ROOT/.deploy-ran" ]] \
    && pass "correct role groups preserve the not-due fast path" \
    || fail "correct role groups caused an unnecessary redeploy"

reset_case
MOCK_CERT_FRESH=1
MOCK_ROLE_TREE_SAFE=0
expect_failure "unsafe certificate root tree fails the not-due fast path" cert_renew_main --cert-name example.com
expect_no_log "certbot " "unsafe role tree never reaches Certbot"

# A fresh live lineage with a stale role copy is repaired through the owned
# deploy hook instead of being skipped forever as "not due".
reset_case
MOCK_CERT_FRESH=1
printf 'stale\n' > "$CERT_ROOT/web/current/fullchain.pem"
expect_success "not-due lineage repairs stale role copies" cert_renew_main --cert-name example.com
cmp -s "$LE_LIVE_ROOT/example.com/fullchain.pem" "$CERT_ROOT/web/current/fullchain.pem" \
    && pass "stale role certificate was redeployed from the live lineage" \
    || fail "stale role certificate survived the not-due fast path"

# Content, owner, and mode are insufficient: the DNS copies must be readable
# only through gpn-dns and the zashboard copy only through mihomo. A wrong role
# group is treated as stale and repaired by the owned deploy hook.
reset_case
MOCK_CERT_FRESH=1
MOCK_BAD_GROUP_ROLE=zash
MOCK_BAD_GROUP_FILE=privkey.pem
expect_success "not-due lineage repairs a role copy with the wrong group" cert_renew_main --cert-name example.com
[[ -e "$CERT_ROOT/.deploy-ran" ]] \
    && pass "wrong zash group forced deploy-hook recovery" \
    || fail "wrong zash group was accepted without deploy-hook recovery"

reset_case
MOCK_CERT_FRESH=1
MOCK_BAD_GROUP_ROLE=web
MOCK_BAD_GROUP_FILE=fullchain.pem
expect_success "not-due lineage repairs a DNS role copy with the wrong group" cert_renew_main --cert-name example.com
[[ -e "$CERT_ROOT/.deploy-ran" ]] \
    && pass "wrong web group forced deploy-hook recovery" \
    || fail "wrong web group was accepted without deploy-hook recovery"

# A stale AAAA record fails the fixed-resolver gate before any :80 disruption.
reset_case
MOCK_DNS_MODE=aaaa
expect_failure "HTTP DNS failure aborts renewal" cert_renew_main --cert-name example.com
expect_log "dig A console.example.com @1.1.1.1" "HTTP renewal checks A through 1.1.1.1"
expect_log "dig AAAA console.example.com @1.1.1.1" "HTTP renewal checks AAAA through 1.1.1.1"
expect_no_log "certbot " "HTTP DNS failure does not invoke Certbot"
expect_no_log "systemctl " "HTTP DNS failure does not touch mihomo"

reset_case
MOCK_DNS_MODE=cname
expect_failure "HTTP DNS rejects a CNAME indirection" cert_renew_main --cert-name example.com
expect_no_log "systemctl " "CNAME rejection happens before touching mihomo"

reset_case
MOCK_DNS_MODE=multi
expect_failure "HTTP DNS rejects multiple A answers" cert_renew_main --cert-name example.com
expect_no_log "systemctl " "multiple-A rejection happens before touching mihomo"

# If Certbot fails after stopping an active mihomo, restoration still happens
# and the order remains DNS -> stop -> Certbot -> start.
reset_case
MOCK_CERTBOT_RC=23
expect_failure "failed HTTP Certbot attempt is reported" cert_renew_main --cert-name example.com
expect_log "systemctl stop mihomo" "active mihomo is stopped for HTTP-01"
expect_log "certbot renew --cert-name example.com --non-interactive" "HTTP Certbot call is cert-name scoped"
expect_log "systemctl start mihomo" "failed HTTP Certbot attempt restores mihomo"
expect_before "dig A console.example.com @1.1.1.1" "systemctl stop mihomo" "DNS gate completes before mihomo is stopped"
expect_before "systemctl stop mihomo" "certbot renew --cert-name example.com --non-interactive" "mihomo stops before HTTP Certbot"
expect_before "certbot renew --cert-name example.com --non-interactive" "systemctl start mihomo" "mihomo restarts after failed HTTP Certbot"

# Even a partially failing stop operation is followed by a restore attempt;
# Certbot must not start while :80 ownership is uncertain.
reset_case
MOCK_STOP_RC=5
expect_failure "failed mihomo stop aborts HTTP renewal" cert_renew_main --cert-name example.com
expect_log "systemctl start mihomo" "failed stop still restores the originally active mihomo"
expect_no_log "certbot " "failed stop never reaches Certbot"

# An initially inactive data plane is neither stopped nor spuriously started.
reset_case
MOCK_MIHOMO_ACTIVE=0
expect_success "HTTP renewal works with initially inactive mihomo" cert_renew_main --cert-name example.com
expect_log "certbot renew --cert-name example.com --non-interactive" "inactive-mihomo renewal remains cert-name scoped"
expect_no_log "systemctl stop mihomo" "initially inactive mihomo is not stopped"
expect_no_log "systemctl start mihomo" "initially inactive mihomo is not started"

# Cloudflare DNS-01 never enters the HTTP DNS or mihomo handoff path.
reset_case
CFG_MODE=cloudflare
write_renewal_conf
expect_success "Cloudflare renewal succeeds through scoped Certbot" cert_renew_main
expect_log "certbot renew --cert-name example.com --non-interactive" "timer-style Cloudflare renewal derives the exact cert name"
expect_no_log "dig " "Cloudflare renewal does not run the HTTP DNS gate"
expect_no_log "systemctl " "Cloudflare renewal does not touch mihomo"

# Root-executed per-lineage hooks are never adopted; 5gpn uses its one audited
# directory deploy hook and mode-aware wrapper instead.
reset_case
printf 'pre_hook = /tmp/untrusted-command\n' >> "$LE_RENEWAL_ROOT/example.com.conf"
expect_failure "persistent Certbot hooks are rejected" cert_renew_main --cert-name example.com
expect_no_log "certbot " "unsafe renewal config never reaches Certbot"
expect_no_log "systemctl " "unsafe renewal config never touches mihomo"

reset_case
printf 'server = https://acme-staging-v02.api.letsencrypt.org/directory\n' >> "$LE_RENEWAL_ROOT/example.com.conf"
expect_failure "non-production ACME server is rejected" cert_renew_main --cert-name example.com
expect_no_log "certbot " "staging/custom ACME config never reaches Certbot"

# A caller cannot select another lineage, even if it supplies a valid FQDN.
reset_case
CFG_MODE=cloudflare
expect_failure "mismatched requested cert name is rejected" cert_renew_main --cert-name other.example.com
expect_no_log "openssl " "cert-name mismatch fails before certificate inspection"
expect_no_log "certbot " "cert-name mismatch never reaches Certbot"
expect_no_log "systemctl " "cert-name mismatch never touches mihomo"

# The fixed public helper is never renewal authority for a reused external
# lineage, even if an old unit or a confirmed Bot action still starts it.
reset_case
CFG_MODE=cloudflare
MOCK_PROVENANCE=reused
expect_failure "reused external lineage rejects project-managed renewal" cert_renew_main --cert-name example.com
expect_no_log "openssl " "external lineage rejection precedes certificate inspection"
expect_no_log "certbot " "external lineage rejection never reaches Certbot"
expect_no_log "systemctl " "external lineage rejection never touches mihomo"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "cert renew helper: PASS"
else
    echo "cert renew helper: FAIL"
    exit 1
fi
