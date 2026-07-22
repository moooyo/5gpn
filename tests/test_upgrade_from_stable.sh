#!/usr/bin/env bash
# Fixed regression coverage for an in-place 0.0.13 stable-to-beta upgrade.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
FIXTURE="$ROOT/tests/fixtures/stable-0.0.13"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d /tmp/5gpn-upgrade-from-stable.XXXXXX)"
claim_temp_dir "$TMP" || { rmdir -- "$TMP"; exit 1; }
trap 'remove_temp_dir "$TMP"' EXIT

# The frozen fixture retains the raw stable key set. The current schema must
# reject it first; this test then performs the same explicit one-key removal an
# operator reviews before continuing the upgrade.
CONF_DIR="$TMP/conf"
mkdir -p "$CONF_DIR"
cp -- "$FIXTURE/dns.env.example" "$CONF_DIR/dns.env"
raw_validation="$(validate_dns_env_schema 2>&1)" && raw_validation_rc=0 || raw_validation_rc=$?
if [[ "$raw_validation_rc" == 0 ]]; then
    fail "raw stable dns.env was accepted as a compatibility alias"
else
    pass "raw stable dns.env requires explicit rebuild after DNS_EGRESS_RESOLVER retirement"
fi
if [[ "$raw_validation" == *"Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER"* ]]; then
    pass "raw stable dns.env failure provides the exact rebuild instruction"
else
    fail "raw stable dns.env failure is not actionable: $raw_validation"
fi
grep -Fq 'Pre-v5 interception config detected' "$INSTALL" \
    && grep -Fq 'Do not delete it' "$INSTALL" \
    && grep -Fq "jq rebuild preserving SOCKS/TLS infrastructure" "$INSTALL" \
    && grep -Fq -- '--check-interception-routing to report ready' "$INSTALL" \
    && pass "interception v4 failure provides the lockstep v5 rebuild instruction" \
    || fail "interception v4 failure lacks the lockstep v5 rebuild instruction"
for recipe_token in \
    'set -euo pipefail' \
    'NEW_INSTALL_SH' \
    'old v4 daemon still owns the transaction' \
    'Disable MITM through the old authenticated API' \
    '.active_capture_hosts | length == 0' \
    'systemctl is-active --quiet 5gpn-intercept.service' \
    'listen: .listen' \
    'username: .username' \
    'password: .password' \
    'tls_cert: .tls_cert' \
    'tls_key: .tls_key' \
    'upstream_proxy: .upstream_proxy' \
    '.version == 4 and .mitm.enabled == false' \
    'enabled: false' \
    'execution_order: []' \
    'modules: []' \
    '"$NEW_5GPN_INTERCEPT" --config "$candidate" --check-config' \
    '"$NEW_5GPN_DNS" --check-interception-routing' \
    '--mihomo-config /etc/5gpn/mihomo/config.yaml' \
    '--intercept-config "$candidate"' \
    'sync -f "$candidate"' \
    'validate_dns_env_schema "$2"' \
    'config_published=1' \
    'env_published=1' \
    'committed=1' \
    'mv -fT -- "$candidate" "$old"' \
    'mv -fT -- "$env_candidate" "$env_file"'; do
    grep -Fq -- "$recipe_token" "$ROOT/README.md" \
        || fail "pre-v5 explicit rebuild recipe is missing: $recipe_token"
done

# Execute the publish-critical README segment with a routing checker that
# returns rc=3. Under the documented set -e contract, no live config or env
# publication may run after that failure.
recipe_critical="$(sed -n '/^if ! sudo "\$NEW_5GPN_INTERCEPT" --config "\$candidate" --check-config; then$/,/^trap - EXIT HUP INT TERM$/p' "$ROOT/README.md")"
recipe_test="$TMP/recipe-fail-closed"
mkdir -p "$recipe_test"
printf '%s\n' old-config > "$recipe_test/config.json"
printf '%s\n' candidate-config > "$recipe_test/candidate.json"
printf '%s\n' 'DNS_EGRESS_RESOLVER=203.0.113.53' keep=yes > "$recipe_test/dns.env"
cp -- "$recipe_test/config.json" "$recipe_test/config.before"
cp -- "$recipe_test/dns.env" "$recipe_test/dns.before"
cat > "$recipe_test/check-sidecar" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$recipe_test/check-routing" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' interception-egress-rules-out-of-sync
exit 3
EOF
chmod +x "$recipe_test/check-sidecar" "$recipe_test/check-routing"
recipe_rc=0
set +e
(
    set -euo pipefail
    sudo() { "$@"; }
    NEW_5GPN_INTERCEPT="$recipe_test/check-sidecar"
    NEW_5GPN_DNS="$recipe_test/check-routing"
    candidate="$recipe_test/candidate.json"
    old="$recipe_test/config.json"
    eval "$recipe_critical"
) >/dev/null 2>&1
recipe_rc=$?
set -e
if [[ "$recipe_rc" == 3 ]] \
   && cmp -s "$recipe_test/config.before" "$recipe_test/config.json" \
   && cmp -s "$recipe_test/dns.before" "$recipe_test/dns.env"; then
    pass "routing rc=3 aborts the documented rebuild before config/env publication"
else
    fail "routing rc=3 did not fail closed (rc=$recipe_rc)"
fi

fixture_keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$FIXTURE/dns.env.example" | sort)"
current_keys="$(for key in $DNS_ENV_KEYS; do printf '%s\n' "$key"; done | sort)"
raw_missing_keys="$(comm -23 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$fixture_keys"))"
raw_extra_keys="$(comm -13 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$fixture_keys"))"
expected_missing="$(printf '%s\n' DNS_INTERCEPT_CONFIG DNS_MARKETPLACES_FILE | sort)"
if [[ "$raw_missing_keys" == "$expected_missing" && "$raw_extra_keys" == DNS_EGRESS_RESOLVER \
   && "$(printf '%s\n' "$fixture_keys" | grep -c .)" == 51 ]]; then
    pass "raw stable key delta is the two additive files plus the retired resolver"
else
    fail "raw stable dns.env key delta is unexpected (missing='$raw_missing_keys', extra='$raw_extra_keys')"
fi

grep -v '^DNS_EGRESS_RESOLVER=' "$FIXTURE/dns.env.example" > "$CONF_DIR/dns.env"
if validate_dns_env_schema >/dev/null 2>&1; then
    pass "operator-rebuilt stable dns.env is accepted by the current strict schema"
else
    fail "operator-rebuilt stable dns.env was rejected by the current strict schema"
fi
rebuilt_keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$CONF_DIR/dns.env" | sort)"
rebuilt_missing_keys="$(comm -23 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$rebuilt_keys"))"
rebuilt_extra_keys="$(comm -13 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$rebuilt_keys"))"
if [[ "$rebuilt_missing_keys" == "$expected_missing" && -z "$rebuilt_extra_keys" \
   && "$(printf '%s\n' "$rebuilt_keys" | grep -c .)" == 50 ]]; then
    pass "rebuilt 0.0.13 dns.env lacks only the two additive beta keys"
else
    fail "rebuilt stable dns.env key delta is unexpected (missing='$rebuilt_missing_keys', extra='$rebuilt_extra_keys')"
fi

# Exercise the real current rendering function with harmless validators. A
# normal upgrade must validate and preserve the legacy operator file exactly.
fixture_conf="$CONF_DIR"
MIHOMO_DIR="$CONF_DIR/mihomo"
INTERCEPT_DIR="$CONF_DIR/intercept"
MIHOMO_BIN="$TMP/fake-mihomo"
INTERCEPT_BIN="$TMP/fake-intercept"
DNS_BIN="$TMP/fake-dns"
MIHOMO_SERVICE_USER="$(id -gn)"
DNS_SERVICE_USER="$(id -un)"
SCRIPT_DIR="$ROOT"
BASE_DOMAIN=example.com
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
mkdir -p "$MIHOMO_DIR" "$INTERCEPT_DIR"
printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
file_uid() {
    case "$1" in
        "$fixture_conf"|"$fixture_conf/$CONF_OWNERSHIP_MARKER"|"$fixture_conf/dns.env") printf '0\n' ;;
        *) stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true ;;
    esac
}
file_gid() {
    case "$1" in
        "$fixture_conf"|"$fixture_conf/$CONF_OWNERSHIP_MARKER") printf '0\n' ;;
        *) stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true ;;
    esac
}
file_mode() {
    case "$1" in
        "$fixture_conf") printf '755\n' ;;
        "$fixture_conf/$CONF_OWNERSHIP_MARKER") printf '644\n' ;;
        "$fixture_conf/dns.env") printf '640\n' ;;
        *) stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true ;;
    esac
}
cp -- "$FIXTURE/mihomo-config.yaml" "$MIHOMO_DIR/config.yaml"
printf '{}\n' > "$INTERCEPT_DIR/config.json"

cat > "$MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$INTERCEPT_BIN" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' --print-mihomo-fields '*)
        printf 'fixture-in-user-123456\tfixture-in-password-1234567890\tfixture-up-user-123456\tfixture-up-password-1234567890\n'
        exit 0 ;;
    *' --check-enabled '*) exit 3 ;;
esac
exit 1
EOF
cat > "$DNS_BIN" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == --print-mihomo-secret && "${2:-}" == --config && -f "${3:-}" ]]; then
    sed -n 's/^secret:[[:space:]]*//p' "$3"
    exit 0
fi
[[ "${1:-}" == --check-interception-routing ]] || exit 1
shift
mihomo=""
intercept=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mihomo-config) mihomo="$2"; shift 2 ;;
        --intercept-config) intercept="$2"; shift 2 ;;
        *) exit 1 ;;
    esac
done
[[ -f "$mihomo" && -f "$intercept" ]] || exit 1
if ! grep -Fq 'name: intercept-egress' "$mihomo"; then
    printf '%s\n' legacy-mihomo-boundary-missing-clean
    exit 3
fi
printf '%s\n' ready
EOF
chmod +x "$MIHOMO_BIN" "$INTERCEPT_BIN" "$DNS_BIN"

# The fixture address is intentionally non-routable and need not exist on the
# test host; only the renderer's structural output is under test.
local_ipv4_present() { return 0; }

legacy_hash="$(hash_file "$MIHOMO_DIR/config.yaml")"
if (
    runtime_directory_slot_is_safe() { return 0; }
    runtime_file_slot_is_safe() { return 0; }
    runtime_tree_has_only_plain_entries() { return 0; }
    seed_mihomo_whitelist() { return 0; }
    persist_mihomo_secret() { return 0; }
    install() { return 0; }
    render_mihomo_config
) >/dev/null 2>&1 \
   && [[ "$legacy_hash" == "$(hash_file "$MIHOMO_DIR/config.yaml")" ]] \
   && cmp -s "$FIXTURE/mihomo-config.yaml" "$MIHOMO_DIR/config.yaml"; then
    pass "normal beta rendering preserves the legacy mihomo config byte-for-byte"
else
    fail "normal beta rendering changed or rejected the legacy mihomo config"
fi

if check_interception_routing_compatibility >/dev/null 2>&1 \
   && [[ "$INTERCEPT_ROUTING_READY" == 0 \
      && "$INTERCEPT_ROUTING_REASON" == legacy-mihomo-boundary-missing-clean ]]; then
    pass "the installer compatibility seam classifies the preserved seed as legacy"
else
    fail "the installer compatibility seam did not classify the preserved seed as legacy"
fi

cat > "$TMP/fake-dns-residual" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --check-interception-routing ]]; then
    printf '%s\n' interception-egress-rules-out-of-sync
    exit 3
fi
exit 1
EOF
cat > "$TMP/fake-intercept-disabled" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' --check-config '*) exit 0 ;;
    *' --check-enabled '*) exit 3 ;;
esac
exit 1
EOF
chmod +x "$TMP/fake-dns-residual" "$TMP/fake-intercept-disabled"
saved_dns_bin="$DNS_BIN"
saved_intercept_bin="$INTERCEPT_BIN"
DNS_BIN="$TMP/fake-dns-residual"
INTERCEPT_BIN="$TMP/fake-intercept-disabled"
before_residual_mihomo="$(hash_file "$MIHOMO_DIR/config.yaml")"
before_residual_intercept="$(hash_file "$INTERCEPT_DIR/config.json")"
if check_interception_routing_compatibility >/dev/null 2>&1; then
    fail "disabled v5 with residual managed rules was allowed to degrade"
elif [[ "$INTERCEPT_ROUTING_REASON" == interception-egress-rules-out-of-sync \
     && "$before_residual_mihomo" == "$(hash_file "$MIHOMO_DIR/config.yaml")" \
     && "$before_residual_intercept" == "$(hash_file "$INTERCEPT_DIR/config.json")" ]]; then
    pass "residual managed rules hard-fail without changing mihomo/intercept bytes"
else
    fail "residual managed-rule preflight did not preserve bytes"
fi

saved_artifact_stage="${ARTIFACT_STAGE:-}"
ARTIFACT_STAGE="$TMP/residual-stage"
mkdir -p "$ARTIFACT_STAGE"
cp -- "$TMP/fake-dns-residual" "$ARTIFACT_STAGE/5gpn-dns"
cp -- "$TMP/fake-intercept-disabled" "$ARTIFACT_STAGE/5gpn-intercept"
if preflight_existing_interception_state >/dev/null 2>&1; then
    fail "target-release preflight accepted residual managed rules"
elif [[ "$before_residual_mihomo" == "$(hash_file "$MIHOMO_DIR/config.yaml")" \
     && "$before_residual_intercept" == "$(hash_file "$INTERCEPT_DIR/config.json")" ]]; then
    pass "target-release preflight aborts residual rules before publication"
else
    fail "target-release residual preflight changed live bytes"
fi
ARTIFACT_STAGE="$saved_artifact_stage"
DNS_BIN="$saved_dns_bin"
INTERCEPT_BIN="$saved_intercept_bin"

full_install_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
preflight_line="$(grep -n 'preflight_existing_interception_state' <<<"$full_install_fn" | head -1 | cut -d: -f1)"
snapshot_line="$(grep -n 'capture_install_rollback' <<<"$full_install_fn" | head -1 | cut -d: -f1)"
publish_line="$(grep -n 'install_5gpndns' <<<"$full_install_fn" | head -1 | cut -d: -f1)"
if [[ -n "$preflight_line" && -n "$snapshot_line" && -n "$publish_line" \
   && "$preflight_line" -lt "$snapshot_line" && "$preflight_line" -lt "$publish_line" ]]; then
    pass "interception routing preflight runs before rollback snapshot and live publication"
else
    fail "interception routing preflight is too late in full_install"
fi

cat > "$TMP/fake-intercept-active" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' --check-enabled '*) exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/fake-intercept-active"
saved_intercept_bin="$INTERCEPT_BIN"
INTERCEPT_BIN="$TMP/fake-intercept-active"
if check_interception_routing_compatibility >/dev/null 2>&1; then
    fail "an active interception config was allowed with legacy mihomo routing"
else
    pass "active interception fails closed on a legacy mihomo boundary"
fi
INTERCEPT_BIN="$saved_intercept_bin"
cat > "$TMP/fake-intercept-broken" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' --check-enabled '*) exit 1 ;;
esac
exit 1
EOF
chmod +x "$TMP/fake-intercept-broken"
INTERCEPT_BIN="$TMP/fake-intercept-broken"
if check_interception_routing_compatibility >/dev/null 2>&1; then
    fail "an invalid interception enabled-state check was treated as disabled"
else
    pass "invalid interception enabled-state checks fail closed"
fi
INTERCEPT_BIN="$saved_intercept_bin"

# The explicit reset path is the only allowed replacement. It must retain an
# exact backup and add all three routing boundaries needed by interception.
if (
    runtime_directory_slot_is_safe() { return 0; }
    runtime_file_slot_is_safe() { return 0; }
    runtime_tree_has_only_plain_entries() { return 0; }
    seed_mihomo_whitelist() { return 0; }
    persist_mihomo_secret() { return 0; }
    install() { return 0; }
    BASE_DIR="$TMP/reset-runtime"
    mkdir -p "$BASE_DIR/etc/mihomo"
    cp -- "$ROOT/etc/mihomo/config.yaml.tmpl" "$BASE_DIR/etc/mihomo/config.yaml.tmpl"
    render_mihomo_config --reset
) >/dev/null 2>&1; then
    backups=("$MIHOMO_DIR"/config.yaml.bak.*)
    if [[ "${#backups[@]}" == 1 && -f "${backups[0]}" ]] \
       && cmp -s "$FIXTURE/mihomo-config.yaml" "${backups[0]}" \
       && grep -Fq 'name: intercept-egress' "$MIHOMO_DIR/config.yaml" \
       && grep -Fq 'name: MODULE-INTERCEPT' "$MIHOMO_DIR/config.yaml" \
       && grep -Fq -- '- IN-NAME,intercept-egress,REJECT' "$MIHOMO_DIR/config.yaml" \
       && check_interception_routing_compatibility >/dev/null 2>&1 \
       && [[ "$INTERCEPT_ROUTING_READY" == 1 ]]; then
        pass "explicit reset backs up the legacy bytes and installs the interception scaffold"
    else
        fail "explicit reset backup or interception scaffold is incomplete"
    fi
else
    fail "explicit reset rejected the 0.0.13 legacy fixture"
fi

# Every fixed-root claim is a transaction boundary. Verify each possible
# failure is returned immediately instead of being hidden by a later success.
claim_failures_propagate=1
for fail_at in 1 2 3; do
    if ! (
        calls=0
        claim_fixed_owned_dir() {
            calls=$((calls + 1))
            [[ "$calls" -ne "$fail_at" ]]
        }
        if claim_project_roots; then
            exit 1
        fi
        [[ "$calls" == "$fail_at" ]]
    ); then
        claim_failures_propagate=0
    fi
done
if [[ "$claim_failures_propagate" == 1 ]]; then
    pass "claim_project_roots propagates failure from every root boundary"
else
    fail "claim_project_roots hid or continued past a root claim failure"
fi
claim_fixed_fn="$(sed -n '/^claim_fixed_owned_dir()/,/^}/p' "$INSTALL")"
grep -Fq 'install -d -o root -g root -m 0755 -- "$dir"' <<<"$claim_fixed_fn" \
    && grep -Fq 'chmod g-s -- "$dir"' <<<"$claim_fixed_fn" \
    && grep -Fq 'chmod 0755 -- "$dir"' <<<"$claim_fixed_fn" \
    || fail "fresh fixed roots can inherit a setgid parent service group"
pass "fresh fixed roots force root ownership below setgid parents"
intercept_claim_failures_propagate=1
for fail_at in 1 2; do
    if ! (
        calls=0
        claim_fixed_owned_dir() {
            calls=$((calls + 1))
            [[ "$calls" -ne "$fail_at" ]]
        }
        if claim_intercept_roots; then
            exit 1
        fi
        [[ "$calls" == "$fail_at" ]]
    ); then
        intercept_claim_failures_propagate=0
    fi
done
if [[ "$intercept_claim_failures_propagate" == 1 ]]; then
    pass "claim_intercept_roots propagates failure from every new root boundary"
else
    fail "claim_intercept_roots hid or continued past a root claim failure"
fi

# A stable installation has neither interception root. Capture that absence,
# create both roots during publication, then exercise the rollback helpers.
ROLLBACK_DIR="$TMP/rollback"
INTERCEPT_CA_DIR="$TMP/unowned-intercept-ca"
INTERCEPT_STATE_DIR="$TMP/unowned-intercept-state"
mkdir -p "$INTERCEPT_CA_DIR"
printf 'operator data\n' > "$INTERCEPT_CA_DIR/keep"
if preflight_intercept_roots >/dev/null 2>&1; then
    fail "preflight adopted an unowned interception root"
elif [[ "$(cat "$INTERCEPT_CA_DIR/keep")" == 'operator data' ]]; then
    pass "preflight refuses and preserves an unowned interception root"
else
    fail "preflight changed an unowned interception root"
fi
INTERCEPT_CA_DIR="$TMP/optional-intercept-ca"
INTERCEPT_STATE_DIR="$TMP/optional-intercept-state"
mkdir -p "$ROLLBACK_DIR"
saved_fixed_owned_dir_is_safe="$(declare -f fixed_owned_dir_is_safe)"
saved_unmarked_fixed_dir_is_safe_to_claim="$(declare -f unmarked_fixed_dir_is_safe_to_claim)"
fixed_owned_dir_is_safe() { return 0; }
unmarked_fixed_dir_is_safe_to_claim() { return 0; }
# The production installer runs as root. This non-root fixture keeps its focus
# on rollback semantics while accepting the exact root-owned creation request.
install() {
    if [[ "$#" == 9 && "$1" == -d && "$2" == -o && "$3" == root \
       && "$4" == -g && "$5" == root && "$6" == -m && "$7" == 0755 \
       && "$8" == -- ]]; then
        command install -d -m 0755 -- "$9"
        return
    fi
    command install "$@"
}
optional_snapshot_ok=1
capture_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
    "$INTERCEPT_CA_MARKER_VALUE" intercept-ca || optional_snapshot_ok=0
capture_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
    "$INTERCEPT_STATE_MARKER_VALUE" intercept-state || optional_snapshot_ok=0
[[ -f "$ROLLBACK_DIR/intercept-ca.absent" \
   && -f "$ROLLBACK_DIR/intercept-state.absent" ]] || optional_snapshot_ok=0
claim_intercept_roots >/dev/null 2>&1 || optional_snapshot_ok=0
unset -f install
rollback_host_failed=0
rollback_state_failed=0
restore_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
    "$INTERCEPT_CA_MARKER_VALUE" intercept-ca rollback_host_failed
restore_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
    "$INTERCEPT_STATE_MARKER_VALUE" intercept-state rollback_state_failed
eval "$saved_fixed_owned_dir_is_safe"
eval "$saved_unmarked_fixed_dir_is_safe_to_claim"
if [[ "$optional_snapshot_ok" == 1 && "$rollback_host_failed" == 0 \
   && "$rollback_state_failed" == 0 \
   && ! -e "$INTERCEPT_CA_DIR" && ! -L "$INTERCEPT_CA_DIR" \
   && ! -e "$INTERCEPT_STATE_DIR" && ! -L "$INTERCEPT_STATE_DIR" ]]; then
    pass "rollback restores absent interception roots to absence"
else
    fail "rollback left a newly created interception root behind"
fi

# Service accounts created by a failed transaction are removed only through
# the run-local creation registry; pre-existing accounts never enter it.
if (
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd)
                if [[ "$#" == 2 ]]; then
                    printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                else
                    printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                    printf 'other-service:x:997:999::/nonexistent:/usr/sbin/nologin\n'
                fi
                ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g) printf '999\n' ;;
            -G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    ! service_account_is_safe gpn-test gpn-test
); then
    pass "service account validation rejects another passwd user sharing the primary GID"
else
    fail "service account validation ignored a shared primary GID"
fi
if (
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd)
                if [[ "$#" == 2 ]]; then
                    printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                else
                    printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                    printf 'uid-alias:x:998:997::/nonexistent:/usr/sbin/nologin\n'
                fi
                ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    ! service_account_is_safe gpn-test gpn-test
); then
    pass "service account validation rejects a duplicate numeric UID"
else
    fail "service account validation accepted a duplicate numeric UID"
fi
if (
    getent() {
        case "$1" in
            group)
                if [[ "$#" == 2 ]]; then
                    printf 'gpn-test:x:999:\n'
                else
                    printf 'gpn-test:x:999:\n'
                    printf 'gid-alias:x:999:other-user\n'
                fi
                ;;
            passwd) printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    ! service_account_is_safe gpn-test gpn-test
); then
    pass "service account validation rejects a duplicate numeric GID alias"
else
    fail "service account validation accepted a duplicate numeric GID alias"
fi
if (
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd) printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g) printf '999\n' ;;
            -G) printf '999 1000\n' ;;
            *) return 1 ;;
        esac
    }
    ! service_account_is_safe gpn-test gpn-test
); then
    pass "service account validation rejects unexpected supplementary groups"
else
    fail "service account validation accepted an unexpected supplementary group"
fi
if (
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd) printf 'gpn-test:x:0:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    ! service_account_is_safe gpn-test gpn-test
); then
    pass "service account validation rejects a UID-zero account alias"
else
    fail "service account validation accepted a root-equivalent account"
fi
if (
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd) printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    id() {
        case "$1" in
            -gn) printf 'gpn-test\n' ;;
            -g|-G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    service_account_is_safe gpn-test gpn-test
); then
    pass "an isolated system service account remains valid"
else
    fail "service account validation rejected the isolated control account"
fi
if (
    calls="$TMP/account-shared-primary.log"
    getent() {
        case "$1" in
            group) printf 'gpn-test:x:999:\n' ;;
            passwd)
                if [[ "$#" == 2 ]]; then
                    return 1
                fi
                printf 'other-service:x:997:999::/nonexistent:/usr/sbin/nologin\n'
                ;;
            *) return 1 ;;
        esac
    }
    groupadd() { printf 'unexpected-groupadd\n' >> "$calls"; }
    useradd() { printf 'unexpected-useradd\n' >> "$calls"; }
    groupdel() { printf 'unexpected-groupdel\n' >> "$calls"; }
    userdel() { printf 'unexpected-userdel\n' >> "$calls"; }
    ! ensure_service_account gpn-test gpn-test && [[ ! -e "$calls" ]]
); then
    pass "service account creation refuses a group used as another user's primary group"
else
    fail "service account creation adopted a shared primary group"
fi
if (
    group_exists=0
    user_exists=0
    getent() {
        case "$1" in
            group) [[ "$group_exists" == 1 ]] && printf 'gpn-intercept:x:999:\n' ;;
            passwd) [[ "$user_exists" == 1 ]] && printf 'gpn-intercept:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    groupadd() { group_exists=1; }
    useradd() { user_exists=1; }
    groupdel() { group_exists=0; }
    userdel() { user_exists=0; }
    service_group_is_exclusive_for_user() { [[ "$group_exists" == 1 ]]; }
    service_account_is_safe() { [[ "$user_exists" == 1 && "$group_exists" == 1 ]]; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    created_user=0
    created_group=0
    created_uid=""
    created_gid=""
    ensure_service_account gpn-intercept gpn-intercept created_user created_group created_uid created_gid
    [[ "$created_user" == 1 && "$created_group" == 1 \
       && "$created_uid" == 998 && "$created_gid" == 999 ]]
); then
    pass "service account creation reports the exact resources and IDs created by the call"
else
    fail "service account creation did not report its own mutation results"
fi
if (
    CREATED_SERVICE_ACCOUNT_USERS=()
    CREATED_SERVICE_ACCOUNT_GROUPS=()
    CREATED_SERVICE_ACCOUNT_UIDS=()
    CREATED_SERVICE_ACCOUNT_GIDS=()
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
    group_exists=0
    getent() {
        case "$1" in
            group) [[ "$group_exists" == 1 ]] && printf 'gpn-test:x:999:\n' ;;
            passwd) [[ "$#" == 1 ]] && printf 'root:x:0:0::/root:/bin/bash\n' ;;
            *) return 1 ;;
        esac
    }
    groupadd() { group_exists=1; }
    groupdel() { return 1; }
    service_group_is_exclusive_for_user() { return 1; }
    ! install_service_account gpn-test gpn-test \
        && [[ "$group_exists" == 1 \
           && "${#CREATED_SERVICE_ACCOUNT_USERS[@]}" == 1 \
           && "${CREATED_SERVICE_ACCOUNT_USERS[0]}" == gpn-test \
           && "${CREATED_SERVICE_ACCOUNT_UIDS[0]}" == '' \
           && "${CREATED_SERVICE_ACCOUNT_GIDS[0]}" == 999 \
           && "${CREATED_SERVICE_ACCOUNT_USER_FLAGS[0]}" == 0 \
           && "${CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[0]}" == 1 ]]
); then
    pass "a newly created group remains registered when immediate cleanup fails"
else
    fail "failed group cleanup left an unregistered service group"
fi
if (
    CREATED_SERVICE_ACCOUNT_USERS=()
    CREATED_SERVICE_ACCOUNT_GROUPS=()
    CREATED_SERVICE_ACCOUNT_UIDS=()
    CREATED_SERVICE_ACCOUNT_GIDS=()
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
    group_exists=0
    user_exists=0
    getent() {
        case "$1" in
            group) [[ "$group_exists" == 1 ]] && printf 'gpn-test:x:999:\n' ;;
            passwd)
                if [[ "$#" == 2 ]]; then
                    [[ "$user_exists" == 1 ]] \
                        && printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                else
                    printf 'root:x:0:0::/root:/bin/bash\n'
                    [[ "$user_exists" == 0 ]] \
                        || printf 'gpn-test:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                fi
                ;;
            *) return 1 ;;
        esac
    }
    groupadd() { group_exists=1; }
    useradd() { user_exists=1; }
    groupdel() { return 1; }
    userdel() { return 1; }
    service_group_is_exclusive_for_user() { return 0; }
    service_account_is_safe() { return 1; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    ! install_service_account gpn-test gpn-test \
        && [[ "$group_exists" == 1 && "$user_exists" == 1 \
           && "${#CREATED_SERVICE_ACCOUNT_USERS[@]}" == 1 \
           && "${CREATED_SERVICE_ACCOUNT_USERS[0]}" == gpn-test \
           && "${CREATED_SERVICE_ACCOUNT_UIDS[0]}" == 998 \
           && "${CREATED_SERVICE_ACCOUNT_GIDS[0]}" == 999 \
           && "${CREATED_SERVICE_ACCOUNT_USER_FLAGS[0]}" == 1 \
           && "${CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[0]}" == 1 ]]
); then
    pass "a newly created user and group remain registered when post-check cleanup fails"
else
    fail "failed user cleanup left an unregistered service account"
fi
if (
    DNS_SERVICE_USER=gpn-dns
    MIHOMO_SERVICE_USER=mihomo
    INTERCEPT_SERVICE_USER=gpn-intercept
    CREATED_SERVICE_ACCOUNT_USERS=()
    CREATED_SERVICE_ACCOUNT_GROUPS=()
    CREATED_SERVICE_ACCOUNT_UIDS=()
    CREATED_SERVICE_ACCOUNT_GIDS=()
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
    ensure_service_account() {
        if [[ "$1" == gpn-intercept ]]; then
            printf -v "$3" '%s' 1
            printf -v "$4" '%s' 0
            printf -v "$5" '%s' 998
            printf -v "$6" '%s' 777
        fi
    }
    install_service_accounts >/dev/null
    [[ "${#CREATED_SERVICE_ACCOUNT_USERS[@]}" == 1 \
       && "${CREATED_SERVICE_ACCOUNT_USERS[0]}" == gpn-intercept \
       && "${CREATED_SERVICE_ACCOUNT_GROUPS[0]}" == gpn-intercept \
       && "${CREATED_SERVICE_ACCOUNT_UIDS[0]}" == 998 \
       && "${CREATED_SERVICE_ACCOUNT_GIDS[0]}" == 777 \
       && "${CREATED_SERVICE_ACCOUNT_USER_FLAGS[0]}" == 1 \
       && "${CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[0]}" == 0 ]]
); then
    pass "new service users are recorded generically with their actual primary GID"
else
    fail "generic service-account creation tracking is incomplete"
fi
if (
    DNS_SERVICE_USER=gpn-dns
    MIHOMO_SERVICE_USER=mihomo
    INTERCEPT_SERVICE_USER=gpn-intercept
    CREATED_SERVICE_ACCOUNT_USERS=()
    CREATED_SERVICE_ACCOUNT_GROUPS=()
    CREATED_SERVICE_ACCOUNT_UIDS=()
    CREATED_SERVICE_ACCOUNT_GIDS=()
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
    ensure_service_account() {
        local uid
        case "$1" in
            gpn-dns) uid=995 ;;
            mihomo) uid=996 ;;
            gpn-intercept) uid=997 ;;
            *) return 1 ;;
        esac
        printf -v "$3" '%s' 1
        printf -v "$4" '%s' 1
        printf -v "$5" '%s' "$uid"
        printf -v "$6" '%s' "$uid"
    }
    install_service_accounts >/dev/null
    [[ "${#CREATED_SERVICE_ACCOUNT_USERS[@]}" == 3 \
       && "${CREATED_SERVICE_ACCOUNT_USERS[*]}" == 'gpn-dns mihomo gpn-intercept' \
       && "${CREATED_SERVICE_ACCOUNT_GROUPS[*]}" == 'gpn-dns mihomo gpn-intercept' \
       && "${CREATED_SERVICE_ACCOUNT_UIDS[*]}" == '995 996 997' \
       && "${CREATED_SERVICE_ACCOUNT_GIDS[*]}" == '995 996 997' \
       && "${CREATED_SERVICE_ACCOUNT_USER_FLAGS[*]}" == '1 1 1' \
       && "${CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[*]}" == '1 1 1' ]]
); then
    pass "all newly created service accounts are registered for failed-install rollback"
else
    fail "service-account tracking omitted a newly created runtime account"
fi
if (
    calls="$TMP/account-rollback.log"
    user_exists=1
    group_exists=1
    CREATED_SERVICE_ACCOUNT_USERS=(gpn-intercept)
    CREATED_SERVICE_ACCOUNT_GROUPS=(gpn-intercept)
    CREATED_SERVICE_ACCOUNT_UIDS=(998)
    CREATED_SERVICE_ACCOUNT_GIDS=(999)
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=(1)
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=(1)
    service_account_is_safe() { return 0; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            -G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    userdel() { printf 'userdel:%s\n' "$1" >> "$calls"; user_exists=0; }
    getent() {
        case "${1:-}" in
            group) [[ "$group_exists" == 1 ]] && printf 'gpn-intercept:x:999:\n' ;;
            passwd)
                if [[ "$#" == 2 ]]; then
                    [[ "$user_exists" == 1 ]] \
                        && printf 'gpn-intercept:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                else
                    printf 'root:x:0:0::/root:/bin/bash\n'
                    [[ "$user_exists" == 0 ]] \
                        || printf 'gpn-intercept:x:998:999::/nonexistent:/usr/sbin/nologin\n'
                fi
                ;;
            *) return 1 ;;
        esac
    }
    groupdel() { printf 'groupdel:%s\n' "$1" >> "$calls"; group_exists=0; }
    failed=0
    rollback_created_service_accounts failed
    [[ "$failed" == 0 && "${#CREATED_SERVICE_ACCOUNT_USERS[@]}" == 0 \
       && "$(tr '\n' ' ' < "$calls")" == 'userdel:gpn-intercept groupdel:gpn-intercept ' ]]
); then
    pass "failed-install rollback removes only the service account created by that run"
else
    fail "failed-install service-account rollback is incomplete"
fi
if (
    calls="$TMP/account-group-only-rollback.log"
    group_exists=1
    CREATED_SERVICE_ACCOUNT_USERS=(gpn-test)
    CREATED_SERVICE_ACCOUNT_GROUPS=(gpn-test)
    CREATED_SERVICE_ACCOUNT_UIDS=('')
    CREATED_SERVICE_ACCOUNT_GIDS=(999)
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=(0)
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=(1)
    getent() {
        case "${1:-}" in
            group) [[ "$group_exists" == 1 ]] && printf 'gpn-test:x:999:\n' ;;
            passwd) printf 'root:x:0:0::/root:/bin/bash\n' ;;
            *) return 1 ;;
        esac
    }
    groupdel() { printf 'groupdel:%s\n' "$1" >> "$calls"; group_exists=0; }
    failed=0
    rollback_created_service_accounts failed
    [[ "$failed" == 0 && "$group_exists" == 0 \
       && "$(cat "$calls")" == 'groupdel:gpn-test' ]]
); then
    pass "failed-install rollback removes a group created before user creation failed"
else
    fail "failed-install rollback left a group-only creation behind"
fi
if (
    calls="$TMP/account-gid-mismatch.log"
    CREATED_SERVICE_ACCOUNT_USERS=(gpn-intercept)
    CREATED_SERVICE_ACCOUNT_GROUPS=(gpn-intercept)
    CREATED_SERVICE_ACCOUNT_UIDS=(998)
    CREATED_SERVICE_ACCOUNT_GIDS=(999)
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=(1)
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=(0)
    service_account_is_safe() { return 0; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g|-G) printf '997\n' ;;
            *) return 1 ;;
        esac
    }
    getent() {
        case "${1:-}" in
            passwd) printf 'gpn-intercept:x:998:997::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    userdel() { printf 'unexpected\n' >> "$calls"; }
    failed=0
    rollback_created_service_accounts failed
    [[ "$failed" == 1 && ! -e "$calls" ]]
); then
    pass "service-account rollback refuses a changed primary GID"
else
    fail "service-account rollback ignored a changed primary GID"
fi

# The destructive upgrade mode refuses non-interactive execution before the
# install transaction or mihomo reset begins.
if confirm_upgrade_mihomo_reset >/dev/null 2>&1; then
    fail "upgrade-reset-mihomo accepted a non-interactive session"
else
    pass "upgrade-reset-mihomo requires an interactive TTY"
fi

# A hostile or concurrent replacement of the nested CA root must never be
# deleted merely because the parent config root still has its own marker.
saved_conf_dir="$CONF_DIR"
saved_rollback_dir="$ROLLBACK_DIR"
CONF_DIR="$TMP/conf-race"
ROLLBACK_DIR="$TMP/rollback-race"
mkdir -p "$CONF_DIR/intercept-ca" "$ROLLBACK_DIR/conf"
write_ownership_marker "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
write_ownership_marker "$ROLLBACK_DIR/conf" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
chmod 2771 "$CONF_DIR"
chmod 0700 "$ROLLBACK_DIR/conf"
printf 'live unowned sentinel\n' > "$CONF_DIR/intercept-ca/keep"
printf 'old config\n' > "$ROLLBACK_DIR/conf/restored"
: > "$ROLLBACK_DIR/intercept-ca.absent"
nested_failed=0
restore_config_root_without_intercept_ca nested_failed
restore_optional_owned_root "$CONF_DIR/intercept-ca" "$INTERCEPT_CA_MARKER" \
    "$INTERCEPT_CA_MARKER_VALUE" intercept-ca nested_failed
if [[ "$nested_failed" == 1 \
   && "$(cat "$CONF_DIR/intercept-ca/keep")" == 'live unowned sentinel' \
   && "$(cat "$CONF_DIR/restored")" == 'old config' \
   && "$(file_mode "$CONF_DIR")" == 700 ]]; then
    pass "parent config rollback preserves a changed unowned nested CA root"
else
    fail "parent config rollback deleted or overwrote an unowned nested CA root"
fi
CONF_DIR="$saved_conf_dir"
ROLLBACK_DIR="$saved_rollback_dir"

# Purge retains the CA for already enrolled devices. Keep this assertion tied
# to the actual clear_owned_scope preserve arguments in uninstall().
uninstall_body="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
if grep -Fq 'cert acme debug-cert intercept-ca \' <<< "$uninstall_body"; then
    pass "purge preserve list retains intercept-ca"
else
    fail "purge preserve list would delete intercept-ca"
fi
purge_root="$TMP/purge-conf"
mkdir -p "$purge_root"/{cert,acme,debug-cert,intercept-ca,remove-me}
write_ownership_marker "$purge_root" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
if clear_owned_scope "$purge_root" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
    "$purge_root" "$CONF_OWNERSHIP_MARKER" cert acme debug-cert intercept-ca \
    && [[ -d "$purge_root/intercept-ca" && ! -e "$purge_root/remove-me" ]]; then
    pass "purge behavior preserves interception CA state"
else
    fail "purge behavior removed interception CA state"
fi

# quick-install intentionally retains all post-channel arguments and passes
# them to the verified bundle installer. These two statements form the direct
# forwarding path for `--beta upgrade-reset-mihomo`.
quick_main="$(sed -n '/^main()/,/^}/p' "$QUICK")"
if grep -Fq 'install_args=("$@")' <<< "$quick_main" \
   && grep -Fq 'install_args=(--beta "${install_args[@]}")' <<< "$quick_main" \
   && grep -Fq 'exec bash ./install.sh "${install_args[@]}"' <<< "$quick_main" \
   && grep -Fq 'upgrade-reset-mihomo' "$QUICK"; then
    pass "quick installer forwards --beta upgrade-reset-mihomo to the verified bundle"
else
    fail "quick installer drops or rewrites upgrade-reset-mihomo"
fi
manage_fn="$(sed -n '/^install_manage_cli()/,/^}/p' "$INSTALL")"
delegate_fn="$(sed -n '/^delegate_pinned_channel_switch()/,/^}/p' "$INSTALL")"
if grep -Fq 'publish_executable "$quick_source" "${BASE_DIR}/quick-install.sh"' <<< "$manage_fn" \
   && grep -Fq 'file_uid "$quick"' <<< "$delegate_fn" \
   && grep -Fq 'file_mode "$quick"' <<< "$delegate_fn" \
   && grep -Fq 'file_uid "$BASE_DIR"' <<< "$delegate_fn" \
   && grep -Fq 'file_mode "$BASE_DIR"' <<< "$delegate_fn" \
   && grep -Fq 'owned_root_canonical "$BASE_DIR"' <<< "$delegate_fn" \
   && grep -Fq 'exec bash "$quick" "${args[@]}"' <<< "$delegate_fn"; then
    pass "future installed stable scripts retain and verify the quick channel handoff"
else
    fail "installed stable channel handoff is incomplete"
fi
if (
    SCRIPT_DIR="$TMP/unsafe-handoff"
    mkdir -p "$SCRIPT_DIR"
    : > "$SCRIPT_DIR/quick-install.sh"
    DNS_VERSION_DEFAULT=0.0.13
    DNS_RELEASE_CHANNEL_EXPLICIT=1
    DNS_RELEASE_CHANNEL=beta
    file_uid() { printf '0\n'; }
    file_mode() { printf '777\n'; }
    ! delegate_pinned_channel_switch >/dev/null 2>&1
); then
    pass "channel handoff rejects a root-owned but group/world-writable quick installer"
else
    fail "channel handoff accepted a writable quick installer"
fi
if (
    BASE_DIR="$TMP/unsafe-runtime-root"
    SCRIPT_DIR="$BASE_DIR"
    mkdir -p "$BASE_DIR"
    write_ownership_marker "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
    : > "$BASE_DIR/quick-install.sh"
    DNS_VERSION_DEFAULT=0.0.13
    DNS_RELEASE_CHANNEL_EXPLICIT=1
    DNS_RELEASE_CHANNEL=beta
    file_uid() { printf '0\n'; }
    file_mode() {
        if [[ "$1" == "$BASE_DIR" ]]; then printf '777\n'; else printf '644\n'; fi
    }
    ! delegate_pinned_channel_switch >/dev/null 2>&1
); then
    pass "channel handoff rejects a group/world-writable installed runtime root"
else
    fail "channel handoff accepted a writable installed runtime root"
fi

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "test_upgrade_from_stable: PASS"
else
    echo "test_upgrade_from_stable: FAIL"
    exit 1
fi
