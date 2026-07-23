import { useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { TFunction } from 'i18next'
import type { ColumnDef } from '@tanstack/react-table'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  ChevronDownIcon,
  DeleteSweepIcon,
  PauseIcon,
  PlayIcon,
  SearchIcon,
  TerminalIcon,
} from '../../components/icons'
import { Badge, Card, Input, Select, StatusDot, type BadgeTone, type SelectItem } from '../../components/ds'
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
const PLUGIN_DOTS = [
  'var(--color-primary)',
  'var(--color-cyan)',
  'var(--color-indigo)',
  'var(--color-green)',
  'var(--color-amber)',
]

function pluginDot(extension?: string): string {
  if (!extension) return 'var(--color-text-faint)'
  let hash = 0
  for (let index = 0; index < extension.length; index += 1) hash = ((hash << 5) - hash + extension.charCodeAt(index)) | 0
  return PLUGIN_DOTS[Math.abs(hash) % PLUGIN_DOTS.length]
}

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
    <Badge className="min-w-[42px] justify-center rounded-[5px] px-[5px] py-0.5 font-mono text-[10px]" tone={LEVEL_TONE[level]}>
      {t(`pluginLogs.level.${level}`)}
    </Badge>
  )
}

function EngineTag({ t }: { t: TFunction }) {
  return <span className="shrink-0 rounded-[5px] bg-tertiary-container px-[5px] py-px text-[9px] font-semibold text-tertiary">{t('pluginLogs.engineTag')}</span>
}

function Details({ entry, mobile, t }: { entry: PluginEngineLogEntry; mobile: boolean; t: TFunction }) {
  const missing = t('pluginLogs.missingValue')
  if (mobile) {
    return (
      <div className="flex h-[118px] w-full flex-col gap-2 overflow-auto bg-surface-container-low px-3.5 pb-2.5 pt-1">
        <div className="rounded-[9px] bg-card px-2.5 py-2 font-mono text-[11px] leading-[1.55] text-text-mid break-all whitespace-pre-wrap">
          {entry.message}
        </div>
        <div className="flex flex-wrap gap-1.5">
          <span className="rounded-[6px] bg-surface-container px-2 py-0.5 font-mono text-[9.5px] text-text-soft">{t('pluginLogs.detail.phase')} {entry.phase ?? missing}</span>
          <span className="rounded-[6px] bg-surface-container px-2 py-0.5 font-mono text-[9.5px] text-text-soft">{t('pluginLogs.detail.duration')} {durationText(entry, t)}</span>
          <span className="rounded-[6px] bg-surface-container px-2 py-0.5 font-mono text-[9.5px] text-text-soft">{shortDigest(entry.script_digest, missing)}</span>
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
      <div className="rounded-[9px] border border-divider bg-card px-[11px] py-2 font-mono text-[11px] leading-[1.55] text-text-mid break-all whitespace-pre-wrap">
        {entry.message}
      </div>
      <div className="flex flex-wrap gap-x-7 gap-y-2">
        {metadata.map(([label, value]) => (
          <div key={label} className={cn('min-w-0', label === t('pluginLogs.detail.url') && 'max-w-full flex-1')}>
            <div className="mb-0.5 text-[10px] text-text-faint">{label}</div>
            <div className="font-mono text-[11px] text-text-mid break-all">{value}</div>
          </div>
        ))}
      </div>
    </div>
  )
}

function EmptyState({ showAction, t }: { showAction: boolean; t: TFunction }) {
  return (
    <div className="flex min-h-[260px] flex-col items-center justify-center gap-1.5 px-5 py-12 text-center">
      <span className="mb-1 grid h-12 w-12 place-items-center rounded-full bg-surface-container-low text-text-faint">
        <TerminalIcon className="h-6 w-6" aria-hidden="true" />
      </span>
      <div className="text-[13px] font-semibold text-text-strong">{t('pluginLogs.emptyTitle')}</div>
      <div className="text-[12px] leading-5 text-text-faint">{t('pluginLogs.emptyHint')}</div>
      {showAction ? (
        <Link className="zds-state-layer mt-1.5 inline-flex h-8 items-center rounded-full bg-primary-container px-4 text-[11.5px] font-medium text-on-primary-container" to="/extensions">
          {t('pluginLogs.goToExtensions')}
        </Link>
      ) : null}
    </div>
  )
}

function LevelFilters({ value, onChange, mobile, t }: { value: LevelFilter; onChange: (value: LevelFilter) => void; mobile: boolean; t: TFunction }) {
  return (
    <div className={cn('flex items-center gap-1.5', mobile && 'min-w-max')} role="group" aria-label={t('pluginLogs.levelFilterLabel')}>
      {(['all', ...LEVELS] as LevelFilter[]).map((level) => {
        const selected = value === level
        return (
          <button
            key={level}
            type="button"
            aria-pressed={selected}
            onClick={() => onChange(level)}
            className={cn(
              'zds-state-layer inline-flex items-center gap-1.5 rounded-full border border-outline-variant/60 px-[11px] font-medium',
              mobile ? 'h-[30px] text-[11.5px]' : 'h-7 text-[11px]',
              selected ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft',
            )}
          >
            {level !== 'all' ? <StatusDot className="h-[7px] w-[7px]" color={LEVEL_DOT[level]} /> : null}
            {level === 'all' ? t('pluginLogs.allLevels') : t(`pluginLogs.level.${level}`)}
          </button>
        )
      })}
    </div>
  )
}

function SearchField({ value, onChange, mobile, t }: { value: string; onChange: (value: string) => void; mobile: boolean; t: TFunction }) {
  return (
    <div className="relative min-w-0 flex-1">
      <SearchIcon className={cn('pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-faint', mobile ? 'h-[17px] w-[17px]' : 'h-4 w-4')} aria-hidden="true" />
      <Input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-label={t('pluginLogs.searchLabel')}
        placeholder={t('pluginLogs.searchPlaceholder')}
        className={cn('rounded-full bg-card pl-[33px] text-[11.5px]', mobile ? 'h-9' : 'h-[31px]')}
      />
    </div>
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
  const checking = Boolean(status?.interceptLoading)
  const inactive = Boolean(status && !checking && status.interceptState === 'healthy' && status.intercept?.expected === false)
  // Subscribe immediately so a slow health probe cannot create an artificial
  // gap in this non-replaying stream. A confirmed idle state then closes the
  // socket and suppresses future reconnects.
  const streamEnabled = !inactive
  const { entries, connected, bufferedCount, getCurrentWatermarks } = usePluginEngineLogs({ paused, enabled: streamEnabled })

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

  const togglePaused = useCallback(() => {
    setExpandedId(null)
    setBufferedBaseline(0)
    setPaused((value) => !value)
  }, [])
  const clear = useCallback(() => {
    const current = getCurrentWatermarks()
    setClearedWatermark(current.latestId)
    setExpandedId(null)
    setBufferedBaseline(paused ? current.bufferedCount : 0)
  }, [getCurrentWatermarks, paused])
  const toggleExpanded = useCallback((entry: PluginEngineLogEntry) => {
    setExpandedId((current) => current === entry.id ? null : entry.id)
  }, [])

  const desktopColumns = useMemo<ColumnDef<PluginEngineLogEntry, unknown>[]>(() => [
    {
      accessorKey: 'time',
      header: t('pluginLogs.colTime'),
      meta: { width: 76, headerClassName: 'py-2 pl-[18px] pr-0', cellClassName: 'pl-[18px] pr-0 py-0' },
      cell: ({ row }) => <span className="font-mono text-[10.5px] text-text-faint">{formatTime(row.original.time, t('pluginLogs.missingValue'))}</span>,
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
        return <div className="flex min-w-0 items-center gap-1.5"><StatusDot className="h-1.5 w-1.5 shrink-0" color={pluginDot(entry.extension)} /><span className="shrink-0 truncate font-mono text-[11px] font-medium text-text-strong">{pluginName(entry)}</span><span className="truncate font-mono text-[10.5px] text-text-faint">· {actionName(entry)}</span></div>
      },
    },
    {
      accessorKey: 'message',
      header: t('pluginLogs.colMessage'),
      meta: { headerClassName: 'px-2 py-2', cellClassName: 'px-2 py-0' },
      cell: ({ row }) => {
        const entry = row.original
        return <div className="flex min-w-0 items-center gap-1.5">{entry.source === 'engine' ? <EngineTag t={t} /> : null}<span className={cn('truncate font-mono text-[11px]', entry.level === 'error' ? 'text-red' : entry.level === 'warn' ? 'text-amber' : 'text-text-mid')}>{entry.message}</span></div>
      },
    },
    {
      id: 'expand',
      header: () => null,
      meta: { width: 34, headerClassName: 'p-0', cellClassName: 'p-0' },
      cell: ({ row }) => <ChevronDownIcon className={cn('mx-auto h-4 w-4 text-text-faint transition-transform', expandedId === row.original.id && 'rotate-180')} aria-hidden="true" />,
    },
  ], [actionName, expandedId, pluginName, t])

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
            <span className="min-w-0 flex-1 truncate font-mono text-[11.5px] font-medium text-text-strong">{pluginName(entry)} · {actionName(entry)}</span>
            <span className="shrink-0 font-mono text-[10.5px] text-text-faint">{formatTime(entry.time, t('pluginLogs.missingValue'))}</span>
          </div>
          <div className="flex min-w-0 items-center gap-1.5">
            {entry.source === 'engine' ? <EngineTag t={t} /> : null}
            <span className={cn('min-w-0 flex-1 truncate font-mono text-[11px]', entry.level === 'error' ? 'text-red' : entry.level === 'warn' ? 'text-amber' : 'text-text-mid')}>{entry.message}</span>
          </div>
        </div>
      )
    },
  }], [actionName, pluginName, t])

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
    <button
      type="button"
      onClick={togglePaused}
      aria-label={paused ? t('pluginLogs.resume') : t('pluginLogs.pause')}
      className={cn(
        'zds-state-layer inline-flex shrink-0 items-center justify-center font-medium',
        mobile ? 'h-9 w-9 rounded-full' : 'h-8 gap-1.5 rounded-full px-3 text-[11.5px]',
        paused ? 'bg-surface-container text-text-soft' : 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]',
      )}
    >
      {paused ? <PlayIcon className="h-[17px] w-[17px]" aria-hidden="true" /> : <PauseIcon className="h-[17px] w-[17px]" aria-hidden="true" />}
      {!mobile ? paused ? t('pluginLogs.pausedBuffered', { count: displayedBufferedCount }) : t('pluginLogs.live') : null}
    </button>
  )
  const clearButton = (mobile: boolean) => (
    <button
      type="button"
      onClick={clear}
      aria-label={t('pluginLogs.clearLabel')}
      className={cn('zds-state-layer inline-flex shrink-0 items-center justify-center border border-outline-variant text-text-soft', mobile ? 'h-9 w-9 rounded-full' : 'h-8 gap-1.5 rounded-full px-3 text-[11.5px]')}
    >
      <DeleteSweepIcon className="h-[17px] w-[17px]" aria-hidden="true" />
      {!mobile ? t('pluginLogs.clear') : null}
    </button>
  )

  return (
    <div className="flex flex-col gap-3" data-testid="page-plugin-logs">
      <div className="hidden items-center gap-3 px-1 md:flex">
        <p className="min-w-[260px] flex-1 text-[12.5px] leading-5 text-text-faint">{t('pluginLogs.intro')}</p>
        <div className="flex items-center gap-2 text-[11.5px] font-medium text-text-soft" role="status" aria-live="polite">
          <StatusDot color={checking ? 'var(--color-amber)' : inactive ? 'var(--color-text-faint)' : connected ? 'var(--color-green)' : 'var(--color-red)'} pulse={checking} />
          {checking ? t('common.healthChecking') : inactive ? t('pluginLogs.inactive') : connected ? t('pluginLogs.connected') : t('pluginLogs.disconnected')}
        </div>
      </div>

      {isMobile ? (
        <>
          <div className="flex items-center gap-2">
            <SearchField value={query} onChange={setQuery} mobile t={t} />
            {pauseButton(true)}
            {clearButton(true)}
          </div>
          <div className="flex items-center gap-1.5 overflow-x-auto">
            <span className="w-[26px] shrink-0 text-[10px] font-medium text-text-faint">{t('pluginLogs.levelLabel')}</span>
            <LevelFilters value={level} onChange={setLevel} mobile t={t} />
          </div>
          <div className="flex items-center gap-1.5 overflow-x-auto">
            <span className="w-[26px] shrink-0 text-[10px] font-medium text-text-faint">{t('pluginLogs.pluginLabel')}</span>
            <div className="flex min-w-max items-center gap-1.5" role="group" aria-label={t('pluginLogs.pluginFilterLabel')}>
              {pluginItems.map((item) => {
                const selected = plugin === item.value
                return <button key={item.value} type="button" aria-pressed={selected} onClick={() => setPlugin(item.value)} className={cn('zds-state-layer inline-flex h-[30px] items-center gap-1.5 rounded-full border border-outline-variant/60 px-3 text-[11.5px] font-medium', selected ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft')}>{item.value !== ALL_PLUGINS ? <StatusDot className="h-[7px] w-[7px]" color={pluginDot(item.value)} /> : null}{item.label}</button>
              })}
            </div>
          </div>
          {paused ? <div className="flex items-center gap-2 rounded-[12px] bg-[var(--md-sys-color-warning-container)] px-3 py-2 text-[11px] font-medium text-[var(--md-sys-color-on-warning-container)]" role="status"><PauseIcon className="h-[15px] w-[15px]" aria-hidden="true" />{t('pluginLogs.pausedHint', { count: displayedBufferedCount })}</div> : null}
          {inactive ? <div className="flex items-center gap-2 rounded-[12px] bg-surface-container-low px-3 py-2 text-[11px] font-medium text-text-soft" role="status"><StatusDot className="h-[7px] w-[7px]" color="var(--color-text-faint)" />{t('pluginLogs.inactive')}</div> : null}
          {!checking && streamEnabled && !connected ? <div className="flex items-center gap-2 rounded-[12px] bg-[var(--md-sys-color-error-container)] px-3 py-2 text-[11px] font-medium text-[var(--md-sys-color-on-error-container)]" role="status"><StatusDot className="h-[7px] w-[7px]" color="var(--color-red)" />{t('pluginLogs.disconnectedBanner')}</div> : null}
          <Card className="overflow-hidden p-0 shadow-none">
            {visibleEntries.length === 0 ? <EmptyState showAction={showEmptyAction} t={t} /> : (
              <VirtualTable
                columns={mobileColumns}
                data={visibleEntries}
                rowHeight={MOBILE_ROW_HEIGHT}
                height="clamp(280px, calc(100dvh - 330px), 560px)"
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
            <div className="border-t border-divider px-3.5 py-2 text-[10.5px] text-text-faint">{t('pluginLogs.footerMobile', { count: visibleEntries.length })}</div>
          </Card>
        </>
      ) : (
        <Card className="overflow-hidden p-0 shadow-none">
          <div className="flex items-center gap-2.5 border-b border-divider px-[18px] py-3">
            <span className="text-[14px] font-semibold text-text-strong">{t('pluginLogs.title')}</span>
            <span className="rounded-full bg-surface-container-low px-2 py-0.5 font-mono text-[10.5px] text-text-soft">{visibleEntries.length}</span>
            {paused ? <span className="text-[10.5px] font-medium text-amber">{t('pluginLogs.pausedHint', { count: displayedBufferedCount })}</span> : null}
            <div className="min-w-2 flex-1" />
            {pauseButton(false)}
            {clearButton(false)}
          </div>
          <div className="flex items-center gap-2 border-b border-divider bg-bg px-[18px] py-2.5">
            <Select value={plugin} onValueChange={setPlugin} items={pluginItems} variant="compact-count" ariaLabel={t('pluginLogs.pluginFilterLabel')} />
            <LevelFilters value={level} onChange={setLevel} mobile={false} t={t} />
            <SearchField value={query} onChange={setQuery} mobile={false} t={t} />
          </div>
          {inactive ? <div className="flex items-center gap-2 bg-surface-container-low px-[18px] py-2 text-[11px] font-medium text-text-soft" role="status"><StatusDot color="var(--color-text-faint)" />{t('pluginLogs.inactive')}</div> : null}
          {!checking && streamEnabled && !connected ? <div className="flex items-center gap-2 bg-[var(--md-sys-color-error-container)] px-[18px] py-2 text-[11px] font-medium text-[var(--md-sys-color-on-error-container)]" role="status"><StatusDot color="var(--color-red)" />{t('pluginLogs.disconnectedBanner')}</div> : null}
          {visibleEntries.length === 0 ? <EmptyState showAction={showEmptyAction} t={t} /> : (
            <VirtualTable
              columns={desktopColumns}
              data={visibleEntries}
              rowHeight={DESKTOP_ROW_HEIGHT}
              height="clamp(280px, calc(100dvh - 310px), 520px)"
              headerClassName="text-[10px]"
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
          <div className="flex items-center justify-between gap-3 border-t border-divider px-[18px] py-2 text-[10.5px] text-text-faint">
            <span>{t('pluginLogs.footer')}</span>
            <span className="font-mono">{t('pluginLogs.transport')}</span>
          </div>
        </Card>
      )}
    </div>
  )
}
