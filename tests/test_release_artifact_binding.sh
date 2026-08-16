#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
RELEASE="$ROOT/.github/workflows/release.yml"
PIN_VERIFY="$ROOT/tests/verify-artifact-pins.sh"
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
   && grep -Fq 'docs/architecture.md' "$RELEASE" \
   && grep -Fq 'docs/native-extensions.md' "$RELEASE" \
   && grep -Fq 'tests/integration-smoke.md' "$RELEASE"; then
    pass "installer bundle retains both README languages and linked operator runbooks"
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
for pin in MIHOMO ZASH; do
    version="${pin}_VERSION"
    digest="${pin}_SHA256"
    if [[ -z "${!version-}" || -z "${!digest-}" ]]; then
        fail "$pin is missing a version or a digest"
        continue
    fi
    if [[ ! "${!digest}" =~ ^[0-9a-f]{64}$ ]]; then
        fail "$digest is not a lowercase 64-character SHA-256"
        continue
    fi
    if grep -Fq "verify_sha256 \"\$ARTIFACT_STAGE/" "$INSTALL" && grep -Fq "\$$digest" "$INSTALL"; then
        pass "$pin is pinned as a complete version/digest pair and verified before use"
    else
        fail "$digest is declared but never passed to verify_sha256"
    fi
done

# Gum is optional only in the sense that a bootstrap failure falls back to plain
# output. It is still a root-installed release artifact when available. Lock all
# three uname-to-release mappings and require the network verifier to bind each
# corresponding tarball to the digest read from install.sh.
install_gum_fn="$(sed -n '/^install_gum()/,/^}/p' "$INSTALL")"
if grep -Fq 'x86_64|amd64)  arch="x86_64"; exp="$GUM_SHA256_X86_64"' <<<"$install_gum_fn" \
   && grep -Fq 'aarch64|arm64) arch="arm64";  exp="$GUM_SHA256_ARM64"' <<<"$install_gum_fn" \
   && grep -Fq 'armv7l|armhf)  arch="armv7";  exp="$GUM_SHA256_ARMV7"' <<<"$install_gum_fn" \
   && grep -Fq 'gum_${GUM_VERSION}_Linux_${arch}.tar.gz' <<<"$install_gum_fn"; then
    pass "Gum uname aliases map to the three pinned release architectures"
else
    fail "Gum architecture mapping or release URL drifted from its pins"
fi

gum_verify_url='https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz'
if grep -Fq "$gum_verify_url" "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release x86_64 "$GUM_SHA256_X86_64"' "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release arm64 "$GUM_SHA256_ARM64"' "$PIN_VERIFY" \
   && grep -Fq 'check_gum_release armv7 "$GUM_SHA256_ARMV7"' "$PIN_VERIFY"; then
    pass "network pin verification covers every Gum release architecture"
else
    fail "network pin verification omits or misroutes a Gum release architecture"
fi

for digest in GUM_SHA256_X86_64 GUM_SHA256_ARM64 GUM_SHA256_ARMV7; do
    if [[ "${!digest-}" =~ ^[0-9a-f]{64}$ ]]; then
        pass "$digest is a complete lowercase SHA-256"
    else
        fail "$digest is missing or malformed"
    fi
done

# The mihomo-config job restates the mihomo pin in its own env block, so it is a
# third copy that can drift from install.sh. The network check reads install.sh;
# this keeps the workflow's copy honest.
if grep -Fq "MIHOMO_VERSION: ${MIHOMO_VERSION}" "$CHECKS" \
   && grep -Fq "MIHOMO_SHA256: ${MIHOMO_SHA256}" "$CHECKS"; then
    pass "checks.yml validates the mihomo build install.sh actually ships"
else
    fail "checks.yml pins a different mihomo version or digest than install.sh"
fi

# The network check is a CI job of its own. It must not be quietly dropped: an
# unverified pin is how 0.0.57 shipped an installer that could not install.
if grep -Fq 'bash tests/verify-artifact-pins.sh' "$CHECKS"; then
    pass "CI verifies every pinned artifact against its published release"
else
    fail "checks.yml no longer runs tests/verify-artifact-pins.sh"
fi

# The public extension corpus must be parsed by the exact core release the
# installer pins. Both repositories are immutable inputs to this release gate.
if grep -Fq 'repository: moooyo/5gpn-extensions' "$CHECKS" \
   && grep -Fq 'ref: ac04d79a12ef01f99bf1637f7dc62b6952694d78' "$CHECKS" \
   && grep -Fq "ref: ${MIHOMO_VERSION}" "$CHECKS" \
   && grep -Fq 'FIVEGPN_EXTENSIONS_ROOT:' "$CHECKS" \
   && grep -Fq "TestOfficialExtensionManifestParserCorpus\$'" "$CHECKS"; then
    pass "CI parses the immutable official extension corpus with the shipped core"
else
    fail "checks.yml no longer gates official manifests with the exact shipped core"
fi

exit "$FAIL"
