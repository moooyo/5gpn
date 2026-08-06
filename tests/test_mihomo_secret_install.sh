#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH_LIB_ONLY=1 source "$ROOT/install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for secret in 'actual # secret' 'controller"secret' 'controller\secret' "controller'secret" '12345'; do
    encoded="$(dns_env_encode_value "$secret")" || fail "could not encode secret: $secret"
    decoded="$(dns_env_decode_value "$encoded")" || fail "could not decode secret: $secret"
    [[ "$decoded" == "$secret" ]] || fail "dns.env secret round trip changed: $secret"
    yaml_value="$(yaml_single_quoted_value "$secret")" || fail "could not quote YAML secret: $secret"
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

sensitive_connection="$({
    CONSOLE_DOMAIN=console.example.test
    cfg_get() {
        [[ "$1" == DNS_MIHOMO_SECRET ]] || return 1
        printf '%s' "$setup_secret"
    }
    print_console_connection_info 1
})" || fail "could not render interactive Console connection information"
for field in \
    "$expected_setup" \
    'Clash API' \
    'HTTPS' \
    'console.example.test' \
    '443' \
    'Secondary Path      留空' \
    "$setup_secret" \
    '127.0.0.1' \
    '浏览器所在的客户端'; do
    grep -Fq "$field" <<<"$sensitive_connection" \
        || fail "interactive Console output omitted: $field"
done
grep -Fq '上述链接等同于密码' <<<"$sensitive_connection" \
    || fail "setup link is not labelled as password-equivalent"

oversize_connection="$({
    CONSOLE_DOMAIN=console.example.test
    cfg_get() {
        [[ "$1" == DNS_MIHOMO_SECRET ]] || return 1
        printf '%s' "$oversize_secret"
    }
    print_console_connection_info 1
})" || fail "an oversized secret made post-install Console output fail"
grep -Fq '一键连接不可用' <<<"$oversize_connection" \
    || fail "oversized secret output did not explain the manual fallback"
grep -Fq '#/setup?' <<<"$oversize_connection" \
    && fail "oversized secret output emitted a setup link the Console rejects"
grep -Fq "$oversize_secret" <<<"$oversize_connection" \
    || fail "oversized secret output omitted the manual password"

grep -Fq "secret: '__CONTROLLER_SECRET__'" "$ROOT/etc/mihomo/config.yaml.tmpl" \
    || fail "mihomo seed does not quote the controller secret placeholder"

TMP="$(mktemp -d)"
case "$TMP" in
    /tmp/*|/var/tmp/*) ;;
    *) fail "unexpected temporary directory: $TMP" ;;
esac
trap 'rm -rf -- "$TMP"' EXIT

CONF_DIR="$TMP/etc-5gpn"
MIHOMO_DIR="$CONF_DIR/mihomo"
SCRIPT_DIR="$ROOT"
FIVEGPN_SERVICE_GROUP="$(id -gn)"
MIHOMO_BIN="$TMP/mihomo"
mkdir -p "$MIHOMO_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MIHOMO_BIN"
chmod 0755 "$MIHOMO_BIN"

fixed_owned_dir_is_safe() { return 0; }
runtime_directory_slot_is_safe() { return 0; }
runtime_file_slot_is_safe() { return 0; }
install() { return 0; }
mihomo_config_secret() { return 23; }
PERSIST_CALLS=0
persist_mihomo_secret() { PERSIST_CALLS=$((PERSIST_CALLS + 1)); }
err() { :; }
ok() { :; }

CONFIG="$MIHOMO_DIR/config.yaml"
EXPECTED="$TMP/expected.yaml"
printf 'secret: controller-secret\n' > "$CONFIG"
cp "$CONFIG" "$EXPECTED"

# Invoke through a conditional so Bash suppresses errexit inside the function.
# Explicit parser error handling must still stop both installation paths.
if render_mihomo_config; then
    fail "preserve path continued after secret parser failure"
fi
cmp -s "$CONFIG" "$EXPECTED" || fail "preserve path changed the live config"
[[ "$PERSIST_CALLS" == 0 ]] || fail "preserve path persisted a secret after parser failure"

if render_mihomo_config --reset; then
    fail "reset path continued after secret parser failure"
fi
cmp -s "$CONFIG" "$EXPECTED" || fail "reset path published a config after parser failure"
[[ "$PERSIST_CALLS" == 0 ]] || fail "reset path persisted a secret after parser failure"
if compgen -G "$MIHOMO_DIR/.config.yaml.*" >/dev/null; then
    fail "reset path staged a candidate after parser failure"
fi
if compgen -G "$CONFIG.bak.*" >/dev/null; then
    fail "reset path created a backup after parser failure"
fi

echo "mihomo secret installer flow: PASS"
