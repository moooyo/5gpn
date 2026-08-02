#!/usr/bin/env bash
# Build a 5gpn beta bundle: one binary, one UI, the units, and the scripts that
# put an existing gateway onto it.
#
# This is deliberately not install.sh. install.sh provisions a host from nothing
# -- certificates, service accounts, ACME, the whole bootstrap -- and it still
# describes the three-process layout in places. This produces the artifact set
# for a gateway that is already provisioned, which is what a beta is for.
#
# Usage: package-beta.sh <version> [output-dir]
#   VERSION is stamped into the binary and the bundle name.
#   MIHOMO_SRC / ZASHBOARD_SRC override the source checkouts.
set -euo pipefail

VERSION="${1:?usage: package-beta.sh <version> [output-dir]}"
OUT="${2:-dist}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MIHOMO_SRC="${MIHOMO_SRC:-$(cd "$REPO/../../worktrees/mihomo-5gpn-monolith" 2>/dev/null && pwd || true)}"
ZASHBOARD_SRC="${ZASHBOARD_SRC:-$(cd "$REPO/../../worktrees/zashboard-5gpn-console" 2>/dev/null && pwd || true)}"

[[ -d "${MIHOMO_SRC:-}" ]] || { echo "set MIHOMO_SRC to the mihomo fork checkout" >&2; exit 1; }
[[ -d "${ZASHBOARD_SRC:-}" ]] || { echo "set ZASHBOARD_SRC to the zashboard checkout" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
BUNDLE="${STAGE}/5gpn-${VERSION}"
mkdir -p "$BUNDLE"/{bin,ui,systemd,scripts}

echo "==> building the core (linux/amd64, with_gvisor)"
# CGO off so the artifact runs on any glibc the target happens to have, and
# with_gvisor because the fork's build matrix uses it -- a beta that differs
# from the release build in its tag set is testing something else.
(
  cd "$MIHOMO_SRC"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -tags with_gvisor -trimpath \
      -ldflags "-X \"github.com/metacubex/mihomo/constant.Version=${VERSION}\" -w -s -buildid=" \
      -o "${BUNDLE}/bin/mihomo" .
)
chmod 0755 "${BUNDLE}/bin/mihomo"

echo "==> checking the fork budget"
# The number that decides whether this fork stays rebaseable is how many
# upstream-owned files carry a 5gpn-shaped change, measured against upstream --
# not against the previous fork branch, which would report the amputation of the
# old overlay as though it were new surface.
#
# Informational, not fatal: a source tree packaged outside a git checkout is a
# legitimate way to build, and refusing to produce an artifact over a number
# nobody can compute there would be the wrong trade.
touched="unknown"
if git -C "$MIHOMO_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    upstream_base="$(git -C "$MIHOMO_SRC" merge-base HEAD Alpha 2>/dev/null || true)"
    if [[ -n "$upstream_base" ]]; then
        # gpn/ and the three new files are not conflict surface -- a rebase
        # never has to reconcile a file upstream does not have. go.mod and
        # go.sum are excluded for a different reason: they conflict, but their
        # resolution is mechanical and does not require understanding 5gpn.
        touched="$(git -C "$MIHOMO_SRC" diff --name-only "$upstream_base"..HEAD 2>/dev/null \
            | grep -vE '^(gpn/|hub/gpn\.go|constant/intercept\.go|tunnel/gpn\.go|go\.(mod|sum)$)' \
            | tr '\n' ' ')" || touched="unknown"
    fi
fi
echo "    upstream-owned files carrying a change: ${touched:-none}"

echo "==> collecting the UI"
# ZASHBOARD_DIST names an already-built bundle. It exists because the UI's
# native build dependencies are platform-specific: a checkout whose
# node_modules were installed on one platform cannot be built from another,
# and on this project the core is cross-compiled for Linux from a machine that
# is frequently not Linux. Building it here when we can, and accepting a bundle
# when we cannot, beats a packager that only works on one developer's box.
UI_SRC="${ZASHBOARD_DIST:-}"
if [[ -z "$UI_SRC" ]]; then
    ( cd "$ZASHBOARD_SRC" && npm run build >/dev/null )
    UI_SRC="${ZASHBOARD_SRC}/dist"
fi
[[ -f "${UI_SRC}/index.html" ]] || { echo "no UI bundle at ${UI_SRC}" >&2; exit 1; }
cp -a "${UI_SRC}/." "${BUNDLE}/ui/"

echo "==> collecting units and scripts"
cp -a "${REPO}/etc/systemd/mihomo.service" \
      "${REPO}/etc/systemd/5gpn-intercept-cert.service" \
      "${REPO}/etc/systemd/5gpn-intercept-cert.path" \
      "${REPO}/etc/systemd/5gpn-intercept-cert.timer" \
      "${BUNDLE}/systemd/"
cp -a "${REPO}/scripts/migrate-to-monolith.sh" \
      "${REPO}/scripts/migrate-state-to-monolith.sh" \
      "${REPO}/scripts/intercept-cert-renew.sh" \
      "${BUNDLE}/scripts/"
cp -a "${REPO}/tests/acceptance-monolith.sh" \
      "${REPO}/tests/acceptance-monolith-writes.sh" \
      "${REPO}/tests/acceptance-monolith-extension.sh" \
      "${BUNDLE}/scripts/"
chmod 0755 "${BUNDLE}"/scripts/*.sh

cp -a "${REPO}/docs/architecture.md" "${BUNDLE}/architecture.md"
cp -a "${HERE}/upgrade-to-beta.sh" "${BUNDLE}/upgrade.sh"
chmod 0755 "${BUNDLE}/upgrade.sh"

cat > "${BUNDLE}/VERSION" <<EOF
version: ${VERSION}
core: $("${BUNDLE}/bin/mihomo" -v 2>/dev/null | head -1)
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
upstream-owned files changed: ${touched}
EOF

mkdir -p "$OUT"
TARBALL="${OUT}/5gpn-${VERSION}-linux-amd64.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" "5gpn-${VERSION}"
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

echo
echo "==> $TARBALL"
cat "${BUNDLE}/VERSION" | sed 's/^/    /'
echo "    sha256: $(cut -d' ' -f1 < "${TARBALL}.sha256")"
echo "    size:   $(du -h "$TARBALL" | cut -f1)"
