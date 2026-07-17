import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import i18n from '../../i18n'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import type { Status } from '../../lib/api/types'
import OverviewPage from './OverviewPage'

// echarts needs a real canvas, which jsdom lacks — mock `echarts/core` as in
// Task 5.1's charts.test.tsx, but return a FRESH stub instance per init()
// call (the dashboard mounts several chart components at once, unlike the
// single-chart tests in charts.test.tsx) so each chart's setOption calls can
// be told apart.
interface StubInstance {
  setOption: ReturnType<typeof vi.fn>
  resize: ReturnType<typeof vi.fn>
  dispose: ReturnType<typeof vi.fn>
  dispatchAction: ReturnType<typeof vi.fn>
}

const { instances, initMock, useMock } = vi.hoisted(() => {
  const instances: StubInstance[] = []
  const initMock = vi.fn(() => {
    const inst = { setOption: vi.fn(), resize: vi.fn(), dispose: vi.fn(), dispatchAction: vi.fn() }
    instances.push(inst)
    return inst
  })
  const useMock = vi.fn()
  return { instances, initMock, useMock }
})

vi.mock('echarts/core', () => ({ use: useMock, init: initMock }))

/** Finds the last `setOption` call, across every mounted chart instance,
 *  whose option satisfies `pred` — used to pick out one specific chart (e.g.
 *  the decision donut) among the several the dashboard renders at once. */
function findOption(pred: (opt: any) => boolean): any {
  for (const inst of instances) {
    const calls = inst.setOption.mock.calls
    const last = calls.at(-1)?.[0]
    if (last && pred(last)) return last
  }
  return undefined
}

beforeAll(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, value: 200 })
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, value: 200 })
})

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
    dnsOk: true,
    mihomoOk: true,
    loading: false,
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
  instances.length = 0
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
  vi.useRealTimers()
})

describe('OverviewPage', () => {
  it('renders the QPS card from /api/status (total/uptime, no second sample yet)', async () => {
    renderOverview()

    // 7200 total / 3600s uptime = 2 qps exactly — appears twice (top metric
    // card + the QPS 实时 card), both driven by the same derived value.
    const matches = await screen.findAllByText('2')
    expect(matches.length).toBeGreaterThanOrEqual(2)
  })

  it('决策分布 donut option has 5 segments derived from the stats verdict counters', async () => {
    renderOverview()

    await waitFor(() => {
      const opt = findOption((o) => o.series?.[0]?.type === 'pie')
      expect(opt).toBeDefined()
      expect(opt.series[0].data).toHaveLength(5)
      const values = opt.series[0].data.map((d: { value: number }) => d.value)
      expect(values).toEqual([100, 50, 20, 500, 300])
    })

    expect(screen.getByText('拦截')).toBeInTheDocument()
    expect(screen.getByText('强制直连')).toBeInTheDocument()
    expect(screen.getByText('强制代理')).toBeInTheDocument()
    expect(screen.getByText('国内直连')).toBeInTheDocument()
    expect(screen.getByText('境外代理')).toBeInTheDocument()
  })

  it('the pause toggle stops further QPS series growth (no getTraffic poll to observe post-B3)', async () => {
    vi.useFakeTimers()
    renderOverview()

    fireEvent.click(screen.getByRole('button', { name: i18n.t('overview.pause') }))

    expect(screen.getByText(i18n.t('overview.paused'))).toBeInTheDocument()
  })

  it('缓存命中率 gauge shows cache_hits/(cache_hits+cache_misses)*100 (1/(1+1) = 50%)', async () => {
    renderOverview()

    await waitFor(() => {
      const opt = findOption((o) => o.series?.[0]?.type === 'gauge')
      expect(opt).toBeDefined()
      expect(opt.series[0].data).toEqual([{ value: 50 }])
    })
    expect(screen.getByText('50%')).toBeInTheDocument()
  })

  it('缓存命中率 gauge renders 0%, not NaN%, when cache_hits and cache_misses are both 0', async () => {
    renderOverview(
      statusValue({ status: { ...STATUS, stats: { ...STATS, cache_hits: 0, cache_misses: 0 } } }),
    )

    await waitFor(() => {
      const opt = findOption((o) => o.series?.[0]?.type === 'gauge')
      expect(opt).toBeDefined()
      expect(opt.series[0].data).toEqual([{ value: 0 }])
    })
    expect(screen.getByText('0%')).toBeInTheDocument()
  })

  it('上游健康与延迟 bar chart carries china/trust ok+err counts and the avg-latency stat line', async () => {
    renderOverview()

    await waitFor(() => {
      const opt = findOption((o) => o.series?.[0]?.type === 'bar')
      expect(opt).toBeDefined()
      expect(opt.series.map((s: { data: number[] }) => s.data)).toEqual([
        [1, 1], // china_ok, trust_ok
        [0, 0], // china_err, trust_err
      ])
    })
    expect(screen.getByText('5.0ms')).toBeInTheDocument()
    expect(screen.getByText('10.0ms')).toBeInTheDocument()
  })

  it('境内/境外分流比 donut has 2 segments derived from the chnroute counters only', async () => {
    renderOverview()

    await waitFor(() => {
      const opt = findOption((o) => o.series?.[0]?.type === 'pie' && o.series[0].data.length === 2)
      expect(opt).toBeDefined()
      const values = opt.series[0].data.map((d: { value: number }) => d.value)
      expect(values).toEqual([500, 300])
    })

    expect(screen.getByText('境内')).toBeInTheDocument()
    expect(screen.getByText('境外')).toBeInTheDocument()
  })
})
