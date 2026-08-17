#!/usr/bin/env bash
# Explicit disposable-only mount-boundary acceptance for publication-fs.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/publication-fs.sh"

if [[ "${PUBLICATION_FS_PRIVATE_MOUNT_NS:-0}" != 1 ]]; then
    [[ "${EUID:-$(id -u)}" == 0 ]] || { echo "mount acceptance requires root" >&2; exit 1; }
    command -v unshare >/dev/null 2>&1 || { echo "mount acceptance requires unshare" >&2; exit 1; }
    exec unshare -m env PUBLICATION_FS_PRIVATE_MOUNT_NS=1 bash "$0" "$@"
fi

mount --make-rprivate /
TMP="$(mktemp -d /tmp/5gpn-publication-fs-mount.XXXXXX)"
declare -a MOUNTS=()
cleanup() {
    local index
    for ((index = ${#MOUNTS[@]} - 1; index >= 0; index--)); do
        mountpoint -q "${MOUNTS[$index]}" && umount -- "${MOUNTS[$index]}" || true
    done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# shellcheck source=../scripts/publication-fs.sh
source "$HELPER"

make_generation() {
    local root="$1"
    mkdir -p "$root/generations/generation-a/nested"
    chmod 0755 "$root" "$root/generations" \
        "$root/generations/generation-a" "$root/generations/generation-a/nested"
    printf 'managed\n' > "$root/generations/generation-a/payload"
}

pointer_root="$TMP/pointer/root"
pointer_outside="$TMP/pointer/outside"
mkdir -p "$pointer_outside"
make_generation "$pointer_root"
mount --bind "$pointer_outside" "$pointer_root/generations/generation-a"
MOUNTS+=("$pointer_root/generations/generation-a")
if publication_fs_commit_relative_pointer \
    "$pointer_root" current generations/generation-a "" \
    "$(id -u)" "$(id -g)" >/dev/null 2>&1; then
    fail "bind-mounted generation was accepted as a current target"
fi
[[ ! -e "$pointer_root/current" && ! -L "$pointer_root/current" ]] \
    || fail "rejected bind-mounted pointer target changed current"
umount -- "$pointer_root/generations/generation-a"
MOUNTS=()
pass "a pointer cannot publish a generation mountpoint"

scope_root="$TMP/scope/root"
scope_outside="$TMP/scope/outside"
mkdir -p "$scope_root/generations" "$scope_outside/generation-a"
chmod 0755 "$scope_root" "$scope_root/generations" \
    "$scope_outside" "$scope_outside/generation-a"
mount --bind "$scope_outside" "$scope_root/generations"
MOUNTS+=("$scope_root/generations")
if publication_fs_commit_relative_pointer \
    "$scope_root" current generations/generation-a "" \
    "$(id -u)" "$(id -g)" >/dev/null 2>&1; then
    fail "pointer publication accepted a target below a bind-mounted scope"
fi
umount -- "$scope_root/generations"
MOUNTS=()
pass "an intermediate bind-mounted scope fails closed"

managed_mountpoint="$TMP/managed-root/root"
managed_outside="$TMP/managed-root/outside"
mkdir -p "$managed_mountpoint"
make_generation "$managed_outside"
mount --bind "$managed_outside" "$managed_mountpoint"
MOUNTS+=("$managed_mountpoint")
if publication_fs_commit_relative_pointer \
    "$managed_mountpoint" current generations/generation-a "" \
    "$(id -u)" "$(id -g)" >/dev/null 2>&1; then
    fail "bind-mounted managed root was accepted"
fi
umount -- "$managed_mountpoint"
MOUNTS=()
pass "a managed root that is itself a bind mount fails closed"

nested_root="$TMP/nested/root"
nested_outside="$TMP/nested/outside"
mkdir -p "$nested_outside"
make_generation "$nested_root"
printf 'outside-nested\n' > "$nested_outside/sentinel"
mount --bind "$nested_outside" "$nested_root/generations/generation-a/nested"
MOUNTS+=("$nested_root/generations/generation-a/nested")
if publication_fs_commit_relative_pointer \
    "$nested_root" current generations/generation-a "" \
    "$(id -u)" "$(id -g)" >/dev/null 2>&1; then
    fail "pointer publication accepted a generation containing a nested mount"
fi
grep -Fxq outside-nested "$nested_outside/sentinel" \
    || fail "nested mount rejection changed the external sentinel"
pass "a nested bind mount below the target generation fails closed"

echo "all publication filesystem mount acceptance checks passed"
