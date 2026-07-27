import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import type { TFunction } from 'i18next'
import { Card, Chip, FilterChips, LiveToggle, LogSearchField, StatusDot, logSurfaceHeight } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import { api } from '../../lib/api/client'
import type { QueryLogEntry } from '../../lib/api/types'
import { useMediaQuery } from '../../lib/useMediaQuery'
import { DECISION, DECISION_ORDER, buildLogColumns, formatLogIps, formatLogTime, resolveDecision } from './log-columns'

const POLL_MS = 3000
const SEARCH_DEBOUNCE_MS = 250
const LIMIT = 300

type LoadState = 'loading' | 'ready' | 'error'

/** Sentinel for the unfiltered pill; the filter state itself stays null. */
const ALL_DECISIONS = '__all__'

/** Two-line stacked card row used below the `md` breakpoint instead of the
 *  VirtualTable (line 1: time + domain + decision swatch; line 2: reason chip
 *  + ip + ms). The swatch is square rather than a dot: at this size it has to
 *  be read as the same legend key the filter pills carry. */
function LogCard({ entry, t }: { entry: QueryLogEntry; t: TFunction }) {
  const decision = resolveDecision(entry)
  return (
    <div className="flex min-h-field flex-col justify-center gap-1.5 px-4 py-3">
      <div className="flex items-center gap-2 text-label">
        <span className="font-mono text-text-faint">{formatLogTime(entry.time)}</span>
        <span className="flex-1 truncate font-mono text-text-strong">{entry.name}</span>
        <StatusDot color={decision.color} square />
        <span className="text-meta font-semibold text-text-mid">
          {t(decision.key)}
        </span>
      </div>
      <div className="flex items-center gap-2 text-meta text-text-soft">
        {entry.reason ? <Chip value={entry.reason} /> : null}
        <span className="font-mono">{formatLogIps(entry.ips)}</span>
        <span className="ml-auto font-mono text-text-faint">{Math.round(entry.duration_ms)}ms</span>
      </div>
    </div>
  )
}

export default function LogsPage() {
  const { t } = useTranslation()
  // `?q=` lets the resolve test hand a domain straight to this page — that
  // hand-off used to be the operator memorizing the name and retyping it.
  const [searchParams] = useSearchParams()
  const initialQuery = searchParams.get('q') ?? ''
  const [query, setQuery] = useState(initialQuery)
  const [entries, setEntries] = useState<QueryLogEntry[]>([])
  const [state, setState] = useState<LoadState>('loading')
  const [live, setLive] = useState(true)
  const [decisionFilter, setDecisionFilter] = useState<string | null>(null)
  const isMobile = useMediaQuery('(max-width: 767px)')
  const [debouncedQuery, setDebouncedQuery] = useState(initialQuery)
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
  // One reduce over the window already in hand — no extra request. Without it
  // a pill only reveals whether it has anything behind it after you click it.
  const decisionCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const entry of entries) {
      if (entry.reason) counts[entry.reason] = (counts[entry.reason] ?? 0) + 1
    }
    return counts
  }, [entries])

  return (
    <div className="flex flex-col gap-3 md:gap-4" data-testid="page-logs">
      <div className="flex flex-wrap items-center gap-3 px-1">
        <p className="min-w-[220px] flex-1 text-label text-text-faint">{t('logs.intro')}</p>
        <LiveToggle
          live={live}
          onToggle={() => setLive((value) => !value)}
          liveLabel={t('logs.live')}
          // Pausing here stops the poll; the window simply stops advancing, so
          // there is nothing to buffer and nothing lost.
          pausedLabel={t('logs.paused')}
          pauseAction={t('logs.pause')}
          resumeAction={t('logs.resume')}
        />
      </div>

      <Card variant="tonal" className="flex flex-col gap-2 p-3 md:p-4">
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center">
          {/* The pills ARE the legend: same slot, same order and same wording
              as the table's decision column, so the row below them no longer
              has to repeat the mapping in a different palette. */}
          <FilterChips
            ariaLabel={t('logs.colDecision')}
            value={decisionFilter ?? ALL_DECISIONS}
            onChange={(value) => setDecisionFilter(value === ALL_DECISIONS ? null : value)}
            options={[
              { value: ALL_DECISIONS, label: t('logs.allDecisions'), count: entries.length },
              ...DECISION_ORDER.map((value) => ({
                value,
                label: t(DECISION[value].key),
                swatch: DECISION[value].color,
                count: decisionCounts[value] ?? 0,
              })),
            ]}
          />
          <div className="sm:flex-1" />
          {/* This page keeps its own toolbar rather than adopting LogSurface —
              its body is a four-way loading/error/empty/list branch, and the
              e2e suite asserts the virtual table is a direct child of the card.
              The search control is still the shared one: it was the third
              hand-rolled copy, differing from the other two in icon inset and
              background, which is exactly the divergence LogSearchField was
              extracted to end. */}
          <LogSearchField
            value={query}
            onChange={setQuery}
            label={t('logs.searchLabel')}
            placeholder={t('logs.searchPlaceholder')}
            className="w-full sm:w-64"
          />
        </div>
        <p className="text-meta text-text-faint">{t('logs.windowHint', { limit: LIMIT })}</p>
      </Card>

      <Card className="overflow-hidden p-0 shadow-none">
        {state === 'loading' ? (
          <div className="p-8 text-center text-label text-text-faint">{t('logs.loading')}</div>
        ) : state === 'error' ? (
          <div className="p-8 text-center text-label text-red">{t('logs.loadFailed')}</div>
        ) : visibleEntries.length === 0 ? (
          <div className="flex flex-col items-center gap-1 p-8 text-center">
            <div className="text-body font-semibold text-text-strong">{t('logs.emptyTitle')}</div>
            <div className="text-label text-text-faint">{t('logs.emptyHint')}</div>
          </div>
        ) : isMobile ? (
          <div className="flex flex-col divide-y divide-divider">
            {visibleEntries.map((entry, i) => (
              <LogCard key={`${entry.time}-${entry.name}-${i}`} entry={entry} t={t} />
            ))}
          </div>
        ) : (
          <VirtualTable columns={columns} data={visibleEntries} height={logSurfaceHeight(300)} />
        )}
      </Card>
    </div>
  )
}
