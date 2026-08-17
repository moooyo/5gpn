#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH_LIB_ONLY=1
export INSTALL_SH_LIB_ONLY
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

expected_keys=(
    CERT_EMAIL
    CERT_MODE
    DNS_BASE_DOMAIN
    DNS_GATEWAY_IP
    DNS_MIHOMO_LISTEN_IPS
    DNS_PUBLIC_IP
)
mapfile -t actual_keys < <(printf '%s\n' $DNS_ENV_KEYS | LC_ALL=C sort)
[[ "${actual_keys[*]}" == "${expected_keys[*]}" ]] \
    || fail "current dns.env keys are not the exact six-key schema: ${actual_keys[*]}"
pass "current dns.env schema contains exactly six installer inputs"

is_valid_cert_email 'admin@example.test' \
    || fail "valid certificate email was rejected"
for invalid_email in '' localpart '@example.test' 'admin@' 'admin@@example.test' \
    'admin user@example.test' '.ops@example.test' 'ops.@example.test' \
    'ops..team@example.test' '~/ops@example.test' 'ops@example..com'; do
    is_valid_cert_email "$invalid_email" \
        && fail "invalid certificate email was accepted: ${invalid_email:-<empty>}"
done
pass "certificate email validation rejects empty parts, multiple @ signs, and whitespace"

for retired_function in dns_env_encode_value dns_env_decode_value set_dns_env_kv persist_mihomo_secret; do
    declare -F "$retired_function" >/dev/null \
        && fail "retired dns.env helper still exists: $retired_function"
done
pass "secret encoding, mirroring, and single-key writers are absent"

preflight_root="$TMP/preflight-config"
mkdir -p "$preflight_root"
write_valid_preflight_env() {
    cat > "$preflight_root/dns.env" <<'EOF'
DNS_BASE_DOMAIN=example.test
DNS_PUBLIC_IP=192.0.2.10
DNS_GATEWAY_IP=192.0.2.11
DNS_MIHOMO_LISTEN_IPS=192.0.2.12
CERT_MODE=debug
CERT_EMAIL=admin@example.test
EOF
}
run_dns_env_preflight() {
    (
        CONF_DIR="$preflight_root"
        fixed_root_is_safe_for_readonly_inspection() { return 0; }
        file_uid() { printf '0\n'; }
        file_gid() { printf '0\n'; }
        file_mode() {
            [[ "$1" == "$CONF_DIR" ]] && printf '755\n' || printf '600\n'
        }
        file_nlink() { stat -c %h -- "$1"; }
        resolve_mihomo_listen_ips() {
            [[ "$1" == 192.0.2.12 ]] || return 1
            printf '%s\n' "$1"
        }
        preflight_persisted_dns_env
    )
}

run_unmarked_dns_env_load() {
    (
        CONF_DIR="$preflight_root"
        fixed_root_is_safe_for_readonly_inspection() { return 0; }
        file_uid() { printf '0\n'; }
        file_gid() { printf '0\n'; }
        file_mode() {
            [[ "$1" == "$CONF_DIR" ]] && printf '755\n' || printf '600\n'
        }
        file_nlink() { stat -c %h -- "$1"; }
        resolve_mihomo_listen_ips() {
            [[ "$1" == 192.0.2.12 ]] || return 1
            printf '%s\n' "$1"
        }
        load_persisted_install_config
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$BASE_DOMAIN" "$PUBLIC_IP" "$GATEWAY_IP" \
            "$MIHOMO_LISTEN_IPS" "$CERT_MODE" "$CERT_EMAIL"
    )
}

rm -f -- "$preflight_root/dns.env"
run_dns_env_preflight >/dev/null || fail "fresh install without dns.env failed preflight"
write_valid_preflight_env
before_preflight="$(sha256sum "$preflight_root/dns.env" | awk '{print $1}')"
before_root_metadata="$(stat -Lc '%u:%g:%a:%d:%i' "$preflight_root")"
before_env_metadata="$(stat -Lc '%u:%g:%a:%h:%d:%i' "$preflight_root/dns.env")"
run_dns_env_preflight >/dev/null || fail "valid six-key dns.env failed read-only preflight"
[[ "$before_preflight" == "$(sha256sum "$preflight_root/dns.env" | awk '{print $1}')" ]] \
    || fail "dns.env preflight changed persisted bytes"
loaded_unmarked="$(run_unmarked_dns_env_load)" \
    || fail "safe unmarked dns.env could not be loaded after read-only preflight"
[[ "$loaded_unmarked" == 'example.test|192.0.2.10|192.0.2.11|192.0.2.12|debug|admin@example.test' ]] \
    || fail "safe unmarked dns.env loaded unexpected values: $loaded_unmarked"
[[ ! -e "$preflight_root/$CONF_OWNERSHIP_MARKER" \
   && "$before_root_metadata" == "$(stat -Lc '%u:%g:%a:%d:%i' "$preflight_root")" \
   && "$before_env_metadata" == "$(stat -Lc '%u:%g:%a:%h:%d:%i' "$preflight_root/dns.env")" ]] \
    || fail "unmarked dns.env loading published a marker or changed ownership/mode/identity"
pass "validated dns.env can be loaded before fixed-root marker publication"

revision_root="$TMP/revision-config"
mkdir -p "$revision_root"
cp "$preflight_root/dns.env" "$revision_root/dns.env"
if (
    CONF_DIR="$revision_root"
    fixed_root_is_safe_for_readonly_inspection() { return 0; }
    file_uid() { printf '0\n'; }
    file_gid() { printf '0\n'; }
    file_mode() { [[ "$1" == "$CONF_DIR" ]] && printf '755\n' || printf '600\n'; }
    file_nlink() { stat -c %h -- "$1"; }
    resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
    load_persisted_install_config >/dev/null
    cp "$CONF_DIR/dns.env" "$CONF_DIR/.dns.env.next"
    sed -i 's/^DNS_GATEWAY_IP=.*/DNS_GATEWAY_IP=192.0.2.99/' "$CONF_DIR/.dns.env.next"
    mv -f -- "$CONF_DIR/.dns.env.next" "$CONF_DIR/dns.env"
    ! assert_loaded_persisted_dns_env_revision 0
); then
    pass "dns.env revision drift is rejected after one stable configuration snapshot"
else
    fail "dns.env revision drift can overwrite a concurrently replaced valid file"
fi

cp "$preflight_root/dns.env" "$TMP/valid-preflight.env"
for production_mode in cloudflare http-01; do
    cp "$TMP/valid-preflight.env" "$preflight_root/dns.env"
    sed -i "s/^CERT_MODE=.*/CERT_MODE=${production_mode}/" "$preflight_root/dns.env"
    run_dns_env_preflight >/dev/null \
        || fail "valid production six-key dns.env failed preflight for $production_mode"
done
pass "both production certificate modes accept a valid six-key email configuration"
for invalid_case in unknown missing duplicate malformed carriage domain public gateway mode email email-shape listen empty-listen; do
    cp "$TMP/valid-preflight.env" "$preflight_root/dns.env"
    case "$invalid_case" in
        unknown) printf 'DNS_UNKNOWN=value\n' >> "$preflight_root/dns.env" ;;
        missing) sed -i '/^CERT_EMAIL=/d' "$preflight_root/dns.env" ;;
        duplicate) printf 'CERT_MODE=cloudflare\n' >> "$preflight_root/dns.env" ;;
        malformed) printf 'not-an-assignment\n' >> "$preflight_root/dns.env" ;;
        carriage) printf 'CERT_EMAIL=bad\r\n' >> "$preflight_root/dns.env" ;;
        domain) sed -i 's/^DNS_BASE_DOMAIN=.*/DNS_BASE_DOMAIN=not-a-domain/' "$preflight_root/dns.env" ;;
        public) sed -i 's/^DNS_PUBLIC_IP=.*/DNS_PUBLIC_IP=999.0.0.1/' "$preflight_root/dns.env" ;;
        gateway) sed -i 's/^DNS_GATEWAY_IP=.*/DNS_GATEWAY_IP=010.0.0.1/' "$preflight_root/dns.env" ;;
        mode) sed -i 's/^CERT_MODE=.*/CERT_MODE=automatic/' "$preflight_root/dns.env" ;;
        email)
            sed -i 's/^CERT_MODE=.*/CERT_MODE=cloudflare/; s/^CERT_EMAIL=.*/CERT_EMAIL=invalid email/' "$preflight_root/dns.env"
            ;;
        email-shape)
            sed -i 's/^CERT_MODE=.*/CERT_MODE=http-01/; s/^CERT_EMAIL=.*/CERT_EMAIL=@/' "$preflight_root/dns.env"
            ;;
        listen) sed -i 's/^DNS_MIHOMO_LISTEN_IPS=.*/DNS_MIHOMO_LISTEN_IPS=203.0.113.99/' "$preflight_root/dns.env" ;;
        empty-listen) sed -i 's/^DNS_MIHOMO_LISTEN_IPS=.*/DNS_MIHOMO_LISTEN_IPS=/' "$preflight_root/dns.env" ;;
    esac
    run_dns_env_preflight >/dev/null 2>&1 \
        && fail "dns.env preflight accepted $invalid_case input"
done
rm -f -- "$preflight_root/dns.env"
ln -s "$TMP/valid-preflight.env" "$preflight_root/dns.env"
run_dns_env_preflight >/dev/null 2>&1 \
    && fail "dns.env preflight accepted a symlink"
rm -f -- "$preflight_root/dns.env"
ln "$TMP/valid-preflight.env" "$preflight_root/dns.env"
run_dns_env_preflight >/dev/null 2>&1 \
    && fail "dns.env preflight accepted a hardlink"
rm -f -- "$preflight_root/dns.env"
pass "pre-publication dns.env validation rejects unsafe and non-six-key inputs read-only"

CONF_DIR="$TMP/etc-5gpn"
mkdir -p "$CONF_DIR"
printf '%s\n' "$CONF_OWNERSHIP_VALUE" > "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
chmod 0644 "$CONF_DIR/$CONF_OWNERSHIP_MARKER"
cat > "$CONF_DIR/dns.env" <<'EOF'
DNS_BASE_DOMAIN=old.example
DNS_PUBLIC_IP=192.0.2.9
DNS_GATEWAY_IP=192.0.2.9
DNS_MIHOMO_LISTEN_IPS=192.0.2.9
CERT_MODE=debug
CERT_EMAIL=admin@old.example
EOF
chmod 0600 "$CONF_DIR/dns.env"
cp "$CONF_DIR/dns.env" "$TMP/original.env"
LOADED_DNS_ENV_SOURCE_STATE=present
LOADED_DNS_ENV_SOURCE_REVISION="$(sha256sum "$CONF_DIR/dns.env" | awk '{print $1}')"
LOADED_DNS_ENV_SOURCE_IDENTITY="$(stat -Lc '%d:%i' -- "$CONF_DIR/dns.env")"

fixed_owned_dir_is_safe() { return 0; }
runtime_file_slot_is_safe() { return 0; }
resolve_mihomo_listen_ips() { printf '%s\n' "$1"; }
BASE_DOMAIN=example.com
PUBLIC_IP=192.0.2.10
GATEWAY_IP=192.0.2.11
MIHOMO_LISTEN_IPS=192.0.2.12
CERT_MODE=debug
CERT_EMAIL=admin@example.com
mktemp() { return 74; }

if write_dns_env >/dev/null 2>&1; then
    fail "write_dns_env swallowed candidate creation failure"
fi
cmp -s "$CONF_DIR/dns.env" "$TMP/original.env" \
    || fail "write_dns_env changed live bytes after candidate creation failure"
pass "write_dns_env propagates candidate creation failure"

unset -f mktemp
chown() { return 0; }
sync() { return 0; }
file_uid() { printf '0\n'; }
file_gid() { printf '0\n'; }
file_mode() {
    case "$1" in
        "$CONF_DIR") printf '755\n' ;;
        "$CONF_DIR/$CONF_OWNERSHIP_MARKER") printf '644\n' ;;
        *) printf '600\n' ;;
    esac
}
file_nlink() { printf '1\n'; }

write_dns_env >/dev/null || fail "write_dns_env rejected the six-key candidate"
mapfile -t written_keys < <(
    sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$CONF_DIR/dns.env" | LC_ALL=C sort
)
[[ "${written_keys[*]}" == "${expected_keys[*]}" ]] \
    || fail "write_dns_env emitted unexpected keys: ${written_keys[*]}"
grep -Fxq 'DNS_BASE_DOMAIN=example.com' "$CONF_DIR/dns.env" \
    || fail "base domain was not written"
grep -Fxq 'DNS_PUBLIC_IP=192.0.2.10' "$CONF_DIR/dns.env" \
    || fail "public IP was not written"
grep -Fxq 'DNS_GATEWAY_IP=192.0.2.11' "$CONF_DIR/dns.env" \
    || fail "gateway IP was not written"
grep -Fxq 'DNS_MIHOMO_LISTEN_IPS=192.0.2.12' "$CONF_DIR/dns.env" \
    || fail "listener IPs were not written"
pass "write_dns_env publishes only the exact current values"

for retired_key in \
    DNS_LISTEN_DOT DNS_LISTEN_DEBUG DNS_CONSOLE_CERT DNS_CONSOLE_KEY \
    DNS_MIHOMO_CONTROLLER DNS_MIHOMO_SECRET DNS_CERT DNS_KEY DNS_WEB_CERT \
    DNS_WEB_KEY WWW_DIR DNS_CHINA_ECS; do
    grep -Eq "^${retired_key}=" "$CONF_DIR/dns.env" \
        && fail "write_dns_env still publishes retired key $retired_key"
done
pass "fixed coordinates and the controller secret are absent from dns.env"

[[ "$DOT_LISTEN_ADDR" == :853 ]] || fail "DoT listener constant drifted"
[[ "$DEBUG_LISTEN_ADDR" == 127.0.0.1:5353 ]] || fail "debug listener constant drifted"
[[ "$ORIGIN_LISTEN_ADDR" == 127.0.0.1:5354 ]] || fail "origin listener constant drifted"
[[ "$MIHOMO_CONTROLLER_TLS_ADDR" == 127.0.0.1:443 ]] \
    || fail "controller listener constant drifted"
[[ "$MIHOMO_CONTROLLER_CERT" == /etc/5gpn/cert/console/current/fullchain.pem ]] \
    || fail "controller certificate constant drifted"
[[ "$MIHOMO_CONTROLLER_KEY" == /etc/5gpn/cert/console/current/privkey.pem ]] \
    || fail "controller private-key constant drifted"
pass "fixed listeners and certificate paths are installer constants"

# The heredoc is interpolated, so comments must not contain live command
# substitutions.
heredoc_body="$(sed -n '/^    if ! cat > "\$dns_env_tmp" <<EOF$/,/^EOF$/p' "$ROOT/install.sh")"
[[ -n "$heredoc_body" ]] || fail "could not extract the dns.env heredoc"
if printf '%s' "$heredoc_body" | grep -q '`'; then
    fail "the dns.env heredoc contains a live backtick substitution"
fi
if printf '%s' "$heredoc_body" | grep -qF '$('; then
    fail "the dns.env heredoc contains a live command substitution"
fi
pass "the dns.env heredoc carries no live command substitution"

writer_fn="$(sed -n '/^write_dns_env()/,/^}/p' "$ROOT/install.sh")"
printf '%s' "$writer_fn" | grep -Eq 'DNS_MIHOMO_SECRET|mihomo_controller_inspection|DNS_CONSOLE_(CERT|KEY)' \
    && fail "write_dns_env still reads or mirrors controller state"
pass "dns.env publication is independent of controller state"

for retired_key in \
    DNS_LISTEN_DOT DNS_LISTEN_DEBUG DNS_CONSOLE_CERT DNS_CONSOLE_KEY \
    DNS_MIHOMO_CONTROLLER DNS_MIHOMO_SECRET; do
    legacy_dns_env_key_is_known "$retired_key" \
        || fail "wider pre-release key is not classified as unsupported legacy: $retired_key"
done
pass "the wider pre-release schema is rejected explicitly"

echo "dns.env write safety: PASS"
