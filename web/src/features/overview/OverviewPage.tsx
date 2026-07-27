import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { NetworkCheckIcon, RuleIcon, SpeedIcon } from '../../components/icons'
import { DonutChart, HBarChart, Sparkline, type DonutSegment, type HBarRow } from '../../components/charts'
import { Card, LiveToggle, StatusDot } from '../../components/ds'
import { useStatus } from '../../lib/StatusContext'
import { cn } from '../../lib/cn'
import { relativeTime } from '../../format'
import {
  arbitrationSegments,
  cacheHitRate,
  decisionCounts,
  deriveQps,
  estimateQps,
  pctDelta,
  pushCapped,
  upstreamHealth,
  upstreamSuccessRate,
  type QpsPoint,
  type UpstreamGroupHealth,
} from './metrics'

const SERIES_CAP = 48

/** One decimal + an explicit unit, shared by every place a group's average
 *  resolver round-trip is printed so the two never drift apart. */
function formatMs(ms: number): string {
  return `${ms.toFixed(1)} ms`
}

/** Two decimals, except an exact 100% which reads as "100%" rather than the
 *  falsely precise "100.00%". */
function formatRate(rate: number): string {
  return rate === 100 ? '100%' : `${rate.toFixed(2)}%`
}

function Metric({
  label,
  value,
  supporting,
  accent,
  meterValue,
}: {
  label: string
  value: string
  supporting?: string
  accent?: boolean
  meterValue?: number
}) {
  return (
    <Card
      variant="tonal"
      className="flex min-h-[116px] flex-col justify-between p-4.5"
      {...(meterValue === undefined ? {} : {
        role: 'meter',
        'aria-label': label,
        'aria-valuemin': 0,
        'aria-valuemax': 100,
        'aria-valuenow': meterValue,
      })}
    >
      <span className="text-label font-medium text-text-soft">{label}</span>
      <div>
        <span className={cn('font-mono text-metric font-medium tracking-[-.03em]', accent ? 'text-primary' : 'text-text-strong')}>{value}</span>
        {supporting ? <div className="mt-1 text-meta text-text-faint">{supporting}</div> : null}
      </div>
    </Card>
  )
}

function TraceNode({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <div className="zds-trace-node">
      <span className="zds-trace-dot">{icon}</span>
      <span className="text-label font-medium text-text-mid">{label}</span>
      <span className="font-mono text-meta text-text-faint">{value}</span>
    </div>
  )
}

/**
 * Supporting line under one upstream group's latency bar: health as a rate plus
 * an absolute failure count, rather than a second bar. Errors here run a few
 * against tens of thousands, so an error bar sharing the success bar's linear
 * scale is sub-pixel — invisible, yet still taking layout space.
 */
function UpstreamMeta({
  group,
  formatter,
}: {
  group: UpstreamGroupHealth
  formatter: Intl.NumberFormat
}) {
  const { t } = useTranslation()
  const rate = upstreamSuccessRate(group)
  const failed = group.err
  return (
    <span className="flex flex-wrap items-center gap-x-1.5 gap-y-1">
      <StatusDot color={failed > 0 ? 'var(--color-amber)' : 'var(--color-green)'} />
      <span>
        {rate === null
          ? t('overview.upstreamSuccessRateUnknown')
          : t('overview.upstreamSuccessRate', { rate: formatRate(rate) })}
      </span>
      <span aria-hidden="true">·</span>
      <span>
        {group.latSamples > 0
          ? t('overview.upstreamP95', { value: formatMs(group.p95Ms), n: formatter.format(group.latSamples) })
          : t('overview.upstreamNoSamples')}
      </span>
      <span aria-hidden="true">·</span>
      <span>{t('overview.upstreamExchanges', { n: formatter.format(group.ok + group.err) })}</span>
      <span aria-hidden="true">·</span>
      <span style={failed > 0 ? { color: 'var(--color-red)' } : undefined}>
        {t('overview.upstreamFailures', { n: formatter.format(failed) })}
      </span>
    </span>
  )
}

export default function OverviewPage() {
  const { t, i18n } = useTranslation()
  const { status, statusUpdatedAt, statusStale } = useStatus()
  const [live, setLive] = useState(true)
  const previousPoint = useRef<QpsPoint | null>(null)
  const [qpsSeries, setQpsSeries] = useState<number[]>([])
  const [qpsNow, setQpsNow] = useState(0)
  // Re-render on a timer so "updated 2s ago" keeps counting up even while the
  // payload itself is unchanged — a frozen relative time is the same lie as no
  // relative time at all.
  const [, setTick] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setTick((value) => value + 1), 1000)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    if (!live || !status?.stats) return
    const next: QpsPoint = { total: status.stats.total, at: Date.now() }
    const derived = previousPoint.current ? deriveQps(previousPoint.current, next) : null
    const qps = derived ?? estimateQps(next.total, status.uptime_seconds)
    previousPoint.current = next
    setQpsNow(Math.round(qps))
    setQpsSeries((series) => pushCapped(series, Math.round(qps), SERIES_CAP))
  }, [live, status?.stats?.total, status?.uptime_seconds])

  const counts = useMemo(() => decisionCounts(status?.stats), [status?.stats])
  // Fixed slot per decision, never by rank — a reader who learned "国内直连 is
  // slot 4" must see the same hue in the chnroute split below, which breaks
  // out the arbitration half of these very counters.
  const decisionSegments: DonutSegment[] = useMemo(() => [
    { name: t('decision.block'), value: counts.block, color: 'var(--color-chart-1)' },
    { name: t('decision.forceDirect'), value: counts.forceDirect, color: 'var(--color-chart-2)' },
    { name: t('decision.forceProxy'), value: counts.forceProxy, color: 'var(--color-chart-3)' },
    { name: t('decision.chnrouteCn'), value: counts.chnrouteCn, color: 'var(--color-chart-4)' },
    { name: t('decision.chnrouteForeign'), value: counts.chnrouteForeign, color: 'var(--color-chart-5)' },
  ], [counts, t])
  const decisionTotal = decisionSegments.reduce((sum, segment) => sum + segment.value, 0)
  const hitRate = cacheHitRate(status?.stats)
  const health = upstreamHealth(status?.stats)
  const arbitration = arbitrationSegments(status?.stats)
  const arbitrationTotal = arbitration.cn + arbitration.foreign
  const arbitrationCnPct = arbitrationTotal > 0 ? Math.round((arbitration.cn / arbitrationTotal) * 100) : 0
  const formatter = useMemo(() => new Intl.NumberFormat(i18n.language), [i18n.language])
  // One row per upstream group, both bars on a single shared ms scale so
  // "which leg is slower" is readable at a glance without a second axis.
  const upstreamRows: HBarRow[] = [
    { name: t('overview.upstreamHealthChina'), group: health.china },
    { name: t('overview.upstreamHealthTrust'), group: health.trust },
  ].map(({ name, group }) => ({
    name,
    // The bar encodes the median: it is what a typical query costs, and the
    // one an operator compares between groups. p95 rides alongside as text
    // rather than as a second bar, so the two are never read as series.
    value: group.p50Ms,
    display: group.latSamples > 0 ? formatMs(group.p50Ms) : t('overview.upstreamNoSamples'),
    meta: <UpstreamMeta group={group} formatter={formatter} />,
  }))
  const delta = pctDelta(qpsSeries)
  const gatewayCount = counts.forceProxy + counts.chnrouteForeign
  const qpsRange = qpsSeries.length > 0
    ? { min: Math.min(...qpsSeries), max: Math.max(...qpsSeries) }
    : null

  return (
    <div className="flex flex-col gap-4" data-testid="page-overview">
      <div className="flex flex-wrap items-center gap-3 px-1">
        <p className="min-w-[220px] flex-1 text-label text-text-faint">{t('overview.intro')}</p>
        {/* Freshness beside the live pill. Pausing or a failing poll used to
            leave the numbers sitting there looking current. */}
        <span
          data-testid="overview-freshness"
          className={cn('text-meta font-medium', statusStale ? 'text-red' : 'text-text-faint')}
        >
          {statusStale
            ? t('overview.pollFailed')
            : statusUpdatedAt
              ? t('overview.updatedAt', { time: relativeTime(new Date(statusUpdatedAt).toISOString()) })
              : t('common.loading')}
        </span>
        <LiveToggle
          live={live}
          onToggle={() => setLive((current) => !current)}
          liveLabel={t('overview.live')}
          // Pausing stops recomputing QPS from the shared status poll; the
          // freshness line beside this says how old the numbers then are.
          pausedLabel={t('overview.paused')}
          pauseAction={t('overview.pause')}
          resumeAction={t('overview.resume')}
        />
      </div>

      {/* QPS is drawn once. It used to appear both here and in a full-size card
          below — the same series, the same number, twice on one screen. */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Card variant="hero" className="min-h-[150px] overflow-hidden p-5 sm:col-span-2">
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-body font-medium">{t('overview.qpsLive')}</div>
              <div className="mt-2 flex items-baseline gap-2">
                <span className="font-mono text-hero font-medium leading-none tracking-[-.05em]">{qpsNow}</span>
              </div>
            </div>
            {delta !== null ? (
              <span className="rounded-pill bg-[rgb(255_255_255_/_35%)] px-3 py-1 font-mono text-meta font-medium">
                {`${delta >= 0 ? '+' : ''}${delta.toFixed(1)}%`}
              </span>
            ) : null}
          </div>
          <Sparkline
            data={qpsSeries.length > 0 ? qpsSeries : [0, 0]}
            color="var(--md-sys-color-on-primary-container)"
            height={56}
            className="mt-4"
          />
          {/* A sparkline with no window and no y range is a shape, not a
              measurement. Both are one line of text. */}
          <div className="mt-2 flex flex-wrap items-baseline justify-between gap-x-3 text-meta opacity-80">
            <span>{t('overview.qpsWindow', { count: qpsSeries.length, cap: SERIES_CAP })}</span>
            {qpsRange ? <span className="font-mono">{`${qpsRange.min} – ${qpsRange.max}`}</span> : null}
          </div>
        </Card>
        <Metric label={t('overview.totalQueries')} value={formatter.format(status?.stats?.total ?? 0)} supporting={t('overview.sinceStartup')} accent />
        <Metric
          label={t('overview.cacheHitRate')}
          value={`${hitRate.toFixed(1)}%`}
          supporting={`${formatter.format(status?.stats?.cache_hits ?? 0)} / ${formatter.format((status?.stats?.cache_hits ?? 0) + (status?.stats?.cache_misses ?? 0))}`}
          meterValue={hitRate}
        />
      </div>

      <Card variant="tonal" className="p-5 sm:p-6">
        <div className="mb-5 flex items-baseline justify-between gap-3">
          <div>
            <h2 className="text-title font-medium text-text-strong">{t('overview.traceTitle')}</h2>
            <p className="mt-1 text-label text-text-faint">{t('overview.traceDescription')}</p>
          </div>
          <span className="hidden rounded-pill bg-secondary-container px-3 py-1 font-mono text-meta text-on-secondary-container sm:inline">/api/status</span>
        </div>
        <div className="zds-trace-rail [--trace-steps:3]">
          <TraceNode icon={<NetworkCheckIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceQuery')} value={formatter.format(status?.stats?.total ?? 0)} />
          <TraceNode icon={<RuleIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceDecision')} value={formatter.format(decisionTotal)} />
          <TraceNode icon={<SpeedIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceGateway')} value={formatter.format(gatewayCount)} />
        </div>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="p-5">
          <h2 className="mb-4 text-title font-medium text-text-strong">{t('overview.decisionDistribution')}</h2>
          <div className="flex items-center gap-5">
            <DonutChart segments={decisionSegments} height={132} width={132} centerLabel={formatter.format(decisionTotal)} className="shrink-0" />
            <div className="flex min-w-0 flex-1 flex-col gap-2.5">
              {decisionSegments.map((segment) => (
                <div key={segment.name} className="flex items-center gap-2">
                  <span className="zds-swatch shrink-0" style={{ background: segment.color }} />
                  <span className="min-w-0 flex-1 truncate text-label text-text-mid">{segment.name}</span>
                  <span className="font-mono text-meta text-text-faint">{decisionTotal > 0 ? `${Math.round((segment.value / decisionTotal) * 100)}%` : '0%'}</span>
                </div>
              ))}
            </div>
          </div>
          {/* The CN/foreign split was a second donut of its own, which is only
              ever segments 4 and 5 of the ring above magnified. As a bar under
              that ring it keeps the same two slots and stops competing with it
              for the reading of "what does this resolver decide". */}
          <div className="mt-5 border-t border-divider pt-4" data-testid="overview-arbitration">
            <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <span className="text-label font-medium text-text-soft">{t('overview.arbitration')}</span>
              <span className="font-mono text-meta text-text-faint">{t('overview.arbitrationCount', { n: formatter.format(arbitrationTotal) })}</span>
            </div>
            <div className="mt-2 flex h-2.5 overflow-hidden rounded-pill bg-surface-container">
              <span style={{ width: `${arbitrationCnPct}%`, background: 'var(--color-chart-4)' }} />
              <span style={{ width: `${100 - arbitrationCnPct}%`, background: 'var(--color-chart-5)' }} />
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-meta text-text-faint">
              <span className="flex items-center gap-1.5">
                <span className="zds-swatch h-2 w-2" style={{ background: 'var(--color-chart-4)' }} />
                {t('overview.arbitrationCn')} {arbitrationTotal > 0 ? `${arbitrationCnPct}%` : '—'}
              </span>
              <span className="flex items-center gap-1.5">
                <span className="zds-swatch h-2 w-2" style={{ background: 'var(--color-chart-5)' }} />
                {t('overview.arbitrationForeign')} {arbitrationTotal > 0 ? `${100 - arbitrationCnPct}%` : '—'}
              </span>
            </div>
          </div>
        </Card>

        <Card className="p-5">
          <div className="mb-1 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 className="text-title font-medium text-text-strong">{t('overview.upstreamHealth')}</h2>
            <span className="rounded-pill bg-secondary-container px-2.5 py-0.5 text-meta text-on-secondary-container">
              {t('overview.upstreamLatencyScope')}
            </span>
          </div>
          <p className="mb-4 text-label leading-relaxed text-text-faint">{t('overview.upstreamLatencyHint')}</p>
          {/* The P50 used to be a fourth metric tile up top AND the bar here.
              One number, one place — and this is the place, because the bar row
              already carries the name and the value beside the scale that makes
              them mean something. A headline row above it was the same
              duplication moved down the page rather than removed. */}
          <HBarChart rows={upstreamRows} />
          <p className="mt-4 text-meta leading-relaxed text-text-faint">
            {t('overview.upstreamMeasured')} {t('overview.upstreamTrustNote')}
          </p>
        </Card>
      </div>
    </div>
  )
}
