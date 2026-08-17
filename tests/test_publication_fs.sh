#!/usr/bin/env bash
# Behavioral checks for shared durable-publication filesystem primitives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/publication-fs.sh"
TMP="$(mktemp -d /tmp/5gpn-publication-fs.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# shellcheck source=../scripts/publication-fs.sh
source "$HELPER"

publication_fs_mount_target_text_is_safe / \
    || fail "root filesystem mount target text was rejected"

EXPECTED_UID="$(id -u)"
EXPECTED_GID="$(id -g)"

new_root() {
    local root="$1"
    mkdir -p "$root/generations/generation-a" "$root/generations/generation-b"
    chmod 0755 "$root" "$root/generations" \
        "$root/generations/generation-a" "$root/generations/generation-b"
    printf 'a\n' > "$root/generations/generation-a/payload"
    printf 'b\n' > "$root/generations/generation-b/payload"
}

root="$TMP/root"
new_root "$root"
publication_fs_commit_relative_pointer \
    "$root" current generations/generation-a "" "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not publish the first relative pointer"
[[ "$PUBLICATION_FS_COMMIT_STATE" == committed \
   && "$(readlink -- "$root/current")" == generations/generation-a ]] \
    || fail "first pointer commit was not durable and exact"

if publication_fs_commit_relative_pointer \
    "$root" current generations/generation-b generations/not-current \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "stale expected pointer was accepted"
fi
[[ "$(readlink -- "$root/current")" == generations/generation-a ]] \
    || fail "stale pointer rejection changed current"

publication_fs_commit_relative_pointer \
    "$root" current generations/generation-b generations/generation-a \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not replace the validated relative pointer"
[[ "$PUBLICATION_FS_COMMIT_STATE" == committed \
   && "$(readlink -- "$root/current")" == generations/generation-b ]] \
    || fail "replacement pointer commit was not durable and exact"
pass "relative pointers commit with an exact compare-and-swap boundary"

commit_drift_root="$TMP/commit-drift-root"
new_root "$commit_drift_root"
publication_fs_commit_relative_pointer \
    "$commit_drift_root" current generations/generation-a "" \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not establish pointer-CAS drift fixture"
REAL_LN="$(command -v ln)"
ln() {
    local args=("$@") last_index last
    "$REAL_LN" "${args[@]}"
    last_index=$((${#args[@]} - 1))
    last="${args[$last_index]}"
    if [[ -n "${DRIFT_COMMIT_ROOT:-}" \
       && "$last" == "$DRIFT_COMMIT_ROOT"/.current.new.* ]]; then
        rm -f -- "$DRIFT_COMMIT_ROOT/current"
        "$REAL_LN" -s -- "$DRIFT_COMMIT_TARGET" "$DRIFT_COMMIT_ROOT/current"
        : > "$DRIFT_COMMIT_SENTINEL"
    fi
}
DRIFT_COMMIT_TARGET=generations/generation-b
DRIFT_COMMIT_SENTINEL="$TMP/commit-drift-injected"
DRIFT_COMMIT_ROOT="$commit_drift_root"
if publication_fs_commit_relative_pointer \
    "$commit_drift_root" current generations/generation-b generations/generation-a \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "pointer drift after temporary-link creation was accepted"
fi
unset -f ln
[[ -e "$DRIFT_COMMIT_SENTINEL" \
   && "$PUBLICATION_FS_COMMIT_STATE" == not-committed \
   && "$(readlink -- "$commit_drift_root/current")" == generations/generation-b ]] \
    || fail "final pointer CAS recheck overwrote the concurrent current target"
find "$commit_drift_root" -maxdepth 1 -name '.current.new.*' -print -quit | grep -q . \
    && fail "pointer CAS rejection retained its temporary symlink"
pass "final pointer CAS recheck rejects drift after temporary-link creation"

sync_root="$TMP/sync-root"
new_root "$sync_root"
original_sync_path="$(declare -f publication_fs_sync_path)"
FAIL_SYNC_PATH="$sync_root"
publication_fs_sync_path() {
    if [[ "${FAIL_SYNC_PATH:-}" == "$1" ]]; then
        return 1
    fi
    sync -f "$1"
}
if publication_fs_commit_relative_pointer \
        "$sync_root" current generations/generation-a "" \
        "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "post-rename directory sync failure was accepted"
fi
eval "$original_sync_path"
[[ "$PUBLICATION_FS_COMMIT_STATE" == committed-undurable \
   && "$(readlink -- "$sync_root/current")" == generations/generation-a ]] \
    || fail "sync failure rolled back or hid the already visible pointer"
pass "post-rename sync failure is committed-but-unconfirmed and never rolls back"

literal_root="$TMP/literal-root"
mkdir -p "$literal_root/absent"
chmod 0755 "$literal_root" "$literal_root/absent"
printf 'literal-current\n' > "$literal_root/absent/payload"
publication_fs_commit_relative_pointer \
    "$literal_root" current absent "" "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not publish a valid target literally named absent"
[[ "$(publication_fs_pointer_target "$literal_root" "$literal_root/current" "$EXPECTED_UID" "$EXPECTED_GID")" == absent ]] \
    || fail "literal target named absent collided with the no-pointer sentinel"
[[ -f "$literal_root/absent/payload" ]] \
    || fail "literal target named absent was not protected as current"
pass "the no-pointer sentinel cannot collide with a legal relative target"

orphan_root="$TMP/orphan-root"
new_root "$orphan_root"
ln -s generations/generation-a "$orphan_root/.current.new.123.456"
publication_fs_cleanup_orphan_pointer \
    "$orphan_root" "$orphan_root/.current.new.123.456" .current.new \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not clean a validated UI-style orphan pointer"
[[ ! -e "$orphan_root/.current.new.123.456" \
   && ! -L "$orphan_root/.current.new.123.456" ]] \
    || fail "validated UI-style orphan pointer remained"
ln -s generations/generation-b "$orphan_root/.current.123.456"
publication_fs_cleanup_orphan_pointer \
    "$orphan_root" "$orphan_root/.current.123.456" .current \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not clean a validated certificate-style orphan pointer"
ln -s /tmp "$orphan_root/.current.new.123.789"
if publication_fs_cleanup_orphan_pointer \
    "$orphan_root" "$orphan_root/.current.new.123.789" .current.new \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "unsafe orphan pointer target was accepted"
fi
[[ -L "$orphan_root/.current.new.123.789" ]] \
    || fail "unsafe orphan rejection removed evidence before validation"
rm -f -- "$orphan_root/.current.new.123.789"
pass "domain-selected UI and certificate orphan prefixes clean safely"
space_root="$TMP/root with space"
new_root "$space_root"
if publication_fs_commit_relative_pointer \
    "$space_root" current generations/generation-a "" \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "whitespace-bearing managed path was accepted"
fi
[[ ! -e "$space_root/current" && ! -L "$space_root/current" ]] \
    || fail "whitespace path rejection changed publication state"
escaped_root="$TMP/root\\escape"
new_root "$escaped_root"
if publication_fs_commit_relative_pointer \
    "$escaped_root" current generations/generation-a "" \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "findmnt-escaped backslash path was accepted"
fi
[[ ! -e "$escaped_root/current" && ! -L "$escaped_root/current" ]] \
    || fail "backslash path rejection changed publication state"
pass "managed publication paths reject every findmnt-escaped spelling"

mount_table_root="$TMP/mount-table-root"
new_root "$mount_table_root"
REAL_FINDMNT="$(command -v findmnt)"
MOUNT_TABLE_MODE=unrelated
MOUNT_TABLE_TARGET="$mount_table_root/generations/generation-a"
findmnt() {
    "$REAL_FINDMNT" "$@"
    local rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    if [[ " $* " == *" -R "* && " $* " == *" -o TARGET "* ]]; then
        case "$MOUNT_TABLE_MODE" in
            unrelated) printf '%s\n' '/run/credentials/getty@tty1.service' ;;
            in-scope) printf '%s\n' "$MOUNT_TABLE_TARGET/unsafe@mount" ;;
        esac
    fi
}
publication_fs_commit_relative_pointer \
    "$mount_table_root" current generations/generation-a "" \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "an unrelated mount target with punctuation poisoned publication"
[[ "$(readlink -- "$mount_table_root/current")" == generations/generation-a ]] \
    || fail "unrelated mount-table entry changed the committed pointer"
MOUNT_TABLE_MODE=in-scope
MOUNT_TABLE_TARGET="$mount_table_root/generations/generation-b"
if publication_fs_commit_relative_pointer \
    "$mount_table_root" current generations/generation-b generations/generation-a \
    "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "an unsafe in-scope nested mount target was ignored"
fi
unset -f findmnt
[[ "$(readlink -- "$mount_table_root/current")" == generations/generation-a ]] \
    || fail "in-scope mount rejection changed current"
pass "unrelated unsafe mount names cannot poison scope checks, while in-scope ones fail"

commit_mount_drift_root="$TMP/commit-mount-drift-root"
new_root "$commit_mount_drift_root"
publication_fs_commit_relative_pointer \
    "$commit_mount_drift_root" current generations/generation-a "" \
    "$EXPECTED_UID" "$EXPECTED_GID" \
    || fail "could not establish final pointer/mount drift fixture"
DRIFT_SENTINEL="$TMP/commit-mount-drift-injected"
DRIFT_POINTER="$commit_mount_drift_root/current"
DRIFT_TARGET=generations/generation-b
MOUNT_BOUNDARY_CALLS=0
original_mount_boundary="$(declare -f publication_fs_mount_boundary_is_safe)"
eval "${original_mount_boundary/publication_fs_mount_boundary_is_safe/original_publication_fs_mount_boundary_is_safe}"
publication_fs_mount_boundary_is_safe() {
    original_publication_fs_mount_boundary_is_safe "$@" || return 1
    MOUNT_BOUNDARY_CALLS=$((MOUNT_BOUNDARY_CALLS + 1))
    if [[ "$MOUNT_BOUNDARY_CALLS" == 2 && ! -e "$DRIFT_SENTINEL" ]]; then
        rm -f -- "$DRIFT_POINTER"
        ln -s -- "$DRIFT_TARGET" "$DRIFT_POINTER"
        : > "$DRIFT_SENTINEL"
    fi
}
if publication_fs_commit_relative_pointer \
        "$commit_mount_drift_root" current generations/generation-b \
        generations/generation-a "$EXPECTED_UID" "$EXPECTED_GID" >/dev/null 2>&1; then
    fail "pointer drift during final mount validation was accepted"
fi
eval "$original_mount_boundary"
unset -f original_publication_fs_mount_boundary_is_safe
[[ -e "$DRIFT_SENTINEL" \
   && "$PUBLICATION_FS_COMMIT_STATE" == not-committed \
   && "$(readlink -- "$commit_mount_drift_root/current")" == generations/generation-b ]] \
    || fail "pointer commit did not re-read current after final mount validation"
find "$commit_mount_drift_root" -maxdepth 1 -name '.current.new.*' -print -quit | grep -q . \
    && fail "final mount-drift rejection retained its temporary pointer"
pass "pointer commit re-reads current after final mount validation"

echo "all publication filesystem tests passed"
