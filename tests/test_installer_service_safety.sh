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

remove_unit="$(sed -n '/^remove_owned_unit()/,/^}/p' "$INSTALL")"
if grep -Fq 'systemctl disable --now "$unit"' <<<"$remove_unit" \
   && ! grep -Fq 'systemctl disable --now "$unit" 2>/dev/null || true' <<<"$remove_unit" \
   && grep -Fq 'refusing to delete its unit file' <<<"$remove_unit"; then
    pass "owned unit files are retained when stop/disable fails"
else
    fail "owned unit removal can delete a unit after stop/disable failure"
fi

readiness="$(sed -n '/^wait_service_ready()/,/^}/p' "$INSTALL")"
if grep -Fq 'deadline=$((SECONDS + SERVICE_READY_TIMEOUT))' <<<"$readiness" \
   && grep -Fq '"${probe_timeout}s"' <<<"$readiness" \
   && grep -Fq '"$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --healthcheck' <<<"$readiness"; then
    pass "installer applies one wall-clock deadline to sidecar readiness"
else
    fail "sidecar readiness can exceed the advertised total deadline"
fi

deps="$(sed -n '/^install_deps()/,/^}/p' "$INSTALL")"
grep -Eq 'for cmd in .* timeout;' <<<"$deps" \
    && pass "installer verifies the timeout dependency" \
    || fail "installer does not verify the timeout dependency"

listener_probe="$(sed -n '/^ss_has_exact_listener()/,/^}/p' "$INSTALL")"
if grep -Fq '$4 == target' <<<"$listener_probe" \
   && ! grep -Fq 'grep -Fq' <<<"$listener_probe"; then
    pass "listener readiness compares the complete local endpoint"
else
    fail "listener readiness permits an address substring match"
fi

slow_intercept="$(mktemp)"
cat > "$slow_intercept" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' --check-enabled '*) exit 0 ;;
    *' --healthcheck '*) sleep 30; exit 0 ;;
esac
exit 1
EOF
chmod +x "$slow_intercept"
if (
    INTERCEPT_BIN="$slow_intercept"
    INTERCEPT_DIR="$(dirname "$slow_intercept")"
    SERVICE_READY_TIMEOUT=1
    INTERCEPT_HEALTHCHECK_MAX_TIMEOUT=1
    systemctl() { return 0; }
    started=$SECONDS
    ! wait_service_ready 5gpn-intercept >/dev/null 2>&1
    (( SECONDS - started <= 3 ))
); then
    pass "silent sidecar readiness respects the total wall-clock budget"
else
    fail "silent sidecar readiness exceeded the total wall-clock budget"
fi
rm -f -- "$slow_intercept"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "installer service safety: PASS"
else
    echo "installer service safety: FAIL"
    exit 1
fi
