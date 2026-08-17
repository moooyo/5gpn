#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX="$ROOT/tests/integration-smoke.md"
RELEASE="$ROOT/.github/workflows/release.yml"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

compare_exact_list() {
    local label="$1" expected_name="$2" actual_name="$3"
    local -n expected_ref="$expected_name"
    local -n actual_ref="$actual_name"
    local expected actual

    expected="$(printf '%s\n' "${expected_ref[@]}" | LC_ALL=C sort -u)"
    actual="$(printf '%s\n' "${actual_ref[@]}" | LC_ALL=C sort -u)"
    [[ "$actual" == "$expected" ]] \
        || fail "$label differs from the approved set"
}

mapfile -t retired_acceptance_scripts < <(
    find "$ROOT/tests" -maxdepth 1 \( -type f -o -type l \) \
        -name 'acceptance*.sh' -printf '%f\n' | LC_ALL=C sort
)
[[ "${#retired_acceptance_scripts[@]}" == 0 ]] \
    || fail "retired root acceptance scripts still exist: ${retired_acceptance_scripts[*]}"
pass "retired executable acceptance mega-suites are absent from source and release packaging"

expected_index_runbooks=(
    deployment-smoke.md
    acceptance/installer.md
    acceptance/disruption-recovery.md
)
mapfile -t actual_index_runbooks < <(
    grep -oE '\]\([^)]+\.md\)' "$INDEX" \
        | sed -E 's/^\]\((.*)\)$/\1/' \
        | grep -vE '^https?://' \
        | LC_ALL=C sort -u
)
compare_exact_list "acceptance index local runbook set" \
    expected_index_runbooks actual_index_runbooks
for runbook in "${expected_index_runbooks[@]}"; do
    [[ -f "$ROOT/tests/$runbook" && ! -L "$ROOT/tests/$runbook" ]] \
        || fail "root acceptance runbook is missing or linked: tests/$runbook"
done

expected_packaged_acceptance=(
    tests/container-acceptance.sh
    tests/docker/probe-lib.sh
    tests/docker/extension-worker-probe.sh
    tests/docker/public-certificate-hot-reload.sh
    tests/docker/recreate-container.sh
    tests/integration-smoke.md
    tests/deployment-smoke.md
    tests/acceptance/installer.md
    tests/acceptance/disruption-recovery.md
)
mapfile -t actual_packaged_acceptance < <(
    awk '
        /^[[:space:]]*bundle_files=\([[:space:]]*$/ { inside=1; next }
        inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
        inside {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ /^tests\//) print line
        }
    ' "$RELEASE" | LC_ALL=C sort -u
)
compare_exact_list "release acceptance document set" \
    expected_packaged_acceptance actual_packaged_acceptance
pass "the root index and release bundle contain only the approved acceptance documents and Docker probes"

MIHOMO_ACCEPTANCE_COMMIT=aba0cfcea5ebeda580ab63e174fd17146c3ef962
ZASHBOARD_ACCEPTANCE_COMMIT=cf3d018ffa20eae0297c434b7a185b0d69f43b66

grep -Fq "moooyo/mihomo/blob/${MIHOMO_ACCEPTANCE_COMMIT}/acceptance/runtime-smoke.md" "$INDEX" \
    && grep -Fq "moooyo/mihomo/blob/${MIHOMO_ACCEPTANCE_COMMIT}/acceptance/runtime-disposable.md" "$INDEX" \
    && grep -Fq "moooyo/mihomo/blob/${MIHOMO_ACCEPTANCE_COMMIT}/acceptance/README.md" "$INDEX" \
    || fail "acceptance index does not use the immutable mihomo acceptance set"
grep -Fq "moooyo/zashboard/blob/${ZASHBOARD_ACCEPTANCE_COMMIT}/docs/5gpn-console-acceptance.md" "$INDEX" \
    || fail "acceptance index does not use the immutable zashboard runbook"
pass "runtime and Console behavior route to immutable repository-owned acceptance documents"
