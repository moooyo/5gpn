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
reuse_line="$(grep -nF 'activate_verified_installed_gum' <<<"$gum_fn" | head -1 | cut -d: -f1)"
download_line="$(grep -nF 'curl -fsSL' <<<"$gum_fn" | head -1 | cut -d: -f1)"
[[ -n "$reuse_line" && -n "$download_line" && "$reuse_line" -lt "$download_line" ]] \
    || fail "install_gum does not verify and reuse the owned binary before downloading"

# --- helpers gum-or-echo (fallback must exist) ---
grep -Fq 'gum log --level info' "$INSTALL"            || fail "info() has no gum branch"
grep -Fq '[INFO]' "$INSTALL"                          || fail "info() lost its echo fallback"
grep -Eq 'ask_secret\(\)' "$INSTALL"                  || fail "no ask_secret() prompt helper"
grep -Fq 'gum input --password' "$INSTALL"            || fail "bot token not collected via gum --password"
ask_secret_fn="$(sed -n '/^ask_secret()/,/^}/p' "$INSTALL")"
grep -Fq 'read -r -s' <<<"$ask_secret_fn"              || fail "plain secret fallback echoes operator input"

# Gum must not probe OSC/CSI terminal capabilities. On TTYs that do not answer
# those queries, one unscoped Gum process can otherwise block for many seconds.
for f in "$INSTALL" "$ROOT/quick-install.sh" \
    "$ROOT/scripts/cert-renew.sh" "$ROOT/scripts/gen-ios-profile.sh" \
    "$ROOT/scripts/intercept-cert-renew.sh" "$ROOT/scripts/reload-rules.sh" \
    "$ROOT/scripts/renew-hook.sh" "$ROOT/scripts/setup-tgbot.sh"; do
    unsafe_gum="$(grep -E 'gum (log|input|confirm|choose|spin|style)([[:space:]]|$)' "$f" \
        | grep -Fv 'CI=1 gum ' || true)"
    [[ -z "$unsafe_gum" ]] || fail "$f has a Gum interaction that can block on terminal probing"
done
gum_spin_fn="$(sed -n '/^gum_spin()/,/^}/p' "$INSTALL")"
grep -Fq 'env -u CI' <<<"$gum_spin_fn" \
    && grep -Fq 'env "CI=$CI"' <<<"$gum_spin_fn" \
    || fail "gum_spin leaks Gum's synthetic CI=1 into wrapped commands"

# --- non-TTY safety: every interactive management op fails before prompting ---
#
# The Telegram case used to be named here specifically. That command is gone
# with the helper it sourced, so the assertion is the general one it was an
# instance of: an op that prompts must refuse a pipe rather than block on it.
grep -Fq 'requires an interactive TTY' "$INSTALL" \
    || fail "no management op is TTY-gated"

# --- Gum must exist before the prompts, not after them -------------------------
# Every question this installer asks runs in resolve_install_configuration. When
# install_gum came later, ask_text/ask_choice/ask_yesno always took their
# read -p fallback and Gum only ever coloured the closing log lines -- the TUI
# was effectively never used.
full_install_body="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
gum_line="$(grep -n '^[[:space:]]*install_gum$' <<<"$full_install_body" | head -1 | cut -d: -f1)"
prompt_line="$(grep -n 'resolve_install_configuration' <<<"$full_install_body" | head -1 | cut -d: -f1)"
if [ -n "$gum_line" ] && [ -n "$prompt_line" ] && [ "$gum_line" -lt "$prompt_line" ]; then
    :
else
    fail "install_gum runs after the prompts; every interactive helper falls back to read -p"
fi

# --- one accent colour, and every framed surface uses it -----------------------
grep -Eq '^UI_ACCENT=[0-9]+$' "$INSTALL" \
    || fail "the installer has no single accent colour"
grep -Fq 'border-foreground "$UI_ACCENT"' "$INSTALL" \
    || fail "card() hardcodes a colour instead of the shared accent"
phase_fn="$(sed -n '/^phase()/,/^}/p' "$INSTALL")"
grep -Fq 'gum style' <<<"$phase_fn" \
    || fail "phase() has no gum branch"
grep -Fq 'printf' <<<"$phase_fn" \
    || fail "phase() lost its plain-text fallback"
grep -Fq 'INSTALL_PHASE=' <<<"$phase_fn" \
    || fail "phase() does not set the phase that failure reporting quotes"

[ $rc -eq 0 ] && echo "gum policy: PASS"
exit $rc
