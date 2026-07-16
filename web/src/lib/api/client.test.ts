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

  it('uses bearer-protected mihomo health and log-ticket endpoints', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const f = vi.fn()
      .mockResolvedValueOnce(jsonResp(200, { version: 'v1.19.28', meta: true }))
      .mockResolvedValueOnce(jsonResp(200, { ticket: 'once' }))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')

    await expect(api.getMihomoHealth()).resolves.toMatchObject({ version: 'v1.19.28' })
    await expect(api.createMihomoLogTicket()).resolves.toEqual({ ticket: 'once' })
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/health')
    expect(f.mock.calls[1][0]).toBe('/api/mihomo/log-ticket')
    expect(f.mock.calls[1][1].method).toBe('POST')
  })
})

describe('api client — mihomo config', () => {
  it('getMihomoConfig GETs /api/mihomo/config and returns the config', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const cfg = { text: 'external-controller: 127.0.0.1:9090\n', applied_at: '2026-07-14T00:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, cfg))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.getMihomoConfig()
    expect(f).toHaveBeenCalledTimes(1)
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config')
    expect(result).toEqual(cfg)
  })

  it('putMihomoConfig PUTs {text} to /api/mihomo/config', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const text = 'external-controller: 127.0.0.1:9090\n'
    const updated = { text, applied_at: '2026-07-14T01:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, updated))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.putMihomoConfig(text)
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config')
    expect(f.mock.calls[0][1].method).toBe('PUT')
    expect(JSON.parse(f.mock.calls[0][1].body as string)).toEqual({ text })
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
      await api.putMihomoConfig('no controller line')
    } catch (err) {
      caught = err
    }
    expect(caught).toBeInstanceOf(ApiError)
    expect(caught).toMatchObject({ status: 400, message: 'missing required infrastructure: controller' })
  })

  it('resetMihomoConfig POSTs to /api/mihomo/config/reset', async () => {
    vi.stubEnv('VITE_API_MOCK', '0')
    vi.resetModules()
    const reset = { text: 'seed text', applied_at: '2026-07-14T02:00:00Z', controller_reachable: true, controller_authenticated: true }
    const f = vi.fn().mockResolvedValue(jsonResp(200, reset))
    vi.stubGlobal('fetch', f)
    const { api } = await import('./client')
    const result = await api.resetMihomoConfig()
    expect(f.mock.calls[0][0]).toBe('/api/mihomo/config/reset')
    expect(f.mock.calls[0][1].method).toBe('POST')
    expect(result).toEqual(reset)
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
  })

  it('putMihomoConfig round-trips a valid edit', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const before = await api.getMihomoConfig()
    const nextText = before.text + '\n# a harmless edit\n'
    const updated = await api.putMihomoConfig(nextText)
    expect(updated.text).toBe(nextText)
    expect(await api.getMihomoConfig()).toEqual(updated)
  })

  it('putMihomoConfig rejects a config missing the controller invariant with ApiError 400', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const { ApiError } = await import('./http')
    await expect(api.putMihomoConfig('proxies: []\n')).rejects.toMatchObject({
      status: 400,
      message: 'missing required infrastructure: controller',
    })
    await expect(api.putMihomoConfig('proxies: []\n')).rejects.toBeInstanceOf(ApiError)
  })

  it('resetMihomoConfig restores the seed after an edit', async () => {
    vi.stubEnv('VITE_API_MOCK', '1')
    vi.resetModules()
    const { api } = await import('./client')
    const { text: seed } = await api.getMihomoConfig()
    await api.putMihomoConfig(seed + '\n# edited\n')
    expect((await api.getMihomoConfig()).text).not.toBe(seed)
    const reset = await api.resetMihomoConfig()
    expect(reset.text).toBe(seed)
    expect((await api.getMihomoConfig()).text).toBe(seed)
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
