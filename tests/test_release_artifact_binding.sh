#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
RELEASE="$ROOT/.github/workflows/release.yml"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$INSTALL"

TMP="$(mktemp -d /tmp/5gpn-release-binding.XXXXXX)"
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

expect_binary_accept() {
    local name="$1" output="$2"
    export FAKE_STDOUT="$output" FAKE_RC=0
    if binary_reports_exact_version "$FAKE_BIN" --version 9.8.7; then
        pass "$name"
    else
        fail "$name"
    fi
}

expect_binary_reject() {
    local name="$1" output="$2" rc="${3:-0}"
    export FAKE_STDOUT="$output" FAKE_RC="$rc"
    if binary_reports_exact_version "$FAKE_BIN" --version 9.8.7; then
        fail "$name"
    else
        pass "$name"
    fi
}

expect_binary_accept "exact first-party version is accepted" $'9.8.7\n'
expect_binary_reject "wrong first-party version is rejected" $'9.8.6\n'
expect_binary_reject "version prefix match is rejected" $'9.8.7-beta.1\n'
expect_binary_reject "extra first-party version output is rejected" $'9.8.7\nextra\n'
expect_binary_reject "failed first-party version command is rejected" $'9.8.7\n' 1

NUL_BIN="$TMP/fake-version-nul"
printf '%s\n' '#!/usr/bin/env bash' "printf '9.8.7\\000\\n'" > "$NUL_BIN"
chmod +x "$NUL_BIN"
if binary_reports_exact_version "$NUL_BIN" --version 9.8.7; then
    fail "NUL-bearing first-party version is rejected"
else
    pass "NUL-bearing first-party version is rejected"
fi

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

WEB_VERSION="$TMP/.web_version"
printf '%s\n' 9.8.7 > "$WEB_VERSION"
release_tag_file_matches "$WEB_VERSION" 9.8.7 \
    && pass "exact web release marker is accepted" \
    || fail "exact web release marker is accepted"
printf '%s\n' 9.8.6 > "$WEB_VERSION"
if release_tag_file_matches "$WEB_VERSION" 9.8.7; then
    fail "wrong web release marker is rejected"
else
    pass "wrong web release marker is rejected"
fi
printf '9.8.7\n\n' > "$WEB_VERSION"
if release_tag_file_matches "$WEB_VERSION" 9.8.7; then
    fail "multi-line web release marker is rejected"
else
    pass "multi-line web release marker is rejected"
fi
printf '9.8.7\0\n' > "$WEB_VERSION"
if release_tag_file_matches "$WEB_VERSION" 9.8.7; then
    fail "NUL-bearing web release marker is rejected"
else
    pass "NUL-bearing web release marker is rejected"
fi
rm -f "$WEB_VERSION"
ln -s marker-target "$WEB_VERSION"
if release_tag_file_matches "$WEB_VERSION" 9.8.7; then
    fail "symlink web release marker is rejected"
else
    pass "symlink web release marker is rejected"
fi

stage_fn="$(sed -n '/^stage_artifacts()/,/^}/p' "$INSTALL")"
install_web_fn="$(sed -n '/^install_web()/,/^}/p' "$INSTALL")"
if grep -Fq 'binary_reports_exact_version "$ARTIFACT_STAGE/5gpn-dns" --version "$ver"' <<<"$stage_fn" \
   && grep -Fq 'binary_reports_exact_version "$ARTIFACT_STAGE/5gpn-intercept" --version "$ver"' <<<"$stage_fn" \
   && grep -Fq 'mihomo_reports_exact_version "$ARTIFACT_STAGE/mihomo" "$MIHOMO_VERSION"' <<<"$stage_fn"; then
    pass "all staged executables are wired to exact version checks"
else
    fail "a staged executable bypasses exact version checks"
fi

for publisher in install_5gpndns install_intercept install_mihomo; do
    if (
        cp "$FAKE_BIN" "$ARTIFACT_STAGE/5gpn-dns"
        cp "$FAKE_BIN" "$ARTIFACT_STAGE/5gpn-intercept"
        cp "$FAKE_BIN" "$ARTIFACT_STAGE/mihomo"
        chmod +x "$ARTIFACT_STAGE/5gpn-dns" "$ARTIFACT_STAGE/5gpn-intercept" "$ARTIFACT_STAGE/mihomo"
        DNS_BIN=/bin/true
        INTERCEPT_BIN=/bin/true
        MIHOMO_BIN=/bin/true
        publish_executable() { return 77; }
        "$publisher" >/dev/null 2>&1
    ); then
        fail "$publisher propagates executable publication failure"
    else
        pass "$publisher propagates executable publication failure"
    fi
done
grep -Fq 'release_tag_file_matches "$ARTIFACT_STAGE/web/.web_version" "$ver"' <<<"$stage_fn" \
    && pass "web marker is checked during staging" \
    || fail "web marker is not checked during staging"
if grep -Fq 'release_tag_file_matches "$ARTIFACT_STAGE/web/.web_version" "$DNS_VERSION_DEFAULT"' <<<"$install_web_fn" \
   && ! grep -Fq '> "$ARTIFACT_STAGE/web/.web_version"' <<<"$install_web_fn"; then
    pass "web publication rechecks rather than overwrites the release marker"
else
    fail "web publication can overwrite or bypass the release marker"
fi

marker_line="$(grep -nF 'printf '\''%s\n'\'' "$VER" > web/dist/.web_version' "$RELEASE" | cut -d: -f1)"
tar_line="$(grep -nF 'tar czf "5gpn-web-${VER}.tar.gz" -C web/dist .' "$RELEASE" | cut -d: -f1)"
if [[ -n "$marker_line" && -n "$tar_line" && "$marker_line" -lt "$tar_line" ]]; then
    pass "release workflow embeds the exact tag before packaging the web archive"
else
    fail "release workflow does not embed the exact tag before packaging"
fi

exit "$FAIL"
