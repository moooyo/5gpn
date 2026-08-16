#!/usr/bin/env bash
# Materialize the digest-pinned runtime and Console assets before Docker build.
# The Dockerfile never downloads mutable GitHub release content.
set -Eeuo pipefail
umask 0022
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
BUILD_ROOT="$ROOT/docker/build"
FINAL="$BUILD_ROOT/components"
MARKER=.5gpn-docker-components
MARKER_VALUE=5gpn-docker-components-v1
CA_BUNDLE_URL=https://curl.se/ca/cacert-2026-07-16.pem
CA_BUNDLE_SHA256=3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91

fatal() { printf 'error: %s\n' "$*" >&2; exit 1; }

read_pin() {
    local key="$1" lines value count
    count="$(grep -cE "^${key}=" "$INSTALLER" || true)"
    [[ "$count" == 1 ]] || fatal "install.sh must define $key exactly once."
    lines="$(sed -n "s/^${key}=\"\([^\"]*\)\".*/\\1/p" "$INSTALLER")"
    value="$(printf '%s\n' "$lines" | sed -n '1p')"
    [[ -n "$value" ]] || fatal "install.sh has an empty $key pin."
    printf '%s' "$value"
}

manifest_value() {
    local key="$1" manifest="$FINAL/manifest.env" value count
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        || fatal "Prepared component manifest is missing; run $0 first."
    value="$(sed -n "s/^${key}=\(.*\)$/\\1/p" "$manifest")"
    count="$(grep -c "^${key}=" "$manifest" || true)"
    [[ "$count" == 1 && -n "$value" ]] || fatal "Malformed component manifest key: $key"
    printf '%s' "$value"
}

print_labels() {
    printf 'io.5gpn.mihomo.source=%s\n' "$(manifest_value MIHOMO_SOURCE)"
    printf 'io.5gpn.mihomo.repository=%s\n' "$(manifest_value MIHOMO_REPO)"
    printf 'io.5gpn.mihomo.version=%s\n' "$(manifest_value MIHOMO_VERSION)"
    printf 'io.5gpn.mihomo.sha256=%s\n' "$(manifest_value MIHOMO_SHA256)"
    printf 'io.5gpn.mihomo.binary.sha256=%s\n' "$(manifest_value MIHOMO_BINARY_SHA256)"
    printf 'io.5gpn.mihomo.container-contract=%s\n' "$(manifest_value MIHOMO_CONTAINER_CONTRACT)"
    printf 'io.5gpn.zashboard.repository=%s\n' "$(manifest_value ZASH_REPO)"
    printf 'io.5gpn.zashboard.version=%s\n' "$(manifest_value ZASH_VERSION)"
    printf 'io.5gpn.zashboard.sha256=%s\n' "$(manifest_value ZASH_SHA256)"
    printf 'io.5gpn.bootstrap-ca.sha256=%s\n' "$(manifest_value CA_BUNDLE_SHA256)"
}

for command in awk basename cat chmod cmp cp curl dirname find grep gzip mkdir mktemp mv readlink rm sed sha256sum timeout tr unzip; do
    command -v "$command" >/dev/null 2>&1 || fatal "Required command is missing: $command"
done

mihomo_input=""
case "${1:-}" in
    --print-labels)
        [[ $# == 1 ]] || fatal "Usage: $0 [--print-labels | --mihomo-binary PATH]"
        print_labels
        exit 0 ;;
    --mihomo-binary)
        [[ $# == 2 && -n "$2" ]] \
            || fatal "Usage: $0 [--print-labels | --mihomo-binary PATH]"
        mihomo_input="$2" ;;
    "") ;;
    *) fatal "Usage: $0 [--print-labels | --mihomo-binary PATH]" ;;
esac
[[ -f "$INSTALLER" && ! -L "$INSTALLER" ]] || fatal "Unsafe or missing install.sh"

MIHOMO_REPO="$(read_pin MIHOMO_REPO)"
MIHOMO_VERSION="$(read_pin MIHOMO_VERSION)"
MIHOMO_SHA256="$(read_pin MIHOMO_SHA256)"
ZASH_REPO="$(read_pin ZASH_REPO)"
ZASH_VERSION="$(read_pin ZASH_VERSION)"
ZASH_SHA256="$(read_pin ZASH_SHA256)"

[[ "$MIHOMO_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || fatal "Invalid MIHOMO_REPO pin: $MIHOMO_REPO"
[[ "$ZASH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || fatal "Invalid ZASH_REPO pin: $ZASH_REPO"
[[ "$MIHOMO_VERSION" =~ ^v[0-9A-Za-z._-]+$ ]] \
    || fatal "Invalid MIHOMO_VERSION pin: $MIHOMO_VERSION"
[[ "$ZASH_VERSION" =~ ^v[0-9A-Za-z._-]+$ ]] \
    || fatal "Invalid ZASH_VERSION pin: $ZASH_VERSION"
[[ "$MIHOMO_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fatal "Invalid MIHOMO_SHA256 pin."
[[ "$ZASH_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fatal "Invalid ZASH_SHA256 pin."

mkdir -p -- "$BUILD_ROOT"
[[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" \
   && "$(readlink -f -- "$BUILD_ROOT")" == "$BUILD_ROOT" ]] \
    || fatal "Unsafe Docker build scratch root: $BUILD_ROOT"
stage="$(mktemp -d "$BUILD_ROOT/.components.XXXXXX")"
printf '%s\n' "$MARKER_VALUE" > "$stage/$MARKER"

cleanup_stage() {
    local canonical
    [[ -n "${stage:-}" && -d "$stage" && ! -L "$stage" ]] || return 0
    canonical="$(readlink -f -- "$stage" 2>/dev/null || true)"
    [[ "$canonical" == "$BUILD_ROOT"/.components.* \
       && -f "$canonical/$MARKER" && ! -L "$canonical/$MARKER" \
       && "$(<"$canonical/$MARKER")" == "$MARKER_VALUE" ]] \
        || return 1
    rm -rf -- "$canonical"
}
trap cleanup_stage EXIT

verify_digest() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || fatal "SHA-256 mismatch for $(basename -- "$file"): expected $expected, got $actual"
}

mihomo_reports_exact_version() {
    local binary="$1" expected="$2" output first actual
    output="$(mktemp "$stage/.mihomo-version.XXXXXX")" || return 1
    chmod 0600 "$output" || { rm -f -- "$output"; return 1; }
    timeout --signal=KILL 10s "$binary" -v > "$output" 2>/dev/null \
        || { rm -f -- "$output"; return 1; }
    LC_ALL=C tr -d '\000' < "$output" | cmp -s - "$output" \
        || { rm -f -- "$output"; return 1; }
    IFS= read -r first < "$output" \
        || { rm -f -- "$output"; return 1; }
    rm -f -- "$output" || return 1
    [[ "$first" != *$'\r'* \
       && "$first" =~ ^Mihomo\ Meta\ ([^[:space:]]+)\ linux\ amd64\ with\ go[^[:space:]]+\ .+$ ]] \
        || return 1
    actual="${BASH_REMATCH[1]}"
    [[ "$actual" == "$expected" ]]
}

mihomo_reports_container_contract() {
    local binary="$1" output
    output="$(mktemp "$stage/.mihomo-container-contract.XXXXXX")" || return 1
    chmod 0600 "$output" || { rm -f -- "$output"; return 1; }
    timeout --signal=KILL 10s "$binary" 5gpn-container-contract > "$output" 2>/dev/null \
        || { rm -f -- "$output"; return 1; }
    if ! printf '%s\n' '5gpn-container-runtime-v1' | cmp -s - "$output"; then
        rm -f -- "$output"
        return 1
    fi
    rm -f -- "$output"
}

archive_paths_safe() {
    local archive="$1" entry normalized verbose types name_count type_count
    declare -A seen=()
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || fatal "Zashboard archive contains an empty path."
        normalized="${entry%/}"
        [[ -n "$normalized" && "$normalized" != . && "$normalized" != ./* \
           && "$normalized" != /* && "$normalized" != *//* \
           && "$normalized" != *'/./'* && "$normalized" != */. \
           && "$normalized" != ../* && "$normalized" != *'/../'* \
           && "$normalized" != */.. && "$normalized" != *'\\'* ]] \
            || fatal "Zashboard archive contains an unsafe path: $entry"
        [[ -z "${seen[$normalized]+present}" ]] \
            || fatal "Zashboard archive contains a duplicate path: $normalized"
        seen[$normalized]=1
    done < <(unzip -Z1 "$archive")
    ((${#seen[@]} > 0)) || fatal "Zashboard archive is empty."
    verbose="$(unzip -Z -l "$archive")" || fatal "Could not inspect Zashboard archive object types."
    types="$(printf '%s\n' "$verbose" \
        | awk '/^[-dlcbps][rwxstST-]{9}[[:space:]]/ { print substr($0,1,1) }')"
    name_count="${#seen[@]}"
    type_count="$(printf '%s\n' "$types" | awk 'NF { n++ } END { print n+0 }')"
    [[ "$name_count" == "$type_count" \
       && -z "$(printf '%s\n' "$types" | grep -Ev '^[-d]$' || true)" ]] \
        || fatal "Zashboard archive contains an unsupported object type."
}

ZASH_URL="https://github.com/${ZASH_REPO}/releases/download/${ZASH_VERSION}/dist.zip"

printf 'Downloading pinned HTTPS bootstrap CA bundle.\n'
curl -fsSL --retry 3 --retry-delay 2 --max-time 300 \
    "$CA_BUNDLE_URL" -o "$stage/bootstrap-ca.pem"
verify_digest "$stage/bootstrap-ca.pem" "$CA_BUNDLE_SHA256"
chmod 0644 "$stage/bootstrap-ca.pem"

if [[ -n "$mihomo_input" ]]; then
    [[ -f "$mihomo_input" && ! -L "$mihomo_input" ]] \
        || fatal "Development mihomo input is not a plain file: $mihomo_input"
    cp -- "$mihomo_input" "$stage/5gpn-mihomo"
    MIHOMO_SOURCE=development-local
else
    MIHOMO_URL="https://github.com/${MIHOMO_REPO}/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"
    printf 'Downloading pinned mihomo %s.\n' "$MIHOMO_VERSION"
    curl -fsSL --retry 3 --retry-delay 2 --max-time 600 \
        "$MIHOMO_URL" -o "$stage/mihomo.gz"
    verify_digest "$stage/mihomo.gz" "$MIHOMO_SHA256"
    gzip -dc "$stage/mihomo.gz" > "$stage/5gpn-mihomo"
    rm -f -- "$stage/mihomo.gz"
    MIHOMO_SOURCE=pinned-release
fi
chmod 0755 "$stage/5gpn-mihomo"
mihomo_reports_exact_version "$stage/5gpn-mihomo" "$MIHOMO_VERSION" \
    || fatal "Prepared mihomo does not report exact version $MIHOMO_VERSION for linux/amd64."
mihomo_reports_container_contract "$stage/5gpn-mihomo" \
    || fatal "Prepared mihomo does not implement exact 5gpn-container-runtime-v1 contract."
MIHOMO_BINARY_SHA256="$(sha256sum "$stage/5gpn-mihomo" | awk '{print $1}')"
[[ "$MIHOMO_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fatal "Could not compute the prepared mihomo binary digest."

printf 'Downloading pinned Zashboard %s.\n' "$ZASH_VERSION"
curl -fsSL --retry 3 --retry-delay 2 --max-time 600 \
    "$ZASH_URL" -o "$stage/zashboard.zip"
verify_digest "$stage/zashboard.zip" "$ZASH_SHA256"
archive_paths_safe "$stage/zashboard.zip"
mkdir -- "$stage/zashboard-extracted" "$stage/ui"
unzip -q "$stage/zashboard.zip" -d "$stage/zashboard-extracted"
[[ -z "$(find "$stage/zashboard-extracted" -mindepth 1 \
    \( -type l -o ! -type f ! -type d \) -print -quit)" ]] \
    || fatal "Zashboard archive extracted an unsafe object."
[[ -z "$(find "$stage/zashboard-extracted" -type f -links +1 -print -quit)" ]] \
    || fatal "Zashboard archive extracted a hard-linked file."

ui_source="$stage/zashboard-extracted"
if [[ -f "$ui_source/dist/index.html" ]]; then
    ui_source="$ui_source/dist"
fi
[[ -f "$ui_source/index.html" && ! -L "$ui_source/index.html" ]] \
    || fatal "Zashboard archive has no index.html at its supported root."
cp -R -- "$ui_source/." "$stage/ui/"
printf '%s\n' "$ZASH_VERSION" > "$stage/ui/.zash_version"
printf '%s\n' '5gpn-zashboard' > "$stage/ui/.5gpn-zashboard-owned"
find "$stage/ui" -type d -exec chmod 0755 {} +
find "$stage/ui" -type f -exec chmod 0644 {} +
rm -rf -- "$stage/zashboard-extracted"
rm -f -- "$stage/zashboard.zip"

cat > "$stage/manifest.env" <<EOF
MIHOMO_SOURCE=${MIHOMO_SOURCE}
MIHOMO_REPO=${MIHOMO_REPO}
MIHOMO_VERSION=${MIHOMO_VERSION}
MIHOMO_SHA256=${MIHOMO_SHA256}
MIHOMO_BINARY_SHA256=${MIHOMO_BINARY_SHA256}
MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v1
ZASH_REPO=${ZASH_REPO}
ZASH_VERSION=${ZASH_VERSION}
ZASH_SHA256=${ZASH_SHA256}
CA_BUNDLE_URL=${CA_BUNDLE_URL}
CA_BUNDLE_SHA256=${CA_BUNDLE_SHA256}
EOF
chmod 0644 "$stage/manifest.env" "$stage/$MARKER"

if [[ -e "$FINAL" || -L "$FINAL" ]]; then
    [[ -d "$FINAL" && ! -L "$FINAL" \
       && "$(readlink -f -- "$FINAL")" == "$FINAL" \
       && -f "$FINAL/$MARKER" && ! -L "$FINAL/$MARKER" \
       && "$(<"$FINAL/$MARKER")" == "$MARKER_VALUE" ]] \
        || fatal "Refusing to replace an unowned Docker component directory: $FINAL"
    rm -rf -- "$FINAL"
fi
mv -- "$stage" "$FINAL"
stage=""
trap - EXIT

printf 'Prepared Docker components in %s.\n' "$FINAL"
printf 'OCI component labels:\n'
print_labels
