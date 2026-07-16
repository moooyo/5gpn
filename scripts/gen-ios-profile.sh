#!/bin/bash
# Generate the 5gpn iOS DoT configuration profile (.mobileconfig) + landing page.
#
# Architecture: client DoT:853 (the ONLY DNS transport) -> 5gpn-dns -> Xray-core -> DIRECT egress.
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
CERT_DIR="/etc/5gpn/cert/dot"
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

# Landing page: the CSS and JavaScript are emitted as same-origin files instead
# of inline blocks. The control server's CSP intentionally rejects inline
# <style>/<script>; keeping these external means the public bootstrap page works
# under exactly the same strict policy as the authenticated console.
if [[ $sign_ok -eq 1 ]]; then
    SIGNED_CLASS="ok"
    SIGNED_TEXT="已签名 · iOS 显示“已验证”"
else
    SIGNED_CLASS="warn"
    SIGNED_TEXT="未签名 · 安装时 iOS 会警告"
fi

cat > "${WWW_DIR}/ios.css" <<'CSS'
:root{--primary:#6865c6;--primary-press:#5a57b8;--base:#f5f5f7;--card:#fff;--border:#d2d2d7;--text:#1d1d1f;--muted:#6e6e73;--success:#248a3d;--warning:#b25000;--error:#d70015}
@media(prefers-color-scheme:dark){:root{--primary:#8583e9;--primary-press:#716ee0;--base:#000;--card:#1d1d1f;--border:#424245;--text:#f5f5f7;--muted:#98989d;--success:#30d158;--warning:#ff9f0a;--error:#ff453a}}
*{box-sizing:border-box;margin:0;padding:0}html{-webkit-text-size-adjust:100%}body{min-height:100vh;padding:max(env(safe-area-inset-top),1.25rem) 1rem max(env(safe-area-inset-bottom),2rem);background:var(--base);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;line-height:1.6;-webkit-font-smoothing:antialiased}.wrap{display:flex;max-width:26rem;margin:auto;flex-direction:column;gap:.875rem}header{display:flex;align-items:center;gap:.625rem;padding:.25rem .125rem .5rem}.mark{width:.75rem;height:.75rem;border-radius:50%;background:var(--primary)}header .name{font-weight:650}header .tag{margin-left:auto;color:var(--muted);font-size:.75rem}.card{padding:1.125rem;border:1px solid var(--border);border-radius:.75rem;background:var(--card)}h1{font-size:1.25rem;line-height:1.35}.sub{margin-top:.375rem;color:var(--muted);font-size:.8125rem}.sub b{color:var(--text);word-break:break-all}.badges{display:flex;flex-wrap:wrap;gap:.375rem;margin-top:.75rem}.badge{padding:.1875rem .5rem;border:1px solid var(--border);border-radius:99rem;color:var(--muted);font-size:.6875rem}.badge.ok{color:var(--success)}.badge.warn,.banner.warn{color:var(--warning)}.btn{display:flex;width:100%;justify-content:center;margin-top:1rem;padding:.8125rem 1rem;border-radius:.5rem;background:var(--primary);color:#fff;font-weight:650;text-decoration:none}.btn:active{background:var(--primary-press)}.btn.disabled{opacity:.45;pointer-events:none}.banner{padding:.625rem .75rem;border:1px solid currentColor;border-radius:.5rem;background:var(--card);font-size:.8125rem}.banner.err{color:var(--error)}.hidden{display:none}.sect{margin-bottom:.625rem;color:var(--muted);font-size:.6875rem;font-weight:650;letter-spacing:.08em;text-transform:uppercase}.steps,.notes{display:flex;list-style:none;flex-direction:column;gap:.75rem}.steps li{display:flex;align-items:flex-start;gap:.75rem;font-size:.875rem}.steps .n{display:flex;width:1.5rem;height:1.5rem;flex:none;align-items:center;justify-content:center;border-radius:50%;background:color-mix(in srgb,var(--primary) 14%,transparent);color:var(--primary);font-size:.75rem;font-weight:700}.steps .t,.notes{color:var(--muted);font-size:.8125rem}footer{padding-top:.25rem;color:var(--muted);font-size:.6875rem;text-align:center}
CSS

cat > "${WWW_DIR}/ios.js" <<'JS'
(function(){
  var ua=navigator.userAgent;
  var isIOS=/iPhone|iPad|iPod/.test(ua)||(navigator.platform==="MacIntel"&&navigator.maxTouchPoints>1);
  if(!isIOS) document.getElementById("warn-device").classList.remove("hidden");
  fetch("ios-dot.mobileconfig",{cache:"no-store"}).then(function(r){
    var ct=(r.headers.get("content-type")||"").toLowerCase();
    if(!r.ok||ct.indexOf("application/x-apple-aspen-config")!==0) throw new Error(String(r.status));
  }).catch(function(){
    document.getElementById("warn-missing").classList.remove("hidden");
    document.getElementById("install-btn").classList.add("disabled");
  });
})();
JS

cat > "${WWW_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#6865c6">
<title>5gpn · iPhone 描述文件安装</title>
<link rel="stylesheet" href="ios.css">
<script src="ios.js" defer></script>
</head>
<body>
<div class="wrap">
  <header><span class="mark"></span><span class="name">5gpn 安全 DNS</span><span class="tag">iPhone 描述文件</span></header>
  <div id="warn-device" class="banner warn hidden">此页面用于 iPhone / iPad。请在 iOS 设备上使用 <b>Safari</b> 打开。</div>
  <div id="warn-missing" class="banner err hidden">描述文件暂不可用，请在网关运行 <b>install.sh --ios</b> 后刷新。</div>
  <main class="card">
    <h1>安装蜂窝网络加密 DNS</h1>
    <p class="sub">描述文件 <b>5gpn Cellular DoT</b> 将蜂窝网络 DNS 加密指向 <b>__DOMAIN__</b>。</p>
    <div class="badges"><span class="badge">仅蜂窝网络</span><span class="badge">DoT · RFC 7858</span><span class="badge __SIGNED_CLASS__">__SIGNED_TEXT__</span></div>
    <a class="btn" id="install-btn" href="ios-dot.mobileconfig">下载描述文件</a>
  </main>
  <section class="card">
    <div class="sect">安装步骤</div>
    <ol class="steps">
      <li><span class="n">1</span><span><b>下载</b><br><span class="t">在 Safari 弹窗中选择「允许」。</span></span></li>
      <li><span class="n">2</span><span><b>打开设置</b><br><span class="t">进入「已下载描述文件」或 通用 → VPN 与设备管理。</span></span></li>
      <li><span class="n">3</span><span><b>安装</b><br><span class="t">点击右上角「安装」并确认。</span></span></li>
      <li><span class="n">4</span><span><b>完成</b><br><span class="t">蜂窝数据使用加密 DNS；Wi-Fi 下自动停用。</span></span></li>
    </ol>
  </section>
  <section class="card"><div class="sect">说明</div><ul class="notes"><li>描述文件应显示「已验证」；若显示未验证，请勿安装。</li><li>移除路径：设置 → 通用 → VPN 与设备管理。</li></ul></section>
  <footer>5gpn gateway · public console install</footer>
</div>
</body>
</html>
HTML
landing_tmp="${WWW_DIR}/.index.html.$$"
sed \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s/__SIGNED_CLASS__/${SIGNED_CLASS}/g" \
    -e "s/__SIGNED_TEXT__/${SIGNED_TEXT}/g" \
    "${WWW_DIR}/index.html" > "$landing_tmp"
mv "$landing_tmp" "${WWW_DIR}/index.html"

ok "Wrote ${profile_path}"
ok "Wrote ${WWW_DIR}/index.html"
ok "Wrote ${WWW_DIR}/ios.css + ios.js (strict-CSP assets)"
