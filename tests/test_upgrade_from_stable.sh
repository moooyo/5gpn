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

# The frozen stable environment must remain valid under the beta parser. Its
# complete key set differs from the current contract only by the two beta files.
CONF_DIR="$TMP/conf"
mkdir -p "$CONF_DIR"
cp -- "$FIXTURE/dns.env.example" "$CONF_DIR/dns.env"
if validate_dns_env_schema >/dev/null 2>&1; then
    pass "0.0.13 dns.env is accepted by the current strict schema"
else
    fail "0.0.13 dns.env was rejected by the current strict schema"
fi

fixture_keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$FIXTURE/dns.env.example" | sort)"
current_keys="$(for key in $DNS_ENV_KEYS; do printf '%s\n' "$key"; done | sort)"
missing_keys="$(comm -23 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$fixture_keys"))"
extra_keys="$(comm -13 <(printf '%s\n' "$current_keys") <(printf '%s\n' "$fixture_keys"))"
expected_missing="$(printf '%s\n' DNS_INTERCEPT_CONFIG DNS_MARKETPLACES_FILE | sort)"
if [[ "$missing_keys" == "$expected_missing" && -z "$extra_keys" \
   && "$(printf '%s\n' "$fixture_keys" | grep -c .)" == 51 ]]; then
    pass "0.0.13 dns.env lacks only the two additive beta keys"
else
    fail "0.0.13 dns.env key delta is unexpected (missing='$missing_keys', extra='$extra_keys')"
fi

# Exercise the real current rendering function with harmless validators. A
# normal upgrade must validate and preserve the legacy operator file exactly.
MIHOMO_DIR="$TMP/mihomo"
INTERCEPT_DIR="$TMP/intercept"
MIHOMO_BIN="$TMP/fake-mihomo"
INTERCEPT_BIN="$TMP/fake-intercept"
DNS_BIN="$TMP/fake-dns"
MIHOMO_SERVICE_USER="$(id -gn)"
SCRIPT_DIR="$ROOT"
BASE_DOMAIN=example.com
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
mkdir -p "$MIHOMO_DIR" "$INTERCEPT_DIR"
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
    printf '%s\n' interception-listener-missing
    exit 3
fi
printf '%s\n' ready
EOF
chmod +x "$MIHOMO_BIN" "$INTERCEPT_BIN" "$DNS_BIN"

# The fixture address is intentionally non-routable and need not exist on the
# test host; only the renderer's structural output is under test.
local_ipv4_present() { return 0; }

legacy_hash="$(hash_file "$MIHOMO_DIR/config.yaml")"
if render_mihomo_config >/dev/null 2>&1 \
   && [[ "$legacy_hash" == "$(hash_file "$MIHOMO_DIR/config.yaml")" ]] \
   && cmp -s "$FIXTURE/mihomo-config.yaml" "$MIHOMO_DIR/config.yaml"; then
    pass "normal beta rendering preserves the legacy mihomo config byte-for-byte"
else
    fail "normal beta rendering changed or rejected the legacy mihomo config"
fi

if check_interception_routing_compatibility >/dev/null 2>&1 \
   && [[ "$INTERCEPT_ROUTING_READY" == 0 \
      && "$INTERCEPT_ROUTING_REASON" == interception-listener-missing ]]; then
    pass "the installer compatibility seam classifies the preserved seed as legacy"
else
    fail "the installer compatibility seam did not classify the preserved seed as legacy"
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
if render_mihomo_config --reset >/dev/null 2>&1; then
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
optional_snapshot_ok=1
capture_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
    "$INTERCEPT_CA_MARKER_VALUE" intercept-ca || optional_snapshot_ok=0
capture_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
    "$INTERCEPT_STATE_MARKER_VALUE" intercept-state || optional_snapshot_ok=0
[[ -f "$ROLLBACK_DIR/intercept-ca.absent" \
   && -f "$ROLLBACK_DIR/intercept-state.absent" ]] || optional_snapshot_ok=0
claim_intercept_roots >/dev/null 2>&1 || optional_snapshot_ok=0
rollback_host_failed=0
rollback_state_failed=0
restore_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
    "$INTERCEPT_CA_MARKER_VALUE" intercept-ca rollback_host_failed
restore_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
    "$INTERCEPT_STATE_MARKER_VALUE" intercept-state rollback_state_failed
if [[ "$optional_snapshot_ok" == 1 && "$rollback_host_failed" == 0 \
   && "$rollback_state_failed" == 0 \
   && ! -e "$INTERCEPT_CA_DIR" && ! -L "$INTERCEPT_CA_DIR" \
   && ! -e "$INTERCEPT_STATE_DIR" && ! -L "$INTERCEPT_STATE_DIR" ]]; then
    pass "rollback restores absent interception roots to absence"
else
    fail "rollback left a newly created interception root behind"
fi

# Service accounts created by a failed transaction are removed only through
# the explicit run-local flags; pre-existing accounts never set those flags.
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
    service_account_is_safe() { [[ "$user_exists" == 1 && "$group_exists" == 1 ]]; }
    created_user=0
    created_group=0
    ensure_service_account gpn-intercept gpn-intercept created_user created_group
    [[ "$created_user" == 1 && "$created_group" == 1 ]]
); then
    pass "service account creation reports the exact resources created by the call"
else
    fail "service account creation did not report its own mutation results"
fi
if (
    DNS_SERVICE_USER=gpn-dns
    MIHOMO_SERVICE_USER=mihomo
    INTERCEPT_SERVICE_USER=gpn-intercept
    INTERCEPT_USER_CREATED_THIS_RUN=0
    INTERCEPT_GROUP_CREATED_THIS_RUN=0
    INTERCEPT_CREATED_UID=""
    INTERCEPT_CREATED_GID=""
    ensure_service_account() {
        if [[ "$1" == gpn-intercept ]]; then
            printf -v "$3" '%s' 1
            printf -v "$4" '%s' 0
        fi
    }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '777\n' ;;
            *) return 1 ;;
        esac
    }
    install_service_accounts >/dev/null
    [[ "$INTERCEPT_USER_CREATED_THIS_RUN" == 1 \
       && "$INTERCEPT_GROUP_CREATED_THIS_RUN" == 0 \
       && "$INTERCEPT_CREATED_UID" == 998 \
       && "$INTERCEPT_CREATED_GID" == 777 ]]
); then
    pass "new interception users record their actual pre-existing primary GID"
else
    fail "interception user creation did not record its primary GID"
fi
if (
    calls="$TMP/account-rollback.log"
    INTERCEPT_SERVICE_USER=gpn-intercept
    INTERCEPT_USER_CREATED_THIS_RUN=1
    INTERCEPT_GROUP_CREATED_THIS_RUN=1
    INTERCEPT_CREATED_UID=998
    INTERCEPT_CREATED_GID=999
    service_account_is_safe() { return 0; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g) printf '999\n' ;;
            -G) printf '999\n' ;;
            *) return 1 ;;
        esac
    }
    userdel() { printf 'userdel:%s\n' "$1" >> "$calls"; }
    getent() {
        case "${1:-}" in
            group) printf 'gpn-intercept:x:999:\n' ;;
            passwd) return 0 ;;
            *) return 1 ;;
        esac
    }
    groupdel() { printf 'groupdel:%s\n' "$1" >> "$calls"; }
    failed=0
    rollback_created_intercept_account failed
    [[ "$failed" == 0 && "$INTERCEPT_USER_CREATED_THIS_RUN" == 0 \
       && "$INTERCEPT_GROUP_CREATED_THIS_RUN" == 0 \
       && "$(tr '\n' ' ' < "$calls")" == 'userdel:gpn-intercept groupdel:gpn-intercept ' ]]
); then
    pass "failed-install rollback removes only the service account created by that run"
else
    fail "failed-install service-account rollback is incomplete"
fi
if (
    calls="$TMP/account-gid-mismatch.log"
    INTERCEPT_SERVICE_USER=gpn-intercept
    INTERCEPT_USER_CREATED_THIS_RUN=1
    INTERCEPT_GROUP_CREATED_THIS_RUN=0
    INTERCEPT_CREATED_UID=998
    INTERCEPT_CREATED_GID=999
    service_account_is_safe() { return 0; }
    id() {
        case "$1" in
            -u) printf '998\n' ;;
            -g|-G) printf '997\n' ;;
            *) return 1 ;;
        esac
    }
    userdel() { printf 'unexpected\n' >> "$calls"; }
    failed=0
    rollback_created_intercept_account failed
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
