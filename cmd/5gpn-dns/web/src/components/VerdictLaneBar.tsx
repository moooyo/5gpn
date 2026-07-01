import type { Stats } from '../api'
import { BAR_LANES, LANES, type Lane } from '../verdicts'
import { fmtInt } from '../format'

interface LaneBarProps {
  stats: Stats
  size?: 'hero' | 'mini'
}

/**
 * The signature element: a thin horizontal stacked bar showing the proportion
 * of direct / proxy / block out of total, in the lane colors. `hero` size is
 * the Dashboard hero (with legend + counts); `mini` is the top-bar strip.
 */
export function VerdictLaneBar({ stats, size = 'hero' }: LaneBarProps) {
  const values: Record<Lane, number> = {
    direct: stats.direct,
    proxy: stats.proxy,
    block: stats.block,
    adblock: 0,
  }
  const sum = BAR_LANES.reduce((a, l) => a + values[l], 0)
  const total = stats.total || sum

  const pct = (n: number) => (total > 0 ? (n / total) * 100 : 0)
  const mini = size === 'mini'

  return (
    <div className={mini ? 'w-40' : 'w-full'}>
      <div
        className="flex overflow-hidden rounded-full"
        style={{
          height: mini ? 8 : 16,
          background: 'var(--surface-2)',
          border: '1px solid var(--border)',
        }}
        role="img"
        aria-label={`Verdict split: ${stats.direct} direct, ${stats.proxy} proxy, ${stats.block} block, of ${total} total`}
      >
        {BAR_LANES.map((lane) => {
          const w = pct(values[lane])
          if (w <= 0) return null
          return (
            <div
              key={lane}
              title={`${LANES[lane].label}: ${fmtInt(values[lane])}`}
              style={{
                width: `${w}%`,
                background: LANES[lane].color,
                transition: 'width 400ms ease',
              }}
            />
          )
        })}
      </div>

      {!mini && (
        <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2">
          {BAR_LANES.map((lane) => (
            <div key={lane} className="flex items-center gap-2">
              <span
                className="inline-block h-2.5 w-2.5 rounded-sm"
                style={{ background: LANES[lane].color }}
              />
              <span className="eyebrow" style={{ letterSpacing: '0.1em' }}>
                {LANES[lane].label}
              </span>
              <span className="font-mono text-sm" style={{ color: 'var(--text)' }}>
                {fmtInt(values[lane])}
              </span>
              <span className="font-mono text-xs" style={{ color: 'var(--muted)' }}>
                {total > 0 ? `${pct(values[lane]).toFixed(1)}%` : '—'}
              </span>
            </div>
          ))}
          <div className="flex items-center gap-2">
            <span className="eyebrow" style={{ letterSpacing: '0.1em' }}>
              Total
            </span>
            <span className="font-mono text-sm">{fmtInt(total)}</span>
          </div>
        </div>
      )}
    </div>
  )
}
