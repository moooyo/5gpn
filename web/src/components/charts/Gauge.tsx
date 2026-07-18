import { cn } from '../../lib/cn'
import { clamp } from './geometry'

export interface GaugeChartProps {
  value: number
  height?: number
  width?: number | string
  color?: string
  className?: string
  ariaLabel?: string
}

export function GaugeChart({ value, height = 140, width = '100%', color = 'var(--color-green)', className, ariaLabel = 'Percentage' }: GaugeChartProps) {
  const clamped = clamp(value, 0, 100)
  return (
    <div className={cn('relative', className)} style={{ height, width }} data-chart="gauge" role="meter" aria-label={ariaLabel} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(clamped)}>
      <svg viewBox="0 0 100 100" className="h-full w-full -rotate-90" aria-hidden="true">
        <circle cx="50" cy="50" r="38" fill="none" stroke="var(--md-sys-color-surface-container)" strokeWidth="12" />
        <circle
          cx="50"
          cy="50"
          r="38"
          pathLength="100"
          fill="none"
          stroke={color}
          strokeWidth="12"
          strokeDasharray={`${clamped} ${100 - clamped}`}
          strokeLinecap="round"
        />
      </svg>
      <span className="pointer-events-none absolute inset-0 flex items-center justify-center font-mono text-[21px] font-medium tracking-tight text-text-strong">
        {`${Math.round(clamped)}%`}
      </span>
    </div>
  )
}
