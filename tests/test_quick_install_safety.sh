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

# Latest is resolved once to a validated tag; branch shortcuts are absent.
latest_json="$TMP/latest.json"
printf '{"tag_name":"9.8.7"}\n' > "$latest_json"
dl() { cp -- "$1" "$2"; }
got="$(resolve_latest_tag "$latest_json" 2>/dev/null)"
[[ "$got" == 9.8.7 ]] && pass "latest release response resolves to one safe tag" \
    || fail "latest tag resolution returned '$got'"

printf '{"tag_name":"../main"}\n' > "$latest_json"
resolve_latest_tag "$latest_json" >/dev/null 2>&1
[[ "$?" != 0 ]] && pass "unsafe release tag is rejected" \
    || fail "unsafe release tag was accepted"
if ! grep -Eq 'REPO="\$\{|SRC_REQUESTED=|DNS_VERSION:-|releases/latest/download|origin main' "$QUICK"; then
    pass "quick install exposes no environment or branch release override"
else
    fail "quick install still exposes an environment or branch version override"
fi

# Build a fixture release bundle and verify that only the matching digest can
# be published. A checksum failure leaves the existing source untouched.
payload="$TMP/bundle-payload"
mkdir -p "$payload"
printf '#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="fixture"\n' > "$payload/install.sh"
echo template > "$payload/template.txt"
bundle="$TMP/$BUNDLE_NAME"
checksums="$TMP/$CHECKSUMS_NAME"
tar -czf "$bundle" -C "$payload" .
printf '%s  %s\n' "$(sha256_file "$bundle")" "$BUNDLE_NAME" > "$checksums"
FIXTURE_BUNDLE="$bundle"
FIXTURE_CHECKSUMS="$checksums"

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
fetch_bundle https://fixture.invalid 9.8.7 >/dev/null 2>&1
if [[ "$?" == 0 && -f "$_QI_SOURCE_DIR/install.sh" && -f "$_QI_SOURCE_DIR/template.txt" ]] \
   && marker_matches "$_QI_SOURCE_DIR/$SOURCE_MARKER" "$SOURCE_MARKER_VALUE"; then
    pass "digest-verified bundle is staged and published"
else
    fail "valid release bundle was not published"
fi

mismatch_target="$TMP/mismatch-target"
prepare_source_dir "$mismatch_target" >/dev/null 2>&1
echo keep > "$_QI_SOURCE_DIR/keep"
printf '%064d  %s\n' 0 "$BUNDLE_NAME" > "$FIXTURE_CHECKSUMS"
fetch_bundle https://fixture.invalid 9.8.7 >/dev/null 2>&1
rc=$?
if [[ "$rc" == 20 && -f "$_QI_SOURCE_DIR/keep" && ! -e "$_QI_SOURCE_DIR/install.sh" ]]; then
    pass "bundle digest mismatch fails closed before source cleanup"
else
    fail "digest mismatch returned $rc or modified the existing source"
fi

DL_MODE=missing_checksums
fetch_bundle https://fixture.invalid 9.8.7 >/dev/null 2>&1
[[ "$?" == 20 ]] && pass "missing checksums fail closed" \
    || fail "bundle without checksums did not hard-fail"
DL_MODE=missing_bundle
fetch_bundle https://fixture.invalid 9.8.7 >/dev/null 2>&1
[[ "$?" == 10 ]] && pass "only an absent bundle is eligible for tag fallback" \
    || fail "absent bundle did not return the fallback-only status"

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

# The git release fallback fetches only the already-resolved tag, stamps that
# tag into install.sh, and leaves the source untouched when the tag is absent.
repo="$TMP/repo"
git init -q "$repo"
git -C "$repo" config user.name 5gpn-test
git -C "$repo" config user.email 5gpn-test@example.invalid
printf '#!/usr/bin/env bash\nDNS_VERSION_DEFAULT="unstamped"\n' > "$repo/install.sh"
echo branch > "$repo/branch-only"
git -C "$repo" add install.sh branch-only
git -C "$repo" commit -qm fixture
git -C "$repo" tag 9.8.7

git_target="$TMP/git-target"
prepare_source_dir "$git_target" >/dev/null 2>&1
fetch_git "$repo" 9.8.7 >/dev/null 2>&1
if [[ "$?" == 0 ]] \
   && grep -Fqx 'DNS_VERSION_DEFAULT="9.8.7"' "$_QI_SOURCE_DIR/install.sh"; then
    pass "git fallback checks out and stamps the exact resolved tag"
else
    fail "git fallback did not bind install.sh to the resolved tag"
fi

missing_target="$TMP/missing-tag-target"
prepare_source_dir "$missing_target" >/dev/null 2>&1
echo keep > "$_QI_SOURCE_DIR/keep"
fetch_git "$repo" 0.0.0 >/dev/null 2>&1
if [[ "$?" != 0 && -f "$_QI_SOURCE_DIR/keep" && ! -e "$_QI_SOURCE_DIR/branch-only" ]]; then
    pass "missing tag never falls back to the repository branch"
else
    fail "missing tag fallback modified source or used a branch"
fi

ln -s "$outside" "$repo/$SOURCE_MARKER"
git -C "$repo" add "$SOURCE_MARKER"
git -C "$repo" commit -qm unsafe-marker
git -C "$repo" tag 9.8.8
linked_git_target="$TMP/linked-git-target"
prepare_source_dir "$linked_git_target" >/dev/null 2>&1
echo keep > "$_QI_SOURCE_DIR/keep"
fetch_git "$repo" 9.8.8 >/dev/null 2>&1
if [[ "$?" != 0 && -f "$_QI_SOURCE_DIR/keep" && "$(cat "$outside")" == untouched ]]; then
    pass "git checkout cannot publish or follow an ownership-marker symlink"
else
    fail "git marker symlink escaped staging or modified the source"
fi

echo "----"
if [[ "$FAIL" == 0 ]]; then
    echo "test_quick_install_safety: PASS"
else
    echo "test_quick_install_safety: FAIL"
    exit 1
fi
