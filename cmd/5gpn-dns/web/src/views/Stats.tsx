import { useEffect, useState } from 'react'
import { api, type Stats } from '../api'
import { Panel, MicroBar } from '../components/ui'
import { Loading, ErrorNotice } from '../components/states'
import { REASON_LANES, REASON_ORDER, laneValue } from '../verdicts'
import { fmtInt, successRatio } from '../format'

export function StatsView() {
  const [stats, setStats] = useState<Stats | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const tick = () => {
      api
        .stats()
        .then((s) => {
          if (!cancelled) {
            setStats(s)
            setError(null)
          }
        })
        .catch((e) => {
          if (!cancelled) setError(e.message)
        })
    }
    tick()
    const id = window.setInterval(tick, 5000)
    return () => {
      cancelled = true
      window.clearInterval(id)
    }
  }, [])

  if (error && !stats) return <ErrorNotice message={error} />
  if (!stats) return <Loading label="Reading counters…" />

  // Largest reason lane sets the scale for the per-lane micro-bars.
  const laneMax = Math.max(...REASON_ORDER.map((l) => laneValue(stats, l)), 1)

  const readouts: { label: string; value: number; color?: string }[] = [
    { label: 'Total', value: stats.total },
    ...REASON_ORDER.map((l) => ({
      label: REASON_LANES[l].label,
      value: laneValue(stats, l),
      color: REASON_LANES[l].color,
    })),
    { label: 'Cache entries', value: stats.cache_entries },
    { label: 'China ok', value: stats.china_ok, color: 'var(--v-direct)' },
    { label: 'China err', value: stats.china_err, color: 'var(--v-block)' },
    { label: 'Trust ok', value: stats.trust_ok, color: 'var(--v-direct)' },
    { label: 'Trust err', value: stats.trust_err, color: 'var(--v-block)' },
  ]

  return (
    <div className="flex flex-col gap-4">
      <Panel eyebrow="Counters" title="Engine readouts">
        <div className="grid grid-cols-2 gap-x-6 gap-y-5 sm:grid-cols-3 lg:grid-cols-4">
          {readouts.map((r) => (
            <div key={r.label}>
              <div className="eyebrow mb-1">{r.label}</div>
              <div
                className="font-mono text-2xl font-semibold tabular-nums"
                style={{ color: r.color ?? 'var(--text)' }}
              >
                {fmtInt(r.value)}
              </div>
            </div>
          ))}
        </div>
      </Panel>

      <Panel eyebrow="Reasons" title="Per-reason distribution">
        {stats.total <= 0 ? (
          <div className="font-mono text-xs" style={{ color: 'var(--muted)' }}>
            No queries classified yet — bars appear here once the resolver sees traffic.
          </div>
        ) : (
          <div className="flex flex-col gap-4">
            {REASON_ORDER.map((l) => (
              <MicroBar
                key={l}
                label={REASON_LANES[l].label}
                value={laneValue(stats, l)}
                max={laneMax}
                color={REASON_LANES[l].color}
              />
            ))}
          </div>
        )}
      </Panel>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Panel eyebrow="Upstream" title="China success">
          <div className="font-mono text-3xl font-semibold">
            {successRatio(stats.china_ok, stats.china_err)}
          </div>
          <div className="mt-1 font-mono text-xs" style={{ color: 'var(--muted)' }}>
            {fmtInt(stats.china_ok)} ok · {fmtInt(stats.china_err)} err
          </div>
        </Panel>
        <Panel eyebrow="Upstream" title="Trust success">
          <div className="font-mono text-3xl font-semibold">
            {successRatio(stats.trust_ok, stats.trust_err)}
          </div>
          <div className="mt-1 font-mono text-xs" style={{ color: 'var(--muted)' }}>
            {fmtInt(stats.trust_ok)} ok · {fmtInt(stats.trust_err)} err
          </div>
        </Panel>
      </div>
    </div>
  )
}
