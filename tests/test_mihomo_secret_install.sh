#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH_LIB_ONLY=1 source "$ROOT/install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() { echo "ok: $*"; }

for retired_function in \
    mihomo_config_secret persist_mihomo_secret set_dns_env_kv \
    dns_env_encode_value dns_env_decode_value rotate_token; do
    declare -F "$retired_function" >/dev/null \
        && fail "retired secret helper still exists: $retired_function"
done
grep -Eq '^([[:space:]]*)rotate-token\)' "$ROOT/install.sh" \
    && fail "rotate-token command dispatch still exists"
grep -F -- '-H "Authorization: Bearer' \
    "$ROOT/install.sh" "$ROOT"/scripts/*.sh \
    "$ROOT"/tests/*.md "$ROOT"/tests/acceptance/*.md >/dev/null \
    && fail "a controller bearer still appears in curl argv"
deployment_smoke="$ROOT/tests/deployment-smoke.md"
grep -Fq 'jq -cse' "$deployment_smoke" \
    && grep -Fq 'select(length == 1)' "$deployment_smoke" \
    && grep -Fq '"certificate","external_controller_tls","external_ui","private_key","raw_revision","secret","version"' "$deployment_smoke" \
    && grep -Fq 'explode | all(. >= 32 and . != 127)' "$deployment_smoke" \
    || fail "deployment smoke does not validate the exact version-2 inspector projection before reading the secret"
pass "the shell YAML parser, secret mirror, and partial rotation writer are absent"

for secret in 'actual # secret' 'controller"secret' 'controller\secret' "controller'secret" '12345'; do
    yaml_value="$(yaml_single_quoted_value "$secret")" \
        || fail "could not quote YAML secret: $secret"
    [[ -n "$yaml_value" ]] || fail "empty YAML secret encoding"
done

setup_secret='controller #&?/%'
setup_url="$(console_setup_url console.example.test "$setup_secret")" \
    || fail "could not build zashboard setup URL"
expected_setup='https://console.example.test/ui/#/setup?type=clash&hostname=console.example.test&port=443&https=1&secret=controller%20%23%26%3F%2F%25&label=5gpn&disableTunMode=1'
[[ "$setup_url" == "$expected_setup" ]] \
    || fail "zashboard setup URL was not encoded field-by-field: $setup_url"
[[ "${setup_url%%#*}" != *"$setup_secret"* ]] \
    || fail "controller secret appeared before the client-side fragment"
for invalid_secret in '' $'line\nfeed' $'carriage\rreturn'; do
    if console_setup_url console.example.test "$invalid_secret" >/dev/null; then
        fail "zashboard setup URL accepted an empty or multiline secret"
    fi
done
boundary_secret="$(printf 'x%.0s' {1..4096})"
console_setup_url console.example.test "$boundary_secret" >/dev/null \
    || fail "zashboard setup URL rejected a 4096-byte secret"
oversize_secret="${boundary_secret}x"
if console_setup_url console.example.test "$oversize_secret" >/dev/null; then
    fail "zashboard setup URL accepted a secret above 4096 UTF-8 bytes"
fi
pass "Console setup fragments encode the inspected secret safely"

TMP="$(mktemp -d /var/tmp/5gpn-mihomo-secret.XXXXXX)"
case "$TMP" in
    /tmp/*|/var/tmp/*) ;;
    *) fail "unexpected temporary directory: $TMP" ;;
esac
trap 'rm -rf -- "$TMP"' EXIT

MIHOMO_DIR="$TMP/etc-5gpn/mihomo"
MIHOMO_BIN="$TMP/mihomo"
ARTIFACT_STAGE=""
mkdir -p "$MIHOMO_DIR"
CONFIG="$MIHOMO_DIR/config.yaml"
printf 'operator config bytes\n' > "$CONFIG"

cat > "$MIHOMO_BIN" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == 5gpn-config && "${2:-}" == inspect-controller && "${3:-}" == --config ]]; then
    revision="$(sha256sum "$4" | awk '{print $1}')"
    case "${MOCK_INSPECTION_MODE:-valid}" in
        valid)
            jq -nc --arg revision "$revision" --arg secret 'controller"secret' \
                '{version:2,raw_revision:$revision,secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        reset)
            jq -nc --arg revision "$revision" --arg secret "operator's secret" \
                '{version:2,raw_revision:$revision,secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        bad-version)
            jq -nc --arg revision "$revision" \
                '{version:1,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        bad-address)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:9090",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        bad-ui)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/tmp/ui",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        flat-ui)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        bad-certificate)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/tmp/controller.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        bad-private-key)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/tmp/controller.key"}' ;;
        missing-field)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem"}' ;;
        extra-field)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem",extra:true}' ;;
        multiline)
            jq -nc --arg revision "$revision" --arg secret $'line\nfeed' \
                '{version:2,raw_revision:$revision,secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        multiple)
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"secret",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}'
            jq -nc --arg revision "$revision" \
                '{version:2,raw_revision:$revision,secret:"second",external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}' ;;
        fail) exit 23 ;;
        *) exit 24 ;;
    esac
    exit 0
fi
if [[ "${1:-}" == -t ]]; then
    exit 0
fi
exit 25
MOCK
chmod 0755 "$MIHOMO_BIN"

inspection="$(mihomo_controller_inspection "$CONFIG")" \
    || fail "valid structured controller inspection was rejected"
[[ "$(mihomo_controller_inspection_field "$inspection" secret)" == 'controller"secret' ]] \
    || fail "inspector secret field changed"
[[ "$(mihomo_controller_inspection_field "$inspection" raw_revision)" == "$(sha256sum "$CONFIG" | awk '{print $1}')" ]] \
    || fail "inspector raw revision changed"
pass "the versioned inspector projection is accepted structurally"

for mode in bad-version bad-address bad-ui flat-ui bad-certificate bad-private-key missing-field extra-field multiline multiple fail; do
    export MOCK_INSPECTION_MODE="$mode"
    if mihomo_controller_inspection "$CONFIG" >/dev/null 2>&1; then
        fail "invalid inspector response was accepted: $mode"
    fi
done
unset MOCK_INSPECTION_MODE
pass "invalid, widened, or unsafe inspector responses fail closed"

# The bearer is supplied through a dedicated inherited descriptor, while stdin
# remains available for a streamed request body.
auth_header_capture="$TMP/auth-header"
body_capture="$TMP/request-body"
mihomo_controller_inspection() {
    jq -nc --arg secret "$setup_secret" \
        '{version:2,raw_revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}'
}
mihomo_controller_curl_with_inspection() {
    local header_path="" arg
    shift 2
    [[ "$*" != *"$setup_secret"* ]] || fail "bearer secret appeared in controller curl arguments"
    while (($#)); do
        arg="$1"; shift
        if [[ "$arg" == -H && $# -gt 0 ]]; then
            arg="$1"; shift
            [[ "$arg" == @/proc/self/fd/* ]] && header_path="${arg#@}"
        fi
    done
    [[ -n "$header_path" ]] || fail "controller request did not receive a descriptor-backed header"
    cat "$header_path" > "$auth_header_capture"
    cat > "$body_capture"
}
printf 'streamed-request-body' \
    | mihomo_authenticated_controller_curl /configs --data-binary @- \
    || fail "descriptor-backed controller request failed"
[[ "$(cat "$auth_header_capture")" == "Authorization: Bearer $setup_secret" ]] \
    || fail "descriptor-backed bearer header changed"
[[ "$(cat "$body_capture")" == streamed-request-body ]] \
    || fail "bearer descriptor consumed or changed request-body stdin"
auth_fn="$(sed -n '/^mihomo_authenticated_controller_curl()/,/^}/p' "$ROOT/install.sh")"
printf '%s' "$auth_fn" | grep -Fq -- '-H "@/proc/self/fd/${auth_fd}"' \
    && printf '%s' "$auth_fn" | grep -Fq 'exec {auth_fd}<<<"Authorization: Bearer $secret"' \
    && printf '%s' "$auth_fn" | grep -Fq 'exec {auth_fd}<&-' \
    || fail "authenticated controller client does not pass a descriptor-backed header"
printf '%s' "$auth_fn" | grep -Fq -- '-H "Authorization: Bearer $secret"' \
    && fail "authenticated controller client still places the bearer in curl argv"
pass "controller bearer stays out of argv without consuming request-body stdin"

public_connection="$({
    CONSOLE_DOMAIN=console.example.test
    print_console_connection_info 0
})" || fail "could not render non-sensitive Console connection information"
grep -Fq 'https://console.example.test/ui/' <<<"$public_connection" \
    || fail "non-sensitive Console output omitted the public URL"
grep -Fq 'sudo 5gpn' <<<"$public_connection" \
    || fail "non-sensitive Console output omitted the host recovery instruction"
grep -Fq "$setup_secret" <<<"$public_connection" \
    && fail "non-sensitive Console output leaked the controller secret"
grep -Fq '#/setup?' <<<"$public_connection" \
    && fail "non-sensitive Console output leaked the password-equivalent setup link"

mihomo_controller_inspection() {
    jq -nc --arg secret "$setup_secret" \
        '{version:2,raw_revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}'
}
sensitive_connection="$({
    CONSOLE_DOMAIN=console.example.test
    print_console_connection_info 1
})" || fail "could not render interactive Console connection information"
for field in "$expected_setup" 'Clash API' 'HTTPS' 'console.example.test' '443' "$setup_secret" '127.0.0.1'; do
    grep -Fq "$field" <<<"$sensitive_connection" \
        || fail "interactive Console output omitted: $field"
done
pass "sensitive Console output reads the current inspector projection"

mihomo_controller_inspection() {
    jq -nc --arg secret "$oversize_secret" \
        '{version:2,raw_revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",secret:$secret,external_controller_tls:"127.0.0.1:443",external_ui:"/opt/5gpn/ui/current",certificate:"/etc/5gpn/cert/console/current/fullchain.pem",private_key:"/etc/5gpn/cert/console/current/privkey.pem"}'
}
oversize_connection="$({
    CONSOLE_DOMAIN=console.example.test
    print_console_connection_info 1
})" || fail "an oversized secret made post-install Console output fail"
grep -Fq '一键连接不可用' <<<"$oversize_connection" \
    || fail "oversized secret output did not explain the manual fallback"
grep -Fq '#/setup?' <<<"$oversize_connection" \
    && fail "oversized secret output emitted a setup link the Console rejects"
grep -Fq "$oversize_secret" <<<"$oversize_connection" \
    || fail "oversized secret output omitted the manual password"

# Restore the production implementation after the output stubs above.
unset -f mihomo_controller_inspection
eval "$(sed -n '/^mihomo_controller_inspection()/,/^}/p' "$ROOT/install.sh")"

CONF_DIR="$TMP/etc-5gpn"
MIHOMO_DIR="$CONF_DIR/mihomo"
BASE_DIR="$TMP/opt-5gpn"
MIHOMO_BIN="$TMP/mihomo"
SCRIPT_DIR="$ROOT"
FIVEGPN_SERVICE_GROUP="$(id -gn)"
mkdir -p "$MIHOMO_DIR" "$BASE_DIR/etc/mihomo"
cp "$ROOT/etc/mihomo/config.yaml.tmpl" "$BASE_DIR/etc/mihomo/config.yaml.tmpl"
CONFIG="$MIHOMO_DIR/config.yaml"
printf 'secret: old\noperator-owned: true\n' > "$CONFIG"
cp "$CONFIG" "$TMP/operator-before.yaml"

fixed_owned_dir_is_safe() { return 0; }
runtime_directory_slot_is_safe() { return 0; }
runtime_file_slot_is_safe() { return 0; }
runtime_tree_has_only_plain_entries() { return 0; }
install() { return 0; }
chown() { return 0; }
sync() { return 0; }
err() { :; }
ok() { :; }

export MOCK_INSPECTION_MODE=valid
render_mihomo_config || fail "normal preserve path rejected a valid inspector response"
cmp -s "$CONFIG" "$TMP/operator-before.yaml" \
    || fail "normal reinstall changed operator config bytes"
pass "normal reinstall validates and preserves the complete operator file"

mihomo_controller_inspection() { return 23; }
if render_mihomo_config --reset; then
    fail "reset path continued after inspector failure"
fi
cmp -s "$CONFIG" "$TMP/operator-before.yaml" \
    || fail "reset path published a config after inspector failure"
if compgen -G "$MIHOMO_DIR/.config.yaml.*" >/dev/null; then
    fail "reset path staged a candidate after inspector failure"
fi
if compgen -G "$CONFIG.bak.*" >/dev/null; then
    fail "reset path created a backup after inspector failure"
fi
pass "inspector failure stops reset before any candidate or backup"

unset -f mihomo_controller_inspection
eval "$(sed -n '/^mihomo_controller_inspection()/,/^}/p' "$ROOT/install.sh")"
resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
BASE_DOMAIN=example.test
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.10
MIHOMO_LISTEN_IPS=192.0.2.10
export MOCK_INSPECTION_MODE=reset
render_mihomo_config --reset || fail "explicit reset rejected a valid inspected secret"
grep -Fq "secret: 'operator''s secret'" "$CONFIG" \
    || fail "explicit reset did not preserve the structurally inspected secret"
backup="$(compgen -G "$CONFIG.bak.*" | head -1)"
[[ -n "$backup" ]] || fail "explicit reset did not retain a backup"
cmp -s "$backup" "$TMP/operator-before.yaml" \
    || fail "explicit reset backup does not contain the original bytes"
pass "explicit reset preserves the unique config secret and backs up old bytes"

echo "mihomo secret inspector flow: PASS"
