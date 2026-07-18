import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { api } from '../../lib/api/client'
import type { QueryLogEntry, QueryLogResponse } from '../../lib/api/types'
import LogsPage from './LogsPage'

vi.mock('../../lib/api/client', () => ({ api: { getQueryLog: vi.fn() } }))

// jsdom does not lay out the DOM, so `offsetHeight`/`offsetWidth` are always
// 0 — @tanstack/react-virtual's `getRect()` reads exactly those to size the
// scroll viewport, so with real (0-height) jsdom values it always computes
// an empty visible range. Stub a synthetic non-zero size so the virtualizer
// actually renders rows (mirrors data-grid.test.tsx).
beforeAll(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, value: 600 })
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, value: 800 })
})

const ENTRIES: QueryLogEntry[] = [
  {
    time: '2026-07-11T02:00:00Z',
    client: '192.168.1.10',
    name: 'example.com.',
    qtype: 'A',
    verdict: 'proxy',
    reason: 'chnroute-foreign',
    upstream: 'dot.example.com@8.8.8.8:853',
    cache_hit: false,
    rcode: 'NOERROR',
    ips: ['93.184.216.34'],
    duration_ms: 45,
  },
  {
    time: '2026-07-11T02:00:05Z',
    client: '192.168.1.10',
    name: 'baidu.com.',
    qtype: 'A',
    verdict: 'direct',
    reason: 'chnroute-cn',
    upstream: '223.5.5.5:53',
    cache_hit: true,
    rcode: 'NOERROR',
    ips: ['110.242.68.66'],
    duration_ms: 3,
  },
  {
    time: '2026-07-11T02:00:10Z',
    client: '192.168.1.11',
    name: 'ads.tracking.io.',
    qtype: 'A',
    verdict: 'block',
    reason: 'block',
    upstream: '',
    cache_hit: false,
    rcode: 'NXDOMAIN',
    ips: [],
    duration_ms: 0,
  },
]

const FIXTURE: QueryLogResponse = { retention_seconds: 300, entries: ENTRIES }

function mockLog(res: QueryLogResponse = FIXTURE) {
  vi.mocked(api.getQueryLog).mockResolvedValue(res)
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getQueryLog).mockReset()
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('LogsPage', () => {
  it('renders rows from a fixture', async () => {
    mockLog()
    render(<LogsPage />)

    const table = await screen.findByTestId('virtual-scroll')
    expect(within(table).getByText('example.com.')).toBeInTheDocument()
    expect(within(table).getByText('baidu.com.')).toBeInTheDocument()
    expect(within(table).getByText('ads.tracking.io.')).toBeInTheDocument()
  })

  it('an entry with reason=chnroute-cn shows the 国内直连 label + cyan dot', async () => {
    mockLog()
    render(<LogsPage />)

    const table = await screen.findByTestId('virtual-scroll')
    const label = within(table).getByText('国内直连')
    expect(label.className).toContain('text-text-mid')
    const dot = label.querySelector('span')
    expect(dot?.style.background).toBe('rgb(8, 145, 178)')
  })

  it('an entry with reason=block shows 拦截 + red', async () => {
    mockLog()
    render(<LogsPage />)

    const table = await screen.findByTestId('virtual-scroll')
    const label = within(table).getByText('拦截')
    expect(label.className).toContain('text-text-mid')
    const dot = label.querySelector('span')
    expect(dot?.style.background).toBe('rgb(220, 38, 38)')
  })

  it('shows the reason as a chip in the 命中规则 column', async () => {
    mockLog()
    render(<LogsPage />)

    const table = await screen.findByTestId('virtual-scroll')
    expect(within(table).getByText('chnroute-foreign')).toBeInTheDocument()
  })

  it('the pause toggle stops further polling', async () => {
    vi.useFakeTimers()
    mockLog()

    render(<LogsPage />)
    expect(vi.mocked(api.getQueryLog)).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(3000)
    expect(vi.mocked(api.getQueryLog)).toHaveBeenCalledTimes(2)

    fireEvent.click(screen.getByRole('button', { name: i18n.t('logs.pause') }))

    const callsAtPause = vi.mocked(api.getQueryLog).mock.calls.length
    await vi.advanceTimersByTimeAsync(9000)
    expect(vi.mocked(api.getQueryLog)).toHaveBeenCalledTimes(callsAtPause)

    expect(screen.getByText(i18n.t('logs.paused'))).toBeInTheDocument()
  })

  it('filtering updates the query sent to the API', async () => {
    mockLog()
    const user = userEvent.setup()
    render(<LogsPage />)

    await waitFor(() => expect(vi.mocked(api.getQueryLog).mock.calls[0]?.slice(0, 2)).toEqual(['', 300]))

    await user.type(screen.getByPlaceholderText(i18n.t('logs.searchPlaceholder')), 'baidu')

    await waitFor(() => {
      const calls = vi.mocked(api.getQueryLog).mock.calls
      expect(calls[calls.length - 1].slice(0, 2)).toEqual(['baidu', 300])
    })
  })

  it('ignores an older response that resolves after a newer filtered request', async () => {
    const user = userEvent.setup()
    let resolveFirst!: (value: QueryLogResponse) => void
    vi.mocked(api.getQueryLog)
      .mockImplementationOnce(() => new Promise<QueryLogResponse>((resolve) => { resolveFirst = resolve }))
      .mockResolvedValueOnce({ retention_seconds: 300, entries: [ENTRIES[1]] })

    render(<LogsPage />)
    await user.type(screen.getByPlaceholderText(i18n.t('logs.searchPlaceholder')), 'baidu')
    await waitFor(() => expect(api.getQueryLog).toHaveBeenCalledTimes(2))
    expect(await screen.findByText('baidu.com.')).toBeInTheDocument()

    resolveFirst(FIXTURE)
    await Promise.resolve()
    expect(screen.queryByText('example.com.')).not.toBeInTheDocument()
  })

  it('shows the empty state when no entries match', async () => {
    mockLog({ retention_seconds: 300, entries: [] })
    render(<LogsPage />)

    expect(await screen.findByText(i18n.t('logs.emptyTitle'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('logs.emptyHint'))).toBeInTheDocument()
  })

  it('shows the load-failed state on a generic API error', async () => {
    vi.mocked(api.getQueryLog).mockRejectedValue(new Error('network'))
    render(<LogsPage />)

    expect(await screen.findByText(i18n.t('logs.loadFailed'))).toBeInTheDocument()
  })

})
