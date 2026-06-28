#!/usr/bin/env bash
# Policy: web control plane removed; gum bootstrap + echo fallback present.
# Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"; FW="$ROOT/scripts/setup-firewall.sh"

# --- web control plane gone ---
[ ! -e "$ROOT/api-server.py" ] || fail "api-server.py must be removed"
[ ! -e "$ROOT/webui" ]         || fail "webui/ must be removed"
grep -Eq 'setup_api|api-server\.py|API_PORT' "$INSTALL" && fail "install.sh still references the removed HTTP API"
grep -Eq 'API_PORT' "$FW" && fail "firewall still references API_PORT"
grep -Fq 'systemctl disable --now 5gpn-api' "$INSTALL" || fail "no upgrade cleanup for the removed 5gpn-api unit"

# --- gum bootstrap: prebuilt + verify, version-pinned, never fatal ---
grep -Eq 'install_gum\(\)' "$INSTALL"                 || fail "no install_gum() bootstrap"
grep -Eq 'GUM_VERSION:-0\.17\.0' "$INSTALL"           || fail "GUM_VERSION not pinned (default 0.17.0)"
grep -Fq 'checksums.txt' "$INSTALL"                   || fail "gum not verified against release checksums"
grep -Fq 'gum sha256 mismatch' "$INSTALL"             || fail "gum verify is not fail-closed"

# --- helpers gum-or-echo (fallback must exist) ---
grep -Fq 'gum log --level info' "$INSTALL"            || fail "info() has no gum branch"
grep -Fq '[INFO]' "$INSTALL"                          || fail "info() lost its echo fallback"
grep -Eq 'ask_secret\(\)' "$INSTALL"                  || fail "no ask_secret() prompt helper"
grep -Fq 'gum input --password' "$INSTALL"            || fail "bot token not collected via gum --password"

# --- non-TTY safety: gum prompts stay behind -t 0 (token prompt still guarded) ---
grep -Eq '\[\[ -z "\$token" && -t 0 \]\]' "$INSTALL"  || fail "tgbot token prompt no longer TTY-gated"

[ $rc -eq 0 ] && echo "gum policy: PASS"
exit $rc
