/*
 * Auth/fetch core for the 5gpn-dns control-plane API client.
 *
 * All console requests share this bearer-token and typed-error behavior.
 */

import i18n from '../../i18n'

export const TOKEN_KEY = '5gpn_token'

// ---- Errors -----------------------------------------------------------------

/** Thrown on any 401. The app catches it to clear auth state and show Login. */
export class AuthError extends Error {
  constructor(message = i18n.t('errors.authRequired')) {
    super(message)
    this.name = 'AuthError'
  }
}

/** Thrown on any non-2xx (except 401) — carries the server's error message. */
export class ApiError extends Error {
  status: number
  blocked?: boolean
  retry_after_seconds?: number
  constructor(status: number, message: string, extra?: { blocked?: boolean; retry_after_seconds?: number }) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    if (extra?.blocked !== undefined) this.blocked = extra.blocked
    if (extra?.retry_after_seconds !== undefined) this.retry_after_seconds = extra.retry_after_seconds
  }
}

// ---- Token helpers ------------------------------------------------------------

export const AUTH_CHANGED_EVENT = '5gpn:auth-changed'

function notifyAuthChanged(): void {
  if (typeof window !== 'undefined') window.dispatchEvent(new Event(AUTH_CHANGED_EVENT))
}

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function setToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token)
  notifyAuthChanged()
}

export function clearToken(): void {
  localStorage.removeItem(TOKEN_KEY)
  notifyAuthChanged()
}

// ---- Core request -------------------------------------------------------------

function authHeaders(init?: RequestInit): Record<string, string> {
  const headers: Record<string, string> = {}
  const token = getToken()
  if (token) headers['Authorization'] = `Bearer ${token}`
  if (init?.body !== undefined) headers['Content-Type'] = 'application/json'
  return headers
}

/** Inspects a non-2xx response body and throws the matching typed error. */
function throwForStatus(status: number, data: unknown): never {
  if (status === 429) {
    throw new ApiError(429, i18n.t('errors.rateLimited'))
  }
  if (
    status === 403 &&
    data && typeof data === 'object' && 'blocked' in data && (data as { blocked: unknown }).blocked === true
  ) {
    const retry = (data as { retry_after_seconds?: number }).retry_after_seconds
    const minutes = Math.max(1, Math.ceil((retry ?? 0) / 60))
    throw new ApiError(403, i18n.t('errors.blocked', { minutes }), {
      blocked: true,
      retry_after_seconds: retry,
    })
  }
  const msg =
    data && typeof data === 'object' && 'error' in data && typeof (data as { error: unknown }).error === 'string'
      ? (data as { error: string }).error
      : i18n.t('errors.requestFailed', { status })
  throw new ApiError(status, msg)
}

export async function apiFetch<T = unknown>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = { ...authHeaders(init), ...(init.headers as Record<string, string> | undefined) }

  let resp: Response
  try {
    resp = await fetch(path, { cache: 'no-store', ...init, headers })
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') throw err
    throw new ApiError(0, i18n.t('errors.network'))
  }

  if (resp.status === 401) {
    clearToken()
    throw new AuthError(i18n.t('errors.tokenRejected'))
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
    throwForStatus(resp.status, data)
  }

  if (resp.status === 204 || !text) return undefined as T
  return data as T
}
