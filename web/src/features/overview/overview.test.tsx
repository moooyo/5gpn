import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import i18n from '../../i18n'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import type { Status } from '../../lib/api/types'
import OverviewPage from './OverviewPage'

const STATS: Status['stats'] = {
  total: 7200,
  block: 100,
  force_direct: 50,
  force_proxy: 20,
  chnroute_cn: 500,
  chnroute_foreign: 300,
  cache_entries: 10,
  china_ok: 1,
  china_err: 0,
  trust_ok: 1,
  trust_err: 0,
  cache_hits: 1,
  cache_misses: 1,
  china_avg_ms: 5,
  trust_avg_ms: 10,
}
const STATUS: Status = { version: 'dev+abc1234', uptime_seconds: 3600, stats: STATS }

function statusValue(overrides: Partial<StatusValue> = {}): StatusValue {
  return {
    dnsState: 'healthy',
    mihomoState: 'healthy',
    interceptState: 'healthy',
    dnsOk: true,
    mihomoOk: true,
    interceptOk: true,
    loading: false,
    interceptLoading: false,
    status: STATUS,
    ...overrides,
  }
}

function renderOverview(status: StatusValue = statusValue()) {
  return render(
    <MemoryRouter>
      <StatusContext.Provider value={status}>
        <OverviewPage />
      </StatusContext.Provider>
    </MemoryRouter>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.useRealTimers()
})

describe('OverviewPage', () => {
  it('derives first-paint QPS from total/uptime and renders the M3 hero', async () => {
    const { container } = renderOverview()
    expect(await screen.findAllByText('2')).toHaveLength(2)
    expect(screen.getByText(i18n.t('overview.queriesPerSecond'))).toBeInTheDocument()
    expect(container.querySelector('[data-chart="sparkline"]')).toBeInTheDocument()
  })

  it('renders the five live decision segments in a CSP-safe SVG donut', () => {
    const { container } = renderOverview()
    const donut = [...container.querySelectorAll<HTMLElement>('[data-chart="donut"]')]
      .find((element) => element.querySelector('svg')?.getAttribute('aria-label')?.includes('拦截: 100'))
    expect(donut).toBeDefined()
    expect(donut?.querySelectorAll('circle[pathLength="100"]')).toHaveLength(5)
    expect(screen.getByText('强制网关')).toBeInTheDocument()
    expect(screen.getByText('境外走网关')).toBeInTheDocument()
  })

  it('pauses QPS collection without changing the status snapshots', () => {
    renderOverview()
    fireEvent.click(screen.getByRole('button', { name: i18n.t('overview.pause') }))
    expect(screen.getByText(i18n.t('overview.paused'))).toBeInTheDocument()
  })

  it('computes cache hit rate and exposes meter semantics', () => {
    renderOverview()
    expect(screen.getByRole('meter')).toHaveAttribute('aria-valuenow', '50')
    expect(screen.getByText('50.0%')).toBeInTheDocument()
  })

  it('renders a fresh cache as 0% rather than NaN%', () => {
    renderOverview(statusValue({ status: { ...STATUS, stats: { ...STATS, cache_hits: 0, cache_misses: 0 } } }))
    expect(screen.getByRole('meter')).toHaveAttribute('aria-valuenow', '0')
    expect(screen.getByText('0.0%')).toBeInTheDocument()
  })

  it('plots both upstream latencies on one shared scale with health beside them', () => {
    const { container } = renderOverview()
    const fills = container.querySelectorAll<HTMLElement>('[data-chart="hbar"] [role="img"] > div')
    expect(fills).toHaveLength(2)
    // trust (10ms) is the slower leg here, so it owns the full-width bar and
    // china (5ms) is drawn at half of it — one scale, no second axis.
    expect(fills[0].style.width).toBe('50%')
    expect(fills[1].style.width).toBe('100%')
    expect(screen.getAllByText('5.0 ms')).toHaveLength(2)
    expect(screen.getAllByText('10.0 ms')).toHaveLength(2)
  })

  it('states which latency it is measuring so the card cannot be misread', () => {
    renderOverview()
    expect(screen.getByText(i18n.t('overview.upstreamLatencyHint'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('overview.upstreamLatencyScope'))).toBeInTheDocument()
  })

  it('reports upstream health as a rate plus an absolute failure count', () => {
    renderOverview()
    // china_ok 1 / china_err 0 in STATS — an exact 100% is printed without
    // false precision, and the zero-failure case still shows its count.
    expect(screen.getAllByText(i18n.t('overview.upstreamSuccessRate', { rate: '100%' }))).toHaveLength(2)
    expect(screen.getAllByText(i18n.t('overview.upstreamFailures', { n: '0' }))).toHaveLength(2)
  })

  it('renders "no samples yet" rather than a fabricated 100% before any exchange', () => {
    renderOverview(statusValue({
      status: { ...STATUS, stats: { ...STATS, china_ok: 0, china_err: 0, trust_ok: 0, trust_err: 0 } },
    }))
    expect(screen.getAllByText(i18n.t('overview.upstreamSuccessRateUnknown'))).toHaveLength(2)
  })

  it('renders the chnroute-only arbitration split separately', () => {
    const { container } = renderOverview()
    const donut = [...container.querySelectorAll<HTMLElement>('[data-chart="donut"]')]
      .find((element) => element.querySelector('svg')?.getAttribute('aria-label')?.includes('境内: 500'))
    expect(donut).toBeDefined()
    expect(donut?.querySelectorAll('circle[pathLength="100"]')).toHaveLength(2)
  })

  it('keeps the live decision rail visible as the product signature', () => {
    renderOverview()
    expect(screen.getByText(i18n.t('overview.traceQuery'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('overview.traceDecision'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('overview.traceGateway'))).toBeInTheDocument()
  })
})
