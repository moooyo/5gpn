#!/usr/bin/env bash
# Behavioral checks for candidate-only, certificate-bound iOS profile signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /var/tmp/5gpn-ui-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

REAL_OPENSSL="$(command -v openssl)"
REAL_RMDIR="$(command -v rmdir)"
REAL_MV="$(command -v mv)"
CONFIG_ROOT="$TMP/config"
CERT_ROOT="$CONFIG_ROOT/cert"
CERT_ROLE="$CERT_ROOT/dot"
CERT_GENERATION="$CERT_ROLE/generations/generation-20260817T000000Z-1-1"
CERT_DIR="$CERT_ROLE/current"
INTERCEPT_DIR="$TMP/intercept-ca"
UI_PARENT="$TMP/runtime"
UI_ROOT="$UI_PARENT/ui"
DIST="$TMP/dist"
MOCK_BIN="$TMP/bin"
GENERATOR="$TMP/gen-ios-profile.sh"
mkdir -p "$CERT_GENERATION" "$INTERCEPT_DIR" "$UI_PARENT" "$DIST/assets" "$MOCK_BIN"
chmod 0755 "$UI_PARENT"
printf '<html>profile test</html>\n' > "$DIST/index.html"
printf 'asset\n' > "$DIST/assets/app-12345678.js"

cp "$ROOT/scripts/ui-generation.sh" "$TMP/ui-generation.sh"
cp "$ROOT/scripts/publication-fs.sh" "$TMP/publication-fs.sh"
cp "$ROOT/scripts/cert-role-ctl.sh" "$TMP/cert-role-ctl.sh"
cp "$ROOT/scripts/gen-ios-profile.sh" "$GENERATOR"
chmod 0755 "$GENERATOR" "$TMP/ui-generation.sh" \
    "$TMP/publication-fs.sh" "$TMP/cert-role-ctl.sh"

"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$CERT_GENERATION/privkey.pem" -out "$CERT_GENERATION/fullchain.pem" \
    -subj '/CN=dot.example.test' -addext 'subjectAltName=DNS:dot.example.test' >/dev/null 2>&1
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$TMP/intercept.key" -out "$INTERCEPT_DIR/root.crt" \
    -subj '/CN=5gpn interception test root' \
    -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
printf '5gpn-config\n' > "$CONFIG_ROOT/.5gpn-owned"
printf '5gpn-cert-root-v1\n' > "$CERT_ROOT/.5gpn-cert-root-owned"
printf '5gpn-cert-role-v1:dot\n' > "$CERT_ROLE/.5gpn-cert-role-owned"
printf '5gpn-intercept-ca-v1\n' > "$INTERCEPT_DIR/.5gpn-intercept-ca-owned"
chmod 0755 "$CONFIG_ROOT"
chmod 0751 "$CERT_ROOT"
chmod 0750 "$CERT_ROLE" "$CERT_ROLE/generations" "$CERT_GENERATION"
chmod 0700 "$INTERCEPT_DIR"
chmod 0644 "$CONFIG_ROOT/.5gpn-owned" "$CERT_ROOT/.5gpn-cert-root-owned" \
    "$CERT_ROLE/.5gpn-cert-role-owned" "$INTERCEPT_DIR/.5gpn-intercept-ca-owned" \
    "$INTERCEPT_DIR/root.crt"
chmod 0640 "$CERT_GENERATION/fullchain.pem" "$CERT_GENERATION/privkey.pem"
ln -s "generations/$(basename "$CERT_GENERATION")" "$CERT_DIR"

# shellcheck source=../scripts/ui-generation.sh
source "$ROOT/scripts/ui-generation.sh"
ui_generation_claim_root "$UI_ROOT" || fail "could not claim test UI root"

new_candidate() { ui_generation_stage_tree "$UI_ROOT" "$DIST" v1.0.0; }
run_generator() {
    FIVEGPN_UI_GENERATION_TEST_MODE=1 \
    FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
    FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" \
    FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" "$@"
}

candidate="$(new_candidate)" || fail "could not stage successful profile candidate"
run_generator bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null \
    || fail "valid candidate profile signing failed"
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    [[ -s "$candidate/$profile" ]] || fail "candidate is missing $profile"
    "$REAL_OPENSSL" smime -verify -binary -inform der -noverify \
        -in "$candidate/$profile" -out "$TMP/$profile.plist" >/dev/null 2>&1 \
        || fail "$profile is not a valid CMS payload"
done
expected_leaf_sha="$($REAL_OPENSSL x509 -in "$CERT_GENERATION/fullchain.pem" -outform DER \
    | sha256sum | awk '{print $1}')"
expected_spki_sha="$($REAL_OPENSSL x509 -in "$CERT_GENERATION/fullchain.pem" -pubkey -noout \
    | $REAL_OPENSSL pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
expected_ca_sha="$($REAL_OPENSSL x509 -in "$INTERCEPT_DIR/root.crt" -outform DER \
    | sha256sum | awk '{print $1}')"
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    "$REAL_OPENSSL" smime -pk7out -inform der -in "$candidate/$profile" \
        | "$REAL_OPENSSL" pkcs7 -print_certs -out "$TMP/$profile.signers" >/dev/null 2>&1 \
        || fail "could not extract CMS signer from $profile"
    signer_sha="$($REAL_OPENSSL x509 -in "$TMP/$profile.signers" -outform DER \
        | sha256sum | awk '{print $1}')"
    [[ "$signer_sha" == "$expected_leaf_sha" ]] \
        || fail "$profile signer does not match the bound DoT leaf"
done
grep -Fq '<string>dot.example.test</string>' "$TMP/ios-dot.mobileconfig.plist" \
    && grep -Fq '<string>192.0.2.10</string>' "$TMP/ios-dot.mobileconfig.plist" \
    || fail "verified DoT profile does not contain the requested domain and gateway"
embedded="$(sed -n 's|^[[:space:]]*<data>\([^<]*\)</data>[[:space:]]*$|\1|p' \
    "$TMP/ios-intercept-ca.mobileconfig.plist")"
printf '%s' "$embedded" | "$REAL_OPENSSL" base64 -d -A > "$TMP/embedded-ca.der"
"$REAL_OPENSSL" x509 -in "$INTERCEPT_DIR/root.crt" -outform DER > "$TMP/source-ca.der"
cmp -s "$TMP/embedded-ca.der" "$TMP/source-ca.der" \
    || fail "verified interception profile embeds the wrong CA"
mapfile -t profile_inputs < "$candidate/.5gpn-profile-inputs"
[[ "${#profile_inputs[@]}" == 8 \
   && "${profile_inputs[0]}" == version=1 \
   && "${profile_inputs[1]}" == "dot_signer_leaf_sha256=${expected_leaf_sha}" \
   && "${profile_inputs[2]}" == "dot_public_key_sha256=${expected_spki_sha}" \
   && "${profile_inputs[3]}" == "intercept_ca_der_sha256=${expected_ca_sha}" \
   && "${profile_inputs[4]}" == domain=dot.example.test \
   && "${profile_inputs[5]}" == gateway_ipv4=192.0.2.10 \
   && "${profile_inputs[6]}" == "ios_dot_sha256=$(sha256sum "$candidate/ios-dot.mobileconfig" | awk '{print $1}')" \
   && "${profile_inputs[7]}" == "ios_intercept_ca_sha256=$(sha256sum "$candidate/ios-intercept-ca.mobileconfig" | awk '{print $1}')" ]] \
    || fail "profile-input manifest does not have the exact public eight-key schema"
grep -Fq 'private_key' "$candidate/.5gpn-profile-inputs" \
    && fail "profile-input manifest persisted a private-key fingerprint"
ui_generation_publish "$UI_ROOT" "$candidate" \
    || fail "real CMS candidate could not be atomically published"
_ui_generation_current_only_is_safe "$UI_ROOT" \
    || fail "published real CMS generation failed the validate-current implementation"
pass "generator, CMS verification, UI publication, and current validation succeed end to end"

# Feed the real generator manifest into the real cert-renew comparator. The
# comparator must reject every mismatched live binding, and a stale DNS
# coordinate must converge through ensure_live_deployed's profile-only branch
# without republishing certificate roles.
(
    comparator_ui_root="$UI_ROOT"
    comparator_cert_generation="$CERT_GENERATION"
    comparator_ca="$INTERCEPT_DIR/root.crt"
    comparator_generator="$GENERATOR"
    comparator_dns_env="$TMP/comparator-dns.env"
    export CERT_RENEW_LIB_ONLY=1
    # shellcheck source=../scripts/cert-renew.sh
    source "$ROOT/scripts/cert-renew.sh"
    UI_ROOT="$comparator_ui_root"
    PROFILE_INPUTS_FILE="$UI_ROOT/current/.5gpn-profile-inputs"
    INTERCEPT_CA="$comparator_ca"
    DNS_ENV="$comparator_dns_env"
    printf '%s\n' 'DNS_BASE_DOMAIN=example.test' 'DNS_GATEWAY_IP=192.0.2.10' > "$DNS_ENV"
    certificate_role_current_safe() { return 0; }
    intercept_ca_boundary_is_safe() { return 0; }
    bound_ui_helper_validate_current() { _ui_generation_current_only_is_safe "$UI_ROOT"; }
    file_uid() { [[ "$1" == "$PROFILE_INPUTS_FILE" ]] && printf '0\n' || stat -c %u "$1"; }
    file_gid() { [[ "$1" == "$PROFILE_INPUTS_FILE" ]] && printf '0\n' || stat -c %g "$1"; }
    profile_inputs_match_live "$comparator_cert_generation" \
        || fail "real cert-renew comparator rejected the real generator manifest"

    manifest_backup="$TMP/profile-inputs.comparator.backup"
    cp "$PROFILE_INPUTS_FILE" "$manifest_backup"
    for replacement in \
        'dot_signer_leaf_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
        'dot_public_key_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
        'intercept_ca_der_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        'domain=dot.other.test' \
        'gateway_ipv4=192.0.2.99' \
        'ios_dot_sha256=1111111111111111111111111111111111111111111111111111111111111111' \
        'ios_intercept_ca_sha256=2222222222222222222222222222222222222222222222222222222222222222'; do
        key="${replacement%%=*}"
        sed -i "s/^${key}=.*/${replacement}/" "$PROFILE_INPUTS_FILE"
        if profile_inputs_match_live "$comparator_cert_generation"; then
            fail "real cert-renew comparator accepted mismatched ${key}"
        fi
        cp "$manifest_backup" "$PROFILE_INPUTS_FILE"
        chmod 0644 "$PROFILE_INPUTS_FILE"
    done

    role_copies_match_live() { return 0; }
    deploy_hook_owned() { return 0; }
    run_bound_deploy_hook() {
        local mode="$1" candidate gateway
        case "$mode" in
            validate) return 0 ;;
            profile)
                gateway="$(cfg_get DNS_GATEWAY_IP)" || return 1
                candidate="$(ui_generation_clone_current "$UI_ROOT")" || return 1
                if ! run_generator bash "$comparator_generator" dot.example.test "$gateway" "$candidate"; then
                    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || true
                    return 1
                fi
                ui_generation_publish "$UI_ROOT" "$candidate"
                ;;
            *) return 1 ;;
        esac
    }
    before_recovery="$(readlink -- "$UI_ROOT/current")"
    printf '%s\n' 'DNS_BASE_DOMAIN=example.test' 'DNS_GATEWAY_IP=192.0.2.11' > "$DNS_ENV"
    ensure_live_deployed "$comparator_cert_generation" \
        || fail "ensure_live_deployed could not repair a real stale profile manifest"
    [[ "$(readlink -- "$UI_ROOT/current")" != "$before_recovery" ]] \
        && grep -Fxq 'gateway_ipv4=192.0.2.11' "$PROFILE_INPUTS_FILE" \
        && profile_inputs_match_live "$comparator_cert_generation" \
        || fail "profile-only recovery did not converge the real generator/comparator state"
)
pass "real profile manifest comparison and profile-only recovery converge every live binding"

for invalid_domain in 'bad<name.example' '.ops.example.test' 'two..dots.test'; do
    candidate="$(new_candidate)" || fail "could not stage invalid-domain candidate"
    if run_generator bash "$GENERATOR" "$invalid_domain" 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "invalid/XML-unsafe domain was accepted: $invalid_domain"
    fi
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean invalid-domain candidate"
done
for invalid_ip in '192.0.2.999' '192.0.02.10' '192.0.2.10</string>' '2001:db8::1'; do
    candidate="$(new_candidate)" || fail "could not stage invalid-IP candidate"
    if run_generator bash "$GENERATOR" dot.example.test "$invalid_ip" "$candidate" >/dev/null 2>&1; then
        fail "invalid/XML-unsafe gateway was accepted: $invalid_ip"
    fi
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean invalid-IP candidate"
done
pass "domain and gateway XML inputs fail closed"

expect_boundary_failure() {
    local label="$1" candidate
    candidate="$(new_candidate)" || fail "could not stage boundary fixture: $label"
    if run_generator bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "unsafe signing boundary was accepted: $label"
    fi
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" \
        || fail "could not clean boundary fixture: $label"
}

mv "$CONFIG_ROOT/.5gpn-owned" "$TMP/config-root-marker.backup"
expect_boundary_failure "missing configuration-root marker"
mv "$TMP/config-root-marker.backup" "$CONFIG_ROOT/.5gpn-owned"

mv "$CERT_ROOT/.5gpn-cert-root-owned" "$TMP/cert-root-marker.backup"
expect_boundary_failure "missing certificate-root marker"
mv "$TMP/cert-root-marker.backup" "$CERT_ROOT/.5gpn-cert-root-owned"

chmod 0644 "$CERT_GENERATION/fullchain.pem"
expect_boundary_failure "wrong certificate mode"
chmod 0640 "$CERT_GENERATION/fullchain.pem"

ln "$CERT_GENERATION/fullchain.pem" "$TMP/dot-fullchain.alias"
expect_boundary_failure "hardlinked DoT certificate"
rm -f "$TMP/dot-fullchain.alias"

cp "$CERT_GENERATION/fullchain.pem" "$TMP/dot-fullchain.backup"
cp "$CERT_GENERATION/privkey.pem" "$TMP/dot-privkey.backup"
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$CERT_GENERATION/privkey.pem" -out "$CERT_GENERATION/fullchain.pem" \
    -subj '/CN=wrong.example.test' -addext 'subjectAltName=DNS:wrong.example.test' >/dev/null 2>&1
chmod 0640 "$CERT_GENERATION/fullchain.pem" "$CERT_GENERATION/privkey.pem"
expect_boundary_failure "wrong-host DoT certificate"
cp "$TMP/dot-fullchain.backup" "$CERT_GENERATION/fullchain.pem"
cp "$TMP/dot-privkey.backup" "$CERT_GENERATION/privkey.pem"
chmod 0640 "$CERT_GENERATION/fullchain.pem" "$CERT_GENERATION/privkey.pem"

ln "$INTERCEPT_DIR/root.crt" "$INTERCEPT_DIR/root.alias"
expect_boundary_failure "hardlinked interception CA"
rm -f "$INTERCEPT_DIR/root.alias"

cp "$INTERCEPT_DIR/root.crt" "$TMP/root-ca.backup"
rm -f "$INTERCEPT_DIR/root.crt"
ln -s "$TMP/root-ca.backup" "$INTERCEPT_DIR/root.crt"
expect_boundary_failure "symlinked interception CA"
rm -f "$INTERCEPT_DIR/root.crt"
cp "$TMP/root-ca.backup" "$INTERCEPT_DIR/root.crt"
chmod 0644 "$INTERCEPT_DIR/root.crt"

"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$TMP/nonca.key" -out "$INTERCEPT_DIR/root.crt" \
    -subj '/CN=not a CA' -addext 'basicConstraints=critical,CA:FALSE' >/dev/null 2>&1
chmod 0644 "$INTERCEPT_DIR/root.crt"
expect_boundary_failure "non-CA interception certificate"
cp "$TMP/root-ca.backup" "$INTERCEPT_DIR/root.crt"
chmod 0644 "$INTERCEPT_DIR/root.crt"

if [[ "${EUID:-$(id -u)}" == 0 ]]; then
    chown 12345:12345 "$INTERCEPT_DIR/root.crt"
    expect_boundary_failure "foreign-owned interception CA"
    chown 0:0 "$INTERCEPT_DIR/root.crt"
fi
pass "root markers, host identity, owner, mode, link, and CA boundaries fail closed"

candidate="$(new_candidate)" || fail "could not stage ordinary-path rejection candidate"
if bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
    fail "ordinary production invocation accepted a non-production UI root"
fi
ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean ordinary-path candidate"
pass "non-production roots require the explicit test seam"

cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${EMULATE_X509_CHECKHOST_ZERO:-0}" == 1 \
   && " $* " == *" x509 "* && " $* " == *" -checkhost "* ]]; then
    printf '%s\n' 'Hostname does NOT match certificate'
    exit 0
fi
if [[ " $* " == *" smime -sign "* ]]; then
    for arg in "$@"; do
        if [[ "${FAIL_DOT_SIGN:-0}" == 1 && "$arg" == */ios-dot.mobileconfig.unsigned ]]; then exit 1; fi
        if [[ "${FAIL_INTERCEPT_SIGN:-0}" == 1 && "$arg" == */ios-intercept-ca.mobileconfig.unsigned ]]; then exit 1; fi
    done
fi
"$REAL_OPENSSL" "$@"
rc=$?
if [[ "$rc" == 0 && -n "${SIGNAL_EVENT:-}" && " $* " == *" smime -sign "* ]]; then
    for arg in "$@"; do
        if [[ ( "$SIGNAL_EVENT" == after-first-sign \
                && "$arg" == */ios-dot.mobileconfig.unsigned ) \
           || ( "$SIGNAL_EVENT" == after-second-sign \
                && "$arg" == */ios-intercept-ca.mobileconfig.unsigned ) ]]; then
            : > "$SIGNAL_SENTINEL"
            kill -s "$SIGNAL_NAME" "$PPID"
            break
        fi
    done
fi
if [[ "$rc" == 0 && -n "${MUTATE_INPUT_AFTER_SIGN:-}" && " $* " == *" smime -sign "* ]]; then
    for arg in "$@"; do
        if [[ "$arg" == */ios-dot.mobileconfig.unsigned ]]; then
            printf '\n' >> "$MUTATE_INPUT_AFTER_SIGN"
            break
        fi
    done
fi
if [[ "$rc" == 0 && "${ABA_SWAP_ROLE:-0}" == 1 && " $* " == *" smime -sign "* ]]; then
    for arg in "$@"; do
        if [[ "$arg" == */ios-dot.mobileconfig.unsigned ]]; then
            : > "$ABA_SENTINEL"
            old_target="$($REAL_READLINK -- "$TEST_CERT_CURRENT")"
            "$REAL_RM" -f -- "$TEST_CERT_CURRENT"
            "$REAL_LN" -s -- "$ABA_CERT_TARGET" "$TEST_CERT_CURRENT"
            "$REAL_RM" -f -- "$TEST_CERT_CURRENT"
            "$REAL_LN" -s -- "$old_target" "$TEST_CERT_CURRENT"
            break
        fi
    done
fi
exit "$rc"
MOCK
chmod 0755 "$MOCK_BIN/openssl"

cp "$CERT_GENERATION/fullchain.pem" "$TMP/dot-fullchain.openssl3.backup"
cp "$CERT_GENERATION/privkey.pem" "$TMP/dot-privkey.openssl3.backup"
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$CERT_GENERATION/privkey.pem" -out "$CERT_GENERATION/fullchain.pem" \
    -subj '/CN=wrong.example.test' -addext 'subjectAltName=DNS:wrong.example.test' >/dev/null 2>&1
chmod 0640 "$CERT_GENERATION/fullchain.pem" "$CERT_GENERATION/privkey.pem"
candidate="$(new_candidate)" || fail "could not stage OpenSSL 3.0 hostname-status candidate"
if EMULATE_X509_CHECKHOST_ZERO=1 PATH="$MOCK_BIN:$PATH" \
    run_generator bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
    fail "OpenSSL 3.0 x509 -checkhost zero status accepted a wrong-host DoT certificate"
fi
ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" \
    || fail "could not clean OpenSSL 3.0 hostname-status candidate"
cp "$TMP/dot-fullchain.openssl3.backup" "$CERT_GENERATION/fullchain.pem"
cp "$TMP/dot-privkey.openssl3.backup" "$CERT_GENERATION/privkey.pem"
chmod 0640 "$CERT_GENERATION/fullchain.pem" "$CERT_GENERATION/privkey.pem"
pass "hostname validation does not trust OpenSSL 3.0 x509 -checkhost exit status"

cat > "$MOCK_BIN/mv" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    [[ "${FAIL_DOT_MOVE:-0}" == 1 && "$arg" == */.ios-profile.*/ios-dot.mobileconfig ]] && exit 1
    [[ "${FAIL_INTERCEPT_MOVE:-0}" == 1 && "$arg" == */.ios-profile.*/ios-intercept-ca.mobileconfig ]] && exit 1
done
"$REAL_MV" "$@"
rc=$?
if [[ "$rc" == 0 && "${SIGNAL_EVENT:-}" == after-first-move ]]; then
    for arg in "$@"; do
        if [[ "$arg" == */ios-dot.mobileconfig ]]; then
            : > "$SIGNAL_SENTINEL"
            kill -s "$SIGNAL_NAME" "$PPID"
            break
        fi
    done
fi
exit "$rc"
MOCK
chmod 0755 "$MOCK_BIN/mv"
REAL_RM="$(command -v rm)"
REAL_LN="$(command -v ln)"
REAL_READLINK="$(command -v readlink)"
export REAL_OPENSSL REAL_MV REAL_RM REAL_LN REAL_READLINK TEST_CERT_CURRENT="$CERT_DIR"

for failure in FAIL_DOT_SIGN FAIL_INTERCEPT_SIGN; do
    candidate="$(new_candidate)" || fail "could not stage signing-failure candidate"
    if env "$failure=1" PATH="$MOCK_BIN:$PATH" \
        FIVEGPN_UI_GENERATION_TEST_MODE=1 FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
        FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
        bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "$failure was accepted"
    fi
    [[ ! -e "$candidate/ios-dot.mobileconfig" && ! -e "$candidate/ios-intercept-ca.mobileconfig" ]] \
        || fail "$failure wrote candidate profile bytes"
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean signing-failure candidate"
done
pass "either signature failure leaves the candidate unpublished and clean"

for failure in FAIL_DOT_MOVE FAIL_INTERCEPT_MOVE; do
    candidate="$(new_candidate)" || fail "could not stage move-failure candidate"
    if env "$failure=1" PATH="$MOCK_BIN:$PATH" \
        FIVEGPN_UI_GENERATION_TEST_MODE=1 FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
        FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
        bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "$failure was accepted"
    fi
    if ui_generation_publish "$UI_ROOT" "$candidate" >/dev/null 2>&1; then
        fail "$failure left a publishable partial generation"
    fi
    find "$candidate" -mindepth 1 -name '.ios-profile.*' -print -quit | grep -q . \
        && fail "$failure left private signing residue after normal cleanup"
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean move-failure candidate"
done
pass "either candidate profile move failure stays unpublished and leaves no signing residue"

for signal_case in 'after-first-sign TERM' 'after-second-sign HUP' 'after-first-move INT'; do
    read -r signal_event signal_name <<< "$signal_case"
    candidate="$(new_candidate)" || fail "could not stage signal-interruption candidate"
    signal_sentinel="$TMP/signal-${signal_event}"
    current_before_signal="$(readlink -- "$UI_ROOT/current")"
    if SIGNAL_EVENT="$signal_event" SIGNAL_NAME="$signal_name" \
        SIGNAL_SENTINEL="$signal_sentinel" PATH="$MOCK_BIN:$PATH" \
        FIVEGPN_UI_GENERATION_TEST_MODE=1 FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
        FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
        bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "$signal_name at $signal_event was accepted"
    fi
    [[ -e "$signal_sentinel" ]] || fail "$signal_name injection did not reach $signal_event"
    [[ "$(readlink -- "$UI_ROOT/current")" == "$current_before_signal" ]] \
        || fail "$signal_name at $signal_event changed the live current generation"
    find "$candidate" -mindepth 1 -name '.ios-profile.*' -print -quit | grep -q . \
        && fail "$signal_name at $signal_event left private signing residue"
    if ui_generation_publish "$UI_ROOT" "$candidate" >/dev/null 2>&1; then
        fail "$signal_name at $signal_event left a publishable partial generation"
    fi
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" \
        || fail "could not clean signal-interrupted candidate: $signal_event"
done
pass "HUP, INT, and TERM during signing or candidate placement leave current unchanged"

for input in "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$INTERCEPT_DIR/root.crt"; do
    backup="$TMP/$(basename "$input").backup.$RANDOM"
    cp "$input" "$backup"
    candidate="$(new_candidate)" || fail "could not stage signing-input-drift candidate"
    if MUTATE_INPUT_AFTER_SIGN="$input" PATH="$MOCK_BIN:$PATH" \
        FIVEGPN_UI_GENERATION_TEST_MODE=1 FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
        FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
        bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
        fail "signing input drift was accepted: $input"
    fi
    cp "$backup" "$input"
    ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" || fail "could not clean signing-input-drift candidate"
done
pass "certificate, private-key, and interception-CA drift are rejected before candidate writes"

CERT_GENERATION_B="$CERT_ROLE/generations/generation-20260817T000001Z-2-2"
mkdir "$CERT_GENERATION_B"
chmod 0750 "$CERT_GENERATION_B"
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$CERT_GENERATION_B/privkey.pem" -out "$CERT_GENERATION_B/fullchain.pem" \
    -subj '/CN=dot.example.test' -addext 'subjectAltName=DNS:dot.example.test' >/dev/null 2>&1
chmod 0640 "$CERT_GENERATION_B/fullchain.pem" "$CERT_GENERATION_B/privkey.pem"
candidate="$(new_candidate)" || fail "could not stage current-target ABA candidate"
ABA_SENTINEL="$TMP/aba-swap-ran"
if ABA_SWAP_ROLE=1 ABA_CERT_TARGET="generations/$(basename "$CERT_GENERATION_B")" \
    ABA_SENTINEL="$ABA_SENTINEL" \
    PATH="$MOCK_BIN:$PATH" FIVEGPN_UI_GENERATION_TEST_MODE=1 \
    FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
    FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
    bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
    fail "dot/current swap-and-restore ABA was accepted"
fi
[[ -e "$ABA_SENTINEL" ]] || fail "dot/current ABA injection did not run"
ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" \
    || fail "could not clean current-target ABA candidate"
pass "private signing snapshot remains A while dot/current swap-and-restore ABA is rejected"

cat > "$MOCK_BIN/rmdir" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    [[ "$arg" == */.ios-profile.* ]] && exit 1
done
exec "$REAL_RMDIR" "$@"
MOCK
chmod 0755 "$MOCK_BIN/rmdir"
export REAL_RMDIR
candidate="$(new_candidate)" || fail "could not stage cleanup-failure candidate"
if PATH="$MOCK_BIN:$PATH" FIVEGPN_UI_GENERATION_TEST_MODE=1 \
    FIVEGPN_UI_GENERATION_TEST_ROOT="$UI_ROOT" \
    FIVEGPN_PROFILE_TEST_DOT_ROLE="$CERT_ROLE" FIVEGPN_PROFILE_TEST_CA_ROOT="$INTERCEPT_DIR" \
    bash "$GENERATOR" dot.example.test 192.0.2.10 "$candidate" >/dev/null 2>&1; then
    fail "profile-signing temporary cleanup failure was accepted"
fi
find "$candidate" -mindepth 1 -name '.ios-profile.*' -print -quit | grep -q . \
    || fail "cleanup failure injection did not leave the private transaction residue"
if ui_generation_publish "$UI_ROOT" "$candidate" >/dev/null 2>&1; then
    fail "candidate with profile-signing residue was publishable"
fi
ui_generation_cleanup_candidate "$UI_ROOT" "$candidate" \
    || fail "ownership-proven cleanup-failure candidate could not be removed"
pass "temporary signing residue makes the generator and publisher fail closed"

INSTALL="$ROOT/install.sh"
prepare_fn="$(sed -n '/^prepare_ios_profile()/,/^}/p' "$INSTALL")"
publish_fn="$(sed -n '/^publish_ios_profile()/,/^}/p' "$INSTALL")"
setup_fn="$(sed -n '/^setup_ios_profile()/,/^}/p' "$INSTALL")"
printf '%s' "$prepare_fn" | grep -Fq 'exec {generator_hash_fd}<"$generator"' \
    && printf '%s' "$prepare_fn" | grep -Fq 'exec {generator_source_fd}<"$generator"' \
    && printf '%s' "$prepare_fn" | grep -Fq 'bash "/proc/self/fd/$generator_source_fd" "$DOT_DOMAIN" "$gw" "$candidate"' \
    && printf '%s' "$publish_fn" | grep -Fq 'ui_generation_publish "$UI_DIR" "$candidate"' \
    && printf '%s' "$setup_fn" | grep -Fq 'prepare_ios_profile && publish_ios_profile' \
    || fail "installer does not execute the anchored generator on an unpublished candidate then switch current once"
grep -Fq 'publish_owned_tree' "$INSTALL" && fail "retired whole-tree swap helper remains"
pass "installer uses only generation-based profile publication"

echo "all iOS profile candidate tests passed"
