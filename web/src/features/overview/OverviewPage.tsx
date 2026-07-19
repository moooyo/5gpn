import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { NetworkCheckIcon, RuleIcon, SpeedIcon } from '../../components/icons'
import { BarChart, DonutChart, Sparkline, type DonutSegment } from '../../components/charts'
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
  type QpsPoint,
} from './metrics'

const SERIES_CAP = 48

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
  const decisionSegments: DonutSegment[] = useMemo(() => [
    { name: t('overview.decision.block'), value: counts.block, color: 'var(--color-red)' },
    { name: t('overview.decision.forceDirect'), value: counts.forceDirect, color: 'var(--color-green)' },
    { name: t('overview.decision.forceProxy'), value: counts.forceProxy, color: 'var(--color-primary)' },
    { name: t('overview.decision.chnrouteCn'), value: counts.chnrouteCn, color: 'var(--color-cyan)' },
    { name: t('overview.decision.chnrouteForeign'), value: counts.chnrouteForeign, color: 'var(--color-indigo)' },
  ], [counts, t])
  const decisionTotal = decisionSegments.reduce((sum, segment) => sum + segment.value, 0)
  const hitRate = cacheHitRate(status?.stats)
  const health = upstreamHealth(status?.stats)
  const arbitration = arbitrationSegments(status?.stats)
  const arbitrationSegmentsView: DonutSegment[] = [
    { name: t('overview.arbitrationCn'), value: arbitration.cn, color: 'var(--color-cyan)' },
    { name: t('overview.arbitrationForeign'), value: arbitration.foreign, color: 'var(--color-indigo)' },
  ]
  const arbitrationTotal = arbitration.cn + arbitration.foreign
  const formatter = useMemo(() => new Intl.NumberFormat(i18n.language), [i18n.language])
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
            <div className="flex items-center gap-2"><StatusDot color="var(--color-green)" /><span className="flex-1 text-[10.5px] text-text-faint">china</span><b className="font-mono text-[17px] font-medium text-text-strong">{health.china.avgMs.toFixed(1)}ms</b></div>
            <div className="flex items-center gap-2"><StatusDot color="var(--color-primary)" /><span className="flex-1 text-[10.5px] text-text-faint">trust</span><b className="font-mono text-[17px] font-medium text-text-strong">{health.trust.avgMs.toFixed(1)}ms</b></div>
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
          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <h2 className="text-[15px] font-medium text-text-strong">{t('overview.upstreamHealth')}</h2>
            <div className="flex gap-3 text-[10.5px] text-text-faint">
              <span className="flex items-center gap-1.5"><StatusDot color="var(--color-green)" />{t('overview.upstreamHealthOk')}</span>
              <span className="flex items-center gap-1.5"><StatusDot color="var(--color-red)" />{t('overview.upstreamHealthErr')}</span>
            </div>
          </div>
          <BarChart
            categories={[t('overview.upstreamHealthChina'), t('overview.upstreamHealthTrust')]}
            series={[
              { name: t('overview.upstreamHealthOk'), data: [health.china.ok, health.trust.ok], color: 'var(--color-green)' },
              { name: t('overview.upstreamHealthErr'), data: [health.china.err, health.trust.err], color: 'var(--color-red)' },
            ]}
            height={130}
          />
          <div className="grid grid-cols-2 text-center text-[10.5px] text-text-faint">
            <span>{t('overview.upstreamHealthLatency')} <b className="font-mono font-medium text-text-mid">{health.china.avgMs.toFixed(1)}ms</b></span>
            <span>{t('overview.upstreamHealthLatency')} <b className="font-mono font-medium text-text-mid">{health.trust.avgMs.toFixed(1)}ms</b></span>
          </div>
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
