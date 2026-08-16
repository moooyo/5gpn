#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/cert-renew.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

export CERT_RENEW_LIB_ONLY=1
# shellcheck source=../scripts/cert-renew.sh
source "$HELPER"

CONFIG_ROOT="$TMP/config"
CERT_ROOT="$CONFIG_ROOT/cert"
mkdir -p "$CERT_ROOT"
chmod 0755 "$CONFIG_ROOT"
chmod 0751 "$CERT_ROOT"
chmod g-s "$CERT_ROOT"
printf '%s\n' "$CONFIG_ROOT_MARKER_VALUE" > "$CONFIG_ROOT/$CONFIG_ROOT_MARKER"
printf '%s\n' "$CERT_ROOT_MARKER_VALUE" > "$CERT_ROOT/$CERT_ROOT_MARKER"
printf '%s\n' 'mode=cloudflare' 'base=example.test' 'certbot_lineage=owned' \
    > "$CERT_ROOT/.provenance"
chmod 0644 "$CONFIG_ROOT/$CONFIG_ROOT_MARKER" "$CERT_ROOT/$CERT_ROOT_MARKER"
chmod 0640 "$CERT_ROOT/.provenance"

named_group_gid() { id -g; }

for role in dot console; do
    generation="$CERT_ROOT/$role/generations/generation-20000101T000000Z-1-1"
    mkdir -p "$generation"
    chmod 0750 "$CERT_ROOT/$role" "$CERT_ROOT/$role/generations" "$generation"
    chmod g-s "$CERT_ROOT/$role" "$CERT_ROOT/$role/generations" "$generation"
    printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:${role}" \
        > "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
    printf '%s\n' cert > "$generation/fullchain.pem"
    printf '%s\n' key > "$generation/privkey.pem"
    chmod 0644 "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
    chmod 0640 "$generation/fullchain.pem" "$generation/privkey.pem"
    ln -s generations/generation-20000101T000000Z-1-1 "$CERT_ROOT/$role/current"
done

certificate_role_tree_safe || fail "canonical certificate role tree was rejected"
pass "canonical certificate root and role generations validate"

mkdir -p "$CERT_ROOT/web"
if certificate_role_tree_safe; then
    fail "retired web certificate role was accepted"
fi
rm -rf -- "$CERT_ROOT/web"
pass "retired certificate roles fail closed"

dot_key="$CERT_ROOT/dot/current/privkey.pem"
ln -- "$dot_key" "$TMP/key-hardlink"
if certificate_role_tree_safe; then
    fail "hardlinked role private key was accepted"
fi
rm -f -- "$TMP/key-hardlink"
pass "hardlinked role private key fails closed"

mv -- "$CERT_ROOT/console" "$CERT_ROOT/console.saved"
ln -s console.saved "$CERT_ROOT/console"
if certificate_role_tree_safe; then
    fail "symlinked certificate role was accepted"
fi
rm -f -- "$CERT_ROOT/console"
mv -- "$CERT_ROOT/console.saved" "$CERT_ROOT/console"
pass "symlinked certificate role fails closed"

original_file_uid="$(declare -f file_uid)"
UNSAFE_OWNER_PATH="$CERT_ROOT/console/$CERT_ROLE_MARKER"
file_uid() {
    if [[ "$1" == "$UNSAFE_OWNER_PATH" ]]; then
        printf '%s\n' "$((EUID + 1))"
    else
        stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true
    fi
}
if certificate_role_tree_safe; then
    fail "service-owned role marker was accepted"
fi
eval "$original_file_uid"
pass "service-owned role marker fails closed"

# The core's own state directory survives the installer's mode sweep.
#
# install.sh hardens everything under the mihomo home to 0660/2770. 5gpn/ must be
# excluded: state.Dir keeps it 0711 so the certificate oneshot -- root with an
# empty capability bounding set, and therefore subject to ordinary permission
# checks -- can traverse without listing, and the certificate request is 0644 so
# that same oneshot can read it. Sweeping it to 0660 left the request unreadable
# by the only process that mints leaves, until the engine happened to rewrite it.
#
# Found by upgrading test-env. A fresh install writes the right modes and the
# sweep only reaches these documents on a host where they already exist, so no
# amount of fresh-install acceptance could have caught it.
sweep="$(sed -n '/^    install -d -o root -g "\$FIVEGPN_SERVICE_USER" -m 3770 "\$MIHOMO_DIR" || return 1$/,/^    for path in config.yaml; do$/p' "$ROOT/install.sh")"
[[ -n "$sweep" ]] || fail "could not extract the mihomo home mode sweep"
[[ "$(printf '%s' "$sweep" | grep -c -- '-path "\$FIVEGPN_STATE_DIR" -prune')" == 2 ]] \
    || fail "the mode sweep does not prune \$FIVEGPN_STATE_DIR; the certificate request loses 0644"
pass "the mode sweep prunes the core's 5gpn/ state directory"

# The one-shot node helper's persistent lock is root-owned in the sticky mihomo
# directory. Letting the generic runtime sweep hand it to fivegpn would allow
# the service account to replace the locked inode and defeat transaction
# exclusion on the next TUI edit.
permissions_fn="$(sed -n '/^prepare_runtime_permissions()/,/^}/p' "$ROOT/install.sh")"
printf '%s' "$permissions_fn" | grep -Fq '! -path "$node_lock"' \
    && printf '%s' "$permissions_fn" | grep -Fq '! -path "$node_backup"' \
    || fail "the generic mihomo mode sweep still rewrites node transaction files"
printf '%s' "$permissions_fn" | grep -Fq 'chown root:root "$node_lock"' \
    && printf '%s' "$permissions_fn" | grep -Fq 'chmod 0600 "$node_lock"' \
    || fail "the node transaction lock is not normalized to root:root 0600"
printf '%s' "$permissions_fn" | grep -Fq 'chown "root:$FIVEGPN_SERVICE_GROUP" "$node_backup"' \
    && printf '%s' "$permissions_fn" | grep -Fq 'chmod 0640 "$node_backup"' \
    || fail "the previous node config backup is not normalized like config.yaml"
pass "the installer preserves the node helper's lock and backup ownership contract"



# Every current publication path must name the same two certificate roles.
#
# The first check names the sites known to enumerate roles. The second sweeps
# for the retired name
# anywhere it could still be load-bearing, so a site nobody thought to add to
# the list above cannot hide.
for site in 'deploy_cert_roles'; do
    body="$(sed -n "/^${site}()/,/^}/p" "$ROOT/install.sh")"
    [[ -n "$body" ]] || fail "$site is missing"
    printf '%s' "$body" | grep -Fq 'console' \
        || fail "$site does not know the console certificate role"
    printf '%s' "$body" | grep -Fq 'dot' \
        || fail "$site does not know the DoT certificate role"
    printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])web([^[:alnum:]_]|$)' \
        && fail "$site still names the retired web certificate role"
    printf '%s' "$body" | grep -Fq 'zash' \
        && fail "$site still names the retired zash certificate role"
done
body="$(sed -n '/^publish_roles()/,/^}/p' "$ROOT/scripts/renew-hook.sh")"
[[ -n "$body" ]] || fail "publish_roles is missing from renew-hook.sh"
printf '%s' "$body" | grep -Fq 'console' \
    || fail "publish_roles does not know the console certificate role"
printf '%s' "$body" | grep -Fq 'dot' \
    || fail "publish_roles does not know the DoT certificate role"
printf '%s' "$body" | grep -Eq '(^|[^[:alnum:]_])web([^[:alnum:]_]|$)' \
    && fail "publish_roles still names the retired web certificate role"
printf '%s' "$body" | grep -Fq 'zash' \
    && fail "publish_roles still names the retired zash certificate role"
pass "current certificate publication enumerates only dot and console"

body="$(sed -n '/^role_copies_match_live()/,/^}/p' "$ROOT/scripts/cert-renew.sh")"
[[ -n "$body" ]] || fail "role_copies_match_live is missing from cert-renew.sh"
printf '%s' "$body" | grep -Fq 'for role in dot console' \
    || fail "renewal freshness checks are not limited to dot and console"
pass "renewal compares only current dot and console copies"

# The sweep. A role name reaches the filesystem as a cert path or as a member of
# a roles=() array; those two shapes must name only current roles.
#
# It covers every shipped helper/config and the CI renderers, and tolerates an
# escaped slash. This is why
# `cert[\\]?/(web|zash)` rather than only the unescaped path.
#
# The read-only legacy-footprint detector is exempt: naming the retired paths
# is how it rejects them before publication.

preflight_free_install="$TMP/preflight-free-install"
awk '
    /^detect_legacy_footprints\(\)/ { skip = 1 }
    skip && /^kernel_release_supports_extension_workers\(\)/ { skip = 0 }
    skip { print ""; next }
    { print }
' "$ROOT/install.sh" > "$preflight_free_install"

RETIRED_ROLE_SHAPES='cert[\\]?/(web|zash)|CERT_DIR\}/(web|zash)|roles=\([^)]*(web|zash)'
retired_role_sites="$(
    grep -rnE "$RETIRED_ROLE_SHAPES" \
        --include='*.sh' --include='*.tmpl' --include='*.example' --include='*.yml' \
        "$ROOT/scripts" "$ROOT/etc" "$ROOT/.github" 2>/dev/null || true
    grep -nE "$RETIRED_ROLE_SHAPES" "$preflight_free_install" 2>/dev/null \
        | sed "s|^|${ROOT}/install.sh:|" || true
)"
retired_role_sites="$(printf '%s' "$retired_role_sites" | grep -v ':[0-9]*:[[:space:]]*#' || true)"
rm -f -- "$preflight_free_install"
[[ -z "$retired_role_sites" ]] || fail "retired certificate role still reachable:
$retired_role_sites"
pass "no retired certificate path or role array remains"
echo "certificate role tree safety: PASS"
