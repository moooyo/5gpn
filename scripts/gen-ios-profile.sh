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

mkdir -p "$WWW_DIR"
profile_path="${WWW_DIR}/ios-dot.mobileconfig"

cat > "$profile_path" <<EOF
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
# DNS. If signing is impossible (no cert / openssl), the UNSIGNED profile is
# REFUSED and removed (fail closed). Caller-environment overrides are not a
# configuration surface.
CERT_DIR="/etc/5gpn/cert/dot/current"
sign_ok=0
if command -v openssl >/dev/null 2>&1 \
   && [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    # Every non-leaf cert in fullchain.pem must ride along in the CMS
    # signature: LE's Gen-Y chain (leaf ← YE2 ← Root YE ← cross-signed X2 ← X1)
    # only reaches an anchor iOS actually trusts via the cross-certs — Root YE
    # is not in Apple's trust store yet, so trimming to just the issuing
    # intermediate breaks verification. Only the leaf is dropped here (openssl
    # -signer already embeds it; -certfile fullchain would duplicate it).
    chain_path="$(mktemp)"
    awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' "${CERT_DIR}/fullchain.pem" > "$chain_path"
    certfile_args=()
    [[ -s "$chain_path" ]] && certfile_args=(-certfile "$chain_path")
    if openssl smime -sign -nodetach -outform der \
        -signer "${CERT_DIR}/fullchain.pem" -inkey "${CERT_DIR}/privkey.pem" \
        "${certfile_args[@]}" \
        -in "$profile_path" -out "${profile_path}.signed" 2>/dev/null; then
        mv "${profile_path}.signed" "$profile_path"
        ok "Signed ${profile_path} with the Let's Encrypt cert (iOS will show Verified)."
        sign_ok=1
    else
        rm -f "${profile_path}.signed"
        warn "openssl smime sign failed."
    fi
    rm -f "$chain_path"
else
    warn "No cert at ${CERT_DIR} (or openssl missing)."
fi
if [[ $sign_ok -ne 1 ]]; then
    rm -f "$profile_path"
    err "Refusing to serve an UNSIGNED .mobileconfig. Repair the configured certificate and rerun the TUI profile action."
    exit 1
fi

ok "Wrote ${profile_path}"

# Generate a separate, explicitly removable profile for the dedicated modular
# interception root. Keeping this payload separate from the cellular DoT profile
# lets an operator revoke interception trust without changing DNS enrollment.
INTERCEPT_CA="/etc/5gpn/intercept-ca/root.crt"
intercept_profile_path="${WWW_DIR}/ios-intercept-ca.mobileconfig"
if [[ ! -f "$INTERCEPT_CA" || -L "$INTERCEPT_CA" ]]; then
    rm -f "$intercept_profile_path"
    err "Dedicated interception CA is missing or unsafe: $INTERCEPT_CA"
    exit 1
fi
INTERCEPT_PAYLOAD_UUID="$(gen_uuid)"
INTERCEPT_TOP_UUID="$(gen_uuid)"
INTERCEPT_CA_DER_BASE64="$(openssl x509 -in "$INTERCEPT_CA" -outform DER 2>/dev/null | openssl base64 -A)"
[[ -n "$INTERCEPT_CA_DER_BASE64" ]] || { err "Could not encode the interception CA."; exit 1; }
cat > "$intercept_profile_path" <<EOF
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
            <string>Trusts only the dedicated 5gpn modular interception certificate authority.</string>
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
    <string>Installs the opt-in CA used only for explicitly enabled 5gpn interception modules.</string>
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

chain_path="$(mktemp)"
awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' "${CERT_DIR}/fullchain.pem" > "$chain_path"
certfile_args=()
[[ -s "$chain_path" ]] && certfile_args=(-certfile "$chain_path")
if openssl smime -sign -nodetach -outform der \
    -signer "${CERT_DIR}/fullchain.pem" -inkey "${CERT_DIR}/privkey.pem" \
    "${certfile_args[@]}" \
    -in "$intercept_profile_path" -out "${intercept_profile_path}.signed" 2>/dev/null; then
    mv "${intercept_profile_path}.signed" "$intercept_profile_path"
else
    rm -f "$chain_path" "$intercept_profile_path" "${intercept_profile_path}.signed"
    err "Refusing to serve an unsigned interception CA profile."
    exit 1
fi
rm -f "$chain_path"
ok "Wrote signed ${intercept_profile_path}"
