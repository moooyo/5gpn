#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/intercept-cert-renew.sh"
TMP="$(mktemp -d)"
trap 'exec 8>&- 2>/dev/null || true; rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

grep -Fxq 'INTERCEPT_DIR=/etc/5gpn/intercept' "$HELPER" \
    || fail "production interception directory default is missing"

export INTERCEPT_CERT_RENEW_LIB_ONLY=1
# shellcheck source=../scripts/intercept-cert-renew.sh
source "$HELPER"

CONFIG_ROOT="$TMP/config"
CA_DIR="$CONFIG_ROOT/intercept-ca"
INTERCEPT_DIR="$CONFIG_ROOT/intercept"
TLS_DIR="$INTERCEPT_DIR/tls"
CONFIG="$INTERCEPT_DIR/config.json"
CERT_STATE="$INTERCEPT_DIR/cert-state"
LOCK_FILE="$TMP/cert-renew.lock"

mkdir -p "$CA_DIR" "$TLS_DIR"
chmod 3771 "$CONFIG_ROOT"
chmod 0700 "$CA_DIR"
chmod 3770 "$INTERCEPT_DIR"
chmod 0750 "$TLS_DIR"
chmod g-s "$CA_DIR" "$TLS_DIR"
printf '%s\n' "$CONFIG_ROOT_MARKER_VALUE" > "$CONFIG_ROOT/$CONFIG_ROOT_MARKER"
printf '%s\n' "$CA_MARKER_VALUE" > "$CA_DIR/$CA_MARKER"
printf '%s\n' root-cert > "$CA_DIR/root.crt"
printf '%s\n' root-key > "$CA_DIR/root.key"
chmod 0644 "$CONFIG_ROOT/$CONFIG_ROOT_MARKER" "$CA_DIR/$CA_MARKER" "$CA_DIR/root.crt"
chmod 0600 "$CA_DIR/root.key"

config_boundary_safe || fail "sticky configuration boundary was rejected"
ca_boundary_safe || fail "canonical root-owned interception CA tree was rejected"
tls_tree_safe || fail "empty canonical interception TLS tree was rejected"
pass "canonical CA and TLS publication boundaries validate"

# The root publisher must enforce the same 512-host contract as both Go
# validators. Exercise the actual request parser so a stale shell-only bound
# cannot reject a document already accepted by the control plane and sidecar.
INTERCEPT_BIN="$TMP/fake-intercept"
printf '%s\n' '{}' > "$CONFIG"
chmod 0640 "$CONFIG"
write_fake_certificate_request() {
    local count="$1" index
    {
        printf '%064d\n' 0
        for ((index = 0; index < count; index++)); do
            printf 'h%03d.example.com\n' "$index"
        done
    } > "$TMP/request"
    cat > "$INTERCEPT_BIN" <<EOF
#!/usr/bin/env bash
cat '$TMP/request'
EOF
    chmod 0755 "$INTERCEPT_BIN"
}
stage="$TMP/host-limit-stage"
mkdir -p "$stage"
write_fake_certificate_request 512
load_desired_hosts || fail "certificate publisher rejected 512 hosts"
write_fake_certificate_request 513
if load_desired_hosts; then
    fail "certificate publisher accepted 513 hosts"
fi
pass "certificate publisher enforces the shared 512-host bound"

# A stale inherited descriptor must not be accepted merely because readlink
# prints the same pathname after the lock file was replaced.
: > "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
exec 8>"$LOCK_FILE"
lock_fd_targets_file 8 "$LOCK_FILE" || fail "matching inherited lock inode was rejected"
mv -- "$LOCK_FILE" "$TMP/old-lock"
: > "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
if lock_fd_targets_file 8 "$LOCK_FILE"; then
    fail "replaced lock pathname was mistaken for the inherited inode"
fi
exec 8>&-
pass "inherited lock validation compares device and inode"

main_fn="$(sed -n '/^main()/,/^}/p' "$HELPER")"
readonly_line="$(grep -nF 'readonly_leaf_ready || readonly_rc=$?' <<<"$main_fn" | cut -d: -f1)"
lock_line="$(grep -nF 'flock -w 10 9' <<<"$main_fn" | cut -d: -f1)"
[[ -n "$readonly_line" && -n "$lock_line" && "$readonly_line" -lt "$lock_line" ]] \
    || fail "valid leaf cannot bypass a contended public certificate lock"
grep -Fq 'if [[ "$readonly_rc" == 4 ]]' <<<"$main_fn" \
    || fail "lock contention still fails a runtime-valid renewal-due sidecar leaf"
if (
    stage="$TMP/readonly-stage"
    mkdir -p "$stage"
    load_desired_hosts() { printf '%s\n' example.com > "$stage/hosts"; }
    validate_root() { return 0; }
    tls_tree_safe() { return 0; }
    validate_leaf() { return 0; }
    readonly_leaf_ready
); then
    pass "valid interception leaf has a strict read-only no-lock fast path"
else
    fail "valid interception leaf still requires the contended write lock"
fi
if (
    set +e
    stage="$TMP/due-stage"
    mkdir -p "$stage"
    load_desired_hosts() { printf '%s\n' example.com > "$stage/hosts"; }
    validate_root() { return 0; }
    tls_tree_safe() { return 0; }
    validate_leaf() { [[ "${1:-}" == 60 ]]; }
    readonly_leaf_ready
    rc=$?
    [[ "$rc" == 4 ]]
); then
    pass "runtime-valid renewal-due leaf is distinguished from a fresh leaf"
else
    fail "renewal-due runtime-valid leaf status is incorrect"
fi

chmod 0644 "$LOCK_FILE"
if lock_file_safe "$LOCK_FILE"; then
    fail "world-readable certificate lock file was accepted"
fi
chmod 0600 "$LOCK_FILE"
ln -- "$LOCK_FILE" "$TMP/lock-hardlink"
if lock_file_safe "$LOCK_FILE"; then
    fail "hardlinked certificate lock file was accepted"
fi
rm -f -- "$TMP/lock-hardlink"
pass "lock file requires private single-link metadata"

# Marker content alone is not ownership proof. Simulate a marker owned by the
# runtime account and ensure CA publication rejects it.
original_path_uid="$(declare -f path_uid)"
UNSAFE_OWNER_PATH="$CA_DIR/$CA_MARKER"
path_uid() {
    if [[ "$1" == "$UNSAFE_OWNER_PATH" ]]; then
        printf '%s\n' "$((EUID + 1))"
    else
        stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
    fi
}
if ca_boundary_safe; then
    fail "service-owned interception CA marker was accepted"
fi
eval "$original_path_uid"
pass "service-owned CA marker fails closed"

mv -- "$TLS_DIR" "$INTERCEPT_DIR/tls.saved"
ln -s tls.saved "$TLS_DIR"
if tls_tree_safe; then
    fail "symlinked interception TLS directory was accepted"
fi
rm -f -- "$TLS_DIR"
mv -- "$INTERCEPT_DIR/tls.saved" "$TLS_DIR"
pass "symlinked TLS publication root fails closed"

for candidate in .leaf.crt.new .fullchain.pem.new .privkey.pem.new .cert-state.new; do
    printf '%s\n' interrupted > "$TLS_DIR/$candidate"
    chmod 0640 "$TLS_DIR/$candidate"
done
# Simulate SIGKILL while install(1) still has a partial root-owned 0600 file.
printf '%s' partial > "$TLS_DIR/.leaf.crt.new"
chmod 0600 "$TLS_DIR/.leaf.crt.new"
cleanup_tls_candidates || fail "safe interrupted TLS candidates could not be scrubbed"
for candidate in .leaf.crt.new .fullchain.pem.new .privkey.pem.new .cert-state.new; do
    [[ ! -e "$TLS_DIR/$candidate" ]] || fail "interrupted TLS candidate survived cleanup: $candidate"
done
pass "interrupted interception TLS candidates are safely scrubbed"

printf '%s\n' leaf > "$TLS_DIR/leaf.crt"
printf '%s\n' fullchain > "$TLS_DIR/fullchain.pem"
printf '%s\n' key > "$TLS_DIR/privkey.pem"
printf '%064d\n' 0 > "$CERT_STATE"
chmod 0640 "$TLS_DIR/leaf.crt" "$TLS_DIR/fullchain.pem" \
    "$TLS_DIR/privkey.pem" "$CERT_STATE"
tls_tree_safe || fail "canonical populated TLS tree was rejected"
ln -- "$TLS_DIR/privkey.pem" "$TMP/key-hardlink"
if tls_tree_safe; then
    fail "hardlinked interception private key was accepted"
fi
rm -f -- "$TMP/key-hardlink"
pass "hardlinked TLS key fails closed"

echo "interception certificate renewal safety: PASS"
