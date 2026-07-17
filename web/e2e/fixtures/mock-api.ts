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
`

const INGRESS_MARKER = '# e2e speedtest-5060 enabled\n'

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

function ingressModulesFixture(enabled: boolean, revision: string): T.IngressModulesView {
  return {
    revision,
    modules: [
      {
        id: 'speedtest-5060',
        port: 5060,
        networks: ['tcp', 'udp'],
        sniffers: ['http', 'tls', 'quic'],
        enabled,
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
  let ingressEnabled = false
  let mihomoText = MIHOMO_CONFIG_TEXT
  let revision = mihomoRevision(mihomoText)

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
      return json(route, currentMihomoConfig())
    }
    if (path === '/api/mihomo/config/reset' && method === 'POST') {
      const body = route.request().postDataJSON() as { revision?: unknown }
      if (body.revision !== revision) return json(route, { error: 'mihomo config revision changed', revision }, 409)
      ingressEnabled = false
      replaceMihomoText(MIHOMO_CONFIG_TEXT)
      return json(route, currentMihomoConfig())
    }
    if (path === '/api/mihomo/ingress-modules' && method === 'GET') {
      return json(route, ingressModulesFixture(ingressEnabled, revision))
    }
    if (path === '/api/mihomo/ingress-modules/speedtest-5060' && method === 'PUT') {
      const body = route.request().postDataJSON() as { enabled?: unknown; revision?: unknown }
      if (body.revision !== revision) {
        return json(route, { error: 'ingress module revision changed', revision }, 409)
      }
      if (typeof body.enabled !== 'boolean') {
        return json(route, { error: 'enabled must be a boolean' }, 400)
      }
      ingressEnabled = body.enabled
      const withoutMarker = mihomoText.replace(`\n${INGRESS_MARKER}`, '')
      replaceMihomoText(ingressEnabled ? `${withoutMarker}\n${INGRESS_MARKER}` : withoutMarker)
      return json(route, ingressModulesFixture(ingressEnabled, revision))
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
