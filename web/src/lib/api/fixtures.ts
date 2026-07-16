/*
 * Typed fixtures served by mock.ts when VITE_API_MOCK=1. They mirror only the
 * current ordered DNS-policy and operator-owned mihomo-config surfaces.
 */
import type * as T from './types'

// ---- mihomo config editor (UP-4 §4) ----------------------------------------
// A minimal-but-realistic seed containing all seven infrastructure invariants
// (external-controller on the loopback controller; a :443 tunnel inbound;
// the :5354 DNS broker; console/zash/profile SNI splits; the gateway-self anti-loop
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
  - name: sniproxy
    type: tunnel
    port: 443
    network: [tcp, udp]
    target: 127.0.0.1:443
hosts:
  console.5gpn.test: 127.0.0.1
  zash.5gpn.test: 127.0.0.2
  profile.5gpn.test: 127.0.0.1
proxies: []
proxy-providers: {}
proxy-groups:
  - name: Proxies
    type: select
    proxies: [DIRECT]
rules:
  - DOMAIN,profile.5gpn.test,DIRECT
  - DOMAIN,console.5gpn.test,DIRECT
  - DOMAIN,zash.5gpn.test,DIRECT
  - IP-CIDR,10.0.1.20/32,REJECT-DROP
  - MATCH,Proxies
`

export const mihomoConfig: T.MihomoConfig = {
  text: mihomoConfigDefaultText,
  applied_at: '2026-07-14T00:00:00Z',
  controller_reachable: true,
  controller_authenticated: true,
}

// ---- Unified policy rules (UP-1; mirrors cmd/5gpn-dns/policy_rules.go's
// JSON shapes — see types.ts's PolicyRule/PolicyMatcher/PolicyFallback for the
// field-by-field mapping). `policyFallback` is a `const` object mutated
// IN PLACE (mock.ts's putPolicyFallback does `Object.assign(...)`, never a
// rebind) — mirrors how the write mocks above mutate the fixture arrays in
// place rather than reassigning them. A namespace import's (`import * as
// fixtures`) bindings are read-only ES-module live bindings, so `fixtures.x =
// value` from a consuming module is rejected by both the spec and tsc
// (TS2540) even when the exporting module declared `let` — only in-place
// mutation of the referenced object/array works across that boundary.
//
// UP-4 made the policy binary: no rule carries a `selector` and the fallback
// carries no `default_selector` — a `proxy` rule (prule-3) is a bare intent.
export const policyRules: T.PolicyRule[] = [
  { id: 'prule-1', order: 0, matcher: { kind: 'subscription', value: 'https://example.test/blocklist.txt', format: 'plain', interval: '24h0m0s' }, intent: 'block', enabled: true },
  { id: 'prule-2', order: 1, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'prule-3', order: 2, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: true },
  { id: 'prule-4', order: 3, matcher: { kind: 'domain-keyword', value: 'ads' }, intent: 'block', enabled: false },
]
export const policyFallback: T.PolicyFallback = { policy: 'auto' }
