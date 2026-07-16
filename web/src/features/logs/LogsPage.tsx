import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { Search } from 'lucide-react'
import { Card, Chip, Input, StatusDot } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import { api, BackendPendingError } from '../../lib/api/client'
import type { QueryLogEntry } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { useMediaQuery } from '../../lib/useMediaQuery'
import { buildLogColumns, formatLogIps, formatLogTime, resolveDecision } from './log-columns'

const POLL_MS = 3000
const SEARCH_DEBOUNCE_MS = 250
const LIMIT = 300

type LoadState = 'loading' | 'ready' | 'pending' | 'error'

// The four legend colors from the design handoff's log view (~L311-314) —
// each reuses an existing `logs.decision.*` key rather than inventing
// legend-only copy, since the 5 reason-driven labels collapse onto exactly
// these 4 colors (blacklist and chnroute-foreign share blue).
const LEGEND: Array<{ color: string; labelKey: string }> = [
  { color: '#16a34a', labelKey: 'logs.decision.direct' },
  { color: '#0891b2', labelKey: 'logs.decision.chnrouteCn' },
  { color: '#2563eb', labelKey: 'logs.decision.proxy' },
  { color: '#dc2626', labelKey: 'logs.decision.block' },
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
        <span className="text-[11px] font-semibold" style={{ color: decision.color }}>
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
    } catch (err) {
      if (controller.signal.aborted || requestId !== requestIdRef.current) return
      setEntries([])
      setState(err instanceof BackendPendingError ? 'pending' : 'error')
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

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-logs">
      <p className="text-[12.5px] text-text-faint">{t('logs.intro')}</p>

      <div className="flex flex-wrap items-center justify-end gap-3.5">
        <div className="flex flex-wrap items-center gap-3.5">
          {LEGEND.map((item) => (
            <div key={item.labelKey} className="flex items-center gap-1.5 text-[10.5px] text-text-soft">
              <StatusDot color={item.color} />
              {t(item.labelKey)}
            </div>
          ))}
        </div>

        <div className="relative">
          <Search
            className="pointer-events-none absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 text-text-faint"
            aria-hidden="true"
          />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t('logs.searchPlaceholder')}
            className="w-64 pl-9"
          />
        </div>

        <button
          type="button"
          onClick={() => setLive((v) => !v)}
          aria-label={live ? t('logs.pause') : t('logs.resume')}
          className={cn(
            'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1.5 text-[11px] font-bold',
            live ? 'bg-green/10 text-green' : 'bg-divider text-text-soft',
          )}
        >
          <StatusDot color={live ? '#16a34a' : '#93a2bd'} pulse={live} />
          {live ? t('logs.live') : t('logs.paused')}
        </button>
      </div>

      <Card className="overflow-hidden p-0">
        {state === 'loading' ? (
          <div className="p-8 text-center text-[12.5px] text-text-faint">{t('logs.loading')}</div>
        ) : state === 'pending' ? (
          <div className="p-8 text-center text-[12.5px] text-text-faint">{t('common.backendPending')}</div>
        ) : state === 'error' ? (
          <div className="p-8 text-center text-[12.5px] text-red">{t('logs.loadFailed')}</div>
        ) : entries.length === 0 ? (
          <div className="flex flex-col items-center gap-1 p-8 text-center">
            <div className="text-[13px] font-semibold text-text-strong">{t('logs.emptyTitle')}</div>
            <div className="text-[12px] text-text-faint">{t('logs.emptyHint')}</div>
          </div>
        ) : isMobile ? (
          <div className="flex flex-col divide-y divide-divider">
            {entries.map((entry, i) => (
              <LogCard key={`${entry.time}-${entry.name}-${i}`} entry={entry} t={t} />
            ))}
          </div>
        ) : (
          <VirtualTable columns={columns} data={entries} />
        )}
      </Card>
    </div>
  )
}
