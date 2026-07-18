import { cn } from '../../lib/cn'

export interface DonutSegment {
  name: string
  value: number
  color: string
}

export interface DonutChartProps {
  segments: DonutSegment[]
  height?: number
  width?: number | string
  centerLabel?: string
  className?: string
}

export function DonutChart({ segments, height = 90, width = '100%', centerLabel, className }: DonutChartProps) {
  const normalized = segments.map((segment) => ({ ...segment, value: Math.max(0, Number.isFinite(segment.value) ? segment.value : 0) }))
  const total = normalized.reduce((sum, segment) => sum + segment.value, 0)
  let offset = 0

  return (
    <div className={cn('relative', className)} style={{ height, width }} data-chart="donut">
      <svg viewBox="0 0 100 100" className="h-full w-full -rotate-90" role="img" aria-label={normalized.map((segment) => `${segment.name}: ${segment.value}`).join(', ')}>
        <circle cx="50" cy="50" r="39" fill="none" stroke="var(--md-sys-color-surface-container)" strokeWidth="13" />
        {total > 0 ? normalized.map((segment) => {
          const length = (segment.value / total) * 100
          const dashOffset = -offset
          offset += length
          return (
            <circle
              key={segment.name}
              cx="50"
              cy="50"
              r="39"
              pathLength="100"
              fill="none"
              stroke={segment.color}
              strokeWidth="13"
              strokeDasharray={`${Math.max(0, length - 1.2)} ${100 - Math.max(0, length - 1.2)}`}
              strokeDashoffset={dashOffset}
              strokeLinecap="round"
            >
              <title>{`${segment.name}: ${segment.value}`}</title>
            </circle>
          )
        }) : null}
      </svg>
      {centerLabel !== undefined ? (
        <span className="pointer-events-none absolute inset-0 flex items-center justify-center font-mono text-[12px] font-medium text-text-strong">
          {centerLabel}
        </span>
      ) : null}
    </div>
  )
}
