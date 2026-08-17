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

SVC="$ROOT/etc/systemd/5gpn-mihomo.service"
CERT_SVC="$ROOT/etc/systemd/5gpn-intercept-cert.service"
INSTALL="$ROOT/install.sh"
DNS_ENV_EXAMPLE="$ROOT/etc/5gpn/dns.env.example"

unit_has_unique_directive_in_section() {
    local section="$1" key="$2" expected="$3" file="$4"
    awk -v wanted_section="[$section]" -v wanted_key="$key" -v wanted_line="$expected" '
        /^\[[^]]+\]$/ { current_section = $0 }
        $0 ~ "^[[:space:]]*" wanted_key "=" {
            directives++
            if (current_section == wanted_section && $0 == wanted_line) correct++
        }
        END { exit !(directives == 1 && correct == 1) }
    ' "$file"
}

# --- the one long-running unit -------------------------------------------
grep -Fq 'NoNewPrivileges=yes' "$SVC" || fail "5gpn-mihomo.service: no NoNewPrivileges"
grep -Fxq 'User=fivegpn' "$SVC" || fail "5gpn-mihomo.service must run as fivegpn"
grep -Fxq 'Group=fivegpn' "$SVC" || fail "5gpn-mihomo.service must use the fivegpn primary group"
grep -Fq 'ProtectSystem=strict' "$SVC" || fail "5gpn-mihomo.service: no ProtectSystem=strict"
grep -Fxq 'PrivateDevices=yes' "$SVC" || fail "5gpn-mihomo.service does not isolate devices"
grep -Fxq 'ProtectHome=yes' "$SVC" || fail "5gpn-mihomo.service does not isolate home directories"
grep -Fxq 'ProtectProc=invisible' "$SVC" || fail "5gpn-mihomo.service can enumerate other processes"
grep -Fxq 'RestrictSUIDSGID=yes' "$SVC" || fail "5gpn-mihomo.service can create setuid files"
grep -Fq 'ExecStart=/opt/5gpn/bin/5gpn-mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' "$SVC" \
    || fail "5gpn-mihomo.service: unexpected ExecStart"
grep -Fxq 'ExecStartPre=+/opt/5gpn/scripts/configure-runtime-gate.sh wait' "$SVC" \
    || fail "5gpn-mihomo.service lacks the root-only PID1 restart gate"
grep -Fxq 'ExecStartPre=/opt/5gpn/scripts/configure-runtime-gate.sh validate-ui' "$SVC" \
    || fail "5gpn-mihomo.service does not validate the current UI generation before listeners start"
gate_line="$(grep -nF 'ExecStartPre=+/opt/5gpn/scripts/configure-runtime-gate.sh wait' "$SVC" | cut -d: -f1)"
ui_line="$(grep -nF 'ExecStartPre=/opt/5gpn/scripts/configure-runtime-gate.sh validate-ui' "$SVC" | cut -d: -f1)"
[[ -n "$gate_line" && -n "$ui_line" && "$gate_line" -lt "$ui_line" \
   && "$(grep -c '^ExecStartPre=+' "$SVC")" == 1 ]] \
    || fail "only the first configure gate may use systemd's privileged exec prefix"
grep -Fxq 'TimeoutStartSec=40min' "$SVC" \
    || fail "the service start timeout cannot cover the bounded configure gate"
grep -Eq '^RuntimeDirectory=' "$SVC" \
    && fail "5gpn-mihomo.service must not own the root certificate-lock directory"

# The monolith is one failure domain. Fatal runtime failures replace the whole
# process from its persisted state; a bounded start rate prevents a persistent
# configuration or host error from spinning without limit. systemd deliberately
# suppresses Restart=always after an explicit stop operation.
unit_has_unique_directive_in_section Service Restart 'Restart=always' "$SVC" \
    || fail "5gpn-mihomo.service must always restart after an unexpected exit"
unit_has_unique_directive_in_section Service RestartSec 'RestartSec=3' "$SVC" \
    || fail "5gpn-mihomo.service restart delay must be exactly three seconds"
unit_has_unique_directive_in_section Unit StartLimitIntervalSec 'StartLimitIntervalSec=60' "$SVC" \
    || fail "5gpn-mihomo.service start-limit interval must be 60 seconds in [Unit]"
unit_has_unique_directive_in_section Unit StartLimitBurst 'StartLimitBurst=10' "$SVC" \
    || fail "5gpn-mihomo.service start-limit burst must be 10 in [Unit]"
unit_has_unique_directive_in_section Unit StartLimitAction 'StartLimitAction=none' "$SVC" \
    || fail "5gpn-mihomo.service start-limit action must never reboot or power off the host"
! grep -Eq '^DNS_HEARTBEAT_(URL|INTERVAL)=' "$DNS_ENV_EXAMPLE" \
    || fail "dns.env.example still persists the retired heartbeat fields"
grep -Eq 'daemon GETs this URL|dead-man.s switch' "$DNS_ENV_EXAMPLE" \
    && fail "dns.env.example retains the deleted in-process heartbeat promise"

# Binding :853 and the operator's gateway ports is the whole reason a capability
# is needed at all; anything wider is not.
grep -Fxq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$SVC" \
    || fail "5gpn-mihomo.service capability bounding set is broader than low-port bind"
grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$SVC" \
    || fail "5gpn-mihomo.service lacks the low-port bind ambient capability"

# AF_NETLINK is required and not decorative: the UDP/QUIC DIRECT dial path does
# a route-table lookup that fatals the forward without it, while TCP is
# unaffected — so removing it presents as "QUIC is broken", not as a sandbox
# problem.
grep -Fxq 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' "$SVC" \
    || fail "5gpn-mihomo.service: address families must be AF_INET AF_INET6 AF_NETLINK AF_UNIX (AF_NETLINK is required for the QUIC/UDP forward)"

# The state documents live under mihomo's own directory, and per-extension
# storage is the only other thing this process writes.
grep -Fq 'ReadWritePaths=/etc/5gpn/mihomo /var/lib/5gpn-intercept' "$SVC" \
    || fail "5gpn-mihomo.service write scope is not exactly its own directory and extension storage"

# The signing key can mint a leaf for any name. An engine that could read it
# would be a compromise of every identity this gateway can present, permanently
# and far beyond the SAN set the published leaf bounds it to.
grep -Fq -- '-/etc/5gpn/intercept-ca' "$SVC" \
    || fail "5gpn-mihomo.service must not be able to read the interception CA signing key"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/intercept-ca -/etc/5gpn/acme' "$SVC" \
    || fail "5gpn-mihomo.service must not read the ACME credentials"
grep -Fq -- '-/etc/5gpn/dns.env' "$SVC" \
    || fail "5gpn-mihomo.service must not read installer-owned secrets"

# Certificates are read-only. A network-facing process able to replace its own
# leaf could replace the SAN set that bounds what it may intercept.
grep -Fq 'ReadOnlyPaths=/etc/5gpn/cert /etc/5gpn/intercept/tls /opt/5gpn/ui' "$SVC" \
    || fail "5gpn-mihomo.service can write the certificates or the UI bundle it serves"
grep -Fq 'Environment=SAFE_PATHS=/etc/5gpn/cert/console:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui' "$SVC" \
    || fail "5gpn-mihomo.service SAFE_PATHS must name exactly the paths it serves from outside its own directory"

# The leaf and runtime share the fivegpn primary group. No supplementary group
# is needed now that there is one service identity.
grep -Eq '^SupplementaryGroups=' "$SVC" \
    && fail "5gpn-mihomo.service must not join supplementary service groups"
grep -Fq 'systemd-journal' "$SVC" \
    && fail "5gpn-mihomo.service must not receive host-wide journal read access"
grep -Fq '5gpn-overlay' "$SVC" \
    && fail "5gpn-mihomo.service still joins an overlay socket group that no longer exists"
grep -Fxq 'After=network-online.target 5gpn-intercept-cert.path' "$SVC" \
    || fail "the certificate watcher is not ordered before 5gpn-mihomo"
grep -Fxq 'Wants=network-online.target 5gpn-intercept-cert.path' "$SVC" \
    || fail "5gpn-mihomo does not pull in the certificate watcher"
grep -Eq '^RuntimeDirectory=5gpn$' "$SVC" \
    && fail "the main unit still owns the root-only shared lock directory"

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
start_fn="$(sed -n '/^start_services()/,/^}/p' "$INSTALL")"
reset_fn="$(sed -n '/^reset_systemd_failed_state()/,/^}/p' "$INSTALL")"
grep -Fq 'systemctl reset-failed "$unit"' <<<"$reset_fn" \
    || fail "systemd failed-state helper no longer attempts reset-failed"
grep -Fq 'LoadState' <<<"$reset_fn" && grep -Fq 'ActiveState' <<<"$reset_fn" \
    || fail "systemd failed-state helper does not inspect the effective unit state"
cert_reset="$(grep -nF 'reset_systemd_failed_state 5gpn-intercept-cert.service' <<<"$start_fn" | cut -d: -f1)"
path_enable="$(grep -nF 'systemctl enable --now 5gpn-intercept-cert.path' <<<"$start_fn" | cut -d: -f1)"
main_reset="$(grep -nF 'reset_systemd_failed_state 5gpn-mihomo.service' <<<"$start_fn" | cut -d: -f1)"
main_restart="$(grep -nF 'systemctl restart 5gpn-mihomo.service' <<<"$start_fn" | cut -d: -f1)"
[[ -n "$cert_reset" && -n "$path_enable" && "$cert_reset" -lt "$path_enable" ]] \
    || fail "certificate publisher start-limit is not cleared before arming the watcher"
[[ -n "$main_reset" && -n "$main_restart" && "$main_reset" -lt "$main_restart" ]] \
    || fail "validated install does not clear the main start-limit before its single restart"
grep -Fq 'systemctl start 5gpn-mihomo.service' <<<"$start_fn" \
    && fail "service activation still consumes a second start token after restart failure"
# The published asset is the compressed one, so that is what the pin covers.
# Checking the unpacked binary instead would verify something gzip produced
# rather than something the release published.
grep -Fq 'mihomo_sha="$(release_artifact_sha256 mihomo)"' "$INSTALL" \
    && grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/mihomo.gz" "$mihomo_sha"' "$INSTALL" \
    || fail "no mandatory centralized checksum verification for the one binary's published asset"

# The polkit rule authorized one service user to restart another's unit. With
# one unit there is no such relationship, and a rule granting a network-facing
# account the ability to restart system services would now be a capability
# nothing needs.
[ ! -f "$ROOT/etc/polkit-1/rules.d/50-5gpn.rules" ] \
    || fail "the polkit rule survived the collapse to one unit"
grep -Fq 'install_polkit_rule' "$INSTALL" \
    && fail "installer still publishes a polkit rule for a boundary that no longer exists"
deps_fn="$(sed -n '/^install_deps()/,/^}/p' "$INSTALL")"
printf '%s' "$deps_fn" | grep -Eq 'polkitd|libcap2-bin|libcap-ng-utils|[[:space:]]polkit([[:space:]\\]|$)|[[:space:]]wget([[:space:]\\]|$)' \
    && fail "installer still installs packages used only by retired polkit/setcap/download paths"

[ $rc -eq 0 ] && echo "hardening policy: PASS"
exit $rc
