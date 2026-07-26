import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

export interface HBarRow {
  /** Category name, printed at the row's leading edge. */
  name: string
  /** Magnitude driving bar length. All rows share one scale (never two axes). */
  value: number
  /** Pre-formatted value printed at the row's trailing edge. */
  display: string
  /** Optional supporting line rendered under the bar. */
  meta?: ReactNode
}

export interface HBarChartProps {
  rows: HBarRow[]
  /**
   * Single hue for every bar: these encode a magnitude, not an identity, so a
   * categorical palette would burn a channel on information the length already
   * carries.
   */
  color?: string
  className?: string
}

/**
 * Smallest rendered fill for a non-zero value, as a percentage of the track.
 * A row that is tiny relative to the max must still read as "present but
 * small" rather than collapsing into the track and looking like no data.
 */
const MIN_VISIBLE_PCT = 1.5

/**
 * Labelled horizontal magnitude bars on one shared scale.
 *
 * Laid out in flow HTML rather than a fixed-viewBox SVG on purpose: the name,
 * the bar and the value share a row box, so a label can never drift out of
 * alignment with the mark it describes, and text is never scaled by a
 * `preserveAspectRatio` stretch.
 */
export function HBarChart({ rows, color = 'var(--color-primary)', className }: HBarChartProps) {
  const values = rows.map((row) => (Number.isFinite(row.value) ? Math.max(0, row.value) : 0))
  const max = Math.max(0, ...values)

  return (
    <div className={cn('flex flex-col gap-4', className)} data-chart="hbar">
      {rows.map((row, index) => {
        const value = values[index]
        const pct = max > 0 ? (value / max) * 100 : 0
        return (
          <div key={row.name}>
            <div className="flex items-baseline justify-between gap-3">
              <span className="truncate text-[12.5px] font-medium text-text-mid">{row.name}</span>
              <span className="shrink-0 font-mono text-[15px] font-medium tabular-nums text-text-strong">{row.display}</span>
            </div>
            <div
              className="mt-1.5 h-2 w-full overflow-hidden rounded-full bg-surface-container"
              role="img"
              aria-label={`${row.name}: ${row.display}`}
            >
              <div
                className="h-full rounded-full transition-[width] duration-500"
                style={{ width: `${value > 0 ? Math.max(MIN_VISIBLE_PCT, pct) : 0}%`, background: color }}
              />
            </div>
            {row.meta ? <div className="mt-1.5 text-[10.5px] text-text-faint">{row.meta}</div> : null}
          </div>
        )
      })}
    </div>
  )
}
