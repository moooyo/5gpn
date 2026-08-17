#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
CERT_RENEW="$ROOT/scripts/cert-renew.sh"
FAIL=0
pass(){ echo "ok: $*"; }
fail(){ echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

BASE_DOMAIN=env.example
PUBLIC_IP=203.0.113.9
CERT_MODE=debug
DNS_BASE_DOMAIN=attacker.example
DNS_GATEWAY_IP=203.0.113.10
DNS_MIHOMO_SECRET=attacker-secret
clear_external_config_env
if [[ -z "${BASE_DOMAIN+x}" && -z "${PUBLIC_IP+x}" && -z "${CERT_MODE+x}" \
   && -z "${DNS_BASE_DOMAIN+x}" && -z "${DNS_GATEWAY_IP+x}" \
   && -z "${DNS_MIHOMO_SECRET+x}" && "${UI_DIR:-}" == "/opt/5gpn/ui" ]]; then
    pass "caller configuration environment is discarded"
else
    fail "caller configuration survived or the fixed UI_DIR changed"
fi

if grep -Fq 'CERT_DNS_PROPAGATION_SECONDS="${CERT_DNS_PROPAGATION_SECONDS:-' "$INSTALL"; then
    fail "certificate propagation timing still accepts caller environment"
elif grep -Eq '^CERT_DNS_PROPAGATION_SECONDS=[0-9]+$' "$INSTALL"; then
    pass "certificate propagation timing is an installer constant"
else
    fail "certificate propagation timing has no fixed installer value"
fi

deps_fn="$(sed -n '/^install_deps()/,/^}/p' "$INSTALL")"
if grep -Fq 'findmnt jq' <<<"$deps_fn" \
   && grep -Fq 'Could not install required host packages.' <<<"$deps_fn" \
   && grep -Fq 'QR display will use the plain URL fallback.' <<<"$deps_fn"; then
    pass "required jq and optional qrencode have separate fail-hard/fallback paths"
else
    fail "host dependency installation can defer a missing jq until publication"
fi

main_fn="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
[[ "$(grep -n 'attach_tty' <<<"$main_fn" | head -1 | cut -d: -f1)" -lt \
   "$(grep -n 'case "\$cmd"' <<<"$main_fn" | head -1 | cut -d: -f1)" ]] \
    && pass "TTY reattachment precedes command dispatch" \
    || fail "main dispatch can prompt before TTY reattachment"

ect="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
if grep -Eq 'CF_API_TOKEN|CLOUDFLARE_API_TOKEN' <<<"$ect"; then
    fail "Cloudflare token still accepts caller environment"
else
    pass "Cloudflare token is TUI/saved-file only"
fi

stage_line="$(grep -n '^[[:space:]]*stage_artifacts' "$INSTALL" | tail -1 | cut -d: -f1)"
publish_line="$(grep -n '^[[:space:]]*install_mihomo' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ -n "$stage_line" && -n "$publish_line" && "$stage_line" -lt "$publish_line" ]]; then
    pass "artifact verification precedes publication"
else
    fail "artifacts are published before they are staged and verified"
fi

zash_flatten_root="$(mktemp -d)"
mkdir -p "$zash_flatten_root/dist/.vite" "$zash_flatten_root/dist/assets"
printf 'ui\n' > "$zash_flatten_root/dist/index.html"
printf 'manifest\n' > "$zash_flatten_root/dist/.vite/manifest.json"
printf 'asset\n' > "$zash_flatten_root/dist/assets/app.js"
if flatten_zashboard_dist "$zash_flatten_root" \
   && [[ -f "$zash_flatten_root/index.html" \
      && -f "$zash_flatten_root/.vite/manifest.json" \
      && -f "$zash_flatten_root/assets/app.js" \
      && ! -e "$zash_flatten_root/dist" ]]; then
    pass "zashboard dist flattening preserves hidden build metadata"
else
    fail "zashboard dist flattening dropped hidden entries or retained dist"
fi
rm -rf -- "$zash_flatten_root"

zash_sibling_root="$(mktemp -d)"
mkdir -p "$zash_sibling_root/dist"
printf 'ui\n' > "$zash_sibling_root/dist/index.html"
printf 'unexpected\n' > "$zash_sibling_root/sibling.txt"
if flatten_zashboard_dist "$zash_sibling_root" >/dev/null 2>&1; then
    fail "zashboard dist flattening accepted ambiguous outer siblings"
else
    pass "zashboard dist flattening rejects ambiguous outer siblings"
fi
rm -rf -- "$zash_sibling_root"

full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
claim_line="$(grep -n 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_fn" | head -1 | cut -d: -f1)"
root_line="$(grep -n 'claim_project_roots' <<<"$full_fn" | head -1 | cut -d: -f1)"
if [[ -n "$claim_line" && -n "$root_line" && "$claim_line" -lt "$root_line" ]] \
   && grep -Fq 'if [[ "${INSTALL_PUBLICATION_STARTED:-0}" == 1 ]]' "$INSTALL"; then
    pass "failure reporting enters the explicit project-root publication phase"
else
    fail "publication failure reporting is not tied to the explicit publication phase"
fi

# The installer reports a failure and unwinds its locks; it does not undo a
# partial publication. Anything that restores or quarantines is a regression.
grep -Fq 'trap install_transaction_error ERR' "$INSTALL" \
    && grep -Fq 'report_install_failure' "$INSTALL" \
    && pass "publication failures are trapped and reported" \
    || fail "publication failure reporting is not wired"
grep -Eq '^(rollback_install|capture_install_rollback|restore_managed_unit_states)\(\)' "$INSTALL" \
    && fail "the install rollback subsystem came back" \
    || pass "a failed install does not restore or quarantine the host"

# The interception credentials used to exist in two places: intercept/config.json
# rendered them and the operator's YAML carried a copy, so a reseeded document
# stranded the preserved YAML in credential-mismatch and the installer had to
# realign the two. In one process there is no second copy to drift from -- the
# engine holds the document and nothing interception-shaped is written into
# config.yaml at all. Neither the realignment nor the seed inputs may come back.
grep -Eq '^align_preserved_intercept_credentials\(\)' "$INSTALL" \
    && fail "the credential realignment subsystem came back" \
    || pass "no interception credential is copied into the operator mihomo config"
render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
grep -Fqi 'intercept' <<<"$render_fn" \
    && fail "the mihomo seed renderer still reaches for interception credentials" \
    || pass "the mihomo seed renderer has no interception inputs"

ic="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
cert_identity_fn="$(sed -n '/^cert_identity_matches_mode()/,/^}/p' "$INSTALL")"
grep -Fq 'validate_cert_pair' <<<"$ic" \
    && grep -Fq 'production' <<<"$ic" \
    && grep -Fq 'Reusing valid matching debug certificate' <<<"$ic" \
    && pass "production/debug certificate reuse paths are validated and isolated" \
    || fail "certificate reuse validation/mode isolation missing"
if grep -Fq 'cert_matches_hostname "$cert" "dot.${base}"' <<<"$cert_identity_fn" \
   && grep -Fq 'cert_matches_ip "${debug_src}/fullchain.pem" "$GATEWAY_IP"' <<<"$ic" \
   && grep -Fq 'cert_matches_ip "${debug_src}/fullchain.pem" "$PUBLIC_IP"' <<<"$ic" \
   && ! grep -Eq 'x509 .*-(checkhost|checkip)' <<<"${cert_identity_fn}${ic}"; then
    pass "certificate reuse routes hostname and IP identity through stable-status helpers"
else
    fail "certificate reuse still trusts x509 checkhost/checkip exit status"
fi

if grep -Fq -- '--cert-name "$base"' <<<"$ic" \
   && grep -Fq 'certbot_args=(renew --cert-name "$base" --non-interactive)' "$CERT_RENEW" \
   && grep -Fq '[[ -z "$requested_name" || "$requested_name" == "$base" ]]' "$CERT_RENEW"; then
    pass "issuance and helper renewal are strictly scoped to the configured cert name"
else
    fail "certificate issuance/renewal is not cert-name scoped"
fi

cert_ownership_tmp="$(mktemp -d)"
if (
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$cert_ownership_tmp/cert"
    certbot_lineage_owned_by_5gpn() { return 1; }
    certbot_lineage_artifacts_exist() { return 0; }
    pause_global_certbot_timer() { printf '%s\n' global-timer-paused >> "$cert_ownership_tmp/external.log"; return 1; }
    validate_cert_pair() { return 1; }
    certbot() { : > "$cert_ownership_tmp/certbot-called"; }
    ! install_cert example.com >/dev/null 2>&1 \
        && [[ ! -e "$cert_ownership_tmp/certbot-called" ]]
); then
    pass "invalid unowned canonical lineage fails before any Certbot mutation"
else
    fail "invalid unowned canonical lineage can reach Certbot"
fi

: > "$cert_ownership_tmp/external.log"
if (
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$cert_ownership_tmp/cert"
    certbot_lineage_owned_by_5gpn() { return 1; }
    certbot_lineage_artifacts_exist() { return 0; }
    pause_global_certbot_timer() { printf '%s\n' global-timer-paused >> "$cert_ownership_tmp/external.log"; return 1; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { return 0; }
    certbot_service_is_quiescent() { return 0; }
    deploy_cert_roles() { printf '%s\n' deploy >> "$cert_ownership_tmp/external.log"; }
    deployed_cert_roles_match_source() { return 0; }
    write_cert_provenance() { printf 'provenance:%s\n' "$3" >> "$cert_ownership_tmp/external.log"; }
    install_cert_deploy_hook() { printf '%s\n' hook >> "$cert_ownership_tmp/external.log"; }
    disable_scoped_renewal_timer() { printf '%s\n' no-project-timer >> "$cert_ownership_tmp/external.log"; }
    certbot() { : > "$cert_ownership_tmp/certbot-called"; }
    install_cert example.com >/dev/null \
        && grep -qx 'provenance:reused' "$cert_ownership_tmp/external.log" \
        && grep -qx 'hook' "$cert_ownership_tmp/external.log" \
        && grep -qx 'no-project-timer' "$cert_ownership_tmp/external.log" \
        && ! grep -qx 'global-timer-paused' "$cert_ownership_tmp/external.log" \
        && [[ ! -e "$cert_ownership_tmp/certbot-called" ]]
); then
    pass "valid external lineage is reused read-only without pausing the distro timer or enabling a project timer"
else
    fail "external lineage reuse claimed timer authority or lost role deployment"
fi

mkdir -p "$cert_ownership_tmp/le/live/example.com" \
    "$cert_ownership_tmp/le/archive/example.com" "$cert_ownership_tmp/le/renewal"
: > "$cert_ownership_tmp/le/renewal/example.com.conf"
if (
    LE_LIVE_ROOT="$cert_ownership_tmp/le/live"
    LE_ARCHIVE_ROOT="$cert_ownership_tmp/le/archive"
    LE_RENEWAL_ROOT="$cert_ownership_tmp/le/renewal"
    certbot_lineage_set_is_exclusive example.com >/dev/null
); then
    pass "owned canonical lineage can exclusively replace the distro timer"
else
    fail "exclusive canonical lineage was rejected"
fi
: > "$cert_ownership_tmp/le/renewal/other.example.conf"
if (
    LE_LIVE_ROOT="$cert_ownership_tmp/le/live"
    LE_ARCHIVE_ROOT="$cert_ownership_tmp/le/archive"
    LE_RENEWAL_ROOT="$cert_ownership_tmp/le/renewal"
    ! certbot_lineage_set_is_exclusive example.com >/dev/null 2>&1
); then
    pass "unrelated Certbot lineage blocks global timer takeover"
else
    fail "installer can disable renewal needed by an unrelated lineage"
fi
: > "$cert_ownership_tmp/timer.log"
if (
    timer_active=active
    systemctl() {
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer) printf '%s\n' "$timer_active"; return 0 ;;
            show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' enabled; return 0 ;;
            show:-p:LoadState:--value:certbot.service) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.service) printf '%s\n' active; return 0 ;;
            show:-p:UnitFileState:--value:certbot.service) printf '%s\n' static; return 0 ;;
            stop:certbot.timer:::) timer_active=inactive; printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ! pause_global_certbot_timer >/dev/null 2>&1
) && grep -qx stopped "$cert_ownership_tmp/timer.log"; then
    pass "installer stops the distro timer and rejects an already running certbot service"
else
    fail "active external Certbot can race the lineage snapshot"
fi

for unsupported_enabled in enabled-runtime static indirect generated transient alias linked linked-runtime masked masked-runtime; do
    : > "$cert_ownership_tmp/timer.log"
    if (
        GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=""
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=""
        systemctl() {
            case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
                show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
                show:-p:ActiveState:--value:certbot.timer) printf '%s\n' active; return 0 ;;
                show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' "$unsupported_enabled"; return 0 ;;
                stop:certbot.timer:::) printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
                *) return 1 ;;
            esac
        }
        ! pause_global_certbot_timer >/dev/null 2>&1
    ) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
        :
    else
        fail "unsupported certbot.timer enablement state was mutated: $unsupported_enabled"
    fi
done
for bad_reader in failure empty unsupported; do
    : > "$cert_ownership_tmp/timer.log"
    if (
        GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
        systemctl() {
            case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
                show:-p:LoadState:--value:certbot.timer)
                    case "$bad_reader" in
                        failure) return 1 ;;
                        empty) return 0 ;;
                        unsupported) printf '%s\n' error; return 0 ;;
                    esac ;;
                show:-p:ActiveState:--value:certbot.timer) printf '%s\n' inactive; return 0 ;;
                show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' disabled; return 0 ;;
                stop:certbot.timer:::) printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
                *) return 1 ;;
            esac
        }
        ! pause_global_certbot_timer >/dev/null 2>&1
    ) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
        :
    else
        fail "unreliable certbot.timer state reader was not fail-closed: $bad_reader"
    fi
done
pass "Certbot timer state queries fail closed before mutation"
if (
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    systemctl() {
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' not-found; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer|show:-p:UnitFileState:--value:certbot.timer) return 99 ;;
            show:-p:LoadState:--value:certbot.service) printf '%s\n' not-found; return 0 ;;
            stop:certbot.timer:::) return 99 ;;
            *) return 1 ;;
        esac
    }
    pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 1 \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE" == not-found \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == not-found ]] \
        && restore_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
); then
    pass "an absent distro Certbot timer is captured and reverified without mutation"
else
    fail "a debug host without certbot.timer was rejected or mutated"
fi
: > "$cert_ownership_tmp/timer.log"
if (
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    systemctl() {
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer) printf '%s\n' failed; return 0 ;;
            show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' enabled; return 0 ;;
            stop:certbot.timer:::) printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ! pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
    pass "non-round-trippable Certbot timer states fail before stop"
else
    fail "failed Certbot timer activity was accepted as restorable"
fi

: > "$cert_ownership_tmp/timer.log"
printf '0\n' > "$cert_ownership_tmp/active-reads"
if (
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    systemctl() {
        local reads
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer)
                reads="$(cat "$cert_ownership_tmp/active-reads")"
                reads=$((reads + 1))
                printf '%s\n' "$reads" > "$cert_ownership_tmp/active-reads"
                [[ "$reads" == 1 ]] && printf '%s\n' active || printf '%s\n' inactive
                return 0 ;;
            show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' enabled; return 0 ;;
            stop:certbot.timer:::) printf '%s\n' stopped >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ! pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
    pass "Certbot timer snapshot drift is rejected before stop"
else
    fail "Certbot timer changed between capture and stop without being rejected"
fi

: > "$cert_ownership_tmp/timer.log"
if (
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=active
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=enabled
    GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
    GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=inactive
    GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=disabled
    certbot_lineage_set_is_exclusive() { return 0; }
    systemctl() {
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer) printf '%s\n' inactive; return 0 ;;
            show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' disabled; return 0 ;;
            disable:--now:certbot.timer::) printf '%s\n' disabled >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ! disable_global_certbot_timer_for_owned_lineage example.com >/dev/null 2>&1
) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
    pass "Certbot timer drift after pause blocks irreversible disable"
else
    fail "Certbot timer takeover ignored state drift after pause"
fi

: > "$cert_ownership_tmp/timer.log"
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=active
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=enabled
    GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
    GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=inactive
    GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=enabled
    systemctl() {
        case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
            show:-p:LoadState:--value:certbot.timer) printf '%s\n' loaded; return 0 ;;
            show:-p:ActiveState:--value:certbot.timer) printf '%s\n' inactive; return 0 ;;
            show:-p:UnitFileState:--value:certbot.timer) printf '%s\n' disabled; return 0 ;;
            enable:*|disable:*|start:*|stop:*) printf '%s\n' "$*" >> "$cert_ownership_tmp/timer.log"; return 0 ;;
            *) return 1 ;;
        esac
    }
    ! restore_global_certbot_timer >/dev/null 2>&1
) && [[ ! -s "$cert_ownership_tmp/timer.log" ]]; then
    pass "timer cleanup refuses to overwrite an external state change"
else
    fail "timer cleanup overwrote a concurrent external state change"
fi

# `pause_global_certbot_timer` snapshots both active and enabled state. Until
# scoped 5gpn renewal is committed, every success, failure, and signal path must
# restore both values exactly.
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=""
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=""
    timer_active=active
    timer_enabled=enabled
    certbot_lineage_set_is_exclusive() { return 0; }
    systemctl() {
        case "${1:-}" in
            show)
                if [[ "${5:-}" == certbot.service ]]; then
                    case "${3:-}" in
                        LoadState) printf '%s\n' loaded ;;
                        ActiveState) printf '%s\n' inactive ;;
                        UnitFileState) printf '%s\n' static ;;
                        *) return 1 ;;
                    esac
                    return 0
                fi
                case "${3:-}" in
                    LoadState) printf '%s\n' loaded ;;
                    ActiveState) printf '%s\n' "$timer_active" ;;
                    UnitFileState) printf '%s\n' "$timer_enabled" ;;
                    *) return 1 ;;
                esac ;;
            stop) [[ "${2:-}" == certbot.timer ]] && timer_active=inactive ;;
            start) [[ "${2:-}" == certbot.timer ]] && timer_active=active ;;
            enable) timer_enabled=enabled ;;
            disable)
                timer_enabled=disabled
                [[ "$*" != *--now* ]] || timer_active=inactive ;;
            *) return 0 ;;
        esac
    }
    pause_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$timer_active" == inactive \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE" == active \
           && "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == enabled ]] \
        && disable_global_certbot_timer_for_owned_lineage example.com >/dev/null 2>&1 \
        && [[ "$timer_enabled" == disabled && "$KEEP_GLOBAL_CERTBOT_TIMER_DISABLED" == 0 ]] \
        && restore_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$timer_active" == active && "$timer_enabled" == enabled \
           && "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
); then
    pass "an uncommitted timer takeover restores original active and enabled state"
else
    fail "a failed or non-owning transaction can strand the distro certbot.timer"
fi
if (
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=active
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=enabled
    GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
    GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=inactive
    GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=disabled
    systemctl() {
        case "${1:-}" in
            show)
                case "${3:-}" in
                    LoadState) printf '%s\n' loaded ;;
                    ActiveState) printf '%s\n' inactive ;;
                    UnitFileState) printf '%s\n' disabled ;;
                    *) return 1 ;;
                esac ;;
            *) return 0 ;;
        esac
    }
    restore_global_certbot_timer >/dev/null 2>&1 \
        && [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 0 ]]
); then
    pass "an owned-lineage takeover keeps the distro timer disabled"
else
    fail "owned-lineage takeover restarted the timer it deliberately disabled"
fi
rm -rf -- "$cert_ownership_tmp"

if grep -Eq 'swapoff[[:space:]]+/swapfile|rm -f[[:space:]]+/swapfile' "$INSTALL"; then
    fail "generic host /swapfile is still touched"
elif grep -Fq 'SWAP_FILE="${STATE_DIR}/swapfile"' "$INSTALL"; then
    pass "swap uses a project-owned private path"
else
    fail "project-private swap path missing"
fi

if grep -Eq 'xray\.service|smartdns\.service|sing-box\.service|^remove_legacy_service_accounts\(\)' "$INSTALL"; then
    fail "historical service-account teardown remains"
else
    pass "installer contains no historical service-account teardown"
fi

renew_disable="$(sed -n '/^disable_scoped_renewal_timer()/,/^}/p' "$INSTALL")"
uninstall_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
if grep -Fq 'systemctl disable --now 5gpn-certbot-renew.timer' <<<"$renew_disable" \
   && ! grep -Eq 'remove_unit|rm[[:space:]].*5gpn-certbot-renew' <<<"$renew_disable" \
   && grep -Fq '5gpn-certbot-renew.timer' <<<"$uninstall_fn" \
   && grep -Fq '5gpn-certbot-renew.service' <<<"$uninstall_fn"; then
    pass "inapplicable renewal is disabled while uninstall remains the only unit-file removal path"
else
    fail "static renewal unit lifecycle is not limited to disable outside uninstall"
fi

if grep -Fxq 'MIHOMO_BIN="${BIN_DIR}/5gpn-mihomo"' "$INSTALL" \
   && ! grep -Fxq 'MIHOMO_BIN="${BIN_DIR}/mihomo"' "$INSTALL" \
   && grep -Fxq 'GUM_BIN="${BIN_DIR}/gum"' "$INSTALL"; then
    pass "the runtime binary is 5gpn-prefixed under the project root"
else
    fail "the runtime binary still uses an unprefixed or global path"
fi
uninstall_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
grep -Fq 'remove_runtime_preserving_gum' <<<"$uninstall_fn" \
    && ! grep -Fq 'remove_fixed_owned_dir "$BASE_DIR"' <<<"$uninstall_fn" \
    && pass "uninstall preserves Gum through the dedicated runtime cleanup" \
    || fail "uninstall still removes Gum with the whole runtime"

grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/mihomo.gz"' "$INSTALL" \
    && grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/zash.zip"' "$INSTALL" \
    && pass "all staged runtime artifacts are digest verified" \
    || fail "mandatory artifact digest verification missing"

if command -v openssl >/dev/null 2>&1; then
    cert_tmp="$(mktemp -d)"
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$cert_tmp/key.pem" -out "$cert_tmp/cert.pem" \
        -subj /CN=example.com \
        -addext 'subjectAltName=DNS:example.com,DNS:*.example.com,IP:203.0.113.9' >/dev/null 2>&1; then
        cert_mock="$cert_tmp/mock"
        mkdir "$cert_mock"
        real_cert_openssl="$(command -v openssl)"
        cat > "$cert_mock/openssl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${EMULATE_X509_CHECK_STATUS_ZERO:-0}" == 1 \
   && " $* " == *" x509 "* \
   && ( " $* " == *" -checkhost "* || " $* " == *" -checkip "* ) ]]; then
    exit 0
fi
exec "$REAL_CERT_OPENSSL" "$@"
MOCK
        chmod 0755 "$cert_mock/openssl"
        if (
            export PATH="$cert_mock:$PATH"
            export REAL_CERT_OPENSSL="$real_cert_openssl"
            export EMULATE_X509_CHECK_STATUS_ZERO=1
            cert_matches_hostname "$cert_tmp/cert.pem" dot.example.com \
                && ! cert_matches_hostname "$cert_tmp/cert.pem" dot.other.test \
                && cert_matches_ip "$cert_tmp/cert.pem" 203.0.113.9 \
                && ! cert_matches_ip "$cert_tmp/cert.pem" 203.0.113.10
        ); then
            pass "hostname and IP matching ignore OpenSSL 3.0 x509 check exit status"
        else
            fail "hostname or IP matching trusts OpenSSL 3.0 x509 check exit status"
        fi
        validate_cert_pair "$cert_tmp/cert.pem" "$cert_tmp/key.pem" example.com 0 debug \
            && pass "matching debug wildcard validates in debug mode" \
            || fail "matching debug wildcard was rejected"
        if validate_cert_pair "$cert_tmp/cert.pem" "$cert_tmp/key.pem" example.com 0 production; then
            fail "self-signed debug wildcard was accepted for production reuse"
        else
            pass "self-signed debug wildcard cannot enter production reuse"
        fi
        # -checkend answers only "does this expire soon" and says nothing about
        # notBefore, so a certificate that is not valid YET used to pass the
        # non-production path, which ran no verification at all. It would then
        # be rejected by every client that saw it.
        if openssl req -x509 -newkey rsa:2048 -nodes             -not_before "$(date -u -d '+2 days' +%Y%m%d%H%M%SZ)"             -not_after "$(date -u -d '+800 days' +%Y%m%d%H%M%SZ)"             -keyout "$cert_tmp/future-key.pem" -out "$cert_tmp/future-cert.pem"             -subj /CN=example.com             -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' >/dev/null 2>&1; then
            cert_matches_hostname "$cert_tmp/future-cert.pem" dot.example.com \
                && pass "certificate identity matching is independent of validity time" \
                || fail "certificate identity matching incorrectly enforces validity time"
            if validate_cert_pair "$cert_tmp/future-cert.pem" "$cert_tmp/future-key.pem" example.com 0 debug; then
                fail "a not-yet-valid debug certificate was accepted"
            else
                pass "a not-yet-valid debug certificate is rejected"
            fi
        else
            # Older OpenSSL has no req -x509 -not_before; skip rather than fail,
            # the assertion above still covers the accept path.
            pass "skipped not-yet-valid check (OpenSSL lacks req -not_before)"
        fi
    else
        fail "test OpenSSL cannot generate a SAN certificate"
    fi
    chain_tmp="$cert_tmp/partial-chain"
    mkdir "$chain_tmp"
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
           -keyout "$chain_tmp/root.key" -out "$chain_tmp/root.crt" \
           -subj '/CN=Root CA' -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1 \
       && openssl req -newkey rsa:2048 -nodes \
           -keyout "$chain_tmp/intermediate.key" -out "$chain_tmp/intermediate.csr" \
           -subj '/CN=Intermediate CA' >/dev/null 2>&1; then
        printf '%s\n' 'basicConstraints=critical,CA:TRUE' \
            'keyUsage=critical,keyCertSign,cRLSign' > "$chain_tmp/intermediate.ext"
        printf '%s\n' 'subjectAltName=DNS:dot.chain.example' > "$chain_tmp/leaf.ext"
        openssl x509 -req -in "$chain_tmp/intermediate.csr" \
            -CA "$chain_tmp/root.crt" -CAkey "$chain_tmp/root.key" -CAcreateserial \
            -days 2 -out "$chain_tmp/intermediate.crt" \
            -extfile "$chain_tmp/intermediate.ext" >/dev/null 2>&1 \
            || fail "test OpenSSL cannot sign an intermediate CA"
        openssl req -newkey rsa:2048 -nodes \
            -keyout "$chain_tmp/leaf.key" -out "$chain_tmp/leaf.csr" \
            -subj '/CN=dot.chain.example' >/dev/null 2>&1 \
            || fail "test OpenSSL cannot create a partial-chain leaf request"
        openssl x509 -req -in "$chain_tmp/leaf.csr" \
            -CA "$chain_tmp/intermediate.crt" -CAkey "$chain_tmp/intermediate.key" -CAcreateserial \
            -days 2 -out "$chain_tmp/leaf.crt" -extfile "$chain_tmp/leaf.ext" >/dev/null 2>&1 \
            || fail "test OpenSSL cannot sign a partial-chain leaf"
        cat "$chain_tmp/leaf.crt" "$chain_tmp/intermediate.crt" > "$chain_tmp/fullchain.pem"
        if cert_matches_hostname "$chain_tmp/fullchain.pem" dot.chain.example \
           && ! cert_matches_hostname "$chain_tmp/fullchain.pem" wrong.chain.example; then
            pass "hostname matching accepts a leaf+intermediate fullchain without a root"
        else
            fail "hostname matching cannot validate an ordinary rootless fullchain"
        fi
    else
        fail "test OpenSSL cannot create a partial-chain fixture"
    fi
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$cert_tmp/http-key.pem" -out "$cert_tmp/http-cert.pem" \
        -subj /CN=console.example.com \
        -addext 'subjectAltName=DNS:console.example.com,DNS:dot.example.com' >/dev/null 2>&1; then
        cert_chain_trusted() { return 0; }
        validate_cert_pair "$cert_tmp/http-cert.pem" "$cert_tmp/http-key.pem" example.com 0 production http-01 \
            && pass "HTTP-01 exact console/dot SAN shape validates" \
            || fail "HTTP-01 exact service SAN certificate was rejected"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
            -keyout "$cert_tmp/http-extra-key.pem" -out "$cert_tmp/http-extra-cert.pem" \
            -subj /CN=console.example.com \
            -addext 'subjectAltName=DNS:console.example.com,DNS:dot.example.com,DNS:extra.example.com' >/dev/null 2>&1
        if validate_cert_pair "$cert_tmp/http-extra-cert.pem" "$cert_tmp/http-extra-key.pem" example.com 0 production http-01; then
            fail "HTTP-01 certificate with an extra DNS SAN was accepted"
        else
            pass "HTTP-01 reuse requires the exact two-service DNS SAN set"
        fi
    else
        fail "test OpenSSL cannot generate an HTTP-01 SAN certificate"
    fi

    # A later-role staging failure must remove every earlier unpublished
    # generation and temporary current link. The live role remains absent.
    cert_failure_root="$(mktemp -d)"
    DEBUG_CERT_DIR="$cert_failure_root/debug-cert"
    DNS_CERT_DIR="$cert_failure_root/cert"
    FIVEGPN_SERVICE_USER="$(id -un)"
    FIVEGPN_SERVICE_GROUP="$(id -gn)"
    mkdir -p "$DEBUG_CERT_DIR/example.com" "$DNS_CERT_DIR"
    cp "$cert_tmp/cert.pem" "$DEBUG_CERT_DIR/example.com/fullchain.pem"
    cp "$cert_tmp/key.pem" "$DEBUG_CERT_DIR/example.com/privkey.pem"
    touch "$DNS_CERT_DIR/console"
    if deploy_cert_roles example.com "$DEBUG_CERT_DIR/example.com" debug >/dev/null 2>&1; then
        fail "certificate deployment succeeded despite an invalid later role path"
    elif find "$DNS_CERT_DIR/dot" -mindepth 1 \
            \( -name '.current.*' -o -name '.new.*' -o -name 'generation-*' -o -name current \) \
            -print -quit 2>/dev/null | grep -q .; then
        fail "failed certificate staging left an unpublished generation or link"
    else
        pass "failed certificate staging cleans every unpublished generation and link"
    fi
    rm -rf -- "$cert_failure_root"
    rm -rf -- "$cert_tmp"
fi

ownership_tmp="$(mktemp -d)"
if (
    DNS_CERT_DIR="$ownership_tmp/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    mkdir -p "$DNS_CERT_DIR"
    ensure_dns_cert_root() { return 0; }
    cert_root_is_safe() { return 0; }
    chown() { return 0; }
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    persist_certbot_lineage_ownership example.com \
        && write_cert_provenance cloudflare example.com owned \
        && write_cert_provenance debug example.com none \
        && certbot_lineage_owned_by_5gpn example.com
); then
    pass "production-to-debug switch preserves independent Certbot ownership proof"
else
    fail "debug mode overwrote the only proof needed to return to production or decommission"
fi
rm -rf -- "$ownership_tmp"

lineage_reuse_tmp="$(mktemp -d)"

run_owned_reuse_case() (
    local label="$1" marker_mode="$2" marker_lineage="$3"
    local case_root="$lineage_reuse_tmp/$label" log="$lineage_reuse_tmp/$label.log"
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$case_root/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    LE_LIVE_ROOT="$case_root/letsencrypt/live"
    LE_ARCHIVE_ROOT="$case_root/letsencrypt/archive"
    LE_RENEWAL_ROOT="$case_root/letsencrypt/renewal"
    DEBUG_CERT_DIR="$case_root/debug-cert"
    DOT_CERT_DIR="$DNS_CERT_DIR/dot"
    CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
    ACME_DIR="$case_root/acme"
    GATEWAY_IP=""
    PUBLIC_IP=""
    CERT_EMAIL=admin@example.com
    mkdir -p "$DNS_CERT_DIR" "$LE_LIVE_ROOT/example.com"
    printf 'version=1\nowned=example.com\n' > "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=%s\nbase=example.com\ncertbot_lineage=%s\n' \
        "$marker_mode" "$marker_lineage" > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE" "$DNS_CERT_DIR/.provenance"
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    certbot_lineage_artifacts_exist() { return 0; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { [[ "$2" == cloudflare ]]; }
    certbot_service_is_quiescent() { return 0; }
    pause_global_certbot_timer() { printf '%s\n' global-timer-paused >> "$log"; }
    disable_global_certbot_timer_for_owned_lineage() { printf '%s\n' global-timer-owned >> "$log"; }
    deploy_cert_roles() { printf 'deploy:%s:%s:%s\n' "$1" "$2" "$3" >> "$log"; }
    write_cert_provenance() { printf 'provenance:%s:%s:%s\n' "$1" "$2" "$3" >> "$log"; }
    install_cert_deploy_hook() { printf '%s\n' hook-installed >> "$log"; }
    install_renewal_automation() { printf '%s\n' project-timer-enabled >> "$log"; }
    ensure_cf_token() { printf '%s\n' token-validated >> "$log"; }
    certbot() { printf '%s\n' certbot-called >> "$log"; return 1; }
    install_cert example.com >/dev/null 2>&1 \
        && grep -qx 'global-timer-paused' "$log" \
        && grep -qx 'global-timer-owned' "$log" \
        && grep -qx "deploy:example.com:${LE_LIVE_ROOT}/example.com:cloudflare" "$log" \
        && grep -qx 'provenance:cloudflare:example.com:owned' "$log" \
        && grep -qx 'project-timer-enabled' "$log" \
        && grep -qx 'token-validated' "$log" \
        && ! grep -qx 'certbot-called' "$log"
)

if run_owned_reuse_case same-mode cloudflare owned; then
    pass "same-mode owned production lineage reuse performs zero Certbot issuance"
else
    fail "same-mode owned production lineage did not reuse safely"
fi

if run_owned_reuse_case return-from-debug debug none; then
    pass "owned production-to-debug-to-production selects the same validated lineage without reissuance"
else
    fail "returning from debug lost independent owned-lineage reuse authority"
fi

if (
    case_root="$lineage_reuse_tmp/external-debug-return"
    log="$lineage_reuse_tmp/external-debug-return.log"
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$case_root/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    LE_LIVE_ROOT="$case_root/letsencrypt/live"
    LE_ARCHIVE_ROOT="$case_root/letsencrypt/archive"
    LE_RENEWAL_ROOT="$case_root/letsencrypt/renewal"
    DEBUG_CERT_DIR="$case_root/debug-cert"
    DOT_CERT_DIR="$DNS_CERT_DIR/dot"
    CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
    ACME_DIR="$case_root/acme"
    GATEWAY_IP=""
    PUBLIC_IP=""
    mkdir -p "$DNS_CERT_DIR" "$LE_LIVE_ROOT/example.com"
    printf 'version=1\nowned=other.example\n' > "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=debug\nbase=example.com\ncertbot_lineage=none\n' > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE" "$DNS_CERT_DIR/.provenance"
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    certbot_lineage_artifacts_exist() { return 0; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { [[ "$2" == cloudflare ]]; }
    certbot_service_is_quiescent() { printf '%s\n' quiescence-checked >> "$log"; }
    deploy_cert_roles() { printf 'deploy:%s:%s:%s\n' "$1" "$2" "$3" >> "$log"; }
    source_match_calls=0
    deployed_cert_roles_match_source() {
        source_match_calls=$((source_match_calls + 1))
        [[ "$source_match_calls" == 2 ]]
    }
    write_cert_provenance() { printf 'provenance:%s\n' "$3" >> "$log"; }
    install_cert_deploy_hook() { printf '%s\n' hook-installed >> "$log"; }
    disable_scoped_renewal_timer() { printf '%s\n' project-timer-disabled >> "$log"; }
    install_renewal_automation() { printf '%s\n' project-timer-enabled >> "$log"; }
    persist_certbot_lineage_ownership() { printf '%s\n' ownership-written >> "$log"; }
    pause_global_certbot_timer() { printf '%s\n' global-timer-paused >> "$log"; return 1; }
    certbot() { printf '%s\n' certbot-called >> "$log"; return 1; }
    install_cert example.com >/dev/null 2>&1 \
        && grep -qx "deploy:example.com:${LE_LIVE_ROOT}/example.com:cloudflare" "$log" \
        && grep -qx 'provenance:reused' "$log" \
        && grep -qx 'hook-installed' "$log" \
        && [[ "$(sed -n '1,3p' "$log")" == $'hook-installed\nquiescence-checked\n'"deploy:example.com:${LE_LIVE_ROOT}/example.com:cloudflare" ]] \
        && grep -qx 'project-timer-disabled' "$log" \
        && [[ "$(grep -Fc "deploy:example.com:${LE_LIVE_ROOT}/example.com:cloudflare" "$log")" == 2 ]] \
        && ! grep -Eq 'ownership-written|project-timer-enabled|global-timer-paused|certbot-called' "$log"
); then
    pass "external production lineage with unrelated retained ownership retries a raced snapshot without timer authority"
else
    fail "external lineage snapshot race or unrelated ownership changed authority"
fi

if (
    case_root="$lineage_reuse_tmp/external-reselection"
    DNS_CERT_DIR="$case_root/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    mkdir -p "$DNS_CERT_DIR"
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    printf 'version=1\nowned=old.example\n' > "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=cloudflare\nbase=old.example\ncertbot_lineage=owned\n' > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE" "$DNS_CERT_DIR/.provenance"
    certificate_selection_state_is_consistent_for_install new.example cloudflare \
        && external_lineage_current_selection_allows_reuse new.example cloudflare \
        || exit 1
    rm -f -- "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=cloudflare\nbase=example.com\ncertbot_lineage=reused\n' > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$DNS_CERT_DIR/.provenance"
    certificate_selection_state_is_consistent_for_install example.com http-01 \
        && external_lineage_current_selection_allows_reuse example.com http-01
); then
    pass "old base or production mode provenance does not cause late rejection of a strict external selection"
else
    fail "external base/mode reselection would fail after publication"
fi

if (
    case_root="$lineage_reuse_tmp/ownership-mismatch"
    log="$lineage_reuse_tmp/ownership-mismatch.log"
    CERT_MODE=cloudflare
    DNS_CERT_DIR="$case_root/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    LE_LIVE_ROOT="$case_root/letsencrypt/live"
    LE_ARCHIVE_ROOT="$case_root/letsencrypt/archive"
    LE_RENEWAL_ROOT="$case_root/letsencrypt/renewal"
    DEBUG_CERT_DIR="$case_root/debug-cert"
    DOT_CERT_DIR="$DNS_CERT_DIR/dot"
    CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
    ACME_DIR="$case_root/acme"
    GATEWAY_IP=""
    PUBLIC_IP=""
    mkdir -p "$DNS_CERT_DIR" "$LE_LIVE_ROOT/example.com"
    printf 'version=1\nowned=example.com\n' > "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=cloudflare\nbase=example.com\ncertbot_lineage=reused\n' > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE" "$DNS_CERT_DIR/.provenance"
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    certbot_lineage_artifacts_exist() { return 0; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { return 0; }
    deploy_cert_roles() { printf '%s\n' deploy >> "$log"; }
    pause_global_certbot_timer() { printf '%s\n' global-timer-paused >> "$log"; }
    install_renewal_automation() { printf '%s\n' project-timer-enabled >> "$log"; }
    persist_certbot_lineage_ownership() { printf '%s\n' ownership-written >> "$log"; }
    certbot() { printf '%s\n' certbot-called >> "$log"; }
    ! certificate_selection_state_is_consistent_for_install example.com cloudflare >/dev/null 2>&1 \
        && ! install_cert example.com >/dev/null 2>&1 \
        && [[ ! -s "$log" ]]
); then
    pass "same-base external provenance conflicting with ownership fails before publication or mutation"
else
    fail "same-base source/ownership mismatch reached certificate or timer mutation"
fi

run_owned_nonreuse_case() (
    local label="$1" marker_mode="$2" marker_base="$3" marker_lineage="$4" requested_mode="$5"
    local case_root="$lineage_reuse_tmp/$label" log="$lineage_reuse_tmp/$label.log"
    CERT_MODE="$requested_mode"
    DNS_CERT_DIR="$case_root/cert"
    CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
    LE_LIVE_ROOT="$case_root/letsencrypt/live"
    LE_ARCHIVE_ROOT="$case_root/letsencrypt/archive"
    LE_RENEWAL_ROOT="$case_root/letsencrypt/renewal"
    DEBUG_CERT_DIR="$case_root/debug-cert"
    DOT_CERT_DIR="$DNS_CERT_DIR/dot"
    CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
    ACME_DIR="$case_root/acme"
    GATEWAY_IP=""
    PUBLIC_IP=""
    CONSOLE_DOMAIN=console.example.com
    DOT_DOMAIN=dot.example.com
    CERT_EMAIL=admin@example.com
    mkdir -p "$DNS_CERT_DIR" "$LE_LIVE_ROOT/example.com"
    printf 'version=1\nowned=example.com\n' > "$CERTBOT_OWNERSHIP_FILE"
    printf 'mode=%s\nbase=%s\ncertbot_lineage=%s\n' \
        "$marker_mode" "$marker_base" "$marker_lineage" > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE" "$DNS_CERT_DIR/.provenance"
    root_plain_file_metadata_is_safe() {
        [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
           && "$(file_nlink "$1")" == 1 ]]
    }
    certbot_lineage_artifacts_exist() { return 0; }
    validate_cert_pair() { return 0; }
    certbot_renewal_mode_matches() { return 0; }
    pause_global_certbot_timer() { return 0; }
    disable_global_certbot_timer_for_owned_lineage() { return 0; }
    ensure_cf_token() { return 0; }
    check_http_challenge_dns_once() { return 0; }
    certbot() { printf '%s\n' certbot-called >> "$log"; return 1; }
    run_http_certbot() { printf '%s\n' certbot-called >> "$log"; return 1; }
    deploy_cert_roles() { printf '%s\n' deploy >> "$log"; }
    ! install_cert example.com >/dev/null 2>&1 \
        && grep -qx 'certbot-called' "$log" \
        && ! grep -qx 'deploy' "$log"
)

if run_owned_nonreuse_case other-base debug other.example none cloudflare; then
    pass "a debug marker for another base cannot reuse the owned production lineage"
else
    fail "another base was accepted as current owned-lineage selection"
fi

if run_owned_nonreuse_case other-mode cloudflare example.com owned http-01; then
    pass "a different production mode cannot reuse the previously selected lineage"
else
    fail "another production mode bypassed reissuance"
fi

if (
    CERT_MODE=cloudflare
    certbot_lineage_artifacts_exist() { return 0; }
    certbot_lineage_owned_by_5gpn() { return 1; }
    ! certbot_transaction_requires_global_timer_pause example.com cloudflare \
        && ! certbot_transaction_requires_global_timer_pause example.com debug
); then
    pass "external and debug selections do not authorize distro timer pause"
else
    fail "read-only certificate sources still request distro timer control"
fi

if (
    certbot_lineage_artifacts_exist() { return 0; }
    certbot_lineage_owned_by_5gpn() { return 0; }
    certbot_transaction_requires_global_timer_pause example.com cloudflare
); then
    pass "an owned production lineage retains scoped timer takeover coordination"
else
    fail "owned production lineage lost required timer coordination"
fi

[[ "$(grep -Fc 'if certbot_transaction_requires_global_timer_pause "$BASE_DOMAIN" "$CERT_MODE"; then' <<<"$full_fn")" == 2 ]] \
    && pass "full installation pauses the distro timer only through the source-aware gate" \
    || fail "full installation still pauses the distro timer unconditionally"

selection_first_line="$(grep -nF 'certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"' <<<"$full_fn" | head -1 | cut -d: -f1)"
selection_last_line="$(grep -nF 'certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"' <<<"$full_fn" | tail -1 | cut -d: -f1)"
deps_line="$(grep -nF 'install_deps' <<<"$full_fn" | head -1 | cut -d: -f1)"
publication_line="$(grep -nF 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_fn" | head -1 | cut -d: -f1)"
if [[ "$(grep -Fc 'certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"' <<<"$full_fn")" == 4 \
   && -n "$selection_first_line" && -n "$selection_last_line" \
   && -n "$deps_line" && -n "$publication_line" \
   && "$selection_first_line" -lt "$deps_line" \
   && "$selection_last_line" -lt "$publication_line" ]]; then
    pass "certificate source/ownership conflicts fail before dependency or project publication"
else
    fail "certificate selection consistency is checked too late"
fi

rm -rf -- "$lineage_reuse_tmp"

cert_state_tmp="$(mktemp -d)"
DNS_CERT_DIR="$cert_state_tmp/cert"
CERTBOT_OWNERSHIP_FILE="$DNS_CERT_DIR/.certbot-ownership"
DOT_CERT_DIR="$DNS_CERT_DIR/dot"
CONSOLE_CERT_DIR="$DNS_CERT_DIR/console"
DEBUG_CERT_DIR="$cert_state_tmp/debug-cert"
ACME_DIR="$cert_state_tmp/acme"
LE_LIVE_ROOT="$cert_state_tmp/letsencrypt/live"
LE_ARCHIVE_ROOT="$cert_state_tmp/letsencrypt/archive"
LE_RENEWAL_ROOT="$cert_state_tmp/letsencrypt/renewal"
mkdir -p "$DOT_CERT_DIR/current" "$LE_LIVE_ROOT/example.com" "$LE_ARCHIVE_ROOT" "$LE_RENEWAL_ROOT"
# This fixture exercises provenance semantics, not the separately covered fixed
# certificate-root ownership boundary.
ensure_dns_cert_root() { mkdir -p "$DNS_CERT_DIR"; }
cert_root_is_safe() { return 0; }
root_plain_file_metadata_is_safe() {
    [[ -f "$1" && ! -L "$1" && "$(file_mode "$1")" == "$3" \
       && "$(file_nlink "$1")" == 1 ]]
}
certbot_ownership_record_is_safe() { [[ -f "$CERTBOT_OWNERSHIP_FILE" ]]; }
set_certbot_ownership() {
    printf 'version=1\nowned=%s\n' "$1" > "$CERTBOT_OWNERSHIP_FILE"
}
clear_certbot_ownership() { rm -f -- "$CERTBOT_OWNERSHIP_FILE"; }
set_cert_provenance() {
    printf 'mode=%s\nbase=%s\ncertbot_lineage=%s\n' "$1" "$2" "$3" \
        > "$DNS_CERT_DIR/.provenance"
    chmod 0640 "$DNS_CERT_DIR/.provenance"
}

clear_certbot_ownership
set_cert_provenance cloudflare example.com reused
if certbot_lineage_owned_by_5gpn example.com; then
    fail "a reused Certbot lineage was treated as 5gpn-owned"
else
    pass "reused Certbot lineage provenance is non-owning"
fi
set_cert_provenance cloudflare example.com owned
set_certbot_ownership example.com
certbot_lineage_owned_by_5gpn example.com \
    && pass "the current Certbot ownership record proves ownership" \
    || fail "the current Certbot ownership record was not recognized"

if (
    printf 'version=1\nowned=example.com\nowned=other.example\n' > "$CERTBOT_OWNERSHIP_FILE"
    chmod 0640 "$CERTBOT_OWNERSHIP_FILE"
    chown() { return 0; }
    sync() { return 0; }
    revoke_certbot_lineage_ownership example.com \
        && grep -Fxq 'owned=other.example' "$CERTBOT_OWNERSHIP_FILE" \
        && ! grep -Fxq 'owned=example.com' "$CERTBOT_OWNERSHIP_FILE"
); then
    pass "ownership revocation removes only the exact base and preserves unrelated authority"
else
    fail "exact-base ownership revocation widened to another lineage"
fi
set_certbot_ownership example.com

certbot_log="$cert_state_tmp/certbot.log"
CERTBOT_DELETE_RC=0
certbot() {
    [[ ! -e "$CERTBOT_OWNERSHIP_FILE" && ! -L "$CERTBOT_OWNERSHIP_FILE" ]] \
        || printf '%s\n' authority-present-at-delete >> "$certbot_log"
    printf '%s\n' "$*" >> "$certbot_log"
    return "$CERTBOT_DELETE_RC"
}
printf 'dns_cloudflare_credentials = %s/cloudflare.ini\n' "$ACME_DIR" \
    > "$LE_RENEWAL_ROOT/example.com.conf"
clear_certbot_ownership
set_cert_provenance cloudflare example.com reused
decommission_certbot_lineage example.com >/dev/null
if [[ -s "$certbot_log" || "$DECOMMISSION_PRESERVE_ACME" != 1 ]]; then
    fail "decommission sent a reused external lineage to certbot delete"
else
    pass "decommission preserves a reused external lineage and its referenced credential"
fi
set_cert_provenance cloudflare example.com owned
set_certbot_ownership example.com
decommission_lineage_safe() { return 0; }
decommission_certbot_lineage example.com >/dev/null
grep -qx -- 'delete --non-interactive --cert-name example.com' "$certbot_log" \
    && [[ ! -e "$CERTBOT_OWNERSHIP_FILE" && ! -L "$CERTBOT_OWNERSHIP_FILE" ]] \
    && [[ "$(cert_provenance_get certbot_lineage)" == reused ]] \
    && ! grep -qx 'authority-present-at-delete' "$certbot_log" \
    && pass "decommission deletes only a provenance-confirmed owned lineage" \
    || fail "owned lineage deletion did not revoke its exact retained authority"

set_certbot_ownership example.com
: > "$certbot_log"
CERTBOT_DELETE_RC=1
if ! decommission_certbot_lineage example.com >/dev/null 2>&1 \
   && [[ ! -e "$CERTBOT_OWNERSHIP_FILE" && ! -L "$CERTBOT_OWNERSHIP_FILE" ]] \
   && [[ "$(cert_provenance_get certbot_lineage)" == reused ]] \
   && grep -qx -- 'delete --non-interactive --cert-name example.com' "$certbot_log" \
   && ! grep -qx 'authority-present-at-delete' "$certbot_log"; then
    pass "failed Certbot deletion leaves the lineage external without restoring authority"
else
    fail "Certbot deletion failure retained or restored stale ownership"
fi
CERTBOT_DELETE_RC=0

# Simulate a lost Certbot live lineage with a still-valid preserved dot role.
set_certbot_ownership example.com
rm -rf -- "$LE_LIVE_ROOT/example.com"
rm -rf -- "$LE_ARCHIVE_ROOT/example.com"
rm -f -- "$LE_RENEWAL_ROOT/example.com.conf"
touch "$DOT_CERT_DIR/current/fullchain.pem" "$DOT_CERT_DIR/current/privkey.pem"
: > "$certbot_log"
reuse_log="$cert_state_tmp/reuse.log"
validate_cert_pair() { [[ "$1" == "$DOT_CERT_DIR/current/fullchain.pem" ]]; }
deploy_cert_roles() { printf 'deploy:%s:%s\n' "$1" "${2:-}" >> "$reuse_log"; }
remove_owned_renew_hook() { printf '%s\n' hook-removed >> "$reuse_log"; }
disable_scoped_renewal_timer() { printf '%s\n' timer-disabled >> "$reuse_log"; }
ensure_cf_token() { printf '%s\n' token-requested >> "$reuse_log"; return 1; }
pause_global_certbot_timer() { return 0; }
set_cert_provenance cloudflare example.com reused
CERT_MODE=cloudflare
if install_cert example.com >/dev/null \
   && grep -qx "deploy:example.com:${DOT_CERT_DIR}/current" "$reuse_log" \
   && grep -qx 'timer-disabled' "$reuse_log" \
   && [[ "$(cert_provenance_get certbot_lineage)" == missing ]] \
   && ! grep -q 'token-requested' "$reuse_log" \
   && [[ ! -s "$certbot_log" ]]; then
    pass "missing lineage reuses the preserved role cert without issuance and disables renewal"
else
    fail "preserved role certificate fallback is incomplete"
fi

# Repairing the canonical owned lineage after a missing-lineage fallback must
# restore ordinary reuse and renewal. `missing` is still only the current role
# source; the independent ownership record and strict live fingerprint provide
# the authority.
mkdir -p "$LE_LIVE_ROOT/example.com" "$LE_ARCHIVE_ROOT/example.com"
: > "$LE_LIVE_ROOT/example.com/fullchain.pem"
: > "$LE_LIVE_ROOT/example.com/privkey.pem"
: > "$LE_RENEWAL_ROOT/example.com.conf"
: > "$reuse_log"
validate_cert_pair() {
    [[ "$1" == "$DOT_CERT_DIR/current/fullchain.pem" \
       || "$1" == "$LE_LIVE_ROOT/example.com/fullchain.pem" ]]
}
certbot_renewal_mode_matches() { return 0; }
disable_global_certbot_timer_for_owned_lineage() { return 0; }
ensure_cf_token() { printf '%s\n' token-validated >> "$reuse_log"; }
install_cert_deploy_hook() { printf '%s\n' hook-installed >> "$reuse_log"; }
install_renewal_automation() { printf '%s\n' timer-enabled >> "$reuse_log"; }
if install_cert example.com >/dev/null \
   && grep -qx "deploy:example.com:${LE_LIVE_ROOT}/example.com" "$reuse_log" \
   && grep -qx 'token-validated' "$reuse_log" \
   && grep -qx 'hook-installed' "$reuse_log" \
   && grep -qx 'timer-enabled' "$reuse_log" \
   && [[ "$(cert_provenance_get certbot_lineage)" == owned ]] \
   && [[ ! -s "$certbot_log" ]]; then
    pass "a repaired owned canonical lineage recovers from missing without reissuance"
else
    fail "missing lineage provenance became an unrecoverable terminal state"
fi

# A crash after Certbot deletion but before authority cleanup is repaired by the
# next explicit decommission without invoking Certbot again.
rm -rf -- "$LE_LIVE_ROOT/example.com" "$LE_ARCHIVE_ROOT/example.com"
rm -f -- "$LE_RENEWAL_ROOT/example.com.conf"
set_certbot_ownership example.com
: > "$certbot_log"
if decommission_certbot_lineage example.com >/dev/null \
   && [[ ! -e "$CERTBOT_OWNERSHIP_FILE" && ! -L "$CERTBOT_OWNERSHIP_FILE" ]] \
   && [[ "$(cert_provenance_get certbot_lineage)" == missing ]] \
   && [[ ! -s "$certbot_log" ]]; then
    pass "decommission repairs stale exact-base ownership after lineage deletion"
else
    fail "absent lineage left stale renewal/deletion authority"
fi
rm -rf -- "$cert_state_tmp"

# Retired certificate and profile fields are unsupported footprints. The
# current-only installer must reject them without rewriting the file.
retired_env="$(mktemp)"
cat > "$retired_env" <<'RETIRED_ENV'
DNS_BASE_DOMAIN=env.example
DNS_CERT=/etc/5gpn/cert/dot/current/fullchain.pem
DNS_KEY=/etc/5gpn/cert/dot/current/privkey.pem
DNS_WEB_CERT=/etc/5gpn/cert/web/current/fullchain.pem
DNS_WEB_KEY=/etc/5gpn/cert/web/current/privkey.pem
WWW_DIR=/opt/5gpn/www
RETIRED_ENV
if validate_dns_env_schema "$retired_env" 2>/dev/null; then
    fail "retired certificate/profile keys were accepted"
else
    pass "retired certificate/profile keys fail closed"
fi

# Arbitrary unknown keys also fail closed.
unsupported_env="$(mktemp)"
printf 'DNS_BASE_DOMAIN=env.example\nDNS_NOT_A_REAL_KEY=x\n' > "$unsupported_env"
if validate_dns_env_schema "$unsupported_env" 2>/dev/null; then
    fail "a genuinely unsupported dns.env key was accepted"
else
    pass "a genuinely unsupported dns.env key is still rejected"
fi
rm -f "$retired_env" "$unsupported_env"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer review regressions: PASS"
else
    echo "installer review regressions: FAIL"
    exit 1
fi
