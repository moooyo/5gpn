#!/usr/bin/env bash
# Policy: web control plane removed; gum bootstrap + echo fallback present.
# Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
TGBOT_HELPER="$ROOT/scripts/setup-tgbot.sh"

# --- legacy python web control plane gone ---
[ ! -e "$ROOT/api-server.py" ] || fail "api-server.py must be removed"
[ ! -e "$ROOT/webui" ]         || fail "webui/ must be removed"
grep -Eq 'setup_api|api-server\.py|API_PORT' "$INSTALL" && fail "install.sh still references the removed HTTP API"
# Upgrade cleanup of the removed 5gpn-api unit now lives in
# clean_previous_install's legacy-unit loop (fresh-artifact rule, 2026-07-10).
sed -n '/^clean_previous_install()/,/^}/p' "$INSTALL" | grep -Fq '5gpn-api.service' \
    || fail "no upgrade cleanup for the removed 5gpn-api unit (clean_previous_install legacy loop)"

# --- gum bootstrap: prebuilt + verify, version-pinned, never fatal ---
grep -Eq 'install_gum\(\)' "$INSTALL"                 || fail "no install_gum() bootstrap"
grep -Eq '^GUM_VERSION="0\.17\.0"' "$INSTALL"       || fail "GUM_VERSION not fixed at 0.17.0"
grep -Fq 'GUM_BIN="${BIN_DIR}/gum"' "$INSTALL"       || fail "gum is not installed under the project-private bin dir"
grep -Fq 'checksums.txt' "$INSTALL"                   || fail "gum not verified against release checksums"
grep -Fq 'gum sha256 mismatch' "$INSTALL"             || fail "gum verify is not fail-closed"

# --- helpers gum-or-echo (fallback must exist) ---
grep -Fq 'gum log --level info' "$INSTALL"            || fail "info() has no gum branch"
grep -Fq '[INFO]' "$INSTALL"                          || fail "info() lost its echo fallback"
grep -Eq 'ask_secret\(\)' "$INSTALL"                  || fail "no ask_secret() prompt helper"
grep -Fq 'gum input --password' "$INSTALL"            || fail "bot token not collected via gum --password"

# --- non-TTY safety: Telegram configuration fails before prompts without a TTY ---
grep -Fq 'Telegram configuration requires the TUI' "$INSTALL" \
    || fail "tgbot configuration is not TTY-gated"

[ $rc -eq 0 ] && echo "gum policy: PASS"
exit $rc
