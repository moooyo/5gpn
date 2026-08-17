#!/usr/bin/env bash
# Disposable-only real mount rejection for the certificate-role publisher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${CERT_ROLE_PRIVATE_MOUNT_NS:-0}" != 1 ]]; then
    [[ "${EUID:-$(id -u)}" == 0 ]] || { echo "root is required" >&2; exit 1; }
    command -v unshare >/dev/null 2>&1 || { echo "unshare is required" >&2; exit 1; }
    exec unshare -m env CERT_ROLE_PRIVATE_MOUNT_NS=1 bash "$0" "$@"
fi
mount --make-rprivate /

TMP="$(mktemp -d /tmp/5gpn-cert-role-mount.XXXXXX)"
MOUNTED=""
cleanup() {
    [[ -z "$MOUNTED" ]] || { mountpoint -q "$MOUNTED" && umount -- "$MOUNTED" || true; }
    rm -rf -- "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../scripts/publication-fs.sh
source "$ROOT/scripts/publication-fs.sh"
# shellcheck source=../scripts/cert-role-ctl.sh
source "$ROOT/scripts/cert-role-ctl.sh"

CONFIG_ROOT="$TMP/config"
CERT_ROLE_CTL_ROOT="$CONFIG_ROOT/cert"
CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
CERT_ROLE_CTL_ALLOW_CREATE=1
CERT_ROLE_CTL_SERVICE_GROUP="$(id -gn)"
CERT_ROLE_CTL_SERVICE_GID="$(id -g)"
CERT_ROLE_CTL_STAGE_PARENT="$TMP/run"
mkdir -p "$CERT_ROLE_CTL_ROOT" "$CERT_ROLE_CTL_STAGE_PARENT"
chmod 0755 "$CONFIG_ROOT"
chmod 0751 "$CERT_ROLE_CTL_ROOT"
chmod 0700 "$CERT_ROLE_CTL_STAGE_PARENT"
printf '5gpn-config\n' > "$CONFIG_ROOT/.5gpn-owned"
printf '5gpn-cert-root-v1\n' > "$CERT_ROLE_CTL_ROOT/.5gpn-cert-root-owned"
chmod 0644 "$CONFIG_ROOT/.5gpn-owned" "$CERT_ROLE_CTL_ROOT/.5gpn-cert-root-owned"
cert_role_ctl_group_gid_override() { id -g; }

source_pair="$TMP/source"
mkdir "$source_pair"
printf 'cert\n' > "$source_pair/fullchain.pem"
printf 'key\n' > "$source_pair/privkey.pem"
chmod 0600 "$source_pair"/*
accept_pair() { return 0; }
cert_role_ctl_publish_pair "$source_pair/fullchain.pem" "$source_pair/privkey.pem" accept_pair \
    || fail "could not establish certificate-role fixture"

outside="$TMP/outside-generation"
mkdir "$outside"
printf 'outside-cert\n' > "$outside/fullchain.pem"
printf 'outside-key\n' > "$outside/privkey.pem"
chmod 0750 "$outside"
chmod 0640 "$outside"/*
target="$CERT_ROLE_CTL_ROOT/dot/generations/generation-20000101T000000Z-88-88"
mkdir "$target"
chmod 0750 "$target"
mount --bind "$outside" "$target"
MOUNTED="$target"
if cert_role_ctl_scrub_role dot >/dev/null 2>&1; then
    fail "bind-mounted non-current certificate generation was accepted"
fi
grep -Fxq outside-cert "$outside/fullchain.pem" \
    || fail "mount rejection changed the external certificate sentinel"
umount -- "$target"
MOUNTED=""

nested="$CERT_ROLE_CTL_ROOT/dot/generations/generation-20000101T000000Z-77-77"
mkdir "$nested"
chmod 0750 "$nested"
printf 'managed-cert\n' > "$nested/fullchain.pem"
printf 'managed-key\n' > "$nested/privkey.pem"
chmod 0640 "$nested"/*
outside_file="$TMP/outside-file"
printf 'outside-file\n' > "$outside_file"
mount --bind "$outside_file" "$nested/fullchain.pem"
MOUNTED="$nested/fullchain.pem"
if cert_role_ctl_scrub_role dot >/dev/null 2>&1; then
    fail "nested bind mount inside a certificate generation was accepted"
fi
grep -Fxq outside-file "$outside_file" \
    || fail "nested mount rejection changed the external file"
umount -- "$nested/fullchain.pem"
MOUNTED=""

scope_outside="$TMP/outside-scope"
mkdir "$scope_outside"
printf 'outside-scope\n' > "$scope_outside/sentinel"
mount --bind "$scope_outside" "$CERT_ROLE_CTL_ROOT/dot/generations"
MOUNTED="$CERT_ROLE_CTL_ROOT/dot/generations"
if cert_role_ctl_scrub_role dot >/dev/null 2>&1; then
    fail "bind-mounted certificate generation scope was accepted"
fi
grep -Fxq outside-scope "$scope_outside/sentinel" \
    || fail "generation-scope rejection changed the external sentinel"
umount -- "$CERT_ROLE_CTL_ROOT/dot/generations"
MOUNTED=""

tombstone="$CERT_ROLE_CTL_ROOT/dot/generations/.delete.901.902"
mkdir "$tombstone"
chmod 0750 "$tombstone"
cp "$CERT_ROLE_CTL_ROOT/dot/current/fullchain.pem" "$tombstone/fullchain.pem"
cp "$CERT_ROLE_CTL_ROOT/dot/current/privkey.pem" "$tombstone/privkey.pem"
chmod 0640 "$tombstone"/*
tombstone_outside="$TMP/tombstone-outside"
printf 'outside-key\n' > "$tombstone_outside"
original_sync_path="$(declare -f publication_fs_sync_path)"
publication_fs_sync_path() {
    sync -f "$1" || return 1
    if [[ "$1" == "$tombstone" && ! -e "$TMP/tombstone-mount-injected" ]]; then
        mount --bind "$tombstone_outside" "$tombstone/privkey.pem"
        MOUNTS+=("$tombstone/privkey.pem")
        : > "$TMP/tombstone-mount-injected"
    fi
}
if cert_role_ctl_remove_tombstone_exact dot "$tombstone" >/dev/null 2>&1; then
    fail "nested mount injected after the first unlink was accepted"
fi
[[ "$PUBLICATION_FS_DELETE_STATE" == partial \
   && -d "$tombstone" && -f "$tombstone/privkey.pem" ]] \
    || fail "post-unlink mount drift did not retain the second file and tombstone"
grep -Fxq outside-key "$tombstone_outside" \
    || fail "post-unlink mount rejection changed the external file"
umount -- "$tombstone/privkey.pem"
MOUNTS=()
eval "$original_sync_path"
cert_role_ctl_remove_tombstone_exact dot "$tombstone" \
    || fail "tombstone did not converge after the injected mount was removed"

echo "certificate-role real mount rejection passed"
