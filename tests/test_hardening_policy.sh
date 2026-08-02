#!/usr/bin/env bash
# Sandboxing policy. Pure grep — runs on the dev box, asserts nothing about a
# live host.
#
# There is one long-running unit now, so it carries the union of what three used
# to guard, and this file follows it. Nothing here was dropped because the
# monolith made it moot: a property that mattered when the DNS engine and the
# interception engine were separate processes matters at least as much when they
# share an address space, because a weakness in either now reaches both.
#
# What did go are the assertions about coordination — the overlay sockets, the
# groups that passed them between service users, the polkit rule that let one
# service user restart another's unit, and the journal exporter that existed so
# a sandboxed daemon could read a log it had no permission to open. Those
# guarded a boundary that no longer exists.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SVC="$ROOT/etc/systemd/mihomo.service"
CERT_SVC="$ROOT/etc/systemd/5gpn-intercept-cert.service"
INSTALL="$ROOT/install.sh"

# --- the one long-running unit -------------------------------------------
grep -Fq 'NoNewPrivileges=yes' "$SVC" || fail "mihomo.service: no NoNewPrivileges"
grep -Fxq 'User=mihomo' "$SVC" || fail "mihomo.service must run as its dedicated user"
grep -Fq 'ProtectSystem=strict' "$SVC" || fail "mihomo.service: no ProtectSystem=strict"
grep -Fxq 'PrivateDevices=yes' "$SVC" || fail "mihomo.service does not isolate devices"
grep -Fxq 'ProtectHome=yes' "$SVC" || fail "mihomo.service does not isolate home directories"
grep -Fxq 'ProtectProc=invisible' "$SVC" || fail "mihomo.service can enumerate other processes"
grep -Fxq 'RestrictSUIDSGID=yes' "$SVC" || fail "mihomo.service can create setuid files"
grep -Fq 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' "$SVC" \
    || fail "mihomo.service: unexpected ExecStart"

# Binding :853 and the operator's gateway ports is the whole reason a capability
# is needed at all; anything wider is not.
grep -Fxq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$SVC" \
    || fail "mihomo.service capability bounding set is broader than low-port bind"
grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$SVC" \
    || fail "mihomo.service lacks the low-port bind ambient capability"

# AF_NETLINK is required and not decorative: the UDP/QUIC DIRECT dial path does
# a route-table lookup that fatals the forward without it, while TCP is
# unaffected — so removing it presents as "QUIC is broken", not as a sandbox
# problem.
grep -Fxq 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' "$SVC" \
    || fail "mihomo.service: address families must be AF_INET AF_INET6 AF_NETLINK AF_UNIX (AF_NETLINK is required for the QUIC/UDP forward)"

# The state documents live under mihomo's own directory, and per-extension
# storage is the only other thing this process writes.
grep -Fq 'ReadWritePaths=/etc/5gpn/mihomo /var/lib/5gpn-intercept' "$SVC" \
    || fail "mihomo.service write scope is not exactly its own directory and extension storage"

# The signing key can mint a leaf for any name. An engine that could read it
# would be a compromise of every identity this gateway can present, permanently
# and far beyond the SAN set the published leaf bounds it to.
grep -Fq -- '-/etc/5gpn/intercept-ca' "$SVC" \
    || fail "mihomo.service must not be able to read the interception CA signing key"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/intercept-ca -/etc/5gpn/acme' "$SVC" \
    || fail "mihomo.service must not read the ACME credentials"
grep -Fq -- '-/etc/5gpn/dns.env' "$SVC" \
    || fail "mihomo.service must not read installer-owned secrets"

# Certificates are read-only. A network-facing process able to replace its own
# leaf could replace the SAN set that bounds what it may intercept.
grep -Fq 'ReadOnlyPaths=/etc/5gpn/cert /etc/5gpn/intercept/tls /opt/5gpn/ui' "$SVC" \
    || fail "mihomo.service can write the certificates or the UI bundle it serves"
grep -Fq 'Environment=SAFE_PATHS=/etc/5gpn/cert/zash:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui' "$SVC" \
    || fail "mihomo.service SAFE_PATHS must name exactly the paths it serves from outside its own directory"

# The leaf is published by the root oneshot and read through this group. It must
# be the only supplementary group: the two overlay socket groups existed to hand
# a socket between service users and have no remaining purpose.
grep -Fxq 'SupplementaryGroups=gpn-intercept' "$SVC" \
    || fail "mihomo.service must hold exactly the leaf-reading group"
grep -Fq 'systemd-journal' "$SVC" \
    && fail "mihomo.service must not receive host-wide journal read access"
grep -Fq '5gpn-overlay' "$SVC" \
    && fail "mihomo.service still joins an overlay socket group that no longer exists"

# --- the root oneshot that does hold the key ------------------------------
grep -Fxq 'User=root' "$CERT_SVC" || fail "the certificate oneshot must run as root"
grep -Fxq 'CapabilityBoundingSet=' "$CERT_SVC" || fail "the certificate oneshot retains capabilities"
grep -Fxq 'RestrictAddressFamilies=AF_UNIX' "$CERT_SVC" \
    || fail "the certificate oneshot must have no network access at all"
grep -Fq 'ReadWritePaths=/etc/5gpn/intercept /run/5gpn' "$CERT_SVC" \
    || fail "the certificate oneshot writes outside the leaf and its runtime directory"
grep -Fq 'ProtectSystem=strict' "$CERT_SVC" || fail "the certificate oneshot: no ProtectSystem=strict"

# --- installer -------------------------------------------------------------
grep -Fq 'install_service_accounts' "$INSTALL" || fail "installer does not create service accounts"
# The published asset is the compressed one, so that is what the pin covers.
# Checking the unpacked binary instead would verify something gzip produced
# rather than something the release published.
grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/mihomo.gz" "$MIHOMO_SHA256"' "$INSTALL" \
    || fail "no mandatory checksum verification for the one binary's published asset"

# The polkit rule authorized one service user to restart another's unit. With
# one unit there is no such relationship, and a rule granting a network-facing
# account the ability to restart system services would now be a capability
# nothing needs.
[ ! -f "$ROOT/etc/polkit-1/rules.d/50-5gpn.rules" ] \
    || fail "the polkit rule survived the collapse to one unit"
grep -Fq 'install_polkit_rule' "$INSTALL" \
    && fail "installer still publishes a polkit rule for a boundary that no longer exists"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
