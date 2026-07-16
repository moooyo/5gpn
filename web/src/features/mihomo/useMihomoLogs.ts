import { useEffect, useRef, useState } from 'react'
import type { MihomoLogLine } from '../../lib/api/types'
import { api } from '../../lib/api/client'

export interface UseMihomoLogsOpts {
  /** Stops APPENDING new frames to `lines` — mirrors LogsPage's pause
   *  semantics (pausing there just stops the poll, never tears down any
   *  underlying connection). The socket stays open and keeps draining
   *  frames while paused; only the ring stops growing. */
  paused: boolean
  /** Ring capacity — oldest lines are dropped once it's exceeded. */
  max?: number
}

export interface UseMihomoLogsResult {
  lines: MihomoLogLine[]
  connected: boolean
}

const DEFAULT_MAX = 1000
const RECONNECT_MS = 3000

/**
 * Subscribes to the daemon's same-origin reverse-proxied mihomo `/logs`
 * WebSocket. Before every connection/reconnection it mints a short-lived,
 * single-use ticket through the bearer-protected control API, then upgrades
 * `/proxy/logs?ticket=…&level=info`. READ-ONLY: mihomo emits one JSON log line per text
 * frame (`{type, payload}`); each parseable frame is appended to a bounded
 * ring (drop-oldest at `max`). The long-lived bearer and mihomo controller
 * secret never go in the WS URL — only the disposable ticket does — so the
 * browser opens a same-origin `wss://` permitted by the console's
 * `connect-src 'self'` CSP). On close (or error, which always fires
 * alongside a close for a WebSocket) the hook retries after a fixed
 * backoff — no exponential growth, since a single dropped mihomo connection
 * is expected to be transient (daemon restart, network hiccup) rather than
 * a sustained-outage case.
 *
 * NOTE: this is exercised in tests against a fake global `WebSocket` double
 * (see mihomo.test.tsx) — driving it against a REAL mihomo `/logs` socket
 * through the reverse proxy is a test-env cutover gate, not something the
 * jsdom unit suite can cover.
 */
export function useMihomoLogs({ paused, max = DEFAULT_MAX }: UseMihomoLogsOpts): UseMihomoLogsResult {
  const [lines, setLines] = useState<MihomoLogLine[]>([])
  const [connected, setConnected] = useState(false)

  // The interval/socket callbacks always read the LATEST `paused` via this
  // ref rather than closing over it, so toggling pause never needs to
  // reopen the socket (mirrors LogsPage's queryRef pattern).
  const pausedRef = useRef(paused)
  useEffect(() => {
    pausedRef.current = paused
  }, [paused])

  useEffect(() => {
    let cancelled = false
    let socket: WebSocket | null = null
    let retryTimer: ReturnType<typeof setTimeout> | null = null
    let generation = 0

    function scheduleReconnect() {
      if (cancelled || retryTimer) return
      retryTimer = setTimeout(() => {
        retryTimer = null
        void connect()
      }, RECONNECT_MS)
    }

    async function connect() {
      if (cancelled) return
      const currentGeneration = ++generation
      let ticket: string
      try {
        ticket = (await api.createMihomoLogTicket()).ticket
      } catch {
        if (!cancelled && currentGeneration === generation) {
          setConnected(false)
          scheduleReconnect()
        }
        return
      }
      if (cancelled || currentGeneration !== generation) return
      const proto = location.protocol === 'https:' ? 'wss' : 'ws'
      const params = new URLSearchParams({ ticket, level: 'info' })
      const url = `${proto}://${location.host}/proxy/logs?${params.toString()}`
      const ws = new WebSocket(url)
      socket = ws

      ws.onopen = () => {
        if (!cancelled) setConnected(true)
      }
      ws.onmessage = (ev: MessageEvent) => {
        if (cancelled || pausedRef.current) return
        let parsed: MihomoLogLine
        try {
          parsed = JSON.parse(ev.data as string) as MihomoLogLine
        } catch {
          return // not a JSON frame — drop rather than crash the list
        }
        setLines((prev) => {
          const next = prev.length >= max ? prev.slice(prev.length - max + 1) : prev.slice()
          next.push(parsed)
          return next
        })
      }
      ws.onclose = () => {
        socket = null
        if (cancelled) return
        setConnected(false)
        scheduleReconnect()
      }
      // onerror is always followed by onclose for a WebSocket — the close
      // handler above already owns the reconnect-with-backoff behavior, so
      // this only exists to swallow the event (no-op) rather than let it
      // surface as an unhandled browser console error.
      ws.onerror = () => {}
    }

    void connect()

    return () => {
      cancelled = true
      generation += 1
      if (retryTimer) clearTimeout(retryTimer)
      if (socket) {
        socket.onopen = null
        socket.onmessage = null
        socket.onclose = null
        socket.onerror = null
        socket.close()
      }
    }
  }, [max])

  return { lines, connected }
}
