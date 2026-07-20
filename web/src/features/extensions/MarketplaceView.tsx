import { useCallback, useEffect, useMemo, useState, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { DeleteIcon, ExternalLinkIcon, FileSearchIcon, NetworkIcon, RefreshIcon, ShieldLockIcon } from '../../components/icons'
import { Badge, Button, Card, ConfirmDialog, Field, Input, Modal, SegmentedControl, Select, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { InterceptModule, InterceptModulesView, MarketplaceEntry, MarketplaceSource, MarketplacesView } from '../../lib/api/types'
import { ExtensionInstallReview } from './ExtensionInstallReview'

type EntryFilter = 'all' | 'available' | 'updates'

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function manifestHost(url: string): string {
  try { return new URL(url).hostname } catch { return url }
}

function ChainOfCustody() {
  const { t } = useTranslation()
  return <div className="zds-trace-rail rounded-[16px] bg-surface-container-low px-3 py-3" style={{ '--trace-steps': 3 } as CSSProperties} aria-label={t('extensions.marketplace.chainLabel')}>
    {['marketplace', 'manifest', 'snapshot'].map((step) => <div key={step} className="zds-trace-node"><span className="zds-trace-dot"><ShieldLockIcon className="h-4 w-4" aria-hidden="true" /></span><span className="text-[10.5px] font-medium text-text-strong">{t(`extensions.marketplace.chain.${step}`)}</span></div>)}
  </div>
}

function CapabilityBadges({ entry }: { entry: MarketplaceEntry }) {
  const { t } = useTranslation()
  const capability = entry.capabilities
  return <div className="flex flex-wrap gap-1.5">
    <Badge tone="blue">{t('extensions.captureCount', { count: capability.capture_host_count })}</Badge>
    <Badge tone="amber">{t('extensions.capabilityAction', { count: capability.action_count })}</Badge>
    {capability.setting_count > 0 ? <Badge tone="indigo">{t('extensions.settingsAction', { count: capability.setting_count })}</Badge> : null}
    {capability.network_origins.length > 0 ? <Badge tone="indigo"><NetworkIcon className="mr-1 inline h-3.5 w-3.5" aria-hidden="true" />{t('extensions.capabilityNetwork', { count: capability.network_origins.length })}</Badge> : null}
    {capability.persistent_storage ? <Badge tone="indigo">{t('extensions.capabilityStorage')}</Badge> : null}
    {capability.upstream_mapping_count > 0 ? <Badge tone="cyan">{t('extensions.capabilityHost', { count: capability.upstream_mapping_count })}</Badge> : null}
    {capability.egress_group_required ? <Badge tone="cyan">{t('extensions.marketplace.egressRequired')}</Badge> : null}
  </div>
}

function MarketplaceEntryCard({ source, entry, installed, onInstall, busy }: { source: MarketplaceSource; entry: MarketplaceEntry; installed?: InterceptModule; onInstall: () => void; busy: boolean }) {
  const { t } = useTranslation()
  const hasUpdate = !!installed && installed.extension_version !== entry.version
  return <article className="zds-card flex min-w-0 flex-col gap-3 p-4" aria-labelledby={`market-entry-${source.id}-${entry.id}`}>
    <div className="flex items-start justify-between gap-3"><div className="min-w-0"><h3 id={`market-entry-${source.id}-${entry.id}`} className="truncate text-[14px] font-semibold text-text-strong">{entry.name}</h3><p className="mt-1 text-[10.5px] text-text-faint">v{entry.version} · {manifestHost(entry.manifest_url)}</p></div><Badge tone={installed ? 'green' : 'neutral'}>{installed ? t('extensions.marketplace.installed') : t('extensions.marketplace.available')}</Badge></div>
    {entry.description ? <p className="line-clamp-3 min-h-12 text-[11.5px] leading-5 text-text-soft">{entry.description}</p> : <div className="min-h-12" />}
    <div className="flex flex-wrap gap-1.5">{entry.tags.map((tag) => <Badge key={tag} tone="neutral">{tag}</Badge>)}{entry.license ? entry.license.url ? <a className="zds-state-layer rounded-full bg-surface-container px-3 py-1 text-[11px] font-medium text-text-soft" href={entry.license.url} target="_blank" rel="noreferrer">{entry.license.spdx}</a> : <Badge tone="neutral">{entry.license.spdx}</Badge> : null}</div>
    <CapabilityBadges entry={entry} />
    <div className="mt-auto flex items-center justify-between gap-3 border-t border-divider pt-3"><code className="min-w-0 truncate font-mono text-[9px] text-text-faint" title={entry.manifest_digest}>{entry.manifest_digest.slice(0, 12)}…</code><div className="flex shrink-0 gap-1.5">{entry.documentation_url ? <a className="zds-state-layer grid h-11 w-11 place-items-center rounded-full text-primary sm:h-8 sm:w-8" href={entry.documentation_url} target="_blank" rel="noreferrer" aria-label={t('extensions.marketplace.documentation', { name: entry.name })}><ExternalLinkIcon className="h-4 w-4" aria-hidden="true" /></a> : null}<Button size="sm" disabled={busy || !!installed} title={hasUpdate ? t('extensions.marketplace.updateAvailable') : undefined} onClick={onInstall}>{installed ? (hasUpdate ? t('extensions.marketplace.updateAvailable') : t('extensions.marketplace.installed')) : t('extensions.marketplace.install')}</Button></div></div>
  </article>
}

export default function MarketplaceView({ modulesView, onModulesInstalled }: { modulesView: InterceptModulesView; onModulesInstalled: (view: InterceptModulesView) => void }) {
  const { t } = useTranslation()
  const [view, setView] = useState<MarketplacesView | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const [sourceID, setSourceID] = useState('')
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<EntryFilter>('all')
  const [addOpen, setAddOpen] = useState(false)
  const [url, setURL] = useState('')
  const [busyID, setBusyID] = useState<string | null>(null)
  const [removeSource, setRemoveSource] = useState<MarketplaceSource | null>(null)
  const [review, setReview] = useState<InterceptModule | null>(null)

  const load = useCallback(async () => { setLoading(true); setError(false); try { const next = await api.getMarketplaces(); setView(next); setSourceID((current) => current && next.sources.some((source) => source.id === current) ? current : (next.sources[0]?.id ?? '')) } catch { setError(true) } finally { setLoading(false) } }, [])
  useEffect(() => { void load() }, [load])
  const selectedSource = view?.sources.find((source) => source.id === sourceID) ?? view?.sources[0]
  const installed = useMemo(() => new Map(modulesView.modules.map((module) => [module.id, module])), [modulesView.modules])
  const entries = useMemo(() => (selectedSource?.entries ?? []).filter((entry) => { const match = `${entry.name} ${entry.id} ${entry.description ?? ''} ${entry.tags.join(' ')}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()); const current = installed.get(entry.id); return match && (filter === 'all' || (filter === 'available' && !current) || (filter === 'updates' && !!current && current.extension_version !== entry.version)) }), [filter, installed, query, selectedSource])

  async function addSource(nextURL = url) { if (!view || !nextURL.trim()) return; setBusyID('add'); try { const next = await api.addMarketplace(view.revision, nextURL.trim()); setView(next); setSourceID(next.sources.at(-1)?.id ?? ''); setAddOpen(false); setURL(''); toast.success(t('extensions.marketplace.added')) } catch (err) { toast.error(errorMessage(err, t('extensions.marketplace.addFailed'))); void load() } finally { setBusyID(null) } }
  async function refreshSource(source: MarketplaceSource) { if (!view) return; setBusyID(source.id); try { setView(await api.refreshMarketplace(source.id, view.revision)); toast.success(t('extensions.marketplace.refreshed')) } catch (err) { toast.error(errorMessage(err, t('extensions.marketplace.refreshFailed'))); void load() } finally { setBusyID(null) } }
  async function deleteSource(source: MarketplaceSource) { if (!view) return; setBusyID(source.id); try { const next = await api.deleteMarketplace(source.id, view.revision); setView(next); setSourceID(next.sources[0]?.id ?? ''); toast.success(t('extensions.marketplace.deleted')) } catch (err) { toast.error(errorMessage(err, t('extensions.marketplace.deleteFailed'))); void load() } finally { setBusyID(null) } }
  async function install(source: MarketplaceSource, entry: MarketplaceEntry) { if (!view) return; setBusyID(entry.id); try { const next = await api.installMarketplaceEntry(source.id, entry.id, view.revision, modulesView.revision); onModulesInstalled(next); const actual = next.modules.find((module) => module.id === entry.id); if (!actual) throw new Error(t('extensions.marketplace.installReviewMissing')); setReview(actual); toast.success(t('extensions.marketplace.installedClosed')) } catch (err) { toast.error(errorMessage(err, t('extensions.marketplace.installFailed'))); void load() } finally { setBusyID(null) } }

  if (loading && !view) return <Card><div className="p-8 text-center text-[12px] text-text-faint">{t('common.loading')}</div></Card>
  if (error && !view) return <Card><div className="flex items-center justify-between gap-3 p-5"><span role="alert" className="text-[12px] text-red">{t('extensions.marketplace.loadFailed')}</span><Button variant="secondary" onClick={() => void load()}>{t('extensions.retry')}</Button></div></Card>
  return <div className="space-y-4" data-testid="marketplace-view">
    <Card className="border-0 bg-primary-container p-5 text-on-primary-container"><div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between"><div className="max-w-2xl"><h2 className="text-[16px] font-semibold">{t('extensions.marketplace.title')}</h2><p className="mt-1 text-[11.5px] leading-5 opacity-85">{t('extensions.marketplace.intro')}</p></div><Button className="min-h-11 shrink-0" variant="secondary" onClick={() => setAddOpen(true)}><FileSearchIcon className="h-4 w-4" />{t('extensions.marketplace.add')}</Button></div><div className="mt-4"><ChainOfCustody /></div></Card>
    {view?.sources.length ? <><Card className="p-4"><div className="flex flex-col gap-3 lg:flex-row lg:items-center"><Select value={selectedSource?.id ?? ''} onValueChange={setSourceID} items={view.sources.map((source) => ({ value: source.id, label: source.name }))} className="min-w-0 flex-1" /><div className="flex gap-2"><Button variant="ghost" className="h-11 w-11 px-0 sm:h-8 sm:w-8" aria-label={t('extensions.marketplace.refresh')} disabled={busyID === selectedSource?.id} onClick={() => selectedSource && void refreshSource(selectedSource)}><RefreshIcon className="h-4 w-4" /></Button><Button variant="ghost" className="h-11 w-11 px-0 text-[var(--md-sys-color-error)] sm:h-8 sm:w-8" aria-label={t('extensions.marketplace.delete')} disabled={busyID === selectedSource?.id} onClick={() => setRemoveSource(selectedSource ?? null)}><DeleteIcon className="h-4 w-4" /></Button></div></div>{selectedSource ? <div className="mt-3 rounded-[14px] bg-surface-container-low p-3"><div className="flex flex-wrap items-center justify-between gap-2"><div><div className="text-[12px] font-medium text-text-strong">{selectedSource.name}</div><p className="mt-0.5 text-[10.5px] text-text-faint">{selectedSource.description}</p></div><a className="zds-state-layer inline-flex min-h-11 items-center gap-1 rounded-full px-3 text-[11px] font-medium text-primary sm:min-h-8" href={selectedSource.homepage ?? selectedSource.final_url} target="_blank" rel="noreferrer"><ExternalLinkIcon className="h-4 w-4" />{t('extensions.marketplace.homepage')}</a></div><div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[9.5px] text-text-faint"><span>{t('extensions.marketplace.fetchedAt', { value: new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(selectedSource.fetched_at)) })}</span><code title={selectedSource.digest} className="font-mono">{selectedSource.digest.slice(0, 12)}…</code></div></div> : null}</Card>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center"><SegmentedControl value={filter} onChange={(next) => setFilter(next as EntryFilter)} ariaLabel={t('extensions.marketplace.filter')} className="grid-cols-3" options={[{ value: 'all', label: t('extensions.filters.all') }, { value: 'available', label: t('extensions.marketplace.notInstalled') }, { value: 'updates', label: t('extensions.marketplace.updates') }]} /><Input value={query} onChange={(event) => setQuery(event.target.value)} aria-label={t('extensions.marketplace.search')} placeholder={t('extensions.marketplace.searchPlaceholder')} className="sm:ml-auto sm:max-w-[320px]" /></div>
      {entries.length ? <div className="grid gap-3 lg:grid-cols-2">{entries.map((entry) => <MarketplaceEntryCard key={entry.id} source={selectedSource!} entry={entry} installed={installed.get(entry.id)} busy={busyID !== null} onInstall={() => void install(selectedSource!, entry)} />)}</div> : <Card className="p-10 text-center"><div className="text-[13px] font-medium text-text-strong">{t('extensions.marketplace.noEntries')}</div><p className="mt-1 text-[11.5px] text-text-faint">{t('extensions.marketplace.noEntriesHint')}</p></Card>}</> : <Card className="p-10 text-center"><div className="text-[14px] font-semibold text-text-strong">{t('extensions.marketplace.empty')}</div><p className="mx-auto mt-2 max-w-xl text-[11.5px] leading-5 text-text-faint">{t('extensions.marketplace.emptyHint')}</p><Button className="mt-4 min-h-11" onClick={() => setAddOpen(true)}>{t('extensions.marketplace.add')}</Button></Card>}
    <Modal open={addOpen} onOpenChange={setAddOpen} title={t('extensions.marketplace.addTitle')} footer={<><Button variant="secondary" onClick={() => setAddOpen(false)}>{t('common.cancel')}</Button><Button disabled={busyID === 'add' || !url.trim()} onClick={() => void addSource()}>{t('extensions.marketplace.add')}</Button></>}><div className="space-y-4"><p className="text-[12px] leading-5 text-text-soft">{t('extensions.marketplace.addBody')}</p><Field label={t('extensions.marketplace.url')}><Input aria-label={t('extensions.marketplace.url')} mono value={url} placeholder="https://…/marketplace.json" onChange={(event) => setURL(event.target.value)} /></Field>{view?.recommended_url ? <Button variant="tonal" className="min-h-11" onClick={() => { setURL(view.recommended_url ?? ''); void addSource(view.recommended_url) }}>{t('extensions.marketplace.addRecommended')}</Button> : null}</div></Modal>
    <Modal open={!!review} onOpenChange={(open) => { if (!open) setReview(null) }} title={review ? t('extensions.marketplace.installReviewTitle', { name: review.name }) : ''} footer={<Button onClick={() => setReview(null)}>{t('extensions.install.closeReview')}</Button>}>{review ? <ExtensionInstallReview module={review} /> : null}</Modal>
    <ConfirmDialog open={!!removeSource} onOpenChange={(open) => { if (!open) setRemoveSource(null) }} title={t('extensions.marketplace.deleteTitle', { name: removeSource?.name ?? '' })} description={t('extensions.marketplace.deleteBody')} confirmLabel={t('extensions.marketplace.delete')} cancelLabel={t('common.cancel')} danger onConfirm={() => { if (removeSource) void deleteSource(removeSource); setRemoveSource(null) }} />
  </div>
}
