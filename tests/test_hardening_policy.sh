#!/usr/bin/env bash
# Policy assertions for the §4 security-hardening batch. Pure grep — runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

MIHOMO_SVC="$ROOT/etc/systemd/mihomo.service"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"
INTERCEPT_SVC="$ROOT/etc/systemd/5gpn-intercept.service"
JOURNAL_SVC="$ROOT/etc/systemd/5gpn-journal@.service"
JOURNAL_EXPORT="$ROOT/scripts/export-journal.sh"
INSTALL="$ROOT/install.sh"
GO_DIR="$ROOT/cmd/5gpn-dns"

# --- systemd sandboxing ---
grep -Fq 'NoNewPrivileges=yes'   "$MIHOMO_SVC" || fail "mihomo.service: no NoNewPrivileges"
grep -Fxq 'User=mihomo' "$MIHOMO_SVC" || fail "mihomo.service must run as the dedicated mihomo user"
grep -Fxq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$MIHOMO_SVC" \
    || fail "mihomo.service capability bounding set is broader than low-port bind"
grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$MIHOMO_SVC" \
    || fail "mihomo.service lacks the low-port bind ambient capability"
grep -Fxq 'PrivateDevices=yes' "$MIHOMO_SVC" || fail "mihomo.service does not isolate devices"
grep -Fq 'ProtectSystem=strict'  "$MIHOMO_SVC" || fail "mihomo.service: no ProtectSystem=strict"
grep -Fq 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' "$MIHOMO_SVC" \
    || fail "mihomo.service: unexpected ExecStart"
# mihomo dials IPv4+IPv6 AND needs AF_NETLINK: its UDP/QUIC DIRECT dial does a
# route-table lookup (netlinkrib) that fatals the forward without it (test-env-confirmed).
grep -Fq 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' "$MIHOMO_SVC" || fail "mihomo.service: address families must be AF_INET AF_INET6 AF_NETLINK AF_UNIX (AF_NETLINK required for QUIC/UDP forward)"
# mihomo writes provider caches under its own dir, unlike xray's read-only config mount.
grep -Fq 'ReadWritePaths=/etc/5gpn/mihomo' "$MIHOMO_SVC" || fail "mihomo.service must have ReadWritePaths=/etc/5gpn/mihomo (provider caches)"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/acme' "$MIHOMO_SVC" \
    || fail "mihomo.service must not read the Cloudflare Zone:DNS:Edit token"
grep -Fq -- '-/etc/5gpn/dns.env' "$MIHOMO_SVC" \
    || fail "mihomo.service must not read control-plane bearer secrets"
grep -Fq 'Environment=SAFE_PATHS=/etc/5gpn/cert/zash' "$MIHOMO_SVC" \
    || fail "mihomo.service must scope SAFE_PATHS to /etc/5gpn/cert/zash for the shared controller certificate"

# Phase 5: the Telegram bot + iOS profile responder are in-process goroutines of
# 5gpn-dns (the separate python tgbot/iosprofile heredoc units are gone), so the
# deployed daemon unit is the one that must stay hardened.
grep -Fq 'NoNewPrivileges=yes'  "$DNS_SVC" || fail "5gpn-dns.service: no NoNewPrivileges"
grep -Fxq 'User=gpn-dns' "$DNS_SVC" || fail "5gpn-dns.service must run as its dedicated user"
grep -Fxq 'SupplementaryGroups=mihomo gpn-intercept' "$DNS_SVC" \
    || fail "5gpn-dns.service must receive only its two narrow shared-config groups"
grep -Fq -- '-/etc/5gpn/intercept-ca' "$DNS_SVC" \
    && grep -Fq -- '-/etc/5gpn/intercept/tls' "$DNS_SVC" \
    || fail "5gpn-dns.service must not read the interception CA key or leaf private key"
grep -Fq 'systemd-journal' "$DNS_SVC" \
    && fail "5gpn-dns.service must not receive host-wide journal read access"
grep -Fxq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$DNS_SVC" \
    || fail "5gpn-dns.service capability bounding set is broader than low-port bind"
grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$DNS_SVC" \
    || fail "5gpn-dns.service lacks the low-port bind ambient capability"
grep -Fq 'ProtectSystem=strict' "$DNS_SVC" || fail "5gpn-dns.service: no ProtectSystem=strict"
# 5gpn-dns soft-orders after the mihomo data-plane forwarder (was xray).
grep -Fq 'After=network-online.target mihomo.service' "$DNS_SVC" || fail "5gpn-dns.service must order After=...mihomo.service"

grep -Fxq 'User=gpn-intercept' "$INTERCEPT_SVC" || fail "5gpn-intercept.service must use its dedicated account"
grep -Fxq 'CapabilityBoundingSet=' "$INTERCEPT_SVC" || fail "5gpn-intercept.service must receive no capabilities"
grep -Fxq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$INTERCEPT_SVC" \
    || fail "5gpn-intercept.service must remain IPv4/Unix only"
grep -Fxq 'ReadOnlyPaths=/etc/5gpn/intercept' "$INTERCEPT_SVC" \
    || fail "5gpn-intercept.service must have read-only runtime configuration"
grep -Fq -- '-/etc/5gpn/intercept-ca' "$INTERCEPT_SVC" \
    || fail "5gpn-intercept.service must not read the CA signing key"

# --- public console keeps token authentication; zashboard keeps the IP ACL ---
# The daemon still binds loopback behind mihomo. The old in-process token lockout
# and PROXY-protocol support are removed; /api/* remains bearer-authenticated.
[ ! -f "$GO_DIR/authblock.go" ]  || fail "authblock.go must be removed (no in-process lockout)"
[ ! -f "$GO_DIR/proxyproto.go" ] || fail "proxyproto.go must be removed (console is loopback-bound, no PROXY protocol)"
grep -Fq '127.0.0.1:443' "$GO_DIR/config.go" || fail "config.go: control plane must default to loopback 127.0.0.1:443"

# --- 5gpn-dns binary integrity (mandatory release checksum) ---
grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/5gpn-dns"' "$INSTALL" \
    || fail "no mandatory 5gpn-dns sha256 verification"

POLKIT="$ROOT/etc/polkit-1/rules.d/50-5gpn.rules"
grep -Fq 'subject.user !== "gpn-dns"' "$POLKIT" || fail "polkit rule is not user-scoped"
grep -Fq 'unit === "mihomo.service" && verb === "restart"' "$POLKIT" \
    || fail "polkit rule does not narrowly authorize mihomo restart"
grep -Fq 'unit === "5gpn-certbot-renew.service" && verb === "start"' "$POLKIT" \
    || fail "polkit rule does not narrowly authorize fixed certificate renewal"
grep -Fq 'unit === "5gpn-journal@5gpn-dns.service"' "$POLKIT" \
    && grep -Fq 'unit === "5gpn-journal@mihomo.service"' "$POLKIT" \
    || fail "polkit rule does not narrowly authorize both fixed journal exporters"
grep -Fxq '# 5gpn-unit-id: 5gpn-journal@.service:v1' "$JOURNAL_SVC" \
    || fail "journal exporter unit lacks its exact ownership marker"
grep -Fxq 'User=root' "$JOURNAL_SVC" || fail "journal exporter must run as root"
grep -Fxq 'Group=gpn-dns' "$JOURNAL_SVC" || fail "journal exporter output group is not scoped to the daemon"
grep -Fxq 'CapabilityBoundingSet=' "$JOURNAL_SVC" || fail "journal exporter retains Linux capabilities"
grep -Fxq 'ExecStart=/opt/5gpn/scripts/export-journal.sh %i' "$JOURNAL_SVC" \
    || fail "journal exporter does not use the fixed validated helper"
grep -Fq 'tail -c 262144' "$JOURNAL_EXPORT" || fail "journal exporter output is not byte-bounded"
grep -Fq '5gpn-dns) unit="5gpn-dns.service"' "$JOURNAL_EXPORT" \
    && grep -Fq 'mihomo) unit="mihomo.service"' "$JOURNAL_EXPORT" \
    || fail "journal exporter helper accepts an unbounded service set"
grep -Fq 'install_service_accounts' "$INSTALL" || fail "installer does not create service accounts"
grep -Fq 'install_polkit_rule' "$INSTALL" || fail "installer does not publish the fixed polkit rule"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
