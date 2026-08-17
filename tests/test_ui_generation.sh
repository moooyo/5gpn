#!/usr/bin/env bash
# Behavioral contract for atomic Console/profile generation publication.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/5gpn-ui-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
umask 022

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

INSTALL_SH_LIB_ONLY=1 TEST_INSTALL="$ROOT/install.sh" bash -c '
    set -Eeuo pipefail
    export INSTALL_SH_LIB_ONLY
    source "$TEST_INSTALL"
    load_ui_generation_helper
    [[ "${#UI_GENERATION_STABLE_URL_PATHS[@]}" -gt 0 ]]
    _ui_generation_path_is_stable_url pwa-192x192.png
' || fail "function-scoped helper loading lost the stable URL catalog"
pass "installed helper loading retains the global stable URL catalog"

tree_fingerprint() {
    local tree="$1" entry sorted
    local -a entries=()
    _ui_generation_find_entries entries "$tree" -mindepth 0 || return 1
    sorted="$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)" || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        stat -c '%n|%F|%a|%u|%g|%h|%s|%Y' -- "$entry" || return 1
        if [[ -f "$entry" && ! -L "$entry" ]]; then
            sha256sum -- "$entry" || return 1
        elif [[ -L "$entry" ]]; then
            readlink -- "$entry" || return 1
        fi
    done <<< "$sorted" | sha256sum | awk '{print $1}'
}

# shellcheck source=../scripts/ui-generation.sh
source "$ROOT/scripts/ui-generation.sh"

find_probe="$TMP/find-probe"
mkdir "$find_probe"
printf 'partial\n' > "$find_probe/entry"
find_probe_entries=(preserved)
REAL_FIND="$(command -v find)"
find() {
    "$REAL_FIND" "$@"
    return 1
}
if _ui_generation_find_entries find_probe_entries "$find_probe" -mindepth 1 -maxdepth 1; then
    fail "a UI find producer failure was accepted after returning partial entries"
fi
unset -f find
[[ "${#find_probe_entries[@]}" == 1 && "${find_probe_entries[0]}" == preserved ]] \
    || fail "a failed UI find producer leaked partial entries to its caller"
pass "UI entry collection requires an unambiguous producer success sentinel"

fresh_root="$TMP/missing-base/ui"
ui_generation_preflight "$fresh_root" \
    || fail "fresh preflight rejected an absent parent below a safe existing ancestor"
[[ ! -e "$TMP/missing-base" ]] \
    || fail "fresh read-only preflight created the missing base directory"
if ui_generation_prepare_existing_current "$fresh_root" >/dev/null 2>&1; then
    fail "manual/renew prepare accepted a missing UI root"
fi
[[ ! -e "$TMP/missing-base" ]] \
    || fail "manual/renew prepare wrote a missing UI root"
empty_parent="$TMP/empty-runtime"
empty_root="$empty_parent/ui"
mkdir -p "$empty_root"
chmod 0755 "$empty_parent" "$empty_root"
empty_state_before="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' "$empty_root")"
if ui_generation_prepare_existing_current "$empty_root" >/dev/null 2>&1; then
    fail "manual/renew prepare accepted an empty unmarked UI root"
fi
[[ "$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' "$empty_root")" == "$empty_state_before" \
   && -z "$(find "$empty_root" -mindepth 1 -print -quit)" ]] \
    || fail "manual/renew prepare mutated an empty unmarked UI root"
pass "fresh absent base/UI preflight is read-only"

runtime="$TMP/runtime"
ui_root="$runtime/ui"
mkdir -p "$runtime"
chmod 0755 "$runtime"
ui_generation_claim_root "$ui_root" || fail "could not claim the fresh UI generation root"

make_dist() { # make_dist <path> <label> <asset-name> <asset-bytes>
    local path="$1" label="$2" asset="$3" bytes="$4"
    mkdir -p "$path/assets" "$path/.vite"
    printf '<html>%s assets/%s</html>\n' "$label" "$asset" > "$path/index.html"
    printf '%s\n' "$bytes" > "$path/assets/$asset"
    cat > "$path/manifest.webmanifest" <<EOF
{"name":"${label}","icons":[{"src":"./pwa-192x192.png"},{"src":"./pwa-512x512.png"},{"src":"./pwa-maskable-192x192.png"},{"src":"./pwa-maskable-512x512.png"}]}
EOF
    printf 'worker-%s\n' "$label" > "$path/sw.js"
    printf 'register-%s\n' "$label" > "$path/registerSW.js"
    printf 'apple-%s\n' "$label" > "$path/apple-touch-icon.png"
    printf 'ico-%s\n' "$label" > "$path/favicon.ico"
    printf 'svg-%s\n' "$label" > "$path/favicon.svg"
    printf 'dark-%s\n' "$label" > "$path/favicon-dark.svg"
    printf 'icon-%s\n' "$label" > "$path/icon.svg"
    printf 'pwa-192-%s\n' "$label" > "$path/pwa-192x192.png"
    printf 'pwa-512-%s\n' "$label" > "$path/pwa-512x512.png"
    printf 'maskable-192-%s\n' "$label" > "$path/pwa-maskable-192x192.png"
    printf 'maskable-512-%s\n' "$label" > "$path/pwa-maskable-512x512.png"
    printf 'no-cache-%s\n' "$label" > "$path/pwa-no-cache.js"
    printf '{"entry":"assets/%s"}\n' "$asset" > "$path/.vite/manifest.json"
}

complete_candidate_profiles() {
    local candidate="$1" label="$2" dot_sha intercept_sha
    printf 'signed-dot-%s\n' "$label" > "$candidate/ios-dot.mobileconfig"
    printf 'signed-intercept-%s\n' "$label" > "$candidate/ios-intercept-ca.mobileconfig"
    dot_sha="$(sha256sum "$candidate/ios-dot.mobileconfig" | awk '{print $1}')"
    intercept_sha="$(sha256sum "$candidate/ios-intercept-ca.mobileconfig" | awk '{print $1}')"
    cat > "$candidate/.5gpn-profile-inputs" <<EOF
version=1
dot_signer_leaf_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dot_public_key_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
intercept_ca_der_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
domain=dot.example.test
gateway_ipv4=192.0.2.10
ios_dot_sha256=${dot_sha}
ios_intercept_ca_sha256=${intercept_sha}
EOF
}

dist_a="$TMP/dist-a"
make_dist "$dist_a" A app-aaaaaaaa.js asset-a
printf 'old-top-level\n' > "$dist_a/old-only.txt"
printf '<html>A assets/app-aaaaaaaa.js favicon.ico manifest.webmanifest registerSW.js sw.js</html>\n' \
    > "$dist_a/index.html"
candidate_a="$(ui_generation_stage_tree "$ui_root" "$dist_a" v1.0.0)" \
    || fail "could not stage generation A"
complete_candidate_profiles "$candidate_a" A
[[ ! -e "$ui_root/current" && ! -L "$ui_root/current" ]] \
    || fail "fresh staging exposed current before the complete first generation"
ui_generation_publish "$ui_root" "$candidate_a" || fail "could not publish generation A"
current_a="$(readlink -- "$ui_root/current")"
[[ "$current_a" == generations/generation-* ]] \
    || fail "current is not a relative safe generation target"
grep -Fq A "$ui_root/current/index.html" || fail "generation A index is not live"
pass "first complete generation becomes visible with one relative current pointer"

multiline_base_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not clone current for base-marker byte validation"
printf 'extra\n' >> "$multiline_base_candidate/.5gpn-ui-base-target"
if ui_generation_publish "$ui_root" "$multiline_base_candidate" >/dev/null 2>&1; then
    fail "a multiline candidate base marker was accepted"
fi
[[ "$(readlink -- "$ui_root/current")" == "$current_a" ]] \
    || fail "multiline base rejection changed current"
ui_generation_cleanup_candidate "$ui_root" "$multiline_base_candidate" \
    || fail "multiline base rejection left an uncleanable candidate"
pass "candidate base marker is one exact line before publication mutates it"

incomplete_profile_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not clone current for incomplete-profile validation"
rm -f -- "$incomplete_profile_candidate/ios-intercept-ca.mobileconfig"
incomplete_before="$(tree_fingerprint "$incomplete_profile_candidate")" \
    || fail "could not fingerprint incomplete profile candidate"
if ui_generation_publish "$ui_root" "$incomplete_profile_candidate" >/dev/null 2>&1; then
    fail "an incomplete profile generation was accepted"
fi
incomplete_after="$(tree_fingerprint "$incomplete_profile_candidate")" \
    || fail "could not fingerprint rejected incomplete profile candidate"
[[ "$incomplete_after" == "$incomplete_before" ]] \
    || fail "incomplete profile rejection mutated candidate bytes or metadata"
[[ "$(readlink -- "$ui_root/current")" == "$current_a" ]] \
    || fail "incomplete profile rejection changed current"
[[ -f "$incomplete_profile_candidate/.5gpn-ui-base-target" \
   && ! -L "$incomplete_profile_candidate/.5gpn-ui-base-target" \
   && "$(_ui_generation_mode "$incomplete_profile_candidate/.5gpn-ui-base-target")" == 600 ]] \
    || fail "incomplete profile rejection mutated the private base marker"
ui_generation_cleanup_candidate "$ui_root" "$incomplete_profile_candidate" \
    || fail "incomplete profile rejection left an uncleanable candidate"
pass "incomplete profiles fail before candidate mutation and remain safely cleanable"

cli_helper="$TMP/ui-generation-cli.sh"
awk -v root="$ui_root" '
    NR == 1 { print; print "od() { return 42; }"; next }
    /^UI_GENERATION_ROOT=/ { print "UI_GENERATION_ROOT=\"" root "\""; next }
    { print }
' "$ROOT/scripts/ui-generation.sh" > "$cli_helper"
chmod 0755 "$cli_helper"
if bash "$cli_helper" validate-current >/dev/null 2>&1; then
    fail "validate-current ignored an od producer failure in the strict profile-manifest byte gate"
fi
pass "validate-current propagates profile-manifest byte producer failures"

ln -s "$current_a" "$ui_root/.current.new.999.1"
ui_generation_preflight "$ui_root" \
    || fail "read-only preflight rejected a safe interrupted current-link candidate"
[[ "$(readlink -- "$ui_root/current")" == "$current_a" ]] \
    || fail "orphan-link preflight changed current"
ui_generation_claim_root "$ui_root" \
    || fail "claim could not clean a safe interrupted current-link candidate"
[[ ! -e "$ui_root/.current.new.999.1" && ! -L "$ui_root/.current.new.999.1" ]] \
    || fail "safe interrupted current-link candidate was not removed under the claim boundary"
ln -s /tmp "$ui_root/.current.new.999.2"
if ui_generation_preflight "$ui_root" >/dev/null 2>&1; then
    fail "unsafe interrupted current-link target was accepted"
fi
rm -f "$ui_root/.current.new.999.2"
pass "safe SIGKILL link residue converges while unsafe residue fails closed"

unreachable="$ui_root/generations/generation-20260101T000000Z-1-ABCDEF"
mkdir "$unreachable"
printf 'corrupt and unreachable\n' > "$unreachable/file"
_ui_generation_current_only_is_safe "$ui_root" \
    || fail "current-only startup validation was amplified by an unreachable old generation"
if ui_generation_preflight "$ui_root" >/dev/null 2>&1; then
    fail "write-transaction preflight accepted an unsafe unreachable generation"
fi
rm -rf -- "$unreachable"
pass "startup validates only current while write transactions retain full-tree safety"

dist_b="$TMP/dist-b"
make_dist "$dist_b" B app-bbbbbbbb.js asset-b
candidate_b="$(ui_generation_stage_tree "$ui_root" "$dist_b" v2.0.0)" \
    || fail "could not stage generation B"
complete_candidate_profiles "$candidate_b" B
[[ "$(readlink -- "$ui_root/current")" == "$current_a" ]] \
    && grep -Fq A "$ui_root/current/index.html" \
    || fail "staging generation B changed the live generation"

# Simulate a browser that fetched A's index immediately before the switch and
# requests its mutually exclusive hashed asset immediately afterwards.
old_asset=assets/app-aaaaaaaa.js
grep -Fq "$old_asset" "$ui_root/current/index.html" \
    || fail "generation A fixture does not name its A-only asset"
ui_generation_publish "$ui_root" "$candidate_b" || fail "could not publish generation B"
grep -Fq B "$ui_root/current/index.html" || fail "generation B index is not live"
grep -Fxq asset-a "$ui_root/current/$old_asset" \
    || fail "old index crossed the switch into a missing or changed A asset"
grep -Fxq asset-b "$ui_root/current/assets/app-bbbbbbbb.js" \
    || fail "generation B primary asset is missing"
[[ ! -e "$ui_root/current/old-only.txt" ]] \
    || fail "old top-level files leaked into the new generation"
grep -Fq worker-B "$ui_root/current/sw.js" \
    || fail "the new generation did not own the top-level worker bytes"
for stable_path in apple-touch-icon.png favicon.ico favicon.svg favicon-dark.svg icon.svg \
                   pwa-192x192.png pwa-512x512.png \
                   pwa-maskable-192x192.png pwa-maskable-512x512.png \
                   manifest.webmanifest registerSW.js sw.js pwa-no-cache.js; do
    [[ -s "$ui_root/current/$stable_path" ]] \
        || fail "stable old-tab URL disappeared across the generation switch: $stable_path"
done
grep -Fq 'assets/app-bbbbbbbb.js' "$ui_root/current/.vite/manifest.json" \
    || fail "the new generation did not own mutable .vite metadata"
pass "A/B current switch retains prior hashed assets while all top-level bytes come from the new generation"

dist_missing_stable="$TMP/dist-missing-stable"
cp -a "$dist_b" "$dist_missing_stable"
rm -f "$dist_missing_stable/favicon.ico"
before_missing_stable="$(readlink -- "$ui_root/current")"
if ui_generation_stage_tree "$ui_root" "$dist_missing_stable" v2.0.1 >/dev/null 2>&1; then
    fail "new generation removed a stable old-tab URL"
fi
[[ "$(readlink -- "$ui_root/current")" == "$before_missing_stable" ]] \
    || fail "stable URL rejection changed current"
pass "stable top-level old-tab URLs cannot disappear across one generation switch"

dist_bad_manifest="$TMP/dist-bad-manifest"
cp -a "$dist_b" "$dist_bad_manifest"
printf '{"icons":[{"src":"../escape.png"}]}\n' > "$dist_bad_manifest/manifest.webmanifest"
if ui_generation_stage_tree "$ui_root" "$dist_bad_manifest" v2.0.2 >/dev/null 2>&1; then
    fail "web manifest with an unsafe icon path was accepted"
fi
pass "web manifest icon URLs stay relative, fixed, and present in the generation"

dist_conflict="$TMP/dist-conflict"
make_dist "$dist_conflict" C app-bbbbbbbb.js conflicting-b
before_conflict="$(readlink -- "$ui_root/current")"
if ui_generation_stage_tree "$ui_root" "$dist_conflict" v3.0.0 >/dev/null 2>&1; then
    fail "same asset path with different bytes was accepted"
fi
[[ "$(readlink -- "$ui_root/current")" == "$before_conflict" ]] \
    || fail "asset conflict changed current"
pass "same-path asset conflicts fail before publication"

profile_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not clone current for profile-only refresh"
complete_candidate_profiles "$profile_candidate" renewed
ui_generation_publish "$ui_root" "$profile_candidate" \
    || fail "could not publish profile-only cloned generation"
grep -Fq B "$ui_root/current/index.html" \
    && grep -Fxq signed-dot-renewed "$ui_root/current/ios-dot.mobileconfig" \
    || fail "profile-only refresh changed Console bytes or missed the new profile"
grep -Fq $'\tassets/app-bbbbbbbb.js' "$ui_root/current/.zash_primary_files" \
    || fail "current primary-asset manifest lost generation B"
grep -Fq $'\tassets/app-aaaaaaaa.js' "$ui_root/current/.zash_primary_files" \
    && fail "carried A asset entered B's primary manifest and would accumulate forever"
grep -Fq $'\tassets/app-aaaaaaaa.js' "$ui_root/current/.zash_compat_files" \
    || fail "immediately previous A asset is absent from B's compatibility manifest"
grep -Fq $'\tassets/app-bbbbbbbb.js' "$ui_root/current/.zash_compat_files" \
    && fail "generation B primary asset overlaps its compatibility manifest"
generation_count="$(find "$ui_root/generations" -mindepth 1 -maxdepth 1 -type d \
    -name 'generation-*' | wc -l | tr -d '[:space:]')"
[[ "$generation_count" == 2 ]] \
    || fail "successful publication retained $generation_count generations instead of current+previous"
pass "profile-only refresh clones current and retention stays bounded"

gc_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare post-commit GC failure candidate"
complete_candidate_profiles "$gc_candidate" gc-warning
original_gc_function="$(declare -f _ui_generation_cleanup_after_publish)"
_ui_generation_cleanup_after_publish() { return 1; }
before_gc_warning="$(readlink -- "$ui_root/current")"
ui_generation_publish "$ui_root" "$gc_candidate" \
    || fail "post-commit GC failure incorrectly failed publication"
eval "$original_gc_function"
[[ "$UI_GENERATION_COMMIT_STATE" == committed && "$UI_GENERATION_GC_WARNING" == 1 \
   && "$(readlink -- "$ui_root/current")" != "$before_gc_warning" ]] \
    || fail "GC failure did not preserve the committed current with a warning"
pass "post-commit GC failure is warning-only after a durable current switch"

sync_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare root-sync failure candidate"
complete_candidate_profiles "$sync_candidate" sync-failure
REAL_SYNC="$(command -v sync)"
SYNC_UI_ROOT="$ui_root"
sync() {
    if [[ "${FAIL_UI_ROOT_SYNC:-0}" == 1 && "$*" == "-f $SYNC_UI_ROOT" ]]; then
        return 1
    fi
    "$REAL_SYNC" "$@"
}
before_sync_failure="$(readlink -- "$ui_root/current")"
FAIL_UI_ROOT_SYNC=1
if ui_generation_publish "$ui_root" "$sync_candidate" >/dev/null 2>&1; then
    fail "UI root sync failure was accepted as durable success"
fi
unset -f sync
[[ "$UI_GENERATION_COMMIT_STATE" == committed-undurable \
   && "$(readlink -- "$ui_root/current")" != "$before_sync_failure" ]] \
    || fail "root sync failure rolled back or hid the already committed current switch"
pass "post-rename root sync failure reports committed-but-undurable without rollback"

stable_current="$(readlink -- "$ui_root/current")"
switch_target="$(find "$ui_root/generations" -mindepth 1 -maxdepth 1 -type d \
    -name 'generation-*' ! -path "$ui_root/$stable_current" -printf 'generations/%f\n' -quit)"
[[ -n "$switch_target" ]] || fail "CAS fixture has no previous generation"
cas_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare current-CAS candidate"
complete_candidate_profiles "$cas_candidate" cas
_ui_generation_before_current_commit() {
    [[ "$1" == "$ui_root" && -L "$2" ]] || return 1
    rm -f -- "$ui_root/current"
    ln -s -- "$switch_target" "$ui_root/current"
}
if ui_generation_publish "$ui_root" "$cas_candidate" >/dev/null 2>&1; then
    fail "current drift immediately before the pointer rename was accepted"
fi
_ui_generation_before_current_commit() { :; }
[[ "$(readlink -- "$ui_root/current")" == "$switch_target" ]] \
    || fail "CAS rejection overwrote the concurrent current target"
find "$ui_root" -maxdepth 1 -name '.current.new.*' -print -quit | grep -q . \
    && fail "CAS rejection left its temporary current symlink"
rm -f "$ui_root/current"
ln -s "$stable_current" "$ui_root/current"
pass "final current recheck rejects a concurrent switch without overwriting it"

transient_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare transient-file rejection fixture"
mkdir "$transient_candidate/.ios-profile.leftover"
if ui_generation_publish "$ui_root" "$transient_candidate" >/dev/null 2>&1; then
    fail "profile-signing transaction residue was accepted as a complete generation"
fi
ui_generation_cleanup_candidate "$ui_root" "$transient_candidate" \
    || fail "could not clean the ownership-proven transient candidate"
pass "profile transaction residue blocks publication and remains safely cleanable"

manifest_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare profile-manifest rejection fixture"
printf 'unknown=value\n' >> "$manifest_candidate/.5gpn-profile-inputs"
if ui_generation_publish "$ui_root" "$manifest_candidate" >/dev/null 2>&1; then
    fail "profile-input manifest with an unknown key was accepted"
fi
ui_generation_cleanup_candidate "$ui_root" "$manifest_candidate" \
    || fail "could not clean invalid profile-manifest candidate"
pass "profile-input manifest enforces its exact key set"

nul_manifest_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare profile-manifest byte rejection fixture"
printf '\0' >> "$nul_manifest_candidate/.5gpn-profile-inputs"
if ui_generation_publish "$ui_root" "$nul_manifest_candidate" >/dev/null 2>&1; then
    fail "profile-input manifest with a trailing NUL was accepted"
fi
ui_generation_cleanup_candidate "$ui_root" "$nul_manifest_candidate" \
    || fail "could not clean NUL profile-manifest candidate"
pass "profile-input manifest rejects control bytes that Bash mapfile could discard"

hardlink_dist="$TMP/dist-hardlink"
make_dist "$hardlink_dist" H app-hhhhhhhh.js hardlink
ln "$hardlink_dist/assets/app-hhhhhhhh.js" "$TMP/hardlink-alias"
if ui_generation_stage_tree "$ui_root" "$hardlink_dist" v4.0.0 >/dev/null 2>&1; then
    fail "hardlinked source asset was accepted"
fi
rm -f "$TMP/hardlink-alias"
pass "hardlinked source assets fail closed"

marker_candidate="$(ui_generation_clone_current "$ui_root")" \
    || fail "could not prepare candidate-marker fixture"
rm -f "$marker_candidate/$UI_GENERATION_ENTRY_MARKER"
if ui_generation_cleanup_candidate "$ui_root" "$marker_candidate" >/dev/null 2>&1; then
    fail "recursive candidate deletion accepted a missing generation marker"
fi
[[ -d "$marker_candidate" ]] || fail "unmarked candidate was partially deleted"
printf '%s\n' "$UI_GENERATION_ENTRY_MARKER_VALUE" \
    > "$marker_candidate/$UI_GENERATION_ENTRY_MARKER"
chmod 0644 "$marker_candidate/$UI_GENERATION_ENTRY_MARKER"
ui_generation_cleanup_candidate "$ui_root" "$marker_candidate" \
    || fail "restored ownership-proven candidate could not be removed"
pass "every recursive generation deletion requires its own marker"

flat_root="$TMP/flat/ui"
mkdir -p "$flat_root"
chmod 0755 "$TMP/flat" "$flat_root"
printf '5gpn-zashboard\n' > "$flat_root/.5gpn-zashboard-owned"
printf 'flat\n' > "$flat_root/index.html"
chmod 0644 "$flat_root/.5gpn-zashboard-owned" "$flat_root/index.html"
if ui_generation_preflight "$flat_root" >/dev/null 2>&1; then
    fail "retired flat UI tree was accepted as current schema"
fi
pass "retired flat UI schema is read-only rejected"

safe_target="$(readlink -- "$ui_root/current")"
rm -f "$ui_root/current"
ln -s /tmp "$ui_root/current"
if ui_generation_remove_root "$ui_root" >/dev/null 2>&1; then
    fail "unsafe absolute current was accepted for recursive uninstall"
fi
[[ -d "$ui_root/generations" ]] \
    || fail "unsafe current caused generation deletion before validation"
rm -f "$ui_root/current"
ln -s "$safe_target" "$ui_root/current"
ui_generation_remove_root "$ui_root" || fail "validated generation root could not be removed"
[[ ! -e "$ui_root" && ! -L "$ui_root" ]] || fail "UI generation root remains after safe removal"
pass "uninstall validates current and per-generation markers before deletion"

echo "all UI generation tests passed"
