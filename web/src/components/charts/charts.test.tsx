import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { DualAreaChart, DonutChart, GaugeChart, HBarChart, Sparkline } from './index'

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

  // Round caps overhang each arc end by strokeWidth/2, which on r=39 adds ~5.3
  // of the ring's 100 units per segment — so a 39/61 split painted 43/65 and a
  // 0% segment still showed up as a visible lozenge.
  it('paints arc lengths that match the data instead of overhanging them', () => {
    const { container } = render(
      <DonutChart segments={[
        { name: 'cn', value: 39, color: '#111111' },
        { name: 'foreign', value: 61, color: '#222222' },
      ]} />,
    )
    const arcs = container.querySelectorAll('[data-chart="donut"] circle[pathLength="100"]')
    expect(arcs).toHaveLength(2)
    for (const arc of arcs) expect(arc).toHaveAttribute('stroke-linecap', 'butt')

    const dashOf = (i: number) => Number.parseFloat(arcs[i].getAttribute('stroke-dasharray')!.split(' ')[0])
    // Each arc is its true share less one 2px separator, never more than its share.
    expect(dashOf(0)).toBeLessThanOrEqual(39)
    expect(dashOf(0)).toBeGreaterThan(38)
    expect(dashOf(1)).toBeLessThanOrEqual(61)
    expect(dashOf(1)).toBeGreaterThan(60)
    // Offsets still tile the ring at the true boundaries.
    expect(arcs[1].getAttribute('stroke-dashoffset')).toBe('-39')
  })

  it('draws nothing at all for a zero-valued segment', () => {
    const { container } = render(
      <DonutChart segments={[
        { name: 'cn', value: 5, color: '#111111' },
        { name: 'none', value: 0, color: '#222222' },
        { name: 'foreign', value: 5, color: '#333333' },
      ]} />,
    )
    const arcs = container.querySelectorAll('[data-chart="donut"] circle[pathLength="100"]')
    expect(arcs).toHaveLength(2)
    expect(container.querySelector('[data-chart="donut"] circle[stroke="#222222"]')).toBeNull()
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

describe('HBarChart', () => {
  const rows = [
    { name: 'china', value: 110.6, display: '110.6 ms' },
    { name: 'trust', value: 42.4, display: '42.4 ms' },
  ]

  it('scales every bar against the shared maximum and direct-labels each row', () => {
    const { container } = render(<HBarChart rows={rows} />)
    const fills = container.querySelectorAll<HTMLElement>('[data-chart="hbar"] [role="img"] > div')
    expect(fills).toHaveLength(2)
    expect(fills[0].style.width).toBe('100%')
    expect(fills[1].style.width).toBe(`${(42.4 / 110.6) * 100}%`)
    expect(screen.getByText('110.6 ms')).toBeInTheDocument()
    expect(screen.getByText('42.4 ms')).toBeInTheDocument()
  })

  // The defect the vertical grouped BarChart shipped with: a value that is
  // non-zero but tiny against the max rendered sub-pixel — invisible, while
  // still consuming its layout slot and pushing the visible bars off-centre
  // from their labels. A floor keeps small-but-present readable as present.
  it('keeps a non-zero value visible instead of collapsing it into the track', () => {
    const { container } = render(
      <HBarChart rows={[{ name: 'china', value: 14000, display: '14000' }, { name: 'trust', value: 3, display: '3' }]} />,
    )
    const fills = container.querySelectorAll<HTMLElement>('[data-chart="hbar"] [role="img"] > div')
    expect(Number.parseFloat(fills[1].style.width)).toBeGreaterThan(1)
  })

  it('renders an empty track rather than a bar when every value is zero', () => {
    const { container } = render(
      <HBarChart rows={[{ name: 'china', value: 0, display: '0.0 ms' }, { name: 'trust', value: 0, display: '0.0 ms' }]} />,
    )
    const fills = container.querySelectorAll<HTMLElement>('[data-chart="hbar"] [role="img"] > div')
    expect(fills[0].style.width).toBe('0%')
    expect(fills[1].style.width).toBe('0%')
  })

  it('names each row and its value in the accessible label', () => {
    const { container } = render(<HBarChart rows={rows} />)
    const marks = container.querySelectorAll('[data-chart="hbar"] [role="img"]')
    expect(marks[0]).toHaveAttribute('aria-label', 'china: 110.6 ms')
    expect(marks[1]).toHaveAttribute('aria-label', 'trust: 42.4 ms')
  })
})
