/*
 * Shared kernel-status poller (amendment A-M3).
 *
 * Polls the two liveness surfaces the chrome needs — api.getStatus() (the
 * 5gpn-dns daemon itself) and api.getMihomoHealth() (the mihomo gateway
 * forwarder, via the daemon's bearer-protected /api/mihomo/health endpoint) —
 * on a completion-scheduled interval, and exposes both raw payloads plus
 * four-state health values via context.
 *
 * mihomo liveness is DELIBERATELY not derived from status.version (that
 * field is the 5gpn-dns build version, unrelated to whether mihomo is up) —
 * mihomoOk is computed from getMihomoHealth() succeeding (mihomo's bare
 * `/version` response carries no `error` field to check).
 */
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { api } from './api/client'
import { ApiError } from './api/http'
import type { Status, MihomoHealth } from './api/types'

export type HealthState = 'checking' | 'healthy' | 'unknown' | 'down'

export interface StatusValue {
  status?: Status
  mihomo?: MihomoHealth
  dnsState: HealthState
  mihomoState: HealthState
  /** Compatibility flag for consumers that only distinguish healthy from all other states. */
  dnsOk: boolean
  /** Compatibility flag for consumers that only distinguish healthy from all other states. */
  mihomoOk: boolean
  loading: boolean
}

const INITIAL: StatusValue = {
  dnsState: 'checking',
  mihomoState: 'checking',
  dnsOk: false,
  mihomoOk: false,
  loading: true,
}

// Exported (not just useStatus) so tests can inject a manual value via
// `<StatusContext.Provider value={...}>` without mocking the api client —
// see the brief's suggested stubbing approach.
export const StatusContext = createContext<StatusValue | null>(null)

export interface StatusProviderProps {
  children: ReactNode
  intervalMs?: number
  requestTimeoutMs?: number
}

function abortError(message: string): Error {
  if (typeof DOMException !== 'undefined') return new DOMException(message, 'AbortError')
  const error = new Error(message)
  error.name = 'AbortError'
  return error
}

/**
 * Abort fetch at the deadline and settle even when a test double or alternate
 * fetch implementation ignores AbortSignal.
 */
function requestWithDeadline<T>(
  request: (signal: AbortSignal) => Promise<T>,
  controller: AbortController,
  timeoutMs: number,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false
    let timer: ReturnType<typeof setTimeout>
    const cleanup = () => {
      clearTimeout(timer)
      controller.signal.removeEventListener('abort', onAbort)
    }
    const succeed = (value: T) => {
      if (settled) return
      settled = true
      cleanup()
      resolve(value)
    }
    const fail = (reason: unknown) => {
      if (settled) return
      settled = true
      cleanup()
      reject(reason instanceof Error ? reason : new Error(String(reason)))
    }
    const onAbort = () => fail(abortError('Health request aborted'))
    timer = setTimeout(() => controller.abort(), timeoutMs)
    controller.signal.addEventListener('abort', onAbort, { once: true })

    try {
      request(controller.signal).then(succeed, fail)
    } catch (error) {
      fail(error)
    }
  })
}

function isExplicitServerFailure(reason: unknown): boolean {
  return reason instanceof ApiError && reason.status >= 500 && reason.status <= 599
}

export function StatusProvider({ children, intervalMs = 5000, requestTimeoutMs = 4000 }: StatusProviderProps) {
  const [value, setValue] = useState<StatusValue>(INITIAL)

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let controllers: AbortController[] = []
    let generation = 0

    async function poll() {
      const currentGeneration = ++generation
      const statusController = new AbortController()
      const healthController = new AbortController()
      controllers = [statusController, healthController]
      let statusResult: PromiseSettledResult<Status> | undefined
      let healthResult: PromiseSettledResult<MihomoHealth> | undefined

      const active = () => !cancelled && currentGeneration === generation
      const updateLoading = () => statusResult === undefined || healthResult === undefined
      const updateMihomoFailure = (): Pick<StatusValue, 'mihomoState' | 'mihomoOk'> => ({
        mihomoState:
          statusResult?.status === 'fulfilled' &&
          healthResult?.status === 'rejected' &&
          isExplicitServerFailure(healthResult.reason)
            ? 'down'
            : 'unknown',
        mihomoOk: false,
      })

      const statusTask = requestWithDeadline(api.getStatus, statusController, requestTimeoutMs).then(
        (status) => ({ status: 'fulfilled', value: status }) as const,
        (reason: unknown) => ({ status: 'rejected', reason }) as const,
      ).then((result) => {
        statusResult = result
        if (!active()) return
        setValue((prev) => ({
          ...prev,
          ...(result.status === 'fulfilled'
            ? { status: result.value, dnsState: 'healthy' as const, dnsOk: true }
            : { dnsState: 'unknown' as const, dnsOk: false }),
          ...(healthResult?.status === 'rejected' ? updateMihomoFailure() : {}),
          loading: prev.loading && updateLoading(),
        }))
      })

      const healthTask = requestWithDeadline(api.getMihomoHealth, healthController, requestTimeoutMs).then(
        (mihomo) => ({ status: 'fulfilled', value: mihomo }) as const,
        (reason: unknown) => ({ status: 'rejected', reason }) as const,
      ).then((result) => {
        healthResult = result
        if (!active()) return
        setValue((prev) => ({
          ...prev,
          ...(result.status === 'fulfilled'
            ? { mihomo: result.value, mihomoState: 'healthy' as const, mihomoOk: true }
            : updateMihomoFailure()),
          loading: prev.loading && updateLoading(),
        }))
      })

      await Promise.all([statusTask, healthTask])
      if (cancelled || currentGeneration !== generation) return
      // Schedule from completion, not from start: a slow status endpoint can
      // never overlap the next poll or let an older response win a race.
      timer = setTimeout(() => void poll(), intervalMs)
    }

    void poll()

    return () => {
      cancelled = true
      generation += 1
      controllers.forEach((controller) => controller.abort())
      if (timer) clearTimeout(timer)
    }
  }, [intervalMs, requestTimeoutMs])

  return <StatusContext.Provider value={value}>{children}</StatusContext.Provider>
}

export function useStatus(): StatusValue {
  const ctx = useContext(StatusContext)
  if (!ctx) throw new Error('useStatus must be used within a StatusProvider')
  return ctx
}
