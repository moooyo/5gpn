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
  ],
}

export const wlocIntercept: T.WLOCInterceptView = {
  revision: '1000000000000000000000000000000000000000000000000000000000000001',
  enabled: false,
  longitude: null,
  latitude: null,
  accuracy: 25,
  fail_closed: true,
  max_body_bytes: 8388608,
  hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
}

export const interceptModules: T.InterceptModulesView = {
  revision: wlocIntercept.revision,
  catalog_url: 'https://hub.kelee.one/',
  active_hosts: [],
  modules: [
    {
      id: 'builtin-wloc',
      name: 'Apple WLOC response rewriting',
      description: 'Built-in bounded protobuf transformation for Apple location responses.',
      enabled: false,
      ready: true,
      compatibility: 'full',
      partial_allowed: false,
      hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
      script_count: 1,
      rewrite_count: 0,
      source_digest: 'a'.repeat(64),
    },
    {
      id: 'mod-1234567890abcdef',
      name: 'Synthetic response cleaner',
      description: 'A local test snapshot using the Loon response-script shape.',
      enabled: false,
      ready: true,
      compatibility: 'full',
      partial_allowed: false,
      hosts: ['api.example.test'],
      script_count: 1,
      rewrite_count: 0,
      source_url: 'https://modules.example.test/clean.lpx',
      source_digest: 'b'.repeat(64),
      imported_at: '2026-07-18T00:00:00Z',
      argument: '',
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
