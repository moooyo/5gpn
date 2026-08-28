#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
UNIT="$ROOT/etc/systemd/5gpn-mihomo.service"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

grep -Fq 'MIN_EXTENSION_WORKER_KERNEL_MAJOR=5' "$INSTALL" \
    && grep -Fq 'MIN_EXTENSION_WORKER_KERNEL_MINOR=7' "$INSTALL" \
    && grep -Fq 'MIN_EXTENSION_WORKER_SYSTEMD_VERSION=257' "$INSTALL" \
    && grep -Fq 'MIN_WORKER_KERNEL_MAJOR=5' "$QUICK" \
    && grep -Fq 'MIN_WORKER_KERNEL_MINOR=7' "$QUICK" \
    && grep -Fq 'MIN_WORKER_SYSTEMD_VERSION=257' "$QUICK" \
    || fail "full and quick installers disagree on the worker-isolation baseline"
pass "full and quick installers pin Linux 5.7 and systemd 257"

for directive in \
    'OOMPolicy=continue' \
    'KillMode=control-group' \
    'MemoryAccounting=yes' \
    'TasksAccounting=yes' \
    'Delegate=memory pids' \
    'ProtectControlGroups=private' \
    'SystemCallFilter=~unshare setns'; do
    [[ "$(grep -Fxc "$directive" "$UNIT" || true)" == 1 ]] \
        || fail "5gpn-mihomo.service must contain exactly one $directive"
done
grep -Fxq '# 5gpn-unit-id: 5gpn-mihomo.service:v3' "$UNIT" \
    || fail "worker-isolation unit revision is not v3"
grep -Fxq 'ProtectControlGroups=yes' "$UNIT" \
    && fail "the main unit still hides the delegated cgroup hierarchy" \
    || true
grep -Eq '^RestrictNamespaces=' "$UNIT" \
    && fail "RestrictNamespaces blocks the clone3 cgroup-FD worker spawn" \
    || true
grep -Eq '^DelegateSubgroup=' "$UNIT" \
    && fail "DelegateSubgroup hides the private delegated unit root" \
    || true
pass "the main unit pins the delegated worker memory and lifecycle contract"

full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
line_of() {
    grep -nF "$2" <<<"$1" | head -1 | cut -d: -f1
}
preflight_line="$(line_of "$full_fn" 'preflight_extension_worker_isolation_host')"
publication_line="$(line_of "$full_fn" 'INSTALL_PUBLICATION_STARTED=1')"
claim_line="$(line_of "$full_fn" 'claim_project_roots')"
if [[ -n "$preflight_line" && -n "$publication_line" && -n "$claim_line" \
   && "$preflight_line" -lt "$publication_line" \
   && "$publication_line" -lt "$claim_line" ]]; then
    pass "worker-isolation host checks precede the first publication boundary"
else
    fail "worker-isolation host checks can run after project publication starts"
fi

preflight_fn="$(sed -n '/^preflight_extension_worker_isolation_host()/,/^}/p' "$INSTALL")"
verify_fn="$(sed -n '/^verify_systemd_unit_candidates()/,/^}/p' "$INSTALL")"
for check in \
    'kernel_release_supports_extension_workers "$kernel_release"' \
    'host_uses_pure_cgroup_v2' \
    'host_has_cgroup_v2_worker_controllers' \
    'systemd_version_supports_extension_workers "$systemd_version"' \
    'systemd_unit_has_dropins 5gpn-mihomo.service' \
    'verify_systemd_unit_candidates'; do
    grep -Fq "$check" <<<"$preflight_fn" \
        || fail "host preflight omitted: $check"
done
grep -Fq 'systemd-analyze verify "${candidates[@]}"' <<<"$verify_fn" \
    || fail "candidate units are not checked by systemd-analyze verify"
grep -Fq 'Candidate systemd units failed systemd-analyze verify; no project file was published.' <<<"$verify_fn" \
    || fail "candidate verification failure does not identify the pre-publication boundary"
for substitution in \
    "s|^ExecStartPre=+/opt/5gpn/scripts/configure-runtime-gate.sh wait$|ExecStartPre=+/bin/true|" \
    "s|^ExecStartPre=/opt/5gpn/scripts/configure-runtime-gate.sh validate-ui$|ExecStartPre=/bin/true|" \
    "s|^ExecStart=.*$|ExecStart=/bin/true|" \
    's/^User=.*$/User=root/' \
    's/^Group=.*$/Group=root/' \
    's/^SupplementaryGroups=.*$/SupplementaryGroups=root/'; do
    grep -Fq "$substitution" <<<"$verify_fn" \
        || fail "fresh-host candidate verification omitted its bounded substitution: $substitution"
done
grep -Eq "s[/|].*\^(Protect|Delegate|MemoryAccounting|TasksAccounting|OOMPolicy|KillMode|SystemCallFilter)" <<<"$verify_fn" \
    && fail "candidate verification rewrites an isolation directive" \
    || true
grep -Fq 'for unit in "${MANAGED_SYSTEMD_UNITS[@]}"' <<<"$verify_fn" \
    || fail "candidate verification does not consume the shared six-unit manifest"
managed_units_decl="$(sed -n '/^declare -ar MANAGED_SYSTEMD_UNITS=(/,/^)/p' "$INSTALL")"
for unit in 5gpn-mihomo.service 5gpn-intercept-cert.service \
            5gpn-intercept-cert.path 5gpn-intercept-cert.timer \
            5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
    grep -Fq "    $unit" <<<"$managed_units_decl" \
        || fail "candidate verification manifest omits $unit"
done
[[ "$(grep -Ec '^[[:space:]]+5gpn-.*\.(service|path|timer)$' <<<"$managed_units_decl")" == 6 ]] \
    || fail "candidate verification manifest does not contain exactly six units"
global_dropin_fn="$(sed -n '/^systemd_global_dropin_has_managed_override()/,/^}/p' "$INSTALL")"
grep -Fq 'systemd_global_dropin_key_is_managed' "$INSTALL" \
    && fail "global resource override gate returned to an incomplete directive denylist"
for section in \
    "service:'[Service]'" "service:'[Unit]'" "service:'[Install]'" \
    "path:'[Path]'" "path:'[Unit]'" "path:'[Install]'" \
    "timer:'[Timer]'" "timer:'[Unit]'" "timer:'[Install]'"; do
    grep -Fq "$section" <<<"$global_dropin_fn" \
        || fail "global override gate omits applicable section: $section"
done
grep -Fq '[[ "$line" == *=* ]] && return 0' <<<"$global_dropin_fn" \
    || fail "global override gate does not reject every applicable assignment"
for legacy_key in MemoryLimit CPUShares StartupCPUShares BlockIOWeight \
                  StartupBlockIOWeight BlockIODeviceWeight \
                  BlockIOReadBandwidth BlockIOWriteBandwidth; do
    grep -Fq "$legacy_key" "$ROOT/tests/test_installer_safety.sh" \
        || fail "resource override policy lacks legacy-key coverage: $legacy_key"
done
pass "host capabilities and every candidate unit are verified before publication"

INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$INSTALL"

UNIT_SOURCE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/5gpn-six-units.XXXXXX")"
mkdir -p "$UNIT_SOURCE_TMP/etc/systemd"
cp "$ROOT"/etc/systemd/* "$UNIT_SOURCE_TMP/etc/systemd/"
ORIGINAL_SCRIPT_DIR="$SCRIPT_DIR"
ORIGINAL_BASE_DIR="$BASE_DIR"
SCRIPT_DIR="$UNIT_SOURCE_TMP"
BASE_DIR="$UNIT_SOURCE_TMP/no-installed-fallback"
VERIFY_ARGUMENTS="$UNIT_SOURCE_TMP/verify-arguments"
systemd-analyze() {
    [[ "${1:-}" == verify ]] || return 1
    shift
    printf '%s\n' "$@" > "$VERIFY_ARGUMENTS"
    [[ "$#" == 6 ]] || return 1
    local candidate
    for candidate in "$@"; do
        [[ -f "$candidate" ]] || return 1
        grep -Fq 'X04InvalidDirective=yes' "$candidate" && return 1
    done
    return 0
}
err() { :; }
verify_systemd_unit_candidates \
    || fail "the complete six-unit static candidate set was rejected"
[[ "$(wc -l < "$VERIFY_ARGUMENTS")" == 6 ]] \
    || fail "systemd-analyze did not receive all six byte-derived candidates"
printf '%s\n' 'X04InvalidDirective=yes' >> "$UNIT_SOURCE_TMP/etc/systemd/5gpn-certbot-renew.service"
if verify_systemd_unit_candidates; then
    fail "a broken static renewal service passed candidate verification"
fi
SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR"
BASE_DIR="$ORIGINAL_BASE_DIR"
rm -rf -- "$UNIT_SOURCE_TMP"
unset -f systemd-analyze
pass "static renewal units participate in the same fail-before-publication verification"

kernel_release_supports_extension_workers 5.7.0 \
    || fail "minimum Linux kernel 5.7 was rejected"
kernel_release_supports_extension_workers 6.0.0 \
    || fail "newer Linux kernel was rejected"
kernel_release_supports_extension_workers 5.6.99 \
    && fail "Linux kernel older than 5.7 was accepted" \
    || true
kernel_release_supports_extension_workers malformed \
    && fail "malformed Linux kernel release was accepted" \
    || true
systemd_version_supports_extension_workers '257.3-1' \
    || fail "minimum systemd 257 was rejected"
systemd_version_supports_extension_workers '258' \
    || fail "newer systemd was rejected"
systemd_version_supports_extension_workers '256.99' \
    && fail "systemd older than 257 was accepted" \
    || true
systemd_version_supports_extension_workers malformed \
    && fail "malformed systemd version was accepted" \
    || true
pass "kernel and systemd minimum versions are compared explicitly"

ERROR_LOG="$(mktemp "${TMPDIR:-/tmp}/5gpn-worker-preflight-errors.XXXXXX")"
VERIFY_MARKER="$(mktemp "${TMPDIR:-/tmp}/5gpn-worker-preflight-verify.XXXXXX")"
trap 'rm -f -- "$ERROR_LOG" "$VERIFY_MARKER"' EXIT
err() { printf '%s\n' "$*" >> "$ERROR_LOG"; }
uname() {
    case "${1:-}" in
        -s) printf '%s\n' "${TEST_KERNEL_NAME:-Linux}" ;;
        -r) printf '%s\n' "${TEST_KERNEL_RELEASE:-6.1.0}" ;;
        *) return 1 ;;
    esac
}
current_systemd_manager_version() { printf '%s\n' "${TEST_SYSTEMD_VERSION:-258}"; }
host_uses_pure_cgroup_v2() { return "${TEST_PURE_CGROUP_RESULT:-0}"; }
host_has_cgroup_v2_worker_controllers() { return "${TEST_WORKER_CONTROLLERS_RESULT:-0}"; }
systemd_unit_has_dropins() { return "${TEST_UNIT_OVERRIDE_RESULT:-1}"; }
verify_systemd_unit_candidates() { : > "$VERIFY_MARKER"; return "${TEST_VERIFY_RESULT:-0}"; }

: > "$ERROR_LOG"
rm -f -- "$VERIFY_MARKER"
preflight_extension_worker_isolation_host \
    || fail "a supported worker-isolation host was rejected"
[[ -f "$VERIFY_MARKER" ]] \
    || fail "supported host did not reach candidate unit verification"

TEST_KERNEL_RELEASE=5.6.99
: > "$ERROR_LOG"
if preflight_extension_worker_isolation_host; then
    fail "old kernel passed worker-isolation preflight"
fi
grep -Fq 'Linux kernel 5.7 or newer is required' "$ERROR_LOG" \
    || fail "old-kernel failure is not actionable"
unset TEST_KERNEL_RELEASE

TEST_PURE_CGROUP_RESULT=1
: > "$ERROR_LOG"
if preflight_extension_worker_isolation_host; then
    fail "hybrid cgroups passed worker-isolation preflight"
fi
grep -Fq 'A pure cgroup v2 hierarchy mounted at /sys/fs/cgroup is required' "$ERROR_LOG" \
    || fail "hybrid-cgroup failure is not actionable"
unset TEST_PURE_CGROUP_RESULT

TEST_WORKER_CONTROLLERS_RESULT=1
: > "$ERROR_LOG"
if preflight_extension_worker_isolation_host; then
    fail "missing worker controller passed worker-isolation preflight"
fi
grep -Fq 'The cgroup-v2 memory and pids controllers must both be available' "$ERROR_LOG" \
    || fail "missing-worker-controller failure is not actionable"
unset TEST_WORKER_CONTROLLERS_RESULT

TEST_SYSTEMD_VERSION=256
: > "$ERROR_LOG"
if preflight_extension_worker_isolation_host; then
    fail "old systemd passed worker-isolation preflight"
fi
grep -Fq 'systemd 257 or newer is required' "$ERROR_LOG" \
    || fail "old-systemd failure is not actionable"
unset TEST_SYSTEMD_VERSION

TEST_UNIT_OVERRIDE_RESULT=0
: > "$ERROR_LOG"
if preflight_extension_worker_isolation_host; then
    fail "a unit override passed worker-isolation preflight"
fi
grep -Fq 'Refusing a systemd override that can change or block the extension worker isolation contract before publication' "$ERROR_LOG" \
    || fail "unit-override failure is not tied to the pre-publication isolation boundary"
unset TEST_UNIT_OVERRIDE_RESULT
pass "unsupported isolation hosts fail closed with actionable diagnostics"
