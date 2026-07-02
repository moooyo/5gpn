import { useEffect, useState } from 'react'
import { api, type Status } from '../api'
import { Panel, Stat } from '../components/ui'
import { VerdictLaneBar } from '../components/VerdictLaneBar'
import { Loading, ErrorNotice } from '../components/states'
import { humanizeUptime, successRatio, fmtInt } from '../format'

export function DashboardView({ status: initial }: { status: Status | null }) {
  const [status, setStatus] = useState<Status | null>(initial)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (initial) setStatus(initial)
  }, [initial])

  useEffect(() => {
    if (status) return
    api
      .status()
      .then(setStatus)
      .catch((e) => setError(e.message))
  }, [status])

  if (error && !status) return <ErrorNotice message={error} />
  if (!status) return <Loading label="Reading status…" />

  const s = status.stats

  return (
    <div className="flex flex-col gap-4">
      {/* Hero verdict-lane bar */}
      <Panel eyebrow="Verdict split" title="How queries are being routed">
        <VerdictLaneBar stats={s} size="hero" />
      </Panel>

      {/* Status row */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Panel>
          <div className="eyebrow mb-1.5">Version</div>
          <div className="font-mono text-lg font-semibold" style={{ color: 'var(--accent)' }}>
            {status.version}
          </div>
        </Panel>
        <Panel>
          <div className="eyebrow mb-1.5">Uptime</div>
          <div className="font-mono text-lg font-semibold">{humanizeUptime(status.uptime_seconds)}</div>
        </Panel>
        <Panel>
          <Stat label="Cache entries" value={s.cache_entries} />
        </Panel>
        <Panel>
          <Stat label="Total queries" value={s.total} />
        </Panel>
      </div>

      {/* TLS certificate expiry — present only when a cert is configured */}
      {status.cert && (
        <Panel
          eyebrow="TLS certificate"
          title={status.cert.expired ? 'Certificate EXPIRED — DoT/DoH will fail' : 'Certificate validity'}
        >
          <div className="flex items-end justify-between">
            <div>
              <div className="eyebrow mb-1.5">{status.cert.expired ? 'Status' : 'Days remaining'}</div>
              <div
                className="font-mono text-2xl font-semibold"
                style={{
                  color: status.cert.expired
                    ? 'var(--v-block)'
                    : status.cert.days_remaining <= 14
                      ? 'var(--accent)'
                      : 'var(--v-direct)',
                }}
              >
                {status.cert.expired ? 'EXPIRED' : status.cert.days_remaining}
              </div>
            </div>
            <div className="text-right">
              <div className="eyebrow mb-1.5">Expires</div>
              <div className="font-mono text-lg font-semibold">{status.cert.not_after.slice(0, 10)}</div>
            </div>
          </div>
        </Panel>
      )}

      {/* Upstream health */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Panel eyebrow="Upstream" title="China resolvers">
          <div className="flex items-end justify-between">
            <Stat label="Answered" value={s.china_ok} color="var(--v-direct)" />
            <Stat label="Errors" value={s.china_err} color="var(--v-block)" />
            <div className="text-right">
              <div className="eyebrow mb-1.5">Success</div>
              <div className="font-mono text-2xl font-semibold">
                {successRatio(s.china_ok, s.china_err)}
              </div>
            </div>
          </div>
          <HealthBar ok={s.china_ok} err={s.china_err} />
        </Panel>

        <Panel eyebrow="Upstream" title="Trust resolvers">
          <div className="flex items-end justify-between">
            <Stat label="Answered" value={s.trust_ok} color="var(--v-direct)" />
            <Stat label="Errors" value={s.trust_err} color="var(--v-block)" />
            <div className="text-right">
              <div className="eyebrow mb-1.5">Success</div>
              <div className="font-mono text-2xl font-semibold">
                {successRatio(s.trust_ok, s.trust_err)}
              </div>
            </div>
          </div>
          <HealthBar ok={s.trust_ok} err={s.trust_err} />
        </Panel>
      </div>
    </div>
  )
}

function HealthBar({ ok, err }: { ok: number; err: number }) {
  const total = ok + err
  const okPct = total > 0 ? (ok / total) * 100 : 0
  return (
    <div className="mt-4">
      <div
        className="flex overflow-hidden rounded-full"
        style={{ height: 8, background: 'var(--surface-2)', border: '1px solid var(--border)' }}
        aria-hidden
      >
        <div style={{ width: `${okPct}%`, background: 'var(--v-direct)' }} />
        <div style={{ width: `${100 - okPct}%`, background: 'var(--v-block)' }} />
      </div>
      <div className="mt-1.5 font-mono text-xs" style={{ color: 'var(--muted)' }}>
        {fmtInt(total)} samples
      </div>
    </div>
  )
}
