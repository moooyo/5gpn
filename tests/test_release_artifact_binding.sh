#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
RELEASE="$ROOT/.github/workflows/release.yml"
PIN_VERIFY="$ROOT/tests/verify-artifact-pins.sh"
PINS_ENV="$ROOT/release/pins.env"
PINS_LIBRARY="$ROOT/release/pins.sh"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d /var/tmp/5gpn-release-binding.XXXXXX)"
claim_temp_dir "$TMP" || { echo "FAIL: could not claim test directory"; exit 1; }
trap 'remove_temp_dir "$TMP" >/dev/null 2>&1 || true' EXIT
ARTIFACT_STAGE="$TMP/stage"
mkdir "$ARTIFACT_STAGE"

FAKE_BIN="$TMP/fake-version"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s" "${FAKE_STDOUT-}"' \
    'exit "${FAKE_RC-0}"' > "$FAKE_BIN"
chmod +x "$FAKE_BIN"

expect_mihomo_accept() {
    local name="$1" output="$2"
    export FAKE_STDOUT="$output" FAKE_RC=0
    if mihomo_reports_exact_version "$FAKE_BIN" v1.19.28; then
        pass "$name"
    else
        fail "$name"
    fi
}

expect_mihomo_reject() {
    local name="$1" output="$2"
    export FAKE_STDOUT="$output" FAKE_RC=0
    if mihomo_reports_exact_version "$FAKE_BIN" v1.19.28; then
        fail "$name"
    else
        pass "$name"
    fi
}

expect_mihomo_accept "exact mihomo version token is accepted" \
    $'Mihomo Meta v1.19.28 linux amd64 with go1.26.5 Wed Jul  8 00:22:48 UTC 2026\nUse tags: with_gvisor\n'
expect_mihomo_reject "wrong mihomo version token is rejected" \
    $'Mihomo Meta v1.19.27 linux amd64 with go1.26.5 Wed Jul  8 00:22:48 UTC 2026\nUse tags: with_gvisor\n'
expect_mihomo_reject "mihomo version suffix is rejected" \
    $'Mihomo Meta v1.19.28-tampered linux amd64 with go1.26.5 Wed Jul  8 00:22:48 UTC 2026\n'
expect_mihomo_reject "malformed mihomo version output is rejected" $'v1.19.28\n'

NUL_MIHOMO="$TMP/fake-mihomo-version-nul"
printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'Mihomo Meta v1.19.28\\000-tampered linux amd64 with go1.26.5 build\\n'" > "$NUL_MIHOMO"
chmod +x "$NUL_MIHOMO"
if mihomo_reports_exact_version "$NUL_MIHOMO" v1.19.28; then
    fail "NUL-bearing mihomo version is rejected"
else
    pass "NUL-bearing mihomo version is rejected"
fi

# The invariant under test is that no staged executable reaches publication
# unversioned. There is one staged executable now.
stage_fn="$(sed -n '/^stage_artifacts()/,/^}/p' "$INSTALL")"
grep -Fq 'mihomo_controller_inspection "$controller_inspection_target"' <<<"$stage_fn" \
    || fail "staged mihomo is not probed for the managed controller inspector contract"
grep -Fq '5gpn-state validate' <<<"$stage_fn" \
    && grep -Fq -- '--owner-uid "$(id -u)"' <<<"$stage_fn" \
    || fail "staged mihomo is not probed for the owner-bound state validator contract"
if grep -Fq 'mihomo_reports_exact_version "$ARTIFACT_STAGE/mihomo" "$MIHOMO_VERSION"' <<<"$stage_fn"; then
    pass "all staged executables are wired to exact version checks"
else
    fail "a staged executable bypasses exact version checks"
fi

for publisher in install_mihomo; do
    if (
        cp "$FAKE_BIN" "$ARTIFACT_STAGE/mihomo"
        chmod +x "$ARTIFACT_STAGE/mihomo"
        MIHOMO_BIN=/bin/true
        publish_executable() { return 77; }
        "$publisher" >/dev/null 2>&1
    ); then
        fail "$publisher propagates executable publication failure"
    else
        pass "$publisher propagates executable publication failure"
    fi
done
# Nothing is drawn from the 5gpn release itself any more, so there is no
# checksums.txt fetch and no per-release asset to bind. What must stay true is
# that the release still carries no unbound artifact: assert the retired console
# SPA has not returned to either side of the boundary.
if grep -Eq 'checksums\.txt|5gpn-web-' <<<"$stage_fn"; then
    fail "staging fetches a 5gpn release asset again"
else
    pass "staging draws nothing from the 5gpn release"
fi
if grep -Fq '5gpn-web-${VER}.tar.gz' "$RELEASE"; then
    fail "release workflow still packages the retired console SPA"
else
    pass "release workflow no longer packages the retired console SPA"
fi

if grep -Fq 'README.en.md' "$RELEASE" \
   && grep -Fq 'release/pins.env' "$RELEASE" \
   && grep -Fq 'release/pins.sh' "$RELEASE" \
   && grep -Fq 'docs/architecture.md' "$RELEASE" \
   && grep -Fq 'docs/native-extensions.md' "$RELEASE" \
   && grep -Fq 'tests/integration-smoke.md' "$RELEASE" \
   && grep -Fq 'tests/deployment-smoke.md' "$RELEASE" \
   && grep -Fq 'tests/acceptance/installer.md' "$RELEASE" \
   && grep -Fq 'tests/acceptance/disruption-recovery.md' "$RELEASE"; then
    pass "installer bundle retains centralized pins, both README languages, and linked operator runbooks"
else
    fail "installer bundle omits a README language or linked operator runbook"
fi

# --- pinned third-party artifacts -------------------------------------------
#
# Each pin is a version and the digest of the asset that version publishes.
# Whether the digest is the RIGHT one needs the network and lives in
# tests/verify-artifact-pins.sh; what can be checked offline is that every pin
# is complete, well-formed, and actually verified before the artifact is used.
CHECKS="$ROOT/.github/workflows/checks.yml"
capture_call_line="$(grep -n '^capture_release_pin_pair "\$RELEASE_PINS_BUNDLE_DIR"' "$INSTALL" | cut -d: -f1)"
source_call_line="$(grep -n '^if ! source "\$RELEASE_PINS_LIBRARY"' "$INSTALL" | cut -d: -f1)"
if grep -Fq 'RELEASE_PINS_BUNDLE_DIR="${SCRIPT_DIR}/release"' "$INSTALL" \
   && grep -Fq 'RELEASE_PINS_BINDING="development"' "$INSTALL" \
   && grep -Fq '"${RELEASE_PINS_ENV_REVISION}:${RELEASE_PINS_LIBRARY_REVISION}"' "$INSTALL" \
   && [[ -n "$capture_call_line" && -n "$source_call_line" \
      && "$capture_call_line" -lt "$source_call_line" ]] \
   && grep -Fq 'source "$RELEASE_PINS_LIBRARY"' "$INSTALL" \
   && grep -Fq 'load_release_pins "$RELEASE_PINS_ENV"' "$INSTALL" \
   && grep -Fq 'RELEASE_PINS_ENV_SNAPSHOT_B64=' "$INSTALL" \
   && grep -Fq 'RELEASE_PINS_LIBRARY_SNAPSHOT_B64=' "$INSTALL"; then
    pass "installer captures one private pin pair before it sources or parses either file"
else
    fail "installer does not bind source and parsed bytes to one private pin snapshot"
fi
if grep -Fq 'pins_env_sha="$(sha256sum "$stage/release/pins.env"' "$RELEASE" \
   && grep -Fq 'pins_library_sha="$(sha256sum "$stage/release/pins.sh"' "$RELEASE" \
   && grep -Fq 'quick_sha="$(sha256sum "$stage/quick-install.sh"' "$RELEASE" \
   && grep -Fq 'RELEASE_PINS_BINDING=\"${pins_binding}\"' "$RELEASE" \
   && grep -Fq 'RELEASE_QUICK_BINDING=\"${quick_sha}\"' "$RELEASE"; then
    pass "release packaging stamps derived installer-to-pin and quick generation bindings"
else
    fail "release packaging does not bind install.sh to its exact pin pair"
fi
install_pins_fn="$(sed -n '/^install_release_pin_files()/,/^}/p' "$INSTALL")"
if grep -Fq '"${RELEASE_DIR}/pins.env"' "$INSTALL" \
   && grep -Fq '"${RELEASE_DIR}/pins.sh"' "$INSTALL" \
   && grep -Fq 'RELEASE_PINS_ENV_SNAPSHOT_B64' <<<"$install_pins_fn" \
   && grep -Fq 'RELEASE_PINS_LIBRARY_SNAPSHOT_B64' <<<"$install_pins_fn" \
   && grep -Fq 'base64 -d > "$candidate"' <<<"$install_pins_fn" \
   && grep -Fq 'RELEASE_PINS_ENV_REVISION' <<<"$install_pins_fn" \
   && grep -Fq 'RELEASE_PINS_LIBRARY_REVISION' <<<"$install_pins_fn" \
   && grep -Fq 'root_plain_file_metadata_is_safe "$destination" 0 644' <<<"$install_pins_fn" \
   && grep -Fq 'sync -f "$RELEASE_DIR"' <<<"$install_pins_fn" \
   && ! grep -Fq 'assert_release_pin_bundle_revision' <<<"$install_pins_fn" \
   && ! grep -Fq 'RELEASE_PINS_BUNDLE_DIR' <<<"$install_pins_fn"; then
    pass "post-boundary publication materializes and verifies only the bound in-memory snapshots"
else
    fail "installed release-pin publication reopens source bytes or omits snapshot verification"
fi

full_install_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
mapfile -t pin_gate_lines < <(grep -n 'assert_release_pin_bundle_revision' <<<"$full_install_fn" | cut -d: -f1)
mapfile -t runtime_slot_lines < <(grep -n 'preflight_runtime_publication_paths 1' <<<"$full_install_fn" | cut -d: -f1)
mapfile -t quick_gate_lines < <(grep -n 'validate_quick_installer_generation' <<<"$full_install_fn" | cut -d: -f1)
gum_line="$(grep -n '^[[:space:]]*install_gum$' <<<"$full_install_fn" | head -n 1 | cut -d: -f1)"
stage_line="$(grep -n '^[[:space:]]*stage_artifacts$' <<<"$full_install_fn" | head -n 1 | cut -d: -f1)"
publication_line="$(grep -n 'INSTALL_PUBLICATION_STARTED=1' <<<"$full_install_fn" | head -n 1 | cut -d: -f1)"
if ((${#pin_gate_lines[@]} >= 2)) \
   && ((${#runtime_slot_lines[@]} == 2)) \
   && ((${#quick_gate_lines[@]} == 2)) \
   && [[ -n "$gum_line" && -n "$stage_line" && -n "$publication_line" \
      && "${pin_gate_lines[0]}" -lt "$gum_line" \
      && "${pin_gate_lines[-1]}" -lt "$publication_line" \
      && "${pin_gate_lines[-1]}" -gt "$stage_line" \
      && "${runtime_slot_lines[0]}" -lt "$gum_line" \
      && "${runtime_slot_lines[-1]}" -lt "${pin_gate_lines[-1]}" \
      && "${quick_gate_lines[0]}" -lt "$gum_line" \
      && "${quick_gate_lines[-1]}" -gt "$stage_line" \
      && "${quick_gate_lines[-1]}" -lt "$publication_line" ]]; then
    pass "pin identity and installed slots are rechecked before downloads and publication"
else
    fail "release pin gates do not close both pre-download and pre-publication windows"
fi

for guarded_function in run_management_with_install_lock run_management_with_install_and_cert_lock full_install uninstall; do
    guarded_body="$(sed -n "/^${guarded_function}()/,/^}/p" "$INSTALL")"
    lock_line="$(grep -n 'acquire_install_lock' <<<"$guarded_body" | head -n 1 | cut -d: -f1)"
    stale_line="$(grep -n 'assert_installed_backend_revision' <<<"$guarded_body" | head -n 1 | cut -d: -f1)"
    gate_line="$(grep -n 'refuse_retained_configure_runtime_gate_state' <<<"$guarded_body" | head -n 1 | cut -d: -f1)"
    case "$guarded_function" in
        run_management_with_install_lock)
            mutation_line="$(grep -n '^[[:space:]]*"\$@"$' <<<"$guarded_body" | head -n 1 | cut -d: -f1)" ;;
        run_management_with_install_and_cert_lock)
            mutation_line="$(grep -n 'acquire_install_cert_lock' <<<"$guarded_body" | head -n 1 | cut -d: -f1)" ;;
        full_install)
            mutation_line="$(grep -n 'delegate_pinned_channel_switch' <<<"$guarded_body" | head -n 1 | cut -d: -f1)" ;;
        uninstall)
            mutation_line="$(grep -n 'claim_project_roots' <<<"$guarded_body" | head -n 1 | cut -d: -f1)" ;;
    esac
    [[ -n "$lock_line" && -n "$stale_line" && -n "$gate_line" && -n "$mutation_line" \
       && "$lock_line" -lt "$stale_line" \
       && "$stale_line" -lt "$gate_line" \
       && "$gate_line" -lt "$mutation_line" ]] \
        || fail "$guarded_function does not reject stale backend or retained gate state before mutation"
done
management_guard_body="$(sed -n '/^run_management_with_install_lock()/,/^}/p' "$INSTALL")"
grep -Fq '[[ "${1:-}" != configure_installation ]]' <<<"$management_guard_body" \
    || fail "the configure recovery entry is blocked by the retained-gate refusal"
pass "every non-configure write entry rejects retained runtime-gate state before mutation"
main_fn="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
manage_action_fn="$(sed -n '/^manage_action()/,/^}/p' "$INSTALL")"
if grep -Fq 'run_management_with_install_lock configure_installation' <<<"$main_fn" \
   && grep -Fq 'run_management_with_install_lock configure_installation' <<<"$manage_action_fn"; then
    pass "CLI and menu configure reach the locked stale-backend guard"
else
    fail "configure can bypass the post-lock installed-backend revision check"
fi
backend_guard_fn="$(sed -n '/^assert_installed_backend_revision()/,/^}/p' "$INSTALL")"
if ! grep -Fq 'RELEASE_QUICK' <<<"$backend_guard_fn"; then
    pass "ordinary management stale checks do not amplify a quick-installer fault"
else
    fail "ordinary management is incorrectly coupled to quick-installer health"
fi
stale_line="$(grep -n 'assert_installed_backend_revision' <<<"$full_install_fn" | head -n 1 | cut -d: -f1)"
channel_line="$(grep -n 'delegate_pinned_channel_switch' <<<"$full_install_fn" | head -n 1 | cut -d: -f1)"
[[ -n "$stale_line" && -n "$channel_line" && "$stale_line" -lt "$channel_line" ]] \
    || fail "installed channel delegation can bypass the locked stale-backend guard"
manage_menu_fn="$(sed -n '/^manage_menu()/,/^}/p' "$INSTALL")"
if grep -Fq 'run_management_with_install_lock install_gum_for_managed_deployment' <<<"$manage_menu_fn" \
   && ! grep -Fq 'load_identity_reconcile_journal' <<<"$manage_menu_fn"; then
    pass "management menu reaches the locked stale-backend guard before runtime-state reads"
else
    fail "management menu reads identity state before its stale-backend guard"
fi

for component in mihomo zashboard; do
    case "$component" in
        mihomo) archive=mihomo.gz; sha_var=mihomo_sha ;;
        zashboard) archive=zash.zip; sha_var=zash_sha ;;
    esac
    if grep -Fq "release_asset_name $component" <<<"$stage_fn" \
       && grep -Fq "release_download_url $component" <<<"$stage_fn" \
       && grep -Fq "release_artifact_sha256 $component" <<<"$stage_fn" \
       && grep -Fq "verify_sha256 \"\$ARTIFACT_STAGE/$archive\" \"\$$sha_var\"" <<<"$stage_fn"; then
        pass "$component stages through the shared asset, URL, and digest builders"
    else
        fail "$component bypasses centralized release-coordinate construction"
    fi
done

NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
mihomo_notice="$(grep -F '| 5gpn mihomo fork |' "$NOTICES" || true)"
zash_notice="$(grep -F '| zashboard fork |' "$NOTICES" || true)"
gum_notice="$(grep -F '| [Charmbracelet Gum]' "$NOTICES" || true)"
if [[ "$(grep -Fc '| 5gpn mihomo fork |' "$NOTICES")" == 1 \
   && "$mihomo_notice" == *"$MIHOMO_REPO"* \
   && "$mihomo_notice" == *"$MIHOMO_VERSION"* \
   && "$mihomo_notice" == *"$(release_asset_name mihomo)"* \
   && "$mihomo_notice" == *"$MIHOMO_SHA256"* \
   && "$(grep -Fc '| zashboard fork |' "$NOTICES")" == 1 \
   && "$zash_notice" == *"$ZASH_REPO"* \
   && "$zash_notice" == *"$ZASH_VERSION"* \
   && "$zash_notice" == *"$(release_asset_name zashboard)"* \
   && "$zash_notice" == *"$ZASH_SHA256"* \
   && "$(grep -Fc '| [Charmbracelet Gum]' "$NOTICES")" == 1 \
   && "$gum_notice" == *"$GUM_REPO"* \
   && "$gum_notice" == *"$GUM_VERSION"* \
   && "$gum_notice" == *"$(release_asset_name gum x86_64)"* \
   && "$gum_notice" == *"$GUM_SHA256_X86_64"* \
   && "$gum_notice" == *"$(release_asset_name gum arm64)"* \
   && "$gum_notice" == *"$GUM_SHA256_ARM64"* \
   && "$gum_notice" == *"$(release_asset_name gum armv7)"* \
   && "$gum_notice" == *"$GUM_SHA256_ARMV7"* ]]; then
    pass "each third-party notice row binds the matching centralized coordinate tuple"
else
    fail "a third-party notice row drifted or mixed centralized coordinates"
fi

# Gum is optional only in the sense that a bootstrap failure falls back to plain
# output. It is still a root-installed release artifact when available. Lock all
# three uname-to-release mappings and require the network verifier to bind each
# corresponding tarball to the digest read from release/pins.env.
install_gum_fn="$(sed -n '/^install_gum()/,/^}/p' "$INSTALL")"
if grep -Fq 'x86_64|amd64)  arch="x86_64"' <<<"$install_gum_fn" \
   && grep -Fq 'aarch64|arm64) arch="arm64"' <<<"$install_gum_fn" \
   && grep -Fq 'armv7l|armhf)  arch="armv7"' <<<"$install_gum_fn" \
   && grep -Fq 'release_asset_name gum "$arch"' <<<"$install_gum_fn" \
   && grep -Fq 'release_download_url gum "$arch"' <<<"$install_gum_fn" \
   && grep -Fq 'release_artifact_sha256 gum "$arch"' <<<"$install_gum_fn"; then
    pass "Gum uname aliases map to the three pinned release architectures"
else
    fail "Gum architecture mapping or release URL drifted from its pins"
fi

if grep -Fq 'source "$PINS_LIBRARY"' "$PIN_VERIFY" \
   && grep -Fq 'load_release_pins "$PINS_ENV"' "$PIN_VERIFY" \
   && ! grep -Fq 'source "$ROOT/install.sh"' "$PIN_VERIFY" \
   && grep -Fq 'release_asset_name mihomo' "$PIN_VERIFY" \
   && grep -Fq 'release_download_url mihomo' "$PIN_VERIFY" \
   && grep -Fq 'release_asset_name zashboard' "$PIN_VERIFY" \
   && grep -Fq 'release_download_url zashboard' "$PIN_VERIFY" \
   && grep -Fq 'release_download_url gum "$arch"' "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release x86_64' "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release arm64' "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release armv7' "$PIN_VERIFY"; then
    pass "network pin verification covers every Gum release architecture"
else
    fail "network pin verification omits or misroutes a Gum release architecture"
fi

gum_verify_fn="$(sed -n '/^check_gum_release()/,/^}/p' "$PIN_VERIFY")"
if (
    eval "$gum_verify_fn"
    FAIL=0
    GUM_VERSION=test
    fail() { FAIL=1; }
    check() { return 0; }
    release_asset_name() { return 1; }
    release_artifact_sha256() { printf '%064d\n' 0; }
    release_download_url() { printf 'https://example.invalid/gum\n'; }
    check_gum_release arm64 >/dev/null 2>&1 || true
    [[ "$FAIL" == 1 ]]
); then
    pass "a Gum builder failure makes the network verifier fail"
else
    fail "the network verifier can silently skip a Gum architecture"
fi

for digest in GUM_SHA256_X86_64 GUM_SHA256_ARM64 GUM_SHA256_ARMV7; do
    if [[ "${!digest-}" =~ ^[0-9a-f]{64}$ ]]; then
        pass "$digest is a complete lowercase SHA-256"
    else
        fail "$digest is missing or malformed"
    fi
done

# CI must parse the same manifest and use the same closed builder. It must not
# carry another complete tag, digest, or hand-built component URL.
if grep -Fq 'source release/pins.sh' "$CHECKS" \
   && grep -Fq 'load_release_pins release/pins.env' "$CHECKS" \
   && grep -Fq 'release_asset_name mihomo' "$CHECKS" \
   && grep -Fq 'release_download_url mihomo' "$CHECKS" \
   && grep -Fq 'release_artifact_sha256 mihomo' "$CHECKS" \
   && ! grep -Eq '^[[:space:]]+MIHOMO_(REPO|VERSION|SHA256):' "$CHECKS"; then
    pass "checks.yml parses and consumes the centralized mihomo pin"
else
    fail "checks.yml duplicates or bypasses the centralized mihomo pin"
fi

for authoritative_value in \
    "$MIHOMO_VERSION" "$MIHOMO_SHA256" \
    "$ZASH_VERSION" "$ZASH_SHA256" "$GUM_VERSION" \
    "$GUM_SHA256_X86_64" "$GUM_SHA256_ARM64" "$GUM_SHA256_ARMV7"; do
    mapfile -t value_files < <(grep -RIlF --exclude-dir=.git -- "$authoritative_value" "$ROOT" 2>/dev/null || true)
    for value_file in "${value_files[@]}"; do
        case "$value_file" in
            "$PINS_ENV"|"$NOTICES") ;;
            *) fail "a repository file duplicates a complete release value outside the manifest/notices projection: $value_file" ;;
        esac
    done
done

if grep -Fq 'release/pins.env' "$ROOT/tests/acceptance/installer.md" \
   && grep -Fq '/opt/5gpn/release/{pins.env,pins.sh}' "$ROOT/tests/acceptance/installer.md" \
   && grep -Fq 'release-pin manifest digest' "$ROOT/tests/acceptance/disruption-recovery.md" \
   && grep -Fq '/opt/5gpn/install.sh' "$ROOT/tests/deployment-smoke.md" \
   && grep -Fq '/opt/5gpn/bin/5gpn-mihomo -v' "$ROOT/tests/deployment-smoke.md" \
   && grep -Fq '/opt/5gpn/ui/current/.zash_version' "$ROOT/tests/deployment-smoke.md"; then
    pass "packaged root acceptance runbooks retain the installed release-pin evidence boundary"
else
    fail "a packaged root acceptance runbook omits its installed release-pin evidence"
fi

if grep -Fq '/tmp/mihomo 5gpn-state validate --owner-uid' "$CHECKS" \
   && grep -Fq '.validated | sort' "$CHECKS"; then
    pass "CI executes the shipped core state validator against current documents"
else
    fail "CI does not execute the pinned core state validator"
fi
for fixture in missing malformed wrong-owner wrong-mode symlink hardlink; do
    grep -Fq "$fixture" "$CHECKS" \
        || fail "CI state-validator gate lacks the real $fixture fixture"
done

controller_negative_line="$(grep -n 'if /tmp/mihomo 5gpn-config inspect-controller' "$CHECKS" | cut -d: -f1)"
controller_revision_line="$(grep -n 'expected_revision="$(sha256sum "$runtime/config.yaml"' "$CHECKS" | cut -d: -f1)"
controller_chown_line="$(grep -n 'sudo chown root:root "$runtime/config.yaml"' "$CHECKS" | cut -d: -f1)"
controller_root_line="$(grep -n 'sudo /tmp/mihomo 5gpn-config inspect-controller' "$CHECKS" | cut -d: -f1)"
if grep -Fq '5gpn-config inspect-controller --config "$runtime/config.yaml"' "$CHECKS" \
   && grep -Fq '.version == 2' "$CHECKS" \
   && grep -Fq 'external_ui' "$CHECKS" \
   && grep -Fq 'private_key' "$CHECKS" \
   && grep -Fq 'sudo chown root:root "$runtime/config.yaml"' "$CHECKS" \
   && grep -Fq 'sudo chmod 0640 "$runtime/config.yaml"' "$CHECKS" \
   && [[ -n "$controller_negative_line" && -n "$controller_revision_line" \
      && -n "$controller_chown_line" && -n "$controller_root_line" \
      && "$controller_negative_line" -lt "$controller_revision_line" \
      && "$controller_revision_line" -lt "$controller_chown_line" \
      && "$controller_chown_line" -lt "$controller_root_line" ]]; then
    pass "CI executes the shipped root-only controller inspector v2 contract"
else
    fail "CI does not execute the exact pinned controller inspector contract"
fi

if grep -Fq 'sudo bash tests/test_configure_runtime_gate.sh' "$CHECKS" \
   && grep -Fq 'sudo bash tests/test_configure_boundary.sh' "$CHECKS"; then
    pass "CI executes the root-owned PID1 gate and configure transaction branches"
else
    fail "CI skips a root-only configure runtime-gate branch"
fi

for guard_script in scripts/cert-renew.sh scripts/renew-hook.sh scripts/intercept-cert-renew.sh; do
    grep -Fq 'readlink -f -- "$directory"' "$ROOT/$guard_script" \
        && grep -Fq 'exec {source_fd}<"$RUNTIME_GATE_HELPER"' "$ROOT/$guard_script" \
        && grep -Fq 'sha256sum -- "/proc/self/fd/$hash_fd"' "$ROOT/$guard_script" \
        && grep -Fq 'bash "/proc/self/fd/$source_fd" assert-clear' "$ROOT/$guard_script" \
        && ! grep -Fq '"$RUNTIME_GATE_HELPER" assert-clear' "$ROOT/$guard_script" \
        || fail "$guard_script reopens the root configure-gate helper by path"
done
pass "every certificate entry executes one parent-validated, digest-bound runtime-gate helper FD"

# The network check is a CI job of its own. It must not be quietly dropped: an
# unverified pin is how 0.0.57 shipped an installer that could not install.
if grep -Fq 'bash tests/verify-artifact-pins.sh' "$CHECKS"; then
    pass "CI verifies every pinned artifact against its published release"
else
    fail "checks.yml no longer runs tests/verify-artifact-pins.sh"
fi

install_files_body="$(sed -n '/^install_files()/,/^}/p' "$INSTALL")"
for helper in publication-fs.sh cert-role-ctl.sh; do
    grep -Fxq "            scripts/${helper}" "$ROOT/.github/workflows/release.yml" \
        || fail "release bundle omits installed certificate helper: $helper"
    grep -Fxq "        ${helper}" <<< "$install_files_body" \
        || fail "installer manifest omits certificate helper: $helper"
done
if grep -Fq 'for s in install.sh quick-install.sh release/*.sh scripts/*.sh' "$CHECKS"; then
    pass "shared certificate publication helpers are bundled, installed, and syntax-gated"
else
    fail "CI shell gate no longer covers installed certificate helpers"
fi

# The public extension corpus must be parsed by the exact core release the
# installer pins. Both repositories are immutable inputs to this release gate.
if grep -Fq 'repository: moooyo/5gpn-extensions' "$CHECKS" \
   && grep -Fq 'ref: e5c550c46e819a06e078751ee9a245dda07bcbe7' "$CHECKS" \
   && grep -Fq 'mihomo_repo=%s\n' "$CHECKS" \
   && grep -Fq 'mihomo_version=%s\n' "$CHECKS" \
   && grep -Fq 'repository: ${{ steps.release_pins.outputs.mihomo_repo }}' "$CHECKS" \
   && grep -Fq 'ref: ${{ steps.release_pins.outputs.mihomo_version }}' "$CHECKS" \
   && grep -Fq 'FIVEGPN_EXTENSIONS_ROOT:' "$CHECKS" \
   && grep -Fq "TestOfficialExtensionManifestParserCorpus\$'" "$CHECKS"; then
    pass "CI parses the immutable official extension corpus with the shipped core"
else
    fail "checks.yml no longer gates official manifests with the exact shipped core"
fi

exit "$FAIL"
