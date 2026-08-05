#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
FAIL=0

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

remove_unit="$(sed -n '/^remove_unit()/,/^}/p' "$INSTALL")"
if grep -Fq 'systemctl disable --now "$unit"' <<<"$remove_unit" \
   && ! grep -Fq 'systemctl disable --now "$unit" 2>/dev/null || true' <<<"$remove_unit" \
   && grep -Fq 'refusing to delete its unit file' <<<"$remove_unit"; then
    pass "unit files are retained when stop/disable fails"
else
    fail "unit removal can delete a unit after stop/disable failure"
fi

readiness="$(sed -n '/^wait_service_ready()/,/^}/p' "$INSTALL")"
if grep -Fq 'deadline=$((SECONDS + SERVICE_READY_TIMEOUT))' <<<"$readiness" \
   && grep -Fq 'probe_mihomo_ready' <<<"$readiness"; then
    pass "installer applies one wall-clock deadline to readiness"
else
    fail "readiness can exceed the advertised total deadline"
fi

deps="$(sed -n '/^install_deps()/,/^}/p' "$INSTALL")"
if grep -Eq 'for cmd in .* timeout([[:space:]]|;)' <<<"$deps" \
   && grep -Eq 'for cmd in .* findmnt([[:space:]]|;)' <<<"$deps"; then
    pass "installer verifies timeout and mount-inspection dependencies"
else
    fail "installer does not verify timeout and mount-inspection dependencies"
fi

listener_probe="$(sed -n '/^ss_has_exact_listener()/,/^}/p' "$INSTALL")"
if grep -Fq '$4 == target' <<<"$listener_probe" \
   && ! grep -Fq 'grep -Fq' <<<"$listener_probe"; then
    pass "listener readiness compares the complete local endpoint"
else
    fail "listener readiness permits an address substring match"
fi

(
    systemctl() {
        case "$1" in
            reset-failed) return 1 ;;
            show)
                [[ "$3" == LoadState ]] && printf 'loaded\n' || printf 'inactive\n' ;;
            *) return 1 ;;
        esac
    }
    info() { :; }
    err() { :; }
    reset_systemd_failed_state 5gpn-intercept-cert.service
) && pass "reset-failed not-loaded race is tolerated for a loaded inactive unit" \
  || fail "loaded inactive unit was treated as a failed reset-failed state"

(
    systemctl() {
        case "$1" in
            reset-failed) return 1 ;;
            show)
                [[ "$3" == LoadState ]] && printf 'loaded\n' || printf 'failed\n' ;;
            *) return 1 ;;
        esac
    }
    info() { :; }
    err() { :; }
    ! reset_systemd_failed_state 5gpn-mihomo.service
) && pass "failed unit remains fatal when reset-failed also fails" \
  || fail "failed unit was allowed to start after reset-failed failed"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer service safety: PASS"
else
    echo "installer service safety: FAIL"
    exit 1
fi
