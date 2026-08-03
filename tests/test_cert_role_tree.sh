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
chmod 3771 "$CONFIG_ROOT"
chmod 0751 "$CERT_ROOT"
chmod g-s "$CERT_ROOT"
printf '%s\n' "$CONFIG_ROOT_MARKER_VALUE" > "$CONFIG_ROOT/$CONFIG_ROOT_MARKER"
printf '%s\n' "$CERT_ROOT_MARKER_VALUE" > "$CERT_ROOT/$CERT_ROOT_MARKER"
printf '%s\n' 'mode=cloudflare' 'base=example.test' 'certbot_lineage=owned' \
    > "$CERT_ROOT/.provenance"
chmod 0644 "$CONFIG_ROOT/$CONFIG_ROOT_MARKER" "$CERT_ROOT/$CERT_ROOT_MARKER"
chmod 0640 "$CERT_ROOT/.provenance"

named_group_gid() { id -g; }

for role in dot web console; do
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

dot_key="$CERT_ROOT/dot/current/privkey.pem"
ln -- "$dot_key" "$TMP/key-hardlink"
if certificate_role_tree_safe; then
    fail "hardlinked role private key was accepted"
fi
rm -f -- "$TMP/key-hardlink"
pass "hardlinked role private key fails closed"

mv -- "$CERT_ROOT/web" "$CERT_ROOT/web.saved"
ln -s web.saved "$CERT_ROOT/web"
if certificate_role_tree_safe; then
    fail "symlinked certificate role was accepted"
fi
rm -f -- "$CERT_ROOT/web"
mv -- "$CERT_ROOT/web.saved" "$CERT_ROOT/web"
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
# install.sh hardens everything under the mihomo home to 0660/2770. gpn/ must be
# excluded: state.Dir keeps it 0711 so the certificate oneshot -- root with an
# empty capability bounding set, and therefore subject to ordinary permission
# checks -- can traverse without listing, and the certificate request is 0644 so
# that same oneshot can read it. Sweeping it to 0660 left the request unreadable
# by the only process that mints leaves, until the engine happened to rewrite it.
#
# Found by upgrading test-env. A fresh install writes the right modes and the
# sweep only reaches these documents on a host where they already exist, so no
# amount of fresh-install acceptance could have caught it.
sweep="$(sed -n '/^    install -d -o root -g "\$MIHOMO_SERVICE_USER" -m 3770 "\$MIHOMO_DIR" || return 1$/,/^    for path in config.yaml; do$/p' "$ROOT/install.sh")"
[[ -n "$sweep" ]] || fail "could not extract the mihomo home mode sweep"
[[ "$(printf '%s' "$sweep" | grep -c -- '-path "\$MIHOMO_DIR/gpn" -prune')" == 2 ]] \
    || fail "the mode sweep does not prune \$MIHOMO_DIR/gpn; the certificate request loses 0644"
pass "the mode sweep prunes the core's gpn/ state directory"



# Every place that enumerates the certificate roles must name the same three.
#
# They were five lists in three files, and the rename kept leaving one behind:
# first cert_root_contents_are_safe still allowed dot|web|zash, so a migrated
# host passed the role rename and then failed the certificate root's own
# structural validation; then deploy_cert_roles still *wrote* dot web zash, so
# the next upgrade died with "Unknown certificate role: zash" -- both during
# publication, after the binaries were replaced.
#
# So this check has two halves. The first names the sites known to enumerate
# roles. The second is the one that matters: it sweeps for the retired name
# anywhere it could still be load-bearing, so a site nobody thought to add to
# the list above cannot hide.
for site in \
    'cert_role_group' \
    'cert_root_contents_are_safe' \
    'deploy_cert_roles' \
    'preflight_runtime_publication_paths'; do
    body="$(sed -n "/^${site}()/,/^}/p" "$ROOT/install.sh")"
    [[ -n "$body" ]] || fail "$site is missing"
    printf '%s' "$body" | grep -Fq 'console' \
        || fail "$site does not know the console certificate role"
    printf '%s' "$body" | grep -Fq 'zash' \
        && fail "$site still names the retired zash certificate role"
done
body="$(sed -n '/^publish_roles()/,/^}/p' "$ROOT/scripts/renew-hook.sh")"
[[ -n "$body" ]] || fail "publish_roles is missing from renew-hook.sh"
printf '%s' "$body" | grep -Fq 'console' \
    || fail "publish_roles does not know the console certificate role"
printf '%s' "$body" | grep -Fq 'zash' \
    && fail "publish_roles still names the retired zash certificate role"
pass "every certificate-role enumeration names console and not zash"

# The sweep. A role name reaches the filesystem as a cert path or as a member of
# a roles=() array; those two shapes are what must never say zash again.
#
# The migration is the one exception, and it is exempted by range rather than
# by pattern: migrate_cert_role_zash_to_console exists precisely to find and
# rename /etc/5gpn/cert/zash on a host that predates the console, so its whole
# body is cut out before the sweep runs -- matching its name line by line would
# exempt only the line that names it, not the lines that do the renaming.
migration_free_install="$(mktemp)"
awk '
    /^migrate_cert_role_zash_to_console\(\)/ { skip = 1 }
    skip { if ($0 == "}") skip = 0; print "" ; next }
    { print }
' "$ROOT/install.sh" >"$migration_free_install"
grep -Fq 'migrate_cert_role_zash_to_console()' "$ROOT/install.sh" \
    || fail "the zash->console migration is gone; drop this exemption too"

zash_sites="$(
    grep -rn "cert/zash\|CERT_DIR}/zash\|roles=([^)]*zash" \
        --include='*.sh' --include='*.tmpl' --include='*.example' \
        "$ROOT/scripts" "$ROOT/etc" 2>/dev/null \
        | grep -v 'migrate-panel-to-console.sh' || true
    grep -n "cert/zash\|CERT_DIR}/zash\|roles=([^)]*zash" \
        "$migration_free_install" 2>/dev/null \
        | sed "s|^|${ROOT}/install.sh:|" || true
)"
zash_sites="$(printf '%s' "$zash_sites" | grep -v ':[0-9]*:[[:space:]]*#' || true)"
rm -f "$migration_free_install"
[[ -z "$zash_sites" ]] || fail "retired zash certificate role still reachable:
$zash_sites"
pass "no zash certificate path or role array outside the migration"
echo "certificate role tree safety: PASS"
