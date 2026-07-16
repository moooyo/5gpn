/*
 * Shared kernel-status poller (amendment A-M3).
 *
 * Polls the two liveness surfaces the chrome needs — api.getStatus() (the
 * 5gpn-dns daemon itself) and api.getMihomoHealth() (the mihomo gateway
 * forwarder, via the daemon's bearer-protected /api/mihomo/health endpoint) —
 * on a completion-scheduled interval, and exposes both raw payloads plus derived up/down flags
 * via context.
 *
 * mihomo liveness is DELIBERATELY not derived from status.version (that
 * field is the 5gpn-dns build version, unrelated to whether mihomo is up) —
 * mihomoOk is computed from getMihomoHealth() succeeding (mihomo's bare
 * `/version` response carries no `error` field to check).
 */
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { api } from './api/client'
import type { Status, MihomoHealth } from './api/types'

export interface StatusValue {
  status?: Status
  mihomo?: MihomoHealth
  dnsOk: boolean
  mihomoOk: boolean
  loading: boolean
}

const INITIAL: StatusValue = { dnsOk: false, mihomoOk: false, loading: true }

// Exported (not just useStatus) so tests can inject a manual value via
// `<StatusContext.Provider value={...}>` without mocking the api client —
// see the brief's suggested stubbing approach.
export const StatusContext = createContext<StatusValue | null>(null)

export interface StatusProviderProps {
  children: ReactNode
  intervalMs?: number
}

export function StatusProvider({ children, intervalMs = 5000 }: StatusProviderProps) {
  const [value, setValue] = useState<StatusValue>(INITIAL)

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let controller: AbortController | undefined
    let generation = 0

    async function poll() {
      const currentGeneration = ++generation
      controller = new AbortController()
      const [statusResult, healthResult] = await Promise.allSettled([
        api.getStatus(controller.signal),
        api.getMihomoHealth(controller.signal),
      ])
      if (cancelled || currentGeneration !== generation) return
      setValue((prev) => ({
        status: statusResult.status === 'fulfilled' ? statusResult.value : prev.status,
        mihomo: healthResult.status === 'fulfilled' ? healthResult.value : prev.mihomo,
        dnsOk: statusResult.status === 'fulfilled',
        mihomoOk: healthResult.status === 'fulfilled',
        loading: false,
      }))
      // Schedule from completion, not from start: a slow status endpoint can
      // never overlap the next poll or let an older response win a race.
      timer = setTimeout(() => void poll(), intervalMs)
    }

    void poll()

    return () => {
      cancelled = true
      generation += 1
      controller?.abort()
      if (timer) clearTimeout(timer)
    }
  }, [intervalMs])

  return <StatusContext.Provider value={value}>{children}</StatusContext.Provider>
}

export function useStatus(): StatusValue {
  const ctx = useContext(StatusContext)
  if (!ctx) throw new Error('useStatus must be used within a StatusProvider')
  return ctx
}
