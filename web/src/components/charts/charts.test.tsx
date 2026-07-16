import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'

// echarts needs a real canvas, which jsdom does not implement — mock the
// `echarts/core` module so `echarts.init(...)` returns a stub instance
// instead of touching canvas. Real `echarts/charts` / `echarts/components` /
// `echarts/renderers` are left UNMOCKED: they're pure registration objects,
// and asserting `use()` was actually called with them is the point of the
// registration test below.
const { chartInstance, initMock, useMock } = vi.hoisted(() => {
  const chartInstance = {
    setOption: vi.fn(),
    resize: vi.fn(),
    dispose: vi.fn(),
    dispatchAction: vi.fn(),
  }
  const initMock = vi.fn(() => chartInstance)
  const useMock = vi.fn()
  return { chartInstance, initMock, useMock }
})

vi.mock('echarts/core', () => ({
  use: useMock,
  init: initMock,
}))

import { BarChart, DualAreaChart, DonutChart, GaugeChart, Sparkline } from './index'
import { echarts } from './echarts'

beforeEach(() => {
  initMock.mockClear()
  chartInstance.setOption.mockClear()
  chartInstance.resize.mockClear()
  chartInstance.dispose.mockClear()
  chartInstance.dispatchAction.mockClear()
})

describe('echarts.ts registration (A-L1)', () => {
  it('registers exactly the core-safe pieces via echarts/core.use, never the barrel', () => {
    expect(useMock).toHaveBeenCalledTimes(1)
    const registered = useMock.mock.calls[0]?.[0] as unknown[]
    expect(Array.isArray(registered)).toBe(true)
    // LineChart, PieChart, BarChart, GaugeChart, GridComponent,
    // TooltipComponent, LegendComponent, CanvasRenderer.
    // Explicitly NOT GeoComponent/MapChart (new Function under CSP).
    expect(registered).toHaveLength(8)
    expect(echarts.use).toBe(useMock)
  })
})

describe('Sparkline', () => {
  it('inits the chart once and sets a single hidden-axis line series', () => {
    render(<Sparkline data={[1, 2, 3]} color="#2563eb" />)

    expect(initMock).toHaveBeenCalledTimes(1)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series).toHaveLength(1)
    expect(option.series[0]).toMatchObject({ type: 'line', data: [1, 2, 3], symbol: 'none' })
    expect(option.xAxis.show).toBe(false)
    expect(option.yAxis.show).toBe(false)
  })

  it('re-applies setOption when data changes', () => {
    const { rerender } = render(<Sparkline data={[1, 2, 3]} color="#2563eb" />)
    expect(chartInstance.setOption).toHaveBeenCalledTimes(1)
    rerender(<Sparkline data={[4, 5, 6]} color="#2563eb" />)
    expect(chartInstance.setOption).toHaveBeenCalledTimes(2)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series[0].data).toEqual([4, 5, 6])
  })
})

describe('DualAreaChart', () => {
  it('inits once, hides the built-in legend, and names the two line series from props', () => {
    render(<DualAreaChart down={[1, 2]} up={[3, 4]} downName="下行" upName="上行" />)

    expect(initMock).toHaveBeenCalledTimes(1)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series).toHaveLength(2)
    expect(option.series.map((s: { name: string }) => s.name)).toEqual(['下行', '上行'])
    expect(option.legend).toEqual({ show: false })
    expect(option.tooltip.trigger).toBe('axis')
  })

  it('defaults series names to empty strings when downName/upName are omitted', () => {
    render(<DualAreaChart down={[1, 2]} up={[3, 4]} />)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series.map((s: { name: string }) => s.name)).toEqual(['', ''])
  })
})

describe('DonutChart', () => {
  it('inits once and sets a pie series with segment-length data and no series labels, and never sets an ECharts title', () => {
    const segments = [
      { name: 'a', value: 1, color: '#111111' },
      { name: 'b', value: 2, color: '#222222' },
      { name: 'c', value: 3, color: '#333333' },
    ]
    render(<DonutChart segments={segments} centerLabel="Total" />)

    expect(initMock).toHaveBeenCalledTimes(1)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series).toHaveLength(1)
    expect(option.series[0].type).toBe('pie')
    expect(option.series[0].radius).toEqual(['62%', '86%'])
    expect(option.series[0].data).toHaveLength(segments.length)
    expect(option.series[0].label).toEqual({ show: false })
    expect(option.title).toBeUndefined()
  })

  it('renders the center label as an HTML overlay (re-themes via text-text-strong), not an ECharts title', () => {
    render(<DonutChart segments={[{ name: 'a', value: 1, color: '#111' }]} centerLabel="42" />)
    const label = screen.getByText('42')
    expect(label).toBeInTheDocument()
    expect(label.className).toContain('text-text-strong')
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.title).toBeUndefined()
  })

  it('omits the center-label overlay when no centerLabel is given', () => {
    render(<DonutChart segments={[{ name: 'a', value: 1, color: '#111' }]} />)
    expect(screen.queryByText('42')).not.toBeInTheDocument()
  })
})

describe('GaugeChart', () => {
  it('inits once and sets a single gauge series with the given value, and never sets an ECharts detail label', () => {
    render(<GaugeChart value={62} />)

    expect(initMock).toHaveBeenCalledTimes(1)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series).toHaveLength(1)
    expect(option.series[0].type).toBe('gauge')
    expect(option.series[0].data).toEqual([{ value: 62 }])
    expect(option.series[0].detail).toEqual({ show: false })
  })

  it('renders the percentage as an HTML overlay (re-themes via text-text-strong), not an ECharts detail', () => {
    render(<GaugeChart value={62} />)
    const label = screen.getByText('62%')
    expect(label).toBeInTheDocument()
    expect(label.className).toContain('text-text-strong')
  })

  it('clamps out-of-range values into 0–100', () => {
    render(<GaugeChart value={150} />)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series[0].data).toEqual([{ value: 100 }])
    expect(screen.getByText('100%')).toBeInTheDocument()
  })

  it('treats a non-finite value as 0 (no NaN%)', () => {
    render(<GaugeChart value={NaN} />)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series[0].data).toEqual([{ value: 0 }])
    expect(screen.getByText('0%')).toBeInTheDocument()
  })
})

describe('BarChart', () => {
  it('inits once, sets one bar series per entry across shared categories, and hides the built-in legend', () => {
    render(
      <BarChart
        categories={['china', 'trust']}
        series={[
          { name: 'ok', data: [10, 8], color: '#16a34a' },
          { name: 'err', data: [2, 1], color: '#dc2626' },
        ]}
      />,
    )

    expect(initMock).toHaveBeenCalledTimes(1)
    const option = chartInstance.setOption.mock.calls.at(-1)?.[0]
    expect(option.series).toHaveLength(2)
    expect(option.series.every((s: { type: string }) => s.type === 'bar')).toBe(true)
    expect(option.series.map((s: { data: number[] }) => s.data)).toEqual([
      [10, 8],
      [2, 1],
    ])
    expect(option.xAxis.data).toEqual(['china', 'trust'])
    expect(option.legend).toEqual({ show: false })
  })
})
