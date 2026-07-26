import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { NetworkCheckIcon, RuleIcon, SpeedIcon } from '../../components/icons'
import { DonutChart, HBarChart, Sparkline, type DonutSegment, type HBarRow } from '../../components/charts'
import { Card, StatusDot } from '../../components/ds'
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
      <span className="text-[12px] font-medium text-text-soft">{label}</span>
      <div>
        <span className={cn('font-mono text-[26px] font-medium tracking-[-.03em]', accent ? 'text-primary' : 'text-text-strong')}>{value}</span>
        {supporting ? <div className="mt-1 text-[10.5px] text-text-faint">{supporting}</div> : null}
      </div>
    </Card>
  )
}

function TraceNode({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <div className="zds-trace-node">
      <span className="zds-trace-dot">{icon}</span>
      <span className="text-[11.5px] font-medium text-text-mid">{label}</span>
      <span className="font-mono text-[10.5px] text-text-faint">{value}</span>
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
  const { status } = useStatus()
  const [live, setLive] = useState(true)
  const previousPoint = useRef<QpsPoint | null>(null)
  const [qpsSeries, setQpsSeries] = useState<number[]>([])
  const [qpsNow, setQpsNow] = useState(0)

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
  // slot 4" must see the same hue in the arbitration card below, which plots
  // the chnroute-only half of these very counters.
  const decisionSegments: DonutSegment[] = useMemo(() => [
    { name: t('overview.decision.block'), value: counts.block, color: 'var(--color-chart-1)' },
    { name: t('overview.decision.forceDirect'), value: counts.forceDirect, color: 'var(--color-chart-2)' },
    { name: t('overview.decision.forceProxy'), value: counts.forceProxy, color: 'var(--color-chart-3)' },
    { name: t('overview.decision.chnrouteCn'), value: counts.chnrouteCn, color: 'var(--color-chart-4)' },
    { name: t('overview.decision.chnrouteForeign'), value: counts.chnrouteForeign, color: 'var(--color-chart-5)' },
  ], [counts, t])
  const decisionTotal = decisionSegments.reduce((sum, segment) => sum + segment.value, 0)
  const hitRate = cacheHitRate(status?.stats)
  const health = upstreamHealth(status?.stats)
  const arbitration = arbitrationSegments(status?.stats)
  const arbitrationSegmentsView: DonutSegment[] = [
    { name: t('overview.arbitrationCn'), value: arbitration.cn, color: 'var(--color-chart-4)' },
    { name: t('overview.arbitrationForeign'), value: arbitration.foreign, color: 'var(--color-chart-5)' },
  ]
  const arbitrationTotal = arbitration.cn + arbitration.foreign
  const formatter = useMemo(() => new Intl.NumberFormat(i18n.language), [i18n.language])
  // One row per upstream group, both bars on a single shared ms scale so
  // "which leg is slower" is readable at a glance without a second axis.
  const upstreamRows: HBarRow[] = [
    { name: t('overview.upstreamHealthChina'), group: health.china },
    { name: t('overview.upstreamHealthTrust'), group: health.trust },
  ].map(({ name, group }) => ({
    name,
    value: group.avgMs,
    display: formatMs(group.avgMs),
    meta: <UpstreamMeta group={group} formatter={formatter} />,
  }))
  const delta = pctDelta(qpsSeries)
  const gatewayCount = counts.forceProxy + counts.chnrouteForeign

  return (
    <div className="flex flex-col gap-4" data-testid="page-overview">
      <div className="flex flex-wrap items-center gap-3 px-1">
        <p className="min-w-[220px] flex-1 text-[12.5px] text-text-faint">{t('overview.intro')}</p>
        <button
          type="button"
          onClick={() => setLive((current) => !current)}
          aria-label={live ? t('overview.pause') : t('overview.resume')}
          className={cn(
            'zds-state-layer inline-flex h-8 items-center gap-2 rounded-full px-3 text-[11.5px] font-medium',
            live ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : 'bg-surface-container text-text-soft',
          )}
        >
          <StatusDot color={live ? 'var(--color-green)' : 'var(--color-text-faint)'} pulse={live} />
          {live ? t('overview.live') : t('overview.paused')}
        </button>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Card variant="hero" className="min-h-[150px] overflow-hidden p-5">
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-[13px] font-medium">{t('overview.qpsLive')}</div>
              <div className="mt-2 flex items-baseline gap-2">
                <span className="font-mono text-[38px] font-medium leading-none tracking-[-.05em]">{qpsNow}</span>
              </div>
            </div>
            {delta !== null ? (
              <span className="rounded-full bg-[rgb(255_255_255_/_35%)] px-3 py-1 font-mono text-[11px] font-medium">
                {`${delta >= 0 ? '+' : ''}${delta.toFixed(1)}%`}
              </span>
            ) : null}
          </div>
          <Sparkline
            data={qpsSeries.length > 0 ? qpsSeries : [0, 0]}
            color="var(--md-sys-color-on-primary-container)"
            height={42}
            className="mt-4"
          />
        </Card>
        <Metric label={t('overview.totalQueries')} value={formatter.format(status?.stats?.total ?? 0)} supporting={t('overview.sinceStartup')} accent />
        <Metric
          label={t('overview.cacheHitRate')}
          value={`${hitRate.toFixed(1)}%`}
          supporting={`${formatter.format(status?.stats?.cache_hits ?? 0)} / ${formatter.format((status?.stats?.cache_hits ?? 0) + (status?.stats?.cache_misses ?? 0))}`}
          meterValue={hitRate}
        />
        <Card variant="tonal" className="flex min-h-[116px] flex-col justify-between p-4.5">
          <span className="text-[12px] font-medium text-text-soft">{t('overview.upstreamHealthLatency')}</span>
          <div className="space-y-2">
            {upstreamRows.map((row) => (
              <div key={row.name} className="flex items-baseline gap-2">
                <span className="flex-1 text-[10.5px] text-text-faint">{row.name}</span>
                <b className="font-mono text-[17px] font-medium tabular-nums text-text-strong">{row.display}</b>
              </div>
            ))}
          </div>
        </Card>
      </div>

      <Card variant="tonal" className="p-5 sm:p-6">
        <div className="mb-5 flex items-baseline justify-between gap-3">
          <div>
            <h2 className="text-[15px] font-medium text-text-strong">{t('overview.traceTitle')}</h2>
            <p className="mt-1 text-[11.5px] text-text-faint">{t('overview.traceDescription')}</p>
          </div>
          <span className="hidden rounded-full bg-secondary-container px-3 py-1 font-mono text-[10.5px] text-on-secondary-container sm:inline">/api/status</span>
        </div>
        <div className="zds-trace-rail [--trace-steps:3]">
          <TraceNode icon={<NetworkCheckIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceQuery')} value={formatter.format(status?.stats?.total ?? 0)} />
          <TraceNode icon={<RuleIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceDecision')} value={formatter.format(decisionTotal)} />
          <TraceNode icon={<SpeedIcon className="h-4 w-4" aria-hidden="true" />} label={t('overview.traceGateway')} value={formatter.format(gatewayCount)} />
        </div>
      </Card>

      <div className="grid gap-4 md:grid-cols-2">
        <Card className="p-5">
          <div className="mb-4 flex items-center justify-between gap-3">
            <div>
              <h2 className="text-[15px] font-medium text-text-strong">{t('overview.qpsLive')}</h2>
              <p className="mt-1 text-[10.5px] text-text-faint">{t('overview.queriesPerSecond')}</p>
            </div>
            <span className="font-mono text-[22px] font-medium text-primary">{qpsNow}</span>
          </div>
          <Sparkline data={qpsSeries.length > 0 ? qpsSeries : [0, 0]} color="var(--color-primary)" height={152} />
        </Card>

        <Card className="p-5">
          <h2 className="mb-4 text-[15px] font-medium text-text-strong">{t('overview.decisionDistribution')}</h2>
          <div className="flex items-center gap-5">
            <DonutChart segments={decisionSegments} height={132} width={132} centerLabel={formatter.format(decisionTotal)} className="shrink-0" />
            <div className="flex min-w-0 flex-1 flex-col gap-2.5">
              {decisionSegments.map((segment) => (
                <div key={segment.name} className="flex items-center gap-2">
                  <span className="h-2.5 w-2.5 shrink-0 rounded-[3px]" style={{ background: segment.color }} />
                  <span className="min-w-0 flex-1 truncate text-[12px] text-text-mid">{segment.name}</span>
                  <span className="font-mono text-[10.5px] text-text-faint">{decisionTotal > 0 ? `${Math.round((segment.value / decisionTotal) * 100)}%` : '0%'}</span>
                </div>
              ))}
            </div>
          </div>
        </Card>

        <Card className="p-5">
          <div className="mb-1 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 className="text-[15px] font-medium text-text-strong">{t('overview.upstreamHealth')}</h2>
            <span className="rounded-full bg-secondary-container px-2.5 py-0.5 text-[10.5px] text-on-secondary-container">
              {t('overview.upstreamLatencyScope')}
            </span>
          </div>
          <p className="mb-4 text-[11px] leading-relaxed text-text-faint">{t('overview.upstreamLatencyHint')}</p>
          <HBarChart rows={upstreamRows} />
          <p className="mt-4 text-[10px] leading-relaxed text-text-faint">
            {t('overview.upstreamMeasured')} {t('overview.upstreamTrustNote')}
          </p>
        </Card>

        <Card className="p-5">
          <h2 className="mb-4 text-[15px] font-medium text-text-strong">{t('overview.arbitration')}</h2>
          <div className="flex items-center gap-5">
            <DonutChart segments={arbitrationSegmentsView} height={132} width={132} centerLabel={formatter.format(arbitrationTotal)} className="shrink-0" />
            <div className="flex flex-1 flex-col gap-3">
              {arbitrationSegmentsView.map((segment) => (
                <div key={segment.name} className="rounded-[12px] bg-surface-container-low p-3">
                  <div className="flex items-center gap-2 text-[11.5px] text-text-mid">
                    <span className="h-2.5 w-2.5 rounded-[3px]" style={{ background: segment.color }} />
                    {segment.name}
                  </div>
                  <div className="mt-1 font-mono text-[20px] font-medium text-text-strong">
                    {arbitrationTotal > 0 ? `${Math.round((segment.value / arbitrationTotal) * 100)}%` : '0%'}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </Card>
      </div>
    </div>
  )
}
