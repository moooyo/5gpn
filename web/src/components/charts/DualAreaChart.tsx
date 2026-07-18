import { useId } from 'react'
import { cn } from '../../lib/cn'
import { chartPoints, linePath } from './geometry'

export interface DualAreaChartProps {
  down: number[]
  up: number[]
  height?: number
  labels?: string[]
  className?: string
  downName?: string
  upName?: string
}

export function DualAreaChart({ down, up, height = 164, labels, className, downName = '', upName = '' }: DualAreaChartProps) {
  const width = 480
  const chartHeight = 150
  const downPoints = chartPoints(down, width, chartHeight, 8)
  const upPoints = chartPoints(up, width, chartHeight, 8)
  const downPath = linePath(downPoints)
  const upPath = linePath(upPoints)
  const id = useId().replace(/:/g, '')

  return (
    <svg
      viewBox={`0 0 ${width} ${chartHeight}`}
      preserveAspectRatio="none"
      className={cn('block w-full', className)}
      style={{ height }}
      role="img"
      aria-label={[downName, upName].filter(Boolean).join(', ')}
      data-chart="dual-area"
    >
      <defs>
        <linearGradient id={`${id}-down`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--md-sys-color-primary)" stopOpacity=".18" />
          <stop offset="1" stopColor="var(--md-sys-color-primary)" stopOpacity="0" />
        </linearGradient>
        <linearGradient id={`${id}-up`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--md-sys-color-trace)" stopOpacity=".16" />
          <stop offset="1" stopColor="var(--md-sys-color-trace)" stopOpacity="0" />
        </linearGradient>
      </defs>
      {[.25, .5, .75].map((fraction) => <line key={fraction} x1="8" x2={width - 8} y1={chartHeight * fraction} y2={chartHeight * fraction} stroke="var(--md-sys-color-outline-variant)" strokeDasharray="3 5" />)}
      {downPath ? <path d={`${downPath} L ${width - 8} ${chartHeight} L 8 ${chartHeight} Z`} fill={`url(#${id}-down)`} /> : null}
      {upPath ? <path d={`${upPath} L ${width - 8} ${chartHeight} L 8 ${chartHeight} Z`} fill={`url(#${id}-up)`} /> : null}
      <path d={downPath} fill="none" stroke="var(--md-sys-color-primary)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
      <path d={upPath} fill="none" stroke="var(--md-sys-color-trace)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
      {labels?.length ? <title>{labels.join(', ')}</title> : null}
    </svg>
  )
}
