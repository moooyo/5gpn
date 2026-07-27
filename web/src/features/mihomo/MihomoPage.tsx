import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import type { ColumnDef } from '@tanstack/react-table'
import { DeleteSweepIcon, ExternalLinkIcon, SpeedIcon } from '../../components/icons'
import { Badge, type BadgeTone, Button, Card, FilterChips, LiveToggle, LogSearchField, LogSurface, StatusDot, toast } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import type { MihomoConfig, MihomoLogLine } from '../../lib/api/types'
import { useStatus } from '../../lib/StatusContext'
import { cn } from '../../lib/cn'
import { relativeTime } from '../../format'
import { useMediaQuery } from '../../lib/useMediaQuery'
import { MIHOMO_LOG_LEVELS, useMihomoLogs, type MihomoLogLevel } from './useMihomoLogs'
import { api } from '../../lib/api/client'

const SEARCH_DEBOUNCE_MS = 250

// mihomo's log levels (its own free-form `type` field) mapped to the closest
// existing Badge tone. `debug` and `silent` used to share `neutral` with the
// unknown-level fallback, so three different things wore one badge; they are
// separated below and an unrecognized level keeps its raw string with an
// outline instead of being absorbed into the neutral bucket.
const LEVEL_TONE: Record<string, BadgeTone> = {
  error: 'red',
  warning: 'amber',
  info: 'blue',
  debug: 'neutral',
  silent: 'cyan',
}

function LevelBadge({ level }: { level: string }) {
  const known = level in LEVEL_TONE
  return (
    <Badge
      className={cn(
        'min-w-16 justify-center rounded-chip px-2 py-0.5 font-mono',
        !known && 'border border-outline-variant bg-transparent text-text-soft',
      )}
      tone={LEVEL_TONE[level] ?? 'neutral'}
    >
      {level || '-'}
    </Badge>
  )
}

function buildColumns(t: TFunction): ColumnDef<MihomoLogLine, unknown>[] {
  return [
    {
      accessorKey: 'type',
      header: t('mihomo.colLevel'),
      meta: { width: 86 },
      cell: (info) => <LevelBadge level={String(info.getValue() ?? '')} />,
    },
    {
      accessorKey: 'payload',
      header: t('mihomo.colMessage'),
      cell: (info) => (
        <span className="block truncate font-mono text-label text-text-mid">{String(info.getValue() ?? '')}</span>
      ),
    },
  ]
}

/** Mobile rows keep the payload readable instead of truncating free text into
 *  a single line: level on the first row, the message wrapped below it. */
function buildMobileColumns(): ColumnDef<MihomoLogLine, unknown>[] {
  return [
    {
      id: 'mobile-line',
      header: () => null,
      meta: { cellClassName: 'p-0' },
      cell: ({ row }) => (
        <div className="flex min-h-field w-full min-w-0 flex-col justify-center gap-1 px-3.5 py-2">
          <LevelBadge level={String(row.original.type ?? '')} />
          <span className="font-mono text-meta text-text-mid break-all">{String(row.original.payload ?? '')}</span>
        </div>
      ),
    },
  ]
}

/** Controller reachability as the config page states it. The health card used
 *  to report a binary healthy/failed from `/api/mihomo/health` while the
 *  config page reported reachable + authenticated separately, so one page
 *  could say "fine" while the other said "not authenticated". */
function controllerText(config: MihomoConfig | null, t: TFunction): string | null {
  if (!config) return null
  if (!config.controller_reachable) return t('mihomo.controllerUnreachable')
  if (!config.controller_authenticated) return t('mihomo.controllerUnauthenticated')
  return t('mihomo.controllerAuthenticated')
}

/** mihomo kernel — read-only monitoring: a health card (version/meta from the
 *  shared `useStatus()` poll plus the controller tri-state and last-applied
 *  time the config page reads) and a virtualized live-log list streamed over
 *  the ticket-gated same-origin `/proxy/logs` WebSocket (see useMihomoLogs).
 *  Deep ops (connections/traffic/per-node inspection) are intentionally NOT
 *  built here — "Open zashboard" hands that off to the full panel. */
export default function MihomoPage() {
  const { t } = useTranslation()
  const { status, mihomo, mihomoOk, loading } = useStatus()
  const zashDomain = status?.zash_domain
  const isMobile = useMediaQuery('(max-width: 767px)')

  const [paused, setPaused] = useState(false)
  const [openingZash, setOpeningZash] = useState(false)
  const [level, setLevel] = useState<MihomoLogLevel>('info')
  const [query, setQuery] = useState('')
  const [debouncedQuery, setDebouncedQuery] = useState('')
  const [config, setConfig] = useState<MihomoConfig | null>(null)
  const { lines, connected, bufferedCount, bufferFull, clear } = useMihomoLogs({ paused, level })
  const columns = useMemo(() => (isMobile ? buildMobileColumns() : buildColumns(t)), [isMobile, t])

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedQuery(query), SEARCH_DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [query])

  // One request on mount, not a poll: this is the same document the config
  // page owns, read here only for the controller tri-state and applied_at.
  useEffect(() => {
    let cancelled = false
    void api.getMihomoConfig().then((value) => {
      if (!cancelled) setConfig(value)
    }).catch(() => {
      if (!cancelled) setConfig(null)
    })
    return () => { cancelled = true }
  }, [])

  const needle = debouncedQuery.trim().toLocaleLowerCase()
  const visibleLines = useMemo(
    () => needle ? lines.filter((line) => String(line.payload ?? '').toLocaleLowerCase().includes(needle)) : lines,
    [lines, needle],
  )
  const levelCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const line of lines) {
      const key = String(line.type ?? '')
      counts[key] = (counts[key] ?? 0) + 1
    }
    return counts
  }, [lines])

  const openZashboard = useCallback(async (sameTab: boolean) => {
    if (openingZash) return
    setOpeningZash(true)
    const popup = sameTab ? null : window.open('about:blank', '_blank')
    if (popup) popup.opener = null
    if (!sameTab && !popup) {
      // A blocked popup used to be indistinguishable from a dead button: the
      // handoff still ran, submitted into this document, and nothing visible
      // happened. Say so and offer the same-tab route.
      setOpeningZash(false)
      toast.error(t('mihomo.zashPopupBlocked'), {
        action: { label: t('mihomo.zashOpenHere'), onClick: () => void openZashboard(true) },
      })
      return
    }
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
      toast.error(t('mihomo.zashHandoffFailed'))
    } finally {
      setOpeningZash(false)
    }
  }, [openingZash, t])

  const healthSubtitle = [
    mihomo?.version,
    mihomo?.meta ? t('mihomo.metaBadge') : null,
    controllerText(config, t),
    config?.applied_at ? t('mihomo.configApplied', { time: relativeTime(config.applied_at) }) : null,
  ].filter(Boolean).join(' · ')

  return (
    <div className="flex flex-col gap-4" data-testid="page-mihomo">
      <p className="px-1 text-label text-text-faint">{t('mihomo.intro')}</p>

      <Card className="p-5 shadow-none">
        <div className="flex flex-wrap items-center gap-3.5">
          <span className={cn('grid h-10 w-10 shrink-0 place-items-center rounded-pill', mihomoOk ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : 'bg-surface-container text-text-soft')}>
            <SpeedIcon className="h-5 w-5" aria-hidden="true" />
          </span>
          {loading ? (
            <span className="text-label text-text-faint">{t('mihomo.healthLoading')}</span>
          ) : !mihomoOk ? (
            <span className="text-label text-red">{t('mihomo.healthFailed')}</span>
          ) : (
            <div className="flex min-w-0 flex-col gap-0.5">
              <span className="text-title font-medium text-text-strong">{t('mihomo.healthRunning')}</span>
              <span className="font-mono text-meta text-text-faint">{healthSubtitle}</span>
            </div>
          )}
          <div className="min-w-2 flex-1" />
          {zashDomain ? (
            <Button type="button" variant="secondary" onClick={() => void openZashboard(false)} disabled={openingZash} aria-busy={openingZash}>
              <ExternalLinkIcon className="h-4 w-4" aria-hidden="true" />
              {t('mihomo.openZashboard')}
            </Button>
          ) : null}
        </div>
      </Card>

      {/* The shared log surface: same toolbar shape, same height policy and
          same footer as the plugin-log page. This page had none of them, and
          its payload is free text — the one place search matters most. */}
      <LogSurface
        chrome={320}
        filters={
          <FilterChips
            outlined
            ariaLabel={t('mihomo.levelFilterLabel')}
            value={level}
            onChange={(next) => setLevel(next as MihomoLogLevel)}
            options={MIHOMO_LOG_LEVELS.map((item) => ({
              value: item,
              label: item,
              count: levelCounts[item] ?? 0,
            }))}
          />
        }
        search={
          <LogSearchField
            className="flex-1"
            value={query}
            onChange={setQuery}
            label={t('mihomo.searchLabel')}
            placeholder={t('mihomo.searchPlaceholder')}
          />
        }
        actions={
          <>
            <LiveToggle
              live={!paused}
              onToggle={() => setPaused((value) => !value)}
              liveLabel={t('mihomo.live')}
              // Frames that arrive while paused are buffered; the label says
              // how many, and says so plainly once the buffer is full and the
              // oldest are being dropped.
              pausedLabel={bufferFull ? t('mihomo.pausedBufferFull') : t('mihomo.pausedBuffered', { count: bufferedCount })}
              pauseAction={t('mihomo.pause')}
              resumeAction={t('mihomo.resume')}
            />
            <button
              type="button"
              onClick={clear}
              aria-label={t('mihomo.clearLabel')}
              className="zds-state-layer inline-flex h-field items-center justify-center gap-1.5 rounded-pill border border-outline-variant px-3 text-label font-medium text-text-soft md:h-chip"
            >
              <DeleteSweepIcon className="h-4 w-4" aria-hidden="true" />
              <span className="hidden sm:inline">{t('mihomo.clear')}</span>
            </button>
          </>
        }
        status={
          // Same left edge as the surface's own rows, so the card has one.
          <div className="flex items-center gap-2 border-b border-divider px-3.5 py-2 text-meta font-medium text-text-soft md:px-[18px]" role="status" aria-live="polite">
            <StatusDot color={connected ? 'var(--color-green)' : 'var(--color-red)'} />
            {connected ? t('mihomo.connected') : t('mihomo.disconnected')}
          </div>
        }
        isEmpty={visibleLines.length === 0}
        empty={
          <div className="flex flex-col items-center gap-1 p-8 text-center">
            <div className="text-body font-semibold text-text-strong">{t('mihomo.emptyTitle')}</div>
            <div className="text-label text-text-faint">{needle ? t('mihomo.emptySearchHint') : t('mihomo.emptyHint')}</div>
          </div>
        }
        footer={t('mihomo.footer', { count: visibleLines.length })}
        footerMeta={t('mihomo.transport')}
      >
        {(height) => (
          <VirtualTable
            columns={columns}
            data={visibleLines}
            rowHeight={isMobile ? 62 : 34}
            height={height}
            showHeader={false}
            showRowDividers={false}
          />
        )}
      </LogSurface>
    </div>
  )
}
