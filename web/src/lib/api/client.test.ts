import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const jsonResp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

beforeEach(() => {
  localStorage.clear()
  vi.unstubAllEnvs()
  vi.resetModules()
})

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllEnvs()
})

describe('api client — live methods', () => {
  it('getStatus calls fetch with /api/status', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn().mockResolvedValue(jsonResp(200, { version: 'x', uptime_seconds: 1, stats: {} }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    await api.getStatus()
    expect(f).toHaveBeenCalledTimes(1)
    expect(f.mock.calls[0][0]).toBe('/api/status')
  })

  it('uses bearer-protected mihomo health, log-ticket, and zashboard handoff endpoints', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn()
      .mockResolvedValueOnce(jsonResp(200, { version: 'v1.19.28', meta: true }))
      .mockResolvedValueOnce(jsonResp(200, { ticket: 'once' }))
      .mockResolvedValueOnce(jsonResp(200, { url: 'https://zash.example/handoff?ticket=once', expires_in_seconds: 30 }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await expect(api.getMihomoHealth()).resolves.toMatchObject({ version: 'v1.19.28' })
    await expect(api.createMihomoLogTicket()).resolves.toEqual({ ticket: 'once' })
    await expect(api.createZashboardHandoff()).resolves.toMatchObject({ expires_in_seconds: 30 })
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/health')
    expect(f.mock.calls[1][0]).toBe('/api/mihomo/log-ticket')
    expect(f.mock.calls[1][1].method).toBe('POST')
    expect(f.mock.calls[2][0]).toBe('/api/mihomo/zashboard-handoff')
    expect(f.mock.calls[2][1].method).toBe('POST')
  })
})

describe('api client — mihomo config', () => {
  it('getMihomoConfig GETs /api/mihomo/config and returns the config', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const cfg = { text: 'external-controller: 127.0.0.1:9090\n', revision: 'r1', applied_at: '2026-07-14T00:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, cfg))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.getMihomoConfig()
    expect(f).toHaveBeenCalledTimes(1)
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config')
    expect(result).toEqual(cfg)
  })

  it('putMihomoConfig PUTs {text,revision} to /api/mihomo/config', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const text = 'external-controller: 127.0.0.1:9090\n'
    const updated = { text, revision: 'r2', applied_at: '2026-07-14T01:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, updated))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.putMihomoConfig(text, 'r1')
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config')
    expect(f.mock.calls[0][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual({ text, revision: 'r1' })
    expect(result).toEqual(updated)
  })

  it('putMihomoConfig rejects with ApiError(400, "missing required infrastructure: controller") on a live 400', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn().mockImplementation(async () => jsonResp(400, { error: 'missing required infrastructure: controller' }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const { ApiError } = await import('./http')
    let caught: unknown
    try {
      await api.putMihomoConfig('no controller line', 'r1')
    } catch (err) {
      caught = err
    }
    expect(caught).toBeInstanceOf(ApiError)
    expect(caught).toMatchObject({ status: 400, message: 'missing required infrastructure: controller' })
  })

  it('resetMihomoConfig POSTs to /api/mihomo/config/reset', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const reset = { text: 'seed text', revision: 'r2', applied_at: '2026-07-14T02:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, reset))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.resetMihomoConfig('r1')
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config/reset')
    expect(f.mock.calls[0][1].method).toBe('POST')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual({ revision: 'r1' })
    expect(result).toEqual(reset)
  })
})

describe('api client — ingress modules', () => {
  it('gets modules and updates one module with enabled and revision', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const view = {
      revision: 'r1',
      modules: [
        { id: 'speedtest-5060', port: 5060, networks: ['tcp', 'udp'], sniffers: ['http', 'tls', 'quic'], enabled: false, manageable: true },
        { id: 'block-quic-443', port: 443, networks: ['udp'], sniffers: [], enabled: true, manageable: true },
      ],
    }
    const f = vi.fn().mockResolvedValueOnce(jsonResp(200, view)).mockResolvedValueOnce(jsonResp(200, view))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await expect(api.getIngressModules()).resolves.toEqual(view)
    await expect(api.putIngressModule('speedtest-5060', true, 'r1')).resolves.toEqual(view)
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/ingress-modules')
    expect(f.mock.calls[1][0]).toBe('/api/mihomo/ingress-modules/speedtest-5060')
    expect(f.mock.calls[1][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[1][1].body as string)).toEqual({ enabled: true, revision: 'r1' })
  })
})

describe('api client — MITM runtime settings', () => {
  it('gets and updates the master, HTTP/2, and QUIC fallback settings', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const view = { revision: 'r1', enabled: false, http2: true, quic_fallback_protection: true }
    const update = { ...view, enabled: true, http2: false }
    const f = vi.fn().mockResolvedValueOnce(jsonResp(200, view)).mockResolvedValueOnce(jsonResp(200, update))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await expect(api.getMITMSettings()).resolves.toEqual(view)
    await expect(api.putMITMSettings(update)).resolves.toEqual(update)
    expect(f.mock.calls[0][0]).toBe('/api/interception/settings')
    expect(f.mock.calls[1][0]).toBe('/api/interception/settings')
    expect(f.mock.calls[1][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[1][1].body as string)).toEqual(update)
  })
})

describe('api client — interception modules', () => {
  it('maps list, snapshot, import, update, reorder, and delete to the authenticated module API', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const view = { revision: 'r1', catalog_url: 'https://github.com/moooyo/5gpn-extensions', active_capture_hosts: [], modules: [] }
    const snapshot = { id: 'io.example.fixture', name: 'Fixture', source_digest: 'a'.repeat(64), source_body: 'apiVersion: 5gpn.io/v1', scripts: [] }
    const f = vi.fn()
      .mockResolvedValueOnce(jsonResp(200, view))
      .mockResolvedValueOnce(jsonResp(200, snapshot))
      .mockResolvedValueOnce(jsonResp(201, view))
      .mockResolvedValueOnce(jsonResp(200, view))
      .mockResolvedValueOnce(jsonResp(200, view))
      .mockResolvedValueOnce(jsonResp(200, view))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const request = { revision: 'r1', url: 'https://example.com/extension.yaml' }

    await api.getInterceptModules()
    await api.getInterceptModuleSnapshot('io.example.fixture')
    await api.importInterceptModule(request)
    await api.putInterceptModule('io.example.fixture', { revision: 'r1', settings: { mode: 'clean' }, capture_dns: 'china' })
    await api.reorderInterceptModules('r1', ['io.example.fixture'])
    await api.deleteInterceptModule('io.example.fixture', 'r1')

    expect(f.mock.calls.map((call) => call[0])).toEqual([
      '/api/interception/modules',
      '/api/interception/modules/io.example.fixture',
      '/api/interception/modules/import',
      '/api/interception/modules/io.example.fixture',
      '/api/interception/modules/reorder',
      '/api/interception/modules/io.example.fixture',
    ])
    expect(f.mock.calls[2][1].method).toBe('POST')
    expect(JSON.parse(f.mock.calls[2][1].body as string)).toEqual(request)
    expect(f.mock.calls[3][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[3][1].body as string)).toEqual({ revision: 'r1', settings: { mode: 'clean' }, capture_dns: 'china' })
    expect(f.mock.calls[4][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[4][1].body as string)).toEqual({ revision: 'r1', execution_order: ['io.example.fixture'] })
    expect(f.mock.calls[5][1].method).toBe('DELETE')
  })

  it('checks and applies an immutable URL extension update through explicit endpoints', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const check = { revision: 'r1', state: 'available', candidate: { id: 'io.example.fixture', source_digest: 'e'.repeat(64), snapshot_digest: 'f'.repeat(64) } }
    const view = { revision: 'r2', catalog_url: '', active_capture_hosts: [], modules: [] }
    const f = vi.fn().mockResolvedValueOnce(jsonResp(200, check)).mockResolvedValueOnce(jsonResp(200, view))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await expect(api.checkInterceptModuleUpdate('io.example.fixture', 'r1')).resolves.toEqual(check)
    await expect(api.applyInterceptModuleUpdate('io.example.fixture', 'r1', 'f'.repeat(64))).resolves.toEqual(view)
    expect(f.mock.calls[0][0]).toBe('/api/interception/modules/io.example.fixture/update-check')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual({ revision: 'r1' })
    expect(f.mock.calls[1][0]).toBe('/api/interception/modules/io.example.fixture/update-apply')
    expect(JSON.parse(f.mock.calls[1][1].body as string)).toEqual({ revision: 'r1', snapshot_digest: 'f'.repeat(64) })
  })

  it('uses the authenticated same-origin city-search projection', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const results = [{ place_id: 1, display_name: 'Shenzhen', lat: '22.544577', lon: '113.94114' }]
    const f = vi.fn().mockResolvedValueOnce(jsonResp(200, results))
    vi.stubGlobal('fetch', f)
    localStorage.setItem('5gpn_token', 'valid-token')
    const { api } = await import('./client')

    await expect(api.searchCities('深圳 南山', 'zh-CN')).resolves.toEqual(results)
    expect(f.mock.calls[0][0]).toBe('/api/geocode/cities?q=%E6%B7%B1%E5%9C%B3%20%E5%8D%97%E5%B1%B1&lang=zh-CN')
    expect(f.mock.calls[0][1].headers.Authorization).toBe('Bearer valid-token')
  })
})

describe('api client — marketplaces', () => {
  it('maps marketplace ledger and immutable entry installation endpoints', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const markets = { revision: 'm1', sources: [] }
    const modules = { revision: 'r2', catalog_url: '', active_capture_hosts: [], execution_order: [], available_egress_groups: [], modules: [] }
    const f = vi.fn()
      .mockResolvedValueOnce(jsonResp(200, markets))
      .mockResolvedValueOnce(jsonResp(201, markets))
      .mockResolvedValueOnce(jsonResp(200, markets))
      .mockResolvedValueOnce(jsonResp(200, markets))
      .mockResolvedValueOnce(jsonResp(201, modules))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await api.getMarketplaces()
    await api.addMarketplace('m1', 'https://example.test/marketplace.json', 'Community mirror')
    await api.refreshMarketplace('official', 'm1')
    await api.deleteMarketplace('official', 'm1')
    await api.installMarketplaceEntry('official', 'io.example.cleaner', 'm1', 'r1')

    expect(f.mock.calls.map((call) => call[0])).toEqual([
      '/api/interception/marketplaces',
      '/api/interception/marketplaces',
      '/api/interception/marketplaces/official/refresh',
      '/api/interception/marketplaces/official',
      '/api/interception/marketplaces/official/entries/io.example.cleaner/install',
    ])
    expect(JSON.parse(f.mock.calls[1][1].body as string)).toEqual({ revision: 'm1', url: 'https://example.test/marketplace.json', name: 'Community mirror' })
    expect(JSON.parse(f.mock.calls[2][1].body as string)).toEqual({ revision: 'm1' })
    expect(f.mock.calls[3][1].method).toBe('DELETE')
    expect(JSON.parse(f.mock.calls[4][1].body as string)).toEqual({ marketplace_revision: 'm1', module_revision: 'r1' })
  })
})

describe('api client — mihomo config mock ON (VITE_API_MOCK=1)', () => {
  it('getMihomoConfig resolves the fixture', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const cfg = await api.getMihomoConfig()
    expect(cfg.text).toContain('external-controller:')
    expect(cfg.controller_reachable).toBe(true)
    expect(cfg.controller_authenticated).toBe(true)
    expect(cfg.revision).toBeTruthy()
  })

  it('putMihomoConfig round-trips a valid edit', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const before = await api.getMihomoConfig()
    const nextText = before.text + '\n# a harmless edit\n'
    const updated = await api.putMihomoConfig(nextText, before.revision)
    expect(updated.text).toBe(nextText)
    expect(await api.getMihomoConfig()).toEqual(updated)
  })

  it('putMihomoConfig rejects a config missing the controller invariant with ApiError 400', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const { ApiError } = await import('./http')
    const before = await api.getMihomoConfig()
    await expect(api.putMihomoConfig('proxies: []\n', before.revision)).rejects.toMatchObject({
      status: 400,
      message: 'missing required infrastructure: controller',
    })
    await expect(api.putMihomoConfig('proxies: []\n', before.revision)).rejects.toBeInstanceOf(ApiError)
  })

  it('resetMihomoConfig restores the seed after an edit', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const before = await api.getMihomoConfig()
    const seed = before.text
    const edited = await api.putMihomoConfig(seed + '\n# edited\n', before.revision)
    expect((await api.getMihomoConfig()).text).not.toBe(seed)
    const reset = await api.resetMihomoConfig(edited.revision)
    expect(reset.text).toBe(seed)
    expect((await api.getMihomoConfig()).text).toBe(seed)
  })
})

describe('api client — ingress modules mock ON (VITE_API_MOCK=1)', () => {
  it('round-trips an enabled module and advances its revision', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const before = await api.getIngressModules()
    const updated = await api.putIngressModule('speedtest-5060', true, before.revision)
    expect(updated.revision).not.toBe(before.revision)
    expect(updated.modules[0]).toMatchObject({ id: 'speedtest-5060', enabled: true })
  })

  it('rejects a stale revision', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    await expect(api.putIngressModule('speedtest-5060', true, 'stale')).rejects.toMatchObject({ status: 409 })
  })
})

describe('api client — policy rules', () => {
  it('getPolicyRules GETs /api/policy/rules and returns the list', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const list = [{ id: 'prule-1', order: 0, matcher: { kind: 'domain-suffix', value: 'x.test' }, intent: 'direct', enabled: true }]
    const f = vi.fn().mockResolvedValue(jsonResp(200, list))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.getPolicyRules()
    expect(f).toHaveBeenCalledTimes(1)
    expect(f.mock.calls[0][0]).toBe('/api/policy/rules')
    expect(result).toEqual(list)
  })

  it('createPolicyRule POSTs to /api/policy/rules with the body', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const body = { matcher: { kind: 'domain-suffix' as const, value: 'x.test' }, intent: 'direct' as const, enabled: true }
    const created = { id: 'prule-1', order: 0, ...body }
    const f = vi.fn().mockResolvedValue(jsonResp(200, created))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.createPolicyRule(body)
    expect(f.mock.calls[0][0]).toBe('/api/policy/rules')
    expect(f.mock.calls[0][1].method).toBe('POST')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual(body)
    expect(result).toEqual(created)
  })

  it('updatePolicyRule PATCHes /api/policy/rules/{id} with the body', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const body = { matcher: { kind: 'domain' as const, value: 'y.test' }, intent: 'block' as const, enabled: false }
    const updated = { id: 'prule-1', order: 0, ...body }
    const f = vi.fn().mockResolvedValue(jsonResp(200, updated))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.updatePolicyRule('prule-1', body)
    expect(f.mock.calls[0][0]).toBe('/api/policy/rules/prule-1')
    expect(f.mock.calls[0][1].method).toBe('PATCH')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual(body)
    expect(result).toEqual(updated)
  })

  it('deletePolicyRule DELETEs /api/policy/rules/{id}', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn().mockResolvedValue(jsonResp(200, { ok: true }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.deletePolicyRule('prule-1')
    expect(f.mock.calls[0][0]).toBe('/api/policy/rules/prule-1')
    expect(f.mock.calls[0][1].method).toBe('DELETE')
    expect(result).toEqual({ ok: true })
  })

  it('reorderPolicyRules PUTs {ids} to /api/policy/rules/reorder', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn().mockResolvedValue(jsonResp(200, { ok: true }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.reorderPolicyRules(['prule-2', 'prule-1'])
    expect(f.mock.calls[0][0]).toBe('/api/policy/rules/reorder')
    expect(f.mock.calls[0][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual({ ids: ['prule-2', 'prule-1'] })
    expect(result).toEqual({ ok: true })
  })

  it('getPolicyFallback / putPolicyFallback hit /api/policy/fallback', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const fb = { policy: 'auto' as const }
    const f1 = vi.fn().mockResolvedValue(jsonResp(200, fb))
    vi.stubGlobal('fetch', f1)
    const { api } = await import('./client')
    const got = await api.getPolicyFallback()
    expect(f1.mock.calls[0][0]).toBe('/api/policy/fallback')
    expect(got).toEqual(fb)

    const f2 = vi.fn().mockResolvedValue(jsonResp(200, { ok: true }))
    vi.stubGlobal('fetch', f2)
    const put = await api.putPolicyFallback(fb)
    expect(f2.mock.calls[0][0]).toBe('/api/policy/fallback')
    expect(f2.mock.calls[0][1].method).toBe('PUT')
    expect(JSON.parse(f2.mock.calls[0][1].body as string)).toEqual(fb)
    expect(put).toEqual({ ok: true })
  })

  it('applyPolicy POSTs to /api/policy/apply', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn().mockResolvedValue(jsonResp(200, { ok: true }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.applyPolicy()
    expect(f.mock.calls[0][0]).toBe('/api/policy/apply')
    expect(f.mock.calls[0][1].method).toBe('POST')
    expect(result).toEqual({ ok: true })
  })
})

describe('api client — policy rules mock ON (VITE_API_MOCK=1)', () => {
  it('getPolicyRules resolves to a non-empty fixture array', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    expect((await api.getPolicyRules()).length).toBeGreaterThan(0)
  })

  it('createPolicyRule mints an id + order via the mock backend', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const created = await api.createPolicyRule({ matcher: { kind: 'domain-suffix', value: 'x.test' }, intent: 'direct', enabled: true })
    expect(created.id).toMatch(/^prule-/)
    expect(typeof created.order).toBe('number')
  })

  it('createPolicyRule / deletePolicyRule round-trip against the mock store', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const before = (await api.getPolicyRules()).length
    const created = await api.createPolicyRule({ matcher: { kind: 'domain-suffix', value: 'x.test' }, intent: 'direct', enabled: true })
    expect((await api.getPolicyRules()).length).toBe(before + 1)
    const del = await api.deletePolicyRule(created.id)
    expect(del).toEqual({ ok: true })
    expect((await api.getPolicyRules()).length).toBe(before)
  })

  it('applyPolicy resolves {ok:true} under mock', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    await expect(api.applyPolicy()).resolves.toEqual({ ok: true })
  })
})
