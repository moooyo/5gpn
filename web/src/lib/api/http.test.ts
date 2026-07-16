import { describe, it, expect, vi, beforeEach } from 'vitest'
import { apiFetch, AuthError, ApiError, TOKEN_KEY, setToken, getToken, clearToken } from './http'

const jsonResp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

beforeEach(() => { localStorage.clear(); clearToken(); vi.restoreAllMocks() })

describe('http core', () => {
  it('adds Authorization: Bearer when token set', async () => {
    setToken('tok123')
    expect(localStorage.getItem(TOKEN_KEY)).toBe('tok123')
    const f = vi.fn().mockResolvedValue(jsonResp(200, { ok: true }))
    vi.stubGlobal('fetch', f)
    await apiFetch('/api/status')
    const init = f.mock.calls[0][1]
    expect(init.headers['Authorization']).toBe('Bearer tok123')
  })

  it('returns parsed JSON on 200', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResp(200, { version: 'x' })))
    expect(await apiFetch<{ version: string }>('/api/status')).toEqual({ version: 'x' })
  })

  it('clears token and throws AuthError on 401', async () => {
    setToken('tok')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResp(401, { error: 'unauthorized' })))
    await expect(apiFetch('/api/status')).rejects.toBeInstanceOf(AuthError)
    expect(getToken()).toBeNull()
  })

  it('throws ApiError with status+message on 500 {error}', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResp(500, { error: 'boom' })))
    const e = (await apiFetch('/api/status').catch((x) => x)) as ApiError
    expect(e).toBeInstanceOf(ApiError)
    expect(e.status).toBe(500)
  })

  it('carries blocked+retry_after_seconds on 403', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResp(403, { error: 'blocked', blocked: true, retry_after_seconds: 900 })))
    const e = (await apiFetch('/api/status').catch((x) => x)) as ApiError
    expect(e).toBeInstanceOf(ApiError)
    expect(e.status).toBe(403)
    expect(e.blocked).toBe(true)
    expect(e.retry_after_seconds).toBe(900)
  })
})
