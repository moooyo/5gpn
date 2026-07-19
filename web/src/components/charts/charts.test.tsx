import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BarChart, DualAreaChart, DonutChart, GaugeChart, Sparkline } from './index'

describe('Sparkline', () => {
  it('renders a CSP-safe inline SVG line and updates its path with new data', () => {
    const { container, rerender } = render(<Sparkline data={[1, 2, 3]} color="#2563eb" />)
    const chart = container.querySelector('[data-chart="sparkline"]')
    expect(chart?.tagName).toBe('svg')
    const firstPath = chart?.querySelector('path[stroke]')?.getAttribute('d')

    rerender(<Sparkline data={[3, 2, 1]} color="#2563eb" />)
    const nextPath = container.querySelector('[data-chart="sparkline"] path[stroke]')?.getAttribute('d')
    expect(nextPath).not.toBe(firstPath)
    expect(container.querySelector('canvas')).toBeNull()
  })
})

describe('DualAreaChart', () => {
  it('renders two named SVG series without a runtime chart engine', () => {
    const { container } = render(<DualAreaChart down={[1, 2]} up={[3, 4]} downName="Down" upName="Up" />)
    const chart = container.querySelector('[data-chart="dual-area"]')
    expect(chart).toHaveAttribute('aria-label', 'Down, Up')
    expect(chart?.querySelectorAll('path[stroke]')).toHaveLength(2)
  })
})

describe('DonutChart', () => {
  const segments = [
    { name: 'direct', value: 1, color: '#111111' },
    { name: 'gateway', value: 2, color: '#222222' },
    { name: 'block', value: 3, color: '#333333' },
  ]

  it('renders one SVG arc per segment and a theme-aware center label', () => {
    const { container } = render(<DonutChart segments={segments} centerLabel="6" />)
    expect(container.querySelectorAll('[data-chart="donut"] circle[stroke="#111111"], [data-chart="donut"] circle[stroke="#222222"], [data-chart="donut"] circle[stroke="#333333"]')).toHaveLength(3)
    expect(screen.getByText('6')).toHaveClass('text-text-strong')
  })

  it('omits the center label when it is not provided', () => {
    render(<DonutChart segments={segments} />)
    expect(screen.queryByText('6')).not.toBeInTheDocument()
  })
})

describe('GaugeChart', () => {
  it.each([
    [62, '62%'],
    [150, '100%'],
    [Number.NaN, '0%'],
  ])('clamps %s and exposes meter semantics', (value, label) => {
    render(<GaugeChart value={value} />)
    const meter = screen.getByRole('meter')
    expect(meter).toHaveAttribute('aria-valuenow', label.replace('%', ''))
    expect(screen.getByText(label)).toBeInTheDocument()
  })
})

describe('BarChart', () => {
  it('renders grouped SVG bars and category labels', () => {
    const { container } = render(
      <BarChart
        categories={['china', 'trust']}
        series={[
          { name: 'ok', data: [10, 8], color: '#16a34a' },
          { name: 'err', data: [2, 1], color: '#dc2626' },
        ]}
      />,
    )
    expect(container.querySelectorAll('[data-chart="bar"] rect')).toHaveLength(4)
    expect(screen.getByText('china')).toBeInTheDocument()
    expect(screen.getByText('trust')).toBeInTheDocument()
  })

  it('centres a lone visible series on its category label', () => {
    const { container } = render(
      <BarChart
        categories={['china', 'trust']}
        series={[
          { name: 'ok', data: [10, 8], color: '#16a34a' },
          { name: 'err', data: [0, 0], color: '#dc2626' },
        ]}
      />,
    )
    const bars = container.querySelectorAll('[data-chart="bar"] rect')
    expect(Number(bars[0].getAttribute('x')) + Number(bars[0].getAttribute('width')) / 2).toBe(90)
    expect(Number(bars[2].getAttribute('x')) + Number(bars[2].getAttribute('width')) / 2).toBe(270)
  })
})
