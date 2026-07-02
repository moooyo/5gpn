import type { Stats } from '../api'
import { REASON_LANES, REASON_ORDER, laneValue, type ReasonLane } from '../verdicts'
import { fmtInt } from '../format'

interface LaneBarProps {
  stats: Stats
  size?: 'hero' | 'mini'
}

/**
 * The signature element: a thin horizontal stacked bar showing how `total`
 * partitions across the five reason lanes (chnroute-cn / force-direct /
 * chnroute-foreign / blacklist / adblock), each in its lane color. `hero` size
 * is the Dashboard hero (with legend + per-lane counts); `mini` is the top-bar
 * strip. When `total` is 0 it shows an honest empty state rather than a blank
 * or divide-by-zero bar.
 */
export function VerdictLaneBar({ stats, size = 'hero' }: LaneBarProps) {
  const mini = size === 'mini'

  const values: Record<ReasonLane, number> = {
    'chnroute-cn': laneValue(stats, 'chnroute-cn'),
    'force-direct': laneValue(stats, 'force-direct'),
    'chnroute-foreign': laneValue(stats, 'chnroute-foreign'),
    blacklist: laneValue(stats, 'blacklist'),
    adblock: laneValue(stats, 'adblock'),
  }
  const sum = REASON_ORDER.reduce((a, l) => a + values[l], 0)
  const total = stats.total || sum
  const empty = total <= 0

  const pct = (n: number) => (total > 0 ? (n / total) * 100 : 0)

  const ariaLabel = empty
    ? 'No queries classified yet'
    : `Reason split of ${fmtInt(total)} queries: ` +
      REASON_ORDER.map((l) => `${fmtInt(values[l])} ${REASON_LANES[l].label.toLowerCase()}`).join(', ')

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
        aria-label={ariaLabel}
      >
        {!empty &&
          REASON_ORDER.map((lane) => {
            const w = pct(values[lane])
            if (w <= 0) return null
            return (
              <div
                key={lane}
                title={`${REASON_LANES[lane].label}: ${fmtInt(values[lane])}`}
                style={{
                  width: `${w}%`,
                  background: REASON_LANES[lane].color,
                  transition: 'width 400ms ease',
                }}
              />
            )
          })}
      </div>

      {!mini &&
        (empty ? (
          <div className="mt-3 font-mono text-xs" style={{ color: 'var(--muted)' }}>
            No queries classified yet — counts appear here once the resolver sees traffic.
          </div>
        ) : (
          <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2">
            {REASON_ORDER.map((lane) => (
              <div key={lane} className="flex items-center gap-2">
                <span
                  className="inline-block h-2.5 w-2.5 rounded-sm"
                  style={{ background: REASON_LANES[lane].color }}
                />
                <span className="eyebrow" style={{ letterSpacing: '0.1em' }}>
                  {REASON_LANES[lane].label}
                </span>
                <span className="font-mono text-sm" style={{ color: 'var(--text)' }}>
                  {fmtInt(values[lane])}
                </span>
                <span className="font-mono text-xs" style={{ color: 'var(--muted)' }}>
                  {`${pct(values[lane]).toFixed(1)}%`}
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
        ))}
    </div>
  )
}
