import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { PauseIcon, PlayIcon, SearchIcon } from '../../components/icons'
import { Card, Chip, Input, StatusDot } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import { api } from '../../lib/api/client'
import type { QueryLogEntry } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { useMediaQuery } from '../../lib/useMediaQuery'
import { buildLogColumns, formatLogIps, formatLogTime, resolveDecision } from './log-columns'

const POLL_MS = 3000
const SEARCH_DEBOUNCE_MS = 250
const LIMIT = 300

type LoadState = 'loading' | 'ready' | 'error'

// The four legend colors from the design handoff's log view (~L311-314) —
// each reuses an existing `logs.decision.*` key rather than inventing
// legend-only copy, since the 5 reason-driven labels collapse onto exactly
// these 4 colors (force-proxy and chnroute-foreign share blue).
const LEGEND: Array<{ color: string; labelKey: string }> = [
  { color: 'var(--color-green)', labelKey: 'logs.decision.direct' },
  { color: 'var(--color-cyan)', labelKey: 'logs.decision.chnrouteCn' },
  { color: 'var(--color-primary)', labelKey: 'logs.decision.proxy' },
  { color: 'var(--color-red)', labelKey: 'logs.decision.block' },
]

/** Two-line stacked card row used below the `md` breakpoint instead of the
 *  VirtualTable (line 1: time + domain + decision dot; line 2: reason chip +
 *  ip + ms). */
function LogCard({ entry, t }: { entry: QueryLogEntry; t: TFunction }) {
  const decision = resolveDecision(entry)
  return (
    <div className="flex flex-col gap-1.5 px-4 py-3">
      <div className="flex items-center gap-2 text-[12px]">
        <span className="font-mono text-text-faint">{formatLogTime(entry.time)}</span>
        <span className="flex-1 truncate font-mono text-text-strong">{entry.name}</span>
        <StatusDot color={decision.color} />
        <span className="text-[11px] font-semibold text-text-mid">
          {t(decision.key)}
        </span>
      </div>
      <div className="flex items-center gap-2 text-[11px] text-text-soft">
        {entry.reason ? <Chip value={entry.reason} /> : null}
        <span className="font-mono">{formatLogIps(entry.ips)}</span>
        <span className="ml-auto font-mono text-text-faint">{Math.round(entry.duration_ms)}ms</span>
      </div>
    </div>
  )
}

export default function LogsPage() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [entries, setEntries] = useState<QueryLogEntry[]>([])
  const [state, setState] = useState<LoadState>('loading')
  const [live, setLive] = useState(true)
  const [decisionFilter, setDecisionFilter] = useState<string | null>(null)
  const isMobile = useMediaQuery('(max-width: 767px)')
  const [debouncedQuery, setDebouncedQuery] = useState('')
  const requestIdRef = useRef(0)
  const activeControllerRef = useRef<AbortController | null>(null)

  // Keep keystrokes local, then issue one request for the settled filter.
  useEffect(() => {
    const id = setTimeout(() => setDebouncedQuery(query), SEARCH_DEBOUNCE_MS)
    return () => clearTimeout(id)
  }, [query])

  const queryRef = useRef(debouncedQuery)
  useEffect(() => {
    queryRef.current = debouncedQuery
  }, [debouncedQuery])

  const load = useCallback(async (filter: string) => {
    activeControllerRef.current?.abort()
    const controller = new AbortController()
    activeControllerRef.current = controller
    const requestId = ++requestIdRef.current
    try {
      const res = await api.getQueryLog(filter, LIMIT, controller.signal)
      if (requestId !== requestIdRef.current) return
      setEntries(res.entries ?? [])
      setState('ready')
    } catch {
      if (controller.signal.aborted || requestId !== requestIdRef.current) return
      setEntries([])
      setState('error')
    } finally {
      if (activeControllerRef.current === controller) activeControllerRef.current = null
    }
  }, [])

  // Fetch immediately on mount and once for each settled filter.
  useEffect(() => {
    void load(debouncedQuery)
  }, [debouncedQuery, load])

  // Poll from completion so a slow request never overlaps the next tick.
  // The request id also prevents an older search/poll response from
  // overwriting a newer filter result.
  useEffect(() => {
    if (!live) {
      activeControllerRef.current?.abort()
      requestIdRef.current += 1
      return
    }
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const tick = async () => {
      await load(queryRef.current)
      if (!cancelled) timer = setTimeout(() => void tick(), POLL_MS)
    }
    timer = setTimeout(() => void tick(), POLL_MS)
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
      activeControllerRef.current?.abort()
      requestIdRef.current += 1
    }
  }, [live, load])

  useEffect(() => () => activeControllerRef.current?.abort(), [])

  const columns = useMemo(() => buildLogColumns(t), [t])
  const visibleEntries = useMemo(
    () => decisionFilter ? entries.filter((entry) => entry.reason === decisionFilter) : entries,
    [decisionFilter, entries],
  )

  return (
    <div className="flex flex-col gap-4" data-testid="page-logs">
      <div className="flex flex-wrap items-center gap-3 px-1">
        <p className="min-w-[220px] flex-1 text-[12.5px] text-text-faint">{t('logs.intro')}</p>
        <button
          type="button"
          onClick={() => setLive((value) => !value)}
          aria-label={live ? t('logs.pause') : t('logs.resume')}
          className={cn(
            'zds-state-layer inline-flex h-8 items-center gap-2 rounded-full px-3 text-[11.5px] font-medium',
            live ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : 'bg-surface-container text-text-soft',
          )}
        >
          {live ? <PauseIcon className="h-4 w-4" aria-hidden="true" /> : <PlayIcon className="h-4 w-4" aria-hidden="true" />}
          {live ? t('logs.live') : t('logs.paused')}
        </button>
      </div>

      <Card variant="tonal" className="flex flex-col gap-3 p-3 sm:p-4">
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={() => setDecisionFilter(null)}
            className={cn('zds-state-layer h-8 rounded-[9px] px-3 text-[11.5px] font-medium', decisionFilter === null ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft')}
          >
            {t('logs.allDecisions')}
          </button>
          {[
            ['force-direct', 'logs.decision.forceDirect', 'var(--color-green)'],
            ['chnroute-cn', 'logs.decision.chnrouteCn', 'var(--color-cyan)'],
            ['force-proxy', 'logs.decision.forceProxy', 'var(--color-primary)'],
            ['chnroute-foreign', 'logs.decision.chnrouteForeign', 'var(--color-indigo)'],
            ['block', 'logs.decision.block', 'var(--color-red)'],
          ].map(([value, key, color]) => (
            <button
              key={value}
              type="button"
              onClick={() => setDecisionFilter(value)}
              className={cn('zds-state-layer flex h-8 items-center gap-2 rounded-[9px] px-3 text-[11.5px] font-medium', decisionFilter === value ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft')}
            >
              <StatusDot color={color} />
              {t(key)}
            </button>
          ))}
          <div className="flex-1" />
          <div className="relative w-full sm:w-64">
          <SearchIcon
            className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint"
            aria-hidden="true"
          />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t('logs.searchPlaceholder')}
            className="w-full rounded-full pl-10"
          />
        </div>
        </div>
        <div className="hidden flex-wrap gap-4 border-t border-border pt-3 sm:flex">
          {LEGEND.map((item) => (
            <div key={item.labelKey} className="flex items-center gap-1.5 text-[10.5px] text-text-faint">
              <StatusDot color={item.color} />
              {t(item.labelKey)}
            </div>
          ))}
        </div>
      </Card>

      <Card className="overflow-hidden p-0 shadow-none">
        {state === 'loading' ? (
          <div className="p-8 text-center text-[12.5px] text-text-faint">{t('logs.loading')}</div>
        ) : state === 'error' ? (
          <div className="p-8 text-center text-[12.5px] text-red">{t('logs.loadFailed')}</div>
        ) : visibleEntries.length === 0 ? (
          <div className="flex flex-col items-center gap-1 p-8 text-center">
            <div className="text-[13px] font-semibold text-text-strong">{t('logs.emptyTitle')}</div>
            <div className="text-[12px] text-text-faint">{t('logs.emptyHint')}</div>
          </div>
        ) : isMobile ? (
          <div className="flex flex-col divide-y divide-divider">
            {visibleEntries.map((entry, i) => (
              <LogCard key={`${entry.time}-${entry.name}-${i}`} entry={entry} t={t} />
            ))}
          </div>
        ) : (
          <VirtualTable columns={columns} data={visibleEntries} />
        )}
      </Card>
    </div>
  )
}
