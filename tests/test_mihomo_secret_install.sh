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
MIHOMO_SERVICE_USER="$(id -gn)"
MIHOMO_BIN="$TMP/mihomo"
mkdir -p "$MIHOMO_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MIHOMO_BIN"
chmod 0755 "$MIHOMO_BIN"

fixed_owned_dir_is_safe() { return 0; }
runtime_directory_slot_is_safe() { return 0; }
runtime_file_slot_is_safe() { return 0; }
seed_mihomo_whitelist() { return 0; }
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
