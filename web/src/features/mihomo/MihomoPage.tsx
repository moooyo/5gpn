import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import type { ColumnDef } from '@tanstack/react-table'
import { ExternalLink } from 'lucide-react'
import { Badge, type BadgeTone, Card, CardHeader, StatusDot } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import type { MihomoLogLine } from '../../lib/api/types'
import { useStatus } from '../../lib/StatusContext'
import { cn } from '../../lib/cn'
import { useMihomoLogs } from './useMihomoLogs'
import { api } from '../../lib/api/client'

// mihomo's log levels (its own free-form `type` field) mapped to the
// closest existing Badge tone — unrecognized/absent levels fall to neutral
// rather than throwing.
const LEVEL_TONE: Record<string, BadgeTone> = {
  error: 'red',
  warning: 'amber',
  info: 'blue',
  debug: 'neutral',
  silent: 'neutral',
}

function buildColumns(t: TFunction): ColumnDef<MihomoLogLine, unknown>[] {
  return [
    {
      accessorKey: 'type',
      header: t('mihomo.colLevel'),
      meta: { width: 96 },
      cell: (info) => {
        const level = String(info.getValue() ?? '')
        return <Badge tone={LEVEL_TONE[level] ?? 'neutral'}>{level || '-'}</Badge>
      },
    },
    {
      accessorKey: 'payload',
      header: t('mihomo.colMessage'),
      cell: (info) => (
        <span className="block truncate font-mono text-[11.5px] text-text-mid">{String(info.getValue() ?? '')}</span>
      ),
    },
  ]
}

/** 出口内核 (mihomo) — READ-ONLY monitoring: a health card (version/meta
 *  from the shared `useStatus()` poll, the bearer-protected
 *  `/api/mihomo/health` liveness check the Sidebar's kernel-status dot reads — see
 *  StatusContext.tsx) plus a virtualized live-log list streamed over the
 *  ticket-gated same-origin `/proxy/logs` WebSocket (see useMihomoLogs). Deep ops
 *  (connections/traffic/per-node inspection) are intentionally NOT built
 *  here — the "Open zashboard" link hands that off to the full zashboard
 *  panel the daemon also serves. */
export default function MihomoPage() {
  const { t } = useTranslation()
  const { status, mihomo, mihomoOk, loading } = useStatus()
  const zashDomain = status?.zash_domain

  const [paused, setPaused] = useState(false)
  const [openingZash, setOpeningZash] = useState(false)
  const { lines, connected } = useMihomoLogs({ paused })
  const columns = useMemo(() => buildColumns(t), [t])

  const openZashboard = async () => {
    if (openingZash) return
    setOpeningZash(true)
    const popup = window.open('about:blank', '_blank')
    if (popup) popup.opener = null
    try {
      const handoff = await api.createZashboardHandoff()
      // Zashboard's root-scoped service worker turns every GET navigation
      // into its cached SPA shell, which would swallow /handoff before the
      // daemon can set the session cookie. Workbox does not route POST, so a
      // top-level form submission reliably reaches the handoff endpoint even
      // when an older zashboard worker is already controlling this origin.
      const targetDocument = popup && !popup.closed ? popup.document : document
      const form = targetDocument.createElement('form')
      form.method = 'post'
      form.action = handoff.url
      form.hidden = true
      targetDocument.body.appendChild(form)
      form.submit()
      form.remove()
    } catch {
      popup?.close()
    } finally {
      setOpeningZash(false)
    }
  }

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-mihomo">
      <p className="text-[12.5px] text-text-faint">{t('mihomo.intro')}</p>

      <Card>
        <CardHeader title={t('mihomo.healthTitle')} />
        <div className="flex flex-wrap items-center gap-3 p-4">
          {loading ? (
            <span className="text-[12.5px] text-text-faint">{t('mihomo.healthLoading')}</span>
          ) : !mihomoOk ? (
            <span className="text-[12.5px] text-red">{t('mihomo.healthFailed')}</span>
          ) : (
            <>
              <div className="flex items-center gap-2">
                <StatusDot color="#16a34a" pulse />
                <span className="text-[13px] font-bold text-text-strong">{mihomo?.version}</span>
              </div>
              {mihomo?.meta ? <Badge tone="indigo">{t('mihomo.metaBadge')}</Badge> : null}
            </>
          )}
          {zashDomain ? (
            <button
              type="button"
              onClick={() => void openZashboard()}
              disabled={openingZash}
              aria-busy={openingZash}
              className="ml-auto inline-flex items-center gap-1.5 rounded-[10px] border border-input-border bg-card px-3 py-1.5 text-[12px] font-semibold text-text-mid hover:bg-primary/10"
            >
              <ExternalLink className="h-3.5 w-3.5" strokeWidth={2} aria-hidden="true" />
              {t('mihomo.openZashboard')}
            </button>
          ) : null}
        </div>
      </Card>

      <div className="flex flex-wrap items-center justify-between gap-3.5">
        <div className="flex items-center gap-1.5 text-[11px] font-semibold text-text-soft">
          <StatusDot color={connected ? '#16a34a' : '#dc2626'} pulse={connected} />
          {connected ? t('mihomo.connected') : t('mihomo.disconnected')}
        </div>
        <button
          type="button"
          onClick={() => setPaused((v) => !v)}
          aria-label={paused ? t('mihomo.resume') : t('mihomo.pause')}
          className={cn(
            'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1.5 text-[11px] font-bold',
            !paused ? 'bg-green/10 text-green' : 'bg-divider text-text-soft',
          )}
        >
          <StatusDot color={!paused ? '#16a34a' : '#93a2bd'} pulse={!paused} />
          {!paused ? t('mihomo.live') : t('mihomo.paused')}
        </button>
      </div>

      <Card className="overflow-hidden p-0">
        {lines.length === 0 ? (
          <div className="flex flex-col items-center gap-1 p-8 text-center">
            <div className="text-[13px] font-semibold text-text-strong">{t('mihomo.emptyTitle')}</div>
            <div className="text-[12px] text-text-faint">{t('mihomo.emptyHint')}</div>
          </div>
        ) : (
          <VirtualTable columns={columns} data={lines} rowHeight={30} height="50vh" />
        )}
      </Card>
    </div>
  )
}
