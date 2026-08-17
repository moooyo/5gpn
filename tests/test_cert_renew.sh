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

TMP="$(mktemp -d /var/tmp/5gpn-cert-renew.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
if [[ -d /proc/self/fd ]]; then
    runtime_helper_dir="$TMP/runtime-helper"
    mkdir -p "$runtime_helper_dir"
    chmod 0755 "$runtime_helper_dir"
    cat > "$runtime_helper_dir/configure-runtime-gate.sh" <<'BOUND_GATE_HELPER'
#!/usr/bin/env bash
# 5gpn-configure-runtime-gate-id: v1
# usage: wait|validate-ui|assert-clear
set -eu
[[ "$#" == 1 && "$1" == assert-clear ]]
: > "$TEST_BOUND_RUNTIME_GATE_HELPER"
BOUND_GATE_HELPER
    chmod 0755 "$runtime_helper_dir/configure-runtime-gate.sh"
    RUNTIME_GATE_HELPER="$runtime_helper_dir/configure-runtime-gate.sh"
    export TEST_BOUND_RUNTIME_GATE_HELPER="$TMP/runtime-gate-helper-ran"
    assert_no_retained_configure_gate \
        || fail "bound configure runtime-gate helper assertion failed"
    [[ -f "$TEST_BOUND_RUNTIME_GATE_HELPER" ]] \
        || fail "bound configure runtime-gate helper FD was not executed"
    chmod 0777 "$runtime_helper_dir"
    if assert_no_retained_configure_gate >/dev/null 2>&1; then
        fail "runtime-gate helper accepted a writable parent directory"
    fi
    chmod 0755 "$runtime_helper_dir"
    pass "runtime-gate assertion binds helper parent, inode, metadata, digest, and execution FD"
fi
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
CERTBOT_OWNERSHIP_FILE="$CERT_ROOT/.certbot-ownership"
DEPLOY_HOOK="$TMP/99-5gpn.sh"
export TEST_CERT_ROOT="$CERT_ROOT"
cat > "$DEPLOY_HOOK" <<'EOF'
#!/usr/bin/env bash
# 5gpn-renew-hook-id: deploy-v1
# Let's Encrypt renewal deploy hook; reads DNS_BASE_DOMAIN; publishes /etc/5gpn/cert.
set -eu
[[ "${RENEW_HOOK_VALIDATE_ONLY:-0}" == 1 ]] && exit 0
if [[ "${FIVEGPN_PROFILE_ONLY_REFRESH:-0}" == 1 ]]; then
    touch "$TEST_CERT_ROOT/.profile-only-ran"
    exit 0
fi
for role in dot console; do
    mkdir -p "$TEST_CERT_ROOT/$role/generations/fixture"
    cp "$RENEWED_LINEAGE/fullchain.pem" "$TEST_CERT_ROOT/$role/generations/fixture/fullchain.pem"
    cp "$RENEWED_LINEAGE/privkey.pem" "$TEST_CERT_ROOT/$role/generations/fixture/privkey.pem"
    chmod 0640 "$TEST_CERT_ROOT/$role/generations/fixture/fullchain.pem" "$TEST_CERT_ROOT/$role/generations/fixture/privkey.pem"
    ln -sfn generations/fixture "$TEST_CERT_ROOT/$role/current"
done
touch "$TEST_CERT_ROOT/.deploy-ran"
EOF
chmod +x "$DEPLOY_HOOK"

RACE_HOOK="$TMP/race-hook.sh"
RACE_SENTINEL="$TMP/race-hook-ran"
printf '#!/bin/bash\n%-500s\n' ':' > "$RACE_HOOK"
chmod 0755 "$RACE_HOOK"
old_race_digest="$(sha256sum "$RACE_HOOK" | awk '{print $1}')"
original_deploy_hook_state="$(declare -f deploy_hook_state)"
DEPLOY_HOOK="$RACE_HOOK"
race_state_calls=0
deploy_hook_state() {
    race_state_calls=$((race_state_calls + 1))
    if [[ "$race_state_calls" == 1 ]]; then
        printf '#!/bin/bash\n%-500s\n' ': > "$RACE_SENTINEL"' > "$RACE_HOOK"
        chmod 0755 "$RACE_HOOK"
        printf '%s:%s\n' \
            "$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$RACE_HOOK")" \
            "$old_race_digest"
        return
    fi
    return 1
}
export RACE_SENTINEL
if run_bound_deploy_hook validate "$TMP/live/example.com" >/dev/null 2>&1; then
    fail "same-inode deploy-hook byte drift was executed"
else
    pass "same-inode deploy-hook byte drift is rejected before execution"
fi
[[ ! -e "$RACE_SENTINEL" ]] || fail "drifted deploy hook reached root execution"
eval "$original_deploy_hook_state"
DEPLOY_HOOK="$TMP/99-5gpn.sh"

sync_role_copies() {
    local role
    for role in dot console; do
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
MOCK_OWNERSHIP_BASE=example.com
write_renewal_conf

# Keep every case inside the temporary tree and bypass the real global lock.
LOCK_ORDER=""
MOCK_GATE_CLEAR=1
acquire_install_gate() { LOCK_ORDER=install; }
assert_no_retained_configure_gate() {
    [[ "$LOCK_ORDER" == install && "$MOCK_GATE_CLEAR" == 1 ]] || return 1
    LOCK_ORDER=install-gate
}
acquire_renew_lock() {
    [[ "$LOCK_ORDER" == install-gate ]] || return 1
    LOCK_ORDER=install-gate-cert
}
cf_credential_safe() { return 0; }
cert_provenance_selects_owned() { [[ "$MOCK_PROVENANCE" == owned ]]; }
file_uid() { printf '0\n'; }
file_gid() { printf '0\n'; }
write_ownership_record() {
    rm -f -- "$CERTBOT_OWNERSHIP_FILE"
    [[ -n "$MOCK_OWNERSHIP_BASE" ]] || return 0
    printf 'version=1\nowned=%s\n' "$MOCK_OWNERSHIP_BASE" > "$CERTBOT_OWNERSHIP_FILE"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE"
}
MOCK_ROLE_TREE_SAFE=1
certificate_role_current_safe() { [[ "$MOCK_ROLE_TREE_SAFE" == 1 ]]; }
cert_role_ctl_current_target() { printf 'generations/fixture\n'; }
MOCK_PROFILE_INPUTS_MATCH=1
profile_inputs_match_live() {
    [[ "$MOCK_PROFILE_INPUTS_MATCH" == 1 || -e "$CERT_ROOT/.profile-only-ran" ]]
}

cfg_get() {
    case "$1" in
        DNS_BASE_DOMAIN)    printf '%s\n' "$CFG_BASE" ;;
        CERT_MODE)          printf '%s\n' "$CFG_MODE" ;;
        DNS_PUBLIC_IP)      printf '%s\n' "$CFG_PUBLIC" ;;
        *)                  return 0 ;;
    esac
}

# Bash 3.2 has no mapfile builtin. A function shadows the builtin on newer
# Bash too and fills the two dynamically scoped arrays used by this helper.
mapfile() {
    local option="${1:-}" target="${2:-}" line
    [[ "$option" == -t ]] || return 2
    case "$target" in
        domains)
            domains=()
            while IFS= read -r line; do domains[${#domains[@]}]="$line"; done ;;
        lines)
            lines=()
            while IFS= read -r line; do lines[${#lines[@]}]="$line"; done ;;
        *) return 2 ;;
    esac
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
    rm -f -- "$CERT_ROOT/.profile-only-ran"
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
    MOCK_OWNERSHIP_BASE=example.com
    MOCK_ROLE_TREE_SAFE=1
    MOCK_PROFILE_INPUTS_MATCH=1
    MOCK_GATE_CLEAR=1
    LOCK_ORDER=""
    write_ownership_record
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
MOCK_GATE_CLEAR=0
expect_failure "retained configure gate defers public certificate renewal" cert_renew_main --cert-name example.com
[[ "$LOCK_ORDER" == install ]] \
    && pass "retained gate refusal happens after the install lock and before the certificate lock" \
    || fail "retained gate refusal crossed the certificate-lock boundary"
expect_no_log "certbot " "retained gate refusal performs no Certbot mutation"
expect_no_log "systemctl " "retained gate refusal performs no systemd mutation"

reset_case
MOCK_CERT_FRESH=1
expect_success "not-due HTTP certificate exits successfully" cert_renew_main --cert-name example.com
[[ "$LOCK_ORDER" == install-gate-cert ]] \
    && pass "public renewal checks retained gate state between the install and certificate locks" \
    || fail "public renewal lock/gate order is not install, gate, certificate"
expect_no_log "dig " "not-due certificate does not query DNS"
expect_no_log "systemctl " "not-due certificate does not inspect/stop mihomo"
expect_no_log "certbot " "not-due certificate does not invoke Certbot"
[[ ! -e "$CERT_ROOT/.deploy-ran" ]] \
    && pass "correct role groups preserve the not-due fast path" \
    || fail "correct role groups caused an unnecessary redeploy"

reset_case
MOCK_CERT_FRESH=1
MOCK_PROFILE_INPUTS_MATCH=0
expect_success "not-due lineage repairs stale profile inputs" cert_renew_main --cert-name example.com
[[ -e "$CERT_ROOT/.profile-only-ran" && ! -e "$CERT_ROOT/.deploy-ran" ]] \
    && pass "stale profile inputs use profile-only generation repair" \
    || fail "stale profile inputs were skipped or republished certificate roles"

reset_case
MOCK_CERT_FRESH=1
MOCK_ROLE_TREE_SAFE=0
expect_failure "unsafe certificate root tree fails the not-due fast path" cert_renew_main --cert-name example.com
expect_no_log "certbot " "unsafe role tree never reaches Certbot"

# A fresh live lineage with a stale role copy is repaired through the owned
# deploy hook instead of being skipped forever as "not due".
reset_case
MOCK_CERT_FRESH=1
printf 'stale\n' > "$CERT_ROOT/dot/current/fullchain.pem"
expect_success "not-due lineage repairs stale role copies" cert_renew_main --cert-name example.com
cmp -s "$LE_LIVE_ROOT/example.com/fullchain.pem" "$CERT_ROOT/dot/current/fullchain.pem" \
    && pass "stale role certificate was redeployed from the live lineage" \
    || fail "stale role certificate survived the not-due fast path"
[[ ! -e "$CERT_ROOT/web" && ! -L "$CERT_ROOT/web" ]] \
    && pass "renewal does not recreate the retired web certificate role" \
    || fail "renewal recreated the retired web certificate role"

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
expect_log "systemctl stop 5gpn-mihomo.service" "active 5gpn-mihomo is stopped for HTTP-01"
expect_log "certbot renew --cert-name example.com --non-interactive" "HTTP Certbot call is cert-name scoped"
expect_log "systemctl start 5gpn-mihomo.service" "failed HTTP Certbot attempt restores 5gpn-mihomo"
expect_before "dig A console.example.com @1.1.1.1" "systemctl stop 5gpn-mihomo.service" "DNS gate completes before 5gpn-mihomo is stopped"
expect_before "systemctl stop 5gpn-mihomo.service" "certbot renew --cert-name example.com --non-interactive" "5gpn-mihomo stops before HTTP Certbot"
expect_before "certbot renew --cert-name example.com --non-interactive" "systemctl start 5gpn-mihomo.service" "5gpn-mihomo restarts after failed HTTP Certbot"

# Even a partially failing stop operation is followed by a restore attempt;
# Certbot must not start while :80 ownership is uncertain.
reset_case
MOCK_STOP_RC=5
expect_failure "failed mihomo stop aborts HTTP renewal" cert_renew_main --cert-name example.com
expect_log "systemctl start 5gpn-mihomo.service" "failed stop still restores the originally active 5gpn-mihomo"
expect_no_log "certbot " "failed stop never reaches Certbot"

# An initially inactive data plane is neither stopped nor spuriously started.
reset_case
MOCK_MIHOMO_ACTIVE=0
expect_success "HTTP renewal works with initially inactive mihomo" cert_renew_main --cert-name example.com
expect_log "certbot renew --cert-name example.com --non-interactive" "inactive-mihomo renewal remains cert-name scoped"
expect_no_log "systemctl stop 5gpn-mihomo.service" "initially inactive 5gpn-mihomo is not stopped"
expect_no_log "systemctl start 5gpn-mihomo.service" "initially inactive 5gpn-mihomo is not started"

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

# Current provenance alone is not renewal authority. The independent retained
# ownership record must name the exact configured base before Certbot or live
# certificate inspection.
reset_case
CFG_MODE=cloudflare
MOCK_OWNERSHIP_BASE=""
write_ownership_record
expect_failure "missing ownership record rejects project-managed renewal" cert_renew_main --cert-name example.com
expect_no_log "openssl " "missing ownership rejection precedes certificate inspection"
expect_no_log "certbot " "missing ownership rejection never reaches Certbot"
expect_no_log "systemctl " "missing ownership rejection never touches mihomo"

reset_case
CFG_MODE=cloudflare
MOCK_OWNERSHIP_BASE=other.example
write_ownership_record
expect_failure "other-base ownership record rejects project-managed renewal" cert_renew_main --cert-name example.com
expect_no_log "openssl " "other-base ownership rejection precedes certificate inspection"
expect_no_log "certbot " "other-base ownership rejection never reaches Certbot"
expect_no_log "systemctl " "other-base ownership rejection never touches mihomo"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "cert renew helper: PASS"
else
    echo "cert renew helper: FAIL"
    exit 1
fi
