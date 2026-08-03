#!/usr/bin/env bash
# Behaviour checks for atomic, fail-closed iOS profile publication.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }
content_checksum() { cksum "$1" | awk '{print $1 ":" $2}'; }

REAL_OPENSSL="$(command -v openssl)"
REAL_MV="$(command -v mv)"
CERT_DIR="$TMP/cert"
INTERCEPT_DIR="$TMP/intercept-ca"
LIVE_DIR="$TMP/live"
CANDIDATE_DIR="$TMP/candidate"
MOCK_BIN="$TMP/bin"
GENERATOR="$TMP/gen-ios-profile.sh"
mkdir -p "$CERT_DIR" "$INTERCEPT_DIR" "$LIVE_DIR" "$CANDIDATE_DIR" "$MOCK_BIN"

# The production paths are fixed by design. Instrument a private copy so the
# black-box test never writes host certificate state.
sed \
    -e "s|CERT_DIR=\"/etc/5gpn/cert/dot/current\"|CERT_DIR=\"$CERT_DIR\"|" \
    -e "s|INTERCEPT_CA=\"/etc/5gpn/intercept-ca/root.crt\"|INTERCEPT_CA=\"$INTERCEPT_DIR/root.crt\"|" \
    "$ROOT/scripts/gen-ios-profile.sh" > "$GENERATOR"
chmod +x "$GENERATOR"

"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj '/CN=dot.example.test' >/dev/null 2>&1
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$TMP/intercept.key" -out "$INTERCEPT_DIR/root.crt" \
    -subj '/CN=5gpn interception test root' >/dev/null 2>&1

cat > "$MOCK_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" smime "* ]]; then
    for arg in "$@"; do
        if [[ "${FAIL_DOT_SIGN:-0}" == 1 && "$arg" == */ios-dot.mobileconfig.unsigned ]]; then
            exit 1
        fi
        if [[ "${FAIL_INTERCEPT_SIGN:-0}" == 1 && "$arg" == *ios-intercept-ca* ]]; then
            exit 1
        fi
    done
fi
exec "$REAL_OPENSSL" "$@"
EOF
chmod +x "$MOCK_BIN/openssl"
cat > "$MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_INTERCEPT_MOVE:-0}" == 1 ]]; then
    for arg in "$@"; do
        [[ "$arg" == */.ios-profile.*/ios-intercept-ca.mobileconfig ]] && exit 1
    done
fi
if [[ "${FAIL_ROLLBACK_MOVE:-0}" == 1 ]]; then
    for arg in "$@"; do
        [[ "$arg" == */.ios-profile.*/old-ios-dot.mobileconfig ]] && exit 1
    done
fi
if [[ "${SIGNAL_AFTER_DOT_MOVE:-0}" == 1 ]]; then
    for arg in "$@"; do
        if [[ "$arg" == */.ios-profile.*/ios-dot.mobileconfig ]]; then
            "$REAL_MV" "$@"
            kill -TERM "$PPID"
            exit 0
        fi
    done
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$MOCK_BIN/mv"
export REAL_OPENSSL REAL_MV

# Establish two valid live profiles first.
PATH="$MOCK_BIN:$PATH" bash "$GENERATOR" dot.example.test 192.0.2.10 "$LIVE_DIR" >/dev/null
dot_before="$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")"
intercept_before="$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")"

# Failure while signing the first profile must leave both live payloads intact.
if FAIL_DOT_SIGN=1 PATH="$MOCK_BIN:$PATH" \
    bash "$GENERATOR" dot.example.test 192.0.2.11 "$LIVE_DIR" >/dev/null 2>&1; then
    fail "DoT profile signing failure was accepted"
fi
[[ "$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")" == "$dot_before" ]] \
    || fail "failed DoT signing changed the previous live profile"
[[ "$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
    || fail "failed DoT signing changed the previous interception profile"
pass "first-profile signing failure preserves both live profiles"

# A later failure while signing the second profile must not publish the first
# replacement or remove either last-known-good live file.
if FAIL_INTERCEPT_SIGN=1 PATH="$MOCK_BIN:$PATH" \
    bash "$GENERATOR" dot.example.test 192.0.2.11 "$LIVE_DIR" >/dev/null 2>&1; then
    fail "interception profile signing failure was accepted"
fi
[[ -f "$LIVE_DIR/ios-dot.mobileconfig" ]] \
    || fail "DoT signing transaction removed the previous live profile"
[[ -f "$LIVE_DIR/ios-intercept-ca.mobileconfig" ]] \
    || fail "interception signing failure removed the previous live profile"
[[ "$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")" == "$dot_before" ]] \
    || fail "DoT profile was published before the interception profile was ready"
[[ "$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
    || fail "failed interception signing changed the previous live profile"
pass "second-profile signing failure preserves both live profiles"

# If the second same-directory rename itself fails, the first rename must roll
# back to the hard-linked last-known-good profile.
if FAIL_INTERCEPT_MOVE=1 PATH="$MOCK_BIN:$PATH" \
    bash "$GENERATOR" dot.example.test 192.0.2.13 "$LIVE_DIR" >/dev/null 2>&1; then
    fail "interception profile publication failure was accepted"
fi
[[ "$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")" == "$dot_before" ]] \
    || fail "second rename failure did not restore the previous DoT profile"
[[ "$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
    || fail "second rename failure changed the interception profile"
if find "$LIVE_DIR" -mindepth 1 -name '.ios-profile.*' -print | grep -q .; then
    fail "profile staging artifacts remain after a publication failure"
fi
pass "second atomic rename failure restores both live profiles"

# Delivering a signal from the first mv wrapper reproduces the exact window
# after the DoT rename and before the interception rename. Run it twice so the
# injection is deterministic and does not depend on a one-shot timing race.
for attempt in 1 2; do
    if SIGNAL_AFTER_DOT_MOVE=1 PATH="$MOCK_BIN:$PATH" \
        bash "$GENERATOR" dot.example.test "192.0.2.2${attempt}" "$LIVE_DIR" \
        >/dev/null 2>&1; then
        fail "signal after the first rename was accepted on attempt $attempt"
    fi
    [[ "$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")" == "$dot_before" ]] \
        || fail "signal after the first rename left a replacement DoT profile"
    [[ "$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
        || fail "signal after the first rename changed the interception profile"
    if find "$LIVE_DIR" -mindepth 1 -name '.ios-profile.*' -print | grep -q .; then
        fail "profile staging artifacts remain after successful signal rollback"
    fi
done
pass "signal after the first rename repeatedly restores the previous pair"

# A rollback failure must keep the hard-linked old file instead of letting EXIT
# cleanup destroy the only recovery copy. The error also names its private path.
rollback_log="$TMP/rollback-failure.log"
if SIGNAL_AFTER_DOT_MOVE=1 FAIL_ROLLBACK_MOVE=1 PATH="$MOCK_BIN:$PATH" \
    bash "$GENERATOR" dot.example.test 192.0.2.30 "$LIVE_DIR" \
    >"$rollback_log" 2>&1; then
    fail "rollback failure after a signal was accepted"
fi
recovery_dir="$(find "$LIVE_DIR" -mindepth 1 -maxdepth 1 \
    -type d -name '.ios-profile.*' -print -quit)"
[[ -n "$recovery_dir" ]] || fail "rollback failure removed its recovery directory"
[[ -f "$recovery_dir/old-ios-dot.mobileconfig" ]] \
    || fail "rollback failure removed the only old DoT profile snapshot"
[[ "$(content_checksum "$recovery_dir/old-ios-dot.mobileconfig")" == "$dot_before" ]] \
    || fail "retained DoT recovery snapshot does not match the old profile"
[[ -f "$recovery_dir/old-ios-intercept-ca.mobileconfig" ]] \
    || fail "rollback failure removed the interception profile snapshot"
[[ "$(content_checksum "$recovery_dir/old-ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
    || fail "retained interception recovery snapshot does not match the old profile"
[[ "$(content_checksum "$LIVE_DIR/ios-dot.mobileconfig")" != "$dot_before" ]] \
    || fail "rollback failure injection did not leave the replacement DoT profile live"
[[ "$(content_checksum "$LIVE_DIR/ios-intercept-ca.mobileconfig")" == "$intercept_before" ]] \
    || fail "rollback failure unexpectedly changed the live interception profile"
"$REAL_OPENSSL" smime -verify -inform der -noverify \
    -in "$recovery_dir/old-ios-dot.mobileconfig" -out /dev/null >/dev/null 2>&1 \
    || fail "retained DoT recovery snapshot is not a valid CMS payload"
grep -Fq "recovery evidence retained at $recovery_dir" "$rollback_log" \
    || fail "rollback failure did not report the retained recovery path"
pass "rollback failure retains and reports the hard-linked old profile"

# Installation passes a fresh candidate directory. Atomic staging must still
# produce both final payloads there without requiring pre-existing files.
PATH="$MOCK_BIN:$PATH" bash "$GENERATOR" \
    dot.example.test 192.0.2.12 "$CANDIDATE_DIR" >/dev/null
for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    [[ -s "$CANDIDATE_DIR/$profile" ]] || fail "candidate is missing $profile"
    "$REAL_OPENSSL" smime -verify -inform der -noverify \
        -in "$CANDIDATE_DIR/$profile" -out /dev/null >/dev/null 2>&1 \
        || fail "candidate $profile is not a valid signed CMS payload"
done
if find "$CANDIDATE_DIR" -mindepth 1 \
    \( -name '.ios-profile.*' -o -name '*.signed' \) -print | grep -q .; then
    fail "profile staging artifacts remain in the installation candidate"
fi
pass "fresh installation candidate receives both signed profiles"

# The URL an operator is told to open must be the URL the installer verified.
#
# Three surfaces print it -- the QR code, the success banner and the regenerate
# message -- and all three said /ios/ after the monolith moved the profiles into
# the bundle at /ui/. verify_console_endpoint probed /ui/ and passed, so the
# install reported success while the printed URL and the QR a phone would scan
# both returned 404. Nothing on the host could notice: the two paths are read by
# different readers, and only one of them is a machine.
INSTALL="$ROOT/install.sh"
grep -nE '(https://\$\{CONSOLE_DOMAIN[^}]*\}|https://%s)/ios/' "$INSTALL" \
    && fail "a printed URL still points at the retired /ios/ path"
url_fn="$(sed -n '/^ios_profile_url()/,/^}/p' "$INSTALL")"
[[ -n "$url_fn" ]] || fail "ios_profile_url is missing"
printf '%s' "$url_fn" | grep -Fq '/ui/' \
    || fail "ios_profile_url does not build the /ui/ path the controller serves"

# Every printer goes through that one derivation rather than spelling it out.
# A name that no longer exists fails here rather than skipping: a silent skip is
# how this check would quietly stop covering the site it was written for.
for site in print_qr regen_ios; do
    body="$(sed -n "/^${site}()/,/^}/p" "$INSTALL")"
    [[ -n "$body" ]] || fail "$site is missing; update this check to its new name"
    printf '%s' "$body" | grep -Fq 'ios_profile_url' \
        || fail "$site builds the profile URL itself instead of calling ios_profile_url"
done

# And the path it builds is the one the console probe actually asserts on.
probe="$(sed -n '/^verify_console_endpoint()/,/^}/p' "$INSTALL")"
printf '%s' "$probe" | grep -Fq '"/ui/${name}"' \
    || fail "verify_console_endpoint no longer probes the profiles under /ui/"
pass "the printed profile URL is the path the console probe verifies"

echo "iOS profile atomic publication tests: PASS"
