import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { api } from '../../lib/api/client'
import type { QueryLogEntry, QueryLogResponse } from '../../lib/api/types'
import LogsPage from './LogsPage'
import { MemoryRouter } from 'react-router-dom'

/** LogsPage reads `?q=` so the resolve test can hand it a domain. */
function renderLogs(initialPath = '/logs') {
  return render(<MemoryRouter initialEntries={[initialPath]}><LogsPage /></MemoryRouter>)
}

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
    renderLogs()

    const table = await screen.findByTestId('virtual-scroll')
    expect(within(table).getByText('example.com.')).toBeInTheDocument()
    expect(within(table).getByText('baidu.com.')).toBeInTheDocument()
    expect(within(table).getByText('ads.tracking.io.')).toBeInTheDocument()
  })

  it('an entry with reason=chnroute-cn shows the 国内直连 label on its own categorical slot', async () => {
    mockLog()
    renderLogs()

    const table = await screen.findByTestId('virtual-scroll')
    const label = within(table).getByText('国内直连')
    expect(label.className).toContain('text-text-mid')
    const dot = label.querySelector('span')
    expect(dot?.style.background).toBe('var(--color-chart-4)')
  })

  it('an entry with reason=block shows 拦截 on its own categorical slot', async () => {
    mockLog()
    renderLogs()

    const table = await screen.findByTestId('virtual-scroll')
    const label = within(table).getByText('拦截')
    expect(label.className).toContain('text-text-mid')
    const dot = label.querySelector('span')
    expect(dot?.style.background).toBe('var(--color-chart-1)')
  })

  /**
   * Caught on the deployed console: an answer carrying several addresses wrapped
   * out of the fixed row box and drew over the row beneath it. Every other cell
   * in this table truncates.
   */
  it('truncates a multi-address answer instead of overflowing its row', async () => {
    mockLog({
      retention_seconds: 300,
      entries: [{ ...ENTRIES[0], ips: ['59.82.43.234', '59.82.121.163', '59.82.122.130', '59.82.44.240'] }],
    })
    renderLogs()

    const table = await screen.findByTestId('virtual-scroll')
    const cell = within(table).getByTitle('59.82.43.234, 59.82.121.163, 59.82.122.130, 59.82.44.240')
    expect(cell.className).toContain('truncate')
  })

  it('shows the reason as a chip in the 命中规则 column', async () => {
    mockLog()
    renderLogs()

    const table = await screen.findByTestId('virtual-scroll')
    expect(within(table).getByText('chnroute-foreign')).toBeInTheDocument()
  })

  it('the pause toggle stops further polling', async () => {
    vi.useFakeTimers()
    mockLog()

    renderLogs()
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
    renderLogs()

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

    renderLogs()
    await user.type(screen.getByPlaceholderText(i18n.t('logs.searchPlaceholder')), 'baidu')
    await waitFor(() => expect(api.getQueryLog).toHaveBeenCalledTimes(2))
    expect(await screen.findByText('baidu.com.')).toBeInTheDocument()

    resolveFirst(FIXTURE)
    await Promise.resolve()
    expect(screen.queryByText('example.com.')).not.toBeInTheDocument()
  })

  it('shows the empty state when no entries match', async () => {
    mockLog({ retention_seconds: 300, entries: [] })
    renderLogs()

    expect(await screen.findByText(i18n.t('logs.emptyTitle'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('logs.emptyHint'))).toBeInTheDocument()
  })

  it('shows the load-failed state on a generic API error', async () => {
    vi.mocked(api.getQueryLog).mockRejectedValue(new Error('network'))
    renderLogs()

    expect(await screen.findByText(i18n.t('logs.loadFailed'))).toBeInTheDocument()
  })

  /**
   * The filter pills used to carry their own list of semantic colours
   * (--color-green / cyan / primary / indigo / red) in their own order, while
   * the legend row and the table dots 40px below read the categorical chart
   * slots. The same 国内直连 was therefore green in the filter row and orange
   * in the table, and ocean/forest alias enough of those semantic roles that
   * five decisions rendered in three colours. These pin the fix: one table
   * (log-columns' DECISION), one order, counts instead of a duplicate legend.
   */
  describe('decision filter pills', () => {
    const pills = () => within(screen.getByRole('group', { name: i18n.t('logs.colDecision') })).getAllByRole('button')

    it('paints each pill from the same categorical slot the table dot uses, in chart-slot order', async () => {
      mockLog()
      renderLogs()
      await screen.findByTestId('virtual-scroll')

      // [0] is 全部决策 and carries no swatch.
      const swatchColors = pills()
        .slice(1)
        .map((pill) => (pill.querySelector('span[style]') as HTMLElement | null)?.style.background)
      expect(swatchColors).toEqual([
        'var(--color-chart-1)',
        'var(--color-chart-2)',
        'var(--color-chart-3)',
        'var(--color-chart-4)',
        'var(--color-chart-5)',
      ])
    })

    it('labels the pills from the shared decision namespace, so a reason reads the same here and in the table', async () => {
      mockLog()
      renderLogs()
      await screen.findByTestId('virtual-scroll')

      expect(pills().slice(1).map((pill) => pill.textContent)).toEqual([
        `${i18n.t('decision.block')}1`,
        `${i18n.t('decision.forceDirect')}0`,
        `${i18n.t('decision.forceProxy')}0`,
        `${i18n.t('decision.chnrouteCn')}1`,
        `${i18n.t('decision.chnrouteForeign')}1`,
      ])
    })

    it('counts the window already in hand rather than issuing another request', async () => {
      mockLog()
      renderLogs()
      await screen.findByTestId('virtual-scroll')

      const callsBefore = vi.mocked(api.getQueryLog).mock.calls.length
      expect(pills()[0].textContent).toBe(`${i18n.t('logs.allDecisions')}${ENTRIES.length}`)
      expect(vi.mocked(api.getQueryLog).mock.calls.length).toBe(callsBefore)
    })

    it('drops the separate legend row — the pills are the legend', async () => {
      mockLog()
      renderLogs()
      await screen.findByTestId('virtual-scroll')

      // 国内直连 appeared twice above the table (pill + legend) with two
      // different colours; it is now the pill only, plus the table cell.
      const outsideTable = screen
        .getAllByText(i18n.t('decision.chnrouteCn'), { exact: false })
        .filter((node) => !node.closest('[data-testid="virtual-scroll"]'))
      expect(outsideTable).toHaveLength(1)
      expect(screen.getByText(i18n.t('logs.windowHint', { limit: 300 }))).toBeInTheDocument()
    })

    it('filters the table to the clicked decision', async () => {
      mockLog()
      const user = userEvent.setup()
      renderLogs()
      await screen.findByTestId('virtual-scroll')

      await user.click(pills()[4]) // chnroute-cn
      const table = screen.getByTestId('virtual-scroll')
      expect(within(table).getByText('baidu.com.')).toBeInTheDocument()
      expect(within(table).queryByText('example.com.')).not.toBeInTheDocument()
    })
  })
})
