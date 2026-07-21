#!/bin/bash
# Generate the signed 5gpn iOS DoT configuration profile (.mobileconfig).
#
# Architecture: client DoT:853 (the ONLY DNS transport) -> 5gpn-dns; DNS
# answers then steer application traffic to direct origins or the mihomo gateway.
# The profile points the phone's cellular DNS at this gateway over TLS (DoT). On
# Wi-Fi it disconnects, so it only applies on cellular as designed.
#
# Usage: gen-ios-profile.sh <DOMAIN> <GATEWAY_IP> <WWW_DIR>
#   GATEWAY_IP = client-facing gateway address written into ServerAddresses
#   (public IP for public deployments, internal 172.22 addr for NPN-only).
set -euo pipefail

# --- Gum-or-echo status helpers (gum when on PATH + interactive; else plain echo).
# Installing gum is install.sh's job (install_gum); here we only detect + use it. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

if [[ $# -ne 3 ]]; then
    err "Usage: $0 <DOMAIN> <PUBLIC_IP> <WWW_DIR>"
    exit 1
fi

DOMAIN="$1"
GATEWAY_IP="$2"
WWW_DIR="$3"

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || uuidgen
}

PAYLOAD_UUID="$(gen_uuid)"
TOP_UUID="$(gen_uuid)"

if [[ -e "$WWW_DIR" || -L "$WWW_DIR" ]]; then
    [[ -d "$WWW_DIR" && ! -L "$WWW_DIR" ]] \
        || { err "Unsafe iOS profile directory: $WWW_DIR"; exit 1; }
else
    mkdir -p -- "$WWW_DIR"
fi

# Both payloads are completed in one private, same-filesystem staging directory.
# Nothing under the public filenames changes until both CMS signatures exist.
stage_dir="$(mktemp -d "${WWW_DIR}/.ios-profile.XXXXXX")" \
    || { err "Could not create the iOS profile staging directory."; exit 1; }
chmod 0700 "$stage_dir" \
    || { rmdir -- "$stage_dir" 2>/dev/null || true; exit 1; }
profile_path="${WWW_DIR}/ios-dot.mobileconfig"
intercept_profile_path="${WWW_DIR}/ios-intercept-ca.mobileconfig"
staged_profile="${stage_dir}/ios-dot.mobileconfig"
unsigned_profile="${stage_dir}/ios-dot.mobileconfig.unsigned"
staged_intercept_profile="${stage_dir}/ios-intercept-ca.mobileconfig"
unsigned_intercept_profile="${stage_dir}/ios-intercept-ca.mobileconfig.unsigned"
chain_path="${stage_dir}/signing-chain.pem"
old_profile="${stage_dir}/old-ios-dot.mobileconfig"
old_intercept_profile="${stage_dir}/old-ios-intercept-ca.mobileconfig"
profile_had_old=0
intercept_had_old=0
publication_started=0
publication_complete=0
preserve_profile_stage=0

cleanup_profile_stage() {
    rm -f -- \
        "$staged_profile" "$unsigned_profile" \
        "$staged_intercept_profile" "$unsigned_intercept_profile" \
        "$chain_path" "$old_profile" "$old_intercept_profile" \
        2>/dev/null || true
    rmdir -- "$stage_dir" 2>/dev/null || true
}

restore_profile_snapshot() {
    local had_old="$1" backup="$2" live="$3" label="$4"
    if [[ "$had_old" == 1 ]]; then
        if [[ ! -f "$backup" || -L "$backup" ]]; then
            err "Cannot restore the previous ${label}; snapshot is missing or unsafe: $backup" || true
            return 1
        fi
        if [[ -f "$live" && ! -L "$live" && "$live" -ef "$backup" ]]; then
            return 0
        fi
        if ! mv -Tf -- "$backup" "$live"; then
            err "Cannot restore the previous ${label} from $backup" || true
            return 1
        fi
    elif ! rm -f -- "$live"; then
        err "Cannot restore the previous absence of ${label}: $live" || true
        return 1
    fi
}

rollback_profile_publication() {
    local rollback_ok=1
    restore_profile_snapshot "$profile_had_old" "$old_profile" \
        "$profile_path" "DoT profile" || rollback_ok=0
    restore_profile_snapshot "$intercept_had_old" "$old_intercept_profile" \
        "$intercept_profile_path" "interception profile" || rollback_ok=0
    [[ "$rollback_ok" == 1 ]]
}

profile_script_exit() {
    local rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$publication_started" == 1 && "$publication_complete" != 1 ]]; then
        if rollback_profile_publication; then
            err "Incomplete iOS profile publication was rolled back." || true
        else
            preserve_profile_stage=1
            rc=1
            err "Profile publication rollback failed; recovery evidence retained at ${stage_dir}." || true
        fi
    fi
    if [[ "$preserve_profile_stage" != 1 ]]; then
        cleanup_profile_stage
    fi
    exit "$rc"
}

profile_script_signal() {
    local signal_name="$1" signal_status="$2"
    err "Interrupted by ${signal_name} during iOS profile generation." || true
    exit "$signal_status"
}

trap profile_script_exit EXIT
trap 'profile_script_signal HUP 129' HUP
trap 'profile_script_signal INT 130' INT
trap 'profile_script_signal TERM 143' TERM

cat > "$unsigned_profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>TLS</string>
                <key>ServerName</key>
                <string>${DOMAIN}</string>
                <key>ServerAddresses</key>
                <array>
                    <string>${GATEWAY_IP}</string>
                </array>
            </dict>
            <key>OnDemandRules</key>
            <array>
                <dict>
                    <key>Action</key>
                    <string>Connect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>Cellular</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>WiFi</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Use ${DOMAIN} DNS over TLS only on cellular networks.</string>
            <key>PayloadDisplayName</key>
            <string>5gpn Cellular DoT</string>
            <key>PayloadIdentifier</key>
            <string>com.5gpn.${DOMAIN}.dnssettings</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>${PAYLOAD_UUID}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs a DNS over TLS profile for cellular networks only.</string>
    <key>PayloadDisplayName</key>
    <string>5gpn Cellular DoT</string>
    <key>PayloadIdentifier</key>
    <string>com.5gpn.${DOMAIN}</string>
    <key>PayloadOrganization</key>
    <string>5gpn</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${TOP_UUID}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

# Sign the .mobileconfig with the deployment's Let's Encrypt cert so iOS shows a
# "Verified" profile and REJECTS any in-flight tampering — the delivery is over
# the network, so an on-path attacker could otherwise
# rewrite ServerName/ServerAddresses and persistently hijack the phone's cellular
# DNS. If signing is impossible (no cert / openssl), the staged unsigned profile
# is refused while any last-known-good live profiles remain untouched. Caller-
# environment overrides are not a configuration surface.
CERT_DIR="/etc/5gpn/cert/dot/current"
if ! command -v openssl >/dev/null 2>&1 \
   || [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
    warn "No cert at ${CERT_DIR} (or openssl missing)."
    err "Refusing to serve an UNSIGNED .mobileconfig. Repair the configured certificate and rerun the TUI profile action."
    exit 1
fi

# Every non-leaf cert in fullchain.pem must ride along in the CMS signature:
# LE's Gen-Y chain (leaf ← YE2 ← Root YE ← cross-signed X2 ← X1) only
# reaches an anchor iOS actually trusts via the cross-certs. Only the leaf is
# dropped here because -signer already embeds it.
awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' \
    "${CERT_DIR}/fullchain.pem" > "$chain_path"
certfile_args=()
[[ -s "$chain_path" ]] && certfile_args=(-certfile "$chain_path")
if ! openssl smime -sign -nodetach -outform der \
    -signer "${CERT_DIR}/fullchain.pem" -inkey "${CERT_DIR}/privkey.pem" \
    "${certfile_args[@]}" \
    -in "$unsigned_profile" -out "$staged_profile" 2>/dev/null; then
    err "Refusing to serve an UNSIGNED .mobileconfig. Repair the configured certificate and rerun the TUI profile action."
    exit 1
fi
chmod 0644 "$staged_profile"

# Generate a separate, explicitly removable profile for the shared modular
# interception root. Keeping this payload separate from the cellular DoT profile
# lets an operator revoke interception trust without changing DNS enrollment.
INTERCEPT_CA="/etc/5gpn/intercept-ca/root.crt"
if [[ ! -f "$INTERCEPT_CA" || -L "$INTERCEPT_CA" ]]; then
    err "Dedicated interception CA is missing or unsafe: $INTERCEPT_CA"
    exit 1
fi
INTERCEPT_PAYLOAD_UUID="$(gen_uuid)"
INTERCEPT_TOP_UUID="$(gen_uuid)"
INTERCEPT_CA_DER_BASE64="$(
    openssl x509 -in "$INTERCEPT_CA" -outform DER 2>/dev/null | openssl base64 -A
)"
[[ -n "$INTERCEPT_CA_DER_BASE64" ]] || { err "Could not encode the interception CA."; exit 1; }
cat > "$unsigned_intercept_profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadContent</key>
            <data>${INTERCEPT_CA_DER_BASE64}</data>
            <key>PayloadDescription</key>
            <string>Trusts the shared root used by all enabled 5gpn modular interception hosts.</string>
            <key>PayloadDisplayName</key>
            <string>5gpn Interception CA</string>
            <key>PayloadIdentifier</key>
            <string>com.5gpn.interception.ca</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>${INTERCEPT_PAYLOAD_UUID}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs the opt-in shared root used by explicitly enabled 5gpn interception modules.</string>
    <key>PayloadDisplayName</key>
    <string>5gpn Interception Trust</string>
    <key>PayloadIdentifier</key>
    <string>com.5gpn.interception</string>
    <key>PayloadOrganization</key>
    <string>5gpn</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${INTERCEPT_TOP_UUID}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

if ! openssl smime -sign -nodetach -outform der \
    -signer "${CERT_DIR}/fullchain.pem" -inkey "${CERT_DIR}/privkey.pem" \
    "${certfile_args[@]}" \
    -in "$unsigned_intercept_profile" -out "$staged_intercept_profile" 2>/dev/null; then
    err "Refusing to serve an unsigned interception CA profile."
    exit 1
fi
chmod 0644 "$staged_intercept_profile"

# Snapshot both existing profiles with same-filesystem hard links. Publication
# rollback retains these links until both atomic renames are known to have
# completed; a failed rollback preserves the private directory as evidence.
if [[ -e "$profile_path" || -L "$profile_path" ]]; then
    [[ -f "$profile_path" && ! -L "$profile_path" ]] \
        || { err "Unsafe existing iOS profile: $profile_path"; exit 1; }
    ln -- "$profile_path" "$old_profile" \
        || { err "Could not snapshot the existing iOS profile."; exit 1; }
    profile_had_old=1
fi
if [[ -e "$intercept_profile_path" || -L "$intercept_profile_path" ]]; then
    [[ -f "$intercept_profile_path" && ! -L "$intercept_profile_path" ]] \
        || { err "Unsafe existing interception profile: $intercept_profile_path"; exit 1; }
    ln -- "$intercept_profile_path" "$old_intercept_profile" \
        || { err "Could not snapshot the existing interception profile."; exit 1; }
    intercept_had_old=1
fi

# Set the transaction state before the first rename. If a signal arrives after
# either rename but before the following shell statement, EXIT still restores
# both previous files (or their previous absence).
publication_started=1
if ! mv -Tf -- "$staged_profile" "$profile_path"; then
    err "Could not atomically publish the signed iOS profile."
    exit 1
fi
if ! mv -Tf -- "$staged_intercept_profile" "$intercept_profile_path"; then
    err "Could not atomically publish both signed profiles."
    exit 1
fi
publication_complete=1

ok "Signed ${profile_path} with the deployment certificate (iOS will show Verified)."
ok "Wrote ${profile_path}"
ok "Wrote signed ${intercept_profile_path}"
