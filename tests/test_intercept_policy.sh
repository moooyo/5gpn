#!/usr/bin/env bash
# What the installer still owns of interception.
#
# Interception used to be a second process with its own unit, account,
# capability set, SOCKS listener and Go manifest parser, plus a React console
# that rendered it. All of that is inside mihomo now, or inside zashboard, and
# the assertions that covered it are not deleted so much as relocated:
#
#   the sidecar unit, its account and confinement   -- there is no second
#       process; the capture stage runs in mihomo, guarded by tunnel/gpn.go's
#       INNER check rather than by a separate uid.
#   the intercept-egress listener and MODULE-INTERCEPT node  -- the seed template
#       assertions live in test_mihomo_policy.sh and test_install_policy.sh,
#       which follow the template.
#   the manifest parser and its permission model   -- gpn/engine/manifest_test.go
#       in the fork.
#   the Extensions and Setup Guide pages           -- zashboard's own repository.
#
# What genuinely remains here is the certificate boundary, because the installer
# is what publishes it: a root oneshot holding the CA signing key, reading a
# request file the engine writes, with no capabilities and no way to reach the
# engine's own binary. That arrangement is the installer's to get right.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
CERT_UNIT="$ROOT/etc/systemd/5gpn-intercept-cert.service"
CERT_PATH="$ROOT/etc/systemd/5gpn-intercept-cert.path"
CERT_TIMER="$ROOT/etc/systemd/5gpn-intercept-cert.timer"
RENEW="$ROOT/scripts/intercept-cert-renew.sh"
PROFILE="$ROOT/scripts/gen-ios-profile.sh"
rc=0
fail() { echo "FAIL: $1"; rc=1; }

find "$ROOT" -type f -name '*.py' -print -quit | grep -q . \
    && fail "Python source was introduced"

# --- the certificate publisher -----------------------------------------------
grep -Fxq '# 5gpn-unit-id: 5gpn-intercept-cert.service:v1' "$CERT_UNIT" || fail "certificate publisher ownership marker missing"
grep -Fxq 'ExecStart=/opt/5gpn/scripts/intercept-cert-renew.sh' "$CERT_UNIT" || fail "certificate publisher helper is missing"
grep -Fxq 'Group=root' "$CERT_UNIT" || fail "certificate publisher primary group is not root"
grep -Fxq 'SupplementaryGroups=gpn-intercept' "$CERT_UNIT" || fail "capability-free certificate publisher lacks the runtime file group"
grep -Fxq 'CapabilityBoundingSet=' "$CERT_UNIT" || fail "certificate publisher has capabilities"
grep -Fxq 'RuntimeDirectory=5gpn' "$CERT_UNIT" || fail "certificate publisher cannot create its fresh-boot lock directory"
grep -Fxq 'RuntimeDirectoryMode=0700' "$CERT_UNIT" || fail "certificate publisher runtime directory is not private"
grep -Fxq 'RuntimeDirectoryPreserve=yes' "$CERT_UNIT" || fail "certificate lock directory is not preserved between oneshot runs"
# A path unit counts every trigger against systemd's start limit. Without a
# raised bound, a burst of writes puts the publisher into failed permanently.
grep -Fxq 'StartLimitIntervalSec=30' "$CERT_UNIT" \
    && grep -Fxq 'StartLimitBurst=64' "$CERT_UNIT" \
    || fail "certificate publisher start limit does not admit the bounded republish retry"
# The publisher holds the CA signing key. It may read the engine's state
# directory -- that is where the request is -- and nothing else of the engine's.
grep -Fq 'ReadOnlyPaths=/etc/5gpn/intercept-ca /etc/5gpn/mihomo/gpn /opt/5gpn/scripts/intercept-cert-renew.sh' "$CERT_UNIT" \
    || fail "certificate publisher does not scope root-key access"

# The watcher fires on the request, not on the document. The document changes
# whenever an operator edits a setting; the request changes only when the host
# set the leaf must cover does, so this reissues when it is actually needed.
grep -Fxq 'PathChanged=/etc/5gpn/mihomo/gpn/certificate-request' "$CERT_PATH" || fail "certificate watcher does not watch the request file"
grep -Fxq '# 5gpn-unit-id: 5gpn-intercept-cert.timer:v1' "$CERT_TIMER" || fail "interception certificate timer ownership marker is missing"
grep -Fxq 'OnCalendar=*-*-* 02:00:00' "$CERT_TIMER" || fail "interception certificate timer does not run on the fixed daily schedule"
grep -Fxq 'Persistent=true' "$CERT_TIMER" || fail "interception certificate timer is not persistent"
grep -Fxq 'Unit=5gpn-intercept-cert.service' "$CERT_TIMER" || fail "interception certificate timer does not target the leaf publisher"

# --- the renewal helper ------------------------------------------------------
grep -Fq "stat -Lc '%d:%i'" "$RENEW" \
    && grep -Fq '/fd/${fd}' "$RENEW" \
    || fail "interception helper does not validate the inherited installer lock inode"
grep -Fq 'CERT_REQUEST=/etc/5gpn/mihomo/gpn/certificate-request' "$RENEW" \
    || fail "certificate helper does not consume the engine's atomic host-set request"
grep -Fq 'if [[ ! -s "$stage/hosts" ]]' "$RENEW" || fail "certificate helper does not accept a fresh zero-extension host set"

# --- the installer's side ----------------------------------------------------
grep -Fq 'install_service_account "$INTERCEPT_SERVICE_USER" "$INTERCEPT_SERVICE_USER"' "$INSTALL" || fail "interception file-ownership account is not installed"
grep -Fq 'ensure_intercept_certificates' "$INSTALL" || fail "interception certificate lifecycle is missing"
grep -Fq 'systemctl enable --now 5gpn-intercept-cert.timer' "$INSTALL" || fail "interception leaf renewal timer is not always enabled"
grep -Fq 'systemctl enable --now 5gpn-intercept-cert.path' "$INSTALL" || fail "interception certificate watcher is not enabled"
grep -Fq '"${SCRIPT_DIR}"/etc/systemd/*.timer' "$INSTALL" || fail "interception certificate timer is not copied into installed bundles"
grep -Fq 'intercept-cert-renew.sh" --installer-lock-held' "$INSTALL" || fail "installer does not reuse its held certificate lock"
grep -Fq 'CERT_REQUEST_FILE="${GPN_STATE_DIR}/certificate-request"' "$INSTALL" \
    || fail "installer does not read the leaf host set from the engine's published request"
renew_service="$(sed -n '/^install_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq 'ExecStart=/opt/5gpn/scripts/intercept-cert-renew.sh' <<<"$renew_service" \
    && fail "public certificate renewal still couples interception leaf renewal"
grep -Fq 'INTERCEPT_CA_MARKER_VALUE="5gpn-intercept-ca-v1"' "$INSTALL" || fail "interception CA ownership marker is missing"
grep -Fq 'INTERCEPT_STATE_MARKER_VALUE="5gpn-intercept-state"' "$INSTALL" || fail "interception state ownership marker is missing"
grep -Fq 'remove_fixed_owned_dir "$INTERCEPT_STATE_DIR"' "$INSTALL" || fail "purge does not remove marked module persistent state"

# The engine writes its own document with interception off, so the installer
# must not seed one -- two writers of one document is how they drift.
grep -Fq '"mitm"' "$INSTALL" && fail "the installer seeds an interception document the engine owns"

# --- the shared trust profile ------------------------------------------------
grep -Fq 'ios-intercept-ca.mobileconfig' "$PROFILE" || fail "interception CA profile generation is missing"
grep -Fq 'com.apple.security.root' "$PROFILE" || fail "shared interception profile is not a root-certificate payload"

# --- retired identifiers must not reappear in what is left here ---------------
if [[ -d "$ROOT/extensions" ]] && find "$ROOT/extensions" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    fail "core repository still vendors extension source"
fi
retired_client="$(printf '%s%s' 'lo' 'on')"
grep -Rni "$retired_client" \
    "$ROOT/README.md" "$ROOT/README.en.md" "$ROOT/docs/architecture.md" \
    "$ROOT/docs/pre-v5-upgrade.md" 2>/dev/null | grep -q . \
    && fail "retired third-party plugin compatibility is still present"
# Only the seed template. docs/architecture.md and migrate-to-monolith.sh name
# these identifiers on purpose -- they are what the upgrade path removes, and a
# migration guide that cannot say what it removes is useless.
grep -niE 'builtin-wloc|MODULE-MITM|MODULE-INTERCEPT|intercept-egress|RUNTIME-OVERLAY' \
    "$ROOT/etc/mihomo/config.yaml.tmpl" 2>/dev/null | grep -q . \
    && fail "retired interception identifiers came back into the seed template"

exit "$rc"
