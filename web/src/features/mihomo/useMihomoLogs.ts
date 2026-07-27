import { useCallback, useEffect, useRef, useState } from 'react'
import type { MihomoLogLine } from '../../lib/api/types'
import { api } from '../../lib/api/client'

export interface UseMihomoLogsOpts {
  /** Freezes the rendered list. Frames that arrive while paused are BUFFERED,
   *  not dropped: this used to `return` out of `onmessage`, so a socket that
   *  kept receiving threw the frames away permanently — the same button on the
   *  plugin-log page buffers and reports a count, and one control cannot mean
   *  two different things about the operator's data. */
  paused: boolean
  /** mihomo log level requested from the controller. Changing it reopens the
   *  socket, since the level is a query parameter of the upgrade URL. */
  level?: MihomoLogLevel
  /** Ring capacity — oldest lines are dropped once it's exceeded. */
  max?: number
}

export type MihomoLogLevel = 'debug' | 'info' | 'warning' | 'error' | 'silent'

export const MIHOMO_LOG_LEVELS: MihomoLogLevel[] = ['debug', 'info', 'warning', 'error']

export interface UseMihomoLogsResult {
  lines: MihomoLogLine[]
  connected: boolean
  /** Frames received since the current pause began and not yet merged in. */
  bufferedCount: number
  /** Whether the pause buffer hit `max` and started dropping its oldest.
   *  Surfaced so the button can stop promising that nothing is being lost. */
  bufferFull: boolean
  /** Drops every line currently displayed (and anything buffered behind the
   *  pause), and returns what was dropped so the caller can offer an undo.
   *  Local only — the controller keeps streaming. */
  clear: () => MihomoLogLine[]
  /** Puts a previous `clear()` result back. The stream keeps arriving during
   *  the undo window, so restored lines go BEFORE anything received since. */
  restore: (restored: MihomoLogLine[]) => void
  /** Abandons the fixed backoff and redials now. Without it a stalled stream
   *  could only be retried by waiting out the timer or reloading the page,
   *  while the plugin-log page beside it already offered exactly this. */
  reconnect: () => void
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
export function useMihomoLogs({ paused, level = 'info', max = DEFAULT_MAX }: UseMihomoLogsOpts): UseMihomoLogsResult {
  const [lines, setLines] = useState<MihomoLogLine[]>([])
  const [connected, setConnected] = useState(false)
  const [bufferedCount, setBufferedCount] = useState(0)
  const [bufferFull, setBufferFull] = useState(false)

  // The interval/socket callbacks always read the LATEST `paused` via this
  // ref rather than closing over it, so toggling pause never needs to
  // reopen the socket (mirrors LogsPage's queryRef pattern).
  const pausedRef = useRef(paused)
  // Frames that arrived during the current pause, oldest first.
  const pauseBufferRef = useRef<MihomoLogLine[]>([])
  const maxRef = useRef(max)
  maxRef.current = max
  // Read by `clear`, which has to hand back what it dropped. Capturing that
  // inside the state updater would run twice under StrictMode.
  const linesRef = useRef<MihomoLogLine[]>(lines)
  linesRef.current = lines

  const [redialNonce, setRedialNonce] = useState(0)
  const reconnect = useCallback(() => setRedialNonce((value) => value + 1), [])

  const clear = useCallback(() => {
    const dropped = [...linesRef.current, ...pauseBufferRef.current]
    pauseBufferRef.current = []
    setBufferedCount(0)
    setBufferFull(false)
    setLines([])
    return dropped
  }, [])

  const restore = useCallback((restored: MihomoLogLine[]) => {
    if (restored.length === 0) return
    setLines((prev) => [...restored, ...prev].slice(-maxRef.current))
  }, [])

  useEffect(() => {
    if (pausedRef.current === paused) return
    pausedRef.current = paused
    if (paused) {
      pauseBufferRef.current = []
      setBufferedCount(0)
      setBufferFull(false)
      return
    }
    // Resuming merges the buffer in rather than discarding it.
    const buffered = pauseBufferRef.current
    pauseBufferRef.current = []
    setBufferedCount(0)
    setBufferFull(false)
    if (buffered.length === 0) return
    setLines((prev) => [...prev, ...buffered].slice(-maxRef.current))
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
      const params = new URLSearchParams({ ticket, level })
      const url = `${proto}://${location.host}/proxy/logs?${params.toString()}`
      const ws = new WebSocket(url)
      socket = ws

      ws.onopen = () => {
        if (!cancelled) setConnected(true)
      }
      ws.onmessage = (ev: MessageEvent) => {
        if (cancelled) return
        let parsed: MihomoLogLine
        try {
          parsed = JSON.parse(ev.data as string) as MihomoLogLine
        } catch {
          return // not a JSON frame — drop rather than crash the list
        }
        if (pausedRef.current) {
          const buffer = pauseBufferRef.current
          buffer.push(parsed)
          if (buffer.length > maxRef.current) {
            buffer.splice(0, buffer.length - maxRef.current)
            setBufferFull(true)
          }
          setBufferedCount(buffer.length)
          return
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
  }, [level, max, redialNonce])

  return { lines, connected, bufferedCount, bufferFull, clear, restore, reconnect }
}
