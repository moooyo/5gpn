#!/usr/bin/env bash
# Behaviour-level checks for quick-install release and filesystem boundaries.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUICK="$ROOT/quick-install.sh"
FAIL=0
pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# quick-install has a normal sourced-file guard; production never enables a
# library environment flag or exposes its internal path/tag seams.
# shellcheck source=../quick-install.sh
source "$QUICK"
set +e

TMP="$(mktemp -d /tmp/5gpn-quick-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

# Exercise the exact production entrypoint guard through stdin. BASH_SOURCE has
# no element zero in this mode, so the guard must tolerate nounset and call main.
entry_guard="$(sed -n '/^if \[\[ .*BASH_SOURCE\[0\]/,/^fi$/p' "$QUICK")"
entry_result="$(printf '%s\n' \
    'set -u' \
    'main() { printf "%s\n" stdin-entry-ran; }' \
    "$entry_guard" | bash 2>&1)"
if [[ "$?" == 0 && "$entry_result" == stdin-entry-ran ]]; then
    pass "stdin execution tolerates an unset BASH_SOURCE element and runs main"
else
    fail "stdin execution guard failed: $entry_result"
fi

# A new or empty custom path can be claimed, and the stored path is canonical.
mkdir -p "$TMP/canonical"
prepare_source_dir "$TMP/source" >/dev/null 2>&1
expected="$(canonical_path "$TMP/source")"
if [[ "$?" == 0 && "$_QI_SOURCE_DIR" == "$expected" ]] \
   && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"; then
    pass "empty source is claimed with an exact marker and canonical path"
else
    fail "empty source claim or canonicalisation failed"
fi

echo payload > "$_QI_SOURCE_DIR/payload"
clear_source_dir >/dev/null 2>&1
if [[ "$?" == 0 && ! -e "$_QI_SOURCE_DIR/payload" ]] \
   && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"; then
    pass "owned source is cleared while retaining its exact marker"
else
    fail "owned source clear failed"
fi

# An arbitrary, almost-correct, or linked marker must never claim a directory.
foreign="$TMP/foreign"
mkdir -p "$foreign"
echo keep > "$foreign/payload"
echo foreign > "$foreign/$SOURCE_MARKER"
prepare_source_dir "$foreign" >/dev/null 2>&1
if [[ "$?" != 0 && -f "$foreign/payload" && "$(cat "$foreign/$SOURCE_MARKER")" == foreign ]]; then
    pass "non-empty directory with a foreign marker is refused unchanged"
else
    fail "foreign marker claimed or changed a directory"
fi

printf '%s\n\n' "$SOURCE_MARKER_VALUE" > "$foreign/$SOURCE_MARKER"
prepare_source_dir "$foreign" >/dev/null 2>&1
if [[ "$?" != 0 && -f "$foreign/payload" ]]; then
    pass "ownership marker content must match byte-for-byte"
else
    fail "marker with trailing data was accepted"
fi

outside="$TMP/outside"
echo untouched > "$outside"
linked="$TMP/linked"
mkdir -p "$linked"
ln -s "$outside" "$linked/$SOURCE_MARKER"
prepare_source_dir "$linked" >/dev/null 2>&1
if [[ "$?" != 0 && "$(cat "$outside")" == untouched ]]; then
    pass "marker symlink cannot claim or overwrite an external file"
else
    fail "marker symlink was followed while claiming a source"
fi

recheck="$TMP/recheck"
prepare_source_dir "$recheck" >/dev/null 2>&1
echo keep > "$_QI_SOURCE_DIR/payload"
rm -f -- "$_QI_SOURCE_DIR/$SOURCE_MARKER"
ln -s "$outside" "$_QI_SOURCE_DIR/$SOURCE_MARKER"
clear_source_dir >/dev/null 2>&1
if [[ "$?" != 0 && -f "$_QI_SOURCE_DIR/payload" && "$(cat "$outside")" == untouched ]]; then
    pass "ownership is revalidated immediately before recursive cleanup"
else
    fail "cleanup followed or ignored a replaced marker"
fi

prepare_source_dir /etc/5gpn-quick-test >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "system directory descendants are refused" \
    || fail "system directory descendant was accepted"

# Stable and beta channels accept disjoint strict SemVer forms.
if valid_stable_release_tag 9.8.7 \
   && ! valid_stable_release_tag 9.8.7-beta.1 \
   && ! valid_stable_release_tag 09.8.7 \
   && valid_beta_release_tag 9.8.8-beta.1 \
   && valid_beta_release_tag 9.8.8-beta.12 \
   && ! valid_beta_release_tag 9.8.8-beta.0 \
   && ! valid_beta_release_tag 9.8.8-beta.01 \
   && ! valid_beta_release_tag 9.8.8-rc.1; then
    pass "stable and beta tag grammars are strict and disjoint"
else
    fail "release tag grammar accepted a cross-channel or malformed tag"
fi

# Latest official is resolved once to a validated stable tag.
latest_json="$TMP/latest.json"
printf '{"tag_name":"9.8.7"}\n' > "$latest_json"
dl() { cp -- "$1" "$2"; }
got="$(resolve_release_tag stable "$latest_json" 2>/dev/null)"
[[ "$got" == 9.8.7 ]] && pass "latest release response resolves to one safe tag" \
    || fail "latest tag resolution returned '$got'"

printf '{"tag_name":"9.8.8-beta.1"}\n' > "$latest_json"
resolve_release_tag stable "$latest_json" >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "official resolution refuses a beta tag" \
    || fail "official resolution accepted a beta tag"

printf '{"tag_name":"../main"}\n' > "$latest_json"
resolve_release_tag stable "$latest_json" >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "unsafe release tag is rejected" \
    || fail "unsafe release tag was accepted"

# Beta discovery selects only a strict tag and verifies its exact GitHub
# metadata. It must fail closed when no beta exists or it is not a prerelease.
beta_list="$TMP/beta-list.json"
beta_metadata="$TMP/beta-metadata.json"
printf '%s\n' \
    '[{"tag_name":"9.8.7","draft":false,"prerelease":false},{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":true},{"tag_name":"9.9.0-beta.1","draft":false,"prerelease":true}]' \
    > "$beta_list"
printf '{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":true}\n' > "$beta_metadata"
got="$(resolve_release_tag beta "$beta_list" "$beta_metadata" 2>/dev/null)"
[[ "$got" == 9.9.0-beta.2 ]] && pass "beta resolution selects and verifies the newest beta candidate" \
    || fail "beta resolution returned '$got'"

printf '{"tag_name":"9.9.0-beta.2","draft":false,"prerelease":false}\n' > "$beta_metadata"
resolve_release_tag beta "$beta_list" "$beta_metadata" >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "beta resolution refuses a non-prerelease candidate" \
    || fail "beta resolution accepted a non-prerelease candidate"

printf '[{"tag_name":"9.8.7","draft":false,"prerelease":false}]\n' > "$beta_list"
resolve_release_tag beta "$beta_list" "$beta_metadata" >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "missing beta fails without an official fallback" \
    || fail "missing beta fell back to an official release"

if ! grep -Eq 'REPO="\$\{|SRC_REQUESTED=|DNS_VERSION:-|releases/latest/download|origin main' "$QUICK"; then
    pass "quick install exposes no environment or branch release override"
else
    fail "quick install still exposes an environment or branch version override"
fi

# Build a fixture release bundle and verify that only the matching digest can
# be published. A checksum failure leaves the existing source untouched.
payload="$TMP/bundle-payload"
bundle="$TMP/$BUNDLE_NAME"
checksums="$TMP/$CHECKSUMS_NAME"
FIXTURE_BUNDLE="$bundle"
FIXTURE_CHECKSUMS="$checksums"

build_fixture_bundle() { # build_fixture_bundle <install.sh contents>
    rm -rf -- "$payload"
    mkdir -p "$payload"
    printf '%s\n' "$1" > "$payload/install.sh"
    echo template > "$payload/template.txt"
    tar -czf "$bundle" -C "$payload" .
    printf '%s  %s\n' "$(sha256_file "$bundle")" "$BUNDLE_NAME" > "$checksums"
}

build_fixture_bundle $'#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="9.8.7"'

DL_MODE=valid
dl() {
    case "$1" in
        */"$BUNDLE_NAME")
            [[ "$DL_MODE" != missing_bundle ]] || return 1
            cp -- "$FIXTURE_BUNDLE" "$2" ;;
        */"$CHECKSUMS_NAME")
            [[ "$DL_MODE" != missing_checksums ]] || return 1
            cp -- "$FIXTURE_CHECKSUMS" "$2" ;;
        *) return 1 ;;
    esac
}

bundle_target="$TMP/bundle-target"
prepare_source_dir "$bundle_target" >/dev/null 2>&1
fetch_bundle https://fixture.invalid stable 9.8.7 >/dev/null 2>&1
if [[ "$?" == 0 && -f "$_QI_SOURCE_DIR/install.sh" && -f "$_QI_SOURCE_DIR/template.txt" ]] \
   && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"; then
    pass "digest-verified bundle is staged and published"
else
    fail "valid release bundle was not published"
fi

beta_bundle_target="$TMP/beta-bundle-target"
prepare_source_dir "$beta_bundle_target" >/dev/null 2>&1
build_fixture_bundle $'#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="9.9.0-beta.2"'
fetch_bundle https://fixture.invalid beta 9.9.0-beta.2 >/dev/null 2>&1
if [[ "$?" == 0 && -f "$_QI_SOURCE_DIR/install.sh" ]] \
   && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"; then
    pass "verified beta bundle is accepted only with a beta tag"
else
    fail "valid beta release bundle was not published"
fi

expect_stamp_rejected() { # expect_stamp_rejected <name> <channel> <tag> <install.sh contents>
    local name="$1" channel="$2" tag="$3" contents="$4" target rc
    target="$TMP/stamp-${name}-target"
    prepare_source_dir "$target" >/dev/null 2>&1
    echo keep > "$_QI_SOURCE_DIR/keep"
    build_fixture_bundle "$contents"
    fetch_bundle https://fixture.invalid "$channel" "$tag" >/dev/null 2>&1
    rc=$?
    if [[ "$rc" == 20 && -f "$_QI_SOURCE_DIR/keep" && ! -e "$_QI_SOURCE_DIR/install.sh" ]]; then
        pass "$name bundle stamp is rejected before publication"
    else
        fail "$name bundle stamp returned $rc or modified the existing source"
    fi
}

expect_stamp_rejected missing stable 9.8.7 \
    $'#!/usr/bin/env bash\necho missing-stamp'
expect_stamp_rejected duplicate stable 9.8.7 \
    $'#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="9.8.7"\nDNS_VERSION_DEFAULT="9.8.7"'
expect_stamp_rejected wrong-tag stable 9.8.7 \
    $'#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="9.8.6"'
expect_stamp_rejected cross-channel stable 9.8.7 \
    $'#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="9.8.7-beta.1"'

mismatch_target="$TMP/mismatch-target"
prepare_source_dir "$mismatch_target" >/dev/null 2>&1
echo keep > "$_QI_SOURCE_DIR/keep"
printf '%064d  %s\n' 0 "$BUNDLE_NAME" > "$FIXTURE_CHECKSUMS"
fetch_bundle https://fixture.invalid stable 9.8.7 >/dev/null 2>&1
rc=$?
if [[ "$rc" == 20 && -f "$_QI_SOURCE_DIR/keep" && ! -e "$_QI_SOURCE_DIR/install.sh" ]]; then
    pass "bundle digest mismatch fails closed before source cleanup"
else
    fail "digest mismatch returned $rc or modified the existing source"
fi

DL_MODE=missing_checksums
fetch_bundle https://fixture.invalid stable 9.8.7 >/dev/null 2>&1
[[ "$?" == 20 ]] && pass "missing checksums fail closed" \
    || fail "bundle without checksums did not hard-fail"
DL_MODE=missing_bundle
fetch_bundle https://fixture.invalid stable 9.8.7 >/dev/null 2>&1
[[ "$?" == 10 ]] && pass "an absent bundle is reported distinctly and still fails closed" \
    || fail "absent bundle did not return the bundle-missing status"
fetch_bundle https://fixture.invalid stable 9.8.8-beta.1 >/dev/null 2>&1
[[ "$?" == 20 ]] && pass "bundle fetch rejects a beta tag on the official channel" \
    || fail "bundle fetch accepted a cross-channel beta tag"
fetch_bundle https://fixture.invalid beta 9.8.7 >/dev/null 2>&1
[[ "$?" == 20 ]] && pass "bundle fetch rejects an official tag on the beta channel" \
    || fail "bundle fetch accepted a cross-channel official tag"
if ! grep -Eq '^fetch_git\(\)|git -C .*fetch|git -C .*checkout' "$QUICK"; then
    pass "missing bundles cannot fall back to unsigned git content"
else
    fail "quick installer still contains an unsigned git fallback"
fi

# Archive validation rejects ownership-marker links before extraction and uses
# no-same-owner extraction for ordinary bundles.
unsafe_payload="$TMP/unsafe-payload"
mkdir -p "$unsafe_payload"
echo '#!/bin/sh' > "$unsafe_payload/install.sh"
ln -s "$outside" "$unsafe_payload/$SOURCE_MARKER"
tar -czf "$TMP/unsafe.tgz" -C "$unsafe_payload" .
archive_is_safe "$TMP/unsafe.tgz" >/dev/null 2>&1
if [[ "$?" != 0 ]] && grep -Fq -- '--no-same-owner --no-same-permissions' "$QUICK"; then
    pass "archive links/markers are rejected and extraction drops stored ownership"
else
    fail "unsafe archive validation or extraction ownership gate is missing"
fi

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "test_quick_install_safety: PASS"
else
    echo "test_quick_install_safety: FAIL"
    exit 1
fi
