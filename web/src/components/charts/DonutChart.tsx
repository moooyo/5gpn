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

const RADIUS = 39
const STROKE = 13
/**
 * A 2px surface gap between adjacent arcs, expressed in the normalised
 * `pathLength="100"` units the dash array is written in.
 */
const GAP = (2 / (2 * Math.PI * RADIUS)) * 100

export function DonutChart({ segments, height = 90, width = '100%', centerLabel, className }: DonutChartProps) {
  const normalized = segments.map((segment) => ({ ...segment, value: Math.max(0, Number.isFinite(segment.value) ? segment.value : 0) }))
  const total = normalized.reduce((sum, segment) => sum + segment.value, 0)
  let offset = 0

  return (
    <div className={cn('relative', className)} style={{ height, width }} data-chart="donut">
      <svg viewBox="0 0 100 100" className="h-full w-full -rotate-90" role="img" aria-label={normalized.map((segment) => `${segment.name}: ${segment.value}`).join(', ')}>
        <circle cx="50" cy="50" r={RADIUS} fill="none" stroke="var(--md-sys-color-surface-container)" strokeWidth={STROKE} />
        {total > 0 ? normalized.map((segment) => {
          const length = (segment.value / total) * 100
          const dashOffset = -offset
          offset += length
          // A zero segment must draw nothing. Round caps would still paint a
          // full lozenge for it, so it is dropped outright rather than dashed
          // to zero.
          if (length <= 0) return null
          // Butt caps paint exactly `dash` units of arc; round caps would each
          // overhang by STROKE/2, adding ~5.3 points per segment and rendering
          // proportions that are not the data's. The separator is carved out
          // of the arc, and only when the arc can spare it — a sliver stays a
          // sliver instead of inverting into a gap.
          const dash = length > GAP * 2 ? length - GAP : length
          return (
            <circle
              key={segment.name}
              cx="50"
              cy="50"
              r={RADIUS}
              pathLength="100"
              fill="none"
              stroke={segment.color}
              strokeWidth={STROKE}
              strokeDasharray={`${dash} ${100 - dash}`}
              strokeDashoffset={dashOffset}
              strokeLinecap="butt"
            >
              <title>{`${segment.name}: ${segment.value}`}</title>
            </circle>
          )
        }) : null}
      </svg>
      {centerLabel !== undefined ? (
        <span className="pointer-events-none absolute inset-0 flex items-center justify-center font-mono text-label font-medium text-text-strong">
          {centerLabel}
        </span>
      ) : null}
    </div>
  )
}
