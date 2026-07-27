import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import type { MihomoHealth, Status } from '../../lib/api/types'
import MihomoPage from './MihomoPage'
import { Toaster } from '../../components/ds'

vi.mock('../../lib/api/client', () => ({
  api: { createMihomoLogTicket: vi.fn(), createZashboardHandoff: vi.fn(), getMihomoConfig: vi.fn() },
}))
import { api } from '../../lib/api/client'

// jsdom does not lay out the DOM, so `offsetHeight`/`offsetWidth` are always
// 0 — @tanstack/react-virtual's `getRect()` reads exactly those to size the
// scroll viewport, so with the real (0-height) jsdom values it always
// computes an empty visible range. Stub a synthetic non-zero size (mirrors
// LogsPage's/data-grid's own test files) so the virtualized log list
// actually renders rows here.
beforeAll(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, value: 600 })
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, value: 800 })
})

// A minimal fake WebSocket the test drives directly. jsdom has no real
// WebSocket implementation, and exercising useMihomoLogs against a REAL
// mihomo /logs socket through the daemon's reverse proxy is a test-env
// cutover gate (see the task brief) — this double lets the unit suite
// control exactly when frames arrive/the socket closes.
// The hook's own reconnect backoff (useMihomoLogs.ts's RECONNECT_MS) — kept
// in sync manually since the constant isn't exported; advancing fake timers
// by more than this must trigger exactly one reconnect attempt.
const RECONNECT_MS = 3000

class FakeWebSocket {
  static instances: FakeWebSocket[] = []
  url: string
  onopen: (() => void) | null = null
  onmessage: ((ev: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  /** Tracks real close() invocations even though the hook's cleanup nulls
   *  `onclose` before calling close() (so the callback itself can't be used
   *  to detect that close() actually ran — see the unmount test below). */
  closeCalls = 0

  constructor(url: string) {
    this.url = url
    FakeWebSocket.instances.push(this)
  }

  emit(line: { type: string; payload: string }) {
    this.onmessage?.({ data: JSON.stringify(line) })
  }

  close() {
    this.closeCalls += 1
    this.onclose?.()
  }
}

function statusWith(
  zashDomain?: string,
  opts: { mihomoOk?: boolean; mihomo?: MihomoHealth; loading?: boolean } = {},
): StatusValue {
  const status = { version: 'dev', uptime_seconds: 1, stats: {} as Status['stats'] } as Status
  if (zashDomain) status.zash_domain = zashDomain
  return {
    status,
    dnsState: 'healthy',
    mihomoState: opts.mihomoOk === false ? 'down' : 'healthy',
    interceptState: 'healthy',
    dnsOk: true,
    mihomoOk: opts.mihomoOk ?? true,
    interceptOk: true,
    mihomo: opts.mihomo ?? { version: 'v1.19.0', meta: true },
    loading: opts.loading ?? false,
    interceptLoading: false,
  }
}

function renderPage(
  zashDomain?: string,
  opts?: { mihomoOk?: boolean; mihomo?: MihomoHealth; loading?: boolean },
) {
  return render(
    <StatusContext.Provider value={statusWith(zashDomain, opts)}>
      <MihomoPage />
    </StatusContext.Provider>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  FakeWebSocket.instances = []
  vi.mocked(api.createMihomoLogTicket).mockReset()
  vi.mocked(api.createMihomoLogTicket).mockResolvedValue({ ticket: 'ticket-1' })
  vi.mocked(api.createZashboardHandoff).mockReset()
  vi.mocked(api.createZashboardHandoff).mockResolvedValue({
    url: 'https://zash.5gpn.example.com/handoff?ticket=one-use-ticket',
    expires_in_seconds: 30,
  })
  vi.mocked(api.getMihomoConfig).mockReset()
  vi.mocked(api.getMihomoConfig).mockResolvedValue({
    text: 'mixed-port: 7890\n',
    revision: 'rev-1',
    applied_at: new Date(Date.now() - 12 * 60_000).toISOString(),
    controller_reachable: true,
    controller_authenticated: true,
  })
  vi.stubGlobal('WebSocket', FakeWebSocket as unknown as typeof WebSocket)
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  // Safety net: a test that throws before its own try/finally restores real
  // timers must not leak fake timers into the next test.
  vi.useRealTimers()
})

describe('MihomoPage', () => {
  it('states the controller tri-state and last-applied time the config page reports, not a binary healthy/failed', async () => {
    renderPage('zash.5gpn.example.com')

    expect(await screen.findByText(i18n.t('mihomo.healthRunning'))).toBeInTheDocument()
    const subtitle = await screen.findByText(/v1\.19\.0/)
    expect(subtitle).toHaveTextContent(i18n.t('mihomo.metaBadge'))
    expect(subtitle).toHaveTextContent(i18n.t('mihomo.controllerAuthenticated'))
    expect(subtitle).toHaveTextContent(i18n.t('format.mAgo', { count: 12 }))
    expect(screen.getByText(i18n.t('mihomo.intro'))).toBeInTheDocument()
    expect(screen.queryByText(i18n.t('mihomo.healthTitle'))).not.toBeInTheDocument()
  })

  it('reports a reachable-but-unauthenticated controller rather than calling it healthy', async () => {
    vi.mocked(api.getMihomoConfig).mockResolvedValue({
      text: '',
      revision: 'rev-1',
      controller_reachable: true,
      controller_authenticated: false,
    })
    renderPage('zash.5gpn.example.com')

    expect(await screen.findByText(new RegExp(i18n.t('mihomo.controllerUnauthenticated')))).toBeInTheDocument()
  })

  it('renders emitted log lines live, and pause buffers rather than discarding', async () => {
    renderPage('zash.5gpn.example.com')
    await screen.findByText(i18n.t('mihomo.healthRunning'))

    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const ws = FakeWebSocket.instances[0]
    expect(ws).toBeDefined()
    expect(ws.url).toContain('/proxy/logs?ticket=ticket-1&level=info')

    act(() => {
      ws.emit({ type: 'info', payload: 'hello world' })
    })
    expect(await screen.findByText('hello world')).toBeInTheDocument()

    act(() => {
      ws.emit({ type: 'warning', payload: 'second line' })
    })
    expect(await screen.findByText('second line')).toBeInTheDocument()
    expect(screen.queryByText(i18n.t('mihomo.colLevel'))).not.toBeInTheDocument()
    expect(screen.queryByText(i18n.t('mihomo.colMessage'))).not.toBeInTheDocument()

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: i18n.t('mihomo.pause') }))

    act(() => {
      ws.emit({ type: 'info', payload: 'held while paused' })
    })
    // Give any (incorrect) state update a tick to land before asserting absence.
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(screen.queryByText('held while paused')).not.toBeInTheDocument()
    // The frame is buffered, not dropped: the button says so, and resuming
    // merges it in. `onmessage` used to `return` while paused, so the line
    // was gone for good with nothing on screen saying so.
    expect(screen.getByText(i18n.t('mihomo.pausedBuffered', { count: 1 }))).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: i18n.t('mihomo.resume') }))
    expect(await screen.findByText('held while paused')).toBeInTheDocument()
  })

  it('filters the visible lines by a payload search', async () => {
    renderPage('zash.5gpn.example.com')
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    const ws = FakeWebSocket.instances[0]
    act(() => {
      ws.emit({ type: 'info', payload: 'dial example.com' })
      ws.emit({ type: 'info', payload: 'dial other.test' })
    })
    await screen.findByText('dial other.test')

    const user = userEvent.setup()
    await user.type(screen.getByPlaceholderText(i18n.t('mihomo.searchPlaceholder')), 'example')

    await waitFor(() => expect(screen.queryByText('dial other.test')).not.toBeInTheDocument())
    expect(screen.getByText('dial example.com')).toBeInTheDocument()
  })

  it('reopens the socket at the requested level when the level filter changes', async () => {
    renderPage('zash.5gpn.example.com')
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /^debug/ }))

    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(2))
    expect(FakeWebSocket.instances[1].url).toContain('level=debug')
  })

  it('clears the current lines locally', async () => {
    renderPage('zash.5gpn.example.com')
    await waitFor(() => expect(FakeWebSocket.instances).toHaveLength(1))
    act(() => FakeWebSocket.instances[0].emit({ type: 'info', payload: 'to be cleared' }))
    await screen.findByText('to be cleared')

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: i18n.t('mihomo.clearLabel') }))
    expect(screen.queryByText('to be cleared')).not.toBeInTheDocument()
  })

  it('opens zashboard through a one-use handoff without putting the controller secret in the browser URL', async () => {
    const close = vi.fn()
    const popupDocument = document.implementation.createHTMLDocument('zashboard handoff')
    let submittedForm: HTMLFormElement | undefined
    vi.spyOn(HTMLFormElement.prototype, 'submit').mockImplementation(function (this: HTMLFormElement) {
      submittedForm = this
    })
    vi.spyOn(window, 'open').mockReturnValue({
      document: popupDocument,
      close,
      closed: false,
      opener: window,
    } as unknown as Window)
    renderPage('zash.5gpn.example.com')
    await screen.findByText(i18n.t('mihomo.healthRunning'))

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: new RegExp(i18n.t('mihomo.openZashboard')) }))

    await waitFor(() => expect(api.createZashboardHandoff).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(submittedForm).toBeDefined())
    expect(submittedForm?.method).toBe('post')
    expect(submittedForm?.action).toBe('https://zash.5gpn.example.com/handoff?ticket=one-use-ticket')
    expect(submittedForm?.action).not.toContain('secret=')
    expect(close).not.toHaveBeenCalled()
  })

  /**
   * A blocked popup used to navigate the console itself to zashboard with no
   * warning — the operator lost the page they were on, and the review's
   * "nothing happens" report is the same failure seen from the other side.
   * It now says what happened and offers the same-tab route as a choice.
   */
  it('reports a blocked popup and only submits in the current tab once the operator asks', async () => {
    let submittedForm: HTMLFormElement | undefined
    vi.spyOn(HTMLFormElement.prototype, 'submit').mockImplementation(function (this: HTMLFormElement) {
      submittedForm = this
    })
    vi.spyOn(window, 'open').mockReturnValue(null)
    render(
      <StatusContext.Provider value={statusWith('zash.5gpn.example.com')}>
        <MihomoPage />
        <Toaster />
      </StatusContext.Provider>,
    )
    await screen.findByText(i18n.t('mihomo.healthRunning'))

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: i18n.t('mihomo.openZashboard') }))

    expect(await screen.findByText(i18n.t('mihomo.zashPopupBlocked'))).toBeInTheDocument()
    expect(submittedForm).toBeUndefined()
    expect(api.createZashboardHandoff).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: i18n.t('mihomo.zashOpenHere') }))
    await waitFor(() => expect(submittedForm).toBeDefined())
    expect(submittedForm?.ownerDocument).toBe(document)
    expect(submittedForm?.method).toBe('post')
    expect(submittedForm?.action).toBe('https://zash.5gpn.example.com/handoff?ticket=one-use-ticket')
  })

  it('hides the "open zashboard" link when zash_domain is empty', async () => {
    renderPage(undefined)
    await screen.findByText(i18n.t('mihomo.healthRunning'))

    expect(screen.queryByRole('button', { name: new RegExp(i18n.t('mihomo.openZashboard')) })).not.toBeInTheDocument()
  })
})

// useMihomoLogs's cleanup (cancelled-flag guard, handlers nulled before
// close(), retryTimer cleared, reconnect-after-close via setTimeout) has
// real failure modes a refactor could reintroduce silently: a socket left
// open past unmount, a reconnect timer that still fires and opens a NEW
// socket nobody will ever tear down, or a post-unmount setState. These two
// tests drive the fake WebSocket through both an unmount and a live
// drop-and-reconnect to pin the cleanup/backoff contract.
describe('useMihomoLogs WS lifecycle (unmount cleanup / reconnect)', () => {
  it('unmount closes the socket, and no reconnect timer fires afterward (no new socket, no post-unmount update)', async () => {
    vi.useFakeTimers()
    try {
      const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})

      const { unmount } = renderPage('zash.5gpn.example.com')
      await act(async () => { await Promise.resolve() })
      const ws = FakeWebSocket.instances[0]
      expect(ws).toBeDefined()

      unmount()

      // The hook's cleanup calls close() unconditionally (after nulling the
      // handlers) — this is the only way to observe it ran, since the
      // nulled onclose can no longer signal it.
      expect(ws.closeCalls).toBe(1)

      const instanceCountAtUnmount = FakeWebSocket.instances.length
      consoleError.mockClear()

      // Advance well past RECONNECT_MS: if the cleanup didn't clear
      // retryTimer (or the cancelled-flag guard were missing), a stray
      // setTimeout(connect, ...) from a close race would fire here and
      // construct a new socket / touch unmounted-component state.
      act(() => {
        vi.advanceTimersByTime(RECONNECT_MS * 3)
      })

      expect(FakeWebSocket.instances.length).toBe(instanceCountAtUnmount)
      expect(consoleError).not.toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })

  it('reconnects after the socket drops while mounted with a newly minted ticket', async () => {
    vi.useFakeTimers()
    try {
      renderPage('zash.5gpn.example.com')
      await act(async () => { await Promise.resolve() })
      const first = FakeWebSocket.instances[0]
      expect(first).toBeDefined()
      expect(FakeWebSocket.instances.length).toBe(1)

      // Simulate the server/network dropping the connection (not an
      // unmount) — this is the hook's own onclose path, which schedules
      // setTimeout(connect, RECONNECT_MS).
      act(() => {
        first.close()
      })

      // No immediate reconnect — it's scheduled, not synchronous.
      expect(FakeWebSocket.instances.length).toBe(1)

      await act(async () => {
        await vi.advanceTimersByTimeAsync(RECONNECT_MS + 100)
      })

      expect(FakeWebSocket.instances.length).toBe(2)
      expect(FakeWebSocket.instances[1]).not.toBe(first)
      expect(api.createMihomoLogTicket).toHaveBeenCalledTimes(2)
    } finally {
      vi.useRealTimers()
    }
  })
})
