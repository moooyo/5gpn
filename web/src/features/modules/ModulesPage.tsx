import { useCallback, useEffect, useMemo, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import {
  AddIcon,
  ArrowRightIcon,
  DeleteIcon,
  ExternalLinkIcon,
  FileSearchIcon,
  NetworkIcon,
  RefreshIcon,
  ShieldLockIcon,
  UploadIcon,
  VerifiedIcon,
  WidgetsFilledIcon,
} from '../../components/icons'
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
  InterceptModuleSnapshot,
  InterceptModulesView,
  WLOCInterceptView,
} from '../../lib/api/types'
import { WLOCInterceptCard } from './WLOCInterceptCard'

type ImportMode = 'url' | 'text'
type PendingAction = { kind: 'toggle' | 'delete' | 'partial'; module: InterceptModule } | null

function compatibilityTone(value: InterceptModule['compatibility']): 'green' | 'amber' | 'blue' | 'red' {
  if (value === 'full') return 'green'
  if (value === 'partial') return 'amber'
  if (value === 'needs_configuration') return 'blue'
  return 'red'
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function TransactionRail({ module }: { module: InterceptModule }) {
  const { t } = useTranslation()
  const steps = [
    { icon: ShieldLockIcon, label: t('modules.transaction.snapshot'), active: true },
    { icon: VerifiedIcon, label: t('modules.transaction.trust'), active: module.enabled && module.ready },
    { icon: NetworkIcon, label: t('modules.transaction.route'), active: module.enabled && module.ready },
  ]
  return (
    <div className="zds-trace-rail [--trace-steps:3] rounded-[14px] bg-surface-container-low px-2 py-3">
      {steps.map((step) => {
        const Icon = step.icon
        return (
          <div className="zds-trace-node" key={step.label}>
            <span className={step.active ? 'zds-trace-dot bg-primary-container text-on-primary-container' : 'zds-trace-dot bg-surface-container-high text-text-faint'}>
              <Icon className="h-4 w-4" aria-hidden="true" />
            </span>
            <span className="truncate text-[10.5px] font-medium text-text-mid">{step.label}</span>
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
  onSaveParameters,
  onInspect,
  onAcknowledge,
}: {
  module: InterceptModule
  busy: boolean
  onToggle: (module: InterceptModule) => void
  onDelete: (module: InterceptModule) => void
  onSaveArgument: (module: InterceptModule, argument: string) => void
  onSaveParameters: (module: InterceptModule, parameters: Record<string, string>) => void
  onInspect: (module: InterceptModule) => void
  onAcknowledge: (module: InterceptModule) => void
}) {
  const { t, i18n } = useTranslation()
  const [argument, setArgument] = useState(module.argument ?? '')
  const [parameters, setParameters] = useState<Record<string, string>>(() => Object.fromEntries((module.parameters ?? []).map((parameter) => [parameter.key, parameter.value ?? ''])))
  const displayName = module.id === 'builtin-wloc' ? t('settings.wlocTitle') : module.name
  const displayDescription = module.id === 'builtin-wloc' ? t('modules.builtinDescription') : module.description

  useEffect(() => setArgument(module.argument ?? ''), [module.argument])
  useEffect(() => setParameters(Object.fromEntries((module.parameters ?? []).map((parameter) => [parameter.key, parameter.value ?? '']))), [module.parameters])

  const status = module.enabled ? (module.ready ? t('modules.enabled') : t('modules.degraded')) : t('modules.disabled')
  const statusTone = module.enabled ? (module.ready ? 'green' : 'amber') : 'neutral'
  const imported = module.imported_at ? new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium' }).format(new Date(module.imported_at)) : ''
  const parametersComplete = (module.parameters ?? []).every((parameter) => (parameters[parameter.key] ?? '').trim() !== '')
  const parametersChanged = (module.parameters ?? []).some((parameter) => (parameters[parameter.key] ?? '') !== (parameter.value ?? ''))

  return (
    <Card className="overflow-hidden shadow-none" data-testid={`module-${module.id}`}>
      <CardBody className="flex h-full flex-col gap-4 p-5">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="mb-2 flex flex-wrap items-center gap-1.5">
              <Badge tone={module.id === 'builtin-wloc' ? 'cyan' : 'indigo'}>
                {module.id === 'builtin-wloc' ? t('modules.builtin') : t('modules.loon')}
              </Badge>
              <Badge tone={compatibilityTone(module.compatibility)}>
                {t(`modules.${module.compatibility}`)}
              </Badge>
              <Badge tone={statusTone}>{status}</Badge>
            </div>
            <h2 className="text-[16px] font-medium leading-tight text-text-strong">{displayName}</h2>
            {displayDescription ? <p className="mt-1.5 text-[12px] leading-relaxed text-text-soft">{displayDescription}</p> : null}
          </div>
          {module.id === 'builtin-wloc' ? (
            <span className="shrink-0 text-[10.5px] font-semibold text-primary">{t('modules.configureBelow')}</span>
          ) : (
            <Toggle
              checked={module.enabled}
              onCheckedChange={() => onToggle(module)}
              disabled={busy || (!module.enabled && (!module.ready || module.compatibility === 'incompatible' || module.compatibility === 'needs_configuration' || (module.compatibility === 'partial' && !module.partial_allowed)))}
              aria-label={module.enabled ? t('modules.toggleOff') : t('modules.toggleOn')}
            />
          )}
        </div>

        <TransactionRail module={module} />

        <div>
          <div className="mb-2 text-[11px] font-medium tracking-[.06em] text-text-faint">{t('modules.hosts')}</div>
          <div className="flex flex-wrap gap-1.5">
            {module.hosts.map((host) => (
              <code key={host} className="rounded-[8px] bg-surface-container px-2.5 py-1 font-mono text-[10.5px] text-text-mid">{host}</code>
            ))}
          </div>
        </div>

        {module.host_mappings?.length ? (
          <div>
            <div className="mb-2 text-[11px] font-medium tracking-[.06em] text-text-faint">{t('modules.hostMappings')}</div>
            <div className="space-y-1.5">
              {module.host_mappings.map((mapping) => (
                <div key={mapping.pattern} className="flex items-center justify-between gap-3 rounded-[10px] bg-surface-container-low px-3 py-2 font-mono text-[10.5px] text-text-mid">
                  <span className="truncate">{mapping.pattern}</span><ArrowRightIcon className="h-4 w-4 shrink-0 text-text-faint" /><span className="truncate">{mapping.target}</span>
                </div>
              ))}
            </div>
          </div>
        ) : null}

        <div className="grid grid-cols-2 gap-2 text-[11px] text-text-soft">
          <div className="rounded-[12px] bg-surface-container-low px-3 py-2.5">{t('modules.scripts', { count: module.script_count })}</div>
          <div className="rounded-[12px] bg-surface-container-low px-3 py-2.5">{t('modules.rewrites', { count: module.rewrite_count })}</div>
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

        {module.issues?.length ? (
          <details className="rounded-[12px] bg-[var(--md-sys-color-warning-container)] px-3.5 py-3 text-[11px] text-[var(--md-sys-color-on-warning-container)]">
            <summary className="cursor-pointer font-medium">{t('modules.compatibilityTitle', { count: module.issues.length })}</summary>
            <ul className="mt-2 space-y-1 break-words font-mono text-[10px]">
              {module.issues.map((issue) => <li className={issue.severity === 'error' ? 'text-red' : undefined} key={`${issue.severity}:${issue.message}`}>{issue.message}</li>)}
            </ul>
          </details>
        ) : null}

        {module.id !== 'builtin-wloc' && module.parameters?.length ? (
          <Field label={t('modules.parameters')}>
            <div className="space-y-2.5 rounded-[10px] border border-divider bg-input/35 p-3">
              {module.parameters.map((parameter) => (
                <label className="block" key={parameter.key}>
                  <span className="mb-1 block font-mono text-[10.5px] font-semibold text-text-mid">{parameter.key}</span>
                  {parameter.kind === 'select' ? (
                    <select
                      aria-label={parameter.key}
                      className="w-full rounded-[9px] border border-input-border bg-input px-3 py-2 text-[12px] text-text-strong outline-none"
                      value={parameters[parameter.key] ?? ''}
                      onChange={(event) => setParameters((current) => ({ ...current, [parameter.key]: event.target.value }))}
                    >
                      <option value="">{t('modules.selectParameter')}</option>
                      {(parameter.options ?? []).map((option) => <option key={option} value={option}>{option}</option>)}
                    </select>
                  ) : (
                    <Input aria-label={parameter.key} maxLength={4096} value={parameters[parameter.key] ?? ''} onChange={(event) => setParameters((current) => ({ ...current, [parameter.key]: event.target.value }))} />
                  )}
                </label>
              ))}
              <div className="flex justify-end">
                <Button type="button" variant="secondary" size="sm" disabled={busy || !parametersComplete || !parametersChanged} onClick={() => onSaveParameters(module, parameters)}>{t('modules.saveParameters')}</Button>
              </div>
            </div>
          </Field>
        ) : null}

        {module.id !== 'builtin-wloc' ? (
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

          <div className="mt-auto flex flex-wrap justify-end gap-2 border-t border-divider pt-4">
            {module.compatibility === 'partial' && !module.partial_allowed ? (
            <Button type="button" variant="tonal" size="sm" disabled={busy} onClick={() => onAcknowledge(module)}>
              <VerifiedIcon className="h-4 w-4" /> {t('modules.acknowledge')}
            </Button>
          ) : null}
          <Button type="button" variant="secondary" size="sm" disabled={busy} onClick={() => onInspect(module)}>
            <FileSearchIcon className="h-4 w-4" /> {t('modules.inspect')}
          </Button>
          {module.id !== 'builtin-wloc' ? (
            <Button type="button" variant="danger" size="sm" disabled={busy || module.enabled} onClick={() => onDelete(module)}>
              <DeleteIcon className="h-4 w-4" /> {t('modules.delete')}
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
            <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap break-words rounded-[14px] bg-surface-container-low p-4 font-mono text-[10.5px] leading-relaxed text-text-mid">{snapshot.source_body}</pre>
          </section>
          {snapshot.scripts.map((script) => (
            <details key={script.id} className="rounded-[14px] bg-surface-container-low px-4 py-3">
              <summary className="cursor-pointer text-[11px] font-bold text-text-strong">
                {t('modules.snapshotScript', { id: script.id })}
                <code className="ml-2 font-normal text-text-faint">{script.digest.slice(0, 12)}…</code>
              </summary>
              {script.url ? <div className="mt-2 break-all text-[10px] text-primary">{script.url}</div> : null}
              <pre className="mt-2 max-h-[320px] overflow-auto whitespace-pre-wrap break-words rounded-[10px] bg-card p-3 font-mono text-[10.5px] leading-relaxed text-text-mid">{script.body}</pre>
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
  existingIDs,
  onOpenChange,
  onImported,
}: {
  open: boolean
  revision: string
  existingIDs: string[]
  onOpenChange: (open: boolean) => void
  onImported: (view: InterceptModulesView) => void
}) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<ImportMode>('url')
  const [url, setURL] = useState('')
  const [content, setContent] = useState('')
  const [busy, setBusy] = useState(false)
  const [review, setReview] = useState<InterceptModule | null>(null)

  function changeOpen(next: boolean) {
    if (!next) setReview(null)
    onOpenChange(next)
  }

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
      })
      onImported(view)
      const imported = view.modules.find((module) => module.id !== 'builtin-wloc' && !existingIDs.includes(module.id)) ?? null
      if (imported && (imported.compatibility === 'incompatible' || imported.compatibility === 'needs_configuration' || (imported.issues?.length ?? 0) > 0)) {
        setReview(imported)
        toast.info(t('modules.import.reviewRequired'))
      } else {
        toast.success(t('modules.import.success'))
        changeOpen(false)
      }
      setURL('')
      setContent('')
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
      onOpenChange={changeOpen}
      title={t('modules.import.title')}
      className="w-[min(94vw,660px)]"
      footer={
        review ? <Button type="button" onClick={() => changeOpen(false)}>{t('modules.import.closeReview')}</Button> : (
          <>
            <Button type="button" variant="secondary" onClick={() => changeOpen(false)}>{t('common.cancel')}</Button>
            <Button type="button" disabled={busy} onClick={() => void submit()}>
              {busy ? t('modules.import.importing') : t('modules.import.submit')}
            </Button>
          </>
        )
      }
    >
      {review ? (
        <div className="space-y-4" data-testid="module-import-review">
          <div className="rounded-[16px] bg-primary-container p-4 text-on-primary-container">
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={compatibilityTone(review.compatibility)}>{t(`modules.${review.compatibility}`)}</Badge>
              <span className="text-[13px] font-extrabold text-text-strong">{review.name}</span>
            </div>
            <p className="mt-2 text-[11px] leading-relaxed text-text-soft">{t('modules.import.reviewBody')}</p>
          </div>
          {review.issues?.length ? (
            <ul className="space-y-2">
              {review.issues.map((issue) => (
                <li className={`rounded-[12px] px-3 py-2.5 text-[11px] leading-relaxed ${issue.severity === 'error' ? 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]' : 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]'}`} key={`${issue.severity}:${issue.message}`}>
                  {issue.message}
                </li>
              ))}
            </ul>
          ) : null}
          {review.parameters?.length ? <div className="text-[11px] text-text-soft">{t('modules.import.parametersPending', { count: review.parameters.length })}</div> : null}
        </div>
      ) : <div className="space-y-4">
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
              className="min-h-[200px] resize-y rounded-[14px] border border-input-border bg-input px-4 py-3 font-mono text-[12px] leading-5 text-text-strong outline-none focus:border-primary focus:bg-card"
              aria-label={t('modules.import.content')}
              value={content}
              maxLength={2097152}
              placeholder={t('modules.import.contentPlaceholder')}
              onChange={(event) => setContent(event.target.value)}
            />
            <label className="zds-state-layer mt-2 inline-flex cursor-pointer items-center gap-2 rounded-full px-3 py-2 text-[11.5px] font-medium text-primary">
              <UploadIcon className="h-4 w-4" /> {t('modules.import.upload')}
              <input className="sr-only" type="file" accept=".lpx,.plugin,.conf,.txt,text/plain" onChange={(event) => void chooseFile(event)} />
            </label>
          </Field>
        )}
        <div className="flex items-start gap-2.5 rounded-[14px] bg-surface-container-low px-4 py-3" data-testid="module-import-automatic">
          <FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
          <p className="text-[11px] leading-relaxed text-text-soft">{t('modules.import.automatic')}</p>
        </div>
      </div>}
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

  const externalCount = useMemo(() => view?.modules.filter((module) => module.id !== 'builtin-wloc').length ?? 0, [view])

  async function updateModule(module: InterceptModule, update: { enabled?: boolean; argument?: string; partial_allowed?: boolean; parameters?: Record<string, string> }, success: string) {
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
    <div className="flex flex-col gap-4" data-testid="page-modules">
      <Card variant="hero" className="overflow-hidden">
        <CardBody className="p-5 sm:p-6">
          <div className="flex flex-col justify-between gap-5 md:flex-row md:items-center">
            <div className="max-w-[700px]">
              <div className="mb-3 grid h-11 w-11 place-items-center rounded-full bg-[rgb(255_255_255_/_36%)]"><WidgetsFilledIcon className="h-6 w-6" /></div>
              <h1 className="text-[21px] font-medium tracking-[-.02em]">{t('modules.title')}</h1>
              <p className="mt-2 text-[12.5px] leading-relaxed opacity-80">{t('modules.intro')}</p>
              <p className="mt-2 text-[10.5px] opacity-65">{t('modules.catalogNotice')}</p>
            </div>
            <div className="flex shrink-0 flex-wrap gap-2">
              <Button type="button" variant="elevated" onClick={() => void load()} disabled={loading}>
                <RefreshIcon className="h-4 w-4" />{t('modules.refresh')}
              </Button>
              <a href={view?.catalog_url ?? 'https://hub.kelee.one/'} target="_blank" rel="noreferrer">
                <Button type="button" variant="elevated"><ExternalLinkIcon className="h-4 w-4" />{t('modules.catalog')}</Button>
              </a>
              <Button type="button" onClick={() => setImportOpen(true)} disabled={!view}>
                <AddIcon className="h-4 w-4" />{t('modules.add')}
              </Button>
            </div>
          </div>
        </CardBody>
      </Card>

      <div className="flex flex-col gap-3 rounded-[16px] bg-secondary-container px-5 py-4 text-on-secondary-container sm:flex-row sm:items-center sm:justify-between" data-testid="mitm-ca-guide-notice">
        <div className="flex items-start gap-2.5">
          <VerifiedIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />
          <div>
            <div className="text-[11.5px] font-bold text-text-strong">{t('modules.caGuideTitle')}</div>
            <p className="mt-0.5 text-[11px] leading-relaxed text-text-soft">{t('modules.caGuideBody')}</p>
          </div>
        </div>
        <Link
          className="zds-state-layer inline-flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-full px-4 text-[12px] font-medium"
          to="/setup-guide"
        >
          {t('modules.caGuideAction')}<ArrowRightIcon className="h-4 w-4" />
        </Link>
      </div>

      {loading && !view ? <Card><CardBody className="text-center text-[12px] text-text-faint">{t('common.loading')}</CardBody></Card> : null}
      {loadError && !view ? (
        <Card><CardBody className="flex items-center justify-between gap-3"><span className="text-[12px] text-red">{t('modules.loadFailed')}</span><Button variant="secondary" size="sm" onClick={() => void load()}><RefreshIcon className="h-4 w-4" />{t('modules.retry')}</Button></CardBody></Card>
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
              onSaveParameters={(selected, parameters) => void updateModule(selected, { parameters }, t('modules.parametersSaved'))}
              onInspect={(selected) => void inspectModule(selected)}
              onAcknowledge={(selected) => setPending({ kind: 'partial', module: selected })}
            />
          ))}
        </div>
      ) : null}

      {view && externalCount === 0 ? <p className="rounded-[10px] border border-dashed border-border px-4 py-5 text-center text-[11.5px] text-text-faint">{t('modules.empty')}</p> : null}

      <div className="mt-2 px-1 text-[13px] font-medium tracking-[.04em] text-text-faint">{t('modules.wlocSection')}</div>
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
          existingIDs={view.modules.map((module) => module.id)}
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
