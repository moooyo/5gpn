#!/usr/bin/env bash
# Centralized release coordinates are strict data and every consumer shares the
# same closed GitHub-release URL builder.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS_ENV="$ROOT/release/pins.env"
PINS_LIBRARY="$ROOT/release/pins.sh"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# shellcheck source=../release/pins.sh
source "$PINS_LIBRARY"

expected_keys=(
    MIHOMO_REPO
    MIHOMO_VERSION
    MIHOMO_ASSET_TEMPLATE
    MIHOMO_SHA256
    ZASH_REPO
    ZASH_VERSION
    ZASH_ASSET_TEMPLATE
    ZASH_SHA256
    GUM_REPO
    GUM_VERSION
    GUM_ASSET_TEMPLATE
    GUM_SHA256_X86_64
    GUM_SHA256_ARM64
    GUM_SHA256_ARMV7
)
mapfile -t actual_keys < <(cut -d= -f1 "$PINS_ENV" | LC_ALL=C sort)
mapfile -t sorted_expected_keys < <(printf '%s\n' "${expected_keys[@]}" | LC_ALL=C sort)
if ((${#actual_keys[@]} == 14 && ${#RELEASE_PIN_KEYS[@]} == 14)) \
   && [[ "$(printf '%s\n' "${actual_keys[@]}")" == "$(printf '%s\n' "${sorted_expected_keys[@]}")" ]] \
   && [[ "$(printf '%s\n' "${RELEASE_PIN_KEYS[@]}" | LC_ALL=C sort)" \
      == "$(printf '%s\n' "${sorted_expected_keys[@]}")" ]]; then
    pass "pins.env and the parser expose the exact 14-key schema"
else
    fail "release pin key set is not the exact 14-key schema"
fi

# Caller variables and a forged loaded flag are discarded by every real load.
MIHOMO_REPO=attacker.invalid/repo
MIHOMO_VERSION=latest
MIHOMO_SHA256=bad
RELEASE_PINS_LOADED=1
if load_release_pins "$PINS_ENV" >/dev/null 2>&1 \
   && [[ "$MIHOMO_REPO" == moooyo/mihomo \
      && "$ZASH_REPO" == moooyo/zashboard \
      && "$GUM_REPO" == charmbracelet/gum \
      && "$RELEASE_PINS_LOADED" == 1 ]]; then
    pass "a strict load replaces caller-supplied release coordinates"
else
    fail "caller-supplied release coordinates survived strict loading"
fi

if grep -Eq '(^|[;[:space:]])eval([;[:space:]]|$)|^[[:space:]]*(source|\.)[[:space:]]' \
    "$PINS_LIBRARY"; then
    fail "pins.env is executed as shell input"
else
    pass "pins.env is parsed as data rather than executed"
fi

mihomo_asset="${MIHOMO_ASSET_TEMPLATE/\{version\}/$MIHOMO_VERSION}"
zash_asset="$ZASH_ASSET_TEMPLATE"
gum_asset="${GUM_ASSET_TEMPLATE/\{version\}/$GUM_VERSION}"
gum_asset="${gum_asset/\{arch\}/arm64}"
if [[ "$(release_asset_name mihomo)" == "$mihomo_asset" \
   && "$(release_asset_name zashboard)" == "$zash_asset" \
   && "$(release_asset_name gum arm64)" == "$gum_asset" \
   && "$(release_download_url mihomo)" == "https://github.com/${MIHOMO_REPO}/releases/download/${MIHOMO_VERSION}/${mihomo_asset}" \
   && "$(release_download_url zashboard)" == "https://github.com/${ZASH_REPO}/releases/download/${ZASH_VERSION}/${zash_asset}" \
   && "$(release_download_url gum arm64)" == "https://github.com/${GUM_REPO}/releases/download/v${GUM_VERSION}/${gum_asset}" ]]; then
    pass "the shared builder derives only the pinned GitHub HTTPS release URLs"
else
    fail "release asset or URL construction drifted from the manifest"
fi

if release_download_url unknown >/dev/null 2>&1 \
   || release_download_url gum amd64 >/dev/null 2>&1 \
   || release_asset_name mihomo extra >/dev/null 2>&1; then
    fail "the builder accepted an unknown component, architecture, or argument"
else
    pass "the builder rejects coordinates outside its component and architecture whitelist"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/5gpn-release-pins.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

sort -r "$PINS_ENV" > "$TMP/shuffled.env"
if load_release_pins "$TMP/shuffled.env" >/dev/null 2>&1; then
    pass "the exact key set is accepted independently of line order"
else
    fail "the parser incorrectly depends on manifest line order"
fi
if load_release_pins "$PINS_ENV" >/dev/null 2>&1; then
    pinned_mihomo_version="$MIHOMO_VERSION"
    pinned_gum_version="$GUM_VERSION"
else
    fail "the committed pin manifest could not be restored after the order probe"
    pinned_mihomo_version=v0.0.0-monolith.0
    pinned_gum_version=0.0.0
fi

replace_pin() { # replace_pin <file> <key> <value>
    local file="$1" key="$2" value="$3" candidate
    candidate="$file.new"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { print key "=" value; next }
        { print }
    ' "$file" > "$candidate" && mv -f -- "$candidate" "$file"
}

would_download=0
curl() {
    would_download=1
    return 0
}
consume_fixture() { # consume_fixture <pins-file>
    local fixture="$1" url
    load_release_pins "$fixture" >/dev/null 2>&1 || return 1
    url="$(release_download_url mihomo)" || return 1
    curl "$url" >/dev/null 2>&1
}

expect_rejected() { # expect_rejected <name> <fixture>
    local name="$1" fixture="$2"
    would_download=0
    if consume_fixture "$fixture"; then
        fail "$name was accepted"
    elif [[ "$would_download" == 0 ]]; then
        pass "$name fails before any download can begin"
    else
        fail "$name reached the download boundary"
    fi
}

fixture="$TMP/missing.env"
sed '$d' "$PINS_ENV" > "$fixture"
expect_rejected "a missing key" "$fixture"

fixture="$TMP/duplicate.env"
cp "$PINS_ENV" "$fixture"
head -n 1 "$PINS_ENV" >> "$fixture"
expect_rejected "a duplicate key" "$fixture"

fixture="$TMP/unknown.env"
cp "$PINS_ENV" "$fixture"
sed 's/^GUM_REPO=/UNKNOWN_PIN=/' "$fixture" > "$fixture.new"
mv -f -- "$fixture.new" "$fixture"
expect_rejected "an unknown key" "$fixture"

fixture="$TMP/cr.env"
awk '{ printf "%s\r\n", $0 }' "$PINS_ENV" > "$fixture"
expect_rejected "CR-bearing input" "$fixture"

fixture="$TMP/nul.env"
cp "$PINS_ENV" "$fixture"
printf '\0' >> "$fixture"
expect_rejected "NUL-bearing input" "$fixture"

fixture="$TMP/non-ascii.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" ZASH_ASSET_TEMPLATE $'d\xc3\xadst.zip'
expect_rejected "non-ASCII input" "$fixture"

fixture="$TMP/whitespace.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_REPO 'moooyo/mihomo '
expect_rejected "whitespace-bearing input" "$fixture"

fixture="$TMP/quoted.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_REPO '"moooyo/mihomo"'
expect_rejected "quoted input" "$fixture"

fixture="$TMP/extra-equals.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" ZASH_REPO 'moooyo/zashboard=extra'
expect_rejected "an assignment with an extra equals sign" "$fixture"

fixture="$TMP/repo.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_REPO mirror.invalid/mihomo
expect_rejected "an unapproved repository" "$fixture"

fixture="$TMP/version.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_VERSION latest
expect_rejected "an unapproved component version" "$fixture"

fixture="$TMP/gum-version.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" GUM_VERSION "v${pinned_gum_version}"
expect_rejected "an unapproved Gum version" "$fixture"

fixture="$TMP/leading-zero-component-version.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_VERSION "v0${pinned_mihomo_version#v}"
expect_rejected "a component version with a leading zero" "$fixture"

fixture="$TMP/leading-zero-gum-version.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" GUM_VERSION "0${pinned_gum_version}"
expect_rejected "a Gum version with a leading zero" "$fixture"

fixture="$TMP/asset-path.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" ZASH_ASSET_TEMPLATE ../dist.zip
expect_rejected "an unsafe asset template path" "$fixture"

fixture="$TMP/asset-version.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_ASSET_TEMPLATE mihomo.gz
expect_rejected "a component template missing its version placeholder" "$fixture"

fixture="$TMP/asset-arch.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" GUM_ASSET_TEMPLATE 'gum_{version}.tar.gz'
expect_rejected "a Gum template missing its architecture placeholder" "$fixture"

fixture="$TMP/asset-duplicate.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" MIHOMO_ASSET_TEMPLATE 'mihomo-{version}-{version}.gz'
expect_rejected "an asset template with duplicate placeholders" "$fixture"

fixture="$TMP/sha.env"
cp "$PINS_ENV" "$fixture"
replace_pin "$fixture" ZASH_SHA256 ABCD
expect_rejected "an invalid SHA-256" "$fixture"

fixture="$TMP/linked.env"
ln -s "$PINS_ENV" "$fixture"
expect_rejected "a linked pin manifest" "$fixture"

fixture="$TMP/hardlinked.env"
cp "$PINS_ENV" "$fixture"
ln "$fixture" "$fixture.alias"
expect_rejected "a hard-linked pin manifest" "$fixture"

# The bootstrap executes and parses only a stable private pair. Mutation while
# the two source files are copied must fail before either file can become the
# authority for this run.
if ROOT_UNDER_TEST="$ROOT" TEST_TMP="$TMP" bash -s <<'BASH'
set -euo pipefail
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_UNDER_TEST/install.sh"
pair="$TEST_TMP/bootstrap-mutation"
mkdir "$pair"
cp "$ROOT_UNDER_TEST/release/pins.env" "$pair/pins.env"
cp "$ROOT_UNDER_TEST/release/pins.sh" "$pair/pins.sh"
real_install="$(command -v install)"
install_calls=0
mutation_sentinel="$pair/mutated"
install() {
    "$real_install" "$@"
    install_calls=$((install_calls + 1))
    if (( install_calls == 2 )); then
        printf '\n' >> "$pair/pins.env"
        : > "$mutation_sentinel"
    fi
}
if capture_release_pin_pair "$pair"; then
    exit 1
fi
[[ "$install_calls" == 2 && -f "$mutation_sentinel" \
   && -z "${RELEASE_PINS_SNAPSHOT_DIR:-}" ]]
BASH
then
    pass "source mutation during capture is rejected before the pair is loaded"
else
    fail "source mutation during capture reached a loaded release authority"
fi

if ROOT_UNDER_TEST="$ROOT" TEST_TMP="$TMP" bash -s <<'BASH'
set -euo pipefail
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_UNDER_TEST/install.sh"
pair="$TEST_TMP/bootstrap-hardlink"
mkdir "$pair"
cp "$ROOT_UNDER_TEST/release/pins.env" "$pair/pins.env"
cp "$ROOT_UNDER_TEST/release/pins.sh" "$pair/pins.sh"
capture_release_pin_pair "$pair"
cleanup_release_pin_snapshot
ln "$pair/pins.env" "$pair/pins.env.alias"
[[ "$(stat -Lc '%h' "$pair/pins.env")" == 2 ]]
if capture_release_pin_pair "$pair"; then
    exit 1
fi
[[ -z "${RELEASE_PINS_SNAPSHOT_DIR:-}" ]]
BASH
then
    pass "a hard-linked pin file is rejected before any release download"
else
    fail "a hard-linked pin file survived the bootstrap boundary"
fi

if ROOT_UNDER_TEST="$ROOT" TEST_TMP="$TMP" bash -s <<'BASH'
set -euo pipefail
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_UNDER_TEST/install.sh"
backend="$TEST_TMP/stale-backend"
mkdir -p "$backend/release"
cp "$ROOT_UNDER_TEST/install.sh" "$backend/install.sh"
cp "$ROOT_UNDER_TEST/quick-install.sh" "$backend/quick-install.sh"
cp "$ROOT_UNDER_TEST/release/pins.env" "$backend/release/pins.env"
cp "$ROOT_UNDER_TEST/release/pins.sh" "$backend/release/pins.sh"
old_tag=9.8.7-beta.6
new_tag=9.8.7-beta.7
binding="$(sha256sum "$backend/release/pins.env" | awk '{print $1}'):\
$(sha256sum "$backend/release/pins.sh" | awk '{print $1}')"
quick_binding="$(sha256sum "$backend/quick-install.sh" | awk '{print $1}')"
sed -i "s/^RELEASE_TAG=.*/RELEASE_TAG=\"${old_tag}\"/" "$backend/install.sh"
sed -i "s/^RELEASE_PINS_BINDING=.*/RELEASE_PINS_BINDING=\"${binding}\"/" "$backend/install.sh"
sed -i "s/^RELEASE_QUICK_BINDING=.*/RELEASE_QUICK_BINDING=\"${quick_binding}\"/" "$backend/install.sh"
BASE_DIR="$backend"
SCRIPT_DIR="$backend"
SCRIPT_PATH="$backend/install.sh"
RELEASE_PINS_BUNDLE_DIR="$backend/release"
RELEASE_QUICK_PATH="$backend/quick-install.sh"
RELEASE_TAG="$old_tag"
RELEASE_QUICK_BINDING="$quick_binding"
capture_release_pin_pair "$RELEASE_PINS_BUNDLE_DIR"
cleanup_release_pin_snapshot
RELEASE_QUICK_BUNDLE_STATE="$(release_pin_file_state "$RELEASE_QUICK_PATH")"
INSTALLED_BACKEND_SCRIPT_STATE="$(release_pin_file_state "$SCRIPT_PATH")"
assert_installed_backend_revision
sed -i "s/^RELEASE_TAG=.*/RELEASE_TAG=\"${new_tag}\"/" "$SCRIPT_PATH"
# Simulate the old-fd/new-path false negative: even if path state were sampled
# after replacement, the in-memory release generation must still disagree.
INSTALLED_BACKEND_SCRIPT_STATE="$(release_pin_file_state "$SCRIPT_PATH")"
if assert_installed_backend_revision >/dev/null 2>&1; then
    exit 1
fi
BASH
then
    pass "a queued installed CLI rejects a backend replaced while it waited"
else
    fail "a queued installed CLI can act through a stale backend"
fi

if ROOT_UNDER_TEST="$ROOT" TEST_TMP="$TMP" bash -s <<'BASH'
set -euo pipefail
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT_UNDER_TEST/install.sh"
backend="$TEST_TMP/queued-wrapper"
mkdir -p "$backend/release" "$backend/run"
chmod 0700 "$backend/run"
cp "$ROOT_UNDER_TEST/install.sh" "$backend/install.sh"
cp "$ROOT_UNDER_TEST/quick-install.sh" "$backend/quick-install.sh"
cp "$ROOT_UNDER_TEST/release/pins.env" "$backend/release/pins.env"
cp "$ROOT_UNDER_TEST/release/pins.sh" "$backend/release/pins.sh"
old_tag=9.8.8-beta.3
new_tag=9.8.8-beta.4
binding="$(sha256sum "$backend/release/pins.env" | awk '{print $1}'):\
$(sha256sum "$backend/release/pins.sh" | awk '{print $1}')"
quick_binding="$(sha256sum "$backend/quick-install.sh" | awk '{print $1}')"
sed -i "s/^RELEASE_TAG=.*/RELEASE_TAG=\"${old_tag}\"/" "$backend/install.sh"
sed -i "s/^RELEASE_PINS_BINDING=.*/RELEASE_PINS_BINDING=\"${binding}\"/" "$backend/install.sh"
sed -i "s/^RELEASE_QUICK_BINDING=.*/RELEASE_QUICK_BINDING=\"${quick_binding}\"/" "$backend/install.sh"
BASE_DIR="$backend"
SCRIPT_DIR="$backend"
SCRIPT_PATH="$backend/install.sh"
RELEASE_PINS_BUNDLE_DIR="$backend/release"
RELEASE_QUICK_PATH="$backend/quick-install.sh"
RELEASE_TAG="$old_tag"
RELEASE_QUICK_BINDING="$quick_binding"
capture_release_pin_pair "$RELEASE_PINS_BUNDLE_DIR"
cleanup_release_pin_snapshot
RELEASE_QUICK_BUNDLE_STATE="$(release_pin_file_state "$RELEASE_QUICK_PATH")"
INSTALLED_BACKEND_SCRIPT_STATE="$(release_pin_file_state "$SCRIPT_PATH")"
INSTALL_LOCK_FILE="$backend/run/install.lock"
INSTALL_LOCK_WAIT_TIMEOUT=5
LOCK_WAIT_REPORT_INTERVAL=1
install -m 0600 /dev/null "$INSTALL_LOCK_FILE"
file_uid() { printf '0\n'; }
file_gid() { printf '0\n'; }
account_gid() { [[ "$1" == root ]] && printf '0\n'; }
chown() { return 0; }
require_completed_runtime_identity() { return 0; }
callback="$backend/callback-ran"
queued_callback() { : > "$callback"; }
holder_ready="$backend/holder-ready"
holder_release="$backend/holder-release"
(
    exec 9>"$INSTALL_LOCK_FILE"
    flock -n 9
    : > "$holder_ready"
    while [[ ! -e "$holder_release" ]]; do sleep 0.05; done
    flock -u 9
) &
holder_pid=$!
for _ in $(seq 1 100); do
    [[ -e "$holder_ready" ]] && break
    sleep 0.02
done
[[ -e "$holder_ready" ]]
run_management_with_install_lock queued_callback >"$backend/wrapper.log" 2>&1 &
wrapper_pid=$!
for _ in $(seq 1 100); do
    grep -Fq 'waiting up to' "$backend/wrapper.log" 2>/dev/null && break
    sleep 0.02
done
grep -Fq 'waiting up to' "$backend/wrapper.log"
sed -i "s/^RELEASE_TAG=.*/RELEASE_TAG=\"${new_tag}\"/" "$SCRIPT_PATH"
: > "$holder_release"
wait "$holder_pid"
if wait "$wrapper_pid"; then
    exit 1
fi
[[ ! -e "$callback" ]]
BASH
then
    pass "the real management wrapper rechecks a queued backend after flock acquisition"
else
    fail "the management wrapper ran a callback through a backend replaced while queued"
fi

exit "$FAIL"
