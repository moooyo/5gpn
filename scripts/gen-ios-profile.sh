#!/bin/bash
# Generate the new-5gpn iOS DoT configuration profile (.mobileconfig) + landing page.
#
# Architecture: client DoT:853 -> smartdns -> sniproxy -> DIRECT egress.
# The profile points the phone's cellular DNS at this gateway over TLS (DoT). On
# Wi-Fi it disconnects, so it only applies on cellular as designed.
#
# Usage: gen-ios-profile.sh <DOMAIN> <GATEWAY_IP> <WWW_DIR>
#   GATEWAY_IP = client-facing gateway address written into ServerAddresses
#   (public IP for public deployments, internal 172.22 addr for NPN-only).
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <DOMAIN> <PUBLIC_IP> <WWW_DIR>" >&2
    exit 1
fi

DOMAIN="$1"
GATEWAY_IP="$2"
WWW_DIR="$3"

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || python3 -c 'import uuid; print(uuid.uuid4())'
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
            <string>new-5gpn Cellular DoT</string>
            <key>PayloadIdentifier</key>
            <string>com.new-5gpn.${DOMAIN}.dnssettings</string>
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
    <string>new-5gpn Cellular DoT</string>
    <key>PayloadIdentifier</key>
    <string>com.new-5gpn.${DOMAIN}</string>
    <key>PayloadOrganization</key>
    <string>new-5gpn</string>
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

cat > "${WWW_DIR}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>new-5gpn iOS DoT</title>
</head>
<body>
  <h1>new-5gpn iOS DoT</h1>
  <p><a href="/ios-dot.mobileconfig">下载 iOS 蜂窝网络 DoT 描述文件</a></p>
</body>
</html>
EOF

echo "[+] Wrote ${profile_path}"
echo "[+] Wrote ${WWW_DIR}/index.html"
