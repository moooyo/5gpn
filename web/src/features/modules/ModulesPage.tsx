import { useCallback, useEffect, useMemo, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ArrowRight,
  Boxes,
  Download,
  ExternalLink,
  FileLock2,
  FileSearch,
  Network,
  Plus,
  RefreshCw,
  ShieldCheck,
  Trash2,
} from 'lucide-react'
import {
  Badge,
  Button,
  Card,
  CardBody,
  ConfirmDialog,
  Field,
  Input,
  Modal,
  SegmentedControl,
  Toggle,
  toast,
} from '../../components/ds'
import { api } from '../../lib/api/client'
import type {
  InterceptModule,
  InterceptModuleFormat,
  InterceptModuleImport,
  InterceptModuleSnapshot,
  InterceptModulesView,
  WLOCInterceptView,
} from '../../lib/api/types'
import { WLOCInterceptCard } from './WLOCInterceptCard'

type ImportMode = 'url' | 'text'
type PendingAction = { kind: 'toggle' | 'delete' | 'partial'; module: InterceptModule } | null

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function formatLabel(format: InterceptModuleFormat, t: (key: string, options?: Record<string, unknown>) => string) {
  return t(`modules.${format}`)
}

function formatTone(format: InterceptModuleFormat): 'blue' | 'indigo' | 'cyan' {
  if (format === 'surge') return 'blue'
  if (format === 'loon') return 'indigo'
  return 'cyan'
}

function TransactionRail({ module }: { module: InterceptModule }) {
  const { t } = useTranslation()
  const steps = [
    { icon: FileLock2, label: t('modules.transaction.snapshot'), active: true },
    { icon: ShieldCheck, label: t('modules.transaction.trust'), active: module.enabled && module.ready },
    { icon: Network, label: t('modules.transaction.route'), active: module.enabled && module.ready },
  ]
  return (
    <div className="grid grid-cols-[1fr_auto_1fr_auto_1fr] items-center gap-2 rounded-[12px] border border-divider bg-input/60 px-3 py-2.5">
      {steps.map((step, index) => {
        const Icon = step.icon
        return (
          <div className="contents" key={step.label}>
            <div className="flex min-w-0 items-center justify-center gap-1.5">
              <span className={step.active ? 'text-primary' : 'text-text-faint'}><Icon className="h-3.5 w-3.5" /></span>
              <span className="truncate text-[10.5px] font-bold text-text-mid">{step.label}</span>
            </div>
            {index < steps.length - 1 ? <ArrowRight className="h-3 w-3 text-text-faint" /> : null}
          </div>
        )
      })}
    </div>
  )
}

function ModuleCard({
  module,
  busy,
  onToggle,
  onDelete,
  onSaveArgument,
  onInspect,
  onAcknowledge,
}: {
  module: InterceptModule
  busy: boolean
  onToggle: (module: InterceptModule) => void
  onDelete: (module: InterceptModule) => void
  onSaveArgument: (module: InterceptModule, argument: string) => void
  onInspect: (module: InterceptModule) => void
  onAcknowledge: (module: InterceptModule) => void
}) {
  const { t, i18n } = useTranslation()
  const [argument, setArgument] = useState(module.argument ?? '')
  const displayName = module.id === 'builtin-wloc' ? t('settings.wlocTitle') : module.name
  const displayDescription = module.id === 'builtin-wloc' ? t('modules.builtinDescription') : module.description

  useEffect(() => setArgument(module.argument ?? ''), [module.argument])

  const status = module.enabled ? (module.ready ? t('modules.enabled') : t('modules.degraded')) : t('modules.disabled')
  const statusTone = module.enabled ? (module.ready ? 'green' : 'amber') : 'neutral'
  const imported = module.imported_at ? new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium' }).format(new Date(module.imported_at)) : ''

  return (
    <Card className="overflow-hidden" data-testid={`module-${module.id}`}>
      <CardBody className="flex h-full flex-col gap-3.5 p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="mb-2 flex flex-wrap items-center gap-1.5">
              <Badge tone={formatTone(module.format)}>{formatLabel(module.format, t)}</Badge>
              <Badge tone={module.compatibility === 'full' ? 'green' : 'amber'}>
                {t(`modules.${module.compatibility}`)}
              </Badge>
              <Badge tone={statusTone}>{status}</Badge>
            </div>
            <h2 className="text-[15px] font-extrabold leading-tight text-text-strong">{displayName}</h2>
            {displayDescription ? <p className="mt-1.5 text-[12px] leading-relaxed text-text-soft">{displayDescription}</p> : null}
          </div>
          {module.format === 'builtin' ? (
            <span className="shrink-0 text-[10.5px] font-semibold text-primary">{t('modules.configureBelow')}</span>
          ) : (
            <Toggle
              checked={module.enabled}
              onCheckedChange={() => onToggle(module)}
              disabled={busy || (!module.enabled && (!module.ready || (module.compatibility === 'partial' && !module.partial_allowed)))}
              aria-label={module.enabled ? t('modules.toggleOff') : t('modules.toggleOn')}
            />
          )}
        </div>

        <TransactionRail module={module} />

        <div>
          <div className="mb-1.5 text-[10.5px] font-bold uppercase tracking-[.08em] text-text-faint">{t('modules.hosts')}</div>
          <div className="flex flex-wrap gap-1.5">
            {module.hosts.map((host) => (
              <code key={host} className="rounded-[6px] border border-border bg-input px-2 py-1 text-[10.5px] text-text-mid">{host}</code>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-2 gap-2 text-[11px] text-text-soft">
          <div className="rounded-[8px] bg-input px-2.5 py-2">{t('modules.scripts', { count: module.script_count })}</div>
          <div className="rounded-[8px] bg-input px-2.5 py-2">{t('modules.rewrites', { count: module.rewrite_count })}</div>
        </div>

        <div className="space-y-1 text-[10.5px] text-text-faint">
          <div className="flex items-center justify-between gap-3">
            <span>{t('modules.digest')}</span>
            <code className="max-w-[68%] truncate text-text-mid" title={module.source_digest}>{module.source_digest}</code>
          </div>
          {module.source_url ? (
            <div className="flex items-center justify-between gap-3">
              <span>{t('modules.source')}</span>
              <a className="max-w-[68%] truncate text-primary hover:underline" href={module.source_url} target="_blank" rel="noreferrer">{module.source_url}</a>
            </div>
          ) : null}
          {imported ? <div>{t('modules.importedAt', { date: imported })}</div> : null}
          {module.reason ? <div className="text-amber-2">{t('modules.routeReason', { reason: module.reason })}</div> : null}
        </div>

        {module.unsupported?.length ? (
          <details className="rounded-[9px] border border-amber-2/25 bg-amber-2/5 px-3 py-2 text-[11px] text-text-soft">
            <summary className="cursor-pointer font-bold text-amber-2">{t('modules.unsupportedTitle', { count: module.unsupported.length })}</summary>
            <ul className="mt-2 space-y-1 break-words font-mono text-[10px]">
              {module.unsupported.map((line) => <li key={line}>{line}</li>)}
            </ul>
          </details>
        ) : null}

        {module.format !== 'builtin' ? (
          <Field label={t('modules.argument')}>
            <div className="flex gap-2">
              <Input aria-label={t('modules.argument')} maxLength={4096} className="min-w-0 flex-1" value={argument} onChange={(event) => setArgument(event.target.value)} />
              <Button
                type="button"
                variant="secondary"
                size="sm"
                disabled={busy || argument === (module.argument ?? '')}
                onClick={() => onSaveArgument(module, argument)}
              >
                {t('modules.saveArgument')}
              </Button>
            </div>
            <p className="mt-1 text-[10.5px] text-text-faint">{t('modules.argumentHint')}</p>
          </Field>
        ) : null}

        <div className="mt-auto flex flex-wrap justify-end gap-2 border-t border-divider pt-3">
          {module.compatibility === 'partial' && !module.partial_allowed ? (
            <Button type="button" variant="secondary" size="sm" disabled={busy} onClick={() => onAcknowledge(module)}>
              <ShieldCheck className="h-3.5 w-3.5" /> {t('modules.acknowledge')}
            </Button>
          ) : null}
          <Button type="button" variant="secondary" size="sm" disabled={busy} onClick={() => onInspect(module)}>
            <FileSearch className="h-3.5 w-3.5" /> {t('modules.inspect')}
          </Button>
          {module.format !== 'builtin' ? (
            <Button type="button" variant="danger" size="sm" disabled={busy || module.enabled} onClick={() => onDelete(module)}>
              <Trash2 className="h-3.5 w-3.5" /> {t('modules.delete')}
            </Button>
          ) : null}
        </div>
      </CardBody>
    </Card>
  )
}

function SnapshotModal({
  open,
  loading,
  snapshot,
  onOpenChange,
}: {
  open: boolean
  loading: boolean
  snapshot: InterceptModuleSnapshot | null
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useTranslation()
  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={snapshot ? t('modules.snapshotTitle', { name: snapshot.name }) : t('modules.snapshotLoading')}
      className="w-[min(94vw,780px)]"
      footer={<Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>{t('modules.snapshotClose')}</Button>}
    >
      {loading ? <div className="py-8 text-center text-[12px] text-text-faint">{t('common.loading')}</div> : null}
      {!loading && snapshot ? (
        <div className="max-h-[68vh] space-y-4 overflow-y-auto pr-1">
          <section>
            <div className="mb-1.5 flex items-center justify-between gap-3 text-[10.5px] text-text-faint">
              <span className="font-bold uppercase tracking-[.08em]">{t('modules.snapshotSource')}</span>
              <code className="max-w-[70%] truncate" title={snapshot.source_digest}>{snapshot.source_digest}</code>
            </div>
            <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap break-words rounded-[10px] border border-border bg-input p-3 font-mono text-[10.5px] leading-relaxed text-text-mid">{snapshot.source_body}</pre>
          </section>
          {snapshot.scripts.map((script) => (
            <details key={script.id} className="rounded-[10px] border border-border bg-input/40 px-3 py-2.5">
              <summary className="cursor-pointer text-[11px] font-bold text-text-strong">
                {t('modules.snapshotScript', { id: script.id })}
                <code className="ml-2 font-normal text-text-faint">{script.digest.slice(0, 12)}…</code>
              </summary>
              {script.url ? <div className="mt-2 break-all text-[10px] text-primary">{script.url}</div> : null}
              <pre className="mt-2 max-h-[320px] overflow-auto whitespace-pre-wrap break-words rounded-[8px] bg-card p-3 font-mono text-[10.5px] leading-relaxed text-text-mid">{script.body}</pre>
            </details>
          ))}
          {snapshot.scripts.length === 0 ? <p className="text-[11px] text-text-faint">{t('modules.snapshotNoScripts')}</p> : null}
        </div>
      ) : null}
    </Modal>
  )
}

function ImportModuleModal({
  open,
  revision,
  onOpenChange,
  onImported,
}: {
  open: boolean
  revision: string
  onOpenChange: (open: boolean) => void
  onImported: (view: InterceptModulesView) => void
}) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<ImportMode>('url')
  const [url, setURL] = useState('')
  const [content, setContent] = useState('')
  const [format, setFormat] = useState<InterceptModuleImport['format']>('auto')
  const [qx, setQX] = useState(true)
  const [referer, setReferer] = useState('https://hub.kelee.one/')
  const [argument, setArgument] = useState('')
  const [partial, setPartial] = useState(false)
  const [busy, setBusy] = useState(false)

  async function submit() {
    if ((mode === 'url' && !url.trim()) || (mode === 'text' && !content.trim())) {
      toast.error(t('modules.import.required'))
      return
    }
    setBusy(true)
    try {
      const view = await api.importInterceptModule({
        revision,
        ...(mode === 'url' ? { url: url.trim() } : { content }),
        format,
        fetch_profile: qx ? 'quantumult-x' : 'standard',
        referer: qx && referer.trim() ? referer.trim() : undefined,
        argument: argument || undefined,
        partial_allowed: partial,
      })
      onImported(view)
      toast.success(t('modules.import.success'))
      onOpenChange(false)
      setURL('')
      setContent('')
      setArgument('')
    } catch (error) {
      toast.error(errorMessage(error, t('modules.import.failed')))
    } finally {
      setBusy(false)
    }
  }

  async function chooseFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    if (!file) return
    if (file.size > 2 * 1024 * 1024) {
      toast.error(t('modules.import.tooLarge'))
      return
    }
    setContent(await file.text())
  }

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={t('modules.import.title')}
      className="w-[min(94vw,660px)]"
      footer={
        <>
          <Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button>
          <Button type="button" disabled={busy} onClick={() => void submit()}>
            {busy ? t('modules.import.importing') : t('modules.import.submit')}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <SegmentedControl
          value={mode}
          onChange={(value) => setMode(value as ImportMode)}
          options={[
            { value: 'url', label: t('modules.import.fromUrl') },
            { value: 'text', label: t('modules.import.fromText') },
          ]}
        />
        {mode === 'url' ? (
          <Field label={t('modules.import.url')}>
            <Input aria-label={t('modules.import.url')} maxLength={4096} mono value={url} placeholder={t('modules.import.urlPlaceholder')} onChange={(event) => setURL(event.target.value)} />
          </Field>
        ) : (
          <Field label={t('modules.import.content')}>
            <textarea
              className="min-h-[180px] resize-y rounded-[10px] border border-input-border bg-input px-3 py-2.5 font-mono text-[12px] text-text-strong outline-none"
              aria-label={t('modules.import.content')}
              value={content}
              maxLength={2097152}
              placeholder={t('modules.import.contentPlaceholder')}
              onChange={(event) => setContent(event.target.value)}
            />
            <label className="mt-2 inline-flex cursor-pointer items-center gap-2 text-[11px] font-semibold text-primary">
              <Download className="h-3.5 w-3.5" /> {t('modules.import.upload')}
              <input className="sr-only" type="file" accept=".sgmodule,.lpx,.plugin,.conf,.txt,text/plain" onChange={(event) => void chooseFile(event)} />
            </label>
          </Field>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('modules.import.format')}>
            <select
              className="rounded-[10px] border border-input-border bg-input px-3 py-2.5 text-[13px] text-text-strong outline-none"
              aria-label={t('modules.import.format')}
              value={format}
              onChange={(event) => setFormat(event.target.value as InterceptModuleImport['format'])}
            >
              <option value="auto">{t('modules.import.auto')}</option>
              <option value="surge">Surge</option>
              <option value="loon">Loon</option>
            </select>
          </Field>
          <Field label={t('modules.import.argument')}>
            <Input aria-label={t('modules.import.argument')} maxLength={4096} value={argument} onChange={(event) => setArgument(event.target.value)} />
          </Field>
        </div>
        <div className="rounded-[11px] border border-divider bg-input/50 p-3">
          <div className="flex items-start justify-between gap-3">
            <div>
              <div className="text-[12px] font-bold text-text-strong">{t('modules.import.qx')}</div>
              <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('modules.import.qxHint')}</p>
            </div>
            <Toggle checked={qx} onCheckedChange={setQX} aria-label={t('modules.import.qx')} />
          </div>
          {qx ? (
            <Field className="mt-3" label={t('modules.import.referer')}>
              <Input aria-label={t('modules.import.referer')} maxLength={4096} mono value={referer} placeholder={t('modules.import.refererPlaceholder')} onChange={(event) => setReferer(event.target.value)} />
            </Field>
          ) : null}
        </div>
        <div className="flex items-start justify-between gap-3 rounded-[11px] border border-amber-2/25 bg-amber-2/5 p-3">
          <div>
            <div className="text-[12px] font-bold text-text-strong">{t('modules.import.partial')}</div>
            <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('modules.import.partialHint')}</p>
          </div>
          <Toggle checked={partial} onCheckedChange={setPartial} aria-label={t('modules.import.partial')} />
        </div>
      </div>
    </Modal>
  )
}

export default function ModulesPage() {
  const { t } = useTranslation()
  const [view, setView] = useState<InterceptModulesView | null>(null)
  const [wloc, setWloc] = useState<WLOCInterceptView | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [importOpen, setImportOpen] = useState(false)
  const [busyID, setBusyID] = useState<string | null>(null)
  const [pending, setPending] = useState<PendingAction>(null)
  const [snapshotOpen, setSnapshotOpen] = useState(false)
  const [snapshotLoading, setSnapshotLoading] = useState(false)
  const [snapshot, setSnapshot] = useState<InterceptModuleSnapshot | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(false)
    const [modulesResult, wlocResult] = await Promise.allSettled([api.getInterceptModules(), api.getWLOCIntercept()])
    if (modulesResult.status === 'fulfilled') setView(modulesResult.value)
    else setLoadError(true)
    if (wlocResult.status === 'fulfilled') setWloc(wlocResult.value)
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  const externalCount = useMemo(() => view?.modules.filter((module) => module.format !== 'builtin').length ?? 0, [view])

  async function updateModule(module: InterceptModule, update: { enabled?: boolean; argument?: string; partial_allowed?: boolean }, success: string) {
    if (!view) return
    setBusyID(module.id)
    try {
      const next = await api.putInterceptModule(module.id, { revision: view.revision, ...update })
      setView(next)
      const nextWloc = await api.getWLOCIntercept().catch(() => null)
      if (nextWloc) setWloc(nextWloc)
      toast.success(success)
    } catch (error) {
      toast.error(errorMessage(error, t('modules.updateFailed')))
      void load()
    } finally {
      setBusyID(null)
    }
  }

  async function deleteModule(module: InterceptModule) {
    if (!view) return
    setBusyID(module.id)
    try {
      setView(await api.deleteInterceptModule(module.id, view.revision))
      const nextWloc = await api.getWLOCIntercept().catch(() => null)
      if (nextWloc) setWloc(nextWloc)
      toast.success(t('modules.deleted'))
    } catch (error) {
      toast.error(errorMessage(error, t('modules.updateFailed')))
      void load()
    } finally {
      setBusyID(null)
    }
  }

  async function inspectModule(module: InterceptModule) {
    setSnapshot(null)
    setSnapshotOpen(true)
    setSnapshotLoading(true)
    try {
      setSnapshot(await api.getInterceptModuleSnapshot(module.id))
    } catch (error) {
      toast.error(errorMessage(error, t('modules.snapshotFailed')))
      setSnapshotOpen(false)
    } finally {
      setSnapshotLoading(false)
    }
  }

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-modules">
      <Card className="overflow-hidden">
        <CardBody className="relative p-5 sm:p-6">
          <div className="pointer-events-none absolute -right-10 -top-16 h-40 w-40 rounded-full bg-primary/8 blur-2xl" />
          <div className="relative flex flex-col justify-between gap-5 md:flex-row md:items-center">
            <div className="max-w-[700px]">
              <div className="mb-3 flex h-9 w-9 items-center justify-center rounded-[10px] bg-primary/10 text-primary"><Boxes className="h-5 w-5" /></div>
              <h1 className="text-[20px] font-extrabold tracking-[-.02em] text-text-strong">{t('modules.title')}</h1>
              <p className="mt-2 text-[12.5px] leading-relaxed text-text-soft">{t('modules.intro')}</p>
              <p className="mt-2 text-[10.5px] text-text-faint">{t('modules.catalogNotice')}</p>
            </div>
            <div className="flex shrink-0 flex-wrap gap-2">
              <Button type="button" variant="secondary" onClick={() => void load()} disabled={loading}>
                <RefreshCw className="h-3.5 w-3.5" />{t('modules.refresh')}
              </Button>
              <a href={view?.catalog_url ?? 'https://hub.kelee.one/'} target="_blank" rel="noreferrer">
                <Button type="button" variant="secondary"><ExternalLink className="h-3.5 w-3.5" />{t('modules.catalog')}</Button>
              </a>
              <Button type="button" onClick={() => setImportOpen(true)} disabled={!view}>
                <Plus className="h-3.5 w-3.5" />{t('modules.add')}
              </Button>
            </div>
          </div>
        </CardBody>
      </Card>

      <div className="flex items-center justify-between gap-3 rounded-[11px] border border-amber-2/20 bg-amber-2/5 px-4 py-3">
        <p className="text-[11.5px] leading-relaxed text-text-soft">{t('modules.trustWarning')}</p>
        <a href={view?.ca_profile_url ?? '/ios/ios-intercept-ca.mobileconfig'}>
          <Button type="button" variant="secondary" size="sm"><Download className="h-3.5 w-3.5" />{t('modules.trustProfile')}</Button>
        </a>
      </div>

      {loading && !view ? <Card><CardBody className="text-center text-[12px] text-text-faint">{t('common.loading')}</CardBody></Card> : null}
      {loadError && !view ? (
        <Card><CardBody className="flex items-center justify-between gap-3"><span className="text-[12px] text-red">{t('modules.loadFailed')}</span><Button variant="secondary" size="sm" onClick={() => void load()}><RefreshCw className="h-3.5 w-3.5" />{t('modules.retry')}</Button></CardBody></Card>
      ) : null}

      {view ? (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          {view.modules.map((module) => (
            <ModuleCard
              key={module.id}
              module={module}
              busy={busyID === module.id}
              onToggle={(selected) => setPending({ kind: 'toggle', module: selected })}
              onDelete={(selected) => setPending({ kind: 'delete', module: selected })}
              onSaveArgument={(selected, argument) => void updateModule(selected, { argument }, t('modules.argumentSaved'))}
              onInspect={(selected) => void inspectModule(selected)}
              onAcknowledge={(selected) => setPending({ kind: 'partial', module: selected })}
            />
          ))}
        </div>
      ) : null}

      {view && externalCount === 0 ? <p className="rounded-[10px] border border-dashed border-border px-4 py-5 text-center text-[11.5px] text-text-faint">{t('modules.empty')}</p> : null}

      <div className="mt-1 text-[12px] font-extrabold uppercase tracking-[.08em] text-text-faint">{t('modules.wlocSection')}</div>
      <WLOCInterceptCard
        value={wloc}
        routeEnabled={view?.modules.some((module) => module.id === 'builtin-wloc' && module.enabled && module.ready) ?? false}
        onReload={async () => {
          try {
            const next = await api.getWLOCIntercept()
            setWloc(next)
            return next
          } catch {
            return null
          }
        }}
        onSaved={(next) => {
          setWloc(next)
          void load()
        }}
      />

      {view ? (
        <ImportModuleModal
          open={importOpen}
          revision={view.revision}
          onOpenChange={setImportOpen}
          onImported={(next) => {
            setView(next)
            void api.getWLOCIntercept().then(setWloc).catch(() => undefined)
          }}
        />
      ) : null}

      <SnapshotModal open={snapshotOpen} loading={snapshotLoading} snapshot={snapshot} onOpenChange={setSnapshotOpen} />

      <ConfirmDialog
        open={pending?.kind === 'toggle'}
        onOpenChange={(open) => { if (!open) setPending(null) }}
        title={pending?.module.enabled
          ? t('modules.disableTitle', { name: pending.module.id === 'builtin-wloc' ? t('settings.wlocTitle') : pending.module.name })
          : t('modules.enableTitle', { name: pending?.module.id === 'builtin-wloc' ? t('settings.wlocTitle') : pending?.module.name ?? '' })}
        description={pending?.module.enabled ? t('modules.disableBody') : t('modules.enableBody')}
        confirmLabel={pending?.module.enabled ? t('modules.toggleOff') : t('modules.toggleOn')}
        cancelLabel={t('common.cancel')}
        danger={pending?.module.enabled}
        onConfirm={() => {
          if (pending) void updateModule(pending.module, { enabled: !pending.module.enabled }, t('modules.updated'))
          setPending(null)
        }}
      />
      <ConfirmDialog
        open={pending?.kind === 'delete'}
        onOpenChange={(open) => { if (!open) setPending(null) }}
        title={t('modules.deleteTitle', { name: pending?.module.name ?? '' })}
        description={t('modules.deleteBody')}
        confirmLabel={t('modules.delete')}
        cancelLabel={t('common.cancel')}
        danger
        onConfirm={() => {
          if (pending) void deleteModule(pending.module)
          setPending(null)
        }}
      />
      <ConfirmDialog
        open={pending?.kind === 'partial'}
        onOpenChange={(open) => { if (!open) setPending(null) }}
        title={t('modules.acknowledgeTitle', { name: pending?.module.name ?? '' })}
        description={t('modules.acknowledgeBody')}
        confirmLabel={t('modules.acknowledge')}
        cancelLabel={t('common.cancel')}
        onConfirm={() => {
          if (pending) void updateModule(pending.module, { partial_allowed: true }, t('modules.acknowledged'))
          setPending(null)
        }}
      />
    </div>
  )
}
