#!/usr/bin/env bash
# Behavioral checks for the shared public-certificate role publisher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/5gpn-cert-role-ctl.XXXXXX)"
cleanup_test_tmp() {
    if [[ "${KEEP_CERT_ROLE_TMP:-0}" == 1 ]]; then
        printf 'kept test fixture: %s\n' "$TMP" >&2
    else
        rm -rf -- "$TMP"
    fi
}
trap cleanup_test_tmp EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# Ambient values must not configure the production library while it is sourced.
CERT_ROLE_CTL_ROOT=/tmp/ambient-root
CERT_ROLE_CTL_ALLOW_CREATE=1
CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
# shellcheck source=../scripts/publication-fs.sh
source "$ROOT/scripts/publication-fs.sh"
# shellcheck source=../scripts/cert-role-ctl.sh
source "$ROOT/scripts/cert-role-ctl.sh"
[[ "$CERT_ROLE_CTL_ROOT" == /etc/5gpn/cert \
   && "$CERT_ROLE_CTL_ALLOW_CREATE" == 0 \
   && "$CERT_ROLE_CTL_ALLOW_TEST_ROOT" == 0 ]] \
    || fail "ambient environment configured the certificate-role library"
remove_body="$(sed -n '/^cert_role_ctl_remove_tombstone_exact()/,/^}/p' \
    "$ROOT/scripts/cert-role-ctl.sh")"
printf '%s' "$remove_body" | grep -Eq 'rm[[:space:]]+(-[^[:space:]]*[rR]|--recursive)' \
    && fail "certificate tombstone cleanup contains recursive deletion"

CONFIG_ROOT="$TMP/config"
CERT_ROOT="$CONFIG_ROOT/cert"
STAGE_PARENT="$TMP/run"
mkdir -p "$CERT_ROOT" "$STAGE_PARENT"
chmod 0755 "$CONFIG_ROOT"
chmod 0751 "$CERT_ROOT"
chmod 0700 "$STAGE_PARENT"
printf '5gpn-config\n' > "$CONFIG_ROOT/.5gpn-owned"
printf '5gpn-cert-root-v1\n' > "$CERT_ROOT/.5gpn-cert-root-owned"
chmod 0644 "$CONFIG_ROOT/.5gpn-owned" "$CERT_ROOT/.5gpn-cert-root-owned"

CERT_ROLE_CTL_ROOT="$CERT_ROOT"
CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
CERT_ROLE_CTL_ALLOW_CREATE=1
CERT_ROLE_CTL_SERVICE_GROUP="$(id -gn)"
CERT_ROLE_CTL_SERVICE_GID="$(id -g)"
CERT_ROLE_CTL_STAGE_PARENT="$STAGE_PARENT"
cert_role_ctl_group_gid_override() { id -g; }

SOURCE_A="$TMP/source-a"
SOURCE_B="$TMP/source-b"
SOURCE_C="$TMP/source-c"
SOURCE_D="$TMP/source-d"
mkdir -p "$SOURCE_A" "$SOURCE_B" "$SOURCE_C" "$SOURCE_D"
printf 'certificate-a\n' > "$SOURCE_A/fullchain.pem"
printf 'private-key-a\n' > "$SOURCE_A/privkey.pem"
printf 'certificate-b\n' > "$SOURCE_B/fullchain.pem"
printf 'private-key-b\n' > "$SOURCE_B/privkey.pem"
printf 'certificate-c\n' > "$SOURCE_C/fullchain.pem"
printf 'private-key-c\n' > "$SOURCE_C/privkey.pem"
printf 'certificate-d\n' > "$SOURCE_D/fullchain.pem"
printf 'private-key-d\n' > "$SOURCE_D/privkey.pem"
chmod 0600 "$SOURCE_A"/* "$SOURCE_B"/* "$SOURCE_C"/* "$SOURCE_D"/*

accept_pair() {
    [[ -s "$1" && -s "$2" && ( "$3" == dot || "$3" == console ) ]]
}

tree_fingerprint() {
    find "$CERT_ROOT" -xdev -printf '%P|%y|%m|%U|%G|%i|%l\n' | LC_ALL=C sort
    find "$CERT_ROOT" -xdev -type f -print0 | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum
}

find_probe="$TMP/find-probe"
mkdir "$find_probe"
printf 'partial\n' > "$find_probe/entry"
find_probe_entries=(preserved)
REAL_FIND="$(command -v find)"
find() {
    "$REAL_FIND" "$@"
    return 1
}
if publication_fs_find_entries find_probe_entries "$find_probe" -mindepth 1 -maxdepth 1; then
    fail "a find producer failure was accepted after returning partial entries"
fi
unset -f find
[[ "${#find_probe_entries[@]}" == 1 && "${find_probe_entries[0]}" == preserved ]] \
    || fail "a failed find producer leaked partial entries to its caller"
pass "certificate entry collection requires an unambiguous producer success sentinel"

cert_role_ctl_publish_pair "$SOURCE_A/fullchain.pem" "$SOURCE_A/privkey.pem" accept_pair \
    || fail "fresh dual-role publication failed: $CERT_ROLE_CTL_LAST_ERROR"
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed \
   && "$CERT_ROLE_CTL_COMMITTED_ROLES" == dot,console ]] \
    || fail "fresh publication did not report a durable dual-role commit"
cert_role_ctl_validate_current || fail "fresh current certificate roles failed validation"
for role in dot console; do
    [[ "$(stat -c '%u:%g:%a:%h' -- "$CERT_ROOT/$role/current")" \
        == "$(id -u):$(id -g):777:1" ]] \
        || fail "$role current symlink metadata is not the explicit root/test owner contract"
    cmp -s "$SOURCE_A/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" \
        || fail "$role did not publish the captured source certificate"
done
pass "fresh role trees publish one durable root-owned relative current each"

original_snapshot_cleanup="$(declare -f cert_role_ctl_remove_source_snapshot)"
cert_role_ctl_remove_source_snapshot() { return 1; }
cert_role_ctl_publish_pair "$SOURCE_A/fullchain.pem" "$SOURCE_A/privkey.pem" accept_pair \
    || fail "safe postcommit source-snapshot residue amplified into publication failure (state=${CERT_ROLE_CTL_COMMIT_STATE}, cleanup=${CERT_ROLE_CTL_SOURCE_CLEANUP_STATE}, error=${CERT_ROLE_CTL_LAST_ERROR})"
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed && "$CERT_ROLE_CTL_GC_WARNING" == 1 ]] \
    || fail "postcommit source-snapshot cleanup failure was not reported as a warning"
find "$STAGE_PARENT" -mindepth 1 -maxdepth 1 -name '.cert-role-stage.*' -print -quit \
    | grep -q . || fail "source-snapshot cleanup failure did not retain recoverable evidence"
eval "$original_snapshot_cleanup"
cert_role_ctl_publish_pair "$SOURCE_A/fullchain.pem" "$SOURCE_A/privkey.pem" accept_pair \
    || fail "next publication did not scrub the retained source snapshot"
find "$STAGE_PARENT" -mindepth 1 -maxdepth 1 -name '.cert-role-stage.*' -print -quit \
    | grep -q . && fail "retained source snapshot did not converge on the next run"
pass "safe private snapshot cleanup failure is warning-only and self-healing"

original_sync_path="$(declare -f publication_fs_sync_path)"
FAIL_STAGE_PARENT_SYNC=1
stage_parent_sync_before="$(readlink -- "$CERT_ROOT/dot/current")"
publication_fs_sync_path() {
    if [[ "$FAIL_STAGE_PARENT_SYNC" == 1 \
       && "$1" == "$STAGE_PARENT" \
       && "$(readlink -- "$CERT_ROOT/dot/current")" != "$stage_parent_sync_before" ]]; then
        FAIL_STAGE_PARENT_SYNC=0
        return 1
    fi
    sync -f "$1"
}
cert_role_ctl_publish_pair "$SOURCE_A/fullchain.pem" "$SOURCE_A/privkey.pem" accept_pair \
    || fail "removed-undurable source snapshot cleanup amplified into deployment failure"
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed \
   && "$CERT_ROLE_CTL_GC_WARNING" == 1 \
   && "$CERT_ROLE_CTL_SOURCE_CLEANUP_STATE" == removed-undurable ]] \
    || fail "stage-parent sync failure was not isolated as cleanup-undurable (state=${CERT_ROLE_CTL_COMMIT_STATE}, warning=${CERT_ROLE_CTL_GC_WARNING}, cleanup=${CERT_ROLE_CTL_SOURCE_CLEANUP_STATE}, error=${CERT_ROLE_CTL_LAST_ERROR})"
find "$STAGE_PARENT" -mindepth 1 -maxdepth 1 -name '.cert-role-stage.*' -print -quit \
    | grep -q . && fail "removed-undurable cleanup left a source snapshot path"
eval "$original_sync_path"
pass "postcommit stage-parent sync failure is warning-only"

original_gc_role="$(declare -f cert_role_ctl_gc_role)"
cert_role_ctl_gc_role() { PUBLICATION_FS_DELETE_STATE=partial-undurable; return 1; }
cert_role_ctl_publish_pair "$SOURCE_A/fullchain.pem" "$SOURCE_A/privkey.pem" accept_pair \
    || fail "postcommit certificate GC failure amplified into deployment failure"
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed \
   && "$CERT_ROLE_CTL_GC_WARNING" == 1 \
   && "$CERT_ROLE_CTL_GC_STATE" == partial-undurable ]] \
    || fail "certificate GC failure was not isolated as a committed warning"
eval "$original_gc_role"
pass "postcommit certificate generation GC failure is warning-only"

chmod 0750 "$CERT_ROOT"
cert_role_ctl_tree_is_recoverable \
    || fail "legacy current root traversal mode was not classified recoverable"
if cert_role_ctl_root_boundary_is_safe; then
    fail "mode 0750 certificate root was accepted as steady runtime state"
fi
cert_role_ctl_repair_recoverable_tree \
    || fail "mode 0750 certificate root did not repair forward to steady state"
[[ "$(stat -c %a -- "$CERT_ROOT")" == 751 ]] \
    || fail "forward repair did not restore certificate-root traversal mode 0751"
cert_role_ctl_validate_current || fail "mode recovery did not restore strict 0751 state"
pass "0750 is recoverable-only while steady certificate roots require 0751"

OUTSIDE_CANDIDATE_ROOT="$TMP/outside-candidates"
OUTSIDE_EMPTY="$OUTSIDE_CANDIDATE_ROOT/.role.new.dot.OUTSIDE"
OUTSIDE_MIMIC="$OUTSIDE_CANDIDATE_ROOT/.role.new.console.MIMIC"
mkdir -p "$OUTSIDE_EMPTY" "$OUTSIDE_MIMIC/generations"
chmod 0700 "$OUTSIDE_EMPTY"
chmod 0750 "$OUTSIDE_MIMIC" "$OUTSIDE_MIMIC/generations"
printf '5gpn-cert-role-v1:console\n' > "$OUTSIDE_MIMIC/.5gpn-cert-role-owned"
chmod 0644 "$OUTSIDE_MIMIC/.5gpn-cert-role-owned"
outside_candidates_before="$(
    find "$OUTSIDE_CANDIDATE_ROOT" -printf '%P|%y|%m|%U|%G|%i\n' | LC_ALL=C sort
    find "$OUTSIDE_CANDIDATE_ROOT" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
)"
if cert_role_ctl_remove_role_candidate_exact "$OUTSIDE_EMPTY" dot; then
    fail "out-of-scope empty role candidate was removed"
fi
if cert_role_ctl_remove_role_candidate_exact "$OUTSIDE_MIMIC" console; then
    fail "out-of-scope role candidate mimic was removed"
fi
outside_candidates_after="$(
    find "$OUTSIDE_CANDIDATE_ROOT" -printf '%P|%y|%m|%U|%G|%i\n' | LC_ALL=C sort
    find "$OUTSIDE_CANDIDATE_ROOT" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
)"
[[ "$outside_candidates_after" == "$outside_candidates_before" ]] \
    || fail "out-of-scope role candidate rejection changed external state"
pass "role candidate cleanup is bound to an exact direct child of the certificate root"

mkdir "$CERT_ROOT/.role.new.dot.CRASHED"
chmod 0700 "$CERT_ROOT/.role.new.dot.CRASHED"
mkdir "$CERT_ROOT/.role.new.console.MARKER"
chmod 0750 "$CERT_ROOT/.role.new.console.MARKER"
printf 'partial-marker\n' > \
    "$CERT_ROOT/.role.new.console.MARKER/..5gpn-cert-role-owned.ABC123"
chmod 0600 "$CERT_ROOT/.role.new.console.MARKER/..5gpn-cert-role-owned.ABC123"
ln -s "$(readlink -- "$CERT_ROOT/dot/current")" "$CERT_ROOT/dot/.current.123.456"
mkdir "$CERT_ROOT/dot/generations/.new.CRASHED"
chmod 0700 "$CERT_ROOT/dot/generations/.new.CRASHED"
mkdir "$CERT_ROOT/dot/generations/.delete.123.456"
chmod 0750 "$CERT_ROOT/dot/generations/.delete.123.456"
printf 'partial-key\n' > "$CERT_ROOT/dot/generations/.delete.123.456/privkey.pem"
chmod 0640 "$CERT_ROOT/dot/generations/.delete.123.456/privkey.pem"
recoverable_before="$(tree_fingerprint)"
cert_role_ctl_tree_is_recoverable \
    || fail "known crash residue was rejected by read-only recoverability preflight"
recoverable_after="$(tree_fingerprint)"
[[ "$recoverable_after" == "$recoverable_before" ]] \
    || fail "read-only certificate recoverability preflight changed the tree"
cert_role_ctl_repair_recoverable_tree \
    || fail "known crash residue did not repair forward under the transaction"
find "$CERT_ROOT" \( -name '.role.new.*' -o -name '.current.*' \
    -o -name '.new.*' -o -name '.delete.*' \) -print -quit | grep -q . \
    && fail "recoverable certificate transaction residue remained"
cert_role_ctl_validate_current || fail "repaired certificate tree is not steady"
pass "read-only recoverability and locked forward repair cover every transaction residue"

ln -s generations/generation-missing "$CERT_ROOT/dot/.current.999.999"
if cert_role_ctl_tree_is_recoverable; then
    fail "dangling current-transaction orphan passed read-only recoverability"
fi
[[ -L "$CERT_ROOT/dot/.current.999.999" ]] \
    || fail "read-only recoverability rejection mutated dangling evidence"
rm -f -- "$CERT_ROOT/dot/.current.999.999"
pass "dangling orphan pointers fail before repair or publication"

mkdir "$STAGE_PARENT/.cert-role-stage.CRASHED"
chmod 0700 "$STAGE_PARENT/.cert-role-stage.CRASHED"
printf 'partial-source-marker\n' > \
    "$STAGE_PARENT/.cert-role-stage.CRASHED/.marker.new.ABC123"
chmod 0600 "$STAGE_PARENT/.cert-role-stage.CRASHED/.marker.new.ABC123"

if [[ "${EUID:-$(id -u)}" == 0 ]]; then
    old_gid=42420
    current_generation="$CERT_ROOT/dot/$(readlink -- "$CERT_ROOT/dot/current")"
    chown 0:"$old_gid" "$current_generation/privkey.pem"
    CERT_ROLE_CTL_ADDITIONAL_GIDS=""
    if cert_role_ctl_validate_current; then
        fail "an unapproved certificate role GID passed strict validation"
    fi
    if cert_role_ctl_tree_is_recoverable; then
        fail "an unapproved certificate role GID was classified recoverable"
    fi
    pass "unapproved certificate role GIDs fail closed"
    CERT_ROLE_CTL_ADDITIONAL_GIDS="$old_gid"
    if ! cert_role_ctl_tree_is_recoverable; then
        cert_role_ctl_gid_is_allowed dot "$old_gid" \
            || printf 'diagnostic: authorized old GID was rejected\n' >&2
        cert_role_ctl_generation_is_recoverable dot "$current_generation" \
            || printf 'diagnostic: mixed current generation was rejected\n' >&2
        cert_role_ctl_role_is_recoverable dot \
            || printf 'diagnostic: mixed dot role was rejected\n' >&2
        cert_role_ctl_role_is_recoverable console \
            || printf 'diagnostic: unchanged console role was rejected\n' >&2
        fail "mixed authorized old/new GID recovery state was rejected"
    fi
    cert_role_ctl_repair_recoverable_tree \
        || fail "mixed authorized GID state did not normalize idempotently"
    [[ "$(stat -c %g -- "$current_generation/privkey.pem")" == "$(id -g)" ]] \
        || fail "mixed GID repair did not restore the current service GID"
    chown 0:"$old_gid" "$current_generation/privkey.pem"
    mkdir "$CERT_ROOT/dot/generations/.new.MIXED"
    chmod 0700 "$CERT_ROOT/dot/generations/.new.MIXED"
    chown 0:"$old_gid" "$CERT_ROOT/dot/generations/.new.MIXED"
    printf 'new-gid-file\n' > "$CERT_ROOT/dot/generations/.new.MIXED/fullchain.pem"
    printf 'old-gid-file\n' > "$CERT_ROOT/dot/generations/.new.MIXED/privkey.pem"
    chmod 0640 "$CERT_ROOT/dot/generations/.new.MIXED"/*
    chown 0:"$old_gid" "$CERT_ROOT/dot/generations/.new.MIXED/privkey.pem"
    mkdir "$CERT_ROOT/dot/generations/.delete.321.654"
    chmod 0750 "$CERT_ROOT/dot/generations/.delete.321.654"
    printf 'partial\n' > "$CERT_ROOT/dot/generations/.delete.321.654/fullchain.pem"
    printf 'partial-key\n' > "$CERT_ROOT/dot/generations/.delete.321.654/privkey.pem"
    chmod 0640 "$CERT_ROOT/dot/generations/.delete.321.654"/*
    chown -R 0:"$old_gid" "$CERT_ROOT/dot/generations/.delete.321.654"
    chown 0:"$(id -g)" "$CERT_ROOT/dot/generations/.delete.321.654/fullchain.pem"
    ln -s "$(readlink -- "$CERT_ROOT/dot/current")" "$CERT_ROOT/dot/.current.321.654"
    cert_role_ctl_tree_is_recoverable \
        || fail "combined mixed-GID and transaction residue failed read-only preflight"
    REAL_CHOWN="$(command -v chown)"
    FAIL_CHOWN_PATH="$CERT_ROOT/dot/generations/.new.MIXED"
    chown() {
        local last="${!#}"
        [[ "$last" != "$FAIL_CHOWN_PATH" ]] || return 1
        "$REAL_CHOWN" "$@"
    }
    if cert_role_ctl_normalize_recoverable_role dot; then
        fail "injected group-normalization interruption was accepted"
    fi
    unset -f chown
    cert_role_ctl_tree_is_recoverable \
        || fail "partially normalized role was not recoverable on the next preflight"
    cert_role_ctl_repair_recoverable_tree \
        || fail "combined mixed-GID and transaction residue did not repair forward"
    cert_role_ctl_validate_current \
        || fail "combined recovery did not return to strict current state"
    for role in dot console; do
        chown 0:"$old_gid" "$CERT_ROOT/$role" "$CERT_ROOT/$role/generations"
        find "$CERT_ROOT/$role/generations" -type d -exec chown 0:"$old_gid" {} +
        find "$CERT_ROOT/$role/generations" -type f -exec chown 0:"$old_gid" {} +
    done
    original_production_root="$CERT_ROLE_CTL_PRODUCTION_ROOT"
    CERT_ROLE_CTL_PRODUCTION_ROOT="$CERT_ROOT"
    chown 0:"$old_gid" "$CONFIG_ROOT"
    chmod 3771 "$CONFIG_ROOT"
    original_gid_override="$(declare -f cert_role_ctl_group_gid_override)"
    cert_role_ctl_group_gid_override() { return 1; }
    cert_role_ctl_tree_is_recoverable \
        || fail "3771 config root and journal-authorized old GID were rejected while the service group was absent"
    eval "$original_gid_override"
    chown 0:0 "$CONFIG_ROOT"
    chmod 00755 "$CONFIG_ROOT"
    cert_role_ctl_repair_recoverable_tree \
        || fail "role tree did not normalize after the service group was recreated"
    cert_role_ctl_validate_current \
        || fail "recreated service group did not restore strict role ownership"
    CERT_ROLE_CTL_PRODUCTION_ROOT="$original_production_root"
    CERT_ROLE_CTL_ADDITIONAL_GIDS=""
    pass "mixed old/new ownership and every transaction residue repair together"
else
    pass "mixed-GID repair case requires root and is covered by disposable acceptance"
fi

dot_a="$(readlink -- "$CERT_ROOT/dot/current")"
console_a="$(readlink -- "$CERT_ROOT/console/current")"
REAL_MV="$(command -v mv)"
FAIL_POINTER_DEST="$CERT_ROOT/console/current"
mv() {
    local last="${!#}"
    if [[ -n "${FAIL_POINTER_DEST:-}" && "$last" == "$FAIL_POINTER_DEST" ]]; then
        return 1
    fi
    "$REAL_MV" "$@"
}
if cert_role_ctl_publish_pair \
    "$SOURCE_B/fullchain.pem" "$SOURCE_B/privkey.pem" accept_pair >/dev/null 2>&1; then
    fail "second-role current failure was accepted"
fi
unset -f mv
[[ ! -e "$STAGE_PARENT/.cert-role-stage.CRASHED" ]] \
    || fail "interrupted private source snapshot was not scrubbed before reuse"
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed-partial \
   && "$(readlink -- "$CERT_ROOT/dot/current")" != "$dot_a" \
   && "$(readlink -- "$CERT_ROOT/console/current")" == "$console_a" ]] \
    || fail "second-role failure rolled back dot or changed console"
cmp -s "$SOURCE_B/fullchain.pem" "$CERT_ROOT/dot/current/fullchain.pem" \
    || fail "the first committed role did not retain the new source bytes"
pass "second-role failure remains committed-partial and never rolls back dot"

unset FAIL_POINTER_DEST
cert_role_ctl_publish_pair "$SOURCE_B/fullchain.pem" "$SOURCE_B/privkey.pem" accept_pair \
    || fail "forward repair after a partial role commit failed"
for role in dot console; do
    cmp -s "$SOURCE_B/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" \
        || fail "forward repair did not converge $role"
done
pass "a later locked publication repairs a partial pair forward"

console_before_sync="$(readlink -- "$CERT_ROOT/console/current")"
FAIL_ROLE_SYNC=1
publication_fs_sync_path() {
    if [[ "$FAIL_ROLE_SYNC" == 1 \
       && "$1" == "$CERT_ROOT/console" \
       && "$(readlink -- "$CERT_ROOT/console/current")" != "$console_before_sync" ]]; then
        FAIL_ROLE_SYNC=0
        return 1
    fi
    sync -f "$1"
}
if cert_role_ctl_publish_pair "$SOURCE_C/fullchain.pem" "$SOURCE_C/privkey.pem" \
    accept_pair >/dev/null 2>&1; then
    fail "post-rename console directory sync failure was accepted"
fi
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed-undurable \
   && "$(readlink -- "$CERT_ROOT/dot/current")" != "$dot_a" ]] \
    || fail "directory sync failure hid or rolled back an already visible role"
cmp -s "$SOURCE_C/fullchain.pem" "$CERT_ROOT/console/current/fullchain.pem" \
    || fail "console current did not retain its already-visible committed bytes"
publication_fs_sync_path() { sync -f "$1"; }
cert_role_ctl_publish_pair "$SOURCE_C/fullchain.pem" "$SOURCE_C/privkey.pem" accept_pair \
    || fail "forward repair after committed-undurable publication failed"
pass "post-pointer sync failure is committed-undurable and forward repairable"

original_pointer_commit="$(declare -f publication_fs_commit_relative_pointer)"
publication_fs_commit_relative_pointer() {
    local root="$1" pointer_name="$2" target="$3" temp
    temp="$root/.current.$$.$RANDOM"
    ln -s -- "$target" "$temp" || return 1
    mv -Tf -- "$temp" "$root/$pointer_name" || return 1
    sync -f "$root" || return 1
    PUBLICATION_FS_COMMIT_STATE=committed
    return 1
}
if cert_role_ctl_publish_pair "$SOURCE_D/fullchain.pem" "$SOURCE_D/privkey.pem" \
    accept_pair >/dev/null 2>&1; then
    fail "post-sync final pointer revalidation failure was accepted"
fi
[[ "$CERT_ROLE_CTL_COMMIT_STATE" == committed-partial \
   && "$CERT_ROLE_CTL_COMMITTED_ROLES" == dot ]] \
    || fail "committed pointer failure was misreported as pre-commit"
cmp -s "$SOURCE_D/fullchain.pem" "$CERT_ROOT/dot/current/fullchain.pem" \
    || fail "committed pointer bytes were cleaned up or rolled back"
eval "$original_pointer_commit"
cert_role_ctl_publish_pair "$SOURCE_D/fullchain.pem" "$SOURCE_D/privkey.pem" accept_pair \
    || fail "forward repair after committed final-revalidation failure failed"
pass "post-sync final revalidation failure remains committed-partial"

extra="$CERT_ROOT/dot/generations/generation-20000101T000000Z-99-99"
mkdir "$extra"
chmod 0750 "$extra"
install -m 0640 "$SOURCE_A/fullchain.pem" "$extra/fullchain.pem"
install -m 0640 "$SOURCE_A/privkey.pem" "$extra/privkey.pem"
saved_current="$(readlink -- "$CERT_ROOT/dot/current")"
original_no_nested="$(declare -f publication_fs_no_nested_mounts)"
publication_fs_no_nested_mounts() {
    if [[ "$1" == "$extra" && ! -e "$TMP/current-drift-injected" ]]; then
        rm -f -- "$CERT_ROOT/dot/current"
        ln -s "generations/$(basename -- "$extra")" "$CERT_ROOT/dot/current"
        : > "$TMP/current-drift-injected"
    fi
    return 0
}
if cert_role_ctl_remove_generation dot "$(basename -- "$extra")" 0; then
    fail "final current drift was accepted by certificate generation deletion"
fi
[[ -d "$extra" && "$(readlink -- "$CERT_ROOT/dot/current")" == "generations/$(basename -- "$extra")" ]] \
    || fail "current-drift rejection deleted or overwrote the concurrent target"
eval "$original_no_nested"
rm -f -- "$CERT_ROOT/dot/current"
ln -s "$saved_current" "$CERT_ROOT/dot/current"
tombstone="$CERT_ROOT/dot/generations/.delete.123.456"
mv -T -- "$extra" "$tombstone"
rm -f -- "$tombstone/fullchain.pem"
cert_role_ctl_scrub_role dot || fail "partial deletion tombstone did not converge"
[[ ! -e "$tombstone" ]] || fail "partial deletion tombstone remained"
pass "exact tombstones make interrupted non-current deletion idempotent"

make_tombstone() {
    local path="$CERT_ROOT/dot/generations/$1"
    mkdir "$path"
    chmod 0750 "$path"
    install -m 0640 "$SOURCE_A/fullchain.pem" "$path/fullchain.pem"
    install -m 0640 "$SOURCE_A/privkey.pem" "$path/privkey.pem"
    printf '%s\n' "$path"
}

outside_tombstone="$TMP/.delete.999.999"
mkdir "$outside_tombstone"
chmod 0750 "$outside_tombstone"
install -m 0640 "$SOURCE_A/fullchain.pem" "$outside_tombstone/fullchain.pem"
install -m 0640 "$SOURCE_A/privkey.pem" "$outside_tombstone/privkey.pem"
outside_before="$(find "$outside_tombstone" -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 sha256sum)"
if cert_role_ctl_remove_tombstone_exact dot "$outside_tombstone"; then
    fail "out-of-scope tombstone lookalike was accepted"
fi
outside_after="$(find "$outside_tombstone" -maxdepth 1 -type f -print0 \
    | sort -z | xargs -0 sha256sum)"
[[ "$PUBLICATION_FS_DELETE_STATE" == unchanged && "$outside_after" == "$outside_before" ]] \
    || fail "out-of-scope tombstone rejection changed external bytes"
pass "tombstone deletion is confined to one canonical role generation child"

unlink_tombstone="$(make_tombstone .delete.201.301)"
REAL_RM="$(command -v rm)"
FAIL_RM_PATH="$unlink_tombstone/fullchain.pem"
RM_RECURSIVE_SENTINEL="$TMP/recursive-rm-seen"
rm() {
    local arg last="${!#}"
    for arg in "$@"; do
        case "$arg" in
            -r|-R|-rf|-fr|--recursive) : > "$RM_RECURSIVE_SENTINEL"; return 98 ;;
        esac
    done
    case "$last" in */fullchain.pem|*/privkey.pem) ;; *) return 97 ;; esac
    [[ "$last" != "$FAIL_RM_PATH" ]] || return 1
    "$REAL_RM" "$@"
}
if cert_role_ctl_remove_tombstone_exact dot "$unlink_tombstone"; then
    fail "injected tombstone file unlink failure was accepted"
fi
unset -f rm
[[ "$PUBLICATION_FS_DELETE_STATE" == unchanged \
   && -f "$unlink_tombstone/fullchain.pem" \
   && -f "$unlink_tombstone/privkey.pem" ]] \
    || fail "unlink failure changed tombstone state before a successful action"
[[ ! -e "$RM_RECURSIVE_SENTINEL" ]] \
    || fail "certificate tombstone cleanup attempted recursive deletion"
cert_role_ctl_remove_tombstone_exact dot "$unlink_tombstone" \
    || fail "tombstone did not recover after unlink failure"

mount_drift_tombstone="$(make_tombstone .delete.205.305)"
original_no_nested_mounts="$(declare -f publication_fs_no_nested_mounts)"
publication_fs_no_nested_mounts() {
    if [[ "$1" == "$mount_drift_tombstone" \
       && ! -e "$mount_drift_tombstone/fullchain.pem" ]]; then
        return 1
    fi
    return 0
}
if cert_role_ctl_remove_tombstone_exact dot "$mount_drift_tombstone"; then
    fail "mount drift after the first tombstone unlink was accepted"
fi
[[ "$PUBLICATION_FS_DELETE_STATE" == partial \
   && ! -e "$mount_drift_tombstone/fullchain.pem" \
   && -f "$mount_drift_tombstone/privkey.pem" ]] \
    || fail "post-unlink mount drift did not preserve the remaining evidence"
eval "$original_no_nested_mounts"
cert_role_ctl_remove_tombstone_exact dot "$mount_drift_tombstone" \
    || fail "mount-drift tombstone did not recover on the next run"
pass "tombstone cleanup rechecks the mount boundary after every unlink"

sync_tombstone="$(make_tombstone .delete.202.302)"
original_sync_path="$(declare -f publication_fs_sync_path)"
FAIL_TOMBSTONE_SYNC=1
publication_fs_sync_path() {
    if [[ "$FAIL_TOMBSTONE_SYNC" == 1 && "$1" == "$sync_tombstone" ]]; then
        FAIL_TOMBSTONE_SYNC=0
        return 1
    fi
    sync -f "$1"
}
if cert_role_ctl_remove_tombstone_exact dot "$sync_tombstone"; then
    fail "tombstone file-delete sync failure was accepted"
fi
[[ "$PUBLICATION_FS_DELETE_STATE" == partial-undurable \
   && -d "$sync_tombstone" ]] \
    || fail "partial tombstone sync failure was not resumable"
eval "$original_sync_path"
cert_role_ctl_remove_tombstone_exact dot "$sync_tombstone" \
    || fail "partial-undurable tombstone did not recover"

rmdir_tombstone="$(make_tombstone .delete.203.303)"
REAL_RMDIR="$(command -v rmdir)"
FAIL_RMDIR_PATH="$rmdir_tombstone"
rmdir() {
    local last="${!#}"
    [[ "$last" != "$FAIL_RMDIR_PATH" ]] || return 1
    "$REAL_RMDIR" "$@"
}
if cert_role_ctl_remove_tombstone_exact dot "$rmdir_tombstone"; then
    fail "injected tombstone rmdir failure was accepted"
fi
unset -f rmdir
[[ "$PUBLICATION_FS_DELETE_STATE" == partial && -d "$rmdir_tombstone" ]] \
    || fail "rmdir failure did not retain an empty resumable tombstone"
cert_role_ctl_remove_tombstone_exact dot "$rmdir_tombstone" \
    || fail "empty tombstone did not recover after rmdir failure"

parent_sync_tombstone="$(make_tombstone .delete.204.304)"
original_sync_path="$(declare -f publication_fs_sync_path)"
FAIL_PARENT_SYNC=1
publication_fs_sync_path() {
    if [[ "$FAIL_PARENT_SYNC" == 1 && "$1" == "$CERT_ROOT/dot/generations" ]]; then
        FAIL_PARENT_SYNC=0
        return 1
    fi
    sync -f "$1"
}
if cert_role_ctl_remove_tombstone_exact dot "$parent_sync_tombstone"; then
    fail "post-rmdir generations sync failure was accepted"
fi
[[ "$PUBLICATION_FS_DELETE_STATE" == removed-undurable \
   && ! -e "$parent_sync_tombstone" ]] \
    || fail "post-rmdir sync failure did not report removed-undurable"
eval "$original_sync_path"
pass "tombstone unlink, target sync, rmdir, and parent sync failures are resumable and explicit"

LE_ROOT="$TMP/letsencrypt"
mkdir -p "$LE_ROOT/live/example.test" "$LE_ROOT/archive/example.test"
printf 'lineage-cert\n' > "$LE_ROOT/archive/example.test/fullchain1.pem"
printf 'lineage-key\n' > "$LE_ROOT/archive/example.test/privkey1.pem"
chmod 0644 "$LE_ROOT/archive/example.test/fullchain1.pem"
chmod 0600 "$LE_ROOT/archive/example.test/privkey1.pem"
ln -s ../../archive/example.test/fullchain1.pem "$LE_ROOT/live/example.test/fullchain.pem"
ln -s ../../archive/example.test/privkey1.pem "$LE_ROOT/live/example.test/privkey.pem"
CERT_ROLE_CTL_LINEAGE_LIVE_ROOT="$LE_ROOT/live"
CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT="$LE_ROOT/archive"
cert_role_ctl_lineage_pair_is_safe "$LE_ROOT/live/example.test" example.test \
    || fail "exact Certbot live-to-archive pair was rejected"
rm -f -- "$LE_ROOT/live/example.test/privkey.pem"
ln -s ../../archive/example.test/privkey2.pem "$LE_ROOT/live/example.test/privkey.pem"
printf 'other-key\n' > "$LE_ROOT/archive/example.test/privkey2.pem"
chmod 0600 "$LE_ROOT/archive/example.test/privkey2.pem"
if cert_role_ctl_lineage_pair_is_safe "$LE_ROOT/live/example.test" example.test; then
    fail "mismatched Certbot archive generations were accepted"
fi
pass "lineage deployment accepts only one exact live-to-archive generation"

echo "all certificate-role controller tests passed"
