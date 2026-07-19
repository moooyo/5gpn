#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
UNIT="$ROOT/etc/systemd/5gpn-intercept.service"
CERT_UNIT="$ROOT/etc/systemd/5gpn-intercept-cert.service"
CERT_PATH="$ROOT/etc/systemd/5gpn-intercept-cert.path"
RUNTIME_PATH="$ROOT/etc/systemd/5gpn-intercept-runtime.path"
TEMPLATE="$ROOT/etc/mihomo/config.yaml.tmpl"
PROFILE="$ROOT/scripts/gen-ios-profile.sh"
MODULE_PAGE="$ROOT/web/src/features/extensions/ExtensionsPage.tsx"
SETUP_GUIDE="$ROOT/web/src/features/setup-guide/SetupGuidePage.tsx"
MODULE_PARSER="$ROOT/cmd/5gpn-dns/intercept_module_parser.go"
rc=0
fail() { echo "FAIL: $1"; rc=1; }

[[ -f "$ROOT/cmd/5gpn-intercept/go.mod" ]] || fail "interception Go module is missing"
grep -Fq 'github.com/quic-go/quic-go v0.60.0' "$ROOT/cmd/5gpn-intercept/go.mod" \
    || fail "quic-go direct dependency is not pinned"
grep -Fq 'github.com/dop251/goja v0.0.0-20260701091749-b07b74453ea9' "$ROOT/cmd/5gpn-intercept/go.mod" \
    || fail "goja direct dependency is not pinned"
grep -Fq 'github.com/dlclark/regexp2/v2 v2.2.1' "$ROOT/cmd/5gpn-intercept/go.mod" \
    || fail "regexp2 timeout dependency is not pinned"
grep -Fq 'github.com/andybalholm/brotli v1.2.2' "$ROOT/cmd/5gpn-intercept/go.mod" \
    || fail "Brotli decoding dependency is not pinned"
find "$ROOT" -path "$ROOT/web/node_modules" -prune -o -type f -name '*.py' -print -quit | grep -q . \
    && fail "Python source was introduced"

grep -Fxq '# 5gpn-unit-id: 5gpn-intercept.service:v1' "$UNIT" || fail "interception unit ownership marker missing"
grep -Fxq 'User=gpn-intercept' "$UNIT" || fail "interception unit lacks its dedicated account"
grep -Fxq 'CapabilityBoundingSet=' "$UNIT" || fail "interception unit has capabilities"
grep -Fxq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$UNIT" || fail "interception unit address families are too broad"
grep -Fxq 'StateDirectory=5gpn-intercept' "$UNIT" || fail "module persistent store has no private state directory"
grep -Fxq 'Requires=5gpn-intercept-cert.service' "$UNIT" || fail "sidecar startup does not gate on certificate publication"
grep -Fxq 'ExecCondition=/opt/5gpn/bin/5gpn-intercept --config /etc/5gpn/intercept/config.json --check-enabled' "$UNIT" \
    || fail "sidecar startup is not gated by the MITM master setting"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/intercept-ca' "$UNIT" || fail "interception unit can read the CA signing key"
grep -Fxq '# 5gpn-unit-id: 5gpn-intercept-cert.service:v1' "$CERT_UNIT" || fail "certificate publisher ownership marker missing"
grep -Fxq 'ExecStart=/opt/5gpn/scripts/intercept-cert-renew.sh' "$CERT_UNIT" || fail "certificate publisher helper is missing"
grep -Fxq 'Group=gpn-intercept' "$CERT_UNIT" || fail "capability-free certificate publisher lacks the runtime file group"
grep -Fxq 'ReadOnlyPaths=/etc/5gpn/intercept-ca /opt/5gpn/bin/5gpn-intercept /opt/5gpn/scripts/intercept-cert-renew.sh' "$CERT_UNIT" \
    || fail "certificate publisher does not scope root-key access"
grep -Fxq 'PathChanged=/etc/5gpn/intercept/config.json' "$CERT_PATH" || fail "module certificate watcher is missing"
grep -Fxq '# 5gpn-unit-id: 5gpn-intercept-runtime.path:v1' "$RUNTIME_PATH" || fail "MITM runtime watcher ownership marker is missing"
grep -Fxq 'PathChanged=/etc/5gpn/intercept/config.json' "$RUNTIME_PATH" || fail "MITM runtime watcher is missing"
grep -Fxq 'Unit=5gpn-intercept.service' "$RUNTIME_PATH" || fail "MITM runtime watcher does not start the sidecar"

grep -Fq 'intercept_asset="5gpn-intercept-linux-amd64"' "$INSTALL" || fail "interception release asset is not staged"
grep -Fq 'verify_sha256 "$ARTIFACT_STAGE/5gpn-intercept"' "$INSTALL" || fail "interception release asset is not checksum-verified"
grep -Fq 'ensure_service_account "$INTERCEPT_SERVICE_USER"' "$INSTALL" || fail "interception service account is not installed"
grep -Fq 'ensure_intercept_certificates' "$INSTALL" || fail "interception certificate lifecycle is missing"
grep -Fq '"version": 4' "$INSTALL" || fail "current interception config schema is not installed"
grep -Fq '"execution_order": []' "$INSTALL" || fail "current interception config has no explicit execution order"
grep -Fq '"quic_fallback_protection": true' "$INSTALL" || fail "QUIC fallback protection is not configured by default"
grep -Fq 'systemctl enable --now 5gpn-intercept-runtime.path' "$INSTALL" || fail "MITM runtime watcher is not enabled"
grep -Fq 'intercept-cert-renew.sh" --installer-lock-held' "$INSTALL" || fail "installer does not reuse its held certificate lock"
grep -Fq '/proc/$$/fd/8' "$ROOT/scripts/intercept-cert-renew.sh" || fail "interception helper does not validate the inherited installer lock"
grep -Fq -- '--print-certificate-request' "$ROOT/scripts/intercept-cert-renew.sh" || fail "certificate helper does not consume one atomic host-set request"
grep -Fq 'if [[ ! -s "$stage/hosts" ]]' "$ROOT/scripts/intercept-cert-renew.sh" || fail "certificate helper does not accept a fresh zero-extension host set"
grep -Fq 'ExecStart=/opt/5gpn/scripts/intercept-cert-renew.sh' "$INSTALL" || fail "interception leaf renewal is not scheduled"
grep -Fq 'INTERCEPT_CA_MARKER_VALUE="5gpn-intercept-ca-v1"' "$INSTALL" || fail "interception CA ownership marker is missing"
grep -Fq 'INTERCEPT_STATE_MARKER_VALUE="5gpn-intercept-state-v1"' "$INSTALL" || fail "interception state ownership marker is missing"
grep -Fq 'remove_fixed_owned_dir "$INTERCEPT_STATE_DIR"' "$INSTALL" || fail "purge does not remove marked module persistent state"

grep -Fq 'name: intercept-egress' "$TEMPLATE" || fail "mihomo interception egress listener is missing"
grep -Fq 'listen: 127.0.0.1' "$TEMPLATE" || fail "interception egress listener is not loopback"
grep -Fq 'name: MODULE-INTERCEPT' "$TEMPLATE" || fail "mihomo extension SOCKS node is missing"
grep -Fq 'type: socks5' "$TEMPLATE" || fail "module node is not SOCKS5"
grep -Fq 'udp: true' "$TEMPLATE" || fail "module node does not carry QUIC"
grep -Fq 'IN-NAME,intercept-egress,REJECT' "$TEMPLATE" || fail "interception fail-closed egress guard is missing"
grep -Fq 'After=network-online.target 5gpn-intercept.service' "$ROOT/etc/systemd/mihomo.service" \
    || fail "mihomo is not ordered after the interception sidecar"
grep -Eq '^  - AND,.*MODULE-INTERCEPT' "$TEMPLATE" \
    && fail "interception extensions must remain disabled in the seed"
grep -Fq 'gs-loc.apple.com' "$ROOT/etc/proxy-domains.txt" \
    && fail "disabled WLOC hosts must not remain in the static proxy policy"

grep -Fq 'ios-intercept-ca.mobileconfig' "$PROFILE" || fail "interception CA profile generation is missing"
grep -Fq 'com.apple.security.root' "$PROFILE" || fail "shared interception profile is not a root-certificate payload"
grep -Fq "INTERCEPT_CA_PROFILE_PATH = '/ios/ios-intercept-ca.mobileconfig'" "$SETUP_GUIDE" \
    || fail "Setup Guide does not own the shared interception CA profile"
grep -Fq 'data-testid="intercept-ca-guide"' "$SETUP_GUIDE" \
    || fail "Setup Guide lacks the shared interception trust guide"
grep -Fq "'/setup-guide'" "$MODULE_PAGE" \
    || fail "Extensions page does not direct operators to the shared trust guide"
grep -Fq "'/extensions/hosts'" "$MODULE_PAGE" \
    || fail "Extensions page does not expose the capture-host audit"
grep -Fq 'ios-intercept-ca.mobileconfig' "$MODULE_PAGE" \
    && fail "Modules page still owns a direct CA profile download"
grep -Fq 'nativeExtensionAPIVersion = "5gpn.io/v1"' "$MODULE_PARSER" \
    || fail "native extension manifest version is missing"
grep -Fq 'decoder.KnownFields(true)' "$MODULE_PARSER" \
    || fail "native extension manifest does not reject unknown fields"
grep -Fq 'rejectUnsafeYAML' "$MODULE_PARSER" \
    || fail "native extension manifest does not reject aliases, anchors, and merges"
grep -Fq 'servePlainHTTPConnection' "$ROOT/cmd/5gpn-intercept/proxy.go" \
    || fail "plain HTTP module interception is missing"
grep -Fq 'BodyMode' "$ROOT/cmd/5gpn-intercept/module_runtime.go" \
    || fail "binary body script support is missing"
grep -Fq 'brotli.NewReader' "$ROOT/cmd/5gpn-intercept/content_encoding.go" \
    || fail "bounded Brotli decoding is missing"
grep -Fq 'transform(context)' "$ROOT/cmd/5gpn-intercept/module_runtime.go" \
    || fail "native transform entry point is missing"
grep -Fq 'moduleOwnsHost' "$ROOT/cmd/5gpn-intercept/module_runtime.go" \
    || fail "native actions are not scoped to their extension capture hosts"
grep -Fq 'contextObject["network"]' "$ROOT/cmd/5gpn-intercept/module_runtime.go" \
    || fail "declared origin permissions do not expose the bounded network capability"
grep -Fq 'dialSOCKS5TCP' "$ROOT/cmd/5gpn-intercept/module_network.go" \
    || fail "extension network requests do not return through authenticated mihomo SOCKS5"
grep -Fq 'ExecutionOrder' "$ROOT/cmd/5gpn-intercept/config.go" \
    || fail "sidecar config has no explicit extension execution order"
grep -Fq 'NetworkOrigins' "$MODULE_PARSER" \
    || fail "native manifest parser does not snapshot exact network origins"
grep -Fq 'EgressGroupRequired' "$MODULE_PARSER" \
    || fail "native manifest parser does not support operator egress requirements"
grep -Fq 'type: location' "$ROOT/extensions/apple-wloc/extension.yaml" \
    || fail "online WLOC extension does not use the generic location setting"
grep -Fq 'source: ./wloc.js' "$ROOT/extensions/apple-wloc/extension.yaml" \
    || fail "online WLOC extension script is missing"
grep -Fq 'fetch_profile' "$ROOT/web/src/lib/api/types.ts" \
    && fail "module import API still exposes a fetch-header choice"
retired_client="$(printf '%s%s' 'lo' 'on')"
grep -Rni "$retired_client" \
    "$ROOT/README.md" "$ROOT/docs/architecture.md" "$ROOT/cmd/5gpn-dns" \
    "$ROOT/cmd/5gpn-intercept" "$ROOT/web/src" "$ROOT/web/e2e" 2>/dev/null | grep -q . \
    && fail "retired third-party plugin compatibility is still present"
grep -RniE 'builtin-wloc|MODULE-MITM' \
    "$ROOT/README.md" "$ROOT/docs/architecture.md" "$ROOT/cmd" "$ROOT/web/src" 2>/dev/null | grep -q . \
    && fail "retired built-in interception identifiers are still present"

exit "$rc"
