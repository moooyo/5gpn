import type { ReactNode } from 'react'
import { useCountUp, fmtInt } from '../format'

/** A titled surface card with an eyebrow label. */
export function Panel({
  eyebrow,
  title,
  right,
  children,
  className,
}: {
  eyebrow?: string
  title?: ReactNode
  right?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className={`panel panel-pad ${className ?? ''}`}>
      {(eyebrow || title || right) && (
        <header className="mb-4 flex items-start justify-between gap-4">
          <div>
            {eyebrow && <div className="eyebrow mb-1">{eyebrow}</div>}
            {title && (
              <h2 className="font-display text-lg font-semibold" style={{ color: 'var(--text)' }}>
                {title}
              </h2>
            )}
          </div>
          {right && <div className="flex items-center gap-2">{right}</div>}
        </header>
      )}
      {children}
    </section>
  )
}

/** A large animated stat readout: label + count-up mono number + optional sub. */
export function Stat({
  label,
  value,
  sub,
  color,
  animate = true,
}: {
  label: string
  value: number
  sub?: ReactNode
  color?: string
  animate?: boolean
}) {
  const shown = useCountUp(animate ? value : value)
  const n = animate ? Math.round(shown) : value
  return (
    <div>
      <div className="eyebrow mb-1.5">{label}</div>
      <div
        className="font-mono font-semibold tabular-nums"
        style={{ fontSize: 28, lineHeight: 1.1, color: color ?? 'var(--text)' }}
      >
        {fmtInt(n)}
      </div>
      {sub !== undefined && (
        <div className="mt-1 font-mono text-xs" style={{ color: 'var(--muted)' }}>
          {sub}
        </div>
      )}
    </div>
  )
}

/** A per-verdict horizontal micro-bar (used on the Stats view). */
export function MicroBar({
  label,
  value,
  max,
  color,
}: {
  label: string
  value: number
  max: number
  color: string
}) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between">
        <span className="eyebrow">{label}</span>
        <span className="font-mono text-sm tabular-nums">{fmtInt(value)}</span>
      </div>
      <div
        className="overflow-hidden rounded-full"
        style={{ height: 6, background: 'var(--surface-2)' }}
      >
        <div style={{ width: `${pct}%`, height: '100%', background: color, transition: 'width 500ms ease' }} />
      </div>
    </div>
  )
}
