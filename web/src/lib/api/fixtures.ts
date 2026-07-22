/*
 * Typed fixtures served by mock.ts when VITE_API_MOCK=1. They mirror only the
 * current ordered DNS-policy and operator-owned mihomo-config surfaces.
 */
import type * as T from './types'

// ---- mihomo config editor -------------------------------------------------
// A minimal-but-realistic seed containing all seven infrastructure invariants
// (external-controller on the loopback controller; a :443 tunnel inbound;
// the :5354 DNS broker; public console and allowlisted zash SNI splits; the gateway-self anti-loop
// guard) so the default mock state is a VALID config the "current" and
// "default" fixtures both start from.
export const mihomoConfigDefaultText = `mixed-port: 7890
external-controller: 127.0.0.1:9090
secret: "REPLACE_WITH_STRONG_SECRET"
dns:
  enable: true
  nameserver:
    - udp://127.0.0.1:5354
listeners:
  - name: gateway
    type: tunnel
    port: 443
    network: [tcp, udp]
    target: console.5gpn.test:443
sniffer:
  enable: true
  override-destination: true
  force-domain: [console.5gpn.test]
hosts:
  console.5gpn.test: 127.0.0.1
  zash.5gpn.test: 127.0.0.2
proxies: []
proxy-providers: {}
proxy-groups:
  - name: Proxies
    type: select
    proxies: [DIRECT]
rules:
  - DOMAIN,console.5gpn.test,DIRECT
  - DOMAIN,zash.5gpn.test,DIRECT
  - IP-CIDR,10.0.1.20/32,REJECT
  - MATCH,Proxies
`

export const mihomoConfig: T.MihomoConfig = {
  text: mihomoConfigDefaultText,
  revision: '0000000000000000000000000000000000000000000000000000000000000001',
  applied_at: '2026-07-14T00:00:00Z',
  controller_reachable: true,
  controller_authenticated: true,
}

// ---- ingress modules -----------------------------------------------------
export const ingressModules: T.IngressModulesView = {
  revision: '0000000000000000000000000000000000000000000000000000000000000001',
  modules: [
    {
      id: 'speedtest-5060',
      port: 5060,
      networks: ['tcp', 'udp'],
      sniffers: ['http', 'tls', 'quic'],
      enabled: true,
      manageable: true,
    },
    {
      id: 'block-quic-443',
      port: 443,
      networks: ['udp'],
      sniffers: [],
      enabled: true,
      manageable: true,
    },
  ],
}

export const mitmSettings: T.MITMSettingsView = {
  revision: '1000000000000000000000000000000000000000000000000000000000000001',
  enabled: false,
  http2: true,
  quic_fallback_protection: true,
}

export const interceptModules: T.InterceptModulesView = {
  revision: mitmSettings.revision,
  catalog_url: 'https://github.com/moooyo/5gpn-extensions',
  active_capture_hosts: [],
  execution_order: ['io.5gpn.apple-wloc', 'io.example.response-cleaner'],
  available_egress_groups: ['DIRECT', 'Proxies'],
  modules: [
    {
      id: 'io.5gpn.apple-wloc',
      extension_version: '1.0.0',
      name: 'Apple WLOC Location Override',
      description: 'Native online extension for Apple location responses.',
      enabled: false,
      ready: false,
      reason: 'mitm-disabled',
      capture_hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
      capture_dns: 'trust',
      script_count: 1,
      settings: [
        { key: 'location', type: 'location', label: 'Target location', required: true, default: { accuracy: 25 }, value: { accuracy: 25 } },
        { key: 'failClosed', type: 'boolean', label: 'Block on transformation failure', required: true, default: true, value: true },
      ],
      persistent_storage: false,
      source_url: 'https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml',
      source_digest: 'a'.repeat(64),
      snapshot_digest: 'a'.repeat(64),
      execution_order: 1,
      network_origins: [],
      egress_group_required: false,
    },
    {
      id: 'io.example.response-cleaner',
      extension_version: '1.0.0',
      name: 'Synthetic response cleaner',
      description: 'A native response action fixture.',
      enabled: false,
      ready: false,
      reason: 'mitm-disabled',
      capture_hosts: ['api.example.test'],
      capture_dns: 'china',
      script_count: 1,
      settings: [],
      persistent_storage: false,
      source_url: 'https://extensions.example.test/clean.yaml',
      source_digest: 'b'.repeat(64),
      snapshot_digest: 'b'.repeat(64),
      imported_at: '2026-07-18T00:00:00Z',
      execution_order: 2,
      network_origins: ['https://origin.example.net'],
      egress_group_required: true,
      egress_group: 'Proxies',
    },
  ],
}

// ---- Unified policy rules (mirrors cmd/5gpn-dns/policy_rules.go's
// JSON shapes — see types.ts's PolicyRule/PolicyMatcher/PolicyFallback for the
// field-by-field mapping). `policyFallback` is a `const` object mutated
// IN PLACE (mock.ts's putPolicyFallback does `Object.assign(...)`, never a
// rebind) — mirrors how the write mocks above mutate the fixture arrays in
// place rather than reassigning them. A namespace import's (`import * as
// fixtures`) bindings are read-only ES-module live bindings, so `fixtures.x =
// value` from a consuming module is rejected by both the spec and tsc
// (TS2540) even when the exporting module declared `let` — only in-place
// mutation of the referenced object/array works across that boundary.
export const policyRules: T.PolicyRule[] = [
  { id: 'prule-1', order: 0, matcher: { kind: 'subscription', value: 'https://example.test/blocklist.txt', format: 'plain', interval: '24h0m0s' }, intent: 'block', enabled: true },
  { id: 'prule-2', order: 1, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'prule-3', order: 2, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: true },
  { id: 'prule-4', order: 3, matcher: { kind: 'domain-keyword', value: 'ads' }, intent: 'block', enabled: false },
]
export const policyFallback: T.PolicyFallback = { policy: 'auto' }
