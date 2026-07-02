/*
 * Typed API client for the 5gpn-dns control plane.
 *
 * Base URL is "" (same origin) — the SPA is served by the Go binary from the
 * :9443 control server, so every request is same-origin and inherits the
 * page's TLS trust (no verify/cert handling needed in-app).
 *
 * The bearer token lives in localStorage['5gpn_token']. Every /api/* request
 * carries `Authorization: Bearer <token>`. On any 401 the token is cleared and
 * a typed AuthError is thrown, which the app catches to reset to the Login
 * view. The token is never logged.
 */

export const TOKEN_KEY = '5gpn_token'

// ---- Shapes (exact keys per the Go API) ------------------------------------

export interface Stats {
  total: number
  // Reason-level counters — a true breakdown of `total` by why the resolver
  // reached its verdict.
  adblock: number
  force_direct: number
  blacklist: number
  chnroute_cn: number
  chnroute_foreign: number
  cache_entries: number
  china_ok: number
  china_err: number
  trust_ok: number
  trust_err: number
}

export interface CertStatus {
  not_after: string // RFC3339 timestamp
  days_remaining: number
  expired: boolean
}

export interface Status {
  version: string
  uptime_seconds: number
  stats: Stats
  cert?: CertStatus // absent when no TLS listener / cert monitor is wired
}

export interface LookupResult {
  name: string
  verdict: string
  reason: string
  ips: string[] | null
  upstream: string
}

export type RuleCategory = 'adblock' | 'direct' | 'blacklist' | 'chnroute'
export type SubFormat = 'plain' | 'gfwlist' | 'dnsmasq' | 'adblock' | 'hosts' | 'cidr'

export interface Subscription {
  id: string
  category: RuleCategory
  name: string
  url: string
  format: string
  enabled: boolean
  interval: string // e.g. "6h", "30m"
}

/** Per-subscription fetch health, attached to the list read. Omitted for a
 *  subscription that has never been fetched. */
export interface SubHealth {
  at: string // RFC3339 timestamp of the last fetch attempt
  ok: boolean
  entries: number
  err: string
}

/** A subscription enriched with its last-fetch health, as returned by the
 *  list endpoint. */
export type SubscriptionView = Subscription & { health?: SubHealth }

export interface UpdateResult {
  id: string
  ok: boolean
  entries: number
  err: string
}

// ---- Errors ----------------------------------------------------------------

/** Thrown on any 401. The app catches it to clear auth state and show Login. */
export class AuthError extends Error {
  constructor(message = 'Authentication required') {
    super(message)
    this.name = 'AuthError'
  }
}

/** Thrown on any non-2xx (except 401) — carries the server's error message. */
export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

// ---- Token helpers ---------------------------------------------------------

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function setToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token)
}

export function clearToken(): void {
  localStorage.removeItem(TOKEN_KEY)
}

// A callback the app registers so a 401 anywhere can drive the UI back to
// Login without every call site needing to know about auth state.
let onAuthLost: (() => void) | null = null
export function setAuthLostHandler(fn: (() => void) | null): void {
  onAuthLost = fn
}

// ---- Core request ----------------------------------------------------------

interface RequestOptions {
  method?: string
  query?: Record<string, string | undefined>
  body?: unknown
}

async function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const token = getToken()
  const headers: Record<string, string> = {}
  if (token) headers['Authorization'] = `Bearer ${token}`

  let url = path
  if (opts.query) {
    const qs = new URLSearchParams()
    for (const [k, v] of Object.entries(opts.query)) {
      if (v !== undefined && v !== '') qs.set(k, v)
    }
    const s = qs.toString()
    if (s) url += `?${s}`
  }

  const init: RequestInit = {
    method: opts.method ?? 'GET',
    headers,
  }
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(opts.body)
  }

  let resp: Response
  try {
    resp = await fetch(url, init)
  } catch {
    throw new ApiError(0, 'Network error — the control server is unreachable.')
  }

  if (resp.status === 401) {
    clearToken()
    if (onAuthLost) onAuthLost()
    throw new AuthError('Token rejected — check the value printed by install.sh.')
  }

  // Some endpoints return an empty body on success; guard the JSON parse.
  const text = await resp.text()
  let data: unknown = null
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = null
    }
  }

  if (!resp.ok) {
    // 429: the per-source rate limiter kicked in. Surface a clear, actionable
    // message rather than the terse server body.
    if (resp.status === 429) {
      throw new ApiError(429, 'Rate limited — slow down and try again in a moment.')
    }
    const msg =
      (data && typeof data === 'object' && 'error' in data && typeof (data as { error: unknown }).error === 'string'
        ? (data as { error: string }).error
        : `Request failed (${resp.status}).`)
    throw new ApiError(resp.status, msg)
  }

  return data as T
}

// ---- Endpoints (one function per route) ------------------------------------

export const api = {
  status(): Promise<Status> {
    return request<Status>('/api/status')
  },

  stats(): Promise<Stats> {
    return request<Stats>('/api/stats')
  },

  lookup(domain: string): Promise<LookupResult> {
    return request<LookupResult>('/api/lookup', { query: { domain } })
  },

  async subscriptions(): Promise<SubscriptionView[]> {
    const r = await request<SubscriptionView[] | null>('/api/subscriptions')
    return r ?? []
  },

  addSubscription(sub: Subscription): Promise<UpdateResult> {
    return request<UpdateResult>('/api/subscriptions', { method: 'POST', body: sub })
  },

  replaceSubscription(id: string, sub: Subscription): Promise<UpdateResult> {
    return request<UpdateResult>(`/api/subscriptions/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: sub,
    })
  },

  deleteSubscription(id: string): Promise<{ ok: boolean }> {
    return request<{ ok: boolean }>(`/api/subscriptions/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    })
  },

  async update(id?: string): Promise<UpdateResult[]> {
    const r = await request<UpdateResult[] | null>('/api/update', {
      method: 'POST',
      query: id ? { id } : undefined,
    })
    return r ?? []
  },

  async rules(cat: RuleCategory): Promise<string[]> {
    const r = await request<string[] | null>(`/api/rules/${cat}`)
    return r ?? []
  },

  addRule(cat: RuleCategory, entry: string): Promise<{ ok: boolean }> {
    return request<{ ok: boolean }>(`/api/rules/${cat}`, {
      method: 'POST',
      body: { entry },
    })
  },

  removeRule(cat: RuleCategory, entry: string): Promise<{ ok: boolean }> {
    return request<{ ok: boolean }>(`/api/rules/${cat}`, {
      method: 'DELETE',
      query: { entry },
    })
  },

  reload(): Promise<{ ok: boolean }> {
    return request<{ ok: boolean }>('/api/reload', { method: 'POST' })
  },
}
