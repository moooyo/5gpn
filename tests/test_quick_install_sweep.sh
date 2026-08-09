#!/usr/bin/env bash
# The stale-source sweep removes only this entrypoint's inactive, leased
# leftovers. An exec'd installer keeps its lease descriptor, so a concurrent
# quick installer must not remove the active source tree.
#
# /tmp is world-writable, so a name match alone would let any local user hand
# root an rm -rf target. Ownership, mode, link count, marker, lease, and mount
# validation jointly define the deletion boundary.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

# The entrypoint has a sourced-file guard, so exercise the same helpers and
# safety validation production uses rather than a copied function body.
# shellcheck source=../quick-install.sh
source "$ROOT/quick-install.sh"
declare -F sweep_stale_source_dirs >/dev/null || fail "sweep_stale_source_dirs is missing"

# The sweep is hardcoded to /tmp, so the fixtures live there under names that
# cannot collide with a real run.
TMPROOT="$(mktemp -d /tmp/5gpn-installer.SWEEPTEST.XXXXXX)"
suffix="$(basename -- "$TMPROOT")"
owned="/tmp/5gpn-installer.sweepcase-${suffix}-owned"
current="/tmp/5gpn-installer.sweepcase-${suffix}-current"
active="/tmp/5gpn-installer.sweepcase-${suffix}-active"
legacy="/tmp/5gpn-installer.sweepcase-${suffix}-legacy"
foreign="/tmp/5gpn-installer.sweepcase-${suffix}-foreign"
wrongvalue="/tmp/5gpn-installer.sweepcase-${suffix}-wrongvalue"
active_pid=""
cleanup() {
    [[ -z "$active_pid" ]] || { kill "$active_pid" 2>/dev/null || true; wait "$active_pid" 2>/dev/null || true; }
    rm -rf -- "$TMPROOT" "$owned" "$current" "$active" "$legacy" "$foreign" "$wrongvalue"
}
trap cleanup EXIT

mkdir -p "$owned" "$current" "$legacy" "$foreign" "$wrongvalue"
chmod 0700 "$owned" "$current" "$legacy" "$foreign" "$wrongvalue"
printf '%s\n' "$SOURCE_MARKER_VALUE" > "$owned/$SOURCE_MARKER"
printf '%s\n' "$SOURCE_MARKER_VALUE" > "$current/$SOURCE_MARKER"
printf '%s\n' "$SOURCE_MARKER_VALUE" > "$legacy/$SOURCE_MARKER"
printf '%s\n' "$SOURCE_LEASE_VALUE" > "$owned/$SOURCE_LEASE"
printf '%s\n' "$SOURCE_LEASE_VALUE" > "$current/$SOURCE_LEASE"
chmod 0600 "$owned/$SOURCE_MARKER" "$current/$SOURCE_MARKER" \
    "$legacy/$SOURCE_MARKER" "$owned/$SOURCE_LEASE" "$current/$SOURCE_LEASE"
printf '%s\n' "5gpn-quick-install-v0" > "$wrongvalue/$SOURCE_MARKER"
# $foreign gets no marker at all: a directory someone else put in /tmp.
printf 'do not delete\n' > "$foreign/evidence"

# Start a real child that acquires the source lease and then execs another Bash
# process. The sweep must observe the inherited descriptor, not a lock held by
# this test shell.
ready="$TMPROOT/active.ready"
QUICK="$ROOT/quick-install.sh" TARGET="$active" READY="$ready" bash -c '
  set -euo pipefail
  source "$QUICK"
  prepare_source_dir "$TARGET"
  : > "$READY"
  exec bash -c "sleep 60"
' >/dev/null 2>&1 &
active_pid=$!
deadline=$((SECONDS + 10))
while [[ ! -e "$ready" && "$SECONDS" -lt "$deadline" ]]; do sleep 0.05; done
[[ -e "$ready" ]] || fail "exec lease fixture did not become ready"

sweep_stale_source_dirs "$current"

[[ ! -e "$owned" ]] || fail "a stale directory this entrypoint owns survived the sweep"
pass "a stale directory carrying the ownership marker is removed"

[[ -d "$current" ]] || fail "the sweep removed the directory the current run is about to use"
pass "the current run's directory is kept"

[[ -d "$active" ]] || fail "the sweep removed an actively leased source"
pass "an active installer source survives a concurrent sweep"

[[ -d "$legacy" ]] || fail "the sweep removed a lease-less legacy source"
pass "absence of a lease is not treated as proof that a legacy run is idle"

kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
active_pid=""
sweep_stale_source_dirs "$current"
[[ ! -e "$active" ]] || fail "an exited installer source remained locked"
pass "the inherited lease releases when the exec'd installer exits"

[[ -d "$foreign" && -f "$foreign/evidence" ]] \
    || fail "the sweep removed an unmarked /tmp directory it does not own"
pass "an unmarked directory is refused"

[[ -d "$wrongvalue" ]] || fail "the sweep removed a directory whose marker value does not match"
pass "a directory with a foreign marker value is refused"

grep -Fq 'mktemp "$_QI_SOURCE_DIR/.bundle.tgz.' "$ROOT/quick-install.sh" \
    && grep -Fq 'mktemp "$_QI_SOURCE_DIR/.checksums.txt.' "$ROOT/quick-install.sh" \
    || fail "bundle temporaries are not scoped beneath the leased source"
pass "bundle temporaries live under the same lease instead of a global glob"

# The sweep must run on the production path (no requested dir) and only there:
# the safety tests pass an explicit directory and must not have /tmp swept.
prep="$(sed -n '/^prepare_source_dir()/,/^}/p' "$ROOT/quick-install.sh")"
printf '%s' "$prep" | grep -Fq 'sweep_stale_source_dirs "$canonical"' \
    || fail "prepare_source_dir does not sweep on the production path"
[[ "$(printf '%s' "$prep" | grep -c 'sweep_stale_source_dirs')" == 1 ]] \
    || fail "prepare_source_dir sweeps outside the private-mktemp branch"
pass "the sweep runs only where the entrypoint allocated the directory itself"

# It has to be a sweep rather than a trap, because exec replaces the shell.
grep -Fq 'exec bash ./install.sh' "$ROOT/quick-install.sh" \
    || fail "quick-install no longer execs; an EXIT trap would now work and is simpler"
pass "the entrypoint still execs, which is why cleanup happens on the next run"

# A mount at the source root is just as unsafe as a nested mount.
mount_fixture="$TMPROOT/mount-root"
mkdir -p "$mount_fixture"
findmnt() { printf '%s\n' "$mount_fixture"; }
source_dir_has_no_nested_mounts "$mount_fixture" \
    && fail "a source that is itself a mountpoint was accepted"
unset -f findmnt
pass "source cleanup refuses a mount at its own root"

echo "quick-install temp sweep: PASS"
