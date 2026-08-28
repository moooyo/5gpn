#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/5gpn-configure-boundary.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$INSTALL"

configure_fn="$(sed -n '/^configure_installation()/,/^}/p' "$INSTALL")"
configure_preflight_fn="$(sed -n '/^configure_require_current_deployment()/,/^}/p' "$INSTALL")"
configure_cert_fn="$(sed -n '/^configure_apply_certificate_transaction()/,/^[)]$/p' "$INSTALL")"
configure_env_fn="$(sed -n '/^configure_apply_environment_transaction()/,/^[)]$/p' "$INSTALL")"
configure_locked_revalidate_fn="$(sed -n '/^configure_revalidate_locked_publication_inputs()/,/^}/p' "$INSTALL")"
configure_restart_fn="$(sed -n '/^configure_restart_runtime_if_active()/,/^}/p' "$INSTALL")"
configure_gateway_fn="$(sed -n '/^configure_update_existing_dns_gateway()/,/^}/p' "$INSTALL")"
configure_revalidate_fn="$(sed -n '/^configure_revalidate_selected_operator_config()/,/^}/p' "$INSTALL")"
configure_gateway_publication_fn="$(sed -n '/^configure_apply_gateway_publication()/,/^}/p' "$INSTALL")"
configure_quiesce_fn="$(sed -n '/^configure_quiesce_runtime_for_gateway()/,/^}/p' "$INSTALL")"
configure_start_quiesced_fn="$(sed -n '/^configure_start_quiesced_runtime()/,/^}/p' "$INSTALL")"
configure_disarm_fn="$(sed -n '/^configure_disarm_runtime_restore_for_coordinate_commit()/,/^}/p' "$INSTALL")"
configure_release_without_start_fn="$(sed -n '/^configure_release_quiesced_runtime_without_start()/,/^}/p' "$INSTALL")"
configure_validate_runtime_fn="$(sed -n '/^configure_validate_runtime_before_start()/,/^}/p' "$INSTALL")"
configure_main_gate_unit_fn="$(sed -n '/^configure_main_unit_restart_gate_is_current()/,/^}/p' "$INSTALL")"
configure_helpers_fn="$(sed -n '/^configure_preflight_selected_runtime_helpers()/,/^}/p' "$INSTALL")"
collect_cf_fn="$(sed -n '/^configure_collect_pending_cf_token()/,/^}/p' "$INSTALL")"
commit_cf_fn="$(sed -n '/^configure_commit_pending_cf_token()/,/^}/p' "$INSTALL")"
pending_cf_collect_fn="$(sed -n '/^collect_pending_cf_token()/,/^}/p' "$INSTALL")"
pending_cf_publish_fn="$(sed -n '/^publish_pending_cf_token()/,/^}/p' "$INSTALL")"
cf_slot_fn="$(sed -n '/^cf_credential_publication_slot_is_safe()/,/^}/p' "$INSTALL")"
full_cf_collect_fn="$(sed -n '/^full_install_collect_pending_cf_token()/,/^}/p' "$INSTALL")"
full_cf_revalidate_fn="$(sed -n '/^full_install_revalidate_pending_cf_token()/,/^}/p' "$INSTALL")"
full_cf_commit_fn="$(sed -n '/^full_install_commit_pending_cf_token()/,/^}/p' "$INSTALL")"
prepare_profile_fn="$(sed -n '/^prepare_ios_profile()/,/^}/p' "$INSTALL")"
publish_profile_fn="$(sed -n '/^publish_ios_profile()/,/^}/p' "$INSTALL")"
http_certbot_fn="$(sed -n '/^run_http_certbot()/,/^[)]$/p' "$INSTALL")"
deploy_hook_fn="$(sed -n '/^install_cert_deploy_hook()/,/^}/p' "$INSTALL")"
runtime_fence_install_fn="$(sed -n '/^configure_install_runtime_start_fence()/,/^}/p' "$INSTALL")"
runtime_fence_recover_fn="$(sed -n '/^recover_stale_configure_runtime_fence()/,/^}/p' "$INSTALL")"
runtime_gate_enqueue_fn="$(sed -n '/^configure_enqueue_pid1_try_restart()/,/^}/p' "$INSTALL")"
runtime_gate_exact_job_fn="$(sed -n '/^configure_systemd_job_is_exact()/,/^}/p' "$INSTALL")"
runtime_gate_ack_fn="$(sed -n '/^configure_runtime_gate_ack_matches_control_process()/,/^}/p' "$INSTALL")"
runtime_gate_publish_release_fn="$(sed -n '/^configure_publish_runtime_gate_release()/,/^}/p' "$INSTALL")"
runtime_gate_release_fn="$(sed -n '/^configure_start_quiesced_runtime()/,/^}/p' "$INSTALL")"
main_fn="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
manage_action_fn="$(sed -n '/^manage_action()/,/^}/p' "$INSTALL")"
full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
delegate_source_fn="$(sed -n '/^delegate_unpinned_installer()/,/^}/p' "$INSTALL")"
delegate_channel_fn="$(sed -n '/^delegate_pinned_channel_switch()/,/^}/p' "$INSTALL")"

[[ -n "$configure_fn" && -n "$configure_preflight_fn" && -n "$configure_cert_fn" ]] \
    || fail "configure transaction functions are missing"
grep -Fq 'run_management_with_install_lock configure_installation' <<<"$main_fn" \
    && grep -Fq 'run_management_with_install_lock configure_installation' <<<"$manage_action_fn" \
    || fail "CLI and menu configure do not enter through the locked installed-state transaction"
main_source_gate_line="$(grep -nF '[[ "$SCRIPT_DIR" == "$BASE_DIR" ]]' <<<"$main_fn" | cut -d: -f1)"
main_configure_lock_line="$(grep -nF 'run_management_with_install_lock configure_installation' <<<"$main_fn" | cut -d: -f1)"
[[ -n "$main_source_gate_line" && -n "$main_configure_lock_line" \
   && "$main_source_gate_line" -lt "$main_configure_lock_line" ]] \
    || fail "source configure can allocate or wait on the installed transaction lock before rejection"
grep -Fq 'full_install configure' "$INSTALL" \
    && fail "configure still calls the full reinstall pipeline"
grep -Fq 'configure' <<<"$delegate_source_fn$delegate_channel_fn" \
    && fail "release delegation still carries a configure contract"
grep -Eq "''\|configure|configure\)" "$QUICK" \
    && fail "quick-install still accepts configure and can download before configuration"
grep -Fq "Use \`sudo 5gpn configure\`" "$QUICK" \
    || fail "quick-install does not route operators to the installed configure entrypoint"
quick_reject_log="$TMP/quick-configure-reject.log"
if bash "$QUICK" configure >"$quick_reject_log" 2>&1; then
    fail "quick-install executed configure instead of rejecting it before download"
else
    quick_reject_rc=$?
fi
[[ "$quick_reject_rc" == 2 ]] \
    && grep -Fq "Use 'sudo 5gpn configure'" "$quick_reject_log" \
    || fail "quick-install configure rejection is not explicit and pre-download"

for forbidden in \
    delegate_unpinned_installer delegate_pinned_channel_switch install_deps \
    stage_artifacts claim_project_roots claim_ui_dir install_service_accounts \
    install_mihomo install_files install_manage_cli install_units seed_dns_document \
    render_mihomo_config install_ui ensure_swap stop_managed_runtime_units; do
    grep -Fq "$forbidden" <<<"$configure_fn" \
        && fail "configure directly invokes forbidden reinstall step: $forbidden"
done
grep -Fq 'configure_installation' <<<"$full_fn" \
    && fail "full install and installed configure were coupled into one pipeline"
full_confirm_line="$(grep -nF 'resolve_install_configuration 0' <<<"$full_fn" | cut -d: -f1)"
full_config_line="$(grep -nF 'mihomo_config_matches_install_config' <<<"$full_fn" | cut -d: -f1)"
full_token_collect_line="$(grep -nF 'full_install_collect_pending_cf_token' <<<"$full_fn" | cut -d: -f1)"
full_token_revalidate_line="$(grep -nF 'full_install_revalidate_pending_cf_token' <<<"$full_fn" | cut -d: -f1)"
full_publication_line="$(grep -nF 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_fn" | cut -d: -f1)"
full_claim_line="$(grep -nF 'claim_project_roots' <<<"$full_fn" | tail -1 | cut -d: -f1)"
full_token_commit_line="$(grep -nF 'full_install_commit_pending_cf_token' <<<"$full_fn" | cut -d: -f1)"
[[ -n "$full_confirm_line" && -n "$full_config_line" \
   && -n "$full_token_collect_line" && -n "$full_token_revalidate_line" \
   && -n "$full_publication_line" && -n "$full_claim_line" \
   && -n "$full_token_commit_line" \
   && "$full_confirm_line" -lt "$full_token_collect_line" \
   && "$full_config_line" -lt "$full_token_collect_line" \
   && "$full_token_collect_line" -lt "$full_token_revalidate_line" \
   && "$full_token_revalidate_line" -lt "$full_publication_line" \
   && "$full_publication_line" -lt "$full_claim_line" \
   && "$full_claim_line" -lt "$full_token_commit_line" \
   && ! "$full_fn" =~ ensure_cf_token ]] \
    || fail "full install does not keep a confirmed Cloudflare token memory-only until project publication"
grep -Fq 'certificate_selection_state_fingerprint "$BASE_DOMAIN" "$CERT_MODE"' <<<"$full_cf_collect_fn" \
    && grep -Fq 'collect_pending_cf_token' <<<"$full_cf_collect_fn" \
    && ! grep -Fq 'write_cf_credential' <<<"$full_cf_collect_fn$full_cf_revalidate_fn" \
    && grep -Fq 'FULL_INSTALL_CERTIFICATE_SELECTION_STATE' <<<"$full_cf_revalidate_fn" \
    && grep -Fq 'INSTALL_PUBLICATION_STARTED' <<<"$full_cf_commit_fn" \
    && grep -Fq 'INSTALL_LOCK_HELD' <<<"$full_cf_commit_fn" \
    && grep -Fq 'INSTALL_CERT_LOCK_HELD' <<<"$full_cf_commit_fn" \
    && grep -Fq 'full_install_revalidate_pending_cf_token' <<<"$full_cf_commit_fn" \
    && grep -Fq 'publish_pending_cf_token' <<<"$full_cf_commit_fn" \
    || fail "full install does not bind Cloudflare credential publication to its pinned selection and active transaction"
configure_token_line="$(grep -nF 'configure_collect_pending_cf_token' <<<"$configure_fn" | cut -d: -f1)"
configure_final_lock_line="$(grep -nF 'acquire_configure_node_lock' <<<"$configure_fn" | tail -1 | cut -d: -f1)"
configure_final_revalidate_line="$(grep -nF 'configure_revalidate_selected_operator_config' <<<"$configure_fn" | tail -1 | cut -d: -f1)"
configure_cert_line="$(grep -nF 'configure_apply_certificate_transaction' <<<"$configure_fn" | cut -d: -f1)"
[[ -n "$configure_token_line" && -n "$configure_final_lock_line" \
   && -n "$configure_final_revalidate_line" && -n "$configure_cert_line" \
   && "$configure_token_line" -lt "$configure_final_lock_line" \
   && "$configure_final_lock_line" -lt "$configure_final_revalidate_line" \
   && "$configure_final_revalidate_line" -lt "$configure_cert_line" ]] \
    || fail "configure does not revalidate config and dns.env after collecting a pending Cloudflare credential"
grep -Fq 'validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core"' <<<"$configure_preflight_fn" \
    || fail "configure does not validate current documents with the installed Core"
for required in 'config.yaml' 'dns.json' 'installed_mihomo_is_current' 'persisted_dns_env_is_safe'; do
    grep -Fq "$required" <<<"$configure_preflight_fn" \
        || fail "configure current-schema preflight omits $required"
done
pre_recovery_validate_line="$(grep -nF 'configure_validate_operator_config 0' <<<"$configure_preflight_fn" | head -1 | cut -d: -f1)"
recover_fence_line="$(grep -nF 'recover_stale_configure_runtime_fence' <<<"$configure_preflight_fn" | cut -d: -f1)"
post_recovery_validate_line="$(grep -nF 'configure_validate_operator_config 0' <<<"$configure_preflight_fn" | tail -1 | cut -d: -f1)"
[[ -n "$pre_recovery_validate_line" && -n "$recover_fence_line" && -n "$post_recovery_validate_line" \
   && "$pre_recovery_validate_line" -lt "$recover_fence_line" \
   && "$recover_fence_line" -lt "$post_recovery_validate_line" ]] \
    || fail "stale-gate recovery is not bracketed by current deployment validation"
for required in renew-hook.sh cert-renew.sh 5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
    grep -Fq "$required" <<<"$configure_helpers_fn" \
        || fail "certificate configure preflight omits $required"
done
grep -Fq '/proc/self/fd/$source_fd' <<<"$deploy_hook_fn" \
    && grep -Fq 'installed_runtime_script_state "$source_path"' <<<"$deploy_hook_fn" \
    || fail "installed renewal hook publication is not FD-anchored and path-revalidated"
grep -Fq 'configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_RECORD"' <<<"$runtime_fence_install_fn" \
    && grep -Fq 'TryRestartUnit ss "$CONFIGURE_RUNTIME_GATE_UNIT" fail' <<<"$runtime_gate_enqueue_fn" \
    && grep -Fq 'busctl --system --json=short call' <<<"$runtime_gate_enqueue_fn" \
    && grep -Fq 'select(.type == "o")' <<<"$runtime_gate_enqueue_fn" \
    && grep -Fq 'job_id="${job_path##*/}"' <<<"$runtime_gate_enqueue_fn" \
    && grep -Fq 'Manager GetJob' <<<"$runtime_gate_exact_job_fn" \
    && grep -Fq 'org.freedesktop.systemd1.Unit Job' <<<"$runtime_gate_exact_job_fn" \
    && grep -Fq 'org.freedesktop.systemd1.Job JobType' <<<"$runtime_gate_exact_job_fn" \
    && grep -Fq 'org.freedesktop.systemd1.Job State' <<<"$runtime_gate_exact_job_fn" \
    && grep -Fq 'CONFIGURE_MIHOMO_CONTROL_PID' <<<"$runtime_gate_ack_fn" \
    && grep -Fq 'CONFIGURE_RUNTIME_GATE_ACK_PID' <<<"$runtime_gate_ack_fn" \
    && grep -Fq 'InvocationID' <<<"$runtime_gate_ack_fn" \
    && grep -Fq 'CONFIGURE_RUNTIME_GATE_INVOCATION_ID' <<<"$runtime_gate_ack_fn" \
    && grep -Fq 'configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_RELEASE"' <<<"$runtime_gate_publish_release_fn" \
    && grep -Fq 'configure_runtime_gate_ack_matches_control_process' <<<"$runtime_gate_release_fn" \
    && grep -Fq 'configure_runtime_is_stably_active_without_job' <<<"$runtime_fence_recover_fn" \
    && grep -Fq 'configure_runtime_is_confirmed_inactive_success' <<<"$runtime_fence_recover_fn" \
    && ! grep -Eq 'systemctl[[:space:]].*start[[:space:]]+5gpn-mihomo' <<<"$runtime_gate_release_fn$runtime_fence_recover_fn" \
    && ! grep -Eq 'systemctl[[:space:]]+(mask|unmask)' "$INSTALL" \
    || fail "gateway publication is not bound to one exact PID1 job, ACK/ControlPID, and matching release record"
grep -Fq 'CONFIGURE_RUNTIME_GATE_LIVE_UNIT_STATE' <<<"$configure_main_gate_unit_fn" \
    && grep -Fq 'CONFIGURE_RUNTIME_GATE_STAGED_UNIT_STATE' <<<"$configure_main_gate_unit_fn" \
    && grep -Fq 'CONFIGURE_RUNTIME_GATE_HELPER_STATE' <<<"$configure_main_gate_unit_fn" \
    && grep -Fq 'CONFIGURE_RUNTIME_UI_VALIDATOR_STATE' <<<"$configure_main_gate_unit_fn" \
    && grep -Fq 'configure_main_unit_restart_gate_is_current' <<<"$configure_validate_runtime_fn" \
    || fail "gate unit/helper generation is not pinned across publication and release"
grep -Fq 'collect_pending_cf_token' <<<"$collect_cf_fn" \
    && grep -Fq 'PENDING_CF_TOKEN="$tok"' <<<"$pending_cf_collect_fn" \
    && ! grep -Fq 'write_cf_credential' <<<"$pending_cf_collect_fn" \
    && ! grep -Eq 'ensure_acme_dir|install[[:space:]]+-d|mkdir|mv[[:space:]]' <<<"$pending_cf_collect_fn$cf_slot_fn" \
    && grep -Fq 'CONFIGURE_NODE_LOCK_HELD' <<<"$commit_cf_fn" \
    && grep -Fq 'INSTALL_CERT_LOCK_HELD' <<<"$commit_cf_fn" \
    && grep -Fq 'configure_assert_certificate_selection' <<<"$commit_cf_fn" \
    && grep -Fq 'publish_pending_cf_token' <<<"$commit_cf_fn" \
    && grep -Fq 'write_cf_credential "$PENDING_CF_TOKEN"' <<<"$pending_cf_publish_fn" \
    && grep -Fq 'verify_console_dns' <<<"$configure_locked_revalidate_fn" \
    || fail "configure does not defer Cloudflare credential persistence until both locks and final revalidation"
grep -Fq 'prepare_ios_profile' <<<"$configure_cert_fn" \
    && grep -Fq 'publish_ios_profile' <<<"$configure_gateway_publication_fn" \
    && ! grep -Fq 'ui_generation_publish' <<<"$prepare_profile_fn" \
    && grep -Fq 'ui_generation_publish' <<<"$publish_profile_fn" \
    || fail "configure profile generation is not split into prepare and publish phases"
grep -Fq 'FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED=1' <<<"$configure_cert_fn" \
    && ! grep -Fq 'FIVEGPN_HTTP_CERTBOT_RESTORE_ON_SUCCESS' "$INSTALL" \
    && grep -Fq 'externally_quiesced' <<<"$http_certbot_fn" \
    && grep -Fq 'CERT_ROLE_CTL_COMMIT_STATE' "$INSTALL" \
    || fail "HTTP-01 configure can still restore mihomo inside run_http_certbot"
final_quiescent_line="$(grep -nF 'configure_assert_runtime_gate_quiescent' <<<"$configure_gateway_fn" | tail -1 | cut -d: -f1)"
final_fence_line="$(grep -nF 'configure_runtime_start_fence_is_active' <<<"$configure_gateway_fn" | tail -1 | cut -d: -f1)"
gateway_rename_line="$(grep -nF 'mv -Tf -- "$tmp" "$target"' <<<"$configure_gateway_fn" | cut -d: -f1)"
[[ -n "$final_quiescent_line" && -n "$final_fence_line" && -n "$gateway_rename_line" \
   && "$final_quiescent_line" -lt "$gateway_rename_line" \
   && "$final_fence_line" -lt "$gateway_rename_line" ]] \
    || fail "gateway file CAS does not reassert writer quiescence and the PID1 start gate before rename"
pass "configure is an installed-only locked transaction with no reinstall or release path"

(
    CERT_MODE=cloudflare
    TEST_LINEAGE_OWNED=1
    TEST_LINEAGE_ARTIFACTS=1
    TEST_PRESERVED_ROLE=0
    certbot_lineage_owned_by_5gpn() { [[ "$TEST_LINEAGE_OWNED" == 1 ]]; }
    certbot_lineage_artifacts_exist() { [[ "$TEST_LINEAGE_ARTIFACTS" == 1 ]]; }
    cert_provenance_matches() { [[ "$TEST_PRESERVED_ROLE" == 1 ]]; }
    validate_cert_pair() { [[ "$TEST_PRESERVED_ROLE" == 1 ]]; }
    cloudflare_credential_required_for_install example.test \
        || fail "owned Cloudflare lineage did not require its renewal credential"
    TEST_LINEAGE_OWNED=0
    cloudflare_credential_required_for_install example.test \
        && fail "external Cloudflare lineage incorrectly required a 5gpn credential"
    TEST_LINEAGE_ARTIFACTS=0
    cloudflare_credential_required_for_install example.test \
        || fail "absent Cloudflare lineage did not require an issuance credential"
    TEST_PRESERVED_ROLE=1
    cloudflare_credential_required_for_install example.test \
        && fail "preserved role recovery unnecessarily collected a Cloudflare credential"
    TEST_LINEAGE_OWNED=1
    cloudflare_credential_required_for_install example.test \
        && fail "stale ownership with a missing lineage bypassed valid preserved-role recovery"
    CERT_MODE=debug
    cloudflare_credential_required_for_install example.test \
        && fail "debug mode requested a Cloudflare credential"
    true
)
pass "Cloudflare credentials are confirmed pre-publication only for owned or absent lineage state"

# Full installation must not turn a confirmed in-memory token into a live file
# until both locks are held, the certificate selection still matches, and the
# explicit project publication boundary has actually started.
(
    BASE_DOMAIN=example.test
    CERT_MODE=cloudflare
    INSTALL_LOCK_HELD=1
    INSTALL_CERT_LOCK_HELD=1
    INSTALL_PUBLICATION_STARTED=0
    FULL_INSTALL_CERTIFICATE_SELECTION_STATE=stable-selection
    PENDING_CF_TOKEN=confirmed-secret
    TEST_CF_SAVED=0
    token_writes="$TMP/full-install-token-writes"
    : > "$token_writes"
    err() { :; }
    ok() { :; }
    certificate_selection_state_is_consistent_for_install() { return 0; }
    certificate_selection_state_fingerprint() { printf '%s\n' stable-selection; }
    cloudflare_credential_required_for_install() { return 0; }
    cf_credential_publication_slot_is_safe() { return 0; }
    has_valid_cf_credential() { [[ "$TEST_CF_SAVED" == 1 ]]; }
    write_cf_credential() {
        printf '%s\n' "$1" >> "$token_writes"
        TEST_CF_SAVED=1
    }

    full_install_commit_pending_cf_token >/dev/null 2>&1 \
        && fail "full install published the pending Cloudflare credential before publication"
    [[ ! -s "$token_writes" && "$PENDING_CF_TOKEN" == confirmed-secret ]] \
        || fail "pre-publication Cloudflare rejection wrote or discarded the confirmed candidate"

    INSTALL_PUBLICATION_STARTED=1
    full_install_commit_pending_cf_token \
        || fail "full install did not publish the confirmed credential inside the active boundary"
    [[ "$(cat "$token_writes")" == confirmed-secret \
       && -z "$PENDING_CF_TOKEN" && "$TEST_CF_SAVED" == 1 ]] \
        || fail "full-install Cloudflare publication did not atomically consume and verify the pending token"
)
pass "full-install Cloudflare persistence begins only inside the locked publication boundary"

(
    BASE_DOMAIN=example.test
    CERT_MODE=cloudflare
    INSTALL_LOCK_HELD=1
    INSTALL_CERT_LOCK_HELD=1
    INSTALL_PUBLICATION_STARTED=1
    FULL_INSTALL_CERTIFICATE_SELECTION_STATE=stable-selection
    PENDING_CF_TOKEN=confirmed-secret
    token_writes="$TMP/full-install-drift-writes"
    : > "$token_writes"
    err() { :; }
    certificate_selection_state_is_consistent_for_install() { return 0; }
    certificate_selection_state_fingerprint() { printf '%s\n' drifted-selection; }
    cloudflare_credential_required_for_install() { return 0; }
    cf_credential_publication_slot_is_safe() { return 0; }
    has_valid_cf_credential() { return 1; }
    write_cf_credential() { printf '%s\n' "$1" >> "$token_writes"; }

    full_install_commit_pending_cf_token >/dev/null 2>&1 \
        && fail "full install published a token after certificate-selection drift"
    [[ ! -s "$token_writes" && "$PENDING_CF_TOKEN" == confirmed-secret ]] \
        || fail "certificate-selection drift wrote or discarded the pending token"
)
pass "full-install Cloudflare persistence rejects certificate-selection drift"

(
    BASE_DOMAIN=example.test
    CERT_MODE=cloudflare
    INSTALL_LOCK_HELD=1
    INSTALL_CERT_LOCK_HELD=1
    INSTALL_PUBLICATION_STARTED=1
    FULL_INSTALL_CERTIFICATE_SELECTION_STATE=stable-selection
    PENDING_CF_TOKEN=unused-confirmed-secret
    err() { :; }
    certificate_selection_state_is_consistent_for_install() { return 0; }
    certificate_selection_state_fingerprint() { printf '%s\n' stable-selection; }
    cloudflare_credential_required_for_install() { return 0; }
    cf_credential_publication_slot_is_safe() { return 0; }
    has_valid_cf_credential() { return 0; }
    write_cf_credential() { fail "full install rewrote an existing valid Cloudflare credential"; }

    full_install_commit_pending_cf_token \
        || fail "full install rejected a valid saved Cloudflare credential"
    [[ -z "$PENDING_CF_TOKEN" ]] \
        || fail "full install retained an unused in-memory token after reusing the saved credential"
)
pass "full installation reuses an existing valid Cloudflare credential without writing it"

(
    unset -f configure_revalidate_selected_operator_config
    eval "$configure_revalidate_fn"
    err() { :; }
    CONFIGURE_OPERATOR_CONFIG_STATE=pinned
    TEST_CONFIG_STATE=drifted
    configure_validate_operator_config() { CONFIGURE_OPERATOR_CONFIG_STATE="$TEST_CONFIG_STATE"; }
    if configure_revalidate_selected_operator_config; then
        fail "configure adopted a config.yaml replacement made while the TUI was open"
    fi
    [[ "$CONFIGURE_OPERATOR_CONFIG_STATE" == pinned ]] \
        || fail "failed YAML revalidation discarded the original pinned revision"
    TEST_CONFIG_STATE=pinned
    configure_revalidate_selected_operator_config \
        || fail "unchanged config.yaml revision failed selected-coordinate revalidation"
)
pass "operator YAML remains pinned across the complete TUI interaction"

assert_plan() {
    local name="$1" expected="$2"
    shift 2
    configure_plan_changes "$@"
    local actual="${CONFIGURE_ANY_CHANGE}:${CONFIGURE_DNS_GATE_REQUIRED}:${CONFIGURE_GATEWAY_CHANGED}:${CONFIGURE_CERT_CHANGED}:${CONFIGURE_PROFILE_CHANGED}:${CONFIGURE_RESTART_REQUIRED}"
    [[ "$actual" == "$expected" ]] \
        || fail "$name plan mismatch: expected $expected, got $actual"
}

old=(example.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare admin@example.test)
assert_plan "no-op"             0:0:0:0:0:0 "${old[@]}" "${old[@]}"
assert_plan "email only"        1:0:0:0:0:0 "${old[@]}" example.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare ops@example.test
assert_plan "production public" 1:1:0:0:0:0 "${old[@]}" example.test 192.0.2.11 192.0.2.20 192.0.2.20 cloudflare admin@example.test
assert_plan "production gateway" 1:0:1:0:1:1 "${old[@]}" example.test 192.0.2.10 192.0.2.21 192.0.2.20 cloudflare admin@example.test
assert_plan "listener"          1:0:0:0:0:1 "${old[@]}" example.test 192.0.2.10 192.0.2.20 192.0.2.21 cloudflare admin@example.test
assert_plan "base"              1:1:0:1:1:1 "${old[@]}" next.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare admin@example.test
assert_plan "mode"              1:1:0:1:1:1 "${old[@]}" example.test 192.0.2.10 192.0.2.20 192.0.2.20 debug ''
debug_old=(example.test 192.0.2.10 192.0.2.20 192.0.2.20 debug '')
assert_plan "debug public"      1:1:0:1:1:1 "${debug_old[@]}" example.test 192.0.2.11 192.0.2.20 192.0.2.20 debug ''
assert_plan "debug gateway"     1:0:1:1:1:1 "${debug_old[@]}" example.test 192.0.2.10 192.0.2.21 192.0.2.20 debug ''
pass "field differences map to the minimal DNS, certificate, profile, and restart effects"

# Exercise orchestration with all side effects replaced by explicit tripwires.
# The fixture files let the no-op case prove inode, bytes, and timestamps stay
# identical rather than merely observing that a mock writer was not called.
fixture="$TMP/noop-state"
mkdir -p "$fixture"
printf 'dns-env-original\n' > "$fixture/dns.env"
printf 'operator-yaml-original\n' > "$fixture/config.yaml"
printf '{"gateway":"192.0.2.20","policy":{"fallback":"auto"}}\n' > "$fixture/dns.json"
snapshot_files() {
    local file
    for file in "$fixture/dns.env" "$fixture/config.yaml" "$fixture/dns.json"; do
        stat -Lc '%n:%d:%i:%s:%Y:%Z' -- "$file"
        sha256sum "$file"
    done
}

operations="$TMP/operations"
: > "$operations"
check_root() { :; }
activate_verified_installed_gum() { :; }
load_persisted_install_config() {
    BASE_DOMAIN=example.test
    PUBLIC_IP=192.0.2.10
    GATEWAY_IP=192.0.2.20
    MIHOMO_LISTEN_IPS=192.0.2.20
    CERT_MODE=cloudflare
    CERT_EMAIL=admin@example.test
    LOADED_DNS_ENV_SOURCE_STATE=present
    LOADED_DNS_ENV_SOURCE_REVISION=fixture
    LOADED_DNS_ENV_SOURCE_IDENTITY=fixture
}
validate_install_config() { :; }
configure_require_current_deployment() { CONFIGURE_RUNTIME_WAS_ACTIVE="${TEST_RUNTIME_ACTIVE:-1}"; }
configure_install_tui() {
    BASE_DOMAIN="$NEXT_BASE"
    PUBLIC_IP="$NEXT_PUBLIC"
    GATEWAY_IP="$NEXT_GATEWAY"
    MIHOMO_LISTEN_IPS="$NEXT_LISTEN"
    CERT_MODE="$NEXT_MODE"
    CERT_EMAIL="$NEXT_EMAIL"
    CANDIDATE_CONFIRMED=1
}
configure_validate_operator_config() { CONFIGURE_OPERATOR_CONFIG_STATE=fixture; }
configure_revalidate_selected_operator_config() { CONFIGURE_OPERATOR_CONFIG_STATE=fixture; }
configure_assert_operator_config_revision() { :; }
assert_loaded_persisted_dns_env_revision() { :; }
TEST_NODE_LOCK_ACQUIRES=0
acquire_configure_node_lock() {
    CONFIGURE_NODE_LOCK_HELD=1
    TEST_NODE_LOCK_ACQUIRES=$((TEST_NODE_LOCK_ACQUIRES + 1))
}
release_configure_node_lock() { CONFIGURE_NODE_LOCK_HELD=0; }
configure_require_selected_dependencies() { :; }
configure_preflight_selected_runtime_helpers() { [[ "${TEST_HELPER_PREFLIGHT_FAIL:-0}" == 0 ]]; }
configure_capture_certificate_selection() { CONFIGURE_CERTIFICATE_SELECTION_STATE=fixture; }
configure_collect_pending_cf_token() { :; }
configure_assert_runtime_state_before_publication() { :; }
verify_console_dns() { printf 'dns-gate\n' >> "$operations"; }
configure_apply_certificate_transaction() {
    [[ "${CANDIDATE_CONFIRMED:-0}" == 1 ]] || fail "certificate work ran before candidate confirmation"
    printf 'certificate:%s:%s:%s:%s:%s\n' "$1" "$2" "$BASE_DOMAIN" "$PUBLIC_IP" "$GATEWAY_IP" >> "$operations"
    [[ "$3" == 192.0.2.20 ]] || fail "certificate transaction lost the pinned old gateway"
    [[ "$CONFIGURE_GATEWAY_CHANGED" != 1 ]] || printf 'gateway\n' >> "$operations"
    [[ "$CONFIGURE_DNS_ENV_CHANGED" != 1 ]] || printf 'dns-env\n' >> "$operations"
    [[ "$CONFIGURE_RESTART_REQUIRED" != 1 ]] || printf 'restart\n' >> "$operations"
}
write_dns_env() { printf 'dns-env\n' >> "$operations"; }
configure_restart_runtime_if_active() { printf 'restart\n' >> "$operations"; }
configure_apply_environment_transaction() {
    write_dns_env
    [[ "$CONFIGURE_RESTART_REQUIRED" != 1 ]] || configure_restart_runtime_if_active
}
ok() { :; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; }

SCRIPT_DIR="$TMP/source-checkout"
BASE_DIR="$TMP/installed"
RELEASE_CHANNEL_EXPLICIT=0
if configure_installation >/dev/null 2>&1; then
    fail "a source checkout entered installed configure"
fi
[[ ! -s "$operations" ]] || fail "source configure rejection reached a managed side effect"

SCRIPT_DIR="$TMP/installed"
BASE_DIR="$SCRIPT_DIR"

set_candidate() {
    NEXT_BASE="$1"
    NEXT_PUBLIC="$2"
    NEXT_GATEWAY="$3"
    NEXT_LISTEN="$4"
    NEXT_MODE="$5"
    NEXT_EMAIL="$6"
    CANDIDATE_CONFIRMED=0
    TEST_NODE_LOCK_ACQUIRES=0
    : > "$operations"
}

assert_operations() {
    local name="$1" expected="$2" actual
    actual="$(paste -sd '|' "$operations")"
    [[ "$actual" == "$expected" ]] \
        || fail "$name operations mismatch: expected '$expected', got '$actual'"
}

before_snapshot="$(snapshot_files)"
set_candidate "${old[@]}"
configure_installation || fail "no-op configure failed"
after_snapshot="$(snapshot_files)"
[[ "$after_snapshot" == "$before_snapshot" ]] \
    || fail "no-op configure changed file inode, bytes, size, mtime, or ctime"
assert_operations "no-op" ''
[[ "$TEST_NODE_LOCK_ACQUIRES" == 0 ]] \
    || fail "no-op configure created or acquired the node/configure lock"

set_candidate next.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare admin@example.test
TEST_HELPER_PREFLIGHT_FAIL=1
if configure_installation >/dev/null 2>&1; then
    fail "certificate configure ignored a missing/unsafe installed helper preflight"
fi
assert_operations "helper preflight failure" ''
TEST_HELPER_PREFLIGHT_FAIL=0

set_candidate example.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare ops@example.test
configure_installation || fail "email-only configure failed"
assert_operations "email only" 'dns-env'

set_candidate example.test 192.0.2.11 192.0.2.20 192.0.2.20 cloudflare admin@example.test
configure_installation || fail "production public configure failed"
assert_operations "production public" 'dns-gate|dns-env'

set_candidate example.test 192.0.2.10 192.0.2.21 192.0.2.20 cloudflare admin@example.test
configure_installation || fail "production gateway configure failed"
assert_operations "production gateway" 'certificate:0:1:example.test:192.0.2.10:192.0.2.21|gateway|dns-env|restart'

set_candidate example.test 192.0.2.10 192.0.2.20 192.0.2.21 cloudflare admin@example.test
configure_installation || fail "listener configure failed"
assert_operations "listener" 'dns-env|restart'

set_candidate next.test 192.0.2.10 192.0.2.20 192.0.2.20 cloudflare admin@example.test
configure_installation || fail "base configure failed"
assert_operations "base" 'dns-gate|certificate:1:1:next.test:192.0.2.10:192.0.2.20|dns-env|restart'

# Reload the mocked persisted state as debug for its IP-SAN cases.
load_persisted_install_config() {
    BASE_DOMAIN=example.test
    PUBLIC_IP=192.0.2.10
    GATEWAY_IP=192.0.2.20
    MIHOMO_LISTEN_IPS=192.0.2.20
    CERT_MODE=debug
    CERT_EMAIL=''
    LOADED_DNS_ENV_SOURCE_STATE=present
    LOADED_DNS_ENV_SOURCE_REVISION=fixture
    LOADED_DNS_ENV_SOURCE_IDENTITY=fixture
}
set_candidate example.test 192.0.2.11 192.0.2.20 192.0.2.20 debug ''
configure_installation || fail "debug public configure failed"
assert_operations "debug public" 'dns-gate|certificate:1:1:example.test:192.0.2.11:192.0.2.20|dns-env|restart'

set_candidate example.test 192.0.2.10 192.0.2.21 192.0.2.20 debug ''
configure_installation || fail "debug gateway configure failed"
assert_operations "debug gateway" 'certificate:1:1:example.test:192.0.2.10:192.0.2.21|gateway|dns-env|restart'
pass "configure orchestration is no-op safe and applies only field-specific effects after confirmation"

(
    unset -f configure_apply_environment_transaction
    eval "$configure_env_fn"
    environment_failure_log="$TMP/environment-failure.log"
    : > "$environment_failure_log"
    CONFIGURE_RESTART_REQUIRED=1
    acquire_install_cert_lock() {
        INSTALL_CERT_LOCK_HELD=1
        printf 'acquire\n' >> "$environment_failure_log"
    }
    release_install_cert_lock() {
        INSTALL_CERT_LOCK_HELD=0
        printf 'release\n' >> "$environment_failure_log"
    }
    configure_revalidate_locked_publication_inputs() {
        printf 'revalidate:%s\n' "$1" >> "$environment_failure_log"
        [[ "${TEST_LOCKED_REVALIDATE_FAIL:-0}" == 0 ]]
    }
    configure_quiesce_runtime_for_gateway() {
        CONFIGURE_RUNTIME_QUIESCED_BY_US=1
        CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
        CONFIGURE_RUNTIME_FENCED_BY_US=1
        printf 'quiesce\n' >> "$environment_failure_log"
    }
    configure_disarm_runtime_restore_for_coordinate_commit() {
        CONFIGURE_RUNTIME_RESTORE_DISARMED=1
        printf 'disarm\n' >> "$environment_failure_log"
    }
    write_dns_env() {
        DNS_ENV_PUBLICATION_COMMIT_STATE=committed-undurable
        printf 'env-visible\n' >> "$environment_failure_log"
        return 78
    }
    configure_restart_runtime_if_active() { printf 'unexpected-restart\n' >> "$environment_failure_log"; }
    configure_stop_runtime_after_visible_failure() { printf 'stop\n' >> "$environment_failure_log"; }
    err() { :; }
    TEST_LOCKED_REVALIDATE_FAIL=1
    if configure_apply_environment_transaction 192.0.2.20 >/dev/null 2>&1; then
        fail "environment transaction accepted locked-input drift"
    fi
    [[ "$(paste -sd '|' "$environment_failure_log")" == 'acquire|revalidate:192.0.2.20|release' ]] \
        || fail "locked-input drift reached gate creation or dns.env publication"
    : > "$environment_failure_log"
    TEST_LOCKED_REVALIDATE_FAIL=0
    if configure_apply_environment_transaction 192.0.2.20 >/dev/null 2>&1; then
        fail "environment transaction accepted a post-rename dns.env failure"
    fi
    [[ "$(paste -sd '|' "$environment_failure_log")" == 'acquire|revalidate:192.0.2.20|quiesce|disarm|env-visible|stop|release' ]] \
        || fail "visible dns.env failure did not stop Core before any restart"
)
pass "non-profile coordinate publication also stops Core after a visible failure"

(
    locked_revalidate_log="$TMP/environment-locked-revalidate.log"
    : > "$locked_revalidate_log"
    INSTALL_CERT_LOCK_HELD=1
    CONFIGURE_NODE_LOCK_HELD=1
    CONFIGURE_GATEWAY_CHANGED=0
    CONFIGURE_DNS_GATE_REQUIRED=0
    configure_assert_certificate_selection() { fail "non-profile revalidation inspected certificate selection"; }
    configure_revalidate_selected_operator_config() { printf 'config\n' >> "$locked_revalidate_log"; }
    configure_assert_runtime_state_before_publication() { printf 'runtime\n' >> "$locked_revalidate_log"; }
    assert_loaded_persisted_dns_env_revision() { printf 'env\n' >> "$locked_revalidate_log"; }
    validate_existing_runtime_documents() {
        printf 'documents\n' >> "$locked_revalidate_log"
        VALIDATED_DNS_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    }
    err() { :; }
    configure_revalidate_locked_publication_inputs 192.0.2.20 0 \
        || fail "non-profile locked revalidation failed without certificate selection"
    [[ "$(paste -sd '|' "$locked_revalidate_log")" == 'config|runtime|env|documents' ]] \
        || fail "non-profile locked revalidation skipped a current runtime input"
)
pass "non-profile locked revalidation does not invent certificate-selection authority"

# Exercise the real certificate transaction wrapper. The pending token must
# remain memory-only until both locks and the final input recheck, and the
# profile must stay unpublished until coordinate persistence completes.
unset -f configure_apply_certificate_transaction
eval "$configure_cert_fn"
cert_operations="$TMP/cert-operations"
: > "$cert_operations"
UI_GENERATION_CANDIDATE=''
UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
INSTALL_LOCK_HELD=1
CONFIGURE_NODE_LOCK_HELD=1
BASE_DOMAIN=next.test
PUBLIC_IP=192.0.2.31
GATEWAY_IP=192.0.2.41
CERT_MODE=cloudflare
CONFIGURE_GATEWAY_CHANGED=0
CONFIGURE_DNS_ENV_CHANGED=1
CONFIGURE_RESTART_REQUIRED=1
PENDING_CF_TOKEN=pending-secret
acquire_install_cert_lock() { INSTALL_CERT_LOCK_HELD=1; printf 'acquire\n' >> "$cert_operations"; }
configure_revalidate_locked_publication_inputs() {
    [[ "$CONFIGURE_NODE_LOCK_HELD" == 1 && "$INSTALL_CERT_LOCK_HELD" == 1 \
       && "$PENDING_CF_TOKEN" == pending-secret ]] || return 90
    printf 'locked-revalidate\n' >> "$cert_operations"
}
configure_commit_pending_cf_token() {
    [[ "$CONFIGURE_NODE_LOCK_HELD" == 1 && "$INSTALL_CERT_LOCK_HELD" == 1 ]] || return 91
    printf 'token-write\n' >> "$cert_operations"
    PENDING_CF_TOKEN=''
}
preflight_global_certbot_timer_state() { printf 'timer-preflight\n' >> "$cert_operations"; }
configure_quiesce_runtime_for_gateway() {
    CONFIGURE_RUNTIME_QUIESCED_BY_US=1
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
    CONFIGURE_RUNTIME_FENCED_BY_US=1
    printf 'quiesce\n' >> "$cert_operations"
}
configure_disarm_runtime_restore_for_coordinate_commit() {
    [[ "${CONFIGURE_RUNTIME_RESTORE_DISARMED:-0}" == 1 ]] && return 0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=1
    printf 'disarm\n' >> "$cert_operations"
}
install_cert() {
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
    printf 'cert:%s:%s:%s:%s\n' "$1" "$BASE_DOMAIN" "$PUBLIC_IP" "$GATEWAY_IP" >> "$cert_operations"
}
prepare_ios_profile() {
    UI_GENERATION_CANDIDATE="$TMP/prepared-profile"
    printf 'prepare:%s:%s:%s\n' "$BASE_DOMAIN" "$PUBLIC_IP" "$GATEWAY_IP" >> "$cert_operations"
}
configure_revalidate_selected_operator_config() { printf 'config-revision\n' >> "$cert_operations"; }
assert_loaded_persisted_dns_env_revision() { printf 'env-revision\n' >> "$cert_operations"; }
validate_existing_runtime_documents() { printf 'validate-latest\n' >> "$cert_operations"; }
write_dns_env() {
    DNS_ENV_PUBLICATION_COMMIT_STATE=committed
    printf 'write-env\n' >> "$cert_operations"
}
publish_ios_profile() {
    [[ -n "$UI_GENERATION_CANDIDATE" && "$INSTALL_CERT_LOCK_HELD" == 1 ]] || return 93
    UI_GENERATION_CANDIDATE=''
    printf 'publish\n' >> "$cert_operations"
}
load_ui_generation_helper() { :; }
_ui_generation_current_only_is_safe() { printf 'ui-final\n' >> "$cert_operations"; }
configure_start_quiesced_runtime() {
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    printf 'pid1-release\n' >> "$cert_operations"
}
restore_global_certbot_timer() {
    [[ "${KEEP_GLOBAL_CERTBOT_TIMER_DISABLED:-0}" == 1 ]] || return 94
    printf 'restore-owned\n' >> "$cert_operations"
}
release_install_cert_lock() { INSTALL_CERT_LOCK_HELD=0; printf 'release\n' >> "$cert_operations"; }
configure_apply_certificate_transaction 1 1 192.0.2.20 \
    || fail "certificate transaction did not preserve owned timer semantics"
[[ "$(paste -sd '|' "$cert_operations")" == \
   'acquire|locked-revalidate|timer-preflight|token-write|quiesce|disarm|cert:next.test:next.test:192.0.2.31:192.0.2.41|prepare:next.test:192.0.2.31:192.0.2.41|config-revision|env-revision|validate-latest|write-env|publish|config-revision|env-revision|validate-latest|ui-final|pid1-release|restore-owned|release' ]] \
    || fail "locked token/certificate/profile transaction order or candidate binding drifted"
pass "pending Cloudflare token and profile publication obey the locked final boundary"

# A pre-quiesced HTTP-01 helper must not issue a stop or start of its own.
unset -f run_http_certbot
eval "$http_certbot_fn"
http_operations="$TMP/http-operations"
: > "$http_operations"
FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED=1
configure_assert_runtime_gate_quiescent() { printf 'gate-quiescent\n' >> "$http_operations"; }
certbot() { printf 'certbot\n' >> "$http_operations"; }
systemctl() { printf 'systemctl:%s\n' "$*" >> "$http_operations"; return 95; }
run_http_certbot certonly --standalone \
    || fail "pre-quiesced HTTP-01 helper failed"
[[ "$(paste -sd '|' "$http_operations")" == 'gate-quiescent|certbot' ]] \
    || fail "HTTP-01 helper touched systemd or skipped its owned-gate proof"
unset FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED
pass "HTTP-01 configure leaves all runtime restoration to the outer PID1 gate transaction"

(
    unset -f configure_apply_certificate_transaction
    eval "$configure_cert_fn"
    partial_cert_log="$TMP/partial-cert.log"
    : > "$partial_cert_log"
    CONFIGURE_NODE_LOCK_HELD=1
    CONFIGURE_GATEWAY_CHANGED=0
    CONFIGURE_DNS_ENV_CHANGED=1
    CONFIGURE_RESTART_REQUIRED=1
    CERT_MODE=http-01
    PENDING_CF_TOKEN=''
    UI_GENERATION_CANDIDATE=''
    acquire_install_cert_lock() { INSTALL_CERT_LOCK_HELD=1; printf 'acquire\n' >> "$partial_cert_log"; }
    configure_revalidate_locked_publication_inputs() { printf 'locked-revalidate\n' >> "$partial_cert_log"; }
    preflight_global_certbot_timer_state() { printf 'timer-preflight\n' >> "$partial_cert_log"; }
    configure_quiesce_runtime_for_gateway() {
        CONFIGURE_RUNTIME_QUIESCED_BY_US=1
        CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
        CONFIGURE_RUNTIME_FENCED_BY_US=1
        printf 'quiesce\n' >> "$partial_cert_log"
    }
    configure_disarm_runtime_restore_for_coordinate_commit() {
        CONFIGURE_RUNTIME_RESTORE_DISARMED=1
        printf 'disarm\n' >> "$partial_cert_log"
    }
    install_cert() {
        [[ "${FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED:-0}" == 1 ]] || return 79
        CERT_ROLE_CTL_COMMIT_STATE=committed
        printf 'role-commit\n' >> "$partial_cert_log"
        return 80
    }
    configure_stop_runtime_after_visible_failure() {
        CONFIGURE_RUNTIME_QUIESCED_BY_US=0
        CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
        CONFIGURE_RUNTIME_FENCED_BY_US=0
        printf 'stop-no-start\n' >> "$partial_cert_log"
    }
    configure_start_quiesced_runtime() { printf 'unexpected-start\n' >> "$partial_cert_log"; return 1; }
    restore_global_certbot_timer() { printf 'restore-timer\n' >> "$partial_cert_log"; }
    release_install_cert_lock() { INSTALL_CERT_LOCK_HELD=0; printf 'release\n' >> "$partial_cert_log"; }
    err() { :; }
    if configure_apply_certificate_transaction 1 1 192.0.2.20 >/dev/null 2>&1; then
        fail "HTTP-01 transaction accepted failure after certificate-role commit"
    fi
    [[ "$(paste -sd '|' "$partial_cert_log")" == \
       'acquire|locked-revalidate|timer-preflight|quiesce|disarm|role-commit|stop-no-start|restore-timer|release' ]] \
        || fail "partial certificate-role publication restarted Core or skipped fail-closed cleanup"
)
pass "visible certificate-role failure leaves HTTP-01 Core stopped"

(
    unset -f configure_release_quiesced_runtime_without_start
    eval "$configure_release_without_start_fn"
    retained_gate_log="$TMP/retained-gate.log"
    : > "$retained_gate_log"
    CONFIGURE_RUNTIME_QUIESCED_BY_US=1
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
    CONFIGURE_RUNTIME_FENCED_BY_US=1
    CONFIGURE_RUNTIME_RESTORE_DISARMED=1
    configure_update_runtime_fence_restore_entitlement() {
        printf 'entitlement:%s\n' "$1" >> "$retained_gate_log"
    }
    configure_release_runtime_start_fence() {
        printf 'inactive-close-failed:%s\n' "${1:-0}" >> "$retained_gate_log"
        return 73
    }
    err() { :; }
    if configure_release_quiesced_runtime_without_start >/dev/null 2>&1; then
        fail "failed inactive proof was accepted while a PID1 job could still start"
    fi
    [[ "$(paste -sd '|' "$retained_gate_log")" == 'entitlement:0|inactive-close-failed:1' \
       && "$CONFIGURE_RUNTIME_QUIESCED_BY_US" == 1 \
       && "$CONFIGURE_RUNTIME_FENCE_ATTEMPTED" == 1 \
       && "$CONFIGURE_RUNTIME_FENCED_BY_US" == 1 ]] \
        || fail "failed inactive proof removed or disowned the retained PID1 gate"
)
pass "failed inactive proof retains the PID1 gate instead of allowing a late start"

# The restart boundary never starts an initially inactive unit. If an active
# unit is stopped while the TUI is open, that newer operator stop also wins.
unset -f configure_restart_runtime_if_active
eval "$configure_restart_fn"
restart_operations="$TMP/restart-operations"
: > "$restart_operations"
load_ui_generation_helper() { :; }
_ui_generation_current_only_is_safe() { :; }
wait_service_ready() { printf 'ready\n' >> "$restart_operations"; }
systemctl() { printf 'systemctl:%s\n' "$*" >> "$restart_operations"; }
configure_runtime_is_stably_active_without_job() { [[ "${TEST_LIVE_STATE:-}" == active ]]; }
configure_runtime_is_confirmed_inactive_success() { [[ "${TEST_LIVE_STATE:-}" == inactive ]]; }
read_exact_systemd_unit_state() {
    SYSTEMD_UNIT_LOAD_STATE=loaded
    SYSTEMD_UNIT_FILE_STATE=enabled
    SYSTEMD_UNIT_ACTIVE_STATE="${TEST_LIVE_STATE:-active}"
}

CONFIGURE_RUNTIME_WAS_ACTIVE=0
TEST_LIVE_STATE=inactive
configure_restart_runtime_if_active || fail "inactive runtime preservation failed"
[[ ! -s "$restart_operations" ]] || fail "configure started or restarted an initially inactive runtime"

CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_LIVE_STATE=inactive
configure_restart_runtime_if_active || fail "newer operator stop preservation failed"
[[ "$(paste -sd '|' "$restart_operations")" == \
   'systemctl:--job-mode=fail try-restart 5gpn-mihomo.service' ]] \
    || fail "try-restart did not preserve a stop that won before its systemd job"

: > "$restart_operations"
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_LIVE_STATE=active
configure_restart_runtime_if_active || fail "active runtime restart failed"
[[ "$(paste -sd '|' "$restart_operations")" == \
   'systemctl:--job-mode=fail try-restart 5gpn-mihomo.service|ready' ]] \
    || fail "active configure restart touched unexpected units or skipped readiness"

preflight_current_managed_unit_definition() { :; }
systemd_unit_has_dropins() { return 1; }
TEST_LIVE_STATE=failed
if configure_capture_runtime_state >/dev/null 2>&1; then
    fail "failed mihomo was misclassified as a deliberate operator stop"
fi
pass "only a stably active runtime is restarted; inactive and failed states stay distinct"

# Gateway changes consume an already prepared profile under the certificate
# lock, then hold one PID1-owned TryRestartUnit job in ExecStartPre, commit
# dns.json and dns.env, publish current, and release that same job. Failures
# before the CAS may release the original job; failures after any visible
# commit cancel it and leave the runtime inactive.
unset -f configure_apply_gateway_publication configure_quiesce_runtime_for_gateway \
    configure_start_quiesced_runtime configure_disarm_runtime_restore_for_coordinate_commit
eval "$configure_gateway_publication_fn"
eval "$configure_quiesce_fn"
eval "$configure_start_quiesced_fn"
eval "$configure_disarm_fn"

gateway_boundary_log="$TMP/gateway-boundary.log"
gateway_boundary_root="$TMP/gateway-boundary-state"
mkdir -p "$gateway_boundary_root"
gateway_boundary_state="$gateway_boundary_root/dns.json"
printf '{"gateway":"192.0.2.20"}\n' > "$gateway_boundary_state"
FIVEGPN_STATE_DIR="$gateway_boundary_root"
MIHOMO_BIN=/bin/true
GATEWAY_IP=192.0.2.21
INSTALL_CERT_LOCK_HELD=1
CONFIGURE_NODE_LOCK_HELD=0
CONFIGURE_OPERATOR_CONFIG_STATE=fixture
LOADED_DNS_ENV_SOURCE_STATE=present
LOADED_DNS_ENV_SOURCE_REVISION=fixture
LOADED_DNS_ENV_SOURCE_IDENTITY=fixture
TEST_BOUNDARY_STATE=inactive
TEST_BOUNDARY_SUB_STATE=dead
TEST_UNIT_FILE_STATE=enabled
TEST_CONTROL_PID=0
TEST_GATE_INSTALL_FAIL=0
TEST_ENQUEUE_FAIL=0
TEST_ENQUEUE_OPERATOR_STOP=0
TEST_JOB_PRESENT=0
TEST_ACK_PRESENT=0
TEST_RELEASE_PUBLISHED=0
TEST_QUIESCE_FAIL=0
TEST_DNS_FAIL_STAGE=none
TEST_PROFILE_FAIL_STAGE=none
TEST_ENTITLEMENT=0
TEST_READY_FAIL=0
TEST_OPERATOR_STOP_BEFORE_RELEASE=0
TEST_OPERATOR_STOP_AFTER_RELEASE=0
read_exact_systemd_unit_state() {
    SYSTEMD_UNIT_LOAD_STATE=loaded
    SYSTEMD_UNIT_FILE_STATE=enabled
    SYSTEMD_UNIT_ACTIVE_STATE="$TEST_BOUNDARY_STATE"
}
configure_read_mihomo_runtime_state() {
    CONFIGURE_MIHOMO_ACTIVE_STATE="$TEST_BOUNDARY_STATE"
    CONFIGURE_MIHOMO_SUB_STATE="$TEST_BOUNDARY_SUB_STATE"
    CONFIGURE_MIHOMO_UNIT_FILE_STATE="$TEST_UNIT_FILE_STATE"
    CONFIGURE_MIHOMO_CONTROL_PID="$TEST_CONTROL_PID"
}
systemctl() {
    printf 'unexpected-systemctl:%s\n' "$*" >> "$gateway_boundary_log"
    return 98
}
configure_main_unit_restart_gate_is_current() {
    printf 'gate-current\n' >> "$gateway_boundary_log"
}
configure_install_runtime_start_fence() {
    printf 'gate-install\n' >> "$gateway_boundary_log"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
    if [[ "$TEST_GATE_INSTALL_FAIL" == 1 ]]; then
        return 63
    fi
}
configure_enqueue_pid1_try_restart() {
    printf 'pid1-try-restart\n' >> "$gateway_boundary_log"
    if [[ "$TEST_ENQUEUE_FAIL" == 1 ]]; then
        if [[ "$TEST_ENQUEUE_OPERATOR_STOP" == 1 ]]; then
            TEST_BOUNDARY_STATE=inactive
            TEST_BOUNDARY_SUB_STATE=dead
            TEST_CONTROL_PID=0
        fi
        return 64
    fi
    TEST_JOB_PRESENT=1
    TEST_ACK_PRESENT=1
    TEST_BOUNDARY_STATE=activating
    TEST_BOUNDARY_SUB_STATE=start-pre
    TEST_CONTROL_PID=4242
    CONFIGURE_RUNTIME_QUIESCED_BY_US=1
    TEST_ENTITLEMENT=1
    printf 'entitlement:1\n' >> "$gateway_boundary_log"
}
configure_wait_for_runtime_inactive_behind_gate() {
    printf 'wait-inactive\n' >> "$gateway_boundary_log"
    [[ "$TEST_BOUNDARY_STATE" == inactive ]]
}
configure_systemd_job_is_exact() {
    [[ "$TEST_JOB_PRESENT" == 1 ]]
}
configure_unit_has_no_job() {
    [[ "$TEST_JOB_PRESENT" == 0 ]]
}
configure_runtime_is_stably_active_without_job() {
    [[ "$TEST_BOUNDARY_STATE" == active \
       && "$TEST_BOUNDARY_SUB_STATE" == running \
       && "$TEST_CONTROL_PID" == 0 \
       && "$TEST_JOB_PRESENT" == 0 ]]
}
configure_runtime_is_confirmed_inactive_success() {
    [[ "$TEST_BOUNDARY_STATE" == inactive \
       && "$TEST_BOUNDARY_SUB_STATE" == dead \
       && "$TEST_CONTROL_PID" == 0 \
       && "$TEST_JOB_PRESENT" == 0 ]]
}
configure_runtime_gate_ack_matches_control_process() {
    [[ "$TEST_JOB_PRESENT" == 1 \
       && "$TEST_ACK_PRESENT" == 1 \
       && "$TEST_BOUNDARY_STATE" == activating \
       && "$TEST_BOUNDARY_SUB_STATE" == start-pre \
       && "$TEST_CONTROL_PID" == 4242 ]]
}
configure_wait_for_pid1_restart_gate() {
    printf 'gate-ack\n' >> "$gateway_boundary_log"
    if configure_runtime_gate_ack_matches_control_process; then
        CONFIGURE_RUNTIME_FENCED_BY_US=1
        return 0
    fi
    if [[ "$TEST_BOUNDARY_STATE" == inactive ]]; then
        configure_update_runtime_fence_restore_entitlement 0 || return 1
        CONFIGURE_RUNTIME_WAS_ACTIVE=0
        CONFIGURE_RUNTIME_QUIESCED_BY_US=0
        return 2
    fi
    return 1
}
configure_update_runtime_fence_restore_entitlement() {
    if [[ "$TEST_ENTITLEMENT" != "$1" ]]; then
        printf 'entitlement:%s\n' "$1" >> "$gateway_boundary_log"
        TEST_ENTITLEMENT="$1"
    fi
}
configure_release_runtime_start_fence() {
    printf 'gate-cleanup\n' >> "$gateway_boundary_log"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    TEST_JOB_PRESENT=0
    TEST_ACK_PRESENT=0
    TEST_RELEASE_PUBLISHED=0
}
configure_runtime_start_fence_is_active() {
    [[ "$TEST_RELEASE_PUBLISHED" == 0 ]] || return 1
    case "$TEST_BOUNDARY_STATE:$TEST_BOUNDARY_SUB_STATE" in
        inactive:dead|inactive:*) return 0 ;;
        activating:start-pre) configure_runtime_gate_ack_matches_control_process ;;
        *) return 1 ;;
    esac
}
configure_assert_runtime_gate_quiescent() {
    printf 'gate-quiescent\n' >> "$gateway_boundary_log"
    configure_runtime_start_fence_is_active || return 1
    wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER"
}
wait_managed_account_quiescent() {
    printf 'wait-account\n' >> "$gateway_boundary_log"
    [[ "$TEST_QUIESCE_FAIL" == 0 ]]
}
configure_publish_runtime_gate_release() {
    configure_runtime_gate_ack_matches_control_process || return 1
    printf 'release-file\n' >> "$gateway_boundary_log"
    TEST_RELEASE_PUBLISHED=1
    TEST_JOB_PRESENT=0
    TEST_ACK_PRESENT=0
    TEST_CONTROL_PID=0
    if [[ "$TEST_OPERATOR_STOP_AFTER_RELEASE" == 1 ]]; then
        TEST_BOUNDARY_STATE=inactive
        TEST_BOUNDARY_SUB_STATE=dead
        printf 'operator-stop\n' >> "$gateway_boundary_log"
    else
        TEST_BOUNDARY_STATE=active
        TEST_BOUNDARY_SUB_STATE=running
    fi
}
configure_force_runtime_inactive_for_gate() {
    printf 'force-inactive\n' >> "$gateway_boundary_log"
    TEST_BOUNDARY_STATE=inactive
    TEST_BOUNDARY_SUB_STATE=dead
    TEST_CONTROL_PID=0
    TEST_JOB_PRESENT=0
    TEST_ACK_PRESENT=0
}
configure_assert_operator_config_revision() { printf 'config-revision\n' >> "$gateway_boundary_log"; }
assert_loaded_persisted_dns_env_revision() { printf 'env-revision\n' >> "$gateway_boundary_log"; }
validate_existing_runtime_documents() {
    printf 'validate-latest\n' >> "$gateway_boundary_log"
    VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$gateway_boundary_state" | awk '{print $1}')"
}
configure_update_existing_dns_gateway() {
    printf 'publish-dns\n' >> "$gateway_boundary_log"
    configure_runtime_start_fence_is_active || return 62
    [[ "$TEST_DNS_FAIL_STAGE" != pre ]] || return 64
    configure_disarm_runtime_restore_for_coordinate_commit || return 1
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=committed-undurable
    printf '{"gateway":"%s"}\n' "$GATEWAY_IP" > "$gateway_boundary_state"
    [[ "$TEST_DNS_FAIL_STAGE" != post ]] || return 65
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=committed
}
write_dns_env() {
    printf 'write-env\n' >> "$gateway_boundary_log"
    DNS_ENV_PUBLICATION_COMMIT_STATE=committed
}
publish_ios_profile() {
    printf 'publish-profile\n' >> "$gateway_boundary_log"
    if [[ "$TEST_PROFILE_FAIL_STAGE" == pre ]]; then
        return 66
    fi
    TEST_PROFILE_CURRENT=new
    UI_GENERATION_CANDIDATE=''
    if [[ "$TEST_PROFILE_FAIL_STAGE" == committed ]]; then
        UI_GENERATION_COMMIT_STATE=committed-undurable
        return 67
    fi
}
load_ui_generation_helper() { :; }
_ui_generation_current_only_is_safe() {
    printf 'ui-final\n' >> "$gateway_boundary_log"
    if [[ "$TEST_OPERATOR_STOP_BEFORE_RELEASE" == 1 ]]; then
        TEST_JOB_PRESENT=0
        TEST_ACK_PRESENT=0
        TEST_BOUNDARY_STATE=inactive
        TEST_BOUNDARY_SUB_STATE=dead
        TEST_CONTROL_PID=0
        printf 'operator-stop\n' >> "$gateway_boundary_log"
    fi
}
configure_validate_runtime_before_start() { :; }
wait_service_ready() {
    printf 'ready\n' >> "$gateway_boundary_log"
    [[ "$TEST_READY_FAIL" == 0 && "$TEST_BOUNDARY_STATE" == active ]]
}
warn() { :; }
info() { :; }
err() { printf '%s\n' "$*" >&2; }

run_gateway_publication_case() {
    local rc=0
    configure_apply_gateway_publication 192.0.2.20 || rc=$?
    if [[ "$rc" != 0 \
       && ( "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 \
            || "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
            || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ) ]]; then
        if configure_visible_coordinate_was_committed; then
            configure_release_quiesced_runtime_without_start || true
        else
            configure_start_quiesced_runtime || true
        fi
    fi
    return "$rc"
}

reset_gateway_publication_case() {
    printf '{"gateway":"192.0.2.20"}\n' > "$gateway_boundary_state"
    UI_GENERATION_CANDIDATE="$TMP/prepared-gateway-profile"
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=not-committed
    DNS_ENV_PUBLICATION_COMMIT_STATE=not-committed
    CONFIGURE_CERT_PUBLICATION_COMPLETED=0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
    TEST_ENTITLEMENT=0
    TEST_PROFILE_CURRENT=old
    TEST_READY_FAIL=0
    TEST_BOUNDARY_SUB_STATE=dead
    TEST_CONTROL_PID=0
    TEST_JOB_PRESENT=0
    TEST_ACK_PRESENT=0
    TEST_RELEASE_PUBLISHED=0
    TEST_GATE_INSTALL_FAIL=0
    TEST_ENQUEUE_FAIL=0
    TEST_ENQUEUE_OPERATOR_STOP=0
    TEST_OPERATOR_STOP_BEFORE_RELEASE=0
    TEST_OPERATOR_STOP_AFTER_RELEASE=0
}

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
run_gateway_publication_case \
    || fail "active gateway publication failed"
active_gateway_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$active_gateway_order" == \
   'gate-current|gate-install|pid1-try-restart|entitlement:1|gate-ack|gate-quiescent|wait-account|config-revision|env-revision|validate-latest|publish-dns|entitlement:0|write-env|publish-profile|env-revision|validate-latest|ui-final|release-file|ready|gate-cleanup' ]] \
    || fail "active gateway publication did not preserve prepare/CAS/publish/PID1-release order: $active_gateway_order"

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_READY_FAIL=1
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted a failed post-start readiness check"
fi
readiness_failure_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$readiness_failure_order" == *'release-file|ready|force-inactive|gate-cleanup' \
   && "$TEST_BOUNDARY_STATE" == inactive ]] \
    || fail "released PID1 job readiness failure did not leave Core inactive: $readiness_failure_order"
TEST_READY_FAIL=0

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_OPERATOR_STOP_BEFORE_RELEASE=1
run_gateway_publication_case \
    || fail "operator stop before PID1 gate release failed"
operator_stop_before_release_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$operator_stop_before_release_order" == *'ui-final|operator-stop|gate-cleanup' \
   && "$operator_stop_before_release_order" != *'release-file'* \
   && "$operator_stop_before_release_order" != *'ready'* \
   && "$TEST_BOUNDARY_STATE" == inactive ]] \
    || fail "operator stop did not cancel the original job and remain stopped: $operator_stop_before_release_order"

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_OPERATOR_STOP_AFTER_RELEASE=1
run_gateway_publication_case \
    || fail "operator stop after PID1 gate release failed"
operator_stop_after_release_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$operator_stop_after_release_order" == *'release-file|operator-stop|ready|gate-cleanup' \
   && "$operator_stop_after_release_order" != *'force-inactive'* \
   && "$TEST_BOUNDARY_STATE" == inactive ]] \
    || fail "operator stop after release was not preserved: $operator_stop_after_release_order"

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=inactive
TEST_UNIT_FILE_STATE=enabled
run_gateway_publication_case \
    || fail "externally stopped gateway publication failed"
external_stop_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$external_stop_order" == \
   'gate-current|gate-install|gate-quiescent|wait-account|config-revision|env-revision|validate-latest|publish-dns|write-env|publish-profile|env-revision|validate-latest|ui-final|gate-cleanup' ]] \
    || fail "external operator stop was not preserved: $external_stop_order"

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=0
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted an external start after an inactive snapshot"
fi
[[ "$(paste -sd '|' "$gateway_boundary_log")" == 'gate-current' ]] \
    || fail "external-start rejection installed a gate or performed a coordinate write"

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
TEST_GATE_INSTALL_FAIL=1
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted an ambiguous PID1 gate installation failure"
fi
[[ "$(paste -sd '|' "$gateway_boundary_log")" == \
   'gate-current|gate-install|gate-cleanup' ]] \
    || fail "ambiguous gate installation failure wrote coordinates or left transaction state"
TEST_GATE_INSTALL_FAIL=0

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
TEST_DNS_FAIL_STAGE=pre
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted a simulated DNS write failure"
fi
failure_restore_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$failure_restore_order" == \
   'gate-current|gate-install|pid1-try-restart|entitlement:1|gate-ack|gate-quiescent|wait-account|config-revision|env-revision|validate-latest|publish-dns|entitlement:0|release-file|ready|gate-cleanup' ]] \
    || fail "pre-CAS failure did not release the original PID1 restart job: $failure_restore_order"
TEST_DNS_FAIL_STAGE=none

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
TEST_ENQUEUE_FAIL=1
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted a failed TryRestartUnit enqueue while Core stayed active"
fi
[[ "$(paste -sd '|' "$gateway_boundary_log")" == \
   'gate-current|gate-install|pid1-try-restart|wait-inactive|gate-cleanup' ]] \
    || fail "failed PID1 enqueue reached a coordinate writer or attempted a separate start"
TEST_ENQUEUE_FAIL=0

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_ENQUEUE_FAIL=1
TEST_ENQUEUE_OPERATOR_STOP=1
run_gateway_publication_case \
    || fail "operator stop winning the TryRestartUnit enqueue race failed"
enqueue_stop_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$enqueue_stop_order" == \
   'gate-current|gate-install|pid1-try-restart|wait-inactive|gate-quiescent|wait-account|config-revision|env-revision|validate-latest|publish-dns|write-env|publish-profile|env-revision|validate-latest|ui-final|gate-cleanup' \
   && "$TEST_BOUNDARY_STATE" == inactive ]] \
    || fail "operator stop at enqueue did not remain stopped through publication: $enqueue_stop_order"
TEST_ENQUEUE_FAIL=0
TEST_ENQUEUE_OPERATOR_STOP=0

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
CONFIGURE_RUNTIME_UNIT_FILE_STATE=enabled
TEST_BOUNDARY_STATE=active
TEST_UNIT_FILE_STATE=enabled
TEST_QUIESCE_FAIL=1
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted surviving fivegpn processes"
fi
quiesce_restore_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$quiesce_restore_order" == \
   'gate-current|gate-install|pid1-try-restart|entitlement:1|gate-ack|gate-quiescent|wait-account|entitlement:0|release-file|ready|gate-cleanup' ]] \
    || fail "process-quiescence failure wrote state or failed to release the PID1 job: $quiesce_restore_order"
TEST_QUIESCE_FAIL=0

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_DNS_FAIL_STAGE=post
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted a post-rename DNS durability failure"
fi
post_cas_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$post_cas_order" == *'publish-dns|entitlement:0|gate-cleanup' \
   && "$post_cas_order" != *'publish-profile'* \
   && "$post_cas_order" != *'release-file'* \
   && "$post_cas_order" != *'ready'* ]] \
    || fail "post-CAS DNS failure published the profile or restarted mihomo: $post_cas_order"
TEST_DNS_FAIL_STAGE=none

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_PROFILE_FAIL_STAGE=pre
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted a pre-commit profile publication failure"
fi
profile_fail_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$TEST_PROFILE_CURRENT" == old \
   && "$profile_fail_order" == *'write-env|publish-profile|gate-cleanup' \
   && "$profile_fail_order" != *'release-file'* \
   && "$profile_fail_order" != *'ready'* ]] \
    || fail "profile pre-commit failure changed current or restarted mihomo: $profile_fail_order"
TEST_PROFILE_FAIL_STAGE=none

: > "$gateway_boundary_log"
reset_gateway_publication_case
CONFIGURE_RUNTIME_WAS_ACTIVE=1
TEST_BOUNDARY_STATE=active
TEST_PROFILE_FAIL_STAGE=committed
if run_gateway_publication_case >/dev/null 2>&1; then
    fail "gateway publication accepted an undurable committed profile switch"
fi
profile_committed_order="$(paste -sd '|' "$gateway_boundary_log")"
[[ "$TEST_PROFILE_CURRENT" == new \
   && "$profile_committed_order" == *'write-env|publish-profile|gate-cleanup' \
   && "$profile_committed_order" != *'release-file'* \
   && "$profile_committed_order" != *'ready'* ]] \
    || fail "committed-undurable profile failure restarted or rolled back current: $profile_committed_order"
TEST_PROFILE_FAIL_STAGE=none
pass "gateway publication releases only its PID1 job before CAS and preserves operator stops or visible-failure inactivity"

# Current-schema preflight refuses every required missing artifact instead of
# turning configure into a repair or seed path.
(
    unset -f configure_require_current_deployment
    eval "$configure_preflight_fn"
    fixture_current="$TMP/current-required"
    CONF_DIR="$fixture_current/etc"
    MIHOMO_DIR="$CONF_DIR/mihomo"
    FIVEGPN_STATE_DIR="$MIHOMO_DIR/5gpn"
    BASE_DIR="$fixture_current/opt"
    BIN_DIR="$BASE_DIR/bin"
    MIHOMO_BIN="$BIN_DIR/5gpn-mihomo"
    mkdir -p "$FIVEGPN_STATE_DIR" "$BIN_DIR"
    printf 'env\n' > "$CONF_DIR/dns.env"
    printf 'yaml\n' > "$MIHOMO_DIR/config.yaml"
    printf '{"gateway":"192.0.2.20"}\n' > "$FIVEGPN_STATE_DIR/dns.json"
    printf 'core\n' > "$MIHOMO_BIN"
    chmod 0755 "$MIHOMO_BIN"

    fixed_owned_dir_is_safe() { :; }
    stat() {
        case "$*" in
            *dns.env*) printf '0:0:600:1\n' ;;
            *) printf '0:0:755\n' ;;
        esac
    }
    persisted_dns_env_is_safe() { [[ -f "$CONF_DIR/dns.env" ]]; }
    getent() { :; }
    managed_user_uid_is_exclusive() { :; }
    managed_primary_gid_is_exclusive_for_user() { :; }
    shared_runtime_directory_metadata_is_safe() { :; }
    account_uid() { printf '100\n'; }
    account_gid() { printf '100\n'; }
    file_uid() { printf '100\n'; }
    file_gid() { printf '100\n'; }
    file_mode() { printf '711\n'; }
    runtime_tree_has_only_plain_entries() { :; }
    installed_mihomo_is_current() { [[ -f "$MIHOMO_BIN" ]]; }
    recover_stale_configure_runtime_fence() { :; }
    configure_capture_runtime_state() { CONFIGURE_RUNTIME_WAS_ACTIVE=0; }
    configure_validate_operator_config() { CONFIGURE_OPERATOR_CONFIG_STATE=fixture; }
    validate_existing_runtime_documents() {
        VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$FIVEGPN_STATE_DIR/dns.json" | awk '{print $1}')"
    }
    err() { :; }

    configure_require_current_deployment 192.0.2.20 \
        || fail "complete current configure fixture was rejected"
    for required in "$CONF_DIR/dns.env" "$MIHOMO_DIR/config.yaml" "$FIVEGPN_STATE_DIR/dns.json" "$MIHOMO_BIN"; do
        backup="${required}.required-test"
        mv -- "$required" "$backup"
        if configure_require_current_deployment 192.0.2.20 >/dev/null 2>&1; then
            fail "configure accepted missing required artifact: $required"
        fi
        mv -- "$backup" "$required"
    done

    recovery_log="$fixture_current/recovery.log"
    : > "$recovery_log"
    recover_stale_configure_runtime_fence() {
        CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=1
    }
    configure_capture_runtime_state() { CONFIGURE_RUNTIME_WAS_ACTIVE=1; }
    TEST_RECOVERY_VALIDATE_CALLS=0
    configure_validate_operator_config() {
        TEST_RECOVERY_VALIDATE_CALLS=$((TEST_RECOVERY_VALIDATE_CALLS + 1))
        CONFIGURE_OPERATOR_CONFIG_STATE=fixture
        [[ "$TEST_RECOVERY_VALIDATE_CALLS" == 1 ]]
    }
    configure_force_runtime_inactive_for_gate() {
        printf 'force-inactive\n' >> "$recovery_log"
    }
    if configure_require_current_deployment 192.0.2.20 >/dev/null 2>&1; then
        fail "configure accepted validation failure after stale-gate recovery"
    fi
    [[ "$(paste -sd '|' "$recovery_log")" == 'force-inactive' \
       && "$CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE" == 0 ]] \
        || fail "configure left the just-recovered Core running after validation failure"
)
pass "configure refuses incomplete state and stops a stale-gate recovery that fails validation"

# Gateway publication is one revision-checked update and never seeds. A true
# mid-call drift must win over the stale candidate, while a post-rename sync
# failure reports committed-undurable state without restoring old bytes.
(
    unset -f configure_update_existing_dns_gateway
    eval "$configure_gateway_fn"
    gateway_root="$TMP/gateway-cas"
    FIVEGPN_STATE_DIR="$gateway_root/state"
    DOT_CERT_DIR="$gateway_root/cert/dot"
    mkdir -p "$FIVEGPN_STATE_DIR" "$DOT_CERT_DIR/current"
    DOT_LISTEN_ADDR=:853
    DEBUG_LISTEN_ADDR=127.0.0.1:5353
    ORIGIN_LISTEN_ADDR=127.0.0.1:5354
    target="$FIVEGPN_STATE_DIR/dns.json"
    write_gateway_fixture() {
        local gateway="$1" marker="$2"
        jq -n --arg gateway "$gateway" --arg marker "$marker" \
            --arg cert "$DOT_CERT_DIR/current/fullchain.pem" \
            --arg key "$DOT_CERT_DIR/current/privkey.pem" '
            {listen:{dot:":853",debug:"127.0.0.1:5353",origin:"127.0.0.1:5354",
                     certificate:$cert,privateKey:$key},gateway:$gateway,
             upstreams:{china:["223.5.5.5:53"],trust:["22.22.22.22:53"]},
             policy:{fallback:"auto",marker:$marker},tuning:{}}' > "$target"
    }
    runtime_control_file_metadata_is_safe() { :; }
    configure_assert_runtime_gate_quiescent() { :; }
    configure_runtime_start_fence_is_active() { :; }
    chown() { :; }
    sync() { :; }
    ok() { :; }
    err() { :; }
    validate_dns_candidate_with_installed_core() {
        jq -e --arg gateway "$GATEWAY_IP" '.gateway == $gateway' "$1" >/dev/null
    }
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0

    write_gateway_fixture 192.0.2.20 original
    VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$target" | awk '{print $1}')"
    GATEWAY_IP=192.0.2.21
    configure_update_existing_dns_gateway || fail "valid gateway-only CAS update failed"
    jq -e '.gateway == "192.0.2.21" and .policy.marker == "original" and .upstreams.china == ["223.5.5.5:53"]' \
        "$target" >/dev/null || fail "gateway update changed operator-owned DNS fields"

    write_gateway_fixture 192.0.2.20 original
    VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$target" | awk '{print $1}')"
    validate_dns_candidate_with_installed_core() {
        local raced="${target}.raced"
        jq '.policy.marker = "raced"' "$target" > "$raced"
        mv -f -- "$raced" "$target"
        return 0
    }
    if configure_update_existing_dns_gateway >/dev/null 2>&1; then
        fail "gateway CAS overwrote a mid-call DNS document update"
    fi
    jq -e '.gateway == "192.0.2.20" and .policy.marker == "raced"' "$target" >/dev/null \
        || fail "gateway CAS did not preserve the concurrent winner"

    write_gateway_fixture 192.0.2.20 original
    VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$target" | awk '{print $1}')"
    validate_dns_candidate_with_installed_core() { return 0; }
    sync() {
        [[ "$1" == -f && "$2" == "$FIVEGPN_STATE_DIR" ]] && return 73
        return 0
    }
    if configure_update_existing_dns_gateway >/dev/null 2>&1; then
        fail "gateway update accepted a failed post-rename directory sync"
    fi
    jq -e '.gateway == "192.0.2.21"' "$target" >/dev/null \
        || fail "gateway update rolled back a visible pointer after directory sync failure"
    [[ "$CONFIGURE_DNS_GATEWAY_COMMIT_STATE" == committed-undurable ]] \
        || fail "gateway update did not expose its committed-undurable boundary"
)
pass "gateway updates preserve DNS state, enforce CAS, and never roll back a visible commit"

if [[ "${EUID:-$(id -u)}" == 0 ]]; then
    TEST_INSTALL="$INSTALL" TEST_TMP="$TMP" bash <<'GATE_TEST'
    set -Eeuo pipefail
    fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
    # Re-source pristine function definitions after the orchestration mocks and
    # exercise the real private gate files while replacing only PID1 queries.
    INSTALL_SH_LIB_ONLY=1
    export INSTALL_SH_LIB_ONLY
    # shellcheck source=../install.sh
    source "$TEST_INSTALL"
    gate_case="/run/5gpn/configure-gate-test.${BASHPID}"
    mkdir -p "$gate_case"
    chmod 0700 "$gate_case"
    INSTALL_LOCK_FILE="$gate_case/install.lock"
    CONFIGURE_RUNTIME_GATE_RECORD="$gate_case/configure-runtime-gate"
    CONFIGURE_RUNTIME_GATE_JOB="$gate_case/configure-runtime-gate.job"
    CONFIGURE_RUNTIME_GATE_ACK="$gate_case/configure-runtime-gate.ack"
    CONFIGURE_RUNTIME_GATE_RELEASE="$gate_case/configure-runtime-gate.release"
    TEST_BUSCTL_LOG="$gate_case/busctl.log"
    TEST_SYSTEMCTL_LOG="$gate_case/systemctl.log"
    : > "$TEST_BUSCTL_LOG"
    : > "$TEST_SYSTEMCTL_LOG"
    gate_cleanup() {
        rm -f -- "$CONFIGURE_RUNTIME_GATE_RELEASE" "$CONFIGURE_RUNTIME_GATE_ACK" \
            "$CONFIGURE_RUNTIME_GATE_JOB" "$CONFIGURE_RUNTIME_GATE_RECORD" \
            "$INSTALL_LOCK_FILE" "$TEST_BUSCTL_LOG" "$TEST_SYSTEMCTL_LOG"
        rmdir -- "$gate_case" 2>/dev/null || true
    }
    trap gate_cleanup EXIT

    ensure_private_lock_dir() { :; }
    TEST_TRY_OUTPUT=exact
    TEST_JOB_STATE=exact
    TEST_RUNTIME_STATE=activating
    TEST_RUNTIME_SUB_STATE=start-pre
    TEST_CONTROL_PID="$$"
    TEST_MAIN_PID=0
    TEST_RESULT=success
    TEST_INVOCATION_ID=0123456789abcdef0123456789abcdef
    TEST_READY_MODE=success
    TEST_READY_CALLS=0
    busctl() {
        local call="$*"
        if [[ "$call" == *' TryRestartUnit ss 5gpn-mihomo.service fail' ]]; then
            printf '%s\n' "$call" >> "$TEST_BUSCTL_LOG"
            case "$TEST_TRY_OUTPUT" in
                exact) printf '{"type":"o","data":["/org/freedesktop/systemd1/job/42"]}\n' ;;
                invalid) printf '{"type":"o","data":["/org/freedesktop/systemd1/job/42","extra"]}\n' ;;
                failure) return 1 ;;
            esac
            return 0
        fi
        if [[ "$call" == *' GetJob u 42' ]]; then
            case "$TEST_JOB_STATE" in
                exact) printf '{"type":"o","data":["/org/freedesktop/systemd1/job/42"]}\n' ;;
                foreign) printf '{"type":"o","data":["/org/freedesktop/systemd1/job/77"]}\n' ;;
                missing) return 1 ;;
            esac
            return 0
        fi
        if [[ "$call" == *' GetUnit s 5gpn-mihomo.service' ]]; then
            printf '{"type":"o","data":["/org/freedesktop/systemd1/unit/5gpn_2dmihomo_2eservice"]}\n'
            return 0
        fi
        case "$call" in
            *'org.freedesktop.systemd1.Job Id')
                [[ "$TEST_JOB_STATE" == exact ]] || return 1
                printf '{"type":"u","data":42}\n'
                ;;
            *'org.freedesktop.systemd1.Job Unit')
                [[ "$TEST_JOB_STATE" == exact ]] || return 1
                printf '{"type":"(so)","data":["5gpn-mihomo.service","/org/freedesktop/systemd1/unit/5gpn_2dmihomo_2eservice"]}\n'
                ;;
            *'org.freedesktop.systemd1.Unit Job')
                if [[ "$TEST_JOB_STATE" == exact ]]; then
                    printf '{"type":"(uo)","data":[42,"/org/freedesktop/systemd1/job/42"]}\n'
                else
                    printf '{"type":"(uo)","data":[0,"/"]}\n'
                fi
                ;;
            *'org.freedesktop.systemd1.Job JobType')
                [[ "$TEST_JOB_STATE" == exact ]] || return 1
                printf '{"type":"s","data":"try-restart"}\n'
                ;;
            *'org.freedesktop.systemd1.Job State')
                [[ "$TEST_JOB_STATE" == exact ]] || return 1
                printf '{"type":"s","data":"waiting"}\n'
                ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        case "$*" in
            'show -p ActiveState --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_RUNTIME_STATE"
                ;;
            'show -p SubState --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_RUNTIME_SUB_STATE"
                ;;
            'show -p UnitFileState --value 5gpn-mihomo.service')
                printf 'enabled\n'
                ;;
            'show -p ControlPID --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_CONTROL_PID"
                ;;
            'show -p MainPID --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_MAIN_PID"
                ;;
            'show -p Result --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_RESULT"
                ;;
            'show -p InvocationID --value 5gpn-mihomo.service')
                printf '%s\n' "$TEST_INVOCATION_ID"
                ;;
            '--job-mode=replace stop 5gpn-mihomo.service')
                printf 'stop\n' >> "$TEST_SYSTEMCTL_LOG"
                TEST_RUNTIME_STATE=inactive
                TEST_RUNTIME_SUB_STATE=dead
                TEST_CONTROL_PID=0
                TEST_MAIN_PID=0
                TEST_JOB_STATE=missing
                ;;
            *)
                printf 'unexpected:%s\n' "$*" >> "$TEST_SYSTEMCTL_LOG"
                return 1
                ;;
        esac
    }
    wait_managed_account_quiescent() {
        printf 'quiescent\n' >> "$TEST_SYSTEMCTL_LOG"
    }
    wait_service_ready() {
        TEST_READY_CALLS=$((TEST_READY_CALLS + 1))
        configure_runtime_gate_release_is_safe || return 1
        case "$TEST_READY_MODE" in
            success)
                TEST_RUNTIME_STATE=active
                TEST_RUNTIME_SUB_STATE=running
                TEST_CONTROL_PID=0
                TEST_MAIN_PID=4242
                TEST_RESULT=success
                TEST_JOB_STATE=missing
                return 0
                ;;
            operator-stop)
                TEST_RUNTIME_STATE=inactive
                TEST_RUNTIME_SUB_STATE=dead
                TEST_CONTROL_PID=0
                TEST_MAIN_PID=0
                TEST_RESULT=success
                TEST_JOB_STATE=missing
                return 1
                ;;
            success-failed)
                TEST_RUNTIME_STATE=failed
                TEST_RUNTIME_SUB_STATE=failed
                TEST_CONTROL_PID=0
                TEST_MAIN_PID=0
                TEST_RESULT=exit-code
                TEST_JOB_STATE=missing
                return 0
                ;;
            success-activating)
                TEST_RUNTIME_STATE=activating
                TEST_RUNTIME_SUB_STATE=start-post
                TEST_CONTROL_PID="$$"
                TEST_MAIN_PID=0
                TEST_RESULT=success
                TEST_JOB_STATE=missing
                return 0
                ;;
            success-control)
                TEST_RUNTIME_STATE=active
                TEST_RUNTIME_SUB_STATE=running
                TEST_CONTROL_PID="$$"
                TEST_MAIN_PID=4242
                TEST_RESULT=success
                TEST_JOB_STATE=missing
                return 0
                ;;
            failure) return 1 ;;
        esac
    }
    configure_validate_runtime_before_start() { :; }
    warn() { :; }
    info() { :; }
    err() { :; }

    publish_ack_fixture() {
        local contents
        configure_runtime_gate_record_is_safe || return 1
        contents="$(printf 'version=1\ntoken=%s\npid=%s\ninvocation_id=%s\n' \
            "$CONFIGURE_RUNTIME_GATE_TOKEN" "$$" \
            0123456789abcdef0123456789abcdef)"
        configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_ACK" \
            "${contents}"$'\n'
    }
    assert_no_gate_state() {
        local path
        for path in "$CONFIGURE_RUNTIME_GATE_RECORD" "$CONFIGURE_RUNTIME_GATE_JOB" \
                    "$CONFIGURE_RUNTIME_GATE_ACK" "$CONFIGURE_RUNTIME_GATE_RELEASE"; do
            [[ ! -e "$path" && ! -L "$path" ]] \
                || fail "PID1 gate cleanup retained state: $path"
        done
    }

    eval "$(declare -f configure_publish_runtime_gate_release \
        | sed '1s/configure_publish_runtime_gate_release/configure_publish_runtime_gate_release_real/')"
    TEST_RELEASE_CALLS=0
    configure_publish_runtime_gate_release() {
        TEST_RELEASE_CALLS=$((TEST_RELEASE_CALLS + 1))
        configure_publish_runtime_gate_release_real
    }

    configure_install_runtime_start_fence \
        || fail "could not install the private PID1 runtime gate fixture"
    configure_enqueue_pid1_try_restart \
        || fail "exact TryRestartUnit response was rejected"
    [[ "$(grep -c ' TryRestartUnit ss 5gpn-mihomo.service fail$' "$TEST_BUSCTL_LOG")" == 1 ]] \
        || fail "configure did not issue one exact fail-on-conflict TryRestartUnit call"
    configure_runtime_gate_job_record_is_safe \
        && [[ "$CONFIGURE_RUNTIME_GATE_JOB_ID" == 42 \
           && "$CONFIGURE_RUNTIME_GATE_JOB_PATH" == /org/freedesktop/systemd1/job/42 \
           && "$CONFIGURE_RUNTIME_GATE_JOB_METHOD" == TryRestartUnit \
           && "$CONFIGURE_RUNTIME_FENCE_RESTORE_ACTIVE" == 1 ]] \
        || fail "TryRestartUnit did not persist its exact PID1 job binding"
    publish_ack_fixture || fail "could not publish the PID1 gate acknowledgement fixture"
    TEST_CONTROL_PID=$(( $$ + 1 ))
    if configure_runtime_gate_ack_matches_control_process >/dev/null 2>&1; then
        fail "PID1 gate accepted an acknowledgement from a different ControlPID"
    fi
    TEST_CONTROL_PID="$$"
    TEST_INVOCATION_ID=ffffffffffffffffffffffffffffffff
    if configure_runtime_gate_ack_matches_control_process >/dev/null 2>&1; then
        fail "PID1 gate accepted an acknowledgement from a different InvocationID"
    fi
    TEST_INVOCATION_ID=0123456789abcdef0123456789abcdef
    configure_runtime_gate_ack_matches_control_process \
        || fail "exact job acknowledgement did not match systemd ControlPID and InvocationID"
    configure_runtime_start_fence_is_active \
        || fail "acknowledged PID1 restart job was not recognized as the active gate"
    configure_publish_runtime_gate_release \
        || fail "could not publish the matching PID1 gate release record"
    configure_runtime_gate_release_is_safe \
        || fail "published release record did not bind the active gate token"
    TEST_JOB_STATE=missing
    TEST_RUNTIME_STATE=active
    TEST_RUNTIME_SUB_STATE=running
    TEST_CONTROL_PID=0
    TEST_MAIN_PID=4242
    TEST_RESULT=success
    configure_release_runtime_start_fence \
        || fail "could not remove the completed PID1 gate state"
    assert_no_gate_state

    TEST_RUNTIME_STATE=inactive
    TEST_RUNTIME_SUB_STATE=dead
    TEST_CONTROL_PID=0
    TEST_MAIN_PID=0
    TEST_RESULT=success
    TEST_TRY_OUTPUT=invalid
    configure_install_runtime_start_fence \
        || fail "could not stage invalid TryRestartUnit response fixture"
    if configure_enqueue_pid1_try_restart >/dev/null 2>&1; then
        fail "configure accepted a non-exact TryRestartUnit job response"
    fi
    configure_runtime_gate_job_record_is_safe \
        && [[ "$CONFIGURE_RUNTIME_GATE_JOB_ID" == 0 \
           && "$CONFIGURE_RUNTIME_GATE_JOB_PATH" == / \
           && "$CONFIGURE_RUNTIME_GATE_JOB_METHOD" == none ]] \
        || fail "rejected TryRestartUnit output changed the unbound job record"
    configure_release_runtime_start_fence \
        || fail "could not clean rejected TryRestartUnit response state"
    assert_no_gate_state

    TEST_TRY_OUTPUT=exact
    TEST_JOB_STATE=exact
    TEST_RUNTIME_STATE=activating
    TEST_RUNTIME_SUB_STATE=start-pre
    TEST_CONTROL_PID="$$"
    TEST_MAIN_PID=0
    TEST_RESULT=success
    configure_install_runtime_start_fence \
        || fail "could not stage operator-stop PID1 gate fixture"
    configure_enqueue_pid1_try_restart \
        || fail "could not bind operator-stop fixture to its PID1 job"
    publish_ack_fixture || fail "could not acknowledge operator-stop fixture"
    TEST_JOB_STATE=missing
    TEST_RUNTIME_STATE=inactive
    TEST_RUNTIME_SUB_STATE=dead
    TEST_CONTROL_PID=0
    TEST_MAIN_PID=0
    TEST_RESULT=success
    CONFIGURE_RUNTIME_QUIESCED_BY_US=1
    CONFIGURE_RUNTIME_FENCED_BY_US=1
    TEST_RELEASE_CALLS=0
    TEST_READY_CALLS=0
    configure_start_quiesced_runtime \
        || fail "operator stop that canceled the PID1 job was not preserved"
    [[ "$TEST_RELEASE_CALLS" == 0 && "$TEST_READY_CALLS" == 0 \
       && "$CONFIGURE_RUNTIME_WAS_ACTIVE" == 0 ]] \
        || fail "configure released or waited on a PID1 job already canceled by operator stop"
    assert_no_gate_state

    for TEST_READY_MODE in success-failed success-activating success-control; do
        TEST_JOB_STATE=exact
        TEST_RUNTIME_STATE=activating
        TEST_RUNTIME_SUB_STATE=start-pre
        TEST_CONTROL_PID="$$"
        TEST_MAIN_PID=0
        TEST_RESULT=success
        configure_install_runtime_start_fence \
            || fail "could not stage post-readiness state fixture: $TEST_READY_MODE"
        configure_enqueue_pid1_try_restart \
            || fail "could not bind post-readiness state fixture: $TEST_READY_MODE"
        publish_ack_fixture || fail "could not acknowledge post-readiness state fixture"
        CONFIGURE_RUNTIME_QUIESCED_BY_US=1
        CONFIGURE_RUNTIME_FENCED_BY_US=1
        CONFIGURE_RUNTIME_WAS_ACTIVE=1
        CONFIGURE_NODE_LOCK_HELD=0
        if configure_start_quiesced_runtime >/dev/null 2>&1; then
            fail "configure accepted unstable state after readiness: $TEST_READY_MODE"
        fi
        assert_no_gate_state
    done
    TEST_READY_MODE=success

    for released_state in failed deactivating; do
        TEST_JOB_STATE=exact
        TEST_RUNTIME_STATE=activating
        TEST_RUNTIME_SUB_STATE=start-pre
        TEST_CONTROL_PID="$$"
        TEST_MAIN_PID=0
        TEST_RESULT=success
        configure_install_runtime_start_fence \
            || fail "could not stage retained released-state fixture: $released_state"
        configure_enqueue_pid1_try_restart \
            || fail "could not bind retained released-state fixture: $released_state"
        publish_ack_fixture || fail "could not acknowledge retained released-state fixture"
        configure_publish_runtime_gate_release \
            || fail "could not publish retained released-state fixture"
        TEST_JOB_STATE=missing
        TEST_RUNTIME_STATE="$released_state"
        TEST_RUNTIME_SUB_STATE="$released_state"
        TEST_CONTROL_PID=0
        TEST_MAIN_PID=0
        TEST_RESULT=exit-code
        CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
        CONFIGURE_RUNTIME_FENCED_BY_US=0
        CONFIGURE_RUNTIME_QUIESCED_BY_US=0
        if recover_stale_configure_runtime_fence >/dev/null 2>&1; then
            fail "released $released_state activation continued into configure"
        fi
        assert_no_gate_state
    done

    TEST_JOB_STATE=exact
    TEST_RUNTIME_STATE=activating
    TEST_RUNTIME_SUB_STATE=start-pre
    TEST_CONTROL_PID="$$"
    TEST_MAIN_PID=0
    TEST_RESULT=success
    configure_install_runtime_start_fence \
        || fail "could not stage missing-job timeout fixture"
    configure_enqueue_pid1_try_restart \
        || fail "could not bind missing-job timeout fixture"
    publish_ack_fixture || fail "could not acknowledge missing-job timeout fixture"
    TEST_JOB_STATE=missing
    TEST_RUNTIME_STATE=inactive
    TEST_RUNTIME_SUB_STATE=dead
    TEST_CONTROL_PID=0
    TEST_MAIN_PID=0
    TEST_RESULT=timeout
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    if recover_stale_configure_runtime_fence >/dev/null 2>&1; then
        fail "a missing PID1 job with timeout result was misclassified as operator stop"
    fi
    assert_no_gate_state

    TEST_JOB_STATE=exact
    TEST_RUNTIME_STATE=activating
    TEST_RUNTIME_SUB_STATE=start-pre
    TEST_CONTROL_PID="$$"
    TEST_MAIN_PID=0
    TEST_RESULT=success
    configure_install_runtime_start_fence \
        || fail "could not stage retained exact-job recovery fixture"
    configure_enqueue_pid1_try_restart \
        || fail "could not bind retained recovery fixture to its PID1 job"
    publish_ack_fixture || fail "could not acknowledge retained exact-job fixture"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
    TEST_RELEASE_CALLS=0
    TEST_READY_CALLS=0
    TEST_READY_MODE=success
    recover_stale_configure_runtime_fence \
        || fail "retained exact PID1 job did not recover after process death"
    [[ "$TEST_RELEASE_CALLS" == 1 && "$TEST_READY_CALLS" == 1 \
       && "$CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE" == 1 ]] \
        || fail "stale recovery did not release exactly its acknowledged PID1 job"
    assert_no_gate_state

    TEST_JOB_STATE=exact
    TEST_RUNTIME_STATE=activating
    TEST_RUNTIME_SUB_STATE=start-pre
    TEST_CONTROL_PID="$$"
    TEST_MAIN_PID=0
    TEST_RESULT=success
    configure_install_runtime_start_fence \
        || fail "could not stage foreign-job stale recovery fixture"
    configure_enqueue_pid1_try_restart \
        || fail "could not bind foreign-job stale recovery fixture"
    publish_ack_fixture || fail "could not acknowledge foreign-job stale fixture"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
    TEST_JOB_STATE=foreign
    TEST_RELEASE_CALLS=0
    TEST_READY_CALLS=0
    : > "$TEST_SYSTEMCTL_LOG"
    if recover_stale_configure_runtime_fence >/dev/null 2>&1; then
        fail "foreign PID1 job stale state continued into a new configure"
    fi
    [[ "$TEST_RELEASE_CALLS" == 0 && "$TEST_READY_CALLS" == 0 \
       && "$(grep -c '^stop$' "$TEST_SYSTEMCTL_LOG")" -ge 1 ]] \
        || fail "stale recovery released a non-exact PID1 job or skipped inactive cleanup"
    assert_no_gate_state
GATE_TEST
    pass "root PID1-gate acceptance proves exact job binding, ACK/ControlPID matching, operator-stop preservation, and exact-only stale release"
fi

printf 'all configure boundary tests passed\n'
