import { useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { TFunction } from 'i18next'
import type { ColumnDef } from '@tanstack/react-table'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  ChevronDownIcon,
  CloseIcon,
  DeleteSweepIcon,
  RefreshIcon,
  TerminalIcon,
  TuneIcon,
} from '../../components/icons'
import { Badge, FilterChips, LiveToggle, LogSearchField, LogSurface, Modal, Select, StatusDot, toast, type BadgeTone, type SelectItem } from '../../components/ds'
import { VirtualTable } from '../../components/data-grid'
import { api } from '../../lib/api/client'
import type { InterceptModule, PluginEngineLogEntry, PluginEngineLogLevel } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { StatusContext } from '../../lib/StatusContext'
import { useMediaQuery } from '../../lib/useMediaQuery'
import { usePluginEngineLogs } from './usePluginEngineLogs'

const SEARCH_DEBOUNCE_MS = 250
const ALL_PLUGINS = '__all__'
const DESKTOP_ROW_HEIGHT = 32
const DESKTOP_EXPANDED_HEIGHT = 148
const MOBILE_ROW_HEIGHT = 58
const MOBILE_EXPANDED_HEIGHT = 176

type LevelFilter = 'all' | PluginEngineLogLevel

const LEVELS: PluginEngineLogLevel[] = ['info', 'warn', 'error']
// Severity IS a status, so these stay on the semantic roles — no theme aliases
// warning onto error onto primary, and a reader expects red to mean error.
// The plugin identity below is the opposite case and must not borrow them.
const LEVEL_TONE: Record<PluginEngineLogLevel, BadgeTone> = {
  info: 'blue',
  warn: 'amber',
  error: 'red',
}
const LEVEL_DOT: Record<PluginEngineLogLevel, string> = {
  info: 'var(--color-primary)',
  warn: 'var(--color-amber)',
  error: 'var(--color-red)',
}
/** Categorical slots for telling N peer plugins apart. This used to hash the
 *  plugin id into a list of semantic roles: ocean aliases primary onto trace
 *  and forest aliases primary onto success, so two plugins could land on the
 *  same colour by theme, and a third could land on it by hash collision.
 *  Assignment is now positional over `execution_order` — stable for a given
 *  install set, and the same order the extensions page lists them in. */
const PLUGIN_SLOTS = [
  'var(--color-chart-1)',
  'var(--color-chart-2)',
  'var(--color-chart-3)',
  'var(--color-chart-4)',
  'var(--color-chart-5)',
]
const NO_PLUGIN_DOT = 'var(--color-text-faint)'

function formatTime(value: string, fallback: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return fallback
  return [date.getHours(), date.getMinutes(), date.getSeconds()]
    .map((part) => String(part).padStart(2, '0'))
    .join(':')
}

function shortDigest(value: string | undefined, fallback: string): string {
  if (!value) return fallback
  const normalized = value.startsWith('sha256:') ? value.slice(7) : value
  return `sha256:${normalized.slice(0, 8)}${normalized.length > 8 ? '…' : ''}`
}

function durationText(entry: PluginEngineLogEntry, t: TFunction): string {
  if (entry.duration_ms === undefined) return t('pluginLogs.missingValue')
  const value = entry.duration_ms < 10 ? Math.round(entry.duration_ms * 10) / 10 : Math.round(entry.duration_ms)
  return t('pluginLogs.durationMs', { value })
}

function LevelBadge({ level, t }: { level: PluginEngineLogLevel; t: TFunction }) {
  return (
    <Badge className="min-w-[42px] justify-center rounded-chip px-[5px] py-0.5 font-mono text-meta" tone={LEVEL_TONE[level]}>
      {t(`pluginLogs.level.${level}`)}
    </Badge>
  )
}

function EngineTag({ t }: { t: TFunction }) {
  return <span className="shrink-0 rounded-chip bg-tertiary-container px-[5px] py-px text-meta font-semibold text-tertiary">{t('pluginLogs.engineTag')}</span>
}

function Details({ entry, mobile, t }: { entry: PluginEngineLogEntry; mobile: boolean; t: TFunction }) {
  const missing = t('pluginLogs.missingValue')
  if (mobile) {
    return (
      <div className="flex h-[118px] w-full flex-col gap-2 overflow-auto bg-surface-container-low px-3.5 pb-2.5 pt-1">
        <div className="rounded-chip bg-card px-2.5 py-2 font-mono text-label leading-[1.55] text-text-mid break-all whitespace-pre-wrap">
          {entry.message}
        </div>
        <div className="flex flex-wrap gap-1.5">
          <span className="rounded-chip bg-surface-container px-2 py-0.5 font-mono text-meta text-text-soft">{t('pluginLogs.detail.phase')} {entry.phase ?? missing}</span>
          <span className="rounded-chip bg-surface-container px-2 py-0.5 font-mono text-meta text-text-soft">{t('pluginLogs.detail.duration')} {durationText(entry, t)}</span>
          <span className="rounded-chip bg-surface-container px-2 py-0.5 font-mono text-meta text-text-soft">{shortDigest(entry.script_digest, missing)}</span>
        </div>
      </div>
    )
  }

  const metadata = [
    [t('pluginLogs.detail.pluginId'), entry.extension ?? missing],
    [t('pluginLogs.detail.phase'), entry.phase ?? missing],
    [t('pluginLogs.detail.duration'), durationText(entry, t)],
    [t('pluginLogs.detail.digest'), shortDigest(entry.script_digest, missing)],
    [t('pluginLogs.detail.url'), entry.url ?? missing],
  ]
  return (
    <div className="flex h-[116px] w-full flex-col gap-2 overflow-auto bg-surface-container-low px-[18px] py-2.5">
      <div className="rounded-chip border border-divider bg-card px-[11px] py-2 font-mono text-label leading-[1.55] text-text-mid break-all whitespace-pre-wrap">
        {entry.message}
      </div>
      <div className="flex flex-wrap gap-x-7 gap-y-2">
        {metadata.map(([label, value]) => (
          <div key={label} className={cn('min-w-0', label === t('pluginLogs.detail.url') && 'max-w-full flex-1')}>
            <div className="mb-0.5 text-meta text-text-faint">{label}</div>
            <div className="font-mono text-label text-text-mid break-all">{value}</div>
          </div>
        ))}
      </div>
    </div>
  )
}

function EmptyState({ showAction, t }: { showAction: boolean; t: TFunction }) {
  return (
    <div className="flex min-h-[260px] flex-col items-center justify-center gap-1.5 px-5 py-12 text-center">
      <span className="mb-1 grid h-12 w-12 place-items-center rounded-pill bg-surface-container-low text-text-faint">
        <TerminalIcon className="h-6 w-6" aria-hidden="true" />
      </span>
      <div className="text-body font-semibold text-text-strong">{t('pluginLogs.emptyTitle')}</div>
      <div className="text-label leading-5 text-text-faint">{t('pluginLogs.emptyHint')}</div>
      {showAction ? (
        <Link className="zds-state-layer mt-1.5 inline-flex h-field items-center rounded-pill bg-primary-container px-4 text-label font-medium text-on-primary-container md:h-ctl" to="/extensions">
          {t('pluginLogs.goToExtensions')}
        </Link>
      ) : null}
    </div>
  )
}

/**
 * Paused, inactive and disconnected used to be three independent conditional
 * banners that could all be true at once — on mobile that was three stacked
 * rows on top of two filter rows and the search row, pushing the table below
 * six rows of chrome inside a viewport that gives it ~280px. They are now one
 * banner: the highest-priority condition owns the row, and anything else still
 * true is appended as supplementary text on the same line.
 */
type BannerTone = 'error' | 'neutral' | 'warning'

interface StatusBannerModel {
  tone: BannerTone
  text: string
  /** Lower-priority condition that is also true, shown inline after a `·`. */
  secondary: string | null
  reconnect: boolean
}

const BANNER_TONE: Record<BannerTone, string> = {
  error: 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]',
  warning: 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
  neutral: 'bg-surface-container-low text-text-soft',
}

const BANNER_DOT: Record<BannerTone, string> = {
  error: 'var(--color-red)',
  warning: 'var(--color-amber)',
  neutral: 'var(--color-text-faint)',
}

function StatusBanner({ banner, mobile, onReconnect, t }: { banner: StatusBannerModel; mobile: boolean; onReconnect: () => void; t: TFunction }) {
  return (
    <div
      role="status"
      data-testid="plugin-logs-status-banner"
      className={cn(
        'flex items-center gap-2 text-meta font-medium',
        BANNER_TONE[banner.tone],
        mobile ? 'rounded-ctl px-3 py-2' : 'px-[18px] py-2',
      )}
    >
      <StatusDot className="h-[7px] w-[7px] shrink-0" color={BANNER_DOT[banner.tone]} />
      <span className="min-w-0 flex-1">
        {banner.text}
        {banner.secondary ? <span className="opacity-80"> · {banner.secondary}</span> : null}
      </span>
      {banner.reconnect ? (
        <button
          type="button"
          onClick={onReconnect}
          className="zds-state-layer inline-flex h-chip shrink-0 items-center gap-1 rounded-pill px-2.5 text-meta font-semibold underline-offset-2 hover:underline"
        >
          <RefreshIcon className="h-3.5 w-3.5" aria-hidden="true" />
          {t('pluginLogs.reconnectNow')}
        </button>
      ) : null}
    </div>
  )
}

function LevelFilters({ value, onChange, mobile, t }: { value: LevelFilter; onChange: (value: LevelFilter) => void; mobile: boolean; t: TFunction }) {
  return (
    <FilterChips
      outlined
      scrollOnMobile={false}
      ariaLabel={t('pluginLogs.levelFilterLabel')}
      value={value}
      onChange={(next) => onChange(next as LevelFilter)}
      className={cn(mobile && 'min-w-max')}
      options={(['all', ...LEVELS] as LevelFilter[]).map((level) => ({
        value: level,
        label: level === 'all' ? t('pluginLogs.allLevels') : t(`pluginLogs.level.${level}`),
        swatch: level === 'all' ? undefined : LEVEL_DOT[level],
      }))}
    />
  )
}

export default function PluginLogsPage() {
  const { t } = useTranslation()
  const status = useContext(StatusContext)
  const isMobile = useMediaQuery('(max-width: 767px)')
  const [paused, setPaused] = useState(false)
  const [level, setLevel] = useState<LevelFilter>('all')
  const [plugin, setPlugin] = useState(ALL_PLUGINS)
  const [query, setQuery] = useState('')
  const [debouncedQuery, setDebouncedQuery] = useState('')
  const [modules, setModules] = useState<InterceptModule[]>([])
  const [clearedWatermark, setClearedWatermark] = useState(0)
  const [expandedId, setExpandedId] = useState<number | null>(null)
  const [bufferedBaseline, setBufferedBaseline] = useState(0)
  const [filtersOpen, setFiltersOpen] = useState(false)
  const checking = Boolean(status?.interceptLoading)
  const inactive = Boolean(status && !checking && status.interceptState === 'healthy' && status.intercept?.expected === false)
  // Subscribe immediately so a slow health probe cannot create an artificial
  // gap in this non-replaying stream. A confirmed idle state then closes the
  // socket and suppresses future reconnects.
  const streamEnabled = !inactive
  const { entries, connected, bufferedCount, getCurrentWatermarks, reconnect } = usePluginEngineLogs({ paused, enabled: streamEnabled })

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedQuery(query), SEARCH_DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [query])

  useEffect(() => {
    let active = true
    void api.getInterceptModules().then((view) => {
      if (active) setModules([...view.modules].sort((left, right) => left.execution_order - right.execution_order))
    }).catch(() => {
      if (active) setModules([])
    })
    return () => { active = false }
  }, [])

  const moduleNames = useMemo(() => new Map(modules.map((module) => [module.id, module.name])), [modules])
  // `modules` is kept sorted by execution_order, so the slot a plugin gets is
  // its position in the pipeline rather than a hash of its id.
  const pluginColors = useMemo(
    () => new Map(modules.map((module, index) => [module.id, PLUGIN_SLOTS[index % PLUGIN_SLOTS.length]])),
    [modules],
  )
  const pluginDot = useCallback(
    (extension?: string) => (extension ? pluginColors.get(extension) ?? NO_PLUGIN_DOT : NO_PLUGIN_DOT),
    [pluginColors],
  )
  const pluginName = useCallback((entry: PluginEngineLogEntry) => {
    if (!entry.extension) return t('pluginLogs.engineTag')
    return moduleNames.get(entry.extension) ?? entry.extension
  }, [moduleNames, t])
  const actionName = useCallback((entry: PluginEngineLogEntry) => entry.action || t('pluginLogs.emptyAction'), [t])

  const searchNeedle = debouncedQuery.trim().toLocaleLowerCase()
  const afterClear = useMemo(() => entries.filter((entry) => entry.id > clearedWatermark), [clearedWatermark, entries])
  const searchMatches = useCallback((entry: PluginEngineLogEntry) => {
    if (!searchNeedle) return true
    return `${entry.message} ${entry.extension ?? ''} ${pluginName(entry)} ${entry.action ?? ''}`.toLocaleLowerCase().includes(searchNeedle)
  }, [pluginName, searchNeedle])
  const countBase = useMemo(
    () => afterClear.filter((entry) => (level === 'all' || entry.level === level) && searchMatches(entry)),
    [afterClear, level, searchMatches],
  )
  const visibleEntries = useMemo(
    () => countBase.filter((entry) => plugin === ALL_PLUGINS || entry.extension === plugin),
    [countBase, plugin],
  )
  const pluginCounts = useMemo(() => {
    const counts = new Map<string, number>()
    for (const entry of countBase) {
      if (entry.extension) counts.set(entry.extension, (counts.get(entry.extension) ?? 0) + 1)
    }
    return counts
  }, [countBase])
  const pluginItems = useMemo<SelectItem[]>(() => [
    { value: ALL_PLUGINS, label: t('pluginLogs.allPlugins'), count: countBase.length },
    ...modules.map((module) => ({
      value: module.id,
      label: module.name,
      count: pluginCounts.get(module.id) ?? 0,
    })),
  ], [countBase.length, modules, pluginCounts, t])

  const displayedBufferedCount = paused ? Math.max(0, bufferedCount - bufferedBaseline) : 0
  const showEmptyAction = entries.length === 0 && clearedWatermark === 0 && level === 'all' && plugin === ALL_PLUGINS && !searchNeedle
  const activeFilterCount = (level === 'all' ? 0 : 1) + (plugin === ALL_PLUGINS ? 0 : 1)

  // Priority: disconnected > inactive > paused. Only the winner gets a row.
  const statusBanner = useMemo<StatusBannerModel | null>(() => {
    if (checking) return null
    const pausedText = paused ? t('pluginLogs.pausedHint', { count: displayedBufferedCount }) : null
    if (streamEnabled && !connected) {
      return { tone: 'error', text: t('pluginLogs.disconnectedBanner'), secondary: pausedText, reconnect: true }
    }
    if (inactive) return { tone: 'neutral', text: t('pluginLogs.inactive'), secondary: pausedText, reconnect: false }
    if (pausedText) return { tone: 'warning', text: pausedText, secondary: null, reconnect: false }
    return null
  }, [checking, connected, displayedBufferedCount, inactive, paused, streamEnabled, t])

  const togglePaused = useCallback(() => {
    setExpandedId(null)
    setBufferedBaseline(0)
    setPaused((value) => !value)
  }, [])
  const clear = useCallback(() => {
    const current = getCurrentWatermarks()
    const previousWatermark = clearedWatermark
    const previousBaseline = bufferedBaseline
    const hidden = afterClear.length
    setClearedWatermark(current.latestId)
    setExpandedId(null)
    setBufferedBaseline(paused ? current.bufferedCount : 0)
    // The watermark is a browser-side number over a ring the sidecar keeps
    // filling — nothing was destroyed, so an undo costs one setState and is
    // strictly better than the confirmation dialog this would otherwise need.
    toast.info(t('pluginLogs.clearedToast', { count: hidden }), {
      action: {
        label: t('common.undo'),
        onClick: () => {
          setClearedWatermark(previousWatermark)
          setBufferedBaseline(previousBaseline)
        },
      },
    })
  }, [afterClear.length, bufferedBaseline, clearedWatermark, getCurrentWatermarks, paused, t])
  const toggleExpanded = useCallback((entry: PluginEngineLogEntry) => {
    setExpandedId((current) => current === entry.id ? null : entry.id)
  }, [])

  const desktopColumns = useMemo<ColumnDef<PluginEngineLogEntry, unknown>[]>(() => [
    {
      accessorKey: 'time',
      header: t('pluginLogs.colTime'),
      meta: { width: 76, headerClassName: 'py-2 pl-[18px] pr-0', cellClassName: 'pl-[18px] pr-0 py-0' },
      cell: ({ row }) => <span className="font-mono text-meta text-text-faint">{formatTime(row.original.time, t('pluginLogs.missingValue'))}</span>,
    },
    {
      accessorKey: 'level',
      header: t('pluginLogs.colLevel'),
      meta: { width: 66, headerClassName: 'px-1.5 py-2', cellClassName: 'px-1.5 py-0' },
      cell: ({ row }) => <LevelBadge level={row.original.level} t={t} />,
    },
    {
      id: 'plugin-action',
      header: t('pluginLogs.colPluginAction'),
      meta: { width: 224, headerClassName: 'px-2 py-2', cellClassName: 'px-2 py-0' },
      cell: ({ row }) => {
        const entry = row.original
        return <div className="flex min-w-0 items-center gap-1.5"><StatusDot className="h-1.5 w-1.5 shrink-0" color={pluginDot(entry.extension)} /><span className="shrink-0 truncate font-mono text-label font-medium text-text-strong">{pluginName(entry)}</span><span className="truncate font-mono text-meta text-text-faint">· {actionName(entry)}</span></div>
      },
    },
    {
      accessorKey: 'message',
      header: t('pluginLogs.colMessage'),
      meta: { headerClassName: 'px-2 py-2', cellClassName: 'px-2 py-0' },
      cell: ({ row }) => {
        const entry = row.original
        return <div className="flex min-w-0 items-center gap-1.5">{entry.source === 'engine' ? <EngineTag t={t} /> : null}<span className={cn('truncate font-mono text-label', entry.level === 'error' ? 'text-red' : entry.level === 'warn' ? 'text-amber' : 'text-text-mid')}>{entry.message}</span></div>
      },
    },
    {
      id: 'expand',
      header: () => null,
      meta: { width: 34, headerClassName: 'p-0', cellClassName: 'p-0' },
      cell: ({ row }) => <ChevronDownIcon className={cn('mx-auto h-4 w-4 text-text-faint transition-transform', expandedId === row.original.id && 'rotate-180')} aria-hidden="true" />,
    },
  ], [actionName, expandedId, pluginDot, pluginName, t])

  const mobileColumns = useMemo<ColumnDef<PluginEngineLogEntry, unknown>[]>(() => [{
    id: 'mobile-log',
    header: () => null,
    meta: { cellClassName: 'p-0' },
    cell: ({ row }) => {
      const entry = row.original
      return (
        <div className="flex h-[58px] min-w-0 flex-col justify-center gap-1.5 px-3.5">
          <div className="flex min-w-0 items-center gap-2">
            <LevelBadge level={entry.level} t={t} />
            <StatusDot className="h-1.5 w-1.5 shrink-0" color={pluginDot(entry.extension)} />
            <span className="min-w-0 flex-1 truncate font-mono text-label font-medium text-text-strong">{pluginName(entry)} · {actionName(entry)}</span>
            <span className="shrink-0 font-mono text-meta text-text-faint">{formatTime(entry.time, t('pluginLogs.missingValue'))}</span>
          </div>
          <div className="flex min-w-0 items-center gap-1.5">
            {entry.source === 'engine' ? <EngineTag t={t} /> : null}
            <span className={cn('min-w-0 flex-1 truncate font-mono text-label', entry.level === 'error' ? 'text-red' : entry.level === 'warn' ? 'text-amber' : 'text-text-mid')}>{entry.message}</span>
          </div>
        </div>
      )
    },
  }], [actionName, pluginDot, pluginName, t])

  const rowAriaLabel = useCallback((entry: PluginEngineLogEntry) => {
    const action = t(expandedId === entry.id ? 'pluginLogs.collapseRow' : 'pluginLogs.expandRow')
    return `${action}: ${pluginName(entry)} · ${actionName(entry)} · ${entry.message.slice(0, 120)}`
  }, [actionName, expandedId, pluginName, t])
  const renderDesktopDetails = useCallback((entry: PluginEngineLogEntry) => <Details entry={entry} mobile={false} t={t} />, [t])
  const renderMobileDetails = useCallback((entry: PluginEngineLogEntry) => <Details entry={entry} mobile t={t} />, [t])
  const desktopRowHeight = useCallback((entry: PluginEngineLogEntry) => expandedId === entry.id ? DESKTOP_EXPANDED_HEIGHT : DESKTOP_ROW_HEIGHT, [expandedId])
  const mobileRowHeight = useCallback((entry: PluginEngineLogEntry) => expandedId === entry.id ? MOBILE_EXPANDED_HEIGHT : MOBILE_ROW_HEIGHT, [expandedId])
  const rowExpanded = useCallback((entry: PluginEngineLogEntry) => expandedId === entry.id, [expandedId])
  const rowClass = useCallback((entry: PluginEngineLogEntry) => expandedId === entry.id ? 'bg-surface-container-low' : undefined, [expandedId])

  const pauseButton = (mobile: boolean) => (
    <LiveToggle
      live={!paused}
      onToggle={togglePaused}
      // Ingestion never stops here; only the rendered snapshot freezes, and
      // the label carries the count that accumulated behind it.
      liveLabel={mobile ? '' : t('pluginLogs.live')}
      pausedLabel={mobile ? '' : t('pluginLogs.pausedBuffered', { count: displayedBufferedCount })}
      pauseAction={t('pluginLogs.pause')}
      resumeAction={t('pluginLogs.resume')}
      className={mobile ? 'w-field justify-center px-0 md:h-field' : undefined}
    />
  )
  const clearButton = (mobile: boolean) => (
    <button
      type="button"
      onClick={clear}
      aria-label={t('pluginLogs.clearLabel')}
      className={cn('zds-state-layer inline-flex shrink-0 items-center justify-center border border-outline-variant text-text-soft', mobile ? 'h-field w-field rounded-pill' : 'h-chip gap-1.5 rounded-pill px-3 text-label')}
    >
      <DeleteSweepIcon className="h-[17px] w-[17px]" aria-hidden="true" />
      {!mobile ? t('pluginLogs.clear') : null}
    </button>
  )

  return (
    <div className="flex flex-col gap-3" data-testid="page-plugin-logs">
      <div className="hidden items-center gap-3 px-1 md:flex">
        <p className="min-w-[260px] flex-1 text-label text-text-faint">{t('pluginLogs.intro')}</p>
        <div className="flex items-center gap-2 text-label font-medium text-text-soft" role="status" aria-live="polite">
          <StatusDot color={checking ? 'var(--color-amber)' : inactive ? 'var(--color-text-faint)' : connected ? 'var(--color-green)' : 'var(--color-red)'} pulse={checking} />
          {checking ? t('common.healthChecking') : inactive ? t('pluginLogs.inactive') : connected ? t('pluginLogs.connected') : t('pluginLogs.disconnected')}
        </div>
      </div>

      {isMobile ? (
        <>
          <div className="flex items-center gap-2">
            <LogSearchField
              className="flex-1"
              value={query}
              onChange={setQuery}
              label={t('pluginLogs.searchLabel')}
              placeholder={t('pluginLogs.searchPlaceholder')}
            />
            <button
              type="button"
              onClick={() => setFiltersOpen(true)}
              aria-label={t('pluginLogs.filters')}
              className={cn(
                'zds-state-layer inline-flex h-field shrink-0 items-center justify-center gap-1 rounded-pill border border-outline-variant px-3 text-label font-medium',
                activeFilterCount > 0 ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft',
              )}
            >
              <TuneIcon className="h-[17px] w-[17px]" aria-hidden="true" />
              {activeFilterCount > 0 ? <span className="font-mono tabular-nums">{activeFilterCount}</span> : null}
            </button>
            {pauseButton(true)}
            {clearButton(true)}
          </div>
          {activeFilterCount > 0 ? (
            <div className="-mx-1 flex items-center gap-1.5 overflow-x-auto px-1" role="group" aria-label={t('pluginLogs.activeFilters')}>
              {level !== 'all' ? (
                <button
                  type="button"
                  onClick={() => setLevel('all')}
                  className="zds-state-layer inline-flex h-field shrink-0 items-center gap-1.5 rounded-pill bg-secondary-container px-3 text-label font-medium text-on-secondary-container"
                >
                  <StatusDot className="h-[7px] w-[7px]" color={LEVEL_DOT[level]} />
                  {t(`pluginLogs.level.${level}`)}
                  <CloseIcon className="h-3.5 w-3.5" aria-hidden="true" />
                  <span className="sr-only">{t('pluginLogs.clearFilter')}</span>
                </button>
              ) : null}
              {plugin !== ALL_PLUGINS ? (
                <button
                  type="button"
                  onClick={() => setPlugin(ALL_PLUGINS)}
                  className="zds-state-layer inline-flex h-field shrink-0 items-center gap-1.5 rounded-pill bg-secondary-container px-3 text-label font-medium text-on-secondary-container"
                >
                  <StatusDot className="h-[7px] w-[7px]" color={pluginDot(plugin)} />
                  {moduleNames.get(plugin) ?? plugin}
                  <CloseIcon className="h-3.5 w-3.5" aria-hidden="true" />
                  <span className="sr-only">{t('pluginLogs.clearFilter')}</span>
                </button>
              ) : null}
            </div>
          ) : null}
          {statusBanner ? <StatusBanner banner={statusBanner} mobile onReconnect={reconnect} t={t} /> : null}
          {/* Body and footer only: with no title, filters, search, actions or
              status, LogSurface emits neither chrome row, so the list stays a
              direct child of the card element. */}
          <LogSurface
            chrome={330}
            isEmpty={visibleEntries.length === 0}
            empty={<EmptyState showAction={showEmptyAction} t={t} />}
            footer={t('pluginLogs.footerMobile', { count: visibleEntries.length })}
          >
            {(height) => (
              <VirtualTable
                columns={mobileColumns}
                data={visibleEntries}
                rowHeight={MOBILE_ROW_HEIGHT}
                height={height}
                showHeader={false}
                getRowId={(entry) => String(entry.id)}
                getRowHeight={mobileRowHeight}
                getRowClassName={rowClass}
                getRowAriaLabel={rowAriaLabel}
                isRowExpanded={rowExpanded}
                onRowClick={toggleExpanded}
                renderRowDetails={renderMobileDetails}
              />
            )}
          </LogSurface>
        </>
      ) : (
        <LogSurface
          // 323, not 310: the toolbar search grew from 31px to the shared
          // 44px input step, and the band has to pay for it.
          chrome={323}
          title={t('pluginLogs.title')}
          // Rendered at 0 too — that is the state right after a clear.
          count={visibleEntries.length}
          // A title exists, so these ride the title row, where they are today.
          // The paused count used to be repeated there as well as on its own
          // banner; the merged status row owns it now.
          actions={<>{pauseButton(false)}{clearButton(false)}</>}
          filters={
            <>
              <Select value={plugin} onValueChange={setPlugin} items={pluginItems} variant="compact-count" ariaLabel={t('pluginLogs.pluginFilterLabel')} />
              <LevelFilters value={level} onChange={setLevel} mobile={false} t={t} />
            </>
          }
          search={
            <LogSearchField
              className="flex-1"
              value={query}
              onChange={setQuery}
              label={t('pluginLogs.searchLabel')}
              placeholder={t('pluginLogs.searchPlaceholder')}
            />
          }
          status={statusBanner ? <StatusBanner banner={statusBanner} mobile={false} onReconnect={reconnect} t={t} /> : undefined}
          isEmpty={visibleEntries.length === 0}
          empty={<EmptyState showAction={showEmptyAction} t={t} />}
          footer={t('pluginLogs.footer')}
          footerMeta={t('pluginLogs.transport')}
        >
          {(height) => (
            <VirtualTable
              columns={desktopColumns}
              data={visibleEntries}
              rowHeight={DESKTOP_ROW_HEIGHT}
              height={height}
              headerClassName="text-meta"
              showRowDividers
              getRowId={(entry) => String(entry.id)}
              getRowHeight={desktopRowHeight}
              getRowClassName={rowClass}
              getRowAriaLabel={rowAriaLabel}
              isRowExpanded={rowExpanded}
              onRowClick={toggleExpanded}
              renderRowDetails={renderDesktopDetails}
            />
          )}
        </LogSurface>
      )}

      {/* Mobile filter sheet. The two filter rows used to sit permanently above
          the table; with three banners also possible, the list could start six
          rows down inside a viewport that only gives it ~280px. */}
      <Modal open={filtersOpen} onOpenChange={setFiltersOpen} title={t('pluginLogs.filters')}>
        <div className="flex flex-col gap-5">
          <div className="flex flex-col gap-2">
            <div className="text-label font-medium text-text-soft">{t('pluginLogs.levelLabel')}</div>
            <LevelFilters value={level} onChange={setLevel} mobile t={t} />
          </div>
          <div className="flex flex-col gap-2">
            <div className="text-label font-medium text-text-soft">{t('pluginLogs.pluginLabel')}</div>
            <FilterChips
              outlined
              scrollOnMobile={false}
              ariaLabel={t('pluginLogs.pluginFilterLabel')}
              value={plugin}
              onChange={setPlugin}
              options={pluginItems.map((item) => ({
                value: item.value,
                label: item.label,
                swatch: item.value === ALL_PLUGINS ? undefined : pluginDot(item.value),
                count: item.count,
              }))}
            />
          </div>
        </div>
      </Modal>
    </div>
  )
}
