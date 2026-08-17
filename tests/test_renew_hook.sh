#!/usr/bin/env bash
# Behaviour checks for scoped, validated, non-truncating certificate deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/renew-hook.sh"
TMP="$(mktemp -d /tmp/5gpn-renew-hook.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

export RENEW_HOOK_LIB_ONLY=1
# shellcheck source=../scripts/renew-hook.sh
TEST_PATH="$PATH"
source "$HOOK"
PATH="$TEST_PATH"
# The production mapping is held statically; temporary fixtures use the current
# developer group so an unprivileged test runner can exercise atomic metadata.
grep -Fq 'dot|console) printf' "$ROOT/scripts/cert-role-ctl.sh" \
    && grep -Fq 'CERT_ROLE_CTL_SERVICE_GROUP=fivegpn' "$ROOT/scripts/cert-role-ctl.sh" \
    || fail "shared certificate roles do not map dot/console to fivegpn"
grep -Fxq 'UI_DIR=/opt/5gpn/ui' "$HOOK" \
    || fail "renew hook stable generation root is not /opt/5gpn/ui"
grep -Fq 'UI_OWNERSHIP_VALUE=5gpn-ui-generations' "$HOOK" \
    && grep -Fq 'UI_GENERATION_MARKER_VALUE="5gpn-ui-generations"' \
        "$ROOT/scripts/ui-generation.sh" \
    || fail "renew hook and UI helper disagree on the generation-root marker"
grep -Eq '^WWW_DIR=/opt/5gpn/www$' "$HOOK" \
    && fail "renew hook still defines the retired profile directory"
# Behaviour fixtures emulate the scoped helper, which already owns the shared
# certificate lock before invoking the hook.
FIVEGPN_CERT_LOCK_HELD=1

# Fixtures are intentionally self-signed; production chain verification itself
# is locked structurally below while SAN/key/publication behavior stays real.
cert_chain_trusted() { return 0; }
grep -Fq 'certificate chain is not trusted for production TLS' "$HOOK" \
    || fail "renew hook does not enforce a trusted production chain"
grep -Fq 'acquire_deploy_lock || return 1' "$HOOK" \
    || fail "external Certbot deploy hook publication is not certificate-lock serialized"
acquire_deploy_lock() { return 0; }

CERT_ROOT="$TMP/cert"
DNS_ENV="$TMP/dns.env"
LE_LIVE_ROOT="$TMP/live"
LE_ARCHIVE_ROOT="$TMP/archive"
IOSGEN="$TMP/gen-ios-profile.sh"
UI_DIR="$TMP/ui"
load_ui_generation_helper || fail "could not load UI generation helper fixture"
# A sentinel keeps a partially updated hook inside the fixture and lets the
# invocation assertion prove that this retired destination was not selected.
WWW_DIR="$TMP/retired-www"
PROFILE_LOG="$TMP/profile.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$LE_LIVE_ROOT" "$LE_ARCHIVE_ROOT"
chmod 0755 "$TMP"
ui_generation_claim_root "$UI_DIR" || fail "could not claim UI generation fixture"
UI_DIST="$TMP/ui-dist"
mkdir -p "$UI_DIST/assets"
printf '<html>renew fixture</html>\n' > "$UI_DIST/index.html"
printf 'asset\n' > "$UI_DIST/assets/app-12345678.js"
UI_INITIAL="$(ui_generation_stage_tree "$UI_DIR" "$UI_DIST" v1.0.0)" \
    || fail "could not stage initial UI generation fixture"
printf 'old dot\n' > "$UI_INITIAL/ios-dot.mobileconfig"
printf 'old intercept\n' > "$UI_INITIAL/ios-intercept-ca.mobileconfig"
dot_sha="$(sha256sum "$UI_INITIAL/ios-dot.mobileconfig" | awk '{print $1}')"
intercept_sha="$(sha256sum "$UI_INITIAL/ios-intercept-ca.mobileconfig" | awk '{print $1}')"
cat > "$UI_INITIAL/.5gpn-profile-inputs" <<EOF
version=1
dot_signer_leaf_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dot_public_key_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
intercept_ca_der_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
domain=dot.example.test
gateway_ipv4=192.0.2.10
ios_dot_sha256=${dot_sha}
ios_intercept_ca_sha256=${intercept_sha}
EOF
ui_generation_publish "$UI_DIR" "$UI_INITIAL" \
    || fail "could not publish initial UI generation fixture"
cat > "$IOSGEN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PROFILE_LOG"
for name in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    printf 'renewed %s\n' "$name" > "$3/$name"
done
dot_sha="$(sha256sum "$3/ios-dot.mobileconfig" | awk '{print $1}')"
intercept_sha="$(sha256sum "$3/ios-intercept-ca.mobileconfig" | awk '{print $1}')"
cat > "$3/.5gpn-profile-inputs" <<MANIFEST
version=1
dot_signer_leaf_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dot_public_key_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
intercept_ca_der_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
domain=dot.example.test
gateway_ipv4=192.0.2.10
ios_dot_sha256=${dot_sha}
ios_intercept_ca_sha256=${intercept_sha}
MANIFEST
EOF
chmod +x "$IOSGEN"
export PROFILE_LOG
printf '%s\n' "$CONFIG_ROOT_MARKER_VALUE" > "$TMP/$CONFIG_ROOT_MARKER"
chmod 0644 "$TMP/$CONFIG_ROOT_MARKER"
mkdir -p "$CERT_ROOT"
chmod 0751 "$CERT_ROOT"
chmod g-s "$CERT_ROOT"
printf '%s\n' "$CERT_ROOT_MARKER_VALUE" > "$CERT_ROOT/$CERT_ROOT_MARKER"
printf '%s\n' 'mode=cloudflare' 'base=example.test' 'certbot_lineage=owned' \
    > "$CERT_ROOT/.provenance"
chmod 0644 "$CERT_ROOT/$CERT_ROOT_MARKER"
chmod 0640 "$CERT_ROOT/.provenance"
for role in dot console; do
    mkdir -p "$CERT_ROOT/$role/generations"
    chmod 0750 "$CERT_ROOT/$role" "$CERT_ROOT/$role/generations"
    chmod g-s "$CERT_ROOT/$role" "$CERT_ROOT/$role/generations"
    printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:${role}" \
        > "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
    chmod 0644 "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
done

systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$1" in
        is-active|reload) return 0 ;;
        *) return 1 ;;
    esac
}

write_env() {
    local mode="${1:-cloudflare}"
    printf '%s\n' \
        'DNS_BASE_DOMAIN=EXAMPLE.TEST.' \
        'DNS_GATEWAY_IP=192.0.2.10' \
        "CERT_MODE=${mode}" > "$DNS_ENV"
}

generate_cert() {
    local dir="$1" sans="$2"
    local name archive
    name="$(basename -- "$dir")"
    archive="$LE_ARCHIVE_ROOT/$name"
    mkdir -p "$dir" "$archive"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$archive/privkey1.pem" -out "$archive/fullchain1.pem" \
        -subj '/CN=example.test' -addext "subjectAltName=${sans}" \
        >/dev/null 2>&1
    ln -sfn "../../archive/$name/fullchain1.pem" "$dir/fullchain.pem"
    ln -sfn "../../archive/$name/privkey1.pem" "$dir/privkey.pem"
}

mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

role_checksums() {
    cksum \
        "$CERT_ROOT/dot/current/fullchain.pem" "$CERT_ROOT/dot/current/privkey.pem" \
        "$CERT_ROOT/console/current/fullchain.pem" "$CERT_ROOT/console/current/privkey.pem"
}

roles_unpublished() {
    local role
    for role in dot console; do
        [[ ! -e "$CERT_ROOT/$role/current" && ! -L "$CERT_ROOT/$role/current" ]] || return 1
        ! find "$CERT_ROOT/$role/generations" -mindepth 1 -print -quit | grep -q . || return 1
    done
}

write_env
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,IP:192.0.2.10'
generate_cert "$LE_LIVE_ROOT/other.test" 'DNS:other.test,DNS:*.other.test'

# A system-wide certbot deploy hook receives every renewed lineage. An unrelated
# lineage must be a successful no-op: no role files and no daemon reload.
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/other.test"
original_load_ui_helper="$(declare -f load_ui_generation_helper)"
load_ui_generation_helper() { return 99; }
renew_hook_main >/dev/null
eval "$original_load_ui_helper"
roles_unpublished || fail "unrelated lineage created role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "unrelated lineage touched systemd: $(cat "$SYSTEMCTL_LOG")"
pass "unrelated lineage is ignored without reload"

# Certbot duplicate suffixes are not accepted as aliases for the configured
# cert-name; bot renewal and hook deployment both target the exact base name.
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test-0001"
renew_hook_main >/dev/null
[[ ! -s "$SYSTEMCTL_LOG" ]] && roles_unpublished \
    || fail "duplicate/foreign cert-name was treated as the current lineage"
pass "only the exact configured cert-name is accepted"

# Even broken 5gpn mode configuration must not break an unrelated system-wide
# Certbot deploy hook invocation.
write_env nonsense
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/other.test"
renew_hook_main >/dev/null
[[ ! -s "$SYSTEMCTL_LOG" ]] && roles_unpublished \
    || fail "unrelated lineage was not a no-op with an invalid CERT_MODE"
pass "unrelated lineage remains a no-op with invalid 5gpn certificate mode"

# The production hook must fail closed for debug and unknown modes when Certbot
# presents the configured lineage. Debug certificate installation is owned by
# the explicit installer path, never by an ACME deploy hook.
for mode in debug http nonsense; do
    write_env "$mode"
    : > "$SYSTEMCTL_LOG"
    RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test"
    if renew_hook_main >/dev/null 2>&1; then
        fail "configured lineage was accepted with CERT_MODE=$mode"
    fi
    [[ ! -s "$SYSTEMCTL_LOG" ]] && roles_unpublished \
        || fail "CERT_MODE=$mode published or reloaded before failing"
done
pass "debug, aliases, and invalid production deploy-hook modes fail closed"

# A valid Cloudflare apex+wildcard pair is staged in each destination and
# published with final permissions. Reload happens only after publication.
write_env cloudflare
: > "$SYSTEMCTL_LOG"
: > "$PROFILE_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test/"
renew_hook_main >/dev/null
for role in dot console; do
    [[ -L "$CERT_ROOT/$role/current" ]] || fail "$role current generation is not an atomic symlink"
    cert="$CERT_ROOT/$role/current/fullchain.pem"
    key="$CERT_ROOT/$role/current/privkey.pem"
    [[ -s "$cert" && -s "$key" ]] || fail "$role certificate pair was not published"
    [[ "$(mode_of "$cert")" == 640 && "$(mode_of "$key")" == 640 ]] \
        || fail "$role certificate pair does not have mode 0640"
    validate_cert_pair "$cert" "$key" cloudflare example.test \
        console.example.test dot.example.test >/dev/null \
        || fail "$role certificate pair failed post-publication validation"
done
profile_candidate="$(cut -f3 "$PROFILE_LOG")"
[[ "$(cut -f1-2 "$PROFILE_LOG")" == $'dot.example.test\t192.0.2.10' \
   && "$profile_candidate" == "$UI_DIR/generations/.candidate-generation-"* ]] \
    || fail "renew hook did not re-sign profiles inside a cloned unpublished generation"
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    [[ -s "$UI_DIR/current/$profile" ]] || fail "renew hook did not publish $profile through current"
done
[[ ! -e "$WWW_DIR/ios-dot.mobileconfig" \
   && ! -e "$WWW_DIR/ios-intercept-ca.mobileconfig" ]] \
    || fail "renew hook published a profile into the retired directory"
if find "$UI_DIR" -mindepth 1 -name '.candidate-generation-*' -print | grep -q .; then
    fail "renew hook left an unpublished UI generation candidate"
fi
[[ ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "valid certificate publication incorrectly used SIGHUP/systemctl"
if find "$CERT_ROOT" \( -name '.new.*' -o -name '.current.*' \) \
    | grep -q .; then
    fail "staging files were left behind after successful publication"
fi
pass "valid Cloudflare pair and renewed profiles publish through one current generation switch"

current_before_skip="$(readlink -- "$UI_DIR/current")"
: > "$PROFILE_LOG"
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,IP:192.0.2.10'
FIVEGPN_SKIP_PROFILE_REFRESH=1 renew_hook_main >/dev/null
[[ ! -s "$PROFILE_LOG" && "$(readlink -- "$UI_DIR/current")" == "$current_before_skip" ]] \
    || fail "installer-deferred certificate publication performed an intermediate profile/current switch"
pass "installer certificate publication can defer profiles to the enclosing single UI switch"

# An exact-lineage deployment publishes valid role copies before attempting the
# non-critical profile refresh. A missing UI helper must not roll those roles
# back or fail the external Certbot hook; the profile-only entrypoint then
# repairs the stale generation without republishing the already-matching roles.
role_before_profile_failure="$(sha256sum "$CERT_ROOT/dot/current/fullchain.pem" | awk '{print $1}')"
current_before_profile_failure="$(readlink -- "$UI_DIR/current")"
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,IP:192.0.2.10'
original_load_ui_helper="$(declare -f load_ui_generation_helper)"
load_ui_generation_helper() { return 99; }
renew_hook_main >/dev/null \
    || fail "profile dependency failure incorrectly failed exact-lineage role deployment"
eval "$original_load_ui_helper"
role_after_profile_failure="$(sha256sum "$CERT_ROOT/dot/current/fullchain.pem" | awk '{print $1}')"
[[ "$role_after_profile_failure" != "$role_before_profile_failure" \
   && "$(readlink -- "$UI_DIR/current")" == "$current_before_profile_failure" ]] \
    || fail "profile dependency failure did not preserve the role-first/current-stable boundary"
: > "$PROFILE_LOG"
FIVEGPN_PROFILE_ONLY_REFRESH=1 renew_hook_main >/dev/null \
    || fail "profile-only recovery could not repair the stale UI generation"
[[ -s "$PROFILE_LOG" && "$(readlink -- "$UI_DIR/current")" != "$current_before_profile_failure" ]] \
    || fail "profile-only recovery did not activate a repaired generation"
pass "role-first profile failure converges through the profile-only recovery entrypoint"

generator_original="$TMP/gen-ios-profile.original"
cp "$IOSGEN" "$generator_original"
current_before_generator_gate="$(readlink -- "$UI_DIR/current")"
: > "$PROFILE_LOG"
ln "$IOSGEN" "$TMP/gen-ios-profile.hardlink"
if refresh_ios_profile_generation >/dev/null 2>&1; then
    fail "hardlinked profile generator was accepted before the FD anchor"
fi
rm -f "$TMP/gen-ios-profile.hardlink"
[[ ! -s "$PROFILE_LOG" && "$(readlink -- "$UI_DIR/current")" == "$current_before_generator_gate" ]] \
    || fail "hardlinked generator reached candidate mutation or changed current"
mv "$IOSGEN" "$TMP/gen-ios-profile.real"
ln -s "$TMP/gen-ios-profile.real" "$IOSGEN"
if refresh_ios_profile_generation >/dev/null 2>&1; then
    fail "symlinked profile generator was accepted before the FD anchor"
fi
rm -f "$IOSGEN"
mv "$TMP/gen-ios-profile.real" "$IOSGEN"
[[ ! -s "$PROFILE_LOG" && "$(readlink -- "$UI_DIR/current")" == "$current_before_generator_gate" ]] \
    || fail "symlinked generator reached candidate mutation or changed current"

generator_race_log="$TMP/generator-race.log"
generator_replacement="$TMP/gen-ios-profile.replacement"
cat > "$generator_replacement" <<'EOF'
#!/usr/bin/env bash
printf 'NEW\n' >> "$GENERATOR_RACE_LOG"
exit 99
EOF
chmod 0755 "$generator_replacement"
{
    head -n 1 "$generator_original"
    cat <<'EOF'
printf 'OLD\n' >> "$GENERATOR_RACE_LOG"
mv -Tf -- "$GENERATOR_RACE_REPLACEMENT" "$GENERATOR_RACE_PATH"
EOF
    tail -n +2 "$generator_original"
} > "$IOSGEN"
chmod 0755 "$IOSGEN"
current_before_generator_race="$(readlink -- "$UI_DIR/current")"
if GENERATOR_RACE_LOG="$generator_race_log" \
    GENERATOR_RACE_REPLACEMENT="$generator_replacement" GENERATOR_RACE_PATH="$IOSGEN" \
    refresh_ios_profile_generation >/dev/null 2>&1; then
    fail "generator path drift after FD anchoring was accepted"
fi
[[ "$(cat "$generator_race_log" 2>/dev/null || true)" == OLD \
   && "$(readlink -- "$UI_DIR/current")" == "$current_before_generator_race" ]] \
    || fail "FD anchoring did not execute OLD bytes or path drift changed current"
find "$UI_DIR/generations" -mindepth 1 -maxdepth 1 -name '.candidate-generation-*' -print -quit \
    | grep -q . && fail "generator path drift left an unpublished candidate"
cp "$generator_original" "$IOSGEN"
chmod 0755 "$IOSGEN"
pass "generator symlink, hardlink, and anchored-path drift fail before current publication"

mkdir -p "$CERT_ROOT/web"
if renew_hook_main >/dev/null 2>&1; then
    fail "renew hook accepted a retired web certificate role"
fi
rm -rf -- "$CERT_ROOT/web"
pass "renew hook rejects retired certificate roles"

# SIGKILL cannot run traps. Root-owned, structurally valid unpublished
# candidates from an interrupted prior run are scrubbed under the lock before
# the strict role-tree validator runs again.
dot_current="$(readlink -- "$CERT_ROOT/dot/current")"
mkdir -p "$CERT_ROOT/dot/generations/.new.ABC123"
chmod 0750 "$CERT_ROOT/dot/generations/.new.ABC123"
chmod g-s "$CERT_ROOT/dot/generations/.new.ABC123"
cp "$CERT_ROOT/dot/current/fullchain.pem" \
    "$CERT_ROOT/dot/generations/.new.ABC123/fullchain.pem"
chmod 0640 "$CERT_ROOT/dot/generations/.new.ABC123/fullchain.pem"
mkdir -p "$CERT_ROOT/dot/generations/.new.EARLYKILL"
chmod 0700 "$CERT_ROOT/dot/generations/.new.EARLYKILL"
chmod g-s "$CERT_ROOT/dot/generations/.new.EARLYKILL"
orphan="$CERT_ROOT/dot/generations/generation-20000101T000000Z-99-99"
mkdir -p "$orphan"
chmod 0750 "$orphan"
chmod g-s "$orphan"
cp "$CERT_ROOT/dot/current/fullchain.pem" "$orphan/fullchain.pem"
cp "$CERT_ROOT/dot/current/privkey.pem" "$orphan/privkey.pem"
chmod 0640 "$orphan/fullchain.pem" "$orphan/privkey.pem"
ln -s "$dot_current" "$CERT_ROOT/dot/.current.123.456"
renew_hook_main >/dev/null
[[ ! -e "$CERT_ROOT/dot/generations/.new.ABC123" \
   && ! -e "$CERT_ROOT/dot/generations/.new.EARLYKILL" \
   && ! -e "$orphan" \
   && ! -e "$CERT_ROOT/dot/.current.123.456" \
   && ! -L "$CERT_ROOT/dot/.current.123.456" ]] \
    || fail "interrupted public certificate candidates were not scrubbed"
pass "interrupted public certificate candidates are safely scrubbed"

if (
    early="$TMP/early-root-group"
    mkdir -p "$early"
    chmod 0700 "$early"
    chmod g-s "$early"
    load_cert_role_helpers
    cert_role_ctl_empty_preclaim_candidate_is_safe "$early" 99999
); then
    pass "root-group empty mktemp generation is safely recoverable"
else
    fail "root-group pre-chgrp generation permanently blocks renewal"
fi
if (
    early="$TMP/early-role-group"
    mkdir -p "$early"
    chmod 0700 "$early"
    chmod g-s "$early"
    load_cert_role_helpers
    cert_role_ctl_empty_preclaim_candidate_is_safe "$early" "$(path_gid "$early")"
); then
    pass "role-group empty pre-chmod generation is safely recoverable"
else
    fail "role-group pre-chmod generation permanently blocks renewal"
fi

before="$(role_checksums)"

# A compromised runtime account can recreate marker bytes but cannot recreate
# root ownership. Simulate that ownership drift through the metadata helper and
# require the hook to reject it before touching any live role.
original_publication_fs_uid="$(declare -f publication_fs_uid)"
UNSAFE_OWNER_PATH="$CERT_ROOT/console/$CERT_ROLE_MARKER"
publication_fs_uid() {
    if [[ "$1" == "$UNSAFE_OWNER_PATH" ]]; then
        printf '%s\n' "$((EUID + 1))"
    else
        stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
    fi
}
if renew_hook_main >/dev/null 2>&1; then
    fail "service-owned certificate role marker was accepted"
fi
eval "$original_publication_fs_uid"
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "service-owned marker changed live role files"
pass "service-owned role marker fails closed before publication"

# Neither the certificate root nor a role may be replaced with a symlink, even
# when the link resolves back to a byte-for-byte valid owned tree.
mv -- "$CERT_ROOT/console" "$CERT_ROOT/console.saved"
ln -s console.saved "$CERT_ROOT/console"
if renew_hook_main >/dev/null 2>&1; then
    fail "symlinked certificate role was accepted"
fi
rm -f -- "$CERT_ROOT/console"
mv -- "$CERT_ROOT/console.saved" "$CERT_ROOT/console"
mv -- "$CERT_ROOT" "${CERT_ROOT}.saved"
ln -s "$(basename -- "$CERT_ROOT").saved" "$CERT_ROOT"
if renew_hook_main >/dev/null 2>&1; then
    fail "symlinked certificate root was accepted"
fi
rm -f -- "$CERT_ROOT"
mv -- "${CERT_ROOT}.saved" "$CERT_ROOT"
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "symlink boundary test changed live role files"
pass "symlinked certificate root and role fail closed"

# A second hardlink to a published keypair file defeats path-only ownership
# checks and is therefore rejected as an unsafe generation tree.
dot_generation="$(readlink -- "$CERT_ROOT/dot/current")"
ln -- "$CERT_ROOT/dot/$dot_generation/fullchain.pem" \
    "$CERT_ROOT/dot/$dot_generation/hardlink.pem"
if renew_hook_main >/dev/null 2>&1; then
    fail "hardlinked certificate generation file was accepted"
fi
rm -f -- "$CERT_ROOT/dot/$dot_generation/hardlink.pem"
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "hardlink boundary test changed live role files"
pass "hardlinked certificate generation fails closed"

# Cloudflare still requires both the apex and wildcard SANs.
generate_cert "$LE_LIVE_ROOT/example.test" 'DNS:example.test'
: > "$SYSTEMCTL_LOG"
RENEWED_LINEAGE="$LE_LIVE_ROOT/example.test"
if renew_hook_main >/dev/null 2>&1; then
    fail "certificate without wildcard SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "Cloudflare SAN failure changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "SAN validation failure reloaded the daemon"
pass "Cloudflare certificate missing wildcard fails closed before publication"

# Cloudflare DNS-01 also rejects DNS identities beyond the exact apex+wildcard
# set, while the IP SAN in the successful fixture above remains irrelevant.
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:example.test,DNS:*.example.test,DNS:extra.example.test'
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "Cloudflare certificate with an extra DNS SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "extra Cloudflare DNS SAN changed roles or reloaded the daemon"
pass "Cloudflare certificate with an extra DNS SAN fails before publication"

# HTTP-01 uses a non-wildcard lineage containing exactly the two
# derived service DNS names. Non-DNS SANs do not change that identity set.
write_env http-01
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:dot.example.test,IP:192.0.2.10'
: > "$SYSTEMCTL_LOG"
renew_hook_main >/dev/null
for role in dot console; do
    validate_cert_pair "$CERT_ROOT/$role/current/fullchain.pem" "$CERT_ROOT/$role/current/privkey.pem" \
        http-01 example.test console.example.test dot.example.test >/dev/null \
        || fail "$role HTTP-01 certificate failed post-publication validation"
done
[[ ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "valid HTTP-01 publication incorrectly used SIGHUP/systemctl"
pass "HTTP-01 publishes a certificate covering both service SANs"

# An extra HTTP-01 DNS identity must fail before any live role is changed.
write_env http-01
before="$(role_checksums)"
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:dot.example.test,DNS:extra.example.test'
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "HTTP-01 certificate with an extra DNS SAN was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" && ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "extra HTTP-01 DNS SAN changed roles or reloaded the daemon"
pass "HTTP-01 certificate with an extra DNS SAN fails before publication"

# Every required HTTP-01 SAN is independently mandatory. Validation happens
# against the lineage before any live role is touched.
for missing in console dot; do
    case "$missing" in
        console) sans='DNS:dot.example.test' ;;
        dot) sans='DNS:console.example.test' ;;
    esac
    generate_cert "$LE_LIVE_ROOT/example.test" "$sans"
    : > "$SYSTEMCTL_LOG"
    if renew_hook_main >/dev/null 2>&1; then
        fail "HTTP-01 certificate missing $missing SAN was accepted"
    fi
    after="$(role_checksums)"
    [[ "$before" == "$after" ]] \
        || fail "HTTP-01 certificate missing $missing SAN changed live role files"
    [[ ! -s "$SYSTEMCTL_LOG" ]] \
        || fail "HTTP-01 certificate missing $missing SAN reloaded the daemon"
done
pass "HTTP-01 certificate missing any required service SAN fails before publication"

# A valid-SAN leaf paired with a different private key must likewise fail closed.
write_env http-01
generate_cert "$LE_LIVE_ROOT/example.test" \
    'DNS:console.example.test,DNS:dot.example.test'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$LE_LIVE_ROOT/example.test/privkey.pem" >/dev/null 2>&1
: > "$SYSTEMCTL_LOG"
if renew_hook_main >/dev/null 2>&1; then
    fail "mismatched certificate/private key was accepted"
fi
after="$(role_checksums)"
[[ "$before" == "$after" ]] || fail "key mismatch changed live role files"
[[ ! -s "$SYSTEMCTL_LOG" ]] || fail "key mismatch reloaded the daemon"
pass "certificate/private-key mismatch fails closed before publication"

echo "renew hook tests: PASS"
