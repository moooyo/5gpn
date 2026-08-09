#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
UNIT="$ROOT/etc/systemd/5gpn-mihomo.service"
ARCHITECTURE="$ROOT/docs/architecture.md"
EXTENSION_CONTRACT="$ROOT/docs/native-extensions.md"
ACCEPTANCE="$ROOT/tests/acceptance-monolith-extension.sh"

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
grep -Fxq '# 5gpn-unit-id: 5gpn-mihomo.service:v2' "$UNIT" \
    || fail "worker-isolation unit revision is not v2"
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

for contract in \
    'Worker admission is fixed at two concurrent processes.' \
    '`memory.max=536870912`' \
    '`memory.swap.max=0`' \
    '`memory.oom.group=1`' \
    '`pids.max=32`' \
    'aggregate upper bounds of 1GiB and 64 tasks' \
    '`ActiveProcessLimit=1`'; do
    grep -Fq "$contract" "$ARCHITECTURE" \
        || fail "architecture omits the fixed worker contract: $contract"
    grep -Fq "$contract" "$EXTENSION_CONTRACT" \
        || fail "extension contract omits the fixed worker contract: $contract"
done
grep -Fq 'There is no in-process fallback on any platform.' "$EXTENSION_CONTRACT" \
    || fail "extension contract permits an in-process fallback"
grep -Fq 'is `0::/main`.' "$ARCHITECTURE" \
    || fail "architecture does not pin the private delegated main subgroup"
grep -Fq 'systemd starts the trusted parent alone at' "$ARCHITECTURE" \
    && grep -Fq '`0::/`' "$ARCHITECTURE" \
    && grep -Fq 'Setting `DelegateSubgroup=main` in the unit would instead' "$ARCHITECTURE" \
    || fail "architecture omits trusted parent normalization from the private unit root"
for contract in \
    '`UseCgroupFD`' \
    '`clone3(CLONE_INTO_CGROUP)`' \
    '`SystemCallFilter=~unshare setns`' \
    'runtime startup isolation probe'; do
    grep -Fq "$contract" "$ARCHITECTURE" \
        || fail "architecture omits the clone3 isolation contract: $contract"
    grep -Fq "$contract" "$EXTENSION_CONTRACT" \
        || fail "extension contract omits the clone3 isolation contract: $contract"
done
for contract in \
    'Startup isolation probe failure is fatal before listeners open.' \
    'After a successful probe, each child failure stays local.' \
    'Guest worker admission is global 2 and per extension 1.' \
    'Admission never queues; saturation fails the current operation immediately.' \
    'Pure parent-side declarative actions do not acquire a worker slot.'; do
    grep -Fq "$contract" "$ARCHITECTURE" \
        || fail "architecture omits the two-stage worker failure contract: $contract"
    grep -Fq "$contract" "$EXTENSION_CONTRACT" \
        || fail "extension contract omits the two-stage worker failure contract: $contract"
done
pass "documentation pins Linux and Windows worker resource ceilings"

for contract in \
    'trap cleanup EXIT' \
    'installed_by_acceptance' \
    '.extension.snapshot_digest' \
    'pathRegex: "^/oom$"' \
    'new Uint8Array(16 * 1024 * 1024)' \
    'workers.${main_pid}.*' \
    '$aggregate_path/memory.events' \
    "-name 'action.*'" \
    'pathRegex: "^/healthy$"' \
    '[ "$healthy_http" = 204 ]'; do
    grep -Fq -- "$contract" "$ACCEPTANCE" \
        || fail "production OOM acceptance omits: $contract"
done
pass "production acceptance fences and verifies a real worker OOM"

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
for unit in 5gpn-mihomo.service 5gpn-intercept-cert.service \
            5gpn-intercept-cert.path 5gpn-intercept-cert.timer; do
    grep -Fq "$unit" <<<"$verify_fn" \
        || fail "candidate verification omits $unit"
done
for pattern in \
    'OOMPolicy|Delegate*|Slice|DisableControllers' \
    'Memory*|StartupMemory*|AllowedMemoryNodes|StartupAllowedMemoryNodes' \
    'CPU*|StartupCPU*|AllowedCPUs|StartupAllowedCPUs' \
    'IO*|StartupIO*|BlockIO*|StartupBlockIO*|Tasks*|ManagedOOM*' \
    'Limit*|Nice|OOMScoreAdjust|TimerSlackNSec|NUMA*'; do
    grep -Fq "$pattern" "$INSTALL" \
        || fail "global resource override gate omits: $pattern"
done
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
