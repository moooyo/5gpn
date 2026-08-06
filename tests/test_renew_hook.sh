#!/usr/bin/env bash
# Behaviour checks for scoped, validated, non-truncating certificate deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/renew-hook.sh"
TMP="$(mktemp -d)"
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
grep -Fq 'dot|console) group="$FIVEGPN_CERT_GROUP"' "$HOOK" \
    || fail "current certificate roles do not map to fivegpn"
grep -Fxq 'UI_DIR=/opt/5gpn/ui' "$HOOK" \
    || fail "renew hook profile destination is not the live UI directory"
grep -Eq '^WWW_DIR=/opt/5gpn/www$' "$HOOK" \
    && fail "renew hook still defines the retired profile directory"
role_group() { id -gn; }
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
IOSGEN="$TMP/gen-ios-profile.sh"
UI_DIR="$TMP/ui"
# A sentinel keeps a partially updated hook inside the fixture and lets the
# invocation assertion prove that this retired destination was not selected.
WWW_DIR="$TMP/retired-www"
PROFILE_LOG="$TMP/profile.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$LE_LIVE_ROOT" "$UI_DIR"
printf '%s\n' "$UI_OWNERSHIP_VALUE" > "$UI_DIR/$UI_OWNERSHIP_MARKER"
chmod 0755 "$UI_DIR"
chmod 0644 "$UI_DIR/$UI_OWNERSHIP_MARKER"
cat > "$IOSGEN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PROFILE_LOG"
mkdir -p -- "$3"
for name in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    candidate="$(mktemp "$3/.profile.XXXXXX")"
    printf 'renewed %s\n' "$name" > "$candidate"
    mv -f -- "$candidate" "$3/$name"
done
EOF
chmod +x "$IOSGEN"
export PROFILE_LOG
chmod 0755 "$TMP"
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
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
        -subj '/CN=example.test' -addext "subjectAltName=${sans}" \
        >/dev/null 2>&1
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
renew_hook_main >/dev/null
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
[[ "$(cat "$PROFILE_LOG")" == $'dot.example.test\t192.0.2.10\t'"$UI_DIR" ]] \
    || fail "renew hook did not re-sign profiles directly into the live UI directory"
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    [[ -s "$UI_DIR/$profile" ]] || fail "renew hook did not publish $profile into UI_DIR"
done
[[ ! -e "$WWW_DIR/ios-dot.mobileconfig" \
   && ! -e "$WWW_DIR/ios-intercept-ca.mobileconfig" ]] \
    || fail "renew hook published a profile into the retired directory"
if find "$UI_DIR" -mindepth 1 -name '.profile.*' -print | grep -q .; then
    fail "renew hook left a profile publication candidate in UI_DIR"
fi
[[ ! -s "$SYSTEMCTL_LOG" ]] \
    || fail "valid certificate publication incorrectly used SIGHUP/systemctl"
if find "$CERT_ROOT" \( -name '.new.*' -o -name '.current.*' \) \
    | grep -q .; then
    fail "staging files were left behind after successful publication"
fi
pass "valid Cloudflare pair and renewed profiles publish into their live paths"

# A structurally valid web role may remain from an older installation. It is
# accepted as retained migration evidence, but is not one of the renewed roles.
legacy_generation="$CERT_ROOT/web/generations/generation-20000101T000000Z-1-1"
mkdir -p "$legacy_generation"
chmod 0750 "$CERT_ROOT/web" "$CERT_ROOT/web/generations" "$legacy_generation"
chmod g-s "$CERT_ROOT/web" "$CERT_ROOT/web/generations" "$legacy_generation"
printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:web" > "$CERT_ROOT/web/$CERT_ROLE_MARKER"
cp "$CERT_ROOT/dot/current/fullchain.pem" "$legacy_generation/fullchain.pem"
cp "$CERT_ROOT/dot/current/privkey.pem" "$legacy_generation/privkey.pem"
chmod 0644 "$CERT_ROOT/web/$CERT_ROLE_MARKER"
chmod 0640 "$legacy_generation/fullchain.pem" "$legacy_generation/privkey.pem"
ln -s generations/generation-20000101T000000Z-1-1 "$CERT_ROOT/web/current"
legacy_target="$(readlink -- "$CERT_ROOT/web/current")"
legacy_checksum="$(cksum "$legacy_generation/fullchain.pem" "$legacy_generation/privkey.pem")"
renew_hook_main >/dev/null
[[ "$(readlink -- "$CERT_ROOT/web/current")" == "$legacy_target" \
   && "$(cksum "$legacy_generation/fullchain.pem" "$legacy_generation/privkey.pem")" == "$legacy_checksum" ]] \
    || fail "renew hook refreshed or replaced retained legacy web material"
rm -rf -- "$CERT_ROOT/web"
pass "renew hook validates but does not refresh retained legacy web material"

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
    root_gid() { path_gid "$early"; }
    interrupted_empty_generation_is_safe "$early" 99999
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
    root_gid() { printf '%s\n' 99999; }
    interrupted_empty_generation_is_safe "$early" "$(path_gid "$early")"
); then
    pass "role-group empty pre-chmod generation is safely recoverable"
else
    fail "role-group pre-chmod generation permanently blocks renewal"
fi

before="$(role_checksums)"

# A compromised runtime account can recreate marker bytes but cannot recreate
# root ownership. Simulate that ownership drift through the metadata helper and
# require the hook to reject it before touching any live role.
original_path_uid="$(declare -f path_uid)"
UNSAFE_OWNER_PATH="$CERT_ROOT/console/$CERT_ROLE_MARKER"
path_uid() {
    if [[ "$1" == "$UNSAFE_OWNER_PATH" ]]; then
        printf '%s\n' "$((EUID + 1))"
    else
        stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
    fi
}
if renew_hook_main >/dev/null 2>&1; then
    fail "service-owned certificate role marker was accepted"
fi
eval "$original_path_uid"
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
