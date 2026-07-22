/**
 * Shared mock-API route handler for Playwright tests.
 *
 * Usage: call `setupMockApi(page)` to mock every /api/* route without
 * seeding a token (useful for testing the unauthenticated/login state
 * against live-shaped responses), or `setupMockApiWithToken(page)`
 * (setupMockApi + a pre-seeded valid token) so the app boots straight into
 * the authed shell.
 *
 * Auth convention: every route (checkAuth) requires
 * `Authorization: Bearer valid-token`; anything else — including a missing
 * header — gets a 401, matching the real daemon's control-plane API and the
 * app's clearToken-on-401 behavior (AuthGate/logout flow). There is no
 * dedicated /api/login endpoint in the current contract — the app probes an
 * entered token via a live GET /api/status call (see LoginPage.tsx), so
 * that's the surface a login-submit test should exercise.
 */

import { createHash } from 'node:crypto'
import type { Page, Route } from '@playwright/test'
import type * as T from '../../src/lib/api/types'

export const VALID_TOKEN = 'valid-token'

// ---- Fixture data ----------------------------------------------------------

const STATS_FIXTURE: T.Stats = {
  total: 4200,
  block: 120,
  force_direct: 30,
  force_proxy: 5,
  chnroute_cn: 2800,
  chnroute_foreign: 1200,
  cache_entries: 440,
  china_ok: 2800,
  china_err: 3,
  trust_ok: 1200,
  trust_err: 2,
  cache_hits: 3100,
  cache_misses: 1100,
  china_avg_ms: 8,
  trust_avg_ms: 42,
}

const STATUS_FIXTURE: T.Status = {
  version: 'dev+abc1234',
  uptime_seconds: 3600,
  stats: STATS_FIXTURE,
  dot_domain: 'dot.example.test',
  cert: {
    not_after: '2026-10-01T00:00:00Z',
    days_remaining: 82,
    expired: false,
  },
}

const RESOLVE_TEST_FIXTURE: T.ResolveTestResult = {
  name: 'example.com.',
  verdict: 'trust',
  reason: 'chnroute-foreign',
  probes: [
    {
      server: '223.5.5.5:53',
      group: 'china',
      proto: 'udp',
      ips: ['93.184.216.34'],
      rcode: 'NOERROR',
      duration_ms: 12,
      err: '',
      selected: true,
    },
    {
      server: 'dot.example.com@8.8.8.8:853',
      group: 'trust',
      proto: 'dot',
      ips: ['93.184.216.34'],
      rcode: 'NOERROR',
      duration_ms: 45,
      err: '',
      selected: true,
    },
  ],
  chosen: 'trust',
  chosen_ips: ['93.184.216.34'],
  client_ips: ['93.184.216.34'],
}

const QUERYLOG_FIXTURE: T.QueryLogResponse = {
  retention_seconds: 300,
  entries: [
    {
      time: '2026-07-11T02:00:00Z',
      client: '192.168.1.10',
      name: 'example.com.',
      qtype: 'A',
      verdict: 'proxy',
      reason: 'chnroute-foreign',
      upstream: 'dot.example.com@8.8.8.8:853',
      cache_hit: false,
      rcode: 'NOERROR',
      ips: ['93.184.216.34'],
      duration_ms: 45,
    },
    {
      time: '2026-07-11T02:00:05Z',
      client: '192.168.1.10',
      name: 'baidu.com.',
      qtype: 'A',
      verdict: 'direct',
      reason: 'chnroute-cn',
      upstream: '223.5.5.5:53',
      cache_hit: true,
      rcode: 'NOERROR',
      ips: ['110.242.68.66'],
      duration_ms: 0,
    },
    {
      time: '2026-07-11T02:00:10Z',
      client: '192.168.1.11',
      name: 'ads.tracking.io.',
      qtype: 'A',
      verdict: 'block',
      reason: 'block',
      upstream: '',
      cache_hit: false,
      rcode: 'NXDOMAIN',
      ips: [],
      duration_ms: 0,
    },
    {
      time: '2026-07-11T02:00:15Z',
      client: '192.168.1.12',
      name: 'internal.corp.',
      qtype: 'A',
      verdict: 'direct',
      reason: 'force-direct',
      upstream: '',
      cache_hit: false,
      rcode: 'NOERROR',
      ips: ['10.0.0.5'],
      duration_ms: 1,
    },
    {
      time: '2026-07-11T02:00:20Z',
      client: '192.168.1.11',
      name: 'malware.example.',
      qtype: 'A',
      verdict: 'proxy',
      reason: 'force-proxy',
      upstream: '',
      cache_hit: false,
      rcode: 'NOERROR',
      ips: ['10.0.1.20'],
      duration_ms: 0,
    },
  ],
}

const UPSTREAMS_FIXTURE: T.UpstreamsView = {
  china: ['223.5.5.5', '119.29.29.29'],
  trust: ['dot.example.com@8.8.8.8:853'],
}

const ECS_FIXTURE: T.ECSView = { subnet: '122.96.30.0/24' }

const TGBOT_FIXTURE: T.TGBotView = {
  admins: [123456789],
  token_set: true,
  state: 'healthy',
}

const POLICY_RULES_FIXTURE: T.PolicyRule[] = [
  { id: 'rule-1', order: 0, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'rule-2', order: 1, matcher: { kind: 'domain-keyword', value: 'ads' }, intent: 'block', enabled: true },
]

const MIHOMO_CONFIG_TEXT = `external-controller: 127.0.0.1:9090
secret: e2e-secret
listeners:
  - {name: gateway, type: tunnel, port: 443, target: console.example.test:443}
sniffer: {enable: true, override-destination: true, force-domain: [console.example.test]}
dns: {nameserver: ["udp://127.0.0.1:5354"]}
hosts: {console.example.test: 127.0.0.1, zash.example.test: 127.0.0.2}
rules: ["DOMAIN,console.example.test,DIRECT", "IP-CIDR,10.0.0.1/32,REJECT", "MATCH,DIRECT"]
# e2e speedtest-5060 enabled
# e2e block-quic-443 enabled
`

const INGRESS_MARKER = '# e2e speedtest-5060 enabled\n'
const QUIC_BLOCK_MARKER = '# e2e block-quic-443 enabled\n'

function mihomoRevision(text: string): string {
  return createHash('sha256').update(text).digest('hex')
}

const MIHOMO_CONFIG_FIXTURE: T.MihomoConfig = {
  text: MIHOMO_CONFIG_TEXT,
  revision: mihomoRevision(MIHOMO_CONFIG_TEXT),
  applied_at: '2026-07-16T00:00:00Z',
  controller_reachable: true,
  controller_authenticated: true,
}

function ingressModulesFixture(speedtestEnabled: boolean, blockQUICEnabled: boolean, revision: string): T.IngressModulesView {
  return {
    revision,
    modules: [
      {
        id: 'speedtest-5060',
        port: 5060,
        networks: ['tcp', 'udp'],
        sniffers: ['http', 'tls', 'quic'],
        enabled: speedtestEnabled,
        manageable: true,
      },
      {
        id: 'block-quic-443',
        port: 443,
        networks: ['udp'],
        sniffers: [],
        enabled: blockQUICEnabled,
        manageable: true,
      },
    ],
  }
}

// ---- Auth helper -----------------------------------------------------------

function extractToken(req: { headers(): Record<string, string> }): string | null {
  const auth = req.headers()['authorization'] ?? ''
  if (auth.startsWith('Bearer ')) return auth.slice(7)
  return null
}

function checkAuth(route: Route): boolean {
  const token = extractToken(route.request())
  if (token !== VALID_TOKEN) {
    route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ error: 'unauthorized' }) })
    return false
  }
  return true
}

function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
}

// ---- Main setup ------------------------------------------------------------

/**
 * Intercept all /api/* routes with mock data matching the current contract
 * (web/src/lib/api/types.ts) exactly. Does NOT seed a token itself — pair
 * with `setupMockApiWithToken` (or seed one yourself before navigating) to
 * boot the authed shell.
 */
export async function setupMockApi(page: Page): Promise<void> {
  let ingressEnabled = true
  let blockQUICEnabled = true
  let mihomoText = MIHOMO_CONFIG_TEXT
  let revision = mihomoRevision(mihomoText)
  let interceptRevision = '1000000000000000000000000000000000000000000000000000000000000001'
  let mitmSettings: T.MITMSettingsView = {
    revision: interceptRevision,
    enabled: false,
    http2: true,
    quic_fallback_protection: true,
  }
  let interceptModules: T.InterceptModule[] = [
    {
      id: 'io.5gpn.apple-wloc', extension_version: '1.0.0', name: 'Apple WLOC Location Override', enabled: false, ready: false, reason: 'settings-required',
      capture_hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'], capture_dns: 'trust', script_count: 1,
      settings: [
        { key: 'location', type: 'location', label: 'Target location', required: true, value: { accuracy: 25 } },
        { key: 'failClosed', type: 'boolean', label: 'Block on transformation failure', required: true, value: true },
      ],
      persistent_storage: false, source_url: 'https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml',
      source_digest: 'a'.repeat(64), snapshot_digest: 'a'.repeat(64),
      execution_order: 1, network_origins: [], egress_group_required: false,
    },
    {
      id: 'io.example.response-cleaner', extension_version: '1.0.0', name: 'Response Cleaner', description: 'Synthetic native extension fixture',
      enabled: false, ready: true, capture_hosts: ['api.example.com'], capture_dns: 'china', script_count: 1, settings: [], persistent_storage: false,
      source_url: 'https://example.com/extension.yaml', source_digest: 'b'.repeat(64), snapshot_digest: 'b'.repeat(64), imported_at: '2026-07-18T00:00:00Z',
      execution_order: 2, network_origins: ['https://origin.example.net'], egress_group_required: true, egress_group: 'Proxies',
    },
  ]

  const currentInterceptModules = (): T.InterceptModulesView => ({
    revision: interceptRevision,
    catalog_url: 'https://github.com/moooyo/5gpn-extensions',
    active_capture_hosts: mitmSettings.enabled ? interceptModules.filter((module) => module.enabled).flatMap((module) => module.capture_hosts) : [],
    execution_order: interceptModules.map((module) => module.id),
    available_egress_groups: ['DIRECT', 'Proxies'],
    modules: interceptModules.map((module) => ({
      ...module,
      ready: mitmSettings.enabled && module.reason !== 'settings-required',
      reason: module.reason === 'settings-required' ? 'settings-required' : mitmSettings.enabled ? undefined : 'mitm-disabled',
    })),
  })
  let marketplaceRevision = '2000000000000000000000000000000000000000000000000000000000000001'
  let marketplaceSources: T.MarketplaceSource[] = [{
    id: 'io.5gpn.official', name: '5GPN Extensions', metadata_name: '5GPN Extensions', description: 'Maintained native extensions.', homepage: 'https://github.com/moooyo/5gpn-extensions',
    url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', final_url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', digest: '9'.repeat(64), fetched_at: '2026-07-20T00:00:00Z',
    entries: [{ id: 'io.example.marketplace-cleaner', name: 'Marketplace Response Cleaner', version: '1.0.0', description: 'A marketplace native extension.', tags: ['response'], license: { spdx: 'MIT' }, manifest_url: 'https://extensions.example.test/marketplace-cleaner.yaml', manifest_digest: '7'.repeat(64), capabilities: { capture_host_count: 1, action_count: 1, setting_count: 0, network_origins: [], persistent_storage: false, upstream_mapping_count: 0, egress_group_required: false } }],
  }]
  const currentMarketplaces = (): T.MarketplacesView => ({ revision: marketplaceRevision, recommended_url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', sources: structuredClone(marketplaceSources) })

  const advanceInterceptRevision = (): void => {
    interceptRevision = (BigInt(`0x${interceptRevision}`) + 1n).toString(16).padStart(64, '0')
    mitmSettings.revision = interceptRevision
  }

  const currentMihomoConfig = (): T.MihomoConfig => ({
    ...MIHOMO_CONFIG_FIXTURE,
    text: mihomoText,
    revision,
  })

  const replaceMihomoText = (text: string): void => {
    mihomoText = text
    revision = mihomoRevision(text)
  }

  await page.route('/api/**', async (route) => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()

    if (!checkAuth(route)) return

    // Status
    if (path === '/api/status') return json(route, STATUS_FIXTURE)
    if (path === '/api/mihomo/health' && method === 'GET') {
      return json(route, { version: 'v1.19.28', meta: true } satisfies T.MihomoHealth)
    }
    if (path === '/api/mihomo/log-ticket' && method === 'POST') {
      return json(route, { ticket: 'e2e-log-ticket' } satisfies T.MihomoLogTicket)
    }

    // Resolve test
    if (path === '/api/resolve-test') return json(route, RESOLVE_TEST_FIXTURE)

    // Query log
    if (path === '/api/querylog') return json(route, QUERYLOG_FIXTURE)

    // Upstreams
    if (path === '/api/upstreams') {
      if (method === 'GET' || method === 'PUT') return json(route, UPSTREAMS_FIXTURE)
    }

    // ECS
    if (path === '/api/ecs') {
      if (method === 'GET' || method === 'PUT') return json(route, ECS_FIXTURE)
    }

    // TGBot
    if (path === '/api/tgbot') {
      if (method === 'GET' || method === 'PUT') return json(route, TGBOT_FIXTURE)
    }

    // Unified DNS policy
    if (path === '/api/policy/rules' && method === 'GET') return json(route, POLICY_RULES_FIXTURE)
    if (path === '/api/policy/fallback') {
      if (method === 'GET') return json(route, { policy: 'auto' } satisfies T.PolicyFallback)
      if (method === 'PUT') return json(route, { ok: true })
    }
    if (path === '/api/policy/apply' && method === 'POST') return json(route, { ok: true })

    // Raw operator-owned mihomo config
    if (path === '/api/mihomo/config' && method === 'GET') return json(route, currentMihomoConfig())
    if (path === '/api/mihomo/config' && method === 'PUT') {
      const body = route.request().postDataJSON() as { text?: unknown; revision?: unknown }
      if (body.revision !== revision) return json(route, { error: 'mihomo config revision changed', revision }, 409)
      if (typeof body.text !== 'string') return json(route, { error: 'text is required' }, 400)
      replaceMihomoText(body.text)
      ingressEnabled = mihomoText.includes(INGRESS_MARKER)
      blockQUICEnabled = mihomoText.includes(QUIC_BLOCK_MARKER)
      return json(route, currentMihomoConfig())
    }
    if (path === '/api/mihomo/config/reset' && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: unknown }
      if (body.revision !== revision) return json(route, { error: 'mihomo config revision changed', revision }, 409)
      ingressEnabled = true
      blockQUICEnabled = true
      replaceMihomoText(MIHOMO_CONFIG_TEXT)
      return json(route, currentMihomoConfig())
    }
    if (path === '/api/mihomo/ingress-modules' && method === 'GET') {
      return json(route, ingressModulesFixture(ingressEnabled, blockQUICEnabled, revision))
    }
    const ingressModuleMatch = path.match(/^\/api\/mihomo\/ingress-modules\/(speedtest-5060|block-quic-443)$/)
    if (ingressModuleMatch && method === 'PUT') {
      const body = route.request().postDataJSON() as { enabled?: unknown; revision?: unknown }
      if (body.revision !== revision) {
        return json(route, { error: 'ingress module revision changed', revision }, 409)
      }
      if (typeof body.enabled !== 'boolean') {
        return json(route, { error: 'enabled must be a boolean' }, 400)
      }
      const marker = ingressModuleMatch[1] === 'speedtest-5060' ? INGRESS_MARKER : QUIC_BLOCK_MARKER
      if (ingressModuleMatch[1] === 'speedtest-5060') ingressEnabled = body.enabled
      else blockQUICEnabled = body.enabled
      const withoutMarker = mihomoText.replace(`\n${marker}`, '')
      replaceMihomoText(body.enabled ? `${withoutMarker}\n${marker}` : withoutMarker)
      return json(route, ingressModulesFixture(ingressEnabled, blockQUICEnabled, revision))
    }
    if (path === '/api/interception/settings' && method === 'GET') {
      return json(route, mitmSettings)
    }
    if (path === '/api/interception/settings' && method === 'PUT') {
      const body = route.request().postDataJSON() as T.MITMSettingsUpdate
      if (body.revision !== mitmSettings.revision) return json(route, mitmSettings, 409)
      advanceInterceptRevision()
      mitmSettings = { ...body, revision: interceptRevision }
      return json(route, mitmSettings)
    }
    if (path === '/api/interception/modules' && method === 'GET') {
      return json(route, currentInterceptModules())
    }
    if (path === '/api/interception/marketplaces' && method === 'GET') return json(route, currentMarketplaces())
    if (path === '/api/interception/marketplaces' && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: string; url?: string; name?: string }
      if (body.revision !== marketplaceRevision || !body.url) return json(route, { error: 'marketplace revision changed' }, 409)
      marketplaceSources = [...marketplaceSources, { id: `source-${marketplaceSources.length + 1}`, name: body.name?.trim() || 'Added marketplace', metadata_name: 'Added marketplace', url: body.url, final_url: body.url, digest: '8'.repeat(64), fetched_at: new Date().toISOString(), entries: [] }]
      marketplaceRevision = (BigInt(`0x${marketplaceRevision}`) + 1n).toString(16).padStart(64, '0')
      return json(route, currentMarketplaces(), 201)
    }
    const marketplaceSource = path.match(/^\/api\/interception\/marketplaces\/([^/]+)$/)
    if (marketplaceSource && method === 'DELETE') {
      const body = route.request().postDataJSON() as { revision?: string }
      if (body.revision !== marketplaceRevision) return json(route, { error: 'marketplace revision changed' }, 409)
      marketplaceSources = marketplaceSources.filter((source) => source.id !== decodeURIComponent(marketplaceSource[1]))
      marketplaceRevision = (BigInt(`0x${marketplaceRevision}`) + 1n).toString(16).padStart(64, '0')
      return json(route, currentMarketplaces())
    }
    const marketplaceRefresh = path.match(/^\/api\/interception\/marketplaces\/([^/]+)\/refresh$/)
    if (marketplaceRefresh && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: string }
      const source = marketplaceSources.find((candidate) => candidate.id === decodeURIComponent(marketplaceRefresh[1]))
      if (!source || body.revision !== marketplaceRevision) return json(route, { error: 'marketplace revision changed' }, 409)
      source.fetched_at = new Date().toISOString()
      marketplaceRevision = (BigInt(`0x${marketplaceRevision}`) + 1n).toString(16).padStart(64, '0')
      return json(route, currentMarketplaces())
    }
    const marketplaceEntry = path.match(/^\/api\/interception\/marketplaces\/([^/]+)\/entries\/([^/]+)\/install$/)
    if (marketplaceEntry && method === 'POST') {
      const body = route.request().postDataJSON() as { marketplace_revision?: string; module_revision?: string }
      const entry = marketplaceSources.find((source) => source.id === decodeURIComponent(marketplaceEntry[1]))?.entries.find((candidate) => candidate.id === decodeURIComponent(marketplaceEntry[2]))
      if (!entry || body.marketplace_revision !== marketplaceRevision || body.module_revision !== interceptRevision) return json(route, { error: 'marketplace revision changed' }, 409)
      interceptModules = [...interceptModules, { id: entry.id, extension_version: entry.version, name: entry.name, description: entry.description, enabled: false, ready: true, capture_hosts: ['capture.example.test'], capture_dns: 'trust', script_count: entry.capabilities.action_count, settings: [], persistent_storage: false, source_url: entry.manifest_url, source_digest: entry.manifest_digest, snapshot_digest: entry.manifest_digest, execution_order: interceptModules.length + 1, network_origins: [], egress_group_required: false }]
      advanceInterceptRevision()
      return json(route, currentInterceptModules(), 201)
    }
    if (path === '/api/geocode/cities' && method === 'GET') {
      return json(route, [{ place_id: 1, display_name: '深圳市, 广东省, 中国', lat: '22.544577', lon: '113.94114' }])
    }
    if (path === '/api/interception/modules/import' && method === 'POST') {
      const body = route.request().postDataJSON() as T.InterceptModuleImport
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      interceptModules = [...interceptModules, {
        id: 'io.example.imported', extension_version: '1.0.0', name: 'Imported native extension',
        enabled: false, ready: true, capture_hosts: ['service.example.test'], capture_dns: 'trust', script_count: 1, settings: [], persistent_storage: false, source_url: body.url,
        source_digest: 'c'.repeat(64), snapshot_digest: 'c'.repeat(64), imported_at: '2026-07-18T01:00:00Z',
        execution_order: interceptModules.length + 1, network_origins: [], egress_group_required: false,
      }]
      advanceInterceptRevision()
      return json(route, currentInterceptModules(), 201)
    }
    const updateCheckMatch = path.match(/^\/api\/interception\/modules\/([^/]+)\/update-check$/)
    if (updateCheckMatch && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: string }
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      const module = interceptModules.find((candidate) => candidate.id === decodeURIComponent(updateCheckMatch[1]))
      if (!module) return json(route, { error: 'extension not found' }, 404)
      if (!module.source_url) return json(route, { error: 'only URL-sourced extensions can check for updates' }, 400)
      return json(route, {
        revision: interceptRevision,
        state: 'available',
        candidate: {
          ...module, extension_version: '1.1.0', enabled: false,
          ready: true, reason: undefined, source_digest: 'e'.repeat(64), snapshot_digest: 'f'.repeat(64),
          imported_at: '2026-07-19T00:00:00Z', capture_hosts: [...module.capture_hosts],
        },
      } satisfies T.InterceptModuleUpdateCheck)
    }
    const updateApplyMatch = path.match(/^\/api\/interception\/modules\/([^/]+)\/update-apply$/)
    if (updateApplyMatch && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: string; snapshot_digest?: string }
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      const index = interceptModules.findIndex((candidate) => candidate.id === decodeURIComponent(updateApplyMatch[1]))
      if (index < 0) return json(route, { error: 'extension not found' }, 404)
      if (interceptModules[index].enabled) return json(route, { error: 'disable the extension before applying an update' }, 400)
      if (body.snapshot_digest !== 'f'.repeat(64)) return json(route, { error: 'reviewed candidate changed' }, 409)
      interceptModules[index] = {
        ...interceptModules[index], extension_version: '1.1.0',
        enabled: false, ready: true, reason: undefined,
        source_digest: 'e'.repeat(64), snapshot_digest: body.snapshot_digest, imported_at: '2026-07-19T00:00:00Z',
      }
      advanceInterceptRevision()
      return json(route, currentInterceptModules())
    }
    const moduleMatch = path.match(/^\/api\/interception\/modules\/([^/]+)$/)
    if (path === '/api/interception/modules/reorder' && method === 'PUT') {
      const body = route.request().postDataJSON() as { revision?: string; execution_order?: string[] }
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      if (!Array.isArray(body.execution_order) || body.execution_order.length !== interceptModules.length || new Set(body.execution_order).size !== interceptModules.length) return json(route, { error: 'invalid execution order' }, 400)
      const byID = new Map(interceptModules.map((module) => [module.id, module]))
      if (body.execution_order.some((id) => !byID.has(id))) return json(route, { error: 'invalid execution order' }, 400)
      interceptModules = body.execution_order.map((id, index) => ({ ...byID.get(id)!, execution_order: index + 1 }))
      advanceInterceptRevision()
      return json(route, currentInterceptModules())
    }
    if (moduleMatch && method === 'GET') {
      const id = decodeURIComponent(moduleMatch[1])
      const module = interceptModules.find((candidate) => candidate.id === id)
      if (!module) return json(route, { error: 'interception module not found' }, 404)
      return json(route, {
        id, name: module.name, source_url: module.source_url,
        source_digest: module.source_digest,
        source_body: 'apiVersion: 5gpn.io/v1\nkind: Extension\n',
        scripts: [{ id: 'action', url: 'https://example.com/action.js', digest: 'd'.repeat(64), body: 'function transform(context) { return { response: { body: context.response.body } } }' }],
      } satisfies T.InterceptModuleSnapshot)
    }
    if (moduleMatch && method === 'PUT') {
      const body = route.request().postDataJSON() as T.InterceptModuleUpdate
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      const module = interceptModules.find((candidate) => candidate.id === decodeURIComponent(moduleMatch[1]))
      if (!module) return json(route, { error: 'interception module not found' }, 404)
      if (body.enabled !== undefined) module.enabled = body.enabled
      if (body.settings !== undefined && module.settings) {
        module.settings = module.settings.map((setting) => ({ ...setting, value: body.settings?.[setting.key] }))
        module.reason = undefined
        module.ready = true
      }
      if (body.egress_group !== undefined) module.egress_group = body.egress_group
      if (body.capture_dns !== undefined) module.capture_dns = body.capture_dns
      advanceInterceptRevision()
      return json(route, currentInterceptModules())
    }
    if (moduleMatch && method === 'DELETE') {
      const body = route.request().postDataJSON() as { revision?: string }
      if (body.revision !== interceptRevision) return json(route, { error: 'interception module revision changed' }, 409)
      interceptModules = interceptModules.filter((module) => module.id !== decodeURIComponent(moduleMatch[1]))
      advanceInterceptRevision()
      return json(route, currentInterceptModules())
    }

    // Unhandled — return 404
    return route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not found' }) })
  })
}

/**
 * setupMockApi plus a pre-seeded valid token (added BEFORE navigation via
 * addInitScript), so the app boots straight into the authed shell instead of
 * the login screen.
 */
export async function setupMockApiWithToken(page: Page): Promise<void> {
  await page.addInitScript((token) => {
    localStorage.setItem('5gpn_token', token)
  }, VALID_TOKEN)
  await setupMockApi(page)
}

/**
 * Sets up the authed mock API and navigates to the given path. Convenience
 * wrapper.
 */
export async function gotoWithMock(page: Page, path: string): Promise<void> {
  await setupMockApiWithToken(page)
  await page.goto(path)
}

/**
 * Setup with no token — simulates unauthenticated state: every /api/* call
 * gets a 401 (there is no dedicated login endpoint in the current contract;
 * the app probes an entered token via a live GET /api/status call).
 */
export async function setupMockApiNoAuth(page: Page): Promise<void> {
  await page.route('/api/**', async (route) => {
    return route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ error: 'unauthorized' }) })
  })
}
