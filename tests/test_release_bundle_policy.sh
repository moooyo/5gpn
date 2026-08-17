#!/usr/bin/env bash
# Lock the exact file and executable policy of the published installer bundle.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="$ROOT/.github/workflows/release.yml"
INSTALL="$ROOT/install.sh"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

extract_workflow_array() { # extract_workflow_array <array-name>
    local name="$1"
    awk -v name="$name" '
        $0 ~ "^[[:space:]]*" name "=\\([[:space:]]*$" { inside=1; next }
        inside && $0 ~ "^[[:space:]]*\\)[[:space:]]*$" { exit }
        inside {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line != "" && line !~ /^#/) print line
        }
    ' "$RELEASE"
}

extract_package_run_block() {
    awk '
        /^[[:space:]]*- name: Package installer bundle[[:space:]]*$/ {
            package_step=1
            next
        }
        package_step && /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ {
            run_block=1
            next
        }
        run_block && /^[[:space:]]*- name:/ { exit }
        run_block {
            sub(/^          /, "")
            print
        }
    ' "$RELEASE"
}

compare_exact_list() { # compare_exact_list <name> <expected-array> <actual-array>
    local name="$1" expected_name="$2" actual_name="$3"
    local -n expected_ref="$expected_name"
    local -n actual_ref="$actual_name"
    local expected actual
    expected="$(printf '%s\n' "${expected_ref[@]}" | LC_ALL=C sort)"
    actual="$(printf '%s\n' "${actual_ref[@]}" | LC_ALL=C sort)"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name is the exact approved list"
    else
        fail "$name differs from the approved list"
        diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
    fi
}

expected_bundle=(
    install.sh
    quick-install.sh
    README.md
    README.en.md
    LICENSE
    THIRD_PARTY_NOTICES.md
    release/pins.env
    release/pins.sh
    etc/5gpn/dns.env.example
    etc/mihomo/config.yaml.tmpl
    etc/systemd/5gpn-certbot-renew.service
    etc/systemd/5gpn-certbot-renew.timer
    etc/systemd/5gpn-intercept-cert.path
    etc/systemd/5gpn-intercept-cert.service
    etc/systemd/5gpn-intercept-cert.timer
    etc/systemd/5gpn-mihomo.service
    scripts/publication-fs.sh
    scripts/cert-role-ctl.sh
    scripts/cert-renew.sh
    scripts/configure-runtime-gate.sh
    scripts/gen-ios-profile.sh
    scripts/intercept-cert-renew.sh
    scripts/renew-hook.sh
    scripts/ui-generation.sh
    docs/architecture.md
    docs/native-extensions.md
    tests/integration-smoke.md
    tests/deployment-smoke.md
    tests/acceptance/installer.md
    tests/acceptance/disruption-recovery.md
)
expected_executables=(
    install.sh
    quick-install.sh
    scripts/publication-fs.sh
    scripts/cert-role-ctl.sh
    scripts/cert-renew.sh
    scripts/configure-runtime-gate.sh
    scripts/gen-ios-profile.sh
    scripts/intercept-cert-renew.sh
    scripts/renew-hook.sh
    scripts/ui-generation.sh
)
expected_installed_scripts=(
    publication-fs.sh
    cert-role-ctl.sh
    cert-renew.sh
    configure-runtime-gate.sh
    gen-ios-profile.sh
    intercept-cert-renew.sh
    renew-hook.sh
    ui-generation.sh
)
expected_installed_release_files=(
    pins.env
    pins.sh
)
mapfile -t actual_bundle < <(extract_workflow_array bundle_files)
mapfile -t actual_executables < <(extract_workflow_array executable_files)

compare_exact_list "installer bundle manifest" expected_bundle actual_bundle
compare_exact_list "installer bundle executable manifest" expected_executables actual_executables

mapfile -t actual_installed_scripts < <(awk '
    /^[[:space:]]*local -a installed_scripts=\([[:space:]]*$/ { inside=1; next }
    inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
    inside { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }
' "$INSTALL")
compare_exact_list "gateway-installed script manifest" expected_installed_scripts actual_installed_scripts

mapfile -t actual_installed_release_files < <(awk '
    /^[[:space:]]*local -a pin_files=\([[:space:]]*$/ { inside=1; next }
    inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
    inside { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }
' "$INSTALL")
compare_exact_list "gateway-installed release-pin manifest" \
    expected_installed_release_files actual_installed_release_files

install_files_body="$(sed -n '/^install_files()/,/^}/p' "$INSTALL")"
if grep -Fq 'clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"' <<<"$install_files_body" \
   && grep -Fq '"$SCRIPTS_DIR"' <<<"$install_files_body" \
   && ! grep -Fq 'retired_installed_scripts' <<<"$install_files_body"; then
    pass "gateway script directory is replaced from the exact current manifest"
else
    fail "gateway script publication retains a historical-script compatibility list"
fi

installed_missing_from_bundle=()
for file in "${actual_installed_scripts[@]}"; do
    [[ " ${actual_bundle[*]} " =~ [[:space:]]scripts/${file}[[:space:]] ]] \
        || installed_missing_from_bundle+=("$file")
done
if ((${#installed_missing_from_bundle[@]} == 0)); then
    pass "every gateway-installed script is present in the release bundle"
else
    fail "gateway-installed scripts are absent from the bundle: ${installed_missing_from_bundle[*]}"
fi

for file in "${actual_installed_release_files[@]}"; do
    [[ " ${actual_bundle[*]} " =~ [[:space:]]release/${file}[[:space:]] ]] \
        || installed_missing_from_bundle+=("release/$file")
done
if ((${#installed_missing_from_bundle[@]} == 0)); then
    pass "every gateway-installed release-pin file is present in the release bundle"
else
    fail "gateway-installed files are absent from the bundle: ${installed_missing_from_bundle[*]}"
fi

missing=()
for file in "${expected_bundle[@]}"; do
    [[ -f "$ROOT/$file" ]] || missing+=("$file")
done
if ((${#missing[@]} == 0)); then
    pass "every approved bundle input exists"
else
    fail "approved bundle inputs are missing: ${missing[*]}"
fi

package_step="$(sed -n '/- name: Package installer bundle/,/- name: Collect exact release assets/p' "$RELEASE")"
if grep -Fq 'scripts/run-suites.sh' <<<"$package_step" \
   && [[ ! " ${actual_bundle[*]} " =~ [[:space:]]scripts/run-suites\.sh[[:space:]] ]]; then
    pass "development suite runner is explicitly excluded from the bundle"
else
    fail "development suite runner exclusion is not explicit"
fi

if grep -Eq '^[[:space:]]*cp[[:space:]]+-[^[:space:]]*r' <<<"$package_step"; then
    fail "installer packaging still recursively copies a source directory"
else
    pass "installer packaging has no recursive source-directory copy"
fi

if grep -Fq 'for file in "${bundle_files[@]}"' <<<"$package_step" \
   && grep -Fq 'install -D -m 0644 "$file" "$stage/$file"' <<<"$package_step" \
   && grep -Fq 'for file in "${executable_files[@]}"' <<<"$package_step" \
   && grep -Fq 'chmod 0755 "$stage/$file"' <<<"$package_step"; then
    pass "approved files are copied individually and executables regain mode 0755"
else
    fail "bundle copy or executable-mode publication bypasses the approved arrays"
fi

if grep -Fq "printf '%s\\n' \"\${bundle_files[@]}\"" <<<"$package_step" \
   && grep -Fq 'find "$stage" -type f -printf' <<<"$package_step" \
   && grep -Fq 'diff -u "$expected_manifest" "$actual_manifest"' <<<"$package_step"; then
    pass "release packaging verifies the staged manifest before archiving"
else
    fail "release packaging does not fail closed on staged-manifest drift"
fi

if grep -Fq 'tar xzf 5gpn-installer.tar.gz -C "$archive_root"' <<<"$package_step" \
   && grep -Fq 'find "$archive_root" -type f -printf' <<<"$package_step" \
   && grep -Fq 'diff -u "$expected_manifest" "$archive_manifest"' <<<"$package_step"; then
    pass "release packaging rechecks the completed archive manifest"
else
    fail "release packaging does not verify the completed archive"
fi

prepare_package_workspace() { # prepare_package_workspace <directory>
    local workspace="$1" file
    mkdir -p "$workspace"
    for file in "${expected_bundle[@]}"; do
        install -D -m 0644 "$ROOT/$file" "$workspace/$file" || return 1
    done
    # Keep the development-only helper present in the simulated checkout so
    # the behavioral assertion proves the allowlist excludes it.
    install -D -m 0644 "$ROOT/scripts/run-suites.sh" \
        "$workspace/scripts/run-suites.sh"
}

PACKAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/5gpn-release-bundle.XXXXXX")"
trap 'rm -rf "$PACKAGE_TMP"' EXIT
PACKAGE_RUN="$(extract_package_run_block)"
FAKE_TAG="9.8.7-beta.6"
PACKAGE_WORKSPACE="$PACKAGE_TMP/package"
PACKAGE_RUNNER_TEMP="$PACKAGE_TMP/runner"
mkdir -p "$PACKAGE_RUNNER_TEMP"

if [[ -n "$PACKAGE_RUN" ]] \
   && prepare_package_workspace "$PACKAGE_WORKSPACE" \
   && (
       cd "$PACKAGE_WORKSPACE" \
           && GITHUB_REF_NAME="$FAKE_TAG" RUNNER_TEMP="$PACKAGE_RUNNER_TEMP" \
               bash -c "$PACKAGE_RUN"
   ) >"$PACKAGE_TMP/package.out" 2>&1; then
    pass "extracted release package block executes successfully"
else
    fail "extracted release package block failed"
    sed 's/^/  /' "$PACKAGE_TMP/package.out" 2>/dev/null || true
fi

PUBLISHED_ROOT="$PACKAGE_TMP/published"
mkdir -p "$PUBLISHED_ROOT"
if tar xzf "$PACKAGE_WORKSPACE/5gpn-installer.tar.gz" -C "$PUBLISHED_ROOT" \
    2>"$PACKAGE_TMP/extract.err"; then
    pass "published installer archive extracts successfully"
else
    fail "published installer archive could not be extracted"
    sed 's/^/  /' "$PACKAGE_TMP/extract.err" 2>/dev/null || true
fi

mapfile -t published_files < <(
    find "$PUBLISHED_ROOT" -type f -printf '%P\n' | LC_ALL=C sort
)
compare_exact_list "published installer archive manifest" expected_bundle published_files
expected_file_count="${#expected_bundle[@]}"
if ((${#published_files[@]} == expected_file_count)); then
    pass "published installer archive contains exactly ${expected_file_count} files"
else
    fail "published installer archive contains ${#published_files[@]} files instead of ${expected_file_count}"
fi

declare -A executable_lookup=()
for file in "${expected_executables[@]}"; do
    executable_lookup["$file"]=1
done
executable_count=0
nonexecutable_count=0
mode_failures=()
for file in "${published_files[@]}"; do
    mode="$(stat -c %a "$PUBLISHED_ROOT/$file")"
    if [[ -n "${executable_lookup[$file]-}" ]]; then
        ((executable_count += 1))
        [[ "$mode" == 755 ]] || mode_failures+=("$file=$mode (expected 755)")
    else
        ((nonexecutable_count += 1))
        [[ "$mode" == 644 ]] || mode_failures+=("$file=$mode (expected 644)")
    fi
done
expected_executable_count="${#expected_executables[@]}"
expected_nonexecutable_count=$((expected_file_count - expected_executable_count))
if ((executable_count == expected_executable_count \
      && nonexecutable_count == expected_nonexecutable_count \
      && ${#mode_failures[@]} == 0)); then
    pass "published modes match the executable and non-executable manifests"
else
    fail "published archive modes differ from the approved policy: ${mode_failures[*]-}"
fi

release_tag_lines="$(grep -c '^RELEASE_TAG=' "$PUBLISHED_ROOT/install.sh" || true)"
exact_stamp_lines="$(grep -c "^RELEASE_TAG=\"${FAKE_TAG}\"$" \
    "$PUBLISHED_ROOT/install.sh" || true)"
if [[ "$release_tag_lines" == 1 && "$exact_stamp_lines" == 1 ]]; then
    pass "published installer contains one exact release tag stamp"
else
    fail "published installer release tag stamp is missing or ambiguous"
fi

expected_pins_binding="$(sha256sum "$PUBLISHED_ROOT/release/pins.env" | awk '{print $1}'):\
$(sha256sum "$PUBLISHED_ROOT/release/pins.sh" | awk '{print $1}')"
binding_lines="$(grep -c '^RELEASE_PINS_BINDING=' "$PUBLISHED_ROOT/install.sh" || true)"
exact_binding_lines="$(grep -Fc "RELEASE_PINS_BINDING=\"${expected_pins_binding}\"" \
    "$PUBLISHED_ROOT/install.sh" || true)"
if [[ "$binding_lines" == 1 && "$exact_binding_lines" == 1 ]]; then
    pass "published installer binds the exact bundled release pin generation"
else
    fail "published installer release-pin generation binding is missing or ambiguous"
fi

expected_quick_binding="$(sha256sum "$PUBLISHED_ROOT/quick-install.sh" | awk '{print $1}')"
quick_binding_lines="$(grep -c '^RELEASE_QUICK_BINDING=' "$PUBLISHED_ROOT/install.sh" || true)"
exact_quick_binding_lines="$(grep -Fc "RELEASE_QUICK_BINDING=\"${expected_quick_binding}\"" \
    "$PUBLISHED_ROOT/install.sh" || true)"
if [[ "$quick_binding_lines" == 1 && "$exact_quick_binding_lines" == 1 ]]; then
    pass "published installer binds the exact bundled quick installer generation"
else
    fail "published installer quick-installer generation binding is missing or ambiguous"
fi

if (cd "$PACKAGE_WORKSPACE" && sha256sum -c checksums.txt >/dev/null); then
    pass "published installer checksum verifies"
else
    fail "published installer checksum does not verify"
fi

if [[ ! " ${published_files[*]} " =~ [[:space:]]scripts/run-suites\.sh[[:space:]] ]]; then
    pass "published installer archive excludes run-suites.sh"
else
    fail "published installer archive contains run-suites.sh"
fi

unexpected_type="$(
    find "$PUBLISHED_ROOT" -mindepth 1 ! -type d ! -type f -print -quit
)"
if [[ -z "$unexpected_type" ]]; then
    pass "published installer archive contains only directories and regular files"
else
    fail "published installer archive contains an unexpected entry: $unexpected_type"
fi

# Prove that the archive-level check rejects a file introduced only after the
# staged manifest has already passed.
if MUTATED_PACKAGE_RUN="$(
    printf '%s\n' "$PACKAGE_RUN" | awk '
        {
            print
            if (!injected && $0 == "diff -u \"$expected_manifest\" \"$actual_manifest\"") {
                print "printf injected > \"$stage/unexpected-after-manifest.txt\""
                injected=1
            }
        }
        END { if (!injected) exit 1 }
    '
)"; then
    INJECTED_WORKSPACE="$PACKAGE_TMP/injected"
    INJECTED_RUNNER_TEMP="$PACKAGE_TMP/injected-runner"
    mkdir -p "$INJECTED_RUNNER_TEMP"
    prepare_package_workspace "$INJECTED_WORKSPACE" || fail "could not prepare injection workspace"
    if (
        cd "$INJECTED_WORKSPACE" \
            && GITHUB_REF_NAME="$FAKE_TAG" RUNNER_TEMP="$INJECTED_RUNNER_TEMP" \
                bash -c "$MUTATED_PACKAGE_RUN"
    ) >"$PACKAGE_TMP/injected.out" 2>&1; then
        fail "post-manifest archive injection was not rejected"
    elif [[ -f "$INJECTED_WORKSPACE/5gpn-installer.tar.gz" ]] \
         && grep -Fq 'unexpected-after-manifest.txt' "$PACKAGE_TMP/injected.out"; then
        pass "archive recheck rejects a post-manifest injected file"
    else
        fail "injection probe failed before proving the archive recheck"
        sed 's/^/  /' "$PACKAGE_TMP/injected.out" 2>/dev/null || true
    fi
else
    fail "could not construct post-manifest injection probe"
fi

exit "$FAIL"
