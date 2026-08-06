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

if service_account_name_is_valid fivegpn \
   && ! service_account_name_is_valid 5gpn-dns \
   && ! service_account_name_is_valid 'five.gpn'; then
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
    pass "exact journal exporter instance conflicts are rejected before legacy cleanup"
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
if valid_stable_release_tag 9.8.7 \
   && ! valid_stable_release_tag 9.8.7-beta.1 \
   && ! valid_stable_release_tag 09.8.7 \
   && valid_beta_release_tag 9.8.8-beta.1 \
   && valid_beta_release_tag 9.8.8-beta.12 \
   && ! valid_beta_release_tag 9.8.8-beta.0 \
   && ! valid_beta_release_tag 9.8.8-beta.01; then
    pass "main installer enforces disjoint official and beta tag grammars"
else
    fail "main installer release tag grammar is not strict"
fi
if ! beta_base_is_newer_than_stable \
        9223372036854775808.0.0-beta.1 9223372036854775807.99.99 \
   || beta_base_is_newer_than_stable \
        9223372036854775807.0.0-beta.1 9223372036854775808.0.0; then
    fail "main installer beta comparison overflows large SemVer components"
else
    pass "main installer beta comparison is arbitrary-precision"
fi

# Source checkouts resolve the selected channel once, while release bundles
# remain pinned to the exact tag stamped by the release workflow.
latest_json="$TMP/latest-release.json"
printf '{"tag_name":"9.8.7"}\n' > "$latest_json"
RELEASE_TAG="latest"
RELEASE_CHANNEL="stable"
RELEASE_CHANNEL_EXPLICIT=0
resolved="$(resolve_install_release_tag "file://$latest_json" 2>/dev/null)"
if [[ "$resolved" == 9.8.7 ]]; then
    pass "source installer resolves the latest official release tag"
else
    fail "source installer did not resolve the latest official release tag"
fi

printf '{"tag_name":"9.8.8-beta.1"}\n' > "$latest_json"
if resolve_install_release_tag "file://$latest_json" >/dev/null 2>&1; then
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
RELEASE_CHANNEL="beta"
RELEASE_CHANNEL_EXPLICIT=1
resolved="$(resolve_install_release_tag "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" 2>/dev/null)"
if [[ "$resolved" == 9.9.0-beta.2 ]]; then
    pass "source installer resolves and verifies the latest beta prerelease"
else
    fail "source installer did not resolve the beta prerelease"
fi

printf '%s\n' \
    '[{"tag_name":"9.9.0","draft":false,"prerelease":false},{"tag_name":"9.8.9-beta.4","draft":false,"prerelease":true}]' \
    > "$beta_list"
printf '{"tag_name":"9.8.9-beta.4","draft":false,"prerelease":true}\n' > "$beta_metadata"
if resolve_install_release_tag "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" >/dev/null 2>&1; then
    fail "source installer allowed an older beta to downgrade the latest official release"
else
    pass "source installer refuses a beta channel downgrade"
fi

printf '%s\n' \
    '[{"tag_name":"9.8.7","draft":false,"prerelease":false},{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":true}]' \
    > "$beta_list"

printf '{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":false}\n' > "$beta_metadata"
if resolve_install_release_tag "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" >/dev/null 2>&1; then
    fail "source installer accepted beta metadata without prerelease status"
else
    pass "source installer rejects beta metadata without prerelease status"
fi

printf '[{"tag_name":"9.8.7","draft":false,"prerelease":false}]\n' > "$beta_list"
if resolve_install_release_tag "file://$TMP/absent" "file://$beta_list" "file://$beta_metadata" >/dev/null 2>&1; then
    fail "source installer fell back to official when beta was missing"
else
    pass "source installer fails closed when no beta exists"
fi

RELEASE_TAG="9.8.6"
RELEASE_CHANNEL="stable"
RELEASE_CHANNEL_EXPLICIT=0
resolved="$(resolve_install_release_tag "file://$TMP/absent" 2>/dev/null)"
if [[ "$resolved" == 9.8.6 ]]; then
    pass "release installer keeps its stamped tag without another lookup"
else
    fail "release installer did not keep its stamped tag"
fi

RELEASE_TAG="9.9.0-beta.2"
resolved="$(resolve_install_release_tag "file://$TMP/absent" 2>/dev/null)"
if [[ "$resolved" == 9.9.0-beta.2 ]]; then
    pass "installed beta management remains pinned without another lookup"
else
    fail "installed beta management did not retain its pinned tag"
fi

RELEASE_TAG="9.8.6"
RELEASE_CHANNEL="beta"
RELEASE_CHANNEL_EXPLICIT=1
if resolve_install_release_tag "file://$TMP/absent" >/dev/null 2>&1; then
    fail "explicit beta selection accepted an official stamped bundle"
else
    pass "explicit beta selection rejects an official stamped bundle"
fi

RELEASE_TAG="latest"
RELEASE_CHANNEL="stable"
RELEASE_CHANNEL_EXPLICIT=0

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
    # This exact old group is accepted only to claim a legacy configuration root.
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
    pass "legacy sticky configuration root remains valid for controlled migration"
else
    fail "sticky configuration-root design was rejected"
fi

# That sticky root is also where markers get published, and a file created in a
# setgid directory inherits its group. The marker must therefore be chowned to
# root:root before it is renamed into place, or the claim deletes the marker it
# just wrote and every rerun repeats the same refusal.
if (
    conf="$TMP/setgid-marker-root"
    chown_log="$TMP/setgid-marker-root.chown"
    mkdir -p "$conf"
    chmod g+s "$conf" 2>/dev/null || true
    : > "$chown_log"
    process_is_root() { return 0; }
    chown() { printf '%s\n' "$*" >> "$chown_log"; }
    write_ownership_marker "$conf" .owner marker-v1 || exit 1
    [[ "$(cat "$conf/.owner")" == marker-v1 ]] || exit 1
    read -r recorded < "$chown_log" || exit 1
    [[ "$recorded" == "0:0 -- $conf/"* ]]
); then
    pass "ownership markers are published root:root, not inherited from a setgid root"
else
    fail "ownership marker took its group from the directory it was written into"
fi

# remove_unit is called with a literal from scopes that have no `unit` variable
# of their own (remove_owned_renewal_automation), so its own declaration must not
# read one. It returns early for an absent unit file, which keeps this off
# systemd.
if (
    set -u
    remove_unit 5gpn-test-does-not-exist.service
); then
    pass "remove_unit resolves its unit file from its own argument"
else
    fail "remove_unit read a caller-scope variable or touched systemd"
fi

# `5gpn-journal@.service` is a template. systemd cannot stop or disable a name
# with no instance, so the stop-and-disable gate refused to delete a unit file
# that was always safe to delete, and the same empty status answers made a clean
# rollback report itself incomplete. An instance name must NOT take that path.
if unit_is_template 5gpn-journal@.service \
   && unit_is_template example@.timer \
   && ! unit_is_template 5gpn-journal@5gpn-mihomo.service \
   && ! unit_is_template 5gpn-mihomo.service; then
    pass "a template name is told apart from its instances and from plain units"
else
    fail "template detection would misclassify an instance or a plain unit"
fi
remove_unit_body="$(sed -n '/^remove_unit()/,/^}/p' "$INSTALL")"
tmpl_line="$(grep -n 'unit_is_template' <<<"$remove_unit_body" | head -1 | cut -d: -f1)"
disable_line="$(grep -n 'systemctl disable --now' <<<"$remove_unit_body" | head -1 | cut -d: -f1)"
if [[ -n "$tmpl_line" && -n "$disable_line" && "$tmpl_line" -lt "$disable_line" ]]; then
    pass "uninstall deletes a template unit file without a stop-and-disable it cannot pass"
else
    fail "uninstall still gates a template unit file on an impossible stop-and-disable"
fi

if [[ "$POSIX_MODES" == 1 ]] && process_is_root; then
    if (
        conf="$TMP/setgid-marker-live"
        mkdir -p "$conf"
        chgrp 1 "$conf" && chmod 3771 "$conf" || exit 1
        write_ownership_marker "$conf" .owner marker-v1 || exit 1
        [[ "$(file_gid "$conf")" != 0 ]] || exit 1
        root_ownership_marker_is_safe "$conf" .owner marker-v1
    ); then
        pass "a marker published into a live setgid root satisfies the root:root boundary"
    else
        fail "marker published into a live setgid root failed the root:root boundary"
    fi
else
    pass "live setgid marker ownership skipped because the suite is not root on a POSIX-mode filesystem"
fi

if (
    CONF_DIR="$TMP/cfg-get-safe"
    mkdir -p "$CONF_DIR"
    printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
    printf 'DNS_BASE_DOMAIN=example.com\n' > "$CONF_DIR/dns.env"
    file_uid() { printf '0\n'; }
    file_gid() {
        printf '0\n'
    }
    file_mode() {
        case "$1" in
            "$CONF_DIR") printf '755\n' ;;
            "$CONF_DIR/$CONF_OWNERSHIP_MARKER") printf '644\n' ;;
            *) printf '600\n' ;;
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
            [[ "$*" != *'-m 0755'*"$CONF_DIR"* ]] || boundary_mode=755
            return 0
        }
        fixed_owned_dir_is_safe() {
            [[ "$1" != "$CONF_DIR" || "$boundary_mode" == 755 ]]
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
            && [[ "$boundary_mode" == 755 ]]
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
    pass "fresh 0755 and legacy 2771 config roots seal as root:root 0755 before certificate helpers"
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
ln -- "$runtime_slots/root/policy.json" "$runtime_slots/outside/policy-hardlink.json"
if runtime_plain_file_slot_is_safe "$runtime_slots/root/policy.json" "$runtime_slots/root"; then
    fail "metadata publication accepted a hardlinked runtime control file"
else
    pass "metadata publication rejects hardlinked runtime control files before chmod/chown"
fi
rm -f -- "$runtime_slots/outside/policy-hardlink.json"
runtime_plain_file_slot_is_safe "$runtime_slots/root/policy.json" "$runtime_slots/root" \
    || fail "single-link runtime control file did not recover after hardlink removal"

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
# unprivileged fivegpn runtime, while their source trees can originate from
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
    publish_owned_tree "$src" "$dest" "$ZASH_OWNERSHIP_MARKER" "$ZASH_OWNERSHIP_VALUE"
    [[ "$(file_mode "$dest")" == 755 ]]
    [[ "$(file_mode "$dest/assets")" == 755 ]]
    [[ "$(file_mode "$dest/index.html")" == 644 ]]
    [[ "$(file_mode "$dest/assets/app.js")" == 644 ]]
    [[ "$(file_mode "$dest/$ZASH_OWNERSHIP_MARKER")" == 644 ]]
    grep -qxF index "$dest/index.html"
    grep -qxF asset "$dest/assets/app.js"
); then
    pass "static publication normalizes restrictive source modes for fivegpn"
else
    fail "static publication retained modes that block the fivegpn runtime"
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
    UI_DIR="$custom_parent/web"
    mkdir -p "$UI_DIR"
    printf '%s\n' "$ZASH_OWNERSHIP_VALUE" > "$UI_DIR/$ZASH_OWNERSHIP_MARKER"
    file_uid() {
        [[ "$1" == "$UI_DIR/$ZASH_OWNERSHIP_MARKER" ]] \
            && printf '1001\n' || printf '0\n'
    }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$UI_DIR/$ZASH_OWNERSHIP_MARKER" ]] \
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
    UI_DIR="$custom_parent/web"
    mkdir -p "$UI_DIR"
    file_uid() {
        [[ "$1" == "$UI_DIR" ]] && printf '1001\n' || printf '0\n'
    }
    file_gid() { printf '0\n'; }
    file_mode() { printf '755\n'; }
    ! claim_web_dir >/dev/null 2>&1 \
        && [[ ! -e "$UI_DIR/$ZASH_OWNERSHIP_MARKER" ]]
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
    ! publish_owned_tree "$src" "$dest" "$ZASH_OWNERSHIP_MARKER" "$ZASH_OWNERSHIP_VALUE" >/dev/null 2>&1 \
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

# Fresh-install host coordinates form a complete installer configuration.
# Resolver defaults are rendered separately into dns.json and do not pass
# through this validator.
BASE_DOMAIN=example.com
MIHOMO_LISTEN_IPS=10.20.30.40
CERT_MODE=debug
CERT_EMAIL=""
if validate_install_config >/dev/null 2>&1; then
    pass "fresh installer host coordinates validate"
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
        "$runtime_root/etc/mihomo/config.yaml.tmpl"; then
pass "installed management runtime retains all mihomo reset assets"

render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
# The render is one call now rather than an inline loop; the property under test
# is the ORDER — rendered, then checked non-empty, then handed to the service
# accounts, then validated — not how the rendering is spelled.
render_line="$(grep -nF 'render_mihomo_seed "$template"' <<<"$render_fn" | cut -d: -f1)"
nonempty_line="$(grep -nF '[[ -s "$candidate" ]]' <<<"$render_fn" | cut -d: -f1)"
secure_line="$(grep -nF 'chown "root:$FIVEGPN_SERVICE_GROUP" "$candidate"' <<<"$render_fn" | cut -d: -f1)"
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
FIVEGPN_SERVICE_USER="$(id -un)"
FIVEGPN_SERVICE_GROUP="$(id -gn)"
MIHOMO_BIN="$TMP/fake-mihomo"
INTERCEPT_DIR="$CONF_DIR/intercept"
MIHOMO_TEST_LOG="$TMP/mihomo.log"; export MIHOMO_TEST_LOG
cat > "$MIHOMO_BIN" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIHOMO_TEST_LOG"
exit 0
EOF
chmod +x "$MIHOMO_BIN"
mkdir -p "$INTERCEPT_DIR"
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
        "$CONF_DIR/dns.env") printf '600\n' ;;
        *) stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true ;;
    esac
}
persist_mihomo_secret() { :; }
chown() { :; }
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
# The panel allow rule is qualified to exclude the engine's own egress: without
# it a captured extension naming the console reaches the gateway's management
# plane. The engine dials its upstreams back through these same rules, so that
# traffic arrives as INNER -- the predicate names the type because there is no
# longer a listener to name.
grep -Fq 'console.example.com: 127.0.0.1' "$config" \
    && grep -Fq 'AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,console.example.com)),DIRECT' "$config" \
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
unset -f chown

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
    "$ROOT/etc/5gpn/dns.env.example" | sort)"
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

# The orphaned allowlist file is removed, and only when no rule reads it.
#
# whitelist.txt survived on every host that had one: holding the operator's
# CIDRs, swept to 0660 by the mode pass, and read by nothing. An operator who
# finds it reasonably concludes the panel is still source-restricted.
#
# Both call sites matter and one was nearly missed: render_mihomo_config returns
# early on the preserve path, which is THE path an upgrade takes, and that is
# exactly where the orphan lives.
retire_fn="$(sed -n '/^retire_mihomo_whitelist()/,/^}/p' "$INSTALL")"
if [[ -z "$retire_fn" ]]; then
    fail "retire_mihomo_whitelist is missing"
else
    printf '%s' "$retire_fn" | grep -Fq 'RULE-SET' \
        || fail "retire_mihomo_whitelist deletes the file without checking the live config"
    render_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
    [[ "$(printf '%s' "$render_fn" | grep -c 'retire_mihomo_whitelist')" == 2 ]] \
        || fail "render_mihomo_config does not retire the allowlist on both the preserve and the seed path"
fi

retire_dir="$TMP/retire/mihomo"
mkdir -p "$retire_dir"
printf '203.0.113.1/32\n' > "$retire_dir/whitelist.txt"
printf 'rules:\n  - AND,((NOT,((IN-TYPE,INNER))),(DOMAIN,c.test)),DIRECT\n' > "$retire_dir/config.yaml"
(
    MIHOMO_DIR="$retire_dir"
    retire_mihomo_whitelist "$retire_dir/config.yaml"
) >/dev/null 2>&1
if [[ -e "$retire_dir/whitelist.txt" ]]; then
    fail "the orphaned allowlist file survived a config that does not read it"
else
    pass "the orphaned allowlist file is removed once no rule reads it"
fi

# And it is kept when a rule still does, because deleting a file a live rule
# reads takes the gateway down at the next reload.
printf '203.0.113.1/32\n' > "$retire_dir/whitelist.txt"
printf 'rules:\n  - AND,((DOMAIN,c.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n' > "$retire_dir/config.yaml"
(
    MIHOMO_DIR="$retire_dir"
    retire_mihomo_whitelist "$retire_dir/config.yaml"
) >/dev/null 2>&1
if [[ -e "$retire_dir/whitelist.txt" ]]; then
    pass "an allowlist file a live rule still reads is kept"
else
    fail "the allowlist file was deleted while a rule still reads it"
fi

# The allowlist ops are gone by owner decision, so the boundaries they used to
# enforce -- canonical CIDR validation, exact-match deletion, symlink refusal
# -- have nothing left to protect. What replaces them is the assertion that
# nothing writes an allowlist file at all: a writer that survives its rule
# would edit a file no rule reads, and report success doing it.
if grep -Eq '^(add_allow_ip|del_allow_ip|apply_whitelist)\(\)' "$INSTALL"; then
    fail "an allowlist mutation op survived the allowlist"
elif [[ -n "$(awk '
    /^retire_mihomo_whitelist\(\)/ { skip = 1 }
    skip { if ($0 == "}") skip = 0; next }
    /[/]whitelist[.]txt/ { print }
' "$INSTALL")" ]]; then
    # retire_mihomo_whitelist is exempt by range: it names the path in order to
    # delete it, which is the one legitimate reason left to name it at all.
    fail "the installer still builds a path to an allowlist file outside the retirement"
else
    pass "no allowlist file is written or refreshed by the installer"
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

# The DoT listener lives in the mihomo process now, so the account that serves a
# certificate has to be the account that can read it. When the writer and the
# validator disagreed the failure was silent in the worst way: the service
# started, bound every tunnel and the TLS controller, reported itself healthy,
# and had no DNS ingress at all because it could not open its own key.
[[ "$(cert_role_group dot)" == "$FIVEGPN_SERVICE_GROUP" ]] \
    || fail "the DoT certificate role is not owned by the account that serves DoT"
[[ "$(cert_role_group console)" == "$FIVEGPN_SERVICE_GROUP" ]] \
    || fail "the controller certificate role is not owned by the serving account"
[[ "$(cert_role_group web)" == root ]] \
    || fail "the reader-less web role was widened beyond root"
if cert_role_group nonsense >/dev/null 2>&1; then
    fail "an unknown certificate role was given an owning account"
fi
pass "certificate roles are owned by the account that serves them"

# The published UI directory needs a marker before recursive cleanup. The
# GitHub checkout lives below /home, which safe_ui_path intentionally rejects,
# so isolate ownership lifecycle behavior from path-policy behavior.
BASE_DIR="$TMP/base"
if (
    safe_ui_path() { printf '%s\n' "$UI_DIR"; }
    UI_DIR="$TMP/external/ui"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() {
        [[ "$1" == "$UI_DIR/$ZASH_OWNERSHIP_MARKER" ]] \
            && printf '644\n' || printf '755\n'
    }
    mkdir -p "$UI_DIR"
    echo foreign > "$UI_DIR/file"
    ! claim_ui_dir >/dev/null 2>&1
    rm -f "$UI_DIR/file"
    claim_ui_dir >/dev/null
    echo owned > "$UI_DIR/file"
    remove_ui_dir >/dev/null
    [[ ! -e "$UI_DIR" ]]
); then
    pass "UI ownership marker gates removal"
else
    fail "UI ownership lifecycle check failed"
fi
UI_DIR=/
if safe_ui_path >/dev/null 2>&1; then
    fail "filesystem root accepted as UI_DIR"
else
    pass "system root is rejected as UI_DIR"
fi
UI_DIR=/etc/5gpn-unowned-panel
if safe_ui_path >/dev/null 2>&1; then
    fail "system-directory descendant accepted as UI_DIR"
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

# MITM no longer has a second service lifecycle. The one runtime and the two
# certificate triggers are the complete activation set regardless of master
# state; capture remains inert inside the process while the document is off.
if (
    calls="$TMP/monolith-systemctl.log"
    MIHOMO_LISTEN_IPS=10.20.30.40
    resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
    cfg_get() { return 0; }
    wait_service_ready() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$calls"
        return 0
    }
    start_services >/dev/null 2>&1
    grep -Fxq 'enable --now 5gpn-intercept-cert.path' "$calls"
    grep -Fxq 'enable --now 5gpn-intercept-cert.timer' "$calls"
    grep -Fxq 'enable 5gpn-mihomo.service' "$calls"
    grep -Fxq 'restart 5gpn-mihomo.service' "$calls"
    ! grep -Eq '(^| )5gpn-(dns|intercept)\.service$' "$calls"
); then
    pass "service activation drives only the monolith and certificate triggers"
else
    fail "service activation retained a retired sidecar lifecycle"
fi

# Public/certificate DNS is fail-closed and always uses the independent
# resolver instead of the host's possibly synthetic resolver.
CONSOLE_DOMAIN=console.example.com
PUBLIC_IP=198.51.100.9
GATEWAY_IP=10.20.30.40
DIG_LOG="$TMP/dig.log"
DIG_A=198.51.100.9
DIG_AAAA=""
# Real dig exits 0 when it successfully receives a NODATA answer and 9 when it
# gets no reply at all. The stub must keep those apart, because the gate now
# distinguishes "observed: no AAAA" from "the AAAA query never answered".
DIG_RC=0
dig() {
    printf '%s\n' "$*" >> "$DIG_LOG"
    case " $* " in
        *' AAAA '*) [[ -n "$DIG_AAAA" ]] && echo "$DIG_AAAA" ;;
        *' A '*) [[ -n "$DIG_A" ]] && echo "$DIG_A" ;;
    esac
    return "$DIG_RC"
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
    && pass "HTTP-01 verifies console/dot A and empty AAAA through 1.1.1.1" \
    || fail "valid HTTP-01 service DNS was rejected"
for name in console.example.com dot.example.com; do
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
# An unanswered AAAA lookup is not evidence of absence. Passing here would stop
# mihomo for a standalone challenge that Let's Encrypt may then attempt over an
# IPv6 address nobody verified.
DIG_RC=9
if verify_console_dns >/dev/null 2>&1; then
    fail "HTTP-01 treated an unanswered AAAA lookup as proof of no AAAA"
else
    pass "HTTP-01 fails closed when the AAAA lookup does not answer"
fi
DIG_RC=0
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
elif grep -q '^systemctl stop 5gpn-mihomo.service$' "$PORT80_LOG" \
  && grep -q '^systemctl start 5gpn-mihomo.service$' "$PORT80_LOG"; then
    pass "HTTP-01 restores an originally active mihomo after Certbot failure"
else
    fail "HTTP-01 did not stop and restore active mihomo around Certbot"
fi
HTTP_CERTBOT_RC=0
: > "$PORT80_LOG"
run_http_certbot certonly --standalone >/dev/null 2>&1 \
    || fail "HTTP-01 wrapper failed after successful Certbot"
if grep -q '^systemctl stop 5gpn-mihomo.service$' "$PORT80_LOG" \
   && ! grep -q '^systemctl start 5gpn-mihomo.service$' "$PORT80_LOG"; then
    pass "successful HTTP-01 keeps active mihomo stopped for certificate publication"
else
    fail "successful HTTP-01 restored mihomo before certificate publication"
fi
for HTTP_CERTBOT_SIGNAL in INT TERM; do
    : > "$PORT80_LOG"
    if run_http_certbot certonly --standalone >/dev/null 2>&1; then
        fail "HTTP-01 wrapper hid a $HTTP_CERTBOT_SIGNAL signal"
    elif grep -q '^systemctl stop 5gpn-mihomo.service$' "$PORT80_LOG" \
      && grep -q '^systemctl start 5gpn-mihomo.service$' "$PORT80_LOG"; then
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
if grep -Eq '^systemctl (stop|start) 5gpn-mihomo.service$' "$PORT80_LOG"; then
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
    deploy_cert_roles() { printf 'deploy_cert_roles console/current\n' >> "$HTTP_INSTALL_LOG"; }
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
        systemctl start 5gpn-mihomo.service
    }
    : > "$HTTP_INSTALL_LOG"
    install_cert example.com >/dev/null 2>&1 || exit 1
    start_services
) || fail "mocked successful HTTP-01 install flow failed"
http_certbot_line="$(grep -n '^certbot ' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
http_deploy_line="$(grep -n '^deploy_cert_roles console/current$' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
http_start_line="$(grep -n '^systemctl start 5gpn-mihomo.service$' "$HTTP_INSTALL_LOG" | head -1 | cut -d: -f1)"
if [[ -n "$http_certbot_line" && -n "$http_deploy_line" && -n "$http_start_line" \
   && "$http_certbot_line" -lt "$http_deploy_line" \
   && "$http_deploy_line" -lt "$http_start_line" ]]; then
    pass "HTTP-01 publishes console/current before start_services restores mihomo"
else
    fail "HTTP-01 service restoration raced ahead of console/current publication"
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

# Starting the monolith can publish a certificate request and trigger the root
# certificate oneshot. The installer must release the shared certificate lock
# for that dependency and reacquire it before success or failure processing.
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
    pass "failed service start reacquires the certificate lock before unwinding"
else
    fail "failed service start can unwind without holding the certificate lock"
fi
exit_trap_fn="$(sed -n '/^install_transaction_exit()/,/^}/p' "$INSTALL")"
error_trap_fn="$(sed -n '/^install_transaction_error()/,/^}/p' "$INSTALL")"
finish_trap_fn="$(sed -n '/^finish_install_transaction()/,/^}/p' "$INSTALL")"
if grep -Fq 'finish_install_transaction' <<<"$exit_trap_fn" \
   && grep -Fq 'finish_install_transaction' <<<"$error_trap_fn" \
   && grep -Fq 'release_install_cert_lock' <<<"$finish_trap_fn" \
   && grep -Fq 'release_install_lock' <<<"$finish_trap_fn"; then
    pass "transaction traps always release both locks on the way out"
else
    fail "a signal or error can leave an installer lock held"
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
# Certificate material has no migration path and nothing to roll back to, so a
# host this release cannot accept must be turned away while its deployment is
# still intact. ensure_dns_cert_root only runs at publication time, by which
# point the three binaries are already replaced -- hence the same read-only
# verdict runs in preflight, from one shared implementation.
cert_pf="$TMP/cert-preflight"
if (
    DNS_CERT_DIR="$cert_pf/populated"
    mkdir -p "$DNS_CERT_DIR/dot"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { printf '751\n'; }
    err() { :; }
    ! cert_root_claim_is_possible
); then
    pass "a populated certificate root with no marker is refused before publication"
else
    fail "a pre-marker certificate tree reaches publication before it is refused"
fi
if (
    DNS_CERT_DIR="$cert_pf/empty"
    mkdir -p "$DNS_CERT_DIR"
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { printf '751\n'; }
    err() { :; }
    cert_root_claim_is_possible
); then
    pass "the empty root a fresh install just created is still claimable"
else
    fail "preflight refuses the empty certificate root of a first install"
fi
cert_full_body="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
cert_pf_line="$(grep -n 'cert_root_claim_is_possible' <<<"$cert_full_body" | head -1 | cut -d: -f1 || true)"
cert_pub_line="$(grep -n 'install_mihomo' <<<"$cert_full_body" | head -1 | cut -d: -f1 || true)"
cert_shared=0
grep -Fq 'cert_root_claim_is_possible || return 1' \
    <<<"$(sed -n '/^ensure_dns_cert_root()/,/^}/p' "$INSTALL")" && cert_shared=1
if [[ -n "$cert_pf_line" && -n "$cert_pub_line" \
   && "$cert_pf_line" -lt "$cert_pub_line" && "$cert_shared" == 1 ]]; then
    pass "preflight and publication share one certificate-root verdict"
else
    fail "the certificate-root check runs after publication begins, or was duplicated"
fi

if [[ "$FAIL" == 0 ]]; then
    echo "test_installer_safety: PASS"
else
    echo "test_installer_safety: FAIL"
    exit 1
fi
