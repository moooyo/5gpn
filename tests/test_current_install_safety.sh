#!/usr/bin/env bash
# Current-schema install safety checks that are independent of legacy upgrades.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d /tmp/5gpn-current-install-safety.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

# Every fixed-root claim is a transaction boundary. Verify each possible
# failure is returned immediately instead of being hidden by a later success.
for fail_at in 1 2 3; do
    (
        calls=0
        claim_fixed_owned_dir() {
            calls=$((calls + 1))
            [[ "$calls" -ne "$fail_at" ]]
        }
        ! claim_project_roots
        [[ "$calls" == "$fail_at" ]]
    ) || fail "claim_project_roots continued past root claim $fail_at"
done
pass "claim_project_roots propagates every root-boundary failure"

claim_fixed_fn="$(sed -n '/^claim_fixed_owned_dir()/,/^}/p' "$INSTALL")"
grep -Fq 'install -d -o root -g root -m 0755 -- "$dir"' <<<"$claim_fixed_fn" \
    && grep -Fq 'chmod g-s -- "$dir"' <<<"$claim_fixed_fn" \
    && grep -Fq 'chmod 0755 -- "$dir"' <<<"$claim_fixed_fn" \
    || fail "fresh fixed roots can inherit a setgid parent service group"
pass "fresh fixed roots force root ownership below setgid parents"

if (
    BASE_DIR="$TMP/adopt-runtime"
    mkdir -p "$BASE_DIR"
    printf 'operator payload\n' > "$BASE_DIR/keep"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] \
            && printf '644\n' || printf '755\n'
    }
    file_nlink() { printf '1\n'; }
    process_is_root() { return 0; }
    chown() { return 0; }
    managed_path_has_no_nested_mounts() { return 0; }
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" 1
    [[ "$(cat "$BASE_DIR/keep")" == 'operator payload' ]] \
        && root_ownership_marker_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
); then
    pass "safe populated fixed roots can be claimed without deleting their contents"
else
    fail "safe populated fixed-root adoption is unavailable or destructive"
fi

if (
    BASE_DIR="$TMP/adopt-nested-mount"
    mkdir -p "$BASE_DIR"
    printf 'operator payload\n' > "$BASE_DIR/keep"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { printf '755\n'; }
    managed_path_has_no_nested_mounts() { return 1; }
    ! claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" 1 >/dev/null 2>&1
    [[ ! -e "$BASE_DIR/$BASE_OWNERSHIP_MARKER" \
       && "$(cat "$BASE_DIR/keep")" == 'operator payload' ]]
); then
    pass "nested mounts are rejected before fixed-root marker publication"
else
    fail "fixed-root claim wrote a marker before nested-mount rejection"
fi

# Every exact non-sensitive fixed root may claim safe plain contents, but a
# symlink, multiply linked file, or special file is a hard pre-publication
# refusal. Exercise each root separately so one path cannot mask another.
assert_unmarked_root_rejects_entry() { # <label> <root> <marker> <value> <kind>
    local label="$1" root="$2" marker="$3" value="$4" kind="$5"
    local source="$TMP/${label//[^a-zA-Z0-9]/-}-$kind-source"
    if (
        mkdir -p "$root"
        printf 'operator payload\n' > "$root/keep"
        case "$kind" in
            symlink) ln -s "$source" "$root/unsafe-link" ;;
            hardlink)
                printf 'shared bytes\n' > "$source"
                ln "$source" "$root/unsafe-hardlink" ;;
            special) mkfifo "$root/unsafe-fifo" ;;
            *) exit 98 ;;
        esac
        canonical_dir_path() { printf '%s\n' "$1"; }
        fixed_owned_dir_metadata_is_safe() { return 0; }
        verify_ownership_marker() { return 1; }
        managed_path_has_no_nested_mounts() { return 0; }
        ! preflight_fixed_owned_dir_claim "$root" "$marker" "$value" 1 \
            >/dev/null 2>&1
        [[ ! -e "$root/$marker" && ! -L "$root/$marker" ]]
        [[ "$(cat "$root/keep")" == 'operator payload' ]]
        if [[ "$kind" == hardlink ]]; then
            [[ "$(file_nlink "$source")" -gt 1 ]]
        fi
    ); then
        pass "$label rejects a populated unmarked $kind fixture"
    else
        fail "$label accepted or mutated a populated unmarked $kind fixture"
    fi
}

root_case=0
while IFS='|' read -r root_name marker value; do
    for kind in symlink hardlink special; do
        root_case=$((root_case + 1))
        assert_unmarked_root_rejects_entry "$root_name" \
            "$TMP/unmarked-root-$root_case" "$marker" "$value" "$kind"
    done
done <<EOF
BASE_DIR|$BASE_OWNERSHIP_MARKER|$BASE_OWNERSHIP_VALUE
CONF_DIR|$CONF_OWNERSHIP_MARKER|$CONF_OWNERSHIP_VALUE
STATE_DIR|$STATE_OWNERSHIP_MARKER|$STATE_OWNERSHIP_VALUE
INTERCEPT_STATE_DIR|$INTERCEPT_STATE_MARKER|$INTERCEPT_STATE_MARKER_VALUE
EOF
pass "all populated unmarked fixed roots reject symlinks, hardlinks, and special files"

full_install_body="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
mount_line="$(grep -n '^[[:space:]]*managed_roots_have_no_nested_mounts' <<<"$full_install_body" | head -1 | cut -d: -f1)"
publication_line="$(grep -n 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_install_body" | head -1 | cut -d: -f1)"
claim_line="$(grep -n '^[[:space:]]*claim_project_roots' <<<"$full_install_body" | head -1 | cut -d: -f1)"
[[ -n "$mount_line" && -n "$publication_line" && -n "$claim_line" \
   && "$mount_line" -lt "$publication_line" && "$publication_line" -lt "$claim_line" ]] \
    || fail "full install writes a fixed-root marker before nested-mount preflight"
pass "full install checks nested mounts before the publication boundary"

uninstall_preflight_body="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
uninstall_mount_line="$(grep -n '^[[:space:]]*managed_roots_have_no_nested_mounts' <<<"$uninstall_preflight_body" | head -1 | cut -d: -f1)"
uninstall_claim_line="$(grep -n '^[[:space:]]*claim_project_roots' <<<"$uninstall_preflight_body" | head -1 | cut -d: -f1)"
[[ -n "$uninstall_mount_line" && -n "$uninstall_claim_line" \
   && "$uninstall_mount_line" -lt "$uninstall_claim_line" ]] \
    || fail "uninstall claims fixed roots before nested-mount preflight"
pass "uninstall checks nested mounts before fixed-root claim"

for fail_at in 1 2; do
    (
        calls=0
        claim_fixed_owned_dir() {
            calls=$((calls + 1))
            [[ "$calls" -ne "$fail_at" ]]
        }
        ! claim_intercept_roots
        [[ "$calls" == "$fail_at" ]]
    ) || fail "claim_intercept_roots continued past root claim $fail_at"
done
pass "claim_intercept_roots propagates every root-boundary failure"

# An unowned interception root must be refused and left byte-for-byte alone.
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

assert_account_shape() { # assert_account_shape <label> <expected-result> <passwd-body> <group-body> <id-groups>
    local label="$1" expected="$2" passwd_body="$3" group_body="$4" id_groups="$5"
    if (
        getent() {
            case "$1" in
                passwd)
                    if [[ "$#" == 2 ]]; then
                        printf '%s' "$passwd_body" | awk -F: -v name="$2" '$1 == name'
                    else
                        printf '%s' "$passwd_body"
                    fi ;;
                group)
                    if [[ "$#" == 2 ]]; then
                        printf '%s' "$group_body" | awk -F: -v name="$2" '$1 == name'
                    else
                        printf '%s' "$group_body"
                    fi ;;
                *) return 1 ;;
            esac
        }
        id() {
            case "$1" in
                -gn) printf 'sample-service\n' ;;
                -g) printf '999\n' ;;
                -G) printf '%s\n' "$id_groups" ;;
                *) return 1 ;;
            esac
        }
        if [[ "$expected" == safe ]]; then
            service_account_is_safe sample-service sample-service
        else
            ! service_account_is_safe sample-service sample-service
        fi
    ); then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_account_shape \
    "service account validation rejects another passwd user sharing the primary GID" unsafe \
    $'sample-service:x:998:999::/nonexistent:/usr/sbin/nologin\nother-service:x:997:999::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\n' '999'
assert_account_shape \
    "service account validation rejects a duplicate numeric UID" unsafe \
    $'sample-service:x:998:999::/nonexistent:/usr/sbin/nologin\nuid-alias:x:998:997::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\n' '999'
assert_account_shape \
    "service account validation rejects a duplicate numeric GID alias" unsafe \
    $'sample-service:x:998:999::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\ngid-alias:x:999:other-user\n' '999'
assert_account_shape \
    "service account validation rejects unexpected supplementary groups" unsafe \
    $'sample-service:x:998:999::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\n' '999 1000'
assert_account_shape \
    "service account validation rejects a UID-zero account alias" unsafe \
    $'sample-service:x:0:999::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\n' '999'
assert_account_shape \
    "an isolated system service account remains valid" safe \
    $'sample-service:x:998:999::/nonexistent:/usr/sbin/nologin\n' \
    $'sample-service:x:999:\n' '999'

(
    calls="$TMP/account-shared-primary.log"
    getent() {
        case "$1" in
            group) printf 'sample-service:x:999:\n' ;;
            passwd)
                [[ "$#" == 2 ]] && return 1
                printf 'other-service:x:997:999::/nonexistent:/usr/sbin/nologin\n' ;;
            *) return 1 ;;
        esac
    }
    groupadd() { printf 'unexpected-groupadd\n' >> "$calls"; }
    useradd() { printf 'unexpected-useradd\n' >> "$calls"; }
    groupdel() { printf 'unexpected-groupdel\n' >> "$calls"; }
    userdel() { printf 'unexpected-userdel\n' >> "$calls"; }
    ! ensure_service_account sample-service sample-service
    [[ ! -e "$calls" ]]
) || fail "service account creation adopted a shared primary group"
pass "service account creation refuses a group used as another user's primary group"

(
    group_exists=0
    user_exists=0
    getent() {
        case "$1" in
            group) [[ "$group_exists" == 1 ]] && printf 'fivegpn:x:999:\n' ;;
            passwd) [[ "$user_exists" == 1 ]] && printf 'fivegpn:x:998:999::/nonexistent:/usr/sbin/nologin\n' ;;
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
    ensure_service_account fivegpn fivegpn created_user created_group created_uid created_gid
    [[ "$created_user" == 1 && "$created_group" == 1 \
       && "$created_uid" == 998 && "$created_gid" == 999 ]]
) || fail "service account creation did not report its own mutation results"
pass "service account creation reports the exact resources and IDs it created"

# Purge retains the interception CA for already enrolled devices.
uninstall_body="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
grep -Fq 'cert acme debug-cert intercept-ca \' <<<"$uninstall_body" \
    || fail "purge preserve list would delete intercept-ca"
purge_root="$TMP/purge-conf"
mkdir -p "$purge_root"/{cert,acme,debug-cert,intercept-ca,remove-me}
printf 'enrolled-root-certificate\n' > "$purge_root/intercept-ca/root.crt"
printf 'enrolled-root-private-key\n' > "$purge_root/intercept-ca/root.key"
write_ownership_marker "$purge_root" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
clear_owned_scope "$purge_root" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
    "$purge_root" "$CONF_OWNERSHIP_MARKER" cert acme debug-cert intercept-ca
[[ -d "$purge_root/intercept-ca" && ! -e "$purge_root/remove-me" \
   && "$(cat "$purge_root/intercept-ca/root.crt")" == enrolled-root-certificate \
   && "$(cat "$purge_root/intercept-ca/root.key")" == enrolled-root-private-key ]] \
    || fail "purge behavior removed interception CA state"
pass "purge behavior preserves interception CA bytes"

# There is one current whole-file reset: the root management `mihomo-reset`
# command. The retired beta installer mode must not remain in either entrypoint,
# help output, or dispatch.
if grep -Fq 'upgrade-reset-mihomo' "$INSTALL" "$QUICK"; then
    fail "retired upgrade-reset-mihomo remains reachable"
fi
install_main="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
install_usage="$(sed -n '/^usage()/,/^}/p' "$INSTALL")"
if grep -Fq 'mihomo-reset)' <<<"$install_main" \
   && grep -Fq 'mihomo-reset' <<<"$install_usage" \
   && ! grep -Fq 'mihomo-reset' "$QUICK"; then
    pass "mihomo-reset is the sole current reset and has no quick-installer path"
else
    fail "current reset dispatch or quick-installer separation is incomplete"
fi

manage_fn="$(sed -n '/^install_manage_cli()/,/^}/p' "$INSTALL")"
delegate_fn="$(sed -n '/^delegate_pinned_channel_switch()/,/^}/p' "$INSTALL")"
if grep -Fq 'publish_executable "$quick_source" "${BASE_DIR}/quick-install.sh"' <<<"$manage_fn" \
   && grep -Fq 'file_uid "$quick"' <<<"$delegate_fn" \
   && grep -Fq 'file_mode "$quick"' <<<"$delegate_fn" \
   && grep -Fq 'owned_root_canonical "$BASE_DIR"' <<<"$delegate_fn" \
   && grep -Fq 'exec bash "$quick" "${args[@]}"' <<<"$delegate_fn"; then
    pass "installed channel handoff retains and verifies the quick installer"
else
    fail "installed channel handoff is incomplete"
fi

# Installed channel handoff must reject writable scripts and runtime roots.
(
    SCRIPT_DIR="$TMP/unsafe-handoff"
    mkdir -p "$SCRIPT_DIR"
    : > "$SCRIPT_DIR/quick-install.sh"
    RELEASE_TAG=1.0.0
    RELEASE_CHANNEL_EXPLICIT=1
    RELEASE_CHANNEL=beta
    file_uid() { printf '0\n'; }
    file_mode() { printf '777\n'; }
    ! delegate_pinned_channel_switch >/dev/null 2>&1
) || fail "channel handoff accepted a writable quick installer"
pass "channel handoff rejects a group/world-writable quick installer"

(
    BASE_DIR="$TMP/unsafe-runtime-root"
    SCRIPT_DIR="$BASE_DIR"
    mkdir -p "$BASE_DIR"
    write_ownership_marker "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
    : > "$BASE_DIR/quick-install.sh"
    RELEASE_TAG=1.0.0
    RELEASE_CHANNEL_EXPLICIT=1
    RELEASE_CHANNEL=beta
    file_uid() { printf '0\n'; }
    file_mode() {
        if [[ "$1" == "$BASE_DIR" ]]; then printf '777\n'; else printf '644\n'; fi
    }
    ! delegate_pinned_channel_switch >/dev/null 2>&1
) || fail "channel handoff accepted a writable installed runtime root"
pass "channel handoff rejects a group/world-writable installed runtime root"

echo "current install safety: PASS"
