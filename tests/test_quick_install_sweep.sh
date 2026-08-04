#!/usr/bin/env bash
# The stale-source sweep: removes this entrypoint's own leftovers, keeps the
# current run's directory, and refuses anything it does not own.
#
# /tmp is world-writable, so a name match alone would let any local user hand
# root an rm -rf target. The marker is the whole safety property.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

# Extract the sweep and its two marker constants rather than sourcing the whole
# entrypoint, which would run its argument parsing and its exec.
eval "$(sed -n 's/^readonly \(SOURCE_MARKER=.*\)$/\1/p;s/^readonly \(SOURCE_MARKER_VALUE=.*\)$/\1/p' "$ROOT/quick-install.sh")"
[[ -n "${SOURCE_MARKER:-}" && -n "${SOURCE_MARKER_VALUE:-}" ]] \
    || fail "could not read the source-directory ownership marker"
eval "$(sed -n '/^sweep_stale_source_dirs()/,/^}/p' "$ROOT/quick-install.sh")"
declare -F sweep_stale_source_dirs >/dev/null || fail "sweep_stale_source_dirs is missing"

# The sweep is hardcoded to /tmp, so the fixtures live there under names that
# cannot collide with a real run.
TMPROOT="$(mktemp -d /tmp/5gpn-installer.SWEEPTEST.XXXXXX)"
trap 'rm -rf -- "$TMPROOT" /tmp/5gpn-installer.sweepcase-* /tmp/5gpn-installer.tgz.sweepcase /tmp/5gpn-checksums.txt.sweepcase' EXIT

owned="/tmp/5gpn-installer.sweepcase-owned"
current="/tmp/5gpn-installer.sweepcase-current"
foreign="/tmp/5gpn-installer.sweepcase-foreign"
wrongvalue="/tmp/5gpn-installer.sweepcase-wrongvalue"
mkdir -p "$owned" "$current" "$foreign" "$wrongvalue"
printf '%s\n' "$SOURCE_MARKER_VALUE" > "$owned/$SOURCE_MARKER"
printf '%s\n' "$SOURCE_MARKER_VALUE" > "$current/$SOURCE_MARKER"
printf '%s\n' "5gpn-quick-install-v0" > "$wrongvalue/$SOURCE_MARKER"
# $foreign gets no marker at all: a directory someone else put in /tmp.
printf 'do not delete\n' > "$foreign/evidence"
: > /tmp/5gpn-installer.tgz.sweepcase
: > /tmp/5gpn-checksums.txt.sweepcase

sweep_stale_source_dirs "$current"

[[ ! -e "$owned" ]] || fail "a stale directory this entrypoint owns survived the sweep"
pass "a stale directory carrying the ownership marker is removed"

[[ -d "$current" ]] || fail "the sweep removed the directory the current run is about to use"
pass "the current run's directory is kept"

[[ -d "$foreign" && -f "$foreign/evidence" ]] \
    || fail "the sweep removed an unmarked /tmp directory it does not own"
pass "an unmarked directory is refused"

[[ -d "$wrongvalue" ]] || fail "the sweep removed a directory whose marker value does not match"
pass "a directory with a foreign marker value is refused"

[[ ! -e /tmp/5gpn-installer.tgz.sweepcase ]] || fail "a leaked bundle download survived"
[[ ! -e /tmp/5gpn-checksums.txt.sweepcase ]] || fail "a leaked checksums file survived"
pass "leaked bundle and checksums temporaries are removed"

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

echo "quick-install temp sweep: PASS"
