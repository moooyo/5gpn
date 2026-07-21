#!/usr/bin/env bash
# Policy: web control plane removed; gum bootstrap + echo fallback present.
# Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
TGBOT_HELPER="$ROOT/scripts/setup-tgbot.sh"

# --- removed Python web control plane stays absent ---
[ ! -e "$ROOT/api-server.py" ] || fail "api-server.py must be removed"
[ ! -e "$ROOT/webui" ]         || fail "webui/ must be removed"
grep -Eq 'setup_api|api-server\.py|API_PORT' "$INSTALL" && fail "install.sh still references the removed HTTP API"

# --- gum bootstrap: prebuilt + verify, version-pinned, never fatal ---
grep -Eq 'install_gum\(\)' "$INSTALL"                 || fail "no install_gum() bootstrap"
grep -Eq '^GUM_VERSION="0\.17\.0"' "$INSTALL"       || fail "GUM_VERSION not fixed at 0.17.0"
grep -Fq 'GUM_BIN="${BIN_DIR}/gum"' "$INSTALL"       || fail "gum is not installed under the project-private bin dir"
grep -Eq '^GUM_SHA256_X86_64="[0-9a-f]{64}"$' "$INSTALL" || fail "gum x86_64 checksum is not embedded"
grep -Eq '^GUM_SHA256_ARM64="[0-9a-f]{64}"$' "$INSTALL"  || fail "gum arm64 checksum is not embedded"
grep -Eq '^GUM_SHA256_ARMV7="[0-9a-f]{64}"$' "$INSTALL"  || fail "gum armv7 checksum is not embedded"
gum_fn="$(sed -n '/^install_gum()/,/^}/p' "$INSTALL")"
grep -Fq 'checksums.txt' <<<"$gum_fn" && fail "gum trusts a mutable remote checksum document"
grep -Fq 'return 1' <<<"$gum_fn" && fail "gum bootstrap has a fatal failure path"
grep -Fq 'gum sha256 mismatch' "$INSTALL"             || fail "gum verify is not fail-closed"
grep -Fq -- '--connect-timeout 10 --max-time 60' <<<"$gum_fn" \
    || fail "optional gum download has no bounded network timeout"

# --- helpers gum-or-echo (fallback must exist) ---
grep -Fq 'gum log --level info' "$INSTALL"            || fail "info() has no gum branch"
grep -Fq '[INFO]' "$INSTALL"                          || fail "info() lost its echo fallback"
grep -Eq 'ask_secret\(\)' "$INSTALL"                  || fail "no ask_secret() prompt helper"
grep -Fq 'gum input --password' "$INSTALL"            || fail "bot token not collected via gum --password"
ask_secret_fn="$(sed -n '/^ask_secret()/,/^}/p' "$INSTALL")"
grep -Fq 'read -r -s' <<<"$ask_secret_fn"              || fail "plain secret fallback echoes operator input"

# --- non-TTY safety: Telegram configuration fails before prompts without a TTY ---
grep -Fq 'Telegram configuration requires the TUI' "$INSTALL" \
    || fail "tgbot configuration is not TTY-gated"

[ $rc -eq 0 ] && echo "gum policy: PASS"
exit $rc
