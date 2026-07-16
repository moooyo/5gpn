#!/usr/bin/env bash
# Policy: every operator-facing shell script renders status through the shared
# gum-or-echo pattern (gum when present + TTY, plain echo otherwise) — never a
# bare echo as the only path. Bootstrapping gum (install_gum) is the one exempt
# step. Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"

# --- install.sh: card() frames the status + completion summary -----------------
grep -Eq 'card\(\)'                "$INSTALL" || fail "install.sh has no card() box helper"
grep -Fq 'gum style --border rounded' "$INSTALL" || fail "install.sh card() does not use a gum style border"
# ...and must not regress to the old ASCII status banner.
grep -Fq '==========================================' "$INSTALL" \
    && fail "install.sh still uses the old ==== status banner instead of a gum card"

# --- sub-scripts + hook: gum-detect + gum log + plain-echo fallback all present -
for f in scripts/update-lists.sh scripts/gen-ios-profile.sh scripts/renew-hook.sh; do
    s="$ROOT/$f"
    grep -Fq 'command -v gum'  "$s" || fail "$f does not detect gum on PATH"
    grep -Fq 'gum log'         "$s" || fail "$f has no gum log output path"
    grep -Eq '\[OK\]|\[INFO\]' "$s" || fail "$f lost its plain-echo fallback"
done

# --- update-lists.sh: Phase 2 repurpose — a manual reload trigger, no fetch of its
# own (the in-process subscription manager owns fetching), so there is no opaque
# download left to wrap in gum_spin; its reload result must stay plain operator
# output, never hidden behind a spinner.
UL="$ROOT/scripts/update-lists.sh"
grep -Eq 'gum_spin[^|]*(render_smartdns_conf|systemctl)' "$UL" \
    && fail "update-lists.sh must not hide the reload/restart output behind a spinner"

# --- quick-install.sh: pre-gum entrypoint — gum-aware-if-present, ANSI fallback -
QI="$ROOT/quick-install.sh"
grep -Fq 'command -v gum' "$QI" || fail "quick-install.sh is not gum-aware (use gum if already on PATH)"
grep -Fq '\033[0;31m'     "$QI" || fail "quick-install.sh lost its ANSI fallback"

[ $rc -eq 0 ] && echo "tui policy: PASS"
exit $rc
