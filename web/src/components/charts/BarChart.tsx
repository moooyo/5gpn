import { cn } from '../../lib/cn'

export interface BarSeries {
  name: string
  data: number[]
  color: string
}

export interface BarChartProps {
  categories: string[]
  series: BarSeries[]
  height?: number
  className?: string
}

export function BarChart({ categories, series, height = 160, className }: BarChartProps) {
  const width = 360
  const plotTop = 10
  const plotBottom = 34
  const plotHeight = 120 - plotTop - plotBottom
  const max = Math.max(1, ...series.flatMap((item) => item.data).map((value) => Number.isFinite(value) ? Math.max(0, value) : 0))
  const groupWidth = width / Math.max(1, categories.length)
  const barWidth = Math.min(28, (groupWidth - 28) / Math.max(1, series.length))

  return (
    <svg
      viewBox={`0 0 ${width} 120`}
      preserveAspectRatio="none"
      className={cn('block w-full', className)}
      style={{ height }}
      role="img"
      aria-label={categories.join(', ')}
      data-chart="bar"
    >
      {[.25, .5, .75].map((fraction) => (
        <line key={fraction} x1="8" x2={width - 8} y1={plotTop + plotHeight * fraction} y2={plotTop + plotHeight * fraction} stroke="var(--md-sys-color-outline-variant)" strokeDasharray="3 4" />
      ))}
      {categories.map((category, categoryIndex) => {
        const visibleSeries = series
          .map((item, seriesIndex) => ({ seriesIndex, value: Math.max(0, item.data[categoryIndex] ?? 0) }))
          .filter((item) => item.value > 0)
        const visibleCount = Math.max(1, visibleSeries.length)
        const totalBarsWidth = visibleCount * barWidth + Math.max(0, visibleCount - 1) * 6
        const start = categoryIndex * groupWidth + (groupWidth - totalBarsWidth) / 2
        return (
          <g key={category}>
            {series.map((item, seriesIndex) => {
              const value = Math.max(0, item.data[categoryIndex] ?? 0)
              const barHeight = (value / max) * plotHeight
              const visibleIndex = visibleSeries.findIndex((entry) => entry.seriesIndex === seriesIndex)
              const x = visibleIndex >= 0
                ? start + visibleIndex * (barWidth + 6)
                : categoryIndex * groupWidth + (groupWidth - barWidth) / 2
              return (
                <rect
                  key={`${category}-${item.name}`}
                  x={x}
                  y={plotTop + plotHeight - barHeight}
                  width={barWidth}
                  height={barHeight}
                  rx="5"
                  fill={item.color}
                >
                  <title>{`${category} · ${item.name}: ${value}`}</title>
                </rect>
              )
            })}
            <text x={categoryIndex * groupWidth + groupWidth / 2} y="112" textAnchor="middle" fill="var(--md-sys-color-on-surface-variant)" fontSize="11">
              {category}
            </text>
          </g>
        )
      })}
    </svg>
  )
}
