import { StrictMode, useState } from 'react'
import { MemoryRouter } from 'react-router-dom'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import i18n from '../../i18n'
import type { InterceptModule, PluginEngineLogLine } from '../../lib/api/types'
import PluginLogsPage from './PluginLogsPage'
import {
  PLUGIN_LOG_HANDSHAKE_TIMEOUT_MS,
  PLUGIN_LOG_RECONNECT_MS,
  PLUGIN_LOG_TICKET_TIMEOUT_MS,
  usePluginEngineLogs,
} from './usePluginEngineLogs'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'

vi.mock('../../lib/api/client', () => ({
  api: {
    createPluginLogTicket: vi.fn(),
    getInterceptModules: vi.fn(),
  },
}))
import { api } from '../../lib/api/client'

beforeAll(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, value: 600 })
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, value: 900 })
})

class FakeWebSocket {
  static instances: FakeWebSocket[] = []
  readonly url: string
  onopen: (() => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  closeCalls = 0

  constructor(url: string) {
    this.url = url
    FakeWebSocket.instances.push(this)
  }

  open() {
    this.onopen?.()
  }

  emit(frame: PluginEngineLogLine) {
    this.onmessage?.({ data: JSON.stringify(frame) })
  }

  emitRaw(data: string) {
    this.onmessage?.({ data })
  }

  close() {
    this.closeCalls += 1
    this.onclose?.()
  }
}

let nextAnimationFrameId = 1
let animationFrameCallbacks = new Map<number, FrameRequestCallback>()

function installAnimationFrameHarness() {
  nextAnimationFrameId = 1
  animationFrameCallbacks = new Map()
  vi.stubGlobal('requestAnimationFrame', vi.fn((callback: FrameRequestCallback) => {
    const id = nextAnimationFrameId
    nextAnimationFrameId += 1
    animationFrameCallbacks.set(id, callback)
    return id
  }))
  vi.stubGlobal('cancelAnimationFrame', vi.fn((id: number) => {
    animationFrameCallbacks.delete(id)
  }))
}

function flushAnimationFrames() {
  const callbacks = [...animationFrameCallbacks.values()]
  animationFrameCallbacks.clear()
  for (const callback of callbacks) callback(performance.now())
}

const modules = [
  { id: 'io.example.apple', name: 'Apple tools', execution_order: 1 },
  { id: 'io.example.cleaner', name: 'Response cleaner', execution_order: 2 },
] as InterceptModule[]

function frame(message: string, overrides: Partial<PluginEngineLogLine> = {}): PluginEngineLogLine {
  return {
    time: '2026-07-23T12:34:56.000Z',
    level: 'info',
    source: 'script',
    extension: 'io.example.apple',
    action: 'rewrite-location',
    phase: 'request',
    message,
    ...overrides,
  }
}

function setMobile(mobile: boolean) {
  vi.stubGlobal('matchMedia', vi.fn().mockImplementation((query: string) => ({
    matches: mobile && query.includes('max-width: 767px'),
    media: query,
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })))
}

function renderPage() {
  return render(<MemoryRouter><PluginLogsPage /></MemoryRouter>)
}

const IDLE_STATUS: StatusValue = {
  intercept: { running: false, expected: false, installed_plugins: 2, active_plugins: 0 },
  dnsState: 'healthy', mihomoState: 'healthy', interceptState: 'healthy',
  dnsOk: true, mihomoOk: true, interceptOk: true, loading: false, interceptLoading: false,
}

function HookHarness({ enabled = true, max = 1000, onRender }: { enabled?: boolean; max?: number; onRender?: () => void }) {
  const [paused, setPaused] = useState(false)
  const result = usePluginEngineLogs({ paused, enabled, max })
  onRender?.()
  return (
    <div>
      <button type="button" onClick={() => setPaused((value) => !value)}>{paused ? 'resume-test' : 'pause-test'}</button>
      <output data-testid="hook-connected">{String(result.connected)}</output>
      <output data-testid="hook-buffered">{result.bufferedCount}</output>
      <output data-testid="hook-latest">{result.latestId}</output>
      <output data-testid="hook-lines">{result.entries.map((entry) => entry.message).join('|')}</output>
    </div>
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  FakeWebSocket.instances = []
  setMobile(false)
  installAnimationFrameHarness()
  vi.stubGlobal('WebSocket', FakeWebSocket as unknown as typeof WebSocket)
  vi.mocked(api.createPluginLogTicket).mockReset()
  vi.mocked(api.createPluginLogTicket).mockResolvedValue({ ticket: 'plugin-ticket', expires_in_seconds: 30 })
  vi.mocked(api.getInterceptModules).mockReset()
  vi.mocked(api.getInterceptModules).mockResolvedValue({
    revision: 'rev',
    catalog_url: 'https://example.test/catalog',
    modules,
    active_capture_hosts: [],
    execution_order: modules.map((module) => module.id),
    available_egress_groups: [],
  })
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('usePluginEngineLogs', () => {
  it('mints a ticket, opens the narrow endpoint, validates frames, and keeps a newest-first bounded ring', async () => {
    render(<HookHarness max={3} />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1)
    const socket = FakeWebSocket.instances[0]
    expect(socket.url).toContain('/intercept/logs?ticket=plugin-ticket')
    expect(socket.url).not.toContain('bearer')

    act(() => {
      socket.open()
      socket.emitRaw('not-json')
      socket.emit(frame('one'))
      socket.emit(frame('two'))
      socket.emit(frame('three'))
      socket.emit(frame('four'))
      flushAnimationFrames()
    })

    expect(screen.getByTestId('hook-connected')).toHaveTextContent('true')
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('four|three|two')
    expect(screen.getByTestId('hook-lines')).not.toHaveTextContent('one')
  })

  it('commits a burst of one hundred frames in one animation-frame render', async () => {
    const onRender = vi.fn()
    render(<HookHarness onRender={onRender} />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const rendersBeforeBurst = onRender.mock.calls.length

    act(() => {
      for (let index = 0; index < 100; index += 1) {
        FakeWebSocket.instances[0].emit(frame(`burst-${index}`))
      }
    })

    expect(requestAnimationFrame).toHaveBeenCalledTimes(1)
    expect(onRender).toHaveBeenCalledTimes(rendersBeforeBurst)
    act(() => flushAnimationFrames())
    expect(onRender).toHaveBeenCalledTimes(rendersBeforeBurst + 1)
    expect(screen.getByTestId('hook-latest')).toHaveTextContent('100')
    expect(screen.getByTestId('hook-lines')).toHaveTextContent(/^burst-99\|burst-98/)
  })

  it('cancels an uncommitted animation-frame batch on unmount', async () => {
    const view = render(<HookHarness />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]

    act(() => socket.emit(frame('never committed')))
    expect(animationFrameCallbacks.size).toBe(1)
    view.unmount()

    expect(cancelAnimationFrame).toHaveBeenCalledTimes(1)
    expect(animationFrameCallbacks.size).toBe(0)
    expect(socket.closeCalls).toBe(1)
    act(() => flushAnimationFrames())
  })

  it('uses the committed pause boundary even when a live batch is still pending', async () => {
    const user = userEvent.setup()
    render(<HookHarness max={3} />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]

    act(() => socket.emit(frame('before pause')))
    expect(screen.getByTestId('hook-lines')).toBeEmptyDOMElement()
    await user.click(screen.getByRole('button', { name: 'pause-test' }))
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('before pause')

    act(() => {
      socket.emit(frame('after pause'))
      flushAnimationFrames()
    })
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('before pause')
    expect(screen.getByTestId('hook-lines')).not.toHaveTextContent('after pause')
    expect(screen.getByTestId('hook-buffered')).toHaveTextContent('1')

    await user.click(screen.getByRole('button', { name: 'resume-test' }))
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('after pause|before pause')
    expect(screen.getByTestId('hook-buffered')).toHaveTextContent('0')
  })

  it('resizes the ring without reconnecting and retains newest-first order', async () => {
    const view = render(<HookHarness max={4} />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]
    act(() => {
      for (const message of ['one', 'two', 'three', 'four']) socket.emit(frame(message))
      flushAnimationFrames()
    })
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('four|three|two|one')

    view.rerender(<HookHarness max={2} />)
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('four|three')
    expect(screen.getByTestId('hook-lines')).not.toHaveTextContent('two')

    view.rerender(<HookHarness max={5} />)
    act(() => {
      for (const message of ['five', 'six', 'seven']) socket.emit(frame(message))
      flushAnimationFrames()
    })
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('seven|six|five|four|three')
    expect(FakeWebSocket.instances).toHaveLength(1)
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1)
  })

  it('reconnects after three seconds with a newly minted one-use ticket', async () => {
    vi.useFakeTimers()
    render(<HookHarness />)
    await act(async () => { await Promise.resolve() })
    expect(FakeWebSocket.instances).toHaveLength(1)

    act(() => FakeWebSocket.instances[0].close())
    expect(FakeWebSocket.instances).toHaveLength(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(PLUGIN_LOG_RECONNECT_MS + 1) })

    expect(FakeWebSocket.instances).toHaveLength(2)
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2)
  })

  it('aborts a stalled ticket request at its deadline before scheduling one reconnect', async () => {
    vi.useFakeTimers()
    const pendingTicket = new Promise<{ ticket: string; expires_in_seconds: number }>(() => {})
    vi.mocked(api.createPluginLogTicket).mockReturnValueOnce(pendingTicket)
    render(<HookHarness />)
    await act(async () => { await Promise.resolve() })

    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1)
    const signal = vi.mocked(api.createPluginLogTicket).mock.calls[0][0]
    expect(signal).toBeInstanceOf(AbortSignal)
    expect(signal?.aborted).toBe(false)

    await act(async () => { await vi.advanceTimersByTimeAsync(PLUGIN_LOG_TICKET_TIMEOUT_MS) })
    expect(signal?.aborted).toBe(true)
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1)
    expect(FakeWebSocket.instances).toHaveLength(0)

    await act(async () => { await vi.advanceTimersByTimeAsync(PLUGIN_LOG_RECONNECT_MS) })
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2)
    expect(FakeWebSocket.instances).toHaveLength(1)
  })

  it('closes a WebSocket stuck in CONNECTING and retries exactly once', async () => {
    vi.useFakeTimers()
    render(<HookHarness />)
    await act(async () => { await Promise.resolve() })
    expect(FakeWebSocket.instances).toHaveLength(1)
    const stalled = FakeWebSocket.instances[0]

    await act(async () => { await vi.advanceTimersByTimeAsync(PLUGIN_LOG_HANDSHAKE_TIMEOUT_MS) })
    expect(stalled.closeCalls).toBe(1)
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1)

    await act(async () => { await vi.advanceTimersByTimeAsync(PLUGIN_LOG_RECONNECT_MS) })
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2)
    expect(FakeWebSocket.instances).toHaveLength(2)
  })

  it('aborts stale attempts across disable, re-enable, and unmount without late sockets or retries', async () => {
    vi.useFakeTimers()
    let resolveStaleTicket: ((value: { ticket: string; expires_in_seconds: number }) => void) | undefined
    const staleTicket = new Promise<{ ticket: string; expires_in_seconds: number }>((resolve) => {
      resolveStaleTicket = resolve
    })
    vi.mocked(api.createPluginLogTicket).mockReturnValueOnce(staleTicket)
    const view = render(<HookHarness enabled />)
    await act(async () => { await Promise.resolve() })
    const staleSignal = vi.mocked(api.createPluginLogTicket).mock.calls[0][0]

    view.rerender(<HookHarness enabled={false} />)
    expect(staleSignal?.aborted).toBe(true)
    await act(async () => {
      resolveStaleTicket?.({ ticket: 'stale-ticket', expires_in_seconds: 30 })
      await Promise.resolve()
    })
    expect(FakeWebSocket.instances).toHaveLength(0)

    view.rerender(<HookHarness enabled />)
    await act(async () => { await Promise.resolve() })
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2)
    expect(FakeWebSocket.instances).toHaveLength(1)
    const current = FakeWebSocket.instances[0]

    view.unmount()
    expect(current.closeCalls).toBe(1)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(PLUGIN_LOG_HANDSHAKE_TIMEOUT_MS + PLUGIN_LOG_RECONNECT_MS)
    })
    expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2)
    expect(FakeWebSocket.instances).toHaveLength(1)
  })

  it('keeps only the live StrictMode connection attempt', async () => {
    let resolveFirstTicket: ((value: { ticket: string; expires_in_seconds: number }) => void) | undefined
    const firstTicket = new Promise<{ ticket: string; expires_in_seconds: number }>((resolve) => {
      resolveFirstTicket = resolve
    })
    vi.mocked(api.createPluginLogTicket).mockReturnValueOnce(firstTicket)
    render(<StrictMode><HookHarness /></StrictMode>)

    await waitFor(() => expect(api.createPluginLogTicket).toHaveBeenCalledTimes(2))
    const firstSignal = vi.mocked(api.createPluginLogTicket).mock.calls[0][0]
    expect(firstSignal?.aborted).toBe(true)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))

    await act(async () => {
      resolveFirstTicket?.({ ticket: 'strict-stale-ticket', expires_in_seconds: 30 })
      await Promise.resolve()
    })
    expect(FakeWebSocket.instances).toHaveLength(1)
  })

  it('freezes an independent snapshot while more than one ring of frames is buffered', async () => {
    const user = userEvent.setup()
    render(<HookHarness max={3} />)
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]
    act(() => {
      socket.emit(frame('base-one'))
      socket.emit(frame('base-two'))
      socket.emit(frame('base-three'))
      flushAnimationFrames()
    })
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('base-three|base-two|base-one')

    await user.click(screen.getByRole('button', { name: 'pause-test' }))
    act(() => {
      for (let index = 0; index < 1005; index += 1) socket.emit(frame(`buffered-${index}`))
      flushAnimationFrames()
    })

    expect(screen.getByTestId('hook-buffered')).toHaveTextContent('1005')
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('base-three|base-two|base-one')
    expect(screen.getByTestId('hook-lines')).not.toHaveTextContent('buffered-1004')

    await user.click(screen.getByRole('button', { name: 'resume-test' }))
    expect(screen.getByTestId('hook-lines')).toHaveTextContent('buffered-1004|buffered-1003|buffered-1002')
    expect(screen.getByTestId('hook-buffered')).toHaveTextContent('0')
  })
})

describe('PluginLogsPage', () => {
  it('does not mint tickets or show a failure while the sidecar is intentionally idle', async () => {
    render(<StatusContext.Provider value={IDLE_STATUS}><MemoryRouter><PluginLogsPage /></MemoryRouter></StatusContext.Provider>)

    expect(await screen.findAllByText(i18n.t('pluginLogs.inactive'))).not.toHaveLength(0)
    expect(api.createPluginLogTicket).not.toHaveBeenCalled()
    expect(FakeWebSocket.instances).toHaveLength(0)
    expect(screen.queryByText(i18n.t('pluginLogs.disconnectedBanner'))).not.toBeInTheDocument()
  })

  it('retries the stream when a stale idle health snapshot becomes unknown', async () => {
    render(
      <StatusContext.Provider value={{ ...IDLE_STATUS, interceptState: 'unknown', interceptOk: false }}>
        <MemoryRouter><PluginLogsPage /></MemoryRouter>
      </StatusContext.Provider>,
    )

    await waitFor(() => expect(api.createPluginLogTicket).toHaveBeenCalledTimes(1))
    expect(FakeWebSocket.instances).toHaveLength(1)
    expect(screen.queryByText(i18n.t('pluginLogs.inactive'))).not.toBeInTheDocument()
  })

  it('shows the empty/disconnected console state and keeps receiving behind a paused view', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))

    expect(screen.getByText(i18n.t('pluginLogs.emptyTitle'))).toBeInTheDocument()
    expect(screen.getByRole('link', { name: i18n.t('pluginLogs.goToExtensions') })).toHaveAttribute('href', '/extensions')
    expect(screen.getByText(i18n.t('pluginLogs.disconnectedBanner'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('pluginLogs.footer'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('pluginLogs.transport'))).toBeInTheDocument()

    const socket = FakeWebSocket.instances[0]
    act(() => socket.open())
    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.pause') }))
    act(() => {
      socket.emit(frame('hidden while paused'))
      flushAnimationFrames()
    })

    expect(screen.queryByText('hidden while paused')).not.toBeInTheDocument()
    expect(screen.getByText(i18n.t('pluginLogs.pausedHint', { count: 1 }))).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.resume') }))
    expect(await screen.findByText('hidden while paused')).toBeInTheDocument()
  })

  it('clears only the current watermark and continues showing later frames', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]
    act(() => {
      socket.open()
      socket.emit(frame('before clear one'))
      socket.emit(frame('before clear two'))
      flushAnimationFrames()
    })
    expect(await screen.findByText('before clear two')).toBeInTheDocument()

    // This frame is already ingested but has not reached React yet. Clear must
    // still advance past it rather than allowing the pending batch to reappear.
    act(() => socket.emit(frame('pending before clear')))

    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.clearLabel') }))
    act(() => flushAnimationFrames())
    expect(screen.queryByText('before clear one')).not.toBeInTheDocument()
    expect(screen.queryByText('before clear two')).not.toBeInTheDocument()
    expect(screen.queryByText('pending before clear')).not.toBeInTheDocument()

    act(() => {
      socket.emit(frame('after clear'))
      flushAnimationFrames()
    })
    expect(await screen.findByText('after clear')).toBeInTheDocument()
  })

  it('clears a paused batch before its animation-frame counters commit', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const socket = FakeWebSocket.instances[0]
    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.pause') }))

    act(() => {
      for (let index = 0; index < 1005; index += 1) socket.emit(frame(`paused-clear-${index}`))
    })
    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.clearLabel') }))
    act(() => flushAnimationFrames())

    expect(screen.getAllByText(i18n.t('pluginLogs.pausedHint', { count: 0 })).length).toBeGreaterThan(0)
    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.resume') }))
    expect(screen.queryByText('paused-clear-1004')).not.toBeInTheDocument()

    act(() => {
      socket.emit(frame('after paused clear'))
      flushAnimationFrames()
    })
    expect(await screen.findByText('after paused clear')).toBeInTheDocument()
  })

  it('filters locally by level, installed plugin, and the debounced search query without reconnecting', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    await waitFor(() => expect(api.getInterceptModules).toHaveBeenCalledTimes(1))
    const socket = FakeWebSocket.instances[0]
    act(() => {
      socket.emit(frame('apple info'))
      socket.emit(frame('cleaner failure', { level: 'error', extension: 'io.example.cleaner', action: 'clean-response' }))
      socket.emit(frame('apple warning needle', { level: 'warn' }))
      flushAnimationFrames()
    })
    expect(await screen.findByText('cleaner failure')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.level.error') }))
    expect(screen.getByText('cleaner failure')).toBeInTheDocument()
    expect(screen.queryByText('apple info')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: i18n.t('pluginLogs.allLevels') }))
    await user.click(screen.getByRole('combobox', { name: i18n.t('pluginLogs.pluginFilterLabel') }))
    act(() => flushAnimationFrames())
    await user.click(await screen.findByRole('option', { name: /Response cleaner/ }))
    expect(screen.getByText('cleaner failure')).toBeInTheDocument()
    expect(screen.queryByText('apple warning needle')).not.toBeInTheDocument()

    await user.click(screen.getByRole('combobox', { name: i18n.t('pluginLogs.pluginFilterLabel') }))
    act(() => flushAnimationFrames())
    await user.click(await screen.findByRole('option', { name: new RegExp(i18n.t('pluginLogs.allPlugins')) }))
    await user.type(screen.getByRole('textbox', { name: i18n.t('pluginLogs.searchLabel') }), 'needle')
    await waitFor(() => expect(screen.getByText('apple warning needle')).toBeInTheDocument(), { timeout: 1000 })
    await waitFor(() => expect(screen.queryByText('cleaner failure')).not.toBeInTheDocument(), { timeout: 1000 })
    expect(FakeWebSocket.instances).toHaveLength(1)
  })

  it('expands one keyboard-accessible row at a time with full engine metadata', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    act(() => {
      FakeWebSocket.instances[0].emit(frame('first expandable', {
        source: 'engine',
        duration_ms: 18.4,
        script_digest: 'sha256:1234567890abcdef',
        url: 'https://example.test/path',
      }))
      FakeWebSocket.instances[0].emit(frame('second expandable'))
      flushAnimationFrames()
    })
    await screen.findByText('second expandable')

    const rows = screen.getAllByRole('button', { name: new RegExp(i18n.t('pluginLogs.expandRow')) })
    await user.click(rows[1])
    expect(rows[1]).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText(i18n.t('pluginLogs.detail.pluginId'))).toBeInTheDocument()
    expect(screen.getByText('sha256:12345678…')).toBeInTheDocument()
    expect(screen.getByText('https://example.test/path')).toBeInTheDocument()

    await user.click(rows[0])
    expect(rows[0]).toHaveAttribute('aria-expanded', 'true')
    expect(rows[1]).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('https://example.test/path')).not.toBeInTheDocument()
  })

  it('renders the mobile two-row virtual cards and split filter rails', async () => {
    setMobile(true)
    renderPage()
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    act(() => {
      FakeWebSocket.instances[0].emit(frame('mobile log line', { source: 'engine' }))
      flushAnimationFrames()
    })

    expect(await screen.findByText('mobile log line')).toBeInTheDocument()
    expect(screen.getByText(i18n.t('pluginLogs.levelLabel'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('pluginLogs.pluginLabel'))).toBeInTheDocument()
    expect(screen.queryByText(i18n.t('pluginLogs.colTime'))).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: i18n.t('pluginLogs.pause') })).toHaveClass('rounded-full')
    expect(screen.getByTestId('virtual-scroll')).toBeInTheDocument()
  })
})
