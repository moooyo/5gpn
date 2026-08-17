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
main_fn="$(sed -n '/^main()/,/^}/p' "$HELPER")"
gate_line="$(grep -n 'assert_no_retained_configure_gate' <<<"$main_fn" | cut -d: -f1)"
cert_lock_line="$(grep -n 'exec 9>"$LOCK_FILE"' <<<"$main_fn" | cut -d: -f1)"
cleanup_armed_line="$(grep -n 'CERT_LOCK_HELD=1' <<<"$main_fn" | cut -d: -f1)"
publication_line="$(grep -n 'cleanup_tls_candidates' <<<"$main_fn" | tail -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$cert_lock_line" && -n "$cleanup_armed_line" && -n "$publication_line" \
   && "$cert_lock_line" -lt "$gate_line" \
   && "$gate_line" -lt "$cleanup_armed_line" \
   && "$cleanup_armed_line" -lt "$publication_line" \
   && ! "$main_fn" =~ INSTALL_LOCK_FILE ]] \
    || fail "interception certificate writer does not assert retained-gate absence before arming cleanup/publication"
pass "interception certificate writer rejects retained gate state before cleanup or publication"

export INTERCEPT_CERT_RENEW_LIB_ONLY=1
# shellcheck source=../scripts/intercept-cert-renew.sh
source "$HELPER"

CONFIG_ROOT="$TMP/config"
CA_DIR="$CONFIG_ROOT/intercept-ca"
INTERCEPT_DIR="$CONFIG_ROOT/intercept"
TLS_DIR="$INTERCEPT_DIR/tls"
CERT_STATE="$INTERCEPT_DIR/cert-state"
CERT_REQUEST_DIR="$TMP/runtime/5gpn"
CERT_REQUEST="$CERT_REQUEST_DIR/certificate-request"
LOCK_FILE="$TMP/cert-renew.lock"
stage="$TMP/stage"

mkdir -p "$CA_DIR" "$TLS_DIR" "$CERT_REQUEST_DIR" "$stage"
chmod 0755 "$CONFIG_ROOT"
chmod 0700 "$CA_DIR"
chmod 0750 "$INTERCEPT_DIR"
chmod 0750 "$TLS_DIR"
chmod 0711 "$CERT_REQUEST_DIR"
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
pass "canonical CA and installer-published 0750 TLS boundaries validate"

write_request() {
    local attempt="$1" host digest json="" separator="" host_file="$TMP/request-hosts"
    shift
    : > "$host_file"
    for host in "$@"; do
        printf '%s\n' "$host" >> "$host_file"
        json="${json}${separator}\"${host}\""
        separator=,
    done
    if [[ -s "$host_file" ]]; then
        digest="$(file_sha256 "$host_file")"
    else
        digest="$(printf '\n' | sha256sum | cut -d' ' -f1)"
    fi
    printf '{"version":1,"target_digest":"%s","attempt":"%s","hosts":[%s]}' \
        "$digest" "$attempt" "$json" > "$CERT_REQUEST"
    chmod 0644 "$CERT_REQUEST"
}

ATTEMPT_A=11111111111111111111111111111111
ATTEMPT_B=22222222222222222222222222222222
ATTEMPT_C=33333333333333333333333333333333

# Exercise the exact compact JSON parser and the shared 512-host bound.
hosts=()
for ((index = 0; index < 512; index++)); do
    hosts+=("h$(printf '%03d' "$index").example.com")
done
write_request "$ATTEMPT_A" "${hosts[@]}"
load_desired_hosts || fail "certificate publisher rejected 512 hosts"
[[ "$desired_attempt" == "$ATTEMPT_A" ]] || fail "request attempt was not parsed"
hosts+=("h512.example.com")
write_request "$ATTEMPT_A" "${hosts[@]}"
if load_desired_hosts; then
    fail "certificate publisher accepted 513 hosts"
fi
pass "certificate request v1 enforces its schema, digest, attempt, and 512-host bound"

write_request "$ATTEMPT_A" a.example.com b.example.com
original_request="$(<"$CERT_REQUEST")"
printf '%s' "${original_request/\"target_digest\":\"/\"target_digest\":\"f}" > "$CERT_REQUEST"
chmod 0644 "$CERT_REQUEST"
if load_desired_hosts; then
    fail "certificate publisher accepted a digest that does not cover the hosts"
fi
printf '%s' "${original_request/\"attempt\":\"$ATTEMPT_A\"/\"attempt\":1}" > "$CERT_REQUEST"
chmod 0644 "$CERT_REQUEST"
if load_desired_hosts; then
    fail "certificate publisher accepted a non-token attempt"
fi
printf '%s' "${original_request%?},\"extra\":true}" > "$CERT_REQUEST"
chmod 0644 "$CERT_REQUEST"
if load_desired_hosts; then
    fail "certificate publisher accepted an unknown request field"
fi
write_request "$ATTEMPT_A" b.example.com a.example.com
if load_desired_hosts; then
    fail "certificate publisher accepted an unsorted host set"
fi
pass "malformed, unfenced, and non-canonical requests fail closed"

write_request "$ATTEMPT_A" a.example.com
truncate -s "$((MAX_REQUEST_BYTES + 1))" "$CERT_REQUEST"
if load_desired_hosts; then
    fail "certificate publisher read an oversized sparse request"
fi
write_request "$ATTEMPT_A" a.example.com
if (
    head() {
        printf 'x' >> "$CERT_REQUEST"
        command head "$@"
    }
    snapshot_certificate_request "$stage/growing-request"
); then
    fail "certificate publisher accepted an in-place growing request"
fi
pass "request snapshots are size-bounded before and during the read"

# A fresh installation can precede the first runtime request. Absence is a
# no-op, but a dangling link must never be mistaken for absence.
rm -f "$CERT_REQUEST"
if load_desired_hosts; then
    fail "load_desired_hosts accepted a missing certificate request"
fi
ln -s "$TMP/does-not-exist" "$CERT_REQUEST"
if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
    fail "dangling symlink was classified as an absent certificate request"
fi
rm -f "$CERT_REQUEST"
[[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]] \
    || fail "a truly absent certificate request was not classified as absence"
grep -Fq 'No extension has requested interception hosts yet' "$HELPER" \
    || fail "the publisher has no fresh-install no-op path"
pass "request absence and hostile links are distinguished"

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

# Marker content alone is not ownership proof.
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

for candidate in \
    "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
    "$TLS_DIR/.privkey.pem.new" "$INTERCEPT_DIR/.cert-state.new"; do
    printf '%s\n' interrupted > "$candidate"
    chmod 0640 "$candidate"
done
# Simulate SIGKILL while install(1) still has a partial root-owned 0600 file.
printf '%s' partial > "$TLS_DIR/.leaf.crt.new"
chmod 0600 "$TLS_DIR/.leaf.crt.new"
cleanup_tls_candidates || fail "safe interrupted publication candidates could not be scrubbed"
for candidate in \
    "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
    "$TLS_DIR/.privkey.pem.new" "$INTERCEPT_DIR/.cert-state.new"; do
    [[ ! -e "$candidate" ]] || fail "interrupted candidate survived cleanup: $candidate"
done
pass "interrupted certificate and manifest candidates are safely scrubbed"

# Replace the fixtures with a real CA, then generate and validate a real leaf.
openssl ecparam -name prime256v1 -genkey -noout -out "$CA_DIR/root.key"
openssl req -new -x509 -sha256 -days 3650 -key "$CA_DIR/root.key" \
    -subj '/CN=5gpn test interception root' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -out "$CA_DIR/root.crt" >/dev/null 2>&1
chmod 0600 "$CA_DIR/root.key"
chmod 0644 "$CA_DIR/root.crt"
validate_root || fail "real test CA did not pass the publisher boundary"

write_request "$ATTEMPT_A" '*.example.net' api.example.com
load_desired_hosts || fail "valid real-certificate request did not parse"
generate_candidate || fail "publisher could not generate a real scoped leaf"
openssl x509 -in "$stage/leaf.crt" -noout -checkhost api.example.com 2>/dev/null \
    | grep -Fq 'does match certificate' || fail "real leaf misses its exact SAN"
openssl x509 -in "$stage/leaf.crt" -noout -checkhost probe.example.net 2>/dev/null \
    | grep -Fq 'does match certificate' || fail "real leaf misses its wildcard SAN"
pass "real OpenSSL signing produces an exact, verified leaf and keypair"

cp -- "$stage/leaf.crt" "$TLS_DIR/leaf.crt"
cp -- "$stage/fullchain.pem" "$TLS_DIR/fullchain.pem"
cp -- "$stage/privkey.pem" "$TLS_DIR/privkey.pem"
render_ready_state "$CERT_STATE" "$material_certificate_hash" "$material_private_key_hash"
chmod 0640 "$TLS_DIR/leaf.crt" "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem" "$CERT_STATE"
validate_committed_ready 60 || fail "complete ready transaction was rejected"
ready_a="$(<"$CERT_STATE")"
pass "ready state binds request, fullchain bytes, and private-key bytes"

if (
    validate_committed_ready() {
        write_request "$ATTEMPT_B" '*.example.net' api.example.com
        return 0
    }
    readonly_leaf_ready
); then
    fail "read-only fast path accepted a request changed during validation"
fi
write_request "$ATTEMPT_A" '*.example.net' api.example.com
load_desired_hosts || fail "request could not be restored after read-only fencing"
validate_committed_ready 60 || fail "ready state did not recover after read-only fencing"
pass "read-only ready checks fence the request before returning"

# Coverage is not identity. A wildcard or superset leaf must not be reused for
# a narrower target, because that would retain identities the new request
# explicitly withdrew.
write_request "$ATTEMPT_B" api.example.com
load_desired_hosts || fail "narrowed certificate request did not parse"
if validate_live_material 60; then
    fail "a broader old leaf was reusable for a narrower target"
fi
write_request "$ATTEMPT_A" '*.example.net' api.example.com
load_desired_hosts || fail "original certificate request did not restore"
validate_committed_ready 60 || fail "restored exact SAN target did not recover"
pass "live material reuse requires the exact requested SAN set"

# A crash can leave new TLS material with the old manifest. The manifest is the
# commit point, so every torn combination must be rejected by readers.
cp -- "$TLS_DIR/leaf.crt" "$TMP/live-leaf"
cp -- "$TLS_DIR/fullchain.pem" "$TMP/live-fullchain"
cp -- "$TLS_DIR/privkey.pem" "$TMP/live-key"
printf '\n' >> "$TLS_DIR/fullchain.pem"
if validate_committed_ready 60; then
    fail "manifest accepted changed fullchain bytes"
fi
cp -- "$TMP/live-fullchain" "$TLS_DIR/fullchain.pem"
generate_candidate || fail "second real candidate generation failed"
cp -- "$stage/leaf.crt" "$TLS_DIR/leaf.crt"
if validate_committed_ready 60; then
    fail "manifest accepted a partially published new leaf"
fi
cp -- "$TMP/live-leaf" "$TLS_DIR/leaf.crt"
cp -- "$TMP/live-key" "$TLS_DIR/privkey.pem"
chmod 0640 "$TLS_DIR/leaf.crt" "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"
validate_committed_ready 60 || fail "restored complete transaction did not recover"
pass "torn TLS publication fails closed until the final manifest matches"

# A same-digest retry receives a new attempt. An old result is fenced out, but
# a valid existing leaf can be committed under the new attempt without reissue.
load_desired_hosts || fail "attempt A request could not be restored"
cp -- "$stage/request" "$TMP/request-a"
write_request "$ATTEMPT_B" '*.example.net' api.example.com
if request_is_current; then
    fail "attempt A candidate remained current after attempt B was published"
fi
[[ "$(<"$CERT_STATE")" == "$ready_a" ]] || fail "stale attempt changed committed state"
load_desired_hosts || fail "attempt B request did not parse"
if validate_committed_ready 60; then
    fail "attempt A ready result was accepted for attempt B"
fi
validate_live_material 60 || fail "same-digest retry could not reuse valid leaf material"
render_ready_state "$CERT_STATE" "$material_certificate_hash" "$material_private_key_hash"
chmod 0640 "$CERT_STATE"
validate_committed_ready 60 || fail "same-digest retry did not become ready under its new attempt"
ready_b="$(<"$CERT_STATE")"
[[ "$ready_b" == *"\"attempt\":\"$ATTEMPT_B\""* ]] \
    || fail "same-digest retry result carries the wrong attempt"
pass "same-digest retries are independently fenced and reuse valid material"

# Test the actual atomic state writer without requiring test-time root chown.
# The production service is root; this wrapper only removes -o/-g from install
# while preserving its write/mode/rename behavior in the unprivileged harness.
if ! (
    install() {
        local args=("$@") count="$#"
        command install -m 0640 "${args[$((count - 2))]}" "${args[$((count - 1))]}"
    }
    load_desired_hosts
    render_error_state "$stage/stale-error" signing_failed \
        'The interception certificate could not be generated.'
    before="$(<"$CERT_STATE")"
    write_request "$ATTEMPT_C" '*.example.net' api.example.com
    rc=0
    publish_state_file "$stage/stale-error" fivegpn "$(id -g)" || rc=$?
    [[ "$rc" == 3 && "$(<"$CERT_STATE")" == "$before" ]]
); then
    fail "stale error result overwrote the current transaction"
fi
write_request "$ATTEMPT_C" '*.example.net' api.example.com
load_desired_hosts || fail "attempt C request did not parse"
if ! (
    install() {
        local args=("$@") count="$#"
        command install -m 0640 "${args[$((count - 2))]}" "${args[$((count - 1))]}"
    }
    publish_error_if_current signing_failed \
        'The interception certificate could not be generated.' fivegpn "$(id -g)"
); then
    fail "current error state could not be atomically published"
fi
error_c="$(<"$CERT_STATE")"
[[ "$error_c" == *'"status":"error"'* \
   && "$error_c" == *'"code":"signing_failed"'* \
   && "$error_c" == *"\"attempt\":\"$ATTEMPT_C\""* ]] \
    || fail "published error state is not stable, safe, and fenced"
pass "only the current request can atomically publish a safe error result"

# An empty target still receives a ready result. Old leaf files may remain on
# disk, but the matching no-certificate manifest makes them unusable.
write_request 44444444444444444444444444444444
load_desired_hosts || fail "empty host request did not parse"
render_ready_state "$CERT_STATE"
chmod 0640 "$CERT_STATE"
validate_committed_ready 60 || fail "empty host target did not become ready"
empty_state="$(<"$CERT_STATE")"
[[ "$empty_state" == *'"status":"ready"'* \
   && "$empty_state" != *'certificate_sha256'* \
   && "$empty_state" != *'private_key_sha256'* ]] \
    || fail "empty host target claims certificate material"
pass "empty host targets commit ready without requiring a certificate"

ln -- "$TLS_DIR/privkey.pem" "$TMP/key-hardlink"
if tls_tree_safe; then
    fail "hardlinked interception private key was accepted"
fi
rm -f -- "$TMP/key-hardlink"
pass "hardlinked TLS key fails closed"

publish_fn="$(sed -n '/^publish_certificate_candidate()/,/^}/p' "$HELPER")"
cert_rename_line="$(grep -nF 'mv -f -- "$TLS_DIR/.leaf.crt.new"' <<<"$publish_fn" | cut -d: -f1)"
state_publish_line="$(grep -nF 'publish_state_file "$stage/ready-state"' <<<"$publish_fn" | cut -d: -f1)"
[[ -n "$cert_rename_line" && -n "$state_publish_line" \
   && "$cert_rename_line" -lt "$state_publish_line" ]] \
    || fail "certificate manifest is not the final publication step"
grep -Fq 'fsync_file "$candidate"' <<<"$publish_fn" \
    || fail "certificate candidates are not fsynced"
state_fn="$(sed -n '/^publish_state_file()/,/^}/p' "$HELPER")"
grep -Fq 'fsync_file "$candidate"' <<<"$state_fn" \
    && grep -Fq 'fsync_directory "$state_dir"' <<<"$state_fn" \
    || fail "state manifest lacks file and directory fsync"
[[ "$MAX_CONVERGENCE_ATTEMPTS" -gt 1 && "$MAX_CONVERGENCE_ATTEMPTS" -le 32 ]] \
    || fail "request convergence is absent or unbounded"
pass "certificate bytes are durable before the final atomic manifest commit"

echo "interception certificate renewal safety: PASS"
