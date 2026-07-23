import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { api } from '../../lib/api/client'
import type { PluginEngineLogEntry, PluginEngineLogLine } from '../../lib/api/types'
import { BoundedNewestFirstRing } from './BoundedNewestFirstRing'

export interface UsePluginEngineLogsOptions {
  /** Freeze the rendered snapshot while the socket continues draining. */
  paused: boolean
  /** False while the configured sidecar is intentionally idle. */
  enabled?: boolean
  /** Capacity of the live in-memory ring. */
  max?: number
}

export interface UsePluginEngineLogsResult {
  /** Newest-first live view, or an independent snapshot while paused. */
  entries: PluginEngineLogEntry[]
  connected: boolean
  /** Valid frames received since the current pause began, even after ring eviction. */
  bufferedCount: number
  /** Monotonic browser-local watermark including frames hidden by pause. */
  latestId: number
  /** Read counters synchronously for local clear actions between render batches. */
  getCurrentWatermarks: () => PluginEngineLogWatermarks
}

interface PluginEngineLogWatermarks {
  latestId: number
  bufferedCount: number
}

interface PluginEngineLogSnapshot extends PluginEngineLogWatermarks {
  entries: PluginEngineLogEntry[]
}

export const PLUGIN_LOG_RING_SIZE = 1000
export const PLUGIN_LOG_RECONNECT_MS = 3000
export const PLUGIN_LOG_TICKET_TIMEOUT_MS = 5000
export const PLUGIN_LOG_HANDSHAKE_TIMEOUT_MS = 5000

function abortError(message: string): Error {
  if (typeof DOMException !== 'undefined') return new DOMException(message, 'AbortError')
  const error = new Error(message)
  error.name = 'AbortError'
  return error
}

/**
 * Settle at the deadline even when a test double or alternate fetch
 * implementation ignores AbortSignal. The controller also lets effect cleanup
 * end an in-flight ticket request immediately.
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
    const onAbort = () => fail(abortError('Plugin log ticket request aborted'))
    timer = setTimeout(() => controller.abort(), timeoutMs)
    controller.signal.addEventListener('abort', onAbort, { once: true })

    try {
      request(controller.signal).then(succeed, fail)
    } catch (error) {
      fail(error)
    }
  })
}

function closeSocket(socket: WebSocket): void {
  socket.onopen = null
  socket.onmessage = null
  socket.onclose = null
  socket.onerror = null
  try {
    socket.close()
  } catch {
    // A browser may reject close while its implementation is tearing down a
    // failed handshake. All handlers are already detached in that case.
  }
}

function parseFrame(data: unknown): PluginEngineLogLine | null {
  if (typeof data !== 'string') return null
  let value: unknown
  try {
    value = JSON.parse(data)
  } catch {
    return null
  }
  if (!value || typeof value !== 'object') return null
  const frame = value as Record<string, unknown>
  if (
    typeof frame.time !== 'string'
    || (frame.level !== 'info' && frame.level !== 'warn' && frame.level !== 'error')
    || (frame.source !== 'script' && frame.source !== 'engine')
    || typeof frame.message !== 'string'
  ) return null
  if (frame.extension !== undefined && typeof frame.extension !== 'string') return null
  if (frame.action !== undefined && typeof frame.action !== 'string') return null
  if (frame.phase !== undefined && frame.phase !== 'request' && frame.phase !== 'response') return null
  if (frame.duration_ms !== undefined && (typeof frame.duration_ms !== 'number' || !Number.isFinite(frame.duration_ms))) return null
  if (frame.url !== undefined && typeof frame.url !== 'string') return null
  if (frame.script_digest !== undefined && typeof frame.script_digest !== 'string') return null
  return frame as unknown as PluginEngineLogLine
}

/**
 * Opens the ticket-gated, same-origin plugin-engine log stream. The bearer
 * credential never enters the WebSocket URL: every initial connection and
 * reconnect first mints a short-lived one-use ticket. Valid frames enter a
 * bounded newest-first ring and receive a browser-local identity.
 *
 * Pausing intentionally does not pause ingestion. Instead, `entries` remains
 * an independent newest-first snapshot while the live ring keeps rotating and
 * `bufferedCount` keeps increasing. This prevents a long pause from silently
 * losing or shifting rows when more than one ring's worth of frames arrives.
 */
export function usePluginEngineLogs({ paused, enabled = true, max = PLUGIN_LOG_RING_SIZE }: UsePluginEngineLogsOptions): UsePluginEngineLogsResult {
  const capacity = Number.isFinite(max) ? Math.max(1, Math.floor(max)) : PLUGIN_LOG_RING_SIZE
  const [snapshot, setSnapshot] = useState<PluginEngineLogSnapshot>({ entries: [], bufferedCount: 0, latestId: 0 })
  const [connected, setConnected] = useState(false)
  const [ring] = useState(() => new BoundedNewestFirstRing<PluginEngineLogEntry>(capacity))
  const capacityRef = useRef(capacity)
  const nextIdRef = useRef(1)
  const latestIdRef = useRef(0)
  const pausedBufferedCountRef = useRef(0)
  const pausedRef = useRef(paused)
  const committedPausedRef = useRef(paused)
  const animationFrameRef = useRef<number | null>(null)
  const mountedRef = useRef(true)

  const cancelScheduledCommit = useCallback(() => {
    if (animationFrameRef.current === null) return
    cancelAnimationFrame(animationFrameRef.current)
    animationFrameRef.current = null
  }, [])

  const commitPendingFrames = useCallback(() => {
    animationFrameRef.current = null
    if (!mountedRef.current) return
    const latestId = latestIdRef.current
    if (pausedRef.current) {
      const bufferedCount = pausedBufferedCountRef.current
      setSnapshot((current) => current.latestId === latestId && current.bufferedCount === bufferedCount
        ? current
        : { ...current, latestId, bufferedCount })
      return
    }
    setSnapshot({ entries: ring.toNewestFirst(), bufferedCount: 0, latestId })
  }, [ring])

  const scheduleCommit = useCallback(() => {
    if (animationFrameRef.current !== null) return
    animationFrameRef.current = requestAnimationFrame(commitPendingFrames)
  }, [commitPendingFrames])

  const getCurrentWatermarks = useCallback((): PluginEngineLogWatermarks => ({
    latestId: latestIdRef.current,
    bufferedCount: pausedRef.current ? pausedBufferedCountRef.current : 0,
  }), [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      cancelScheduledCommit()
    }
  }, [cancelScheduledCommit])

  useLayoutEffect(() => {
    if (committedPausedRef.current === paused) return
    committedPausedRef.current = paused
    pausedRef.current = paused
    pausedBufferedCountRef.current = 0
    cancelScheduledCommit()
    setSnapshot({
      entries: ring.toNewestFirst(),
      bufferedCount: 0,
      latestId: latestIdRef.current,
    })
  }, [cancelScheduledCommit, paused, ring])

  useLayoutEffect(() => {
    if (capacityRef.current === capacity) return
    capacityRef.current = capacity
    ring.resize(capacity)
    if (pausedRef.current) return
    cancelScheduledCommit()
    setSnapshot({
      entries: ring.toNewestFirst(),
      bufferedCount: 0,
      latestId: latestIdRef.current,
    })
  }, [cancelScheduledCommit, capacity, ring])

  useEffect(() => {
    if (!enabled) {
      setConnected(false)
      return
    }
    let cancelled = false
    let socket: WebSocket | null = null
    let retryTimer: ReturnType<typeof setTimeout> | null = null
    let handshakeTimer: ReturnType<typeof setTimeout> | null = null
    let ticketController: AbortController | null = null
    let generation = 0

    function clearHandshakeTimer() {
      if (handshakeTimer === null) return
      clearTimeout(handshakeTimer)
      handshakeTimer = null
    }

    function scheduleReconnect() {
      if (cancelled || retryTimer !== null) return
      retryTimer = setTimeout(() => {
        retryTimer = null
        void connect()
      }, PLUGIN_LOG_RECONNECT_MS)
    }

    async function connect() {
      if (cancelled) return
      const currentGeneration = ++generation
      const controller = new AbortController()
      ticketController = controller
      let ticket: string
      try {
        ticket = (await requestWithDeadline(
          (signal) => api.createPluginLogTicket(signal),
          controller,
          PLUGIN_LOG_TICKET_TIMEOUT_MS,
        )).ticket
      } catch {
        if (!cancelled && currentGeneration === generation) {
          setConnected(false)
          scheduleReconnect()
        }
        return
      } finally {
        if (ticketController === controller) ticketController = null
      }
      if (cancelled || currentGeneration !== generation) return

      const protocol = location.protocol === 'https:' ? 'wss' : 'ws'
      const params = new URLSearchParams({ ticket })
      let ws: WebSocket
      try {
        ws = new WebSocket(`${protocol}://${location.host}/intercept/logs?${params.toString()}`)
      } catch {
        if (!cancelled && currentGeneration === generation) {
          setConnected(false)
          scheduleReconnect()
        }
        return
      }
      socket = ws
      handshakeTimer = setTimeout(() => {
        if (cancelled || currentGeneration !== generation || socket !== ws) return
        handshakeTimer = null
        socket = null
        closeSocket(ws)
        setConnected(false)
        scheduleReconnect()
      }, PLUGIN_LOG_HANDSHAKE_TIMEOUT_MS)

      ws.onopen = () => {
        if (cancelled || currentGeneration !== generation || socket !== ws) return
        clearHandshakeTimer()
        setConnected(true)
      }
      ws.onmessage = (event: MessageEvent) => {
        if (cancelled || currentGeneration !== generation || socket !== ws) return
        const frame = parseFrame(event.data)
        if (!frame) return
        const entry: PluginEngineLogEntry = { ...frame, id: nextIdRef.current++ }
        ring.push(entry)
        latestIdRef.current = entry.id
        if (pausedRef.current) pausedBufferedCountRef.current += 1
        scheduleCommit()
      }
      ws.onclose = () => {
        if (cancelled || currentGeneration !== generation || socket !== ws) return
        clearHandshakeTimer()
        socket = null
        setConnected(false)
        scheduleReconnect()
      }
      // Browsers always follow a WebSocket error with close. Reconnect stays
      // owned by onclose so a single failure cannot schedule duplicate timers.
      ws.onerror = () => {}
    }

    void connect()

    return () => {
      cancelled = true
      generation += 1
      ticketController?.abort()
      ticketController = null
      if (retryTimer !== null) clearTimeout(retryTimer)
      clearHandshakeTimer()
      if (socket) {
        closeSocket(socket)
        socket = null
      }
    }
  }, [enabled, ring, scheduleCommit])

  return { ...snapshot, connected, getCurrentWatermarks }
}
