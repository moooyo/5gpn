import { useId } from 'react'
import { cn } from '../../lib/cn'
import { chartPoints, linePath } from './geometry'

export interface SparklineProps {
  data: number[]
  color: string
  height?: number
  className?: string
}

export function Sparkline({ data, color, height = 32, className }: SparklineProps) {
  const gradientId = useId().replace(/:/g, '')
  const width = 240
  const points = chartPoints(data, width, height)
  const line = linePath(points)
  const first = points[0]
  const last = points.at(-1)
  const area = first && last ? `${line} L ${last.x.toFixed(2)} ${height} L ${first.x.toFixed(2)} ${height} Z` : ''

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      className={cn('block w-full', className)}
      style={{ height }}
      aria-hidden="true"
      data-chart="sparkline"
    >
      <defs>
        <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={color} stopOpacity=".22" />
          <stop offset="1" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      {area ? <path d={area} fill={`url(#${gradientId})`} /> : null}
      {line ? <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" /> : null}
      {last ? <circle cx={last.x} cy={last.y} r="2.5" fill={color} /> : null}
    </svg>
  )
}
