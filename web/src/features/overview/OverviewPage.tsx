import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Card, StatusDot } from '../../components/ds'
import { BarChart, DonutChart, GaugeChart, Sparkline, type DonutSegment } from '../../components/charts'
import { useStatus } from '../../lib/StatusContext'
import { cn } from '../../lib/cn'
import {
  arbitrationSegments,
  cacheHitRate,
  decisionCounts,
  deriveQps,
  estimateQps,
  pctDelta,
  pushCapped,
  upstreamHealth,
  type QpsPoint,
} from './metrics'

const SERIES_CAP = 48

interface DeltaBadge {
  text: string
  color: string
}

function deltaFor(series: number[]): DeltaBadge | null {
  const pct = pctDelta(series)
  if (pct === null) return null
  return {
    text: `${pct >= 0 ? '+' : ''}${pct.toFixed(1)}%`,
    color: pct >= 0 ? '#16a34a' : '#dc2626',
  }
}

// ---- QPS metric card --------------------------------------------------------

interface MetricCardProps {
  label: string
  color: string
  unit?: string
  value?: string
  series: number[]
  delta?: DeltaBadge | null
}

function MetricCard({ label, color, unit, value, series, delta }: MetricCardProps) {
  return (
    <Card className="p-[15px_16px]">
      <div className="flex items-start justify-between gap-2">
        <div className="flex items-center gap-1.5">
          <span className="text-[12px] font-semibold text-text-soft">{label}</span>
        </div>
        {delta ? (
          <span className="text-[11px] font-bold" style={{ color: delta.color }}>
            {delta.text}
          </span>
        ) : null}
      </div>
      <div className="mt-2.5 flex items-baseline gap-1">
        <span className="font-mono text-[28px] font-extrabold tracking-tight" style={{ color }}>
          {value}
        </span>
        {unit ? <span className="text-[11px] text-text-faint">{unit}</span> : null}
      </div>
      <Sparkline data={series.length > 0 ? series : [0, 0]} color={color} height={32} className="mt-2 block" />
    </Card>
  )
}

/** 仪表盘 (Overview/Dashboard) — task 5.2, trimmed in B3. Sources `/api/stats`
 *  via the shared StatusContext: QPS (derived client-side as Δtotal/Δt across
 *  polls) and the 决策分布 donut (the 5 verdict counters). The former
 *  current-exit card (the removed exit-selector fetch + the shared default-exit store) and
 *  traffic-preview cards (getTraffic()) were dropped in B3 — SP-2 removed
 *  their backend endpoints (`/api/exits`, `/api/traffic`, `/api/nodes`) and
 *  egress switching is now the operator's raw mihomo config (UP-4, which also
 *  removed the console's own egress feature); mihomo traffic/connections move
 *  to zashboard (deep ops), not this page. A single live/pause toggle (A-L3)
 *  stops/starts the client-side QPS derivation.
 *
 *  "A档" charts (below the 决策分布 row): 缓存命中率 gauge, 上游健康与延迟
 *  bar chart, and a focused 境内/境外分流比 donut — all LIVE SNAPSHOTS
 *  recomputed from `status.stats` every render (same as 决策分布 above), not
 *  tied to the `live`/pause QPS series. No new backend fields. */
export default function OverviewPage() {
  const { t } = useTranslation()
  const { status } = useStatus()

  const [live, setLive] = useState(true)

  // ---- LIVE: QPS derived from /api/stats's monotonic `total` counter ------
  const prevPointRef = useRef<QpsPoint | null>(null)
  const [qpsSeries, setQpsSeries] = useState<number[]>([])
  const [qpsNow, setQpsNow] = useState(0)

  useEffect(() => {
    if (!live) return
    const stats = status?.stats
    if (!stats) return
    const next: QpsPoint = { total: stats.total, at: Date.now() }
    const prev = prevPointRef.current
    const delta = prev ? deriveQps(prev, next) : null
    const qps = delta ?? estimateQps(next.total, status?.uptime_seconds ?? 0)
    prevPointRef.current = next
    setQpsNow(Math.round(qps))
    setQpsSeries((s) => pushCapped(s, Math.round(qps), SERIES_CAP))
  }, [status?.stats?.total, status?.uptime_seconds, live])

  // ---- 决策分布 (LIVE, from /api/stats verdict counters) -------------------
  const decisionSegments: DonutSegment[] = useMemo(() => {
    const c = decisionCounts(status?.stats)
    return [
      { name: t('overview.decision.block'), value: c.block, color: '#dc2626' },
      { name: t('overview.decision.forceDirect'), value: c.forceDirect, color: '#16a34a' },
      { name: t('overview.decision.blacklist'), value: c.blacklist, color: '#2563eb' },
      { name: t('overview.decision.chnrouteCn'), value: c.chnrouteCn, color: '#0891b2' },
      // Distinct indigo, NOT the A-H1 log/resolve-test mapping's blue
      // (#2563eb, same as 强制代理/blacklist there — disambiguated by label
      // text in that table) and NOT the former traffic-trend card's upload
      // cyan (#38bdf8, dropped in B3). The donut has no per-wedge label, so
      // its 5 segments need 5 visually distinct colors by design.
      { name: t('overview.decision.chnrouteForeign'), value: c.chnrouteForeign, color: '#6366f1' },
    ]
  }, [status?.stats, t])
  const decisionTotal = decisionSegments.reduce((sum, seg) => sum + seg.value, 0)

  // ---- 缓存命中率 (LIVE, from /api/stats cache_hits/cache_misses) ----------
  const hitRatePct = useMemo(() => cacheHitRate(status?.stats), [status?.stats])

  // ---- 上游健康与延迟 (LIVE, china vs trust ok/err counts + avg latency) ---
  const health = useMemo(() => upstreamHealth(status?.stats), [status?.stats])

  // ---- 境内/境外分流比 (LIVE, chnroute arbitration outcome only) ----------
  const arbitrationDonutSegments: DonutSegment[] = useMemo(() => {
    const a = arbitrationSegments(status?.stats)
    return [
      // Same colors as the matching wedges in 决策分布 above (#0891b2/#6366f1)
      // so the two donuts read as the same category across cards.
      { name: t('overview.arbitrationCn'), value: a.cn, color: '#0891b2' },
      { name: t('overview.arbitrationForeign'), value: a.foreign, color: '#6366f1' },
    ]
  }, [status?.stats, t])
  const arbitrationTotal = arbitrationDonutSegments.reduce((sum, seg) => sum + seg.value, 0)

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-overview">
      <div className="flex items-center justify-between gap-2">
        <p className="text-[12px] text-text-faint">{t('overview.intro')}</p>
        <button
          type="button"
          onClick={() => setLive((v) => !v)}
          aria-label={live ? t('overview.pause') : t('overview.resume')}
          className={cn(
            'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1.5 text-[11px] font-bold',
            live ? 'bg-green/10 text-green' : 'bg-divider text-text-soft',
          )}
        >
          <StatusDot color={live ? '#16a34a' : '#93a2bd'} pulse={live} />
          {live ? t('overview.live') : t('overview.paused')}
        </button>
      </div>

      <div className="grid grid-cols-1 gap-4">
        <MetricCard
          label={t('overview.qps')}
          color="#6366f1"
          value={String(qpsNow)}
          series={qpsSeries}
          delta={deltaFor(qpsSeries)}
        />
      </div>

      <div className="grid grid-cols-2 gap-4">
        <Card className="p-[15px_17px]">
          <div className="flex items-center justify-between">
            <span className="text-[13px] font-bold text-text-strong">{t('overview.qpsLive')}</span>
            <span className="font-mono text-[22px] font-extrabold tracking-tight text-[#6366f1]">{qpsNow}</span>
          </div>
          <Sparkline data={qpsSeries.length > 0 ? qpsSeries : [0, 0]} color="#6366f1" height={96} className="mt-2 block" />
        </Card>

        <Card className="p-[15px_17px]">
          <div className="mb-2.5 text-[13px] font-bold text-text-strong">{t('overview.decisionDistribution')}</div>
          <div className="flex items-center gap-3">
            <DonutChart segments={decisionSegments} height={86} width={86} centerLabel={String(decisionTotal)} className="shrink-0" />
            <div className="flex min-w-0 flex-1 flex-col gap-1.5 text-[10.5px]">
              {decisionSegments.map((seg) => (
                <div key={seg.name} className="flex items-center gap-1.5">
                  <span className="h-[7px] w-[7px] shrink-0 rounded-[2px]" style={{ background: seg.color }} />
                  <span className="min-w-0 flex-1 truncate font-semibold text-text-mid">{seg.name}</span>
                  <span className="shrink-0 text-text-faint">{decisionTotal > 0 ? `${Math.round((seg.value / decisionTotal) * 100)}%` : '0%'}</span>
                </div>
              ))}
            </div>
          </div>
        </Card>
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <Card className="p-[15px_17px]">
          <div className="mb-2.5 text-[13px] font-bold text-text-strong">{t('overview.cacheHitRate')}</div>
          <GaugeChart value={hitRatePct} height={128} color="#16a34a" />
        </Card>

        <Card className="p-[15px_17px]">
          <div className="mb-2.5 flex items-center justify-between gap-2">
            <span className="text-[13px] font-bold text-text-strong">{t('overview.upstreamHealth')}</span>
            <div className="flex items-center gap-2 text-[10.5px] text-text-faint">
              <span className="flex items-center gap-1">
                <span className="h-[7px] w-[7px] rounded-[2px] bg-green" />
                {t('overview.upstreamHealthOk')}
              </span>
              <span className="flex items-center gap-1">
                <span className="h-[7px] w-[7px] rounded-[2px] bg-red" />
                {t('overview.upstreamHealthErr')}
              </span>
            </div>
          </div>
          <BarChart
            categories={[t('overview.upstreamHealthChina'), t('overview.upstreamHealthTrust')]}
            series={[
              { name: t('overview.upstreamHealthOk'), data: [health.china.ok, health.trust.ok], color: '#16a34a' },
              { name: t('overview.upstreamHealthErr'), data: [health.china.err, health.trust.err], color: '#dc2626' },
            ]}
            height={104}
          />
          <div className="mt-2 grid grid-cols-2 text-[10.5px] text-text-faint">
            <span className="text-center">
              {t('overview.upstreamHealthChina')} · {t('overview.upstreamHealthLatency')}{' '}
              <span className="font-mono font-semibold text-text-mid">{health.china.avgMs.toFixed(1)}ms</span>
            </span>
            <span className="text-center">
              {t('overview.upstreamHealthTrust')} · {t('overview.upstreamHealthLatency')}{' '}
              <span className="font-mono font-semibold text-text-mid">{health.trust.avgMs.toFixed(1)}ms</span>
            </span>
          </div>
        </Card>

        <Card className="p-[15px_17px]">
          <div className="mb-2.5 text-[13px] font-bold text-text-strong">{t('overview.arbitration')}</div>
          <div className="flex items-center gap-3">
            <DonutChart
              segments={arbitrationDonutSegments}
              height={86}
              width={86}
              centerLabel={String(arbitrationTotal)}
              className="shrink-0"
            />
            <div className="flex min-w-0 flex-1 flex-col gap-1.5 text-[10.5px]">
              {arbitrationDonutSegments.map((seg) => (
                <div key={seg.name} className="flex items-center gap-1.5">
                  <span className="h-[7px] w-[7px] shrink-0 rounded-[2px]" style={{ background: seg.color }} />
                  <span className="min-w-0 flex-1 truncate font-semibold text-text-mid">{seg.name}</span>
                  <span className="shrink-0 text-text-faint">
                    {arbitrationTotal > 0 ? `${Math.round((seg.value / arbitrationTotal) * 100)}%` : '0%'}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </Card>
      </div>
    </div>
  )
}
