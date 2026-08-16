#!/usr/bin/env bash
# Unsupported legacy footprints are detected read-only before publication.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d /tmp/5gpn-current-preflight.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

detector="$(sed -n '/^detect_legacy_footprints()/,/^}/p' "$INSTALL")"
[[ -n "$detector" ]] || fail "legacy-footprint detector is missing"

for token in \
    unit_definition_exists mihomo.service 5gpn-dns.service 5gpn-intercept.service \
    5gpn-intercept-runtime.path 5gpn-journal@.service \
    5gpn-journal@5gpn-dns.service 5gpn-journal@mihomo.service \
    gpn-dns gpn-intercept 5gpn-overlay-ctl 5gpn-overlay-gen \
    'migrate-panel-to-console.sh' 'migrate-state-to-monolith.sh' \
    'migrate-to-monolith.sh' '"${BIN_DIR}/mihomo"' '"${MIHOMO_DIR}/gpn"' \
    '"${DNS_CERT_DIR}/web"' legacy_dns_env_key_is_known \
    RUNTIME-OVERLAY intercept-egress MODULE-INTERCEPT runtime-overlay-processor \
    IDENTITY_RECONCILE_FILE fixed_root_is_safe_for_readonly_inspection; do
    grep -Fq "$token" <<<"$detector" \
        || fail "legacy-footprint detector does not cover $token"
done
pass "legacy-footprint detector covers every retired surface"

# The detector may silence read-only probes to /dev/null, but no other output
# redirection or mutating command belongs in this function.
detector_without_null_redirects="$(sed -E \
    -e 's/[0-9]*>\/dev\/null([[:space:]]+2>&1)?//g' \
    -e 's/[0-9]*>&[0-9]+//g' <<<"$detector")"
if grep -Eq '(^|[;&|()[:space:]])(rm|mv|cp|install|chmod|chown|mkdir|rmdir|touch|ln|truncate|tee|dd|useradd|groupadd|userdel|groupdel)([[:space:]]|$)|systemctl[[:space:]]+(stop|disable|enable|restart|start|mask|unmask|daemon-reload)|sed[[:space:]]+-i' <<<"$detector" \
   || grep -Eq '(^|[^<])>>?[[:space:]]*[^&[:space:]/]' <<<"$detector_without_null_redirects"; then
    fail "legacy-footprint detector contains a mutating operation"
fi
pass "legacy-footprint detector is structurally read-only"

validator="$(sed -n '/^validate_existing_runtime_documents()/,/^}/p' "$INSTALL")"
[[ -n "$validator" ]] || fail "runtime-document validator integration is missing"
stage_fn="$(sed -n '/^stage_artifacts()/,/^}/p' "$INSTALL")"
grep -Fq 'validate_existing_runtime_documents' <<<"$stage_fn" \
    || fail "staged artifact verification does not invoke runtime document validation"
grep -Fq '"$ARTIFACT_STAGE/mihomo"' <<<"$validator" \
    && grep -Fq '5gpn-state validate' <<<"$validator" \
    && grep -Fq 'FIVEGPN_STATE_DIR' <<<"$validator" \
    && grep -Fq -- '--owner-uid' <<<"$validator" \
    && grep -Fq 'timeout --kill-after=' <<<"$validator" \
    || fail "runtime documents are not validated by the staged Core against their proven owner UID"
if grep -Eq '\bjq\b|\.version[[:space:]]*==|keys[[:space:]]*-' <<<"$detector$validator"; then
    fail "installer shell duplicates Core-owned existing-document validation"
fi
pass "state validation uses the staged Core without a duplicate shell decoder"

full_install="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
line_of() {
    local pattern="$1"
    grep -nE "$pattern" <<<"$full_install" | head -1 | cut -d: -f1
}
load_identity_line="$(line_of '^[[:space:]]*load_identity_reconcile_journal([[:space:]]|$)')"
preload_identity_line="$(line_of '^[[:space:]]*preload_fivegpn_identity_for_claim([[:space:]]|$)')"
detect_line="$(line_of '^[[:space:]]*detect_legacy_footprints([[:space:]]|$)')"
stage_line="$(line_of '^[[:space:]]*stage_artifacts([[:space:]]|$)')"
validate_line="$(line_of '^[[:space:]]*validate_existing_runtime_documents([[:space:]]|$)' || true)"
[[ -n "$validate_line" ]] || validate_line="$stage_line"
publication_line="$(line_of 'INSTALL_PUBLICATION_STARTED=1')"
claim_line="$(line_of '^[[:space:]]*claim_project_roots([[:space:]]|$)')"
account_line="$(line_of '^[[:space:]]*install_service_accounts([[:space:]]|$)')"
service_line="$(line_of '^[[:space:]]*start_services_with_cert_lock_handoff([[:space:]]|$)')"
[[ -n "$load_identity_line" && -n "$preload_identity_line" && -n "$detect_line" \
   && -n "$stage_line" && -n "$validate_line" && -n "$publication_line" \
   && -n "$claim_line" && -n "$account_line" && -n "$service_line" \
   && "$load_identity_line" -lt "$preload_identity_line" \
   && "$preload_identity_line" -lt "$detect_line" \
   && "$stage_line" -le "$validate_line" \
   && "$detect_line" -lt "$publication_line" \
   && "$validate_line" -lt "$publication_line" \
   && "$publication_line" -lt "$claim_line" \
   && "$validate_line" -lt "$account_line" \
   && "$validate_line" -lt "$service_line" ]] \
    || fail "legacy or document validation can run after publication/account/service mutation"
pass "legacy and state validation finish before claims, publication, accounts, and services"

snapshot_roots() {
    local output="$1"
    shift
    {
        find "$@" -xdev -printf '%p|%y|%m|%U|%G|%n|%s|%l\n' | LC_ALL=C sort
        find "$@" -xdev -type f -exec sha256sum -- {} + | LC_ALL=C sort
    } > "$output"
}

CASE_INDEX=0
assert_legacy_case() { # assert_legacy_case <label> <setup-function> [args...]
    local label="$1" setup="$2"
    shift 2
    CASE_INDEX=$((CASE_INDEX + 1))
    if (
        CASE_ROOT="$TMP/case-$CASE_INDEX"
        BASE_DIR="$CASE_ROOT/runtime"
        BIN_DIR="$BASE_DIR/bin"
        SCRIPT_DIR="$BASE_DIR/scripts"
        SCRIPTS_DIR="$BASE_DIR/scripts"
        CONF_DIR="$CASE_ROOT/config"
        MIHOMO_DIR="$CONF_DIR/mihomo"
        DNS_CERT_DIR="$CONF_DIR/cert"
        INTERCEPT_DIR="$CONF_DIR/intercept"
        FIVEGPN_STATE_DIR="$MIHOMO_DIR/5gpn"
        STATE_DIR="$CASE_ROOT/state"
        INTERCEPT_STATE_DIR="$CASE_ROOT/intercept-state"
        IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
        LEGACY_UNIT=""
        LEGACY_PASSWD=""
        LEGACY_GROUP=""
        LEGACY_ROLE=""
        mkdir -p "$BIN_DIR" "$SCRIPT_DIR" "$MIHOMO_DIR" "$DNS_CERT_DIR" \
            "$INTERCEPT_DIR" "$FIVEGPN_STATE_DIR" "$STATE_DIR" \
            "$INTERCEPT_STATE_DIR"

        fixed_root_is_safe_for_readonly_inspection() {
            [[ "$1" == "$BASE_DIR" || "$1" == "$CONF_DIR" \
               || "$1" == "$STATE_DIR" || "$1" == "$INTERCEPT_STATE_DIR" ]]
        }
        root_ownership_marker_is_safe() {
            [[ -n "$LEGACY_ROLE" && "$1" == "$LEGACY_ROLE" ]]
        }
        unit_definition_exists() { [[ -n "$LEGACY_UNIT" && "$1" == "$LEGACY_UNIT" ]]; }
        unit_file_has_5gpn_marker() { return 1; }
        current_managed_unit_file_is_safe() { return 1; }
        getent() {
            local database="${1:-}" key="${2:-}"
            case "$database:$key" in
                passwd:"$LEGACY_PASSWD")
                    [[ -n "$LEGACY_PASSWD" ]] \
                        && printf '%s:x:498:498::/nonexistent:/usr/sbin/nologin\n' "$LEGACY_PASSWD" ;;
                group:"$LEGACY_GROUP")
                    [[ -n "$LEGACY_GROUP" ]] \
                        && printf '%s:x:498:\n' "$LEGACY_GROUP" ;;
                *) return 1 ;;
            esac
        }
        err() { :; }

        "$setup" "$@"
        before="$CASE_ROOT.before"
        after="$CASE_ROOT.after"
        spy="$CASE_ROOT.spy"
        snapshot_roots "$before" "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR"

        mutation_spy() { printf '%s\n' "$1" >> "$spy"; return 97; }
        rm() { mutation_spy rm; }
        mv() { mutation_spy mv; }
        cp() { mutation_spy cp; }
        install() { mutation_spy install; }
        chmod() { mutation_spy chmod; }
        chown() { mutation_spy chown; }
        mkdir() { mutation_spy mkdir; }
        rmdir() { mutation_spy rmdir; }
        touch() { mutation_spy touch; }
        ln() { mutation_spy ln; }
        truncate() { mutation_spy truncate; }
        tee() { mutation_spy tee; }
        dd() { mutation_spy dd; }
        useradd() { mutation_spy useradd; }
        groupadd() { mutation_spy groupadd; }
        userdel() { mutation_spy userdel; }
        groupdel() { mutation_spy groupdel; }
        systemctl() {
            case "${1:-}" in
                show|is-active|is-enabled|list-unit-files|cat) return 1 ;;
                *) mutation_spy systemctl ;;
            esac
        }

        result=0
        detect_legacy_footprints >/dev/null 2>&1 || result=$?
        unset -f rm mv cp install chmod chown mkdir rmdir touch ln truncate tee dd \
            useradd groupadd userdel groupdel systemctl mutation_spy
        [[ "$result" -ne 0 ]]
        [[ ! -s "$spy" ]]
        snapshot_roots "$after" "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR"
        cmp -s "$before" "$after"
    ); then
        pass "$label"
    else
        fail "$label"
    fi
}

setup_unit() { LEGACY_UNIT="$1"; }
setup_passwd() { LEGACY_PASSWD="$1"; }
setup_group() { LEGACY_GROUP="$1"; }
setup_migration_helper() { printf 'retired helper\n' > "$BASE_DIR/scripts/$1"; }
setup_legacy_key() {
    printf '%s\n' 'DNS_BASE_DOMAIN=example.test' 'DNS_WEB_CERT=/retired/web.pem' \
        > "$CONF_DIR/dns.env"
}
setup_legacy_role() {
    LEGACY_ROLE="$DNS_CERT_DIR/web"
    mkdir -p "$LEGACY_ROLE"
}
setup_legacy_rule() {
    printf '%s\n' 'rules:' "  - $1" > "$MIHOMO_DIR/config.yaml"
}
setup_legacy_listener() {
    printf '%s\n' \
        'listeners:' \
        '  - name: intercept-egress' \
        '    type: socks' \
        '    listen: 127.0.0.1' \
        '    port: 1080' \
        > "$MIHOMO_DIR/config.yaml"
}
setup_legacy_proxy() {
    printf '%s\n' \
        'proxies:' \
        '  - name: MODULE-INTERCEPT' \
        '    type: direct' \
        > "$MIHOMO_DIR/config.yaml"
}
setup_legacy_scalar() {
    printf '%s\n' 'runtime-overlay-processor: true' > "$MIHOMO_DIR/config.yaml"
}

for unit in mihomo.service 5gpn-dns.service 5gpn-intercept.service \
            5gpn-intercept-runtime.path 5gpn-journal@.service \
            5gpn-journal@5gpn-dns.service 5gpn-journal@mihomo.service; do
    assert_legacy_case "retired unit definition $unit is rejected read-only" setup_unit "$unit"
done
assert_legacy_case "generic mihomo user alone is rejected read-only" setup_passwd mihomo
assert_legacy_case "generic mihomo group alone is rejected read-only" setup_group mihomo
for helper in migrate-panel-to-console.sh migrate-state-to-monolith.sh migrate-to-monolith.sh; do
    assert_legacy_case "removed helper $helper is rejected read-only" setup_migration_helper "$helper"
done
assert_legacy_case "retired dns.env key is rejected read-only" setup_legacy_key
assert_legacy_case "retired certificate role is rejected read-only" setup_legacy_role
for rule in 'RUNTIME-OVERLAY,5gpn,legacy' 'IN-NAME,intercept-egress,REJECT'; do
    assert_legacy_case "retired mihomo construct $rule is rejected read-only" setup_legacy_rule "$rule"
done
assert_legacy_case "retired intercept-egress listener is rejected read-only" setup_legacy_listener
assert_legacy_case "retired MODULE-INTERCEPT proxy is rejected read-only" setup_legacy_proxy
assert_legacy_case "retired runtime-overlay-processor scalar is rejected read-only" setup_legacy_scalar

# Runtime document schemas belong to the staged Core rather than the legacy
# name detector. A Core rejection must still be read-only and carry the exact
# proven owner UID.
(
    CASE_ROOT="$TMP/document-case"
    FIVEGPN_STATE_DIR="$CASE_ROOT/state"
    ARTIFACT_STAGE="$CASE_ROOT/stage"
    VALIDATOR_LOG="$TMP/document-validator.args"
    mkdir -p "$FIVEGPN_STATE_DIR" "$ARTIFACT_STAGE"
    printf '{"version":5}\n' > "$FIVEGPN_STATE_DIR/intercept.json"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$VALIDATOR_LOG"' 'exit 1' \
        > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    export VALIDATOR_LOG
    current_deployment_proves_identity_repair() { return 0; }
    getent() {
        [[ "$1:$2" == passwd:fivegpn ]] \
            && printf 'fivegpn:x:498:499::/nonexistent:/usr/sbin/nologin\n'
    }
    managed_user_uid_is_exclusive() { return 0; }
    managed_primary_gid_is_exclusive_for_user() { return 0; }
    identity_id_is_in_system_range() { return 0; }
    id() { [[ "$1" == -u ]] && printf '498\n'; }
    err() { :; }
    before="$TMP/document.before"
    after="$TMP/document.after"
    snapshot_roots "$before" "$FIVEGPN_STATE_DIR"
    ! validate_existing_runtime_documents >/dev/null 2>&1
    snapshot_roots "$after" "$FIVEGPN_STATE_DIR"
    cmp -s "$before" "$after"
    grep -Fxq "5gpn-state validate --owner-uid 498 $FIVEGPN_STATE_DIR" "$VALIDATOR_LOG"
) || fail "retired runtime document was accepted, mutated, or validated with the wrong owner"
pass "retired runtime document is rejected read-only by the staged Core"

(
    CASE_ROOT="$TMP/journal-document-case"
    FIVEGPN_STATE_DIR="$CASE_ROOT/state"
    ARTIFACT_STAGE="$CASE_ROOT/stage"
    VALIDATOR_LOG="$TMP/journal-document-validator.args"
    REPLACED_FIVEGPN_UID=901
    REPLACED_FIVEGPN_GID=902
    REPLACED_FIVEGPN_NAMED_GID=902
    mkdir -p "$FIVEGPN_STATE_DIR" "$ARTIFACT_STAGE"
    printf '{"version":1}\n' > "$FIVEGPN_STATE_DIR/bot.json"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$VALIDATOR_LOG"' 'exit 0' \
        > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    export VALIDATOR_LOG
    getent() { return 1; }
    journaled_identity_recovery_is_safe() { return 0; }
    err() { :; }
    validate_existing_runtime_documents
    grep -Fxq "5gpn-state validate --owner-uid 901 $FIVEGPN_STATE_DIR" "$VALIDATOR_LOG"
) || fail "journal recovery did not validate state with the recorded owner UID"
pass "account-absent journal recovery passes the recorded UID to the staged Core"

(
    CASE_ROOT="$TMP/group-only-document-case"
    FIVEGPN_STATE_DIR="$CASE_ROOT/state"
    ARTIFACT_STAGE="$CASE_ROOT/stage"
    VALIDATOR_LOG="$TMP/group-only-document-validator.args"
    REPLACED_FIVEGPN_UID=""
    REPLACED_FIVEGPN_GID=902
    REPLACED_FIVEGPN_NAMED_GID=902
    mkdir -p "$FIVEGPN_STATE_DIR" "$ARTIFACT_STAGE"
    printf '{"version":1}\n' > "$FIVEGPN_STATE_DIR/bot.json"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$VALIDATOR_LOG"' 'exit 0' \
        > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    export VALIDATOR_LOG
    getent() { return 1; }
    journaled_identity_recovery_is_safe() { return 0; }
    err() { :; }
    ! validate_existing_runtime_documents >/dev/null 2>&1
    [[ ! -e "$VALIDATOR_LOG" ]]
) || fail "group-only journal attempted to validate user-owned runtime documents"
pass "group-only journal recovery refuses present documents without an owner UID"

(
    FIVEGPN_STATE_DIR="$TMP/missing-document-state"
    ARTIFACT_STAGE="$TMP/missing-document-stage"
    [[ ! -e "$FIVEGPN_STATE_DIR" ]]
    validate_existing_runtime_documents
    [[ ! -e "$FIVEGPN_STATE_DIR" ]]
) || fail "missing runtime documents were created or rejected"
pass "missing runtime documents remain valid non-creating seed inputs"

# Missing state documents are valid fresh-seed inputs, and retired words in
# comments are not deployment evidence.
(
    BASE_DIR="$TMP/current/runtime"
    BIN_DIR="$BASE_DIR/bin"
    CONF_DIR="$TMP/current/config"
    MIHOMO_DIR="$CONF_DIR/mihomo"
    DNS_CERT_DIR="$CONF_DIR/cert"
    INTERCEPT_DIR="$CONF_DIR/intercept"
    FIVEGPN_STATE_DIR="$MIHOMO_DIR/5gpn"
    STATE_DIR="$TMP/current/state"
    INTERCEPT_STATE_DIR="$TMP/current/intercept-state"
    IDENTITY_RECONCILE_FILE="$STATE_DIR/identity-reconcile"
    mkdir -p "$BIN_DIR" "$DNS_CERT_DIR" "$INTERCEPT_DIR" \
        "$FIVEGPN_STATE_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR"
    printf '%s\n' \
        '# RUNTIME-OVERLAY,5gpn and MODULE-INTERCEPT are historical notes only' \
        'proxy-groups:' \
        '  - name: my-intercept-egress-backup' \
        '    type: select' \
        '    proxies: [DIRECT]' \
        '  - name: pre-MODULE-INTERCEPT-backup' \
        '    type: select' \
        '    proxies: [DIRECT]' \
        'rules:' \
        '  - MATCH,DIRECT # intercept-egress is a comment' \
        > "$MIHOMO_DIR/config.yaml"
    fixed_root_is_safe_for_readonly_inspection() { return 0; }
    root_ownership_marker_is_safe() { return 1; }
    unit_definition_exists() { return 1; }
    unit_file_has_5gpn_marker() { return 1; }
    current_managed_unit_file_is_safe() { return 1; }
    getent() { return 1; }
    err() { fail "current fixture was rejected: $*"; }
    detect_legacy_footprints
) || fail "missing current documents or comment-only legacy words were rejected"
pass "missing current documents and comment-only retired words remain valid"

echo "current schema preflight: PASS"
