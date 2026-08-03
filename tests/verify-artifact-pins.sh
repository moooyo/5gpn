#!/usr/bin/env bash
# Verifies every pinned third-party artifact against its published release.
#
# install.sh pins each one as a PAIR: a version and the SHA-256 of the exact
# asset that version publishes. Nothing bound the two together, so bumping the
# version and leaving the digest behind produced an installer that downloaded
# the right artifact, computed the right hash, and refused it. That shipped once
# (0.0.57) and was only discovered by installing on a real gateway, because it
# is the only place the check runs — nothing in the offline suite touches the
# network.
#
# Deliberately NOT named tests/test_*.sh. The local suite is
# `for t in tests/test_*.sh` and must stay offline and deterministic; this needs
# the network, so it is a CI job instead.
#
# It never skips. A check that quietly does nothing when it cannot reach the
# network is worse than no check: it manufactures confidence, which is exactly
# how a stale end-to-end fixture survived two contract changes in this tree. If
# the artifact cannot be fetched, this fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

pass() { echo "ok:   $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# Read the pins from install.sh rather than restating them. A second copy is a
# second thing to forget.
export INSTALL_SH_LIB_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

TMP="$(mktemp -d /tmp/5gpn-pins.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# check <label> <expected-sha256> <url>
check() {
    local label="$1" expected="$2" url="$3" out="$TMP/artifact"

    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        fail "$label: pinned digest is not a lowercase 64-character SHA-256: '$expected'"
        return
    fi
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 300 "$url" -o "$out"; then
        # Not a skip. An unreachable pin is an unverified pin.
        fail "$label: could not download $url"
        return
    fi
    local actual
    actual="$(sha256sum "$out" | cut -d' ' -f1)"
    if [[ "$actual" != "$expected" ]]; then
        fail "$label: pinned digest does not match the published artifact
        pinned:    $expected
        published: $actual
        url:       $url
      The version and its digest are updated together; one of them was not."
        return
    fi
    pass "$label $expected"
    rm -f "$out"
}

echo "Verifying pinned artifacts against their published releases."

# Two artifacts, because there are two processes' worth of code left to fetch and
# they both run inside one. The 5gpn-intercept sidecar that used to be checked
# here is not unpinned, it is gone: the monolith absorbed it, so there is no
# third binary to bind.

check "mihomo ${MIHOMO_VERSION}" "$MIHOMO_SHA256" \
    "https://github.com/${MIHOMO_REPO}/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"

check "zashboard ${ZASH_VERSION}" "$ZASH_SHA256" \
    "https://github.com/${ZASH_REPO}/releases/download/${ZASH_VERSION}/dist.zip"

if [[ "$FAIL" -ne 0 ]]; then
    echo "artifact pins: FAIL"
    exit 1
fi
echo "artifact pins: PASS"
