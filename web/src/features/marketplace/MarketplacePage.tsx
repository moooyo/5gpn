import { useCallback, useEffect, useMemo, useState, type ComponentType, type ReactNode, type SVGProps } from 'react'
import { useTranslation } from 'react-i18next'
import { useNavigate } from 'react-router-dom'
import {
  AddIcon,
  AddLinkIcon,
  BadgeIcon,
  BalanceIcon,
  BoltIcon,
  CheckCircleIcon,
  CloudIcon,
  DeleteIcon,
  DnsIcon,
  DownloadIcon,
  ExtensionFilledIcon,
  ExternalLinkIcon,
  LinkIcon,
  LocationIcon,
  NetworkIcon,
  PlayIcon,
  ProgressIcon,
  RefreshIcon,
  RocketIcon,
  SearchIcon,
  SettingsIcon,
  ShieldFilledIcon,
  SortIcon,
  TagIcon,
  VerifiedIcon,
} from '../../components/icons'
import { Button, Card, ConfirmDialog, Field, Modal, Select, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { InterceptModule, InterceptModulesView, MarketplaceEntry, MarketplaceSource, MarketplacesView } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { ExtensionInstallReview } from '../extensions/ExtensionInstallReview'

type SortKey = 'source-updated' | 'name'
type Icon = ComponentType<SVGProps<SVGSVGElement>>
type MarketplaceItem = { source: MarketplaceSource; entry: MarketplaceEntry }

const AVATAR_TONES = [
  'bg-primary-container text-on-primary-container',
  'bg-secondary-container text-on-secondary-container',
  'bg-tertiary-container text-tertiary',
  'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]',
  'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
  'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]',
]

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function hostFromURL(value: string): string {
  try {
    return new URL(value).hostname
  } catch {
    return value
  }
}

function stableIndex(value: string, length: number): number {
  let hash = 0
  for (const char of value) hash = ((hash * 31) + char.charCodeAt(0)) >>> 0
  return hash % length
}

function entryIcon(entry: MarketplaceEntry): Icon {
  const text = `${entry.id} ${entry.name} ${entry.tags.join(' ')}`.toLocaleLowerCase()
  if (text.includes('location') || text.includes('wloc')) return LocationIcon
  if (text.includes('youtube') || text.includes('spotify') || text.includes('media')) return PlayIcon
  if (text.includes('testflight') || text.includes('region')) return RocketIcon
  if (text.includes('dns')) return NetworkIcon
  if (text.includes('block') || text.includes('privacy') || text.includes('cleaner')) return ShieldFilledIcon
  return ExtensionFilledIcon
}

function validMarketplaceURL(value: string): boolean {
  try {
    const parsed = new URL(value)
    return parsed.protocol === 'https:' && parsed.username === '' && parsed.password === '' && parsed.hash === ''
  } catch {
    return false
  }
}

function MarketplaceAvatar({ entry, size = 'card' }: { entry: MarketplaceEntry; size?: 'card' | 'dialog' }) {
  const IconComponent = entryIcon(entry)
  const tone = AVATAR_TONES[stableIndex(entry.id, AVATAR_TONES.length)]
  return (
    <span className={cn(
      'grid shrink-0 place-items-center rounded-[16px]',
      size === 'card' ? 'h-14 w-14' : 'h-12 w-12',
      tone,
    )}>
      <IconComponent className={size === 'card' ? 'h-[30px] w-[30px]' : 'h-6 w-6'} aria-hidden="true" />
    </span>
  )
}

function MetaChip({ icon: IconComponent, children, tone = 'neutral', mono = false }: {
  icon?: Icon
  children: ReactNode
  tone?: 'blue' | 'amber' | 'neutral' | 'outline' | 'cyan' | 'indigo'
  mono?: boolean
}) {
  const toneClass = {
    blue: 'bg-primary-container text-on-primary-container',
    amber: 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
    neutral: 'bg-surface-container-high text-text-soft',
    outline: 'border border-outline bg-transparent text-text-soft',
    cyan: 'bg-secondary-container text-on-secondary-container',
    indigo: 'bg-tertiary-container text-tertiary',
  }[tone]
  return (
    <span className={cn('inline-flex min-h-7 items-center gap-1.5 rounded-[8px] px-2.5 py-1 text-[11.5px] font-medium', toneClass, mono && 'font-mono')}>
      {IconComponent ? <IconComponent className="h-3.5 w-3.5" aria-hidden="true" /> : null}
      {children}
    </span>
  )
}

function SourceChip({ source, selected, warning, count, onClick }: {
  source?: MarketplaceSource
  selected: boolean
  warning?: boolean
  count: number
  onClick: () => void
}) {
  const { t } = useTranslation()
  const label = source?.name ?? t('marketplace.allSources')
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      title={source ? `${t('marketplace.publisherIdentity', { name: source.metadata_name })}\n${source.final_url}\n${t('marketplace.lastRefreshed', { value: new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(source.fetched_at)) })}` : undefined}
      className={cn(
        'zds-state-layer inline-flex h-10 shrink-0 items-center gap-2 rounded-full px-[18px] text-[13.5px] font-medium outline-none transition-[box-shadow,background-color,color]',
        selected ? 'border border-transparent bg-secondary-container text-on-secondary-container' : 'border border-outline bg-transparent text-text-strong hover:shadow-[var(--md-sys-elevation-1)]',
      )}
    >
      {source ? <span className={cn('h-2 w-2 rounded-full', warning ? 'bg-amber' : 'bg-green')} aria-hidden="true" /> : null}
      <span className="max-w-[210px] truncate">{label}</span>
      <span className={selected ? 'opacity-80' : 'text-text-faint'}>{count}</span>
      {source ? <span className="sr-only">{warning ? t('marketplace.sourceWarning') : t('marketplace.sourceCached')}</span> : null}
    </button>
  )
}

function MarketplaceCard({ item, installed, busy, onInstall, onManage }: {
  item: MarketplaceItem
  installed?: InterceptModule
  busy: boolean
  onInstall: () => void
  onManage: () => void
}) {
  const { t } = useTranslation()
  const { entry, source } = item
  const sourceDomain = hostFromURL(entry.manifest_url)
  const documentationURL = entry.documentation_url || source.homepage || entry.manifest_url
  return (
    <article
      className="zds-card flex min-w-0 flex-col gap-4 rounded-[20px] bg-surface-container-low px-5 py-[18px] sm:flex-row sm:gap-[18px]"
      aria-labelledby={`marketplace-${source.id}-${entry.id}`}
      data-testid={`marketplace-entry-${entry.id}`}
    >
      <MarketplaceAvatar entry={entry} />
      <div className="flex min-w-0 flex-1 flex-col gap-[7px]">
        <div className="min-w-0 truncate">
          <h2 id={`marketplace-${source.id}-${entry.id}`} className="inline text-[17px] font-medium text-text-strong">{entry.name}</h2>
          <span className="ml-2 text-[12.5px] font-medium text-primary">v{entry.version}</span>
        </div>
        <div className="truncate text-[12.5px] text-text-faint">
          <span className="font-mono">{entry.id}</span>
          <span className="mx-[7px] opacity-40">·</span>{sourceDomain}
          <span className="mx-[7px] opacity-40">·</span>{source.metadata_name}
        </div>
        {entry.description ? <p className="max-w-[760px] text-pretty text-[13.5px] leading-[1.5] text-text-soft">{entry.description}</p> : null}
        <div className="mt-1 flex flex-wrap items-center gap-[7px]">
          <MetaChip icon={DnsIcon} tone="blue">{t('marketplace.captureCount', { count: entry.capabilities.capture_host_count })}</MetaChip>
          <MetaChip icon={BoltIcon} tone="amber">{t('marketplace.actionCount', { count: entry.capabilities.action_count })}</MetaChip>
          {entry.tags.map((tag) => <MetaChip key={tag}>{tag}</MetaChip>)}
          {entry.license ? <MetaChip icon={BalanceIcon} tone="outline">{entry.license.spdx}</MetaChip> : null}
          <MetaChip icon={TagIcon} mono>{entry.manifest_digest.slice(0, 10)}…</MetaChip>
          {entry.capabilities.setting_count > 0 ? <MetaChip tone="indigo">{t('marketplace.settingCount', { count: entry.capabilities.setting_count })}</MetaChip> : null}
          {entry.capabilities.network_origins.length > 0 ? <MetaChip tone="cyan">{t('marketplace.networkCount', { count: entry.capabilities.network_origins.length })}</MetaChip> : null}
          {(entry.capabilities.routing_rule_count ?? 0) > 0 ? <MetaChip tone="amber">{t('marketplace.routingCount', { count: entry.capabilities.routing_rule_count })}</MetaChip> : null}
          {entry.capabilities.persistent_storage ? <MetaChip tone="indigo">{t('marketplace.persistentStorage')}</MetaChip> : null}
          {entry.capabilities.egress_group_required ? <MetaChip tone="cyan">{t('marketplace.egressRequired')}</MetaChip> : null}
        </div>
      </div>
      <div className="flex shrink-0 items-center justify-between gap-3 sm:min-w-[170px] sm:flex-col sm:items-end">
        <span className={cn(
          'inline-flex min-h-7 items-center gap-1.5 rounded-[8px] px-2.5 py-1 text-[12px] font-medium',
          installed ? 'bg-secondary-container text-on-secondary-container' : 'border border-outline text-text-soft',
        )}>
          {installed ? <CheckCircleIcon className="h-4 w-4" aria-hidden="true" /> : null}
          {installed ? t('marketplace.installed') : t('marketplace.available')}
        </span>
        <div className="flex items-center gap-2">
          <a
            href={documentationURL}
            target="_blank"
            rel="noreferrer"
            aria-label={t('marketplace.openDocumentation', { name: entry.name })}
            className="zds-state-layer grid h-10 w-10 place-items-center rounded-full border border-outline text-text-soft"
          >
            <ExternalLinkIcon className="h-[18px] w-[18px]" aria-hidden="true" />
          </a>
          {installed ? (
            <Button variant="secondary" className="h-10 px-4" onClick={onManage}>
              <SettingsIcon className="h-[18px] w-[18px]" aria-hidden="true" />
              {t('marketplace.manageSnapshot')}
            </Button>
          ) : (
            <Button className="h-10 px-[22px]" disabled={busy} onClick={onInstall}>
              {busy ? <ProgressIcon className="h-[18px] w-[18px] animate-spin" aria-hidden="true" /> : <DownloadIcon className="h-[18px] w-[18px]" aria-hidden="true" />}
              {busy ? t('marketplace.installing') : t('marketplace.installSnapshot')}
            </Button>
          )}
        </div>
      </div>
    </article>
  )
}

function ScopeRow({ icon: IconComponent, label, value, tone }: { icon: Icon; label: string; value: ReactNode; tone?: 'blue' | 'amber' }) {
  return (
    <div className="flex min-h-11 items-center gap-3 rounded-[10px] px-3">
      <IconComponent className={cn('h-5 w-5 shrink-0', tone === 'blue' ? 'text-primary' : tone === 'amber' ? 'text-amber' : 'text-text-soft')} aria-hidden="true" />
      <span className="text-[13.5px] text-text-strong">{label}</span>
      <span className="ml-auto max-w-[55%] truncate text-right text-[13px] font-medium text-text-soft">{value}</span>
    </div>
  )
}

export default function MarketplacePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [view, setView] = useState<MarketplacesView | null>(null)
  const [modulesView, setModulesView] = useState<InterceptModulesView | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [sourceID, setSourceID] = useState('all')
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<SortKey>('source-updated')
  const [refreshing, setRefreshing] = useState(false)
  const [sourceWarnings, setSourceWarnings] = useState<Set<string>>(() => new Set())
  const [addOpen, setAddOpen] = useState(false)
  const [addURL, setAddURL] = useState('')
  const [addName, setAddName] = useState('')
  const [addBusy, setAddBusy] = useState(false)
  const [pendingInstall, setPendingInstall] = useState<MarketplaceItem | null>(null)
  const [installBusy, setInstallBusy] = useState(false)
  const [installedReview, setInstalledReview] = useState<InterceptModule | null>(null)
  const [removeSource, setRemoveSource] = useState<MarketplaceSource | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(false)
    const [marketplaces, modules] = await Promise.allSettled([api.getMarketplaces(), api.getInterceptModules()])
    if (marketplaces.status === 'fulfilled') setView(marketplaces.value)
    else setLoadError(true)
    if (modules.status === 'fulfilled') setModulesView(modules.value)
    else setLoadError(true)
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  const allItems = useMemo<MarketplaceItem[]>(() => (
    view?.sources.flatMap((source) => source.entries.map((entry) => ({ source, entry }))) ?? []
  ), [view?.sources])
  const installedByID = useMemo(() => new Map((modulesView?.modules ?? []).map((module) => [module.id, module])), [modulesView?.modules])
  const visibleItems = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase()
    return allItems
      .filter((item) => sourceID === 'all' || item.source.id === sourceID)
      .filter(({ source, entry }) => !needle || `${entry.name} ${entry.id} ${entry.description ?? ''} ${entry.tags.join(' ')} ${entry.license?.spdx ?? ''} ${hostFromURL(entry.manifest_url)} ${source.name} ${source.metadata_name}`.toLocaleLowerCase().includes(needle))
      .sort((left, right) => {
        if (sort === 'name') return left.entry.name.localeCompare(right.entry.name)
        const byRefresh = right.source.fetched_at.localeCompare(left.source.fetched_at)
        return byRefresh || left.entry.name.localeCompare(right.entry.name)
      })
  }, [allItems, query, sort, sourceID])
  const selectedSource = view?.sources.find((source) => source.id === sourceID)

  async function addMarketplace() {
    if (!view || addBusy || !validMarketplaceURL(addURL.trim())) return
    setAddBusy(true)
    try {
      const next = await api.addMarketplace(view.revision, addURL.trim(), addName.trim() || undefined)
      const added = next.sources.find((source) => !view.sources.some((current) => current.id === source.id))
      setView(next)
      setSourceID(added?.id ?? 'all')
      setAddOpen(false)
      setAddURL('')
      setAddName('')
      toast.success(t('marketplace.added'))
    } catch (error) {
      toast.error(errorMessage(error, t('marketplace.addFailed')))
      void load()
    } finally {
      setAddBusy(false)
    }
  }

  async function refreshMarketplaces() {
    if (!view || refreshing || view.sources.length === 0) return
    setRefreshing(true)
    const ids = sourceID === 'all' ? view.sources.map((source) => source.id) : [sourceID]
    let current = view
    const failed = new Set(sourceWarnings)
    try {
      for (const id of ids) {
        try {
          current = await api.refreshMarketplace(id, current.revision)
          failed.delete(id)
        } catch (error) {
          failed.add(id)
          throw error
        }
      }
      setView(current)
      setSourceWarnings(failed)
      toast.success(t('marketplace.refreshed', { count: ids.length }))
    } catch (error) {
      setView(current)
      setSourceWarnings(failed)
      toast.error(errorMessage(error, t('marketplace.refreshFailed')))
      void load()
    } finally {
      setRefreshing(false)
    }
  }

  async function confirmInstall() {
    if (!pendingInstall || !view || !modulesView || installBusy) return
    setInstallBusy(true)
    try {
      const next = await api.installMarketplaceEntry(pendingInstall.source.id, pendingInstall.entry.id, view.revision, modulesView.revision)
      const actual = next.modules.find((module) => module.id === pendingInstall.entry.id)
      if (!actual) throw new Error(t('marketplace.installReviewMissing'))
      setModulesView(next)
      setInstalledReview(actual)
      toast.success(t('marketplace.installedClosed'))
    } catch (error) {
      toast.error(errorMessage(error, t('marketplace.installFailed')))
      setPendingInstall(null)
      void load()
    } finally {
      setInstallBusy(false)
    }
  }

  async function deleteMarketplace(source: MarketplaceSource) {
    if (!view) return
    try {
      const next = await api.deleteMarketplace(source.id, view.revision)
      setView(next)
      setSourceID('all')
      setSourceWarnings((current) => {
        const copy = new Set(current)
        copy.delete(source.id)
        return copy
      })
      toast.success(t('marketplace.deleted'))
    } catch (error) {
      toast.error(errorMessage(error, t('marketplace.deleteFailed')))
      void load()
    }
  }

  const installDialogOpen = pendingInstall !== null || installedReview !== null
  const installTitle = installedReview ? t('marketplace.installedReviewTitle') : t('marketplace.installConfirmTitle')

  return (
    <div className="flex flex-col gap-5" data-testid="page-marketplace">
      {loading && !view ? <Card className="p-10 text-center text-[13px] text-text-faint">{t('common.loading')}</Card> : null}
      {loadError && (!view || !modulesView) ? (
        <Card className="flex items-center justify-between gap-4 p-5">
          <span role="alert" className="text-[13px] text-red">{t('marketplace.loadFailed')}</span>
          <Button variant="secondary" onClick={() => void load()}>{t('marketplace.retry')}</Button>
        </Card>
      ) : null}

      {view && modulesView ? <>
        <section aria-labelledby="marketplace-sources-title">
          <div className="mb-3.5 flex flex-wrap items-center gap-3">
            <h1 id="marketplace-sources-title" className="text-[13px] font-bold text-text-strong">{t('marketplace.sources')}</h1>
            <span className="text-[12.5px] text-text-faint">{t('marketplace.connectedSources', { count: view.sources.length })}</span>
            <div className="flex-1" />
            {selectedSource ? (
              <button
                type="button"
                className="zds-state-layer grid h-10 w-10 place-items-center rounded-full text-red"
                aria-label={t('marketplace.deleteCurrentSource')}
                onClick={() => setRemoveSource(selectedSource)}
              >
                <DeleteIcon className="h-5 w-5" aria-hidden="true" />
              </button>
            ) : null}
            <Button variant="tonal" className="h-10 px-[18px]" onClick={() => setAddOpen(true)}>
              <AddLinkIcon className="h-5 w-5" aria-hidden="true" />
              {t('marketplace.addMarketplace')}
            </Button>
          </div>
          <div className="flex flex-wrap gap-2.5">
            <SourceChip selected={sourceID === 'all'} count={allItems.length} onClick={() => setSourceID('all')} />
            {view.sources.map((source) => (
              <SourceChip
                key={source.id}
                source={source}
                selected={sourceID === source.id}
                warning={sourceWarnings.has(source.id)}
                count={source.entries.length}
                onClick={() => setSourceID(source.id)}
              />
            ))}
          </div>
        </section>

        <div className="flex flex-col gap-3 lg:flex-row lg:items-center">
          <label className="flex h-12 w-full max-w-[460px] items-center gap-3 rounded-full bg-surface-container-high px-[18px] text-text-faint focus-within:ring-2 focus-within:ring-primary lg:flex-1">
            <SearchIcon className="h-[22px] w-[22px] shrink-0" aria-hidden="true" />
            <span className="sr-only">{t('marketplace.search')}</span>
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t('marketplace.searchPlaceholder')}
              className="min-w-0 flex-1 border-0 bg-transparent text-[13.5px] text-text-strong outline-none placeholder:text-text-faint"
            />
          </label>
          <div className="flex-1" />
          <div className="relative min-w-[210px]">
            <SortIcon className="pointer-events-none absolute left-[18px] top-1/2 z-10 h-5 w-5 -translate-y-1/2 text-text-soft" aria-hidden="true" />
            <Select
              ariaLabel={t('marketplace.sort')}
              value={sort}
              onValueChange={(value) => setSort(value as SortKey)}
              items={[
                { value: 'source-updated', label: t('marketplace.sortSourceUpdated') },
                { value: 'name', label: t('marketplace.sortName') },
              ]}
              className="h-12 rounded-full border-outline bg-transparent pl-12"
            />
          </div>
          <button
            type="button"
            className="zds-state-layer grid h-12 w-12 shrink-0 place-items-center rounded-full border border-outline text-text-soft disabled:opacity-40"
            aria-label={t('marketplace.refresh')}
            disabled={refreshing || view.sources.length === 0}
            onClick={() => void refreshMarketplaces()}
          >
            {refreshing ? <ProgressIcon className="h-5 w-5 animate-spin" aria-hidden="true" /> : <RefreshIcon className="h-5 w-5" aria-hidden="true" />}
          </button>
        </div>

        <div className="text-[13px] text-text-faint">
          {t('marketplace.resultCount', { count: visibleItems.length, source: selectedSource ? selectedSource.name : t('marketplace.allMarkets') })}
        </div>

        {view.sources.length === 0 ? (
          <Card className="flex flex-col items-center gap-3 rounded-[20px] bg-surface-container-low px-6 py-16 text-center">
            <AddLinkIcon className="h-12 w-12 text-text-faint opacity-60" aria-hidden="true" />
            <div className="text-[15px] font-medium text-text-strong">{t('marketplace.noSources')}</div>
            <p className="max-w-lg text-[13px] leading-5 text-text-faint">{t('marketplace.noSourcesHint')}</p>
            <Button variant="tonal" onClick={() => setAddOpen(true)}><AddIcon className="h-5 w-5" />{t('marketplace.addMarketplace')}</Button>
          </Card>
        ) : visibleItems.length > 0 ? (
          <div className="flex flex-col gap-3.5" aria-busy={installBusy || refreshing}>
            {visibleItems.map((item) => (
              <MarketplaceCard
                key={`${item.source.id}:${item.entry.id}`}
                item={item}
                installed={installedByID.get(item.entry.id)}
                busy={installBusy && pendingInstall?.entry.id === item.entry.id}
                onInstall={() => { setInstalledReview(null); setPendingInstall(item) }}
                onManage={() => void navigate('/extensions')}
              />
            ))}
          </div>
        ) : (
          <div className="flex flex-col items-center gap-2 py-[72px] text-center">
            <SearchIcon className="h-12 w-12 text-text-faint opacity-50" aria-hidden="true" />
            <div className="text-[15px] font-medium text-text-strong">{t('marketplace.noMatches')}</div>
            <p className="text-[13px] text-text-faint">{t('marketplace.noMatchesHint')}</p>
          </div>
        )}
      </> : null}

      <Modal
        open={addOpen}
        onOpenChange={(open) => {
          if (addBusy) return
          setAddOpen(open)
          if (!open) { setAddURL(''); setAddName('') }
        }}
        className="w-[min(92vw,472px)] bg-surface-container-high"
        title={<span className="flex items-center gap-3"><span className="grid h-12 w-12 place-items-center rounded-[16px] bg-primary-container text-on-primary-container"><AddLinkIcon className="h-6 w-6" aria-hidden="true" /></span>{t('marketplace.addTitle')}</span>}
        footer={<>
          <Button variant="ghost" disabled={addBusy} onClick={() => setAddOpen(false)}>{t('common.cancel')}</Button>
          <Button disabled={addBusy || !validMarketplaceURL(addURL.trim())} onClick={() => void addMarketplace()}>
            {addBusy ? <ProgressIcon className="h-5 w-5 animate-spin" aria-hidden="true" /> : <AddIcon className="h-5 w-5" aria-hidden="true" />}
            {addBusy ? t('marketplace.adding') : t('marketplace.addAndFetch')}
          </Button>
        </>}
      >
        <p className="mb-5 text-[14px] leading-[1.5] text-text-soft">{t('marketplace.addBody')}</p>
        <div className="space-y-4">
          <Field label={t('marketplace.url')} error={addURL && !validMarketplaceURL(addURL.trim()) ? t('marketplace.urlInvalid') : undefined}>
            <div className="flex h-[52px] items-center gap-2.5 rounded-[8px] border border-outline bg-transparent px-4 focus-within:border-primary focus-within:ring-1 focus-within:ring-primary">
              <LinkIcon className="h-5 w-5 shrink-0 text-text-soft" aria-hidden="true" />
              <input aria-label={t('marketplace.url')} value={addURL} onChange={(event) => setAddURL(event.target.value)} maxLength={4096} autoFocus className="min-w-0 flex-1 border-0 bg-transparent font-mono text-[13.5px] text-text-strong outline-none placeholder:text-text-faint" placeholder="https://example.com/marketplace.json" />
            </div>
          </Field>
          <Field label={t('marketplace.displayName')} supportingText={t('marketplace.displayNameHint')}>
            <div className="flex h-[52px] items-center gap-2.5 rounded-[8px] border border-outline bg-transparent px-4 focus-within:border-primary focus-within:ring-1 focus-within:ring-primary">
              <BadgeIcon className="h-5 w-5 shrink-0 text-text-soft" aria-hidden="true" />
              <input aria-label={t('marketplace.displayName')} value={addName} onChange={(event) => setAddName(event.target.value)} maxLength={128} className="min-w-0 flex-1 border-0 bg-transparent text-[14px] text-text-strong outline-none placeholder:text-text-faint" placeholder={t('marketplace.displayNamePlaceholder')} />
            </div>
          </Field>
        </div>
      </Modal>

      <Modal
        open={installDialogOpen}
        onOpenChange={(open) => {
          if (!open && !installBusy) { setPendingInstall(null); setInstalledReview(null) }
        }}
        className="w-[min(92vw,488px)] bg-surface-container-high"
        title={pendingInstall ? <span className="flex items-center gap-3"><MarketplaceAvatar entry={pendingInstall.entry} size="dialog" /><span><span className="block">{installTitle}</span><span className="block text-[13px] font-normal text-text-faint">{pendingInstall.entry.name} · v{pendingInstall.entry.version}</span></span></span> : installTitle}
        footer={installedReview ? (
          <Button onClick={() => { setPendingInstall(null); setInstalledReview(null) }}>{t('marketplace.finishReview')}</Button>
        ) : <>
          <Button variant="ghost" disabled={installBusy} onClick={() => setPendingInstall(null)}>{t('common.cancel')}</Button>
          <Button disabled={installBusy} onClick={() => void confirmInstall()}>
            {installBusy ? <ProgressIcon className="h-5 w-5 animate-spin" aria-hidden="true" /> : <DownloadIcon className="h-5 w-5" aria-hidden="true" />}
            {installBusy ? t('marketplace.installing') : t('marketplace.confirmInstall')}
          </Button>
        </>}
      >
        {installedReview ? <ExtensionInstallReview module={installedReview} /> : pendingInstall ? <>
          <p className="mb-4 text-[14px] leading-[1.5] text-text-soft">{t('marketplace.installBody')}</p>
          <div className="rounded-[14px] bg-surface-container p-1.5">
            <ScopeRow icon={DnsIcon} label={t('marketplace.captureHosts')} value={pendingInstall.entry.capabilities.capture_host_count} tone="blue" />
            <ScopeRow icon={BoltIcon} label={t('marketplace.gatewayActions')} value={pendingInstall.entry.capabilities.action_count} tone="amber" />
            <ScopeRow icon={NetworkIcon} label={t('marketplace.routingRules')} value={pendingInstall.entry.capabilities.routing_rule_count} tone="amber" />
            <ScopeRow icon={CloudIcon} label={t('marketplace.source')} value={hostFromURL(pendingInstall.entry.manifest_url)} />
            <ScopeRow icon={BalanceIcon} label={t('marketplace.license')} value={pendingInstall.entry.license?.spdx ?? t('marketplace.notDeclared')} />
          </div>
          <div className="mt-4 flex items-start gap-3 rounded-[12px] bg-surface-container px-3.5 py-3 text-[12.5px] leading-5 text-text-soft">
            <VerifiedIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
            {t('marketplace.egressReassurance')}
          </div>
        </> : null}
      </Modal>

      <ConfirmDialog
        open={removeSource !== null}
        onOpenChange={(open) => { if (!open) setRemoveSource(null) }}
        title={t('marketplace.deleteTitle', { name: removeSource?.name ?? '' })}
        description={t('marketplace.deleteBody')}
        confirmLabel={t('marketplace.deleteSource')}
        cancelLabel={t('common.cancel')}
        danger
        onConfirm={() => { if (removeSource) void deleteMarketplace(removeSource); setRemoveSource(null) }}
      />
    </div>
  )
}
