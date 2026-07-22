#!/usr/bin/env bash
# Behaviour-level regression checks for destructive installer operations.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
QUICK="$ROOT/quick-install.sh"
FAIL=0
pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d "$ROOT/.test-installer-safety.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
POSIX_MODES=0
printf probe > "$TMP/.mode-probe"
chmod 0600 "$TMP/.mode-probe" 2>/dev/null || true
[[ "$(stat -c %a "$TMP/.mode-probe" 2>/dev/null || stat -f %Lp "$TMP/.mode-probe")" == 600 ]] \
    && POSIX_MODES=1

# Main-installer archive validation is behavioral: ordinary files/directories
# pass, while links, hardlinks, and special files are rejected before extract.
archive_fixture="$(mktemp -d /tmp/5gpn-archive-test.XXXXXX)"
mkdir -p "$archive_fixture/safe/dir"
printf 'payload\n' > "$archive_fixture/safe/dir/file.txt"
tar -czf "$archive_fixture/safe.tgz" -C "$archive_fixture/safe" .
archive_paths_safe tar "$archive_fixture/safe.tgz" \
    && pass "main installer accepts an ordinary tar tree" \
    || fail "main installer rejected an ordinary tar tree"

mkdir -p "$archive_fixture/hardlink"
printf 'payload\n' > "$archive_fixture/hardlink/file.txt"
ln "$archive_fixture/hardlink/file.txt" "$archive_fixture/hardlink/alias.txt"
tar -czf "$archive_fixture/hardlink.tgz" -C "$archive_fixture/hardlink" .
if archive_paths_safe tar "$archive_fixture/hardlink.tgz" >/dev/null 2>&1; then
    fail "main installer accepted a tar hardlink"
else
    pass "main installer rejects tar hardlinks before extraction"
fi

mkdir -p "$archive_fixture/special"
if mkfifo "$archive_fixture/special/pipe"; then
    tar -czf "$archive_fixture/special.tgz" -C "$archive_fixture/special" .
    if archive_paths_safe tar "$archive_fixture/special.tgz" >/dev/null 2>&1; then
        fail "main installer accepted a tar special file"
    else
        pass "main installer rejects tar special files before extraction"
    fi
else
    fail "test host could not create the FIFO needed for tar special-file coverage"
fi

if command -v base64 >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    # Prebuilt with Go's archive/zip using Unix modes: one ordinary regular
    # file and one symlink entry. Embedding keeps this shell gate independent
    # of a zip-creation tool while exercising the exact unzip metadata parser.
    safe_zip_b64='UEsDBBQACAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAAYWxpYXMudHh0cGF5bG9hZApQSwcIEs5IXwgAAAAIAAAAUEsBAhQDFAAIAAAAAAAAABLOSF8IAAAACAAAAAkAAAAAAAAAAAAAAKSBAAAAAGFsaWFzLnR4dFBLBQYAAAAAAQABADcAAAA/AAAAAAA='
    link_zip_b64='UEsDBBQACAAAAAAAAAAAAAAAAAAAAAAAAAAJAAAAYWxpYXMudHh0ZmlsZS50eHRQSwcIJRb34AgAAAAIAAAAUEsBAhQDFAAIAAAAAAAAACUW9+AIAAAACAAAAAkAAAAAAAAAAAAAAP+hAAAAAGFsaWFzLnR4dFBLBQYAAAAAAQABADcAAAA/AAAAAAA='
    printf '%s' "$safe_zip_b64" | base64 -d > "$archive_fixture/safe.zip"
    archive_paths_safe zip "$archive_fixture/safe.zip" \
        && pass "main installer accepts an ordinary zip tree" \
        || fail "main installer rejected an ordinary zip tree"

    printf '%s' "$link_zip_b64" | base64 -d > "$archive_fixture/link.zip"
    if archive_paths_safe zip "$archive_fixture/link.zip" >/dev/null 2>&1; then
        fail "main installer accepted a zip symlink"
    else
        pass "main installer rejects zip special entries before extraction"
    fi
else
    pass "zip special-entry behavior skipped because base64/unzip are unavailable"
fi
rm -rf -- "$archive_fixture"

if service_account_name_is_valid gpn-dns \
   && ! service_account_name_is_valid 5gpn-dns \
   && ! service_account_name_is_valid 'gpn.dns'; then
    pass "service accounts use Debian/systemd strict user-name syntax"
else
    fail "service account name validation does not match strict Linux syntax"
fi

unit_conflicts="$TMP/systemd-conflicts"
mkdir -p "$unit_conflicts"
if ! journal_export_instances_clear "$unit_conflicts"; then
    fail "empty systemd search root was treated as an exporter conflict"
fi
touch "$unit_conflicts/5gpn-journal@5gpn-dns.service"
if journal_export_instances_clear "$unit_conflicts"; then
    fail "pre-existing exact journal exporter instance was accepted"
else
    pass "exact journal exporter instance conflicts are rejected before polkit publication"
fi
rm -f -- "$unit_conflicts/5gpn-journal@5gpn-dns.service"
mkdir "$unit_conflicts/5gpn-dns.service.d"
if systemd_unit_has_dropins 5gpn-dns.service "$unit_conflicts"; then
    pass "systemd unit drop-ins invalidate the project ownership fingerprint"
else
    fail "systemd unit drop-in was ignored by ownership validation"
fi
rmdir "$unit_conflicts/5gpn-dns.service.d"
mkdir "$unit_conflicts/5gpn-.service.d"
if systemd_unit_has_dropins 5gpn-dns.service "$unit_conflicts" \
   && [[ "$SYSTEMD_UNIT_CONFLICT_REASON" == *5gpn-.service.d* ]]; then
    pass "systemd dash-prefix drop-ins invalidate managed unit ownership"
else
    fail "systemd dash-prefix drop-in was ignored by ownership validation"
fi
rmdir "$unit_conflicts/5gpn-.service.d"

mkdir "$unit_conflicts/service.d"
cat > "$unit_conflicts/service.d/10-host-defaults.conf" <<'EOF'
[Service]
TimeoutStopSec=90s
EOF
if systemd_unit_has_dropins 5gpn-dns.service "$unit_conflicts"; then
    fail "unrelated global service default was treated as an execution override"
else
    pass "unrelated global service defaults remain compatible"
fi
cat > "$unit_conflicts/service.d/20-exec.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/tmp/not-5gpn
EOF
if systemd_unit_has_dropins 5gpn-dns.service "$unit_conflicts" \
   && [[ "$SYSTEMD_UNIT_CONFLICT_REASON" == *global*service.d* ]]; then
    pass "global service execution overrides invalidate managed unit ownership"
else
    fail "global service ExecStart override was ignored"
fi
rm -rf -- "$unit_conflicts/service.d"

mkdir "$unit_conflicts/5gpn-intercept-.service.d"
if systemd_unit_has_dropins 5gpn-intercept-cert.service "$unit_conflicts"; then
    pass "multi-segment systemd dash-prefix overrides are rejected"
else
    fail "multi-segment systemd dash-prefix override was ignored"
fi
rm -rf -- "$unit_conflicts/5gpn-intercept-.service.d"

# Stable and beta release tags are strict, disjoint SemVer forms.
if valid_dns_stable_release_tag 9.8.7 \
   && ! valid_dns_stable_release_tag 9.8.7-beta.1 \
   && ! valid_dns_stable_release_tag 09.8.7 \
   && valid_dns_beta_release_tag 9.8.8-beta.1 \
   && valid_dns_beta_release_tag 9.8.8-beta.12 \
   && ! valid_dns_beta_release_tag 9.8.8-beta.0 \
   && ! valid_dns_beta_release_tag 9.8.8-beta.01; then
    pass "main installer enforces disjoint official and beta tag grammars"
else
    fail "main installer release tag grammar is not strict"
fi

# Source checkouts resolve the selected channel once, while release bundles
# remain pinned to the exact tag stamped by the release workflow.
latest_json="$TMP/latest-release.json"
printf '{"tag_name":"9.8.7"}\n' > "$latest_json"
DNS_VERSION_DEFAULT="latest"
DNS_RELEASE_CHANNEL="stable"
DNS_RELEASE_CHANNEL_EXPLICIT=0
resolved="$(resolve_dns_release_version "file://$latest_json" 2>/dev/null)"
if [[ "$resolved" == 9.8.7 ]]; then
    pass "source installer resolves the latest official release tag"
else
    fail "source installer did not resolve the latest official release tag"
fi

printf '{"tag_name":"9.8.8-beta.1"}\n' > "$latest_json"
if resolve_dns_release_version "file://$latest_json" >/dev/null 2>&1; then
    fail "official source resolution accepted a beta tag"
else
    pass "official source resolution refuses beta tags"
fi

beta_list="$TMP/beta-releases.json"
beta_metadata="$TMP/beta-release.json"
printf '%s\n' \
    '[{"tag_name":"9.8.7","draft":false,"prerelease":false},{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":true}]' \
    > "$beta_list"
printf '{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":true}\n' > "$beta_metadata"
DNS_RELEASE_CHANNEL="beta"
DNS_RELEASE_CHANNEL_EXPLICIT=1
resolved="$(resolve_dns_release_version "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" 2>/dev/null)"
if [[ "$resolved" == 9.9.0-beta.2 ]]; then
    pass "source installer resolves and verifies the latest beta prerelease"
else
    fail "source installer did not resolve the beta prerelease"
fi

printf '{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":false}\n' > "$beta_metadata"
if resolve_dns_release_version "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" >/dev/null 2>&1; then
    fail "source installer accepted beta metadata without prerelease status"
else
    pass "source installer rejects beta metadata without prerelease status"
fi

printf '[{"tag_name":"9.8.7","draft":false,"prerelease":false}]\n' > "$beta_list"
if resolve_dns_release_version "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" >/dev/null 2>&1; then
    fail "source installer fell back to official when beta was missing"
else
    pass "source installer fails closed when no beta exists"
fi

DNS_VERSION_DEFAULT="9.8.6"
DNS_RELEASE_CHANNEL="stable"
DNS_RELEASE_CHANNEL_EXPLICIT=0
resolved="$(resolve_dns_release_version "file://$TMP/absent" 2>/dev/null)"
if [[ "$resolved" == 9.8.6 ]]; then
    pass "release installer keeps its stamped tag without another lookup"
else
    fail "release installer did not keep its stamped tag"
fi

DNS_VERSION_DEFAULT="9.9.0-beta.2"
resolved="$(resolve_dns_release_version "file://$TMP/absent" 2>/dev/null)"
if [[ "$resolved" == 9.9.0-beta.2 ]]; then
    pass "installed beta management remains pinned without another lookup"
else
    fail "installed beta management did not retain its pinned tag"
fi

DNS_VERSION_DEFAULT="9.8.6"
DNS_RELEASE_CHANNEL="beta"
DNS_RELEASE_CHANNEL_EXPLICIT=1
if resolve_dns_release_version "file://$TMP/absent" >/dev/null 2>&1; then
    fail "explicit beta selection accepted an official stamped bundle"
else
    pass "explicit beta selection rejects an official stamped bundle"
fi

DNS_VERSION_DEFAULT="latest"
DNS_RELEASE_CHANNEL="stable"
DNS_RELEASE_CHANNEL_EXPLICIT=0

grep -Fq 'delegate_unpinned_installer' "$INSTALL" \
    && grep -Fq 'quick-install.sh' "$INSTALL" \
    && pass "unpinned source installs delegate to a version-matched bundle" \
    || fail "source installer can still mix checkout templates with release artifacts"

# Ownership verification must be safe under the installer's set -u mode. Keep
# the call in a subshell so a nounset regression is reported by this test rather
# than aborting the whole policy suite without a useful assertion.
owned_root="$TMP/owned-root"
mkdir -p "$owned_root"
printf '%s\n' 'test-owner-v1' > "$owned_root/.owner"
if (verify_ownership_marker "$owned_root" '.owner' 'test-owner-v1'); then
    pass "ownership marker verification is nounset-safe"
else
    fail "ownership marker verification aborts under set -u"
fi

# Fixed roots must distinguish a root-published marker from attacker-controlled
# bytes in a service-writable directory. Mock only stat/account lookups so the
# canonical-path and marker-content checks still exercise the real boundary.
if (
    BASE_DIR="$TMP/fixed-root-safe"
    mkdir -p "$BASE_DIR"
    printf '%s\n' "$BASE_OWNERSHIP_VALUE" > "$BASE_DIR/$BASE_OWNERSHIP_MARKER"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] && printf '644\n' || printf '755\n'
    }
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
); then
    pass "root-owned fixed runtime metadata is accepted"
else
    fail "valid fixed runtime metadata was rejected"
fi

if (
    marker_root="$TMP/hardlinked-marker"
    mkdir -p "$marker_root"
    printf 'marker-v1\n' > "$marker_root/.owner"
    ln "$marker_root/.owner" "$marker_root/.owner-alias"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { printf '644\n'; }
    ! root_ownership_marker_is_safe "$marker_root" .owner marker-v1
); then
    pass "root ownership markers must be single-link files"
else
    fail "hardlinked ownership marker was accepted"
fi

if (
    BASE_DIR="$TMP/fixed-root-forged"
    mkdir -p "$BASE_DIR"
    printf '%s\n' "$BASE_OWNERSHIP_VALUE" > "$BASE_DIR/$BASE_OWNERSHIP_MARKER"
    file_uid() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] && printf '1001\n' || printf '0\n'
    }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] && printf '644\n' || printf '755\n'
    }
    ! claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" >/dev/null 2>&1
); then
    pass "service-forgeable ownership marker content is rejected"
else
    fail "non-root ownership marker was accepted on a fixed root"
fi

if (
    BASE_DIR="$TMP/fixed-root-empty-untrusted"
    mkdir -p "$BASE_DIR"
    file_uid() { printf '1001\n'; }
    file_gid() { printf '1001\n'; }
    file_mode() { printf '755\n'; }
    ! claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" >/dev/null 2>&1 \
        && [[ ! -e "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]]
); then
    pass "empty fixed roots are trusted before marker publication"
else
    fail "fixed-root marker was written into an untrusted empty directory"
fi

if (
    CONF_DIR="$TMP/fixed-conf"
    DNS_SERVICE_USER=gpn-dns
    mkdir -p "$CONF_DIR"
    printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
    getent() {
        [[ "$1" == group && "$2" == gpn-dns ]] && printf 'gpn-dns:x:4242:\n'
    }
    file_uid() { printf '0\n'; }
    file_gid() {
        [[ "$1" == "$CONF_DIR" ]] && printf '4242\n' || printf '0\n'
    }
    file_mode() {
        [[ "$1" == "$CONF_DIR" ]] && printf '3771\n' || printf '644\n'
    }
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
); then
    pass "sticky root:gpn-dns configuration root remains valid"
else
    fail "sticky configuration-root design was rejected"
fi

if (
    INTERCEPT_CA_DIR="$TMP/legacy-intercept-ca"
    DNS_SERVICE_USER=gpn-dns
    normalized=0
    mkdir -p "$INTERCEPT_CA_DIR"
    printf '%s\n' "$INTERCEPT_CA_MARKER_VALUE" > "$INTERCEPT_CA_DIR/$INTERCEPT_CA_MARKER"
    printf '%s\n' cert > "$INTERCEPT_CA_DIR/root.crt"
    printf '%s\n' key > "$INTERCEPT_CA_DIR/root.key"
    getent() { [[ "$1" == group && "$2" == gpn-dns ]] && printf 'gpn-dns:x:4242:\n'; }
    file_uid() { printf '0\n'; }
    file_gid() {
        if [[ "$1" == "$INTERCEPT_CA_DIR/$INTERCEPT_CA_MARKER" && "$normalized" == 0 ]]; then
            printf '4242\n'
        else
            printf '0\n'
        fi
    }
    file_mode() {
        case "$1" in
            "$INTERCEPT_CA_DIR") [[ "$normalized" == 1 ]] && printf '700\n' || printf '2700\n' ;;
            "$INTERCEPT_CA_DIR/root.key") printf '600\n' ;;
            *) printf '644\n' ;;
        esac
    }
    file_nlink() { printf '1\n'; }
    chown() { return 0; }
    chmod() {
        [[ "$1" != 0700 || "$2" != "$INTERCEPT_CA_DIR" ]] || normalized=1
        return 0
    }
    legacy_intercept_ca_root_is_safe \
        && normalize_legacy_intercept_ca_root \
        && [[ "$normalized" == 1 ]]
); then
    pass "legacy setgid interception CA metadata normalizes after strict validation"
else
    fail "valid legacy interception CA metadata cannot upgrade safely"
fi

if (
    CONF_DIR="$TMP/cfg-get-safe"
    DNS_SERVICE_USER=gpn-dns
    mkdir -p "$CONF_DIR"
    printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
    printf 'DNS_BASE_DOMAIN=example.com\n' > "$CONF_DIR/dns.env"
    getent() { [[ "$1" == group && "$2" == gpn-dns ]] && printf 'gpn-dns:x:4242:\n'; }
    file_uid() { printf '0\n'; }
    file_gid() {
        [[ "$1" == "$CONF_DIR/dns.env" ]] && printf '4242\n' || printf '0\n'
    }
    file_mode() {
        case "$1" in
            "$CONF_DIR") printf '755\n' ;;
            "$CONF_DIR/$CONF_OWNERSHIP_MARKER") printf '644\n' ;;
            *) printf '640\n' ;;
        esac
    }
    [[ "$(cfg_get DNS_BASE_DOMAIN)" == example.com ]] || exit 1
    ln "$CONF_DIR/dns.env" "$CONF_DIR/dns.env.alias"
    ! cfg_get DNS_BASE_DOMAIN >/dev/null 2>&1 || exit 1
    rm -f -- "$CONF_DIR/dns.env" "$CONF_DIR/dns.env.alias"
    printf 'DNS_BASE_DOMAIN=attacker.example\n' > "$CONF_DIR/elsewhere"
    ln -s "$CONF_DIR/elsewhere" "$CONF_DIR/dns.env"
    ! cfg_get DNS_BASE_DOMAIN >/dev/null 2>&1
); then
    pass "cfg_get accepts only single-link regular dns.env under a trusted config root"
else
    fail "cfg_get followed or accepted an unsafe persisted configuration"
fi

certificate_boundary_modes_ok=1
for initial_mode in 755 2771; do
    if ! (
        boundary_mode="$initial_mode"
        CONF_DIR="$TMP/early-cert-conf-$initial_mode"
        INTERCEPT_DIR="$CONF_DIR/intercept"
        INTERCEPT_CA_DIR="$CONF_DIR/intercept-ca"
        DNS_CERT_DIR="$CONF_DIR/cert"
        CERT_MODE=cloudflare
        preflight_runtime_publication_paths() { :; }
        install() {
            [[ "$*" != *'-m 3771'*"$CONF_DIR"* ]] || boundary_mode=3771
            return 0
        }
        fixed_owned_dir_is_safe() {
            [[ "$1" != "$CONF_DIR" || "$boundary_mode" == 3771 ]]
        }
        prepare_intercept_runtime_dirs() { :; }
        runtime_file_slot_is_safe() { :; }
        runtime_tree_has_only_plain_entries() { :; }
        claim_fixed_owned_dir() { :; }
        ensure_dns_cert_root() { :; }
        chown() { :; }
        chmod() { :; }
        find() { :; }
        prepare_certificate_publication_boundaries \
            && [[ "$boundary_mode" == 3771 ]]
    ); then
        certificate_boundary_modes_ok=0
    fi
done
prep_boundary_line="$(grep -n '^[[:space:]]*prepare_certificate_publication_boundaries$' "$INSTALL" | tail -1 | cut -d: -f1)"
install_files_line="$(grep -n '^[[:space:]]*install_files$' "$INSTALL" | tail -1 | cut -d: -f1)"
intercept_cert_line="$(grep -n '^[[:space:]]*ensure_intercept_certificates$' "$INSTALL" | tail -1 | cut -d: -f1)"
if [[ "$certificate_boundary_modes_ok" == 1 \
   && -n "$prep_boundary_line" && -n "$install_files_line" && -n "$intercept_cert_line" \
   && "$prep_boundary_line" -lt "$install_files_line" \
   && "$prep_boundary_line" -lt "$intercept_cert_line" ]]; then
    pass "fresh 0755 and legacy 2771 config roots seal before certificate helpers"
else
    fail "certificate publication can run before the sticky config boundary"
fi

runtime_slots="$TMP/runtime-slots"
mkdir -p "$runtime_slots/root" "$runtime_slots/outside"
ln -s "$runtime_slots/outside" "$runtime_slots/root/rules"
if runtime_directory_slot_is_safe "$runtime_slots/root/rules/cache" "$runtime_slots/root"; then
    fail "runtime directory validation accepted an escaping symlink component"
else
    pass "runtime directory validation rejects symlink components before install -d"
fi
rm -f -- "$runtime_slots/root/rules"
mkdir -p "$runtime_slots/root/rules"
printf 'safe\n' > "$runtime_slots/root/policy.json"
ln -s "$runtime_slots/outside/file" "$runtime_slots/root/tgbot.json"
if runtime_file_slot_is_safe "$runtime_slots/root/policy.json" "$runtime_slots/root" \
   && ! runtime_file_slot_is_safe "$runtime_slots/root/tgbot.json" "$runtime_slots/root"; then
    pass "direct runtime files must be regular and non-symlinked"
else
    fail "direct runtime file validation did not distinguish regular files and symlinks"
fi

tls_tree="$TMP/tls-tree"
mkdir -p "$tls_tree"
printf 'cert\n' > "$tls_tree/fullchain.pem"
printf 'key\n' > "$tls_tree/privkey.pem"
if runtime_tree_has_only_plain_entries "$tls_tree"; then
    pass "ordinary interception TLS trees are accepted"
else
    fail "ordinary interception TLS tree was rejected"
fi
ln -s "$runtime_slots/outside/file" "$tls_tree/escaped.pem"
if runtime_tree_has_only_plain_entries "$tls_tree"; then
    fail "interception TLS tree accepted a planted symlink"
else
    pass "interception TLS tree rejects planted symlinks before recursive chown"
fi
rm -f -- "$tls_tree/escaped.pem"
if mkfifo "$tls_tree/special"; then
    if runtime_tree_has_only_plain_entries "$tls_tree"; then
        fail "interception TLS tree accepted a special file"
    else
        pass "interception TLS tree rejects special files before recursive chown"
    fi
    rm -f -- "$tls_tree/special"
fi

if (
    DNS_CERT_DIR="$TMP/cert-roles"
    DNS_SERVICE_USER=gpn-dns
    role="$DNS_CERT_DIR/dot"
    generation="$role/generations/generation-20260721T010203Z-10-20"
    mkdir -p "$generation"
    printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:dot" > "$role/$CERT_ROLE_MARKER"
    printf 'cert\n' > "$generation/fullchain.pem"
    printf 'key\n' > "$generation/privkey.pem"
    ln -s "generations/$(basename -- "$generation")" "$role/current"
    account_gid() { printf '4242\n'; }
    file_uid() { printf '0\n'; }
    file_gid() {
        case "$1" in "$role/$CERT_ROLE_MARKER"|"$role/current") printf '0\n' ;; *) printf '4242\n' ;; esac
    }
    file_mode() {
        case "$1" in
            "$role"|"$role/generations"|"$generation") printf '750\n' ;;
            "$role/$CERT_ROLE_MARKER") printf '644\n' ;;
            *) printf '640\n' ;;
        esac
    }
    file_nlink() { printf '1\n'; }
    cert_role_tree_is_safe_for_recursive_metadata "$role" || exit 1
    rm -f -- "$role/current"
    ln -s ../../outside "$role/current"
    ! cert_role_tree_is_safe_for_recursive_metadata "$role"
); then
    pass "certificate role permits only its bounded generation pointer"
else
    fail "certificate role tree validation missed a valid or escaping current pointer"
fi

if (
    CONF_DIR="$TMP/cert-migration-conf"
    DNS_CERT_DIR="$CONF_DIR/cert"
    DNS_SERVICE_USER=gpn-dns
    role="$DNS_CERT_DIR/dot"
    generation="$role/generations/generation-20260721T020304Z-30-40"
    mkdir -p "$generation"
    printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
    printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:dot" > "$role/$CERT_ROLE_MARKER"
    printf 'cert\n' > "$generation/fullchain.pem"
    printf 'key\n' > "$generation/privkey.pem"
    command ln -s "generations/$(basename -- "$generation")" "$role/current"
    role_marker_normalized=0
    current_normalized=0
    root_marker_written=0
    account_gid() { printf '4242\n'; }
    file_uid() { printf '0\n'; }
    file_gid() {
        case "$1" in
            "$CONF_DIR"|"$CONF_DIR/$CONF_OWNERSHIP_MARKER"|"$DNS_CERT_DIR"|"$DNS_CERT_DIR/$CERT_ROOT_MARKER")
                printf '0\n' ;;
            "$role/$CERT_ROLE_MARKER")
                [[ "$role_marker_normalized" == 1 ]] && printf '0\n' || printf '4242\n' ;;
            "$role/current")
                [[ "$current_normalized" == 1 ]] && printf '0\n' || printf '4242\n' ;;
            *) printf '4242\n' ;;
        esac
    }
    file_mode() {
        case "$1" in
            "$CONF_DIR") printf '755\n' ;;
            "$CONF_DIR/$CONF_OWNERSHIP_MARKER"|"$DNS_CERT_DIR/$CERT_ROOT_MARKER") printf '644\n' ;;
            "$DNS_CERT_DIR") printf '751\n' ;;
            "$role"|"$role/generations"|"$generation") printf '750\n' ;;
            "$role/$CERT_ROLE_MARKER")
                [[ "$role_marker_normalized" == 1 ]] && printf '644\n' || printf '640\n' ;;
            *) printf '640\n' ;;
        esac
    }
    file_nlink() { printf '1\n'; }
    write_ownership_marker() {
        local dir="$1" name="$2" value="$3"
        printf '%s\n' "$value" > "$dir/$name" || return 1
        case "$name" in
            "$CERT_ROLE_MARKER") role_marker_normalized=1 ;;
            "$CERT_ROOT_MARKER") root_marker_written=1 ;;
        esac
    }
    ln() {
        command ln "$@" || return 1
        [[ "$*" != *'.current.normalize.'* ]] || current_normalized=1
    }
    legacy_cert_role_tree_is_migratable "$role" \
        && ensure_dns_cert_root \
        && cert_root_is_safe \
        && [[ "$role_marker_normalized" == 1 \
           && "$current_normalized" == 1 \
           && "$root_marker_written" == 1 ]]
); then
    pass "legacy 0751 certificate trees normalize safely before root-marker claim"
else
    fail "legacy certificate tree could not be normalized to the current boundary"
fi

debug_root="$TMP/debug-cert-root"
mkdir -p "$debug_root"
ln -s "$runtime_slots/outside" "$debug_root/example.com"
if (
    DEBUG_CERT_DIR="$debug_root"
    ! debug_cert_lineage_slot_is_safe "$debug_root/example.com"
); then
    pass "debug certificate lineage rejects symlinked base directories"
else
    fail "debug certificate lineage accepted a symlinked base directory"
fi
rm -f -- "$debug_root/example.com"

if (
    CONF_DIR="$TMP/debug-conf"
    DEBUG_CERT_DIR="$CONF_DIR/debug-cert"
    mkdir -p "$DEBUG_CERT_DIR"
    fixed_owned_dir_is_safe() { :; }
    runtime_directory_slot_is_safe() { :; }
    file_uid() { [[ "$1" == "$DEBUG_CERT_DIR" ]] && printf '1001\n' || printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { printf '700\n'; }
    ! ensure_debug_cert_root >/dev/null 2>&1 \
        && [[ ! -e "$DEBUG_CERT_DIR/$DEBUG_CERT_MARKER" ]]
); then
    pass "debug root ownership is validated before writing its marker"
else
    fail "debug root marker was written into an untrusted directory"
fi

# Static publication must override restrictive source modes before the atomic
# swap. The console, zashboard, and iOS profile are all served by the
# unprivileged gpn-dns account, while their source trees can originate from
# mktemp or a caller running with umask 077.
static_root="$TMP/static-publication"
if (
    umask 077
    src="$static_root/source"
    dest="$static_root/live"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        case "$1" in
            "$src"|"$src"/*|"$dest"|"$dest"/*|"$static_root"/.live.new.*)
                if [[ "$POSIX_MODES" == 0 ]]; then
                    [[ -d "$1" ]] && printf '755\n' || printf '644\n'
                else
                    stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true
                fi ;;
            *) printf '755\n' ;;
        esac
    }
    normalize_static_tree_ownership() { :; }
    mkdir -p "$src/assets"
    printf 'index\n' > "$src/index.html"
    printf 'asset\n' > "$src/assets/app.js"
    chmod 0700 "$src" "$src/assets"
    chmod 0600 "$src/index.html" "$src/assets/app.js"
    publish_owned_tree "$src" "$dest" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"
    [[ "$(file_mode "$dest")" == 755 ]]
    [[ "$(file_mode "$dest/assets")" == 755 ]]
    [[ "$(file_mode "$dest/index.html")" == 644 ]]
    [[ "$(file_mode "$dest/assets/app.js")" == 644 ]]
    [[ "$(file_mode "$dest/$WEB_OWNERSHIP_MARKER")" == 644 ]]
    grep -qxF index "$dest/index.html"
    grep -qxF asset "$dest/assets/app.js"
); then
    pass "static publication normalizes restrictive source modes for gpn-dns"
else
    fail "static publication retained modes that block the gpn-dns service"
fi

if (
    custom_parent="$TMP/custom-static-writable"
    mkdir -p "$custom_parent"
    file_uid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$custom_parent" ]] && printf '777\n' || printf '755\n'
    }
    ! static_publish_parent_is_safe "$custom_parent/web"
); then
    pass "custom static publication rejects a group/world-writable parent"
else
    fail "custom static publication accepted a writable parent"
fi

if (
    custom_parent="$TMP/custom-static-marker"
    DNS_WEB_DIR="$custom_parent/web"
    mkdir -p "$DNS_WEB_DIR"
    printf '%s\n' "$WEB_OWNERSHIP_VALUE" > "$DNS_WEB_DIR/$WEB_OWNERSHIP_MARKER"
    file_uid() {
        [[ "$1" == "$DNS_WEB_DIR/$WEB_OWNERSHIP_MARKER" ]] \
            && printf '1001\n' || printf '0\n'
    }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$DNS_WEB_DIR/$WEB_OWNERSHIP_MARKER" ]] \
            && printf '644\n' || printf '755\n'
    }
    ! claim_web_dir >/dev/null 2>&1
); then
    pass "custom static ownership markers must be root-published"
else
    fail "custom static tree accepted a non-root ownership marker"
fi

if (
    custom_parent="$TMP/custom-static-empty-owner"
    DNS_WEB_DIR="$custom_parent/web"
    mkdir -p "$DNS_WEB_DIR"
    file_uid() {
        [[ "$1" == "$DNS_WEB_DIR" ]] && printf '1001\n' || printf '0\n'
    }
    file_gid() { printf '0\n'; }
    file_mode() { printf '755\n'; }
    ! claim_web_dir >/dev/null 2>&1 \
        && [[ ! -e "$DNS_WEB_DIR/$WEB_OWNERSHIP_MARKER" ]]
); then
    pass "empty custom asset roots are trusted before marker publication"
else
    fail "public-tree marker was written into an untrusted empty directory"
fi

if (
    race_root="$TMP/custom-static-race"
    src="$race_root/source"
    dest="$race_root/live"
    mkdir -p "$src" "$dest"
    printf 'new\n' > "$src/index.html"
    printf 'old\n' > "$dest/index.html"
    ensure_static_publish_parent() { :; }
    static_publish_parent_is_safe() { return 1; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { [[ -d "$1" ]] && printf '755\n' || printf '644\n'; }
    normalize_static_tree_ownership() { :; }
    ! publish_owned_tree "$src" "$dest" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" >/dev/null 2>&1 \
        && grep -qxF old "$dest/index.html"
); then
    pass "static publication revalidates its trusted parent before the swap"
else
    fail "static publication swapped after its parent boundary changed"
fi

# Uninstall keeps Gum while deleting the rest of an owned runtime, and falls
# back to plain output before deleting a runtime where Gum is already absent.
if (
    BASE_DIR="$TMP/runtime-with-gum"
    BIN_DIR="$BASE_DIR/bin"
    GUM_BIN="$BIN_DIR/gum"
    _HAVE_GUM=0
    mkdir -p "$BIN_DIR" "$BASE_DIR/scripts"
    printf '%s\n' "$BASE_OWNERSHIP_VALUE" > "$BASE_DIR/$BASE_OWNERSHIP_MARKER"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] && printf '644\n' || printf '755\n'
    }
    printf '#!/bin/sh\nexit 0\n' > "$GUM_BIN"
    chmod 0755 "$GUM_BIN"
    printf 'runtime\n' > "$BIN_DIR/5gpn-dns"
    printf 'runtime\n' > "$BASE_DIR/scripts/helper"
    remove_runtime_preserving_gum >/dev/null
    [[ -x "$GUM_BIN" && ! -e "$BIN_DIR/5gpn-dns" && ! -e "$BASE_DIR/scripts" ]]
); then
    pass "uninstall preserves Gum and removes the remaining runtime"
else
    fail "uninstall did not preserve Gum cleanly"
fi
if (
    BASE_DIR="$TMP/runtime-without-gum"
    BIN_DIR="$BASE_DIR/bin"
    GUM_BIN="$BIN_DIR/gum"
    _HAVE_GUM=1
    mkdir -p "$BIN_DIR"
    printf '%s\n' "$BASE_OWNERSHIP_VALUE" > "$BASE_DIR/$BASE_OWNERSHIP_MARKER"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$BASE_DIR/$BASE_OWNERSHIP_MARKER" ]] && printf '644\n' || printf '755\n'
    }
    remove_runtime_preserving_gum >/dev/null
    [[ ! -e "$BASE_DIR" && "$_HAVE_GUM" == 0 ]]
); then
    pass "uninstall disables Gum output before removing an absent-Gum runtime"
else
    fail "uninstall retained a stale Gum output state"
fi

# Fake a host with one assigned non-loopback IPv4 and a matching default route.
ip() {
    case "$*" in
        '-o -4 addr show')
            echo '2: eth0    inet 10.20.30.40/24 brd 10.20.30.255 scope global eth0' ;;
        'route get 1.1.1.1')
            echo '1.1.1.1 via 10.20.30.1 dev eth0 src 10.20.30.40 uid 0' ;;
        *) return 1 ;;
    esac
}

PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
got="$(resolve_mihomo_listen_ips '')" || got=""
[[ "$got" == 10.20.30.40 ]] && pass "listener defaults keep only locally assigned addresses" \
    || fail "listener default = '$got', want 10.20.30.40"
got="$(resolve_mihomo_listen_ips '10.20.30.40,10.20.30.40')" || got=""
[[ "$got" == 10.20.30.40 ]] && pass "listener addresses are deduplicated" \
    || fail "listener dedupe = '$got'"

# Fresh-install automatic values are a complete valid configuration: the
# operational upstream groups and ECS subnet are accepted, and cache size is the
# memory-profile default selected before the TUI runs.
BASE_DOMAIN=example.com
MIHOMO_LISTEN_IPS=10.20.30.40
CERT_MODE=debug
CERT_EMAIL=""
CACHE_SIZE=20000
CHINA_ECS="112.96.32.0/24"
if validate_install_config >/dev/null 2>&1; then
    pass "automatic upstream, ECS, and cache defaults validate"
else
    fail "fresh-install automatic defaults were rejected"
fi
if resolve_mihomo_listen_ips '203.0.113.7' >/dev/null 2>&1; then
    fail "non-local listener address was accepted"
else
    pass "non-local listener address is rejected"
fi
if resolve_mihomo_listen_ips '127.0.0.1' >/dev/null 2>&1; then
    fail "panel loopback listener address was accepted"
else
    pass "panel loopback listener address is rejected"
fi
listeners="$(render_mihomo_listeners '10.20.30.40,10.20.30.41' 'console.example.com')"
[[ "$(grep -Fc 'port: 443,' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'port: 80,' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'port: 8080,' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'port: 8443,' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'port: 5060,' <<<"$listeners")" == 2 ]] \
    && pass "two bind IPs render independent :80/:443/:5060/:8080/:8443 listener sets" \
    || fail "dynamic listener renderer did not emit five listeners per bind IP"
[[ "$listeners" == *'name: gateway,'* && "$listeners" == *'name: gateway-2,'* \
   && "$listeners" == *'name: gateway80,'* && "$listeners" == *'name: gateway80-2,'* \
   && "$listeners" == *'name: gateway8080,'* && "$listeners" == *'name: gateway8080-2,'* \
   && "$listeners" == *'name: gateway8443,'* && "$listeners" == *'name: gateway8443-2,'* \
   && "$listeners" == *'name: gateway5060,'* && "$listeners" == *'name: gateway5060-2,'* ]] \
    && pass "listener names use the current gateway vocabulary" \
    || fail "dynamic listener names do not cover all seeded gateway ports"
[[ "$(grep -Fc 'target: console.example.com:443}' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'target: console.example.com:80}' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'target: console.example.com:8080}' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'target: console.example.com:8443}' <<<"$listeners")" == 2 \
   && "$(grep -Fc 'target: console.example.com:5060}' <<<"$listeners")" == 2 ]] \
    && pass "all listener sets use same-port console hostname fallback targets" \
    || fail "dynamic listeners did not use the console hostname target"

# Persist the seed inputs needed by the installed management script. Rendering
# below deliberately switches SCRIPT_DIR to this simulated runtime tree so the
# test covers `5gpn mihomo-reset`, not only execution from a source checkout.
source_script_dir="$SCRIPT_DIR"
source_base_dir="$BASE_DIR"
runtime_root="$TMP/runtime-assets"
BASE_DIR="$runtime_root"
if install_mihomo_runtime_assets >/dev/null \
   && cmp -s "$source_script_dir/etc/mihomo/config.yaml.tmpl" \
        "$runtime_root/etc/mihomo/config.yaml.tmpl" \
   && cmp -s "$source_script_dir/etc/mihomo/whitelist.seed.txt" \
        "$runtime_root/etc/mihomo/whitelist.seed.txt"; then
pass "installed management runtime retains all mihomo reset assets"

render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
render_line="$(grep -nF 'done < "$template" > "$candidate"' <<<"$render_fn" | cut -d: -f1)"
nonempty_line="$(grep -nF '[[ -s "$candidate" ]]' <<<"$render_fn" | cut -d: -f1)"
secure_line="$(grep -nF 'chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$candidate"' <<<"$render_fn" | cut -d: -f1)"
validate_line="$(grep -nF '"$MIHOMO_BIN" -t -f "$candidate"' <<<"$render_fn" | cut -d: -f1)"
if grep -Fq 'template="${BASE_DIR}/etc/mihomo/config.yaml.tmpl"' <<<"$render_fn" \
   && [[ -n "$render_line" && -n "$nonempty_line" && -n "$secure_line" && -n "$validate_line" \
      && "$render_line" -lt "$nonempty_line" && "$nonempty_line" -lt "$secure_line" \
      && "$secure_line" -lt "$validate_line" ]]; then
    pass "mihomo seed renders from the installed snapshot before ownership and validation"
else
    fail "mihomo seed can be validated empty or written after service ownership transfer"
fi
else
    fail "installed management runtime is missing mihomo reset assets"
fi
# Installed management resolves immutable seed assets from BASE_DIR.
BASE_DIR="$runtime_root"
SCRIPT_DIR="$runtime_root"

# Seed -> preserve byte-for-byte -> explicit validated reset with backup.
CONF_DIR="$TMP/conf"
MIHOMO_DIR="$CONF_DIR/mihomo"
MIHOMO_SERVICE_USER="$(id -gn)"
DNS_SERVICE_USER="$(id -un)"
MIHOMO_BIN="$TMP/fake-mihomo"
DNS_BIN="$TMP/fake-dns"
INTERCEPT_BIN="$TMP/fake-intercept"
INTERCEPT_DIR="$CONF_DIR/intercept"
MIHOMO_TEST_LOG="$TMP/mihomo.log"; export MIHOMO_TEST_LOG
cat > "$MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIHOMO_TEST_LOG"
exit 0
EOF
chmod +x "$MIHOMO_BIN"
cat > "$DNS_BIN" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --print-mihomo-secret && "${2:-}" == --config && -f "${3:-}" ]]; then
    sed -n 's/^secret:[[:space:]]*//p' "$3"
    exit 0
fi
exit 1
EOF
chmod +x "$DNS_BIN"
mkdir -p "$INTERCEPT_DIR"
cat > "$INTERCEPT_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'test-inbound-user\ttest-inbound-password-123456\ttest-upstream-user\ttest-upstream-password-123456\n'
EOF
chmod +x "$INTERCEPT_BIN"
mkdir -p "$CONF_DIR"
printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
file_uid() {
    case "$1" in
        "$CONF_DIR"|"$CONF_DIR/$CONF_OWNERSHIP_MARKER"|"$CONF_DIR/dns.env") printf '0\n' ;;
        *) stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true ;;
    esac
}
file_gid() {
    case "$1" in
        "$CONF_DIR"|"$CONF_DIR/$CONF_OWNERSHIP_MARKER") printf '0\n' ;;
        *) stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true ;;
    esac
}
file_mode() {
    case "$1" in
        "$CONF_DIR") printf '755\n' ;;
        "$CONF_DIR/$CONF_OWNERSHIP_MARKER") printf '644\n' ;;
        "$CONF_DIR/dns.env") printf '640\n' ;;
        *) stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true ;;
    esac
}
persist_mihomo_secret() { :; }
BASE_DOMAIN=example.com
MIHOMO_LISTEN_IPS=10.20.30.40
render_mihomo_config >/dev/null
config="$MIHOMO_DIR/config.yaml"
[[ "$MIHOMO_SEED_PORTS_REQUIRED" == 1 ]] \
    && pass "first-install seed requires alternate-port readiness" \
    || fail "first-install seed did not enable alternate-port readiness"
config_mode="$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")"
[[ -s "$config" && ( "$POSIX_MODES" == 0 || "$config_mode" == 640 ) ]] \
    && pass "first install seeds a private mihomo config" \
    || fail "first-install mihomo config missing or not mode 0640"
grep -Fq 'console.example.com: 127.0.0.1' "$config" \
    && grep -Fq 'DOMAIN,console.example.com,DIRECT' "$config" \
    && grep -Fq 'name: gateway5060' "$config" \
    && grep -Fq 'QUIC: { ports: [443, 5060] }' "$config" \
    && pass "seed contains public console mapping" \
    || fail "seed lacks public console mapping or default :5060 ingress"
printf '%s\n' '# operator edit must survive' >> "$config"
before="$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')"
render_mihomo_config >/dev/null
after="$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')"
[[ "$MIHOMO_SEED_PORTS_REQUIRED" == 0 ]] \
    && pass "preserved operator config keeps alternate-port readiness optional" \
    || fail "preserved operator config incorrectly requires seed-only ports"
[[ "$before" == "$after" ]] && pass "normal render validates and preserves operator config bytes" \
    || fail "normal render overwrote operator config"
render_mihomo_config --reset >/dev/null
[[ "$MIHOMO_SEED_PORTS_REQUIRED" == 1 ]] \
    && pass "explicit reset requires alternate-port readiness" \
    || fail "explicit reset did not enable alternate-port readiness"
if grep -Fq '# operator edit must survive' "$config"; then
    fail "explicit reset did not replace operator config"
elif compgen -G "$config.bak.*" >/dev/null; then
    pass "explicit reset replaces only after retaining a backup"
else
    fail "explicit reset did not retain a backup"
fi
grep -q '\.config\.yaml\.' "$MIHOMO_TEST_LOG" \
    && pass "mihomo validates a staged candidate before publication" \
    || fail "mihomo never validated a staged config candidate"
printf '%s\n' '# backup failure must preserve this' >> "$config"
if (
    cp() { return 1; }
    render_mihomo_config --reset
) >/dev/null 2>&1; then
    fail "explicit reset succeeded after backup failure"
elif ! grep -Fq '# backup failure must preserve this' "$config"; then
    fail "explicit reset changed the live config after backup failure"
elif compgen -G "$MIHOMO_DIR/.config.yaml.*" >/dev/null; then
    fail "explicit reset left a candidate behind after backup failure"
else
    pass "backup failure leaves the live mihomo config unchanged"
fi

before="$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')"
BASE_DIR="$TMP/runtime-without-mihomo-template"
mkdir -p "$BASE_DIR/etc/mihomo"
if missing_template_output="$(render_mihomo_config --reset 2>&1)"; then
    fail "explicit reset succeeded without its installed mihomo template"
elif [[ "$before" != "$(sha256sum "$config" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$config" | awk '{print $1}')" ]]; then
    fail "missing mihomo template changed the live operator config"
elif compgen -G "$MIHOMO_DIR/.config.yaml.*" >/dev/null; then
    fail "missing mihomo template left an empty candidate behind"
elif [[ "$missing_template_output" != *"mihomo seed template is missing, unreadable, or empty"* ]]; then
    fail "missing mihomo template did not produce a clear installer error"
else
    pass "missing installed template fails before candidate creation and preserves live config"
fi
SCRIPT_DIR="$source_script_dir"
BASE_DIR="$source_base_dir"

# dns.env accepts exactly the current key set and rejects ambiguous state.
saved_dns_env="$(cat "$CONF_DIR/dns.env" 2>/dev/null || true)"
printf '%s\n' \
    'DNS_BASE_DOMAIN=example.com' \
    'DNS_PUBLIC_IP=198.51.100.9' > "$CONF_DIR/dns.env"
validate_dns_env_schema >/dev/null 2>&1 \
    && pass "current dns.env keys pass strict schema validation" \
    || fail "current dns.env keys were rejected"
printf '%s\n' 'DNS_DOMAIN=dot.example.com' > "$CONF_DIR/dns.env"
if validate_dns_env_schema >/dev/null 2>&1; then
    fail "retired dns.env key was accepted"
else
    pass "retired dns.env key is rejected"
fi
printf '%s\n' \
    'DNS_BASE_DOMAIN=example.com' \
    'DNS_BASE_DOMAIN=other.example.com' > "$CONF_DIR/dns.env"
if validate_dns_env_schema >/dev/null 2>&1; then
    fail "duplicate dns.env key was accepted"
else
    pass "duplicate dns.env key is rejected"
fi
printf '%s\n' "$saved_dns_env" > "$CONF_DIR/dns.env"
if set_dns_env_kv "$CONF_DIR/dns.env" DNS_DOMAIN dot.example.com >/dev/null 2>&1; then
    fail "dns.env writer accepted a retired key"
else
    pass "dns.env writer enforces the current-key whitelist"
fi
whitelist_keys="$(for key in $DNS_ENV_KEYS; do printf '%s\n' "$key"; done | sort)"
rendered_keys="$(sed -n '/^write_dns_env()/,/^}/p' "$INSTALL" \
    | sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' | sort)"
example_keys="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' \
    "$ROOT/etc/5gpn-dns/dns.env.example" | sort)"
[[ "$whitelist_keys" == "$rendered_keys" && "$whitelist_keys" == "$example_keys" ]] \
    && pass "dns.env writer, example, and current-key whitelist match exactly" \
    || fail "dns.env writer/example keys drifted from the current-key whitelist"

# Only current, unprefixed commands are accepted, and their arity is enforced
# before an operation can run.
if (
    attach_tty() { :; }
    clear_external_config_env() { :; }
    main --status
) >/dev/null 2>&1; then
    fail "flag-style command alias was accepted"
else
    pass "flag-style command alias is rejected"
fi
command_ran="$TMP/command-ran"
if (
    attach_tty() { :; }
    clear_external_config_env() { :; }
    show_status() { : > "$command_ran"; }
    main status extra
) >/dev/null 2>&1 || [[ -e "$command_ran" ]]; then
    fail "unsupported status arguments reached the operation"
else
    pass "command arity is enforced before dispatch"
fi

# Allowlist mutations accept only canonical IPv4/IP-CIDR entries, are exact,
# and refuse symlink targets.
allow_conf="$TMP/allow-conf"
allow_dir="$allow_conf/mihomo"
mkdir -p "$allow_conf"
printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$allow_conf/$CONF_OWNERSHIP_MARKER"
if (
    CONF_DIR="$allow_conf"
    MIHOMO_DIR="$allow_dir"
    check_root() { :; }
    install_gum() { :; }
    apply_whitelist() { :; }
    ! add_allow_ip '203.0.113.1/33' >/dev/null 2>&1 || exit 1
    [[ ! -e "$MIHOMO_DIR/whitelist.txt" ]] || exit 1
    add_allow_ip '203.0.113.1/32' >/dev/null || exit 1
    add_allow_ip '203.0.113.10/32' >/dev/null || exit 1
    add_allow_ip '203.0.113.1/32' >/dev/null || exit 1
    add_allow_ip '203.0.113.20' >/dev/null || exit 1
    [[ "$(grep -c '^203\.0\.113\.1/32$' "$MIHOMO_DIR/whitelist.txt")" == 1 ]] || exit 1
    grep -qxF '203.0.113.20/32' "$MIHOMO_DIR/whitelist.txt" || exit 1
    del_allow_ip '203.0.113.1/32' >/dev/null || exit 1
    del_allow_ip '203.0.113.20' >/dev/null || exit 1
    ! grep -qxF '203.0.113.1/32' "$MIHOMO_DIR/whitelist.txt" || exit 1
    ! grep -qxF '203.0.113.20/32' "$MIHOMO_DIR/whitelist.txt" || exit 1
    grep -qxF '203.0.113.10/32' "$MIHOMO_DIR/whitelist.txt" || exit 1
); then
    pass "allowlist updates validate, deduplicate, and delete exact CIDRs"
else
    fail "allowlist update boundaries are not enforced"
fi
symlink_target="$TMP/allowlist-target"
printf '%s\n' sentinel > "$symlink_target"
rm -rf -- "$allow_dir"
mkdir -p "$allow_dir"
ln -s "$symlink_target" "$allow_dir/whitelist.txt"
if (
    CONF_DIR="$allow_conf"
    MIHOMO_DIR="$allow_dir"
    check_root() { :; }
    install_gum() { :; }
    apply_whitelist() { :; }
    add_allow_ip '203.0.113.1/32'
) >/dev/null 2>&1; then
    fail "allowlist writer followed a symlink"
elif [[ "$(cat "$symlink_target")" == sentinel ]]; then
    pass "allowlist writer refuses symlink targets"
else
    fail "allowlist writer modified a symlink target"
fi

# Reset must stop at the first failed boundary even when main dispatch invokes
# it through an && list (which suppresses Bash errexit inside called functions).
reset_ran="$TMP/reset-ran"
if (
    check_root() { :; }
    install_gum() { :; }
    load_mihomo_reset_context() { return 1; }
    render_mihomo_config() { : > "$reset_ran"; }
    restart_services() { : > "$reset_ran"; }
    reset_mihomo_config
) >/dev/null 2>&1; then
    fail "mihomo reset succeeded without a valid current dns.env"
elif [[ -e "$reset_ran" ]]; then
    fail "mihomo reset continued after context validation failed"
else
    pass "mihomo reset stops before rendering when current config is invalid"
fi
restart_ran="$TMP/restart-ran"
if (
    check_root() { :; }
    install_gum() { :; }
    load_mihomo_reset_context() { :; }
    render_mihomo_config() { return 1; }
    restart_services() { : > "$restart_ran"; }
    reset_mihomo_config
) >/dev/null 2>&1; then
    fail "mihomo reset succeeded after candidate publication failed"
elif [[ -e "$restart_ran" ]]; then
    fail "mihomo reset restarted services after candidate publication failed"
else
    pass "mihomo reset does not restart after candidate publication failure"
fi

# External zashboard directories need a marker before recursive cleanup. The
# GitHub checkout lives below /home, which safe_zashboard_path intentionally
# rejects, so isolate ownership lifecycle behavior from path-policy behavior.
BASE_DIR="$TMP/base"
if (
    safe_zashboard_path() { printf '%s\n' "$DNS_ZASH_DIR"; }
    DNS_ZASH_DIR="$TMP/external/zash"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$DNS_ZASH_DIR/$ZASH_OWNERSHIP_MARKER" ]] \
            && printf '644\n' || printf '755\n'
    }
    mkdir -p "$DNS_ZASH_DIR"
    echo foreign > "$DNS_ZASH_DIR/file"
    ! claim_zashboard_dir >/dev/null 2>&1
    rm -f "$DNS_ZASH_DIR/file"
    claim_zashboard_dir >/dev/null
    echo owned > "$DNS_ZASH_DIR/file"
    clear_zashboard_dir >/dev/null
    [[ -f "$DNS_ZASH_DIR/$ZASH_OWNERSHIP_MARKER" && ! -e "$DNS_ZASH_DIR/file" ]]
    remove_zashboard_dir >/dev/null
    [[ ! -e "$DNS_ZASH_DIR" ]]
); then
    pass "zashboard ownership marker gates cleanup and removal"
else
    fail "zashboard ownership lifecycle check failed"
fi
DNS_ZASH_DIR=/
if safe_zashboard_path >/dev/null 2>&1; then
    fail "filesystem root accepted as DNS_ZASH_DIR"
else
    pass "system root is rejected as DNS_ZASH_DIR"
fi
DNS_ZASH_DIR=/etc/5gpn-unowned-panel
if safe_zashboard_path >/dev/null 2>&1; then
    fail "system-directory descendant accepted as DNS_ZASH_DIR"
else
    pass "system-directory descendants are rejected as panel cleanup paths"
fi

# Service activation errors must propagate instead of falling through to the
# final "install complete" card.
systemctl() {
    case "$1" in
        daemon-reload|enable|is-active) return 0 ;;
        restart|start) return 1 ;;
    esac
    return 1
}
MIHOMO_LISTEN_IPS=10.20.30.40
if start_services >/dev/null 2>&1; then
    fail "start_services returned success after both service starts failed"
else
    pass "service start failure propagates as a non-zero installer result"
fi

# A disabled MITM service is a successful steady state. systemd reports a
# skipped ExecCondition as a non-zero start, so start_services must inspect the
# persisted master setting before attempting restart/start.
if (
    calls="$TMP/disabled-mitm-systemctl.log"
    check_bin="$TMP/5gpn-intercept-check"
    cat > "$check_bin" <<'EOF'
#!/bin/sh
case " $* " in
    *' --check-enabled '*) exit 3 ;;
esac
exit 0
EOF
    chmod +x "$check_bin"
    INTERCEPT_BIN="$check_bin"
    INTERCEPT_DIR="$TMP/intercept-disabled"
    MIHOMO_LISTEN_IPS=10.20.30.40
    resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
    cfg_get() { return 0; }
    wait_service_ready() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$calls"
        return 0
    }
    start_services >/dev/null 2>&1
    grep -Fxq 'enable 5gpn-intercept' "$calls"
    grep -Fxq 'stop 5gpn-intercept.service' "$calls"
    ! grep -Eq '^(restart|start) 5gpn-intercept($|\.service)' "$calls"
); then
    pass "disabled MITM remains stopped without failing service activation"
else
    fail "disabled MITM was started or treated as an activation failure"
fi

# Public/certificate DNS is fail-closed and always uses the independent
# resolver instead of the host's possibly synthetic resolver.
CONSOLE_DOMAIN=console.example.com
PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
DIG_LOG="$TMP/dig.log"
DIG_A=198.51.100.9
DIG_AAAA=""
dig() {
    printf '%s\n' "$*" >> "$DIG_LOG"
    case " $* " in
        *' AAAA '*) [[ -n "$DIG_AAAA" ]] && echo "$DIG_AAAA" ;;
        *' A '*) [[ -n "$DIG_A" ]] && echo "$DIG_A" ;;
    esac
}
CERT_MODE=cloudflare
verify_console_dns >/dev/null \
    && pass "console A matching PUBLIC_IP passes bootstrap verification" \
    || fail "matching console A was rejected"
grep -q '@1.1.1.1' "$DIG_LOG" \
    && pass "console DNS bootstrap uses the fixed 1.1.1.1 resolver" \
    || fail "console DNS bootstrap did not query 1.1.1.1"
DIG_A=203.0.113.8
CERT_DNS_WAIT_TIMEOUT=0
if verify_console_dns >/dev/null 2>&1; then
    fail "mismatched console A passed bootstrap verification"
else
    pass "mismatched console A fails closed"
fi
DIG_A=198.51.100.9
derive_domains example.com
CERT_MODE=http-01
verify_console_dns >/dev/null \
    && pass "HTTP-01 verifies console/zash/dot A and empty AAAA through 1.1.1.1" \
    || fail "valid HTTP-01 service DNS was rejected"
for name in console.example.com zash.example.com dot.example.com; do
    grep -q " A ${name} @1.1.1.1" "$DIG_LOG" \
        || fail "HTTP-01 DNS gate did not query A for ${name} through 1.1.1.1"
    grep -q " AAAA ${name} @1.1.1.1" "$DIG_LOG" \
        || fail "HTTP-01 DNS gate did not query AAAA for ${name} through 1.1.1.1"
done
DIG_A=$'alias.example.net.\n198.51.100.9'
if verify_console_dns >/dev/null 2>&1; then
    fail "HTTP-01 accepted a CNAME indirection"
else
    pass "HTTP-01 requires a direct A record"
fi
DIG_A=$'198.51.100.9\n198.51.100.9'
if verify_console_dns >/dev/null 2>&1; then
    fail "HTTP-01 accepted multiple A answers"
else
    pass "HTTP-01 requires exactly one A answer"
fi
DIG_A=198.51.100.9
DIG_AAAA=2001:db8::9
if verify_console_dns >/dev/null 2>&1; then
    fail "HTTP-01 accepted an IPv6 record on the IPv4-only gateway"
else
    pass "HTTP-01 rejects published AAAA records"
fi
DIG_AAAA=""
CERT_MODE=debug
: > "$DIG_LOG"
verify_console_dns >/dev/null \
    && [[ ! -s "$DIG_LOG" ]] \
    && pass "debug mode skips public DNS checks" \
    || fail "debug mode unexpectedly required public DNS"
SKIP_CONSOLE_DNS_CHECK=1
CERT_MODE=cloudflare
DIG_A=203.0.113.8
if verify_console_dns >/dev/null 2>&1; then
    fail "caller environment bypassed the console DNS safety gate"
else
    pass "console DNS gate ignores caller environment bypasses"
fi
unset SKIP_CONSOLE_DNS_CHECK

# Initial HTTP-01 issuance releases :80 only when mihomo was active. Failure and
# signal paths restore it immediately; success leaves it stopped until role
# certificates are published and full_install reaches start_services.
PORT80_LOG="$TMP/http-port80.log"
HTTP_MIHOMO_ACTIVE=1
HTTP_CERTBOT_RC=1
HTTP_CERTBOT_SIGNAL=""
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$PORT80_LOG"
    case "$1" in
        is-active) [[ "$HTTP_MIHOMO_ACTIVE" == 1 ]] ;;
        stop|start) return 0 ;;
        *) return 0 ;;
    esac
}
certbot() {
    printf 'certbot %s\n' "$*" >> "$PORT80_LOG"
    if [[ -n "$HTTP_CERTBOT_SIGNAL" ]]; then
        kill "-$HTTP_CERTBOT_SIGNAL" "$BASHPID"
    fi
    return "$HTTP_CERTBOT_RC"
}
: > "$PORT80_LOG"
if run_http_certbot certonly --standalone >/dev/null 2>&1; then
    fail "HTTP-01 wrapper hid a Certbot failure"
elif grep -q '^systemctl stop mihomo.service$' "$PORT80_LOG" \
  && grep -q '^systemctl start mihomo.service$' "$PORT80_LOG"; then
    pass "HTTP-01 restores an originally active mihomo after Certbot failure"
else
    fail "HTTP-01 did not stop and restore active mihomo around Certbot"
fi
HTTP_CERTBOT_RC=0
: > "$PORT80_LOG"
run_http_certbot certonly --standalone >/dev/null 2>&1 \
    || fail "HTTP-01 wrapper failed after successful Certbot"
if grep -q '^systemctl stop mihomo.service$' "$PORT80_LOG" \
   && ! grep -q '^systemctl start mihomo.service$' "$PORT80_LOG"; then
    pass "successful HTTP-01 keeps active mihomo stopped for certificate publication"
else
    fail "successful HTTP-01 restored mihomo before certificate publication"
fi
for HTTP_CERTBOT_SIGNAL in INT TERM; do
    : > "$PORT80_LOG"
    if run_http_certbot certonly --standalone >/dev/null 2>&1; then
        fail "HTTP-01 wrapper hid a $HTTP_CERTBOT_SIGNAL signal"
    elif grep -q '^systemctl stop mihomo.service$' "$PORT80_LOG" \
      && grep -q '^systemctl start mihomo.service$' "$PORT80_LOG"; then
        pass "HTTP-01 restores an originally active mihomo after $HTTP_CERTBOT_SIGNAL"
    else
        fail "HTTP-01 $HTTP_CERTBOT_SIGNAL path did not restore active mihomo"
    fi
done
HTTP_CERTBOT_SIGNAL=""
HTTP_MIHOMO_ACTIVE=0
HTTP_CERTBOT_RC=0
: > "$PORT80_LOG"
run_http_certbot certonly --standalone >/dev/null 2>&1 \
    || fail "HTTP-01 wrapper failed with inactive mihomo and successful Certbot"
if grep -Eq '^systemctl (stop|start) mihomo.service$' "$PORT80_LOG"; then
    fail "HTTP-01 changed the state of an originally inactive mihomo"
else
    pass "HTTP-01 leaves an originally inactive mihomo stopped"
fi

# Exercise the real install_cert orchestration with deterministic stubs. This
# catches the original race: no service start may occur between successful
# Certbot completion and deploy_cert_roles, while the later start_services phase
# remains responsible for restoring the data plane.
HTTP_INSTALL_LOG="$TMP/http-install-order.log"
(
    CERT_MODE=http-01
    CERT_EMAIL=admin@example.com
    derive_domains example.com
    validation_calls=0
    certbot_lineage_owned_by_5gpn() { return 1; }
    certbot_lineage_artifacts_exist() { return 1; }
    cert_provenance_matches() { return 1; }
    validate_cert_pair() {
        validation_calls=$((validation_calls + 1))
        [[ "$validation_calls" -ge 1 ]]
    }
    certbot_renewal_mode_matches() { return 0; }
    check_http_challenge_dns_once() { return 0; }
    write_cert_provenance() { printf 'write_cert_provenance\n' >> "$HTTP_INSTALL_LOG"; }
    install_cert_deploy_hook() { printf 'install_cert_deploy_hook\n' >> "$HTTP_INSTALL_LOG"; }
    install_renewal_automation() { printf 'install_renewal_automation\n' >> "$HTTP_INSTALL_LOG"; }
    deploy_cert_roles() { printf 'deploy_cert_roles zash/current\n' >> "$HTTP_INSTALL_LOG"; }
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$HTTP_INSTALL_LOG"
        case "$*" in
            'cat certbot.timer'|'is-active --quiet certbot.service') return 1 ;;
        esac
        return 0
    }
    certbot() {
        printf 'certbot %s\n' "$*" >> "$HTTP_INSTALL_LOG"
        return 0
    }
    start_services() {
        printf 'start_services\n' >> "$HTTP_INSTALL_LOG"
        systemctl start mihomo.service
    }
    : > "$HTTP_INSTALL_LOG"
    install_cert example.com >/dev/null 2>&1 || exit 1
    start_services
) || fail "mocked successful HTTP-01 install flow failed"
http_certbot_line="$(grep -n '^certbot ' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
http_deploy_line="$(grep -n '^deploy_cert_roles zash/current$' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
http_start_line="$(grep -n '^systemctl start mihomo.service$' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
if [[ -n "$http_certbot_line" && -n "$http_deploy_line" && -n "$http_start_line" \
   && "$http_certbot_line" -lt "$http_deploy_line" \
   && "$http_deploy_line" -lt "$http_start_line" ]]; then
    pass "HTTP-01 publishes zash/current before start_services restores mihomo"
else
    fail "HTTP-01 service restoration raced ahead of zash/current publication"
fi

# Static gates for operations that are intentionally not executed in a unit
# test (root binary install, systemd, certificate issuance, network fallback).
if grep -Eq 'nft flush ruleset|systemctl disable --now nftables|> /etc/nftables.conf' "$INSTALL"; then
    fail "installer still globally flushes/disables/overwrites nftables"
else
    pass "installer contains no global nftables mutation"
fi
lock_fn="$(sed -n '/^acquire_install_cert_lock()/,/^}/p' "$INSTALL")"
lock_dir_fn="$(sed -n '/^ensure_private_lock_dir()/,/^}/p' "$INSTALL")"
if grep -Fq 'CERT_RENEW_LOCK_FILE="/run/5gpn/cert-renew.lock"' "$INSTALL" \
   && grep -Fq '! -L "$lock_dir"' <<<"$lock_dir_fn" \
   && grep -Fq 'file_uid "$lock_dir"' <<<"$lock_dir_fn" \
   && grep -Fq 'ensure_private_lock_dir' <<<"$lock_fn" \
   && ! grep -Fq '/run/lock/' "$INSTALL"; then
    pass "certificate lock uses a root-owned private non-symlink runtime directory"
else
    fail "certificate lock can clobber or follow files in a shared runtime directory"
fi

# An enabled MITM sidecar requires its certificate oneshot during service
# startup. The installer must release the shared certificate lock for that
# dependency and reacquire it before success or rollback processing.
handoff_log="$TMP/cert-lock-handoff.log"
if (
    INSTALL_CERT_LOCK_HELD=1
    release_install_cert_lock() { printf 'release\n' >> "$handoff_log"; INSTALL_CERT_LOCK_HELD=0; }
    start_services() { [[ "$INSTALL_CERT_LOCK_HELD" == 0 ]] || return 91; printf 'start\n' >> "$handoff_log"; }
    acquire_install_cert_lock() { printf 'acquire\n' >> "$handoff_log"; INSTALL_CERT_LOCK_HELD=1; }
    start_services_with_cert_lock_handoff
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 \
       && "$(tr '\n' ' ' < "$handoff_log")" == "release start acquire " ]]
); then
    pass "service start hands off and reacquires the certificate lock"
else
    fail "service start can deadlock its required certificate oneshot"
fi
if (
    : > "$handoff_log"
    INSTALL_CERT_LOCK_HELD=1
    release_install_cert_lock() { printf 'release\n' >> "$handoff_log"; INSTALL_CERT_LOCK_HELD=0; }
    start_services() { printf 'start-failed\n' >> "$handoff_log"; return 7; }
    acquire_install_cert_lock() { printf 'acquire\n' >> "$handoff_log"; INSTALL_CERT_LOCK_HELD=1; }
    start_services_with_cert_lock_handoff
    handoff_rc=$?
    [[ "$handoff_rc" == 7 && "$INSTALL_CERT_LOCK_HELD" == 1 \
       && "$(tr '\n' ' ' < "$handoff_log")" == "release start-failed acquire " ]]
); then
    pass "failed service start reacquires the certificate lock before rollback"
else
    fail "failed service start can enter rollback without the certificate lock"
fi
rollback_lock_fn="$(sed -n '/^ensure_install_cert_lock_for_rollback()/,/^}/p' "$INSTALL")"
exit_trap_fn="$(sed -n '/^install_transaction_exit()/,/^}/p' "$INSTALL")"
error_trap_fn="$(sed -n '/^install_transaction_error()/,/^}/p' "$INSTALL")"
finish_trap_fn="$(sed -n '/^finish_install_transaction()/,/^}/p' "$INSTALL")"
if grep -Fq 'acquire_install_cert_lock' <<<"$rollback_lock_fn" \
   && grep -Fq 'finish_install_transaction' <<<"$exit_trap_fn" \
   && grep -Fq 'finish_install_transaction' <<<"$error_trap_fn" \
   && grep -Fq 'ensure_install_cert_lock_for_rollback' <<<"$finish_trap_fn"; then
    pass "transaction traps reacquire the certificate lock before rollback"
else
    fail "a signal or error during service lock handoff can race rollback"
fi
debug_fn="$(sed -n '/^issue_selfsigned_wildcard()/,/^}/p' "$INSTALL")"
if grep -Fq '/etc/letsencrypt/live' <<<"$debug_fn"; then
    fail "debug certificate writer still targets a Certbot lineage"
elif grep -Fq 'DEBUG_CERT_DIR' <<<"$debug_fn"; then
    pass "debug certificate writer is isolated from Certbot lineages"
else
    fail "debug certificate writer does not use DEBUG_CERT_DIR"
fi
grep -Fq 'checksum is missing or invalid; refusing to install' "$INSTALL" \
    && pass "gum missing/invalid checksum fails closed to plain output" \
    || fail "gum checksum absence is not fail-closed"
if ! grep -Eq '^fetch_git\(\)|git -C .*fetch|git -C .*checkout|origin main' "$QUICK"; then
    pass "quick install has no unsigned branch or tag fallback"
else
    fail "quick install can fall forward to unsigned git content"
fi
grep -Fq '5gpn-quick-install-v1' "$QUICK" \
    && ! grep -Eq '^[[:space:]]*rm -rf "\$SRC"' "$QUICK" \
    && pass "quick-install cleanup is ownership-marker gated" \
    || fail "quick-install still deletes arbitrary SRC"
grep -Eq '^wait_service_ready\(\)' "$INSTALL" \
    && grep -Fq 'full_install must never print success' "$INSTALL" \
    && pass "install success is gated on service readiness" \
    || fail "service readiness gate is absent"

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "test_installer_safety: PASS"
else
    echo "test_installer_safety: FAIL"
    exit 1
fi
