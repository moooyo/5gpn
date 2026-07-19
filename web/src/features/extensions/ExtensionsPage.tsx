import { useCallback, useEffect, useMemo, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import {
  AddIcon,
  CloudIcon,
  CodeIcon,
  DeleteIcon,
  EditIcon,
  ExtensionFilledIcon,
  ExternalLinkIcon,
  FileIcon,
  FileSearchIcon,
  LinkIcon,
  RefreshIcon,
  SearchIcon,
  ShieldLockIcon,
  TuneIcon,
  UploadIcon,
  VerifiedIcon,
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
  MITMSettingsView,
  WLOCInterceptView,
} from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { useMITMTrustAcknowledgement } from '../../lib/mitmTrust'
import { HostAuditView } from './HostAuditView'
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

function sourceHost(value?: string): string {
  if (!value) return ''
  try {
    return new URL(value).hostname
  } catch {
    return value
  }
}

function ExtensionCard({
  module,
  busy,
  trusted,
  onToggle,
  onDelete,
  onInspect,
  onAcknowledge,
  onConfigure,
  onAudit,
  onCheckUpdate,
}: {
  module: InterceptModule
  busy: boolean
  trusted: boolean
  onToggle: (module: InterceptModule) => void
  onDelete: (module: InterceptModule) => void
  onInspect: (module: InterceptModule) => void
  onAcknowledge: (module: InterceptModule) => void
  onConfigure: (module: InterceptModule) => void
  onAudit: (module: InterceptModule) => void
  onCheckUpdate: (module: InterceptModule) => void
}) {
  const { t, i18n } = useTranslation()
  const displayName = module.id === 'builtin-wloc' ? t('settings.wlocTitle') : module.name
  const displayDescription = module.id === 'builtin-wloc' ? t('extensions.builtinDescription') : module.description
  const isBuiltin = module.id === 'builtin-wloc'
  const imported = module.imported_at ? new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium' }).format(new Date(module.imported_at)) : ''
  const canArmWhileRuntimeStopped = module.reason === 'mitm-disabled'
  const parameterCount = module.parameters?.length ?? 0
  const sourceLabel = isBuiltin ? t('extensions.builtin') : sourceHost(module.source_url) || t('extensions.localSnapshot')
  const toggleDisabled = busy || (!module.enabled && ((!module.ready && !canArmWhileRuntimeStopped) || module.compatibility === 'incompatible' || module.compatibility === 'needs_configuration' || (module.compatibility === 'partial' && !module.partial_allowed)))
  const trustWarning = module.enabled && module.hosts.length > 0 && !trusted

  return (
    <Card className="min-w-0 overflow-hidden border-0 shadow-[var(--md-sys-elevation-1)]" data-testid={`extension-${module.id}`}>
      <CardBody className="flex h-full min-h-[248px] flex-col gap-3 p-4.5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className={cn(
              'grid h-11 w-11 shrink-0 place-items-center rounded-[12px]',
              module.enabled ? 'bg-primary-container text-on-primary-container' : 'bg-surface-container text-text-faint',
            )}>
              {isBuiltin ? <ShieldLockIcon className="h-5 w-5" aria-hidden="true" /> : module.hosts.length > 0 ? <ExtensionFilledIcon className="h-5 w-5" aria-hidden="true" /> : <CodeIcon className="h-5 w-5" aria-hidden="true" />}
            </span>
            <div className="min-w-0">
              <h2 className="truncate text-[14.5px] font-medium leading-tight text-text-strong">{displayName}</h2>
              <p className="mt-1 truncate text-[10.5px] text-text-faint">
                {sourceLabel}
                {imported ? ` · ${imported}` : ''}
              </p>
            </div>
          </div>
          <Toggle
            checked={module.enabled}
            onCheckedChange={() => onToggle(module)}
            disabled={toggleDisabled}
            aria-label={`${module.enabled ? t('extensions.toggleOff') : t('extensions.toggleOn')} · ${displayName}`}
          />
        </div>

        {displayDescription ? <p className="line-clamp-2 min-h-10 text-[11.5px] leading-5 text-text-soft">{displayDescription}</p> : <div className="min-h-10" />}

        <div className="flex flex-wrap items-center gap-1.5">
          {!module.enabled ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="neutral">{t('extensions.disabled')}</Badge> : null}
          {module.rewrite_count > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="indigo">{t('extensions.capabilityRewrite')}</Badge> : null}
          {module.script_count > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.capabilityScript')}</Badge> : null}
          {module.hosts.length > 0 ? (
            <button type="button" aria-label={t('extensions.auditHosts')} onClick={() => onAudit(module)} className="zds-state-layer inline-flex items-center gap-1 rounded-[6px] bg-primary-container px-2.5 py-0.5 text-[11px] font-medium text-on-primary-container">
              <ShieldLockIcon className="h-3.5 w-3.5" aria-hidden="true" /> MITM · {module.hosts.length}
            </button>
          ) : null}
          {(module.host_mappings?.length ?? 0) > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="cyan">{t('extensions.capabilityHost', { count: module.host_mappings?.length ?? 0 })}</Badge> : null}
          {module.compatibility !== 'full' ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone={compatibilityTone(module.compatibility)}>{t(`extensions.${module.compatibility}`)}</Badge> : null}
          {trustWarning ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.trustPending')}</Badge> : null}
          {module.enabled && module.reason === 'mitm-disabled' ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.masterPending')}</Badge> : null}
        </div>

        {module.issues?.length ? (
          <details className="rounded-[10px] bg-[var(--md-sys-color-warning-container)] px-3 py-2.5 text-[10.5px] text-[var(--md-sys-color-on-warning-container)]">
            <summary className="cursor-pointer font-medium">{t('extensions.compatibilityTitle', { count: module.issues.length })}</summary>
            <ul className="mt-2 space-y-1 break-words font-mono text-[10px]">
              {module.issues.map((issue) => <li className={issue.severity === 'error' ? 'text-red' : undefined} key={`${issue.severity}:${issue.message}`}>{issue.message}</li>)}
            </ul>
          </details>
        ) : null}

        <div className="mt-auto flex min-w-0 items-center gap-1 border-t border-divider pt-3">
          <span className="flex min-w-0 flex-1 items-center gap-1.5 text-[10.5px] text-text-faint">
            {module.source_url ? <CloudIcon className="h-4 w-4 shrink-0" aria-hidden="true" /> : <FileIcon className="h-4 w-4 shrink-0" aria-hidden="true" />}
            <span className="max-w-[104px] truncate">{sourceLabel}</span>
            <code className="shrink-0 font-mono text-[9px] text-text-faint" title={module.snapshot_digest}>· {module.snapshot_digest.slice(0, 8)}</code>
          </span>
          {module.compatibility === 'partial' && !module.partial_allowed ? (
            <Button type="button" variant="tonal" size="sm" className="shrink-0" disabled={busy} onClick={() => onAcknowledge(module)}>
              <VerifiedIcon className="h-4 w-4" /> {t('extensions.acknowledge')}
            </Button>
          ) : null}
          {module.source_url ? (
            <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0" aria-label={t('extensions.checkUpdate')} title={t('extensions.checkUpdate')} disabled={busy} onClick={() => onCheckUpdate(module)}>
              <RefreshIcon className="h-4 w-4" />
            </Button>
          ) : null}
          {parameterCount > 0 ? (
            <Button type="button" variant="secondary" size="sm" className="shrink-0" onClick={() => onConfigure(module)}>
              <TuneIcon className="h-4 w-4" /> {t('extensions.parametersAction', { count: parameterCount })}
            </Button>
          ) : (
            <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0" aria-label={t('extensions.configure')} title={t('extensions.configure')} onClick={() => onConfigure(module)}>
              <EditIcon className="h-4 w-4" />
            </Button>
          )}
          <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0" aria-label={t('extensions.inspect')} title={t('extensions.inspect')} disabled={busy} onClick={() => onInspect(module)}>
            <FileSearchIcon className="h-4 w-4" />
          </Button>
          {!isBuiltin ? (
            <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0 text-[var(--md-sys-color-error)]" aria-label={t('extensions.delete')} title={t('extensions.delete')} disabled={busy || module.enabled} onClick={() => onDelete(module)}>
              <DeleteIcon className="h-4 w-4" />
            </Button>
          ) : null}
        </div>
      </CardBody>
    </Card>
  )
}

function ExtensionConfigModal({
  module,
  onOpenChange,
  onSave,
}: {
  module: InterceptModule | null
  onOpenChange: (open: boolean) => void
  onSave: (module: InterceptModule, update: { argument: string; parameters?: Record<string, string> }) => void
}) {
  const { t } = useTranslation()
  const [argument, setArgument] = useState('')
  const [parameters, setParameters] = useState<Record<string, string>>({})

  useEffect(() => {
    setArgument(module?.argument ?? '')
    setParameters(Object.fromEntries((module?.parameters ?? []).map((parameter) => [parameter.key, parameter.value ?? ''])))
  }, [module])

  const changed = !!module && (
    argument !== (module.argument ?? '') ||
    (module.parameters ?? []).some((parameter) => parameters[parameter.key] !== (parameter.value ?? ''))
  )
  const parametersReady = (module?.parameters ?? []).every((parameter) => (parameters[parameter.key] ?? '').trim() !== '')
  const parameterLocked = !!module?.enabled && (module.parameters?.length ?? 0) > 0

  return (
    <Modal
      open={!!module}
      onOpenChange={onOpenChange}
      title={module ? t('extensions.configureTitle', { name: module.name }) : ''}
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button>
          <Button
            type="button"
            size="sm"
            disabled={!module || !changed || !parametersReady || parameterLocked}
            onClick={() => {
              if (!module) return
              onSave(module, { argument, parameters: module.parameters?.length ? parameters : undefined })
            }}
          >
            {t('common.save')}
          </Button>
        </>
      }
    >
      {module ? (
        <div className="space-y-4">
          {parameterLocked ? (
            <div role="alert" className="rounded-[12px] bg-[var(--md-sys-color-warning-container)] px-3.5 py-3 text-[11px] text-[var(--md-sys-color-on-warning-container)]">
              {t('extensions.disableBeforeParameters')}
            </div>
          ) : null}
          {(module.parameters ?? []).map((parameter) => (
            <Field key={parameter.key} label={parameter.key}>
              {parameter.kind === 'select' ? (
                <select
                  aria-label={parameter.key}
                  disabled={parameterLocked}
                  className="w-full rounded-[10px] border border-input-border bg-input px-3 py-2.5 text-[12px] text-text-strong outline-none disabled:opacity-50"
                  value={parameters[parameter.key] ?? ''}
                  onChange={(event) => setParameters((current) => ({ ...current, [parameter.key]: event.target.value }))}
                >
                  <option value="">{t('extensions.selectParameter')}</option>
                  {(parameter.options ?? []).map((option) => <option key={option} value={option}>{option}</option>)}
                </select>
              ) : (
                <Input
                  aria-label={parameter.key}
                  disabled={parameterLocked}
                  maxLength={4096}
                  value={parameters[parameter.key] ?? ''}
                  onChange={(event) => setParameters((current) => ({ ...current, [parameter.key]: event.target.value }))}
                />
              )}
            </Field>
          ))}
          <Field label={t('extensions.argument')}>
            <Input aria-label={t('extensions.argument')} maxLength={4096} value={argument} onChange={(event) => setArgument(event.target.value)} />
            <p className="mt-1 text-[10.5px] text-text-faint">{t('extensions.argumentHint')}</p>
          </Field>
        </div>
      ) : null}
    </Modal>
  )
}

function ExtensionUpdateModal({
  review,
  busy,
  onOpenChange,
  onApply,
}: {
  review: { current: InterceptModule; candidate: InterceptModule } | null
  busy: boolean
  onOpenChange: (open: boolean) => void
  onApply: () => void
}) {
  const { t } = useTranslation()
  return (
    <Modal
      open={!!review}
      onOpenChange={onOpenChange}
      title={review ? t('extensions.updateTitle', { name: review.current.name }) : ''}
      className="w-[min(94vw,680px)]"
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button>
          <Button type="button" size="sm" disabled={!review || review.current.enabled || busy} onClick={onApply}>
            {busy ? t('common.saving') : t('extensions.applyUpdate')}
          </Button>
        </>
      }
    >
      {review ? (
        <div className="space-y-4">
          {review.current.enabled ? (
            <div role="alert" className="rounded-[12px] bg-[var(--md-sys-color-warning-container)] px-3.5 py-3 text-[11px] text-[var(--md-sys-color-on-warning-container)]">
              {t('extensions.disableBeforeUpdate')}
            </div>
          ) : null}
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-[14px] bg-surface-container-low p-4">
              <div className="text-[10.5px] font-medium text-text-faint">{t('extensions.currentSnapshot')}</div>
              <code className="mt-2 block break-all font-mono text-[10.5px] text-text-mid">{review.current.snapshot_digest}</code>
            </div>
            <div className="rounded-[14px] bg-primary-container p-4 text-on-primary-container">
              <div className="text-[10.5px] font-medium opacity-70">{t('extensions.candidateSnapshot')}</div>
              <code className="mt-2 block break-all font-mono text-[10.5px]">{review.candidate.snapshot_digest}</code>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone={compatibilityTone(review.candidate.compatibility)}>{t(`extensions.${review.candidate.compatibility}`)}</Badge>
            <Badge tone="blue">MITM · {review.candidate.hosts.length}</Badge>
            {review.candidate.script_count > 0 ? <Badge tone="amber">{t('extensions.scripts', { count: review.candidate.script_count })}</Badge> : null}
            {review.candidate.rewrite_count > 0 ? <Badge tone="indigo">{t('extensions.rewrites', { count: review.candidate.rewrite_count })}</Badge> : null}
          </div>
          <div>
            <div className="mb-2 text-[11px] font-medium text-text-faint">{t('extensions.hosts')}</div>
            <div className="flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-[12px] bg-surface-container-low p-3">
              {review.candidate.hosts.map((host) => <code key={host} className="rounded-[7px] bg-card px-2 py-1 font-mono text-[10px] text-text-mid">{host}</code>)}
            </div>
          </div>
          {review.candidate.issues?.length ? (
            <ul className="space-y-2">
              {review.candidate.issues.map((issue) => (
                <li key={`${issue.severity}:${issue.message}`} className={cn(
                  'rounded-[12px] px-3 py-2.5 text-[11px] leading-5',
                  issue.severity === 'error'
                    ? 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]'
                    : 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
                )}>{issue.message}</li>
              ))}
            </ul>
          ) : null}
          <p className="text-[10.5px] leading-5 text-text-faint">{t('extensions.updateSafety')}</p>
        </div>
      ) : null}
    </Modal>
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
      title={snapshot ? t('extensions.snapshotTitle', { name: snapshot.name }) : t('extensions.snapshotLoading')}
      className="w-[min(94vw,780px)]"
      footer={<Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>{t('extensions.snapshotClose')}</Button>}
    >
      {loading ? <div className="py-8 text-center text-[12px] text-text-faint">{t('common.loading')}</div> : null}
      {!loading && snapshot ? (
        <div className="max-h-[68vh] space-y-4 overflow-y-auto pr-1">
          <section>
            <div className="mb-1.5 flex items-center justify-between gap-3 text-[10.5px] text-text-faint">
              <span className="font-bold uppercase tracking-[.08em]">{t('extensions.snapshotSource')}</span>
              <code className="max-w-[70%] truncate" title={snapshot.source_digest}>{snapshot.source_digest}</code>
            </div>
            <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap break-words rounded-[14px] bg-surface-container-low p-4 font-mono text-[10.5px] leading-relaxed text-text-mid">{snapshot.source_body}</pre>
          </section>
          {snapshot.scripts.map((script) => (
            <details key={script.id} className="rounded-[14px] bg-surface-container-low px-4 py-3">
              <summary className="cursor-pointer text-[11px] font-bold text-text-strong">
                {t('extensions.snapshotScript', { id: script.id })}
                <code className="ml-2 font-normal text-text-faint">{script.digest.slice(0, 12)}…</code>
              </summary>
              {script.url ? <div className="mt-2 break-all text-[10px] text-primary">{script.url}</div> : null}
              <pre className="mt-2 max-h-[320px] overflow-auto whitespace-pre-wrap break-words rounded-[10px] bg-card p-3 font-mono text-[10.5px] leading-relaxed text-text-mid">{script.body}</pre>
            </details>
          ))}
          {snapshot.scripts.length === 0 ? <p className="text-[11px] text-text-faint">{t('extensions.snapshotNoScripts')}</p> : null}
        </div>
      ) : null}
    </Modal>
  )
}

function ImportModuleModal({
  open,
  initialMode,
  revision,
  existingIDs,
  onOpenChange,
  onImported,
}: {
  open: boolean
  initialMode: ImportMode
  revision: string
  existingIDs: string[]
  onOpenChange: (open: boolean) => void
  onImported: (view: InterceptModulesView) => void
}) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<ImportMode>(initialMode)
  const [url, setURL] = useState('')
  const [content, setContent] = useState('')
  const [busy, setBusy] = useState(false)
  const [review, setReview] = useState<InterceptModule | null>(null)

  useEffect(() => {
    if (open) setMode(initialMode)
  }, [initialMode, open])

  function changeOpen(next: boolean) {
    if (!next) setReview(null)
    onOpenChange(next)
  }

  async function submit() {
    if ((mode === 'url' && !url.trim()) || (mode === 'text' && !content.trim())) {
      toast.error(t('extensions.import.required'))
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
        toast.info(t('extensions.import.reviewRequired'))
      } else {
        toast.success(t('extensions.import.success'))
        changeOpen(false)
      }
      setURL('')
      setContent('')
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.import.failed')))
    } finally {
      setBusy(false)
    }
  }

  async function chooseFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    if (!file) return
    if (file.size > 2 * 1024 * 1024) {
      toast.error(t('extensions.import.tooLarge'))
      return
    }
    setContent(await file.text())
  }

  return (
    <Modal
      open={open}
      onOpenChange={changeOpen}
      title={t('extensions.import.title')}
      className="w-[min(94vw,660px)]"
      footer={
        review ? <Button type="button" onClick={() => changeOpen(false)}>{t('extensions.import.closeReview')}</Button> : (
          <>
            <Button type="button" variant="secondary" onClick={() => changeOpen(false)}>{t('common.cancel')}</Button>
            <Button type="button" disabled={busy} onClick={() => void submit()}>
              {busy ? t('extensions.import.importing') : t('extensions.import.submit')}
            </Button>
          </>
        )
      }
    >
      {review ? (
        <div className="space-y-4" data-testid="extension-import-review">
          <div className="rounded-[16px] bg-primary-container p-4 text-on-primary-container">
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone={compatibilityTone(review.compatibility)}>{t(`extensions.${review.compatibility}`)}</Badge>
              <span className="text-[13px] font-extrabold text-text-strong">{review.name}</span>
            </div>
            <p className="mt-2 text-[11px] leading-relaxed text-text-soft">{t('extensions.import.reviewBody')}</p>
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
          {review.parameters?.length ? <div className="text-[11px] text-text-soft">{t('extensions.import.parametersPending', { count: review.parameters.length })}</div> : null}
        </div>
      ) : <div className="space-y-4">
        <SegmentedControl
          value={mode}
          onChange={(value) => setMode(value as ImportMode)}
          options={[
            { value: 'url', label: t('extensions.import.fromUrl') },
            { value: 'text', label: t('extensions.import.fromText') },
          ]}
        />
        {mode === 'url' ? (
          <Field label={t('extensions.import.url')}>
            <Input aria-label={t('extensions.import.url')} maxLength={4096} mono value={url} placeholder={t('extensions.import.urlPlaceholder')} onChange={(event) => setURL(event.target.value)} />
          </Field>
        ) : (
          <Field label={t('extensions.import.content')}>
            <textarea
              className="min-h-[200px] resize-y rounded-[14px] border border-input-border bg-input px-4 py-3 font-mono text-[12px] leading-5 text-text-strong outline-none focus:border-primary focus:bg-card"
              aria-label={t('extensions.import.content')}
              value={content}
              maxLength={2097152}
              placeholder={t('extensions.import.contentPlaceholder')}
              onChange={(event) => setContent(event.target.value)}
            />
            <label className="zds-state-layer mt-2 inline-flex cursor-pointer items-center gap-2 rounded-full px-3 py-2 text-[11.5px] font-medium text-primary">
              <UploadIcon className="h-4 w-4" /> {t('extensions.import.upload')}
              <input className="sr-only" type="file" accept=".lpx,.plugin,.conf,.txt,text/plain" onChange={(event) => void chooseFile(event)} />
            </label>
          </Field>
        )}
        <div className="flex items-start gap-2.5 rounded-[14px] bg-surface-container-low px-4 py-3" data-testid="extension-import-automatic">
          <FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
          <p className="text-[11px] leading-relaxed text-text-soft">{t('extensions.import.automatic')}</p>
        </div>
      </div>}
    </Modal>
  )
}

type ExtensionFilter = 'all' | 'enabled' | 'mitm' | 'local'

export default function ExtensionsPage() {
  const { t } = useTranslation()
  const location = useLocation()
  const navigate = useNavigate()
  const { acknowledged } = useMITMTrustAcknowledgement()
  const [view, setView] = useState<InterceptModulesView | null>(null)
  const [wloc, setWloc] = useState<WLOCInterceptView | null>(null)
  const [settings, setSettings] = useState<MITMSettingsView | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [importOpen, setImportOpen] = useState(false)
  const [importMode, setImportMode] = useState<ImportMode>('url')
  const [wlocConfigOpen, setWlocConfigOpen] = useState(false)
  const [filter, setFilter] = useState<ExtensionFilter>('all')
  const [search, setSearch] = useState('')
  const [configTarget, setConfigTarget] = useState<InterceptModule | null>(null)
  const [updateReview, setUpdateReview] = useState<{ current: InterceptModule; candidate: InterceptModule } | null>(null)
  const [updateBusy, setUpdateBusy] = useState(false)
  const [busyID, setBusyID] = useState<string | null>(null)
  const [pending, setPending] = useState<PendingAction>(null)
  const [snapshotOpen, setSnapshotOpen] = useState(false)
  const [snapshotLoading, setSnapshotLoading] = useState(false)
  const [snapshot, setSnapshot] = useState<InterceptModuleSnapshot | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(false)
    const [modulesResult, wlocResult, settingsResult] = await Promise.allSettled([
      api.getInterceptModules(),
      api.getWLOCIntercept(),
      api.getMITMSettings(),
    ])
    if (modulesResult.status === 'fulfilled') setView(modulesResult.value)
    else setLoadError(true)
    if (wlocResult.status === 'fulfilled') setWloc(wlocResult.value)
    if (settingsResult.status === 'fulfilled') setSettings(settingsResult.value)
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  const visibleModules = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase()
    return (view?.modules ?? []).filter((module) => {
      if (filter === 'enabled' && !module.enabled) return false
      if (filter === 'mitm' && module.hosts.length === 0) return false
      if (filter === 'local' && module.source_url) return false
      if (!needle) return true
      return `${module.name} ${module.description ?? ''} ${module.source_url ?? ''} ${module.hosts.join(' ')}`.toLocaleLowerCase().includes(needle)
    })
  }, [filter, search, view?.modules])
  const hostCount = useMemo(() => view?.modules.reduce((count, module) => count + module.hosts.length, 0) ?? 0, [view?.modules])
  const activeMITMCount = useMemo(() => view?.modules.filter((module) => module.enabled && module.hosts.length > 0).length ?? 0, [view?.modules])
  const showingHosts = location.pathname === '/extensions/hosts'
  const scopedModuleID = new URLSearchParams(location.search).get('plugin') ?? undefined
  const trustState = !acknowledged ? 'trust' : !settings?.enabled ? 'master' : 'ready'

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
      toast.error(errorMessage(error, t('extensions.updateFailed')))
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
      toast.success(t('extensions.deleted'))
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateFailed')))
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
      toast.error(errorMessage(error, t('extensions.snapshotFailed')))
      setSnapshotOpen(false)
    } finally {
      setSnapshotLoading(false)
    }
  }

  async function checkExtensionUpdate(module: InterceptModule) {
    if (!view || !module.source_url) return
    setBusyID(module.id)
    try {
      const result = await api.checkInterceptModuleUpdate(module.id, view.revision)
      if (result.state === 'unchanged' || !result.candidate) {
        toast.success(t('extensions.updateUnchanged'))
      } else {
        setUpdateReview({ current: module, candidate: result.candidate })
      }
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateCheckFailed')))
      void load()
    } finally {
      setBusyID(null)
    }
  }

  async function applyExtensionUpdate() {
    if (!view || !updateReview) return
    setUpdateBusy(true)
    try {
      const next = await api.applyInterceptModuleUpdate(
        updateReview.current.id,
        view.revision,
        updateReview.candidate.snapshot_digest,
      )
      setView(next)
      setUpdateReview(null)
      toast.success(t('extensions.updateApplied'))
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateApplyFailed')))
      void load()
    } finally {
      setUpdateBusy(false)
    }
  }

  return (
    <div className="flex flex-col gap-4" data-testid="page-extensions">
      <div className={cn(
        'flex flex-col gap-3 rounded-[20px] px-5 py-4 sm:flex-row sm:items-center sm:justify-between',
        trustState === 'ready'
          ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]'
          : trustState === 'master'
            ? 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]'
            : 'bg-primary-container text-on-primary-container',
      )} data-testid="mitm-readiness-notice">
        <div className="flex items-start gap-2.5">
          {trustState === 'ready' ? <VerifiedIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" /> : <ShieldLockIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />}
          <div>
            <div className="text-[12.5px] font-semibold">{t(`extensions.readiness.${trustState}.title`)}</div>
            <p className="mt-0.5 text-[11px] leading-relaxed opacity-80">{t(`extensions.readiness.${trustState}.body`, { count: activeMITMCount })}</p>
          </div>
        </div>
        <Link
          className={cn(
            'zds-state-layer inline-flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-full px-5 text-[12px] font-medium',
            trustState === 'ready' ? 'bg-[rgb(0_0_0_/_8%)]' : 'bg-primary text-[var(--md-sys-color-on-primary)]',
          )}
          to={trustState === 'master' ? '/settings' : '/setup-guide'}
        >
          {trustState !== 'ready' ? <LinkIcon className="h-4 w-4" aria-hidden="true" /> : null}
          {t(`extensions.readiness.${trustState}.action`)}
        </Link>
      </div>

      {loading && !view ? <Card><CardBody className="text-center text-[12px] text-text-faint">{t('common.loading')}</CardBody></Card> : null}
      {loadError && !view ? (
        <Card><CardBody className="flex items-center justify-between gap-3"><span className="text-[12px] text-red">{t('extensions.loadFailed')}</span><Button variant="secondary" size="sm" onClick={() => void load()}><RefreshIcon className="h-4 w-4" />{t('extensions.retry')}</Button></CardBody></Card>
      ) : null}

      {!showingHosts && view ? (
        <>
          <div className="flex flex-col gap-3 px-1 lg:flex-row lg:items-center">
            <p className="min-w-[240px] flex-1 text-[12.5px] leading-5 text-text-faint">
              {t('extensions.catalogSummary', { total: view.modules.length, enabled: view.modules.filter((module) => module.enabled).length })}{' '}
              <button type="button" className="zds-state-layer rounded-full px-2 py-1 font-medium text-primary" onClick={() => void navigate('/extensions/hosts')}>
                {t('extensions.tabs.hosts', { count: hostCount })}
              </button>
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <Button type="button" variant="ghost" size="sm" className="w-9 px-0" aria-label={t('extensions.refresh')} title={t('extensions.refresh')} onClick={() => void load()} disabled={loading}>
                <RefreshIcon className="h-4 w-4" />
              </Button>
              <a
                href={view.catalog_url ?? 'https://hub.kelee.one/'}
                target="_blank"
                rel="noreferrer"
                aria-label={t('extensions.catalog')}
                title={t('extensions.catalog')}
                className="zds-state-layer grid h-9 w-9 place-items-center rounded-full text-primary"
              >
                <ExternalLinkIcon className="h-4 w-4" aria-hidden="true" />
              </a>
              <Button type="button" variant="tonal" size="sm" onClick={() => { setImportMode('url'); setImportOpen(true) }}>
                <LinkIcon className="h-4 w-4" />{t('extensions.addUrl')}
              </Button>
              <Button type="button" size="sm" onClick={() => { setImportMode('text'); setImportOpen(true) }}>
                <AddIcon className="h-4 w-4" />{t('extensions.addLocal')}
              </Button>
            </div>
          </div>

          <div className="flex flex-col gap-3 px-1 sm:flex-row sm:items-center">
            <SegmentedControl
              value={filter}
              onChange={(value) => setFilter(value as ExtensionFilter)}
              ariaLabel={t('extensions.filterLabel')}
              className="grid-cols-2 sm:grid-cols-4"
              options={([
                ['all', t('extensions.filters.all')],
                ['enabled', t('extensions.filters.enabled')],
                ['mitm', t('extensions.filters.mitm')],
                ['local', t('extensions.filters.local')],
              ] as Array<[ExtensionFilter, string]>).map(([value, label]) => ({ value, label }))}
            />
            <div className="relative min-w-0 sm:ml-auto sm:w-[280px] sm:flex-none">
              <SearchIcon className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                aria-label={t('extensions.search')}
                placeholder={t('extensions.searchPlaceholder')}
                className="pl-10"
              />
            </div>
          </div>

          {visibleModules.length > 0 ? <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          {visibleModules.map((module) => (
            <ExtensionCard
              key={module.id}
              module={module}
              busy={busyID === module.id}
              trusted={acknowledged}
              onToggle={(selected) => {
                if (selected.id === 'builtin-wloc' && !selected.enabled && (!wloc || wloc.longitude === null || wloc.latitude === null)) {
                  setWlocConfigOpen(true)
                  return
                }
                setPending({ kind: 'toggle', module: selected })
              }}
              onDelete={(selected) => setPending({ kind: 'delete', module: selected })}
              onInspect={(selected) => void inspectModule(selected)}
              onAcknowledge={(selected) => setPending({ kind: 'partial', module: selected })}
              onConfigure={(selected) => selected.id === 'builtin-wloc' ? setWlocConfigOpen(true) : setConfigTarget(selected)}
              onAudit={(selected) => void navigate(`/extensions/hosts?plugin=${encodeURIComponent(selected.id)}`)}
              onCheckUpdate={(selected) => void checkExtensionUpdate(selected)}
            />
          ))}
          </div> : (
            <Card className="p-10 text-center shadow-none">
              <div className="text-[13px] font-medium text-text-strong">{t('extensions.noMatches')}</div>
              <div className="mt-1 text-[11.5px] text-text-faint">{t('extensions.noMatchesHint')}</div>
            </Card>
          )}

        </>
      ) : null}

      {showingHosts && view ? (
        <>
          <div className="flex items-center justify-between gap-3 px-1">
            <p className="text-[12.5px] text-text-faint">{t('extensions.hostAudit.intro')}</p>
            <Button type="button" variant="secondary" size="sm" onClick={() => void navigate('/extensions')}>{t('extensions.backToCatalog')}</Button>
          </div>
          <HostAuditView
            view={view}
            settings={settings}
            moduleID={scopedModuleID}
            onClearModule={() => void navigate('/extensions/hosts')}
          />
        </>
      ) : null}

      {view ? (
        <ImportModuleModal
          open={importOpen}
          initialMode={importMode}
          revision={view.revision}
          existingIDs={view.modules.map((module) => module.id)}
          onOpenChange={setImportOpen}
          onImported={(next) => {
            setView(next)
            void api.getWLOCIntercept().then(setWloc).catch(() => undefined)
          }}
        />
      ) : null}

      <Modal
        open={wlocConfigOpen}
        onOpenChange={setWlocConfigOpen}
        title={t('settings.wlocTitle')}
        className="w-[min(94vw,760px)]"
      >
        <WLOCInterceptCard
          embedded
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
            setWlocConfigOpen(false)
            void load()
          }}
        />
      </Modal>

      <SnapshotModal open={snapshotOpen} loading={snapshotLoading} snapshot={snapshot} onOpenChange={setSnapshotOpen} />

      <ExtensionConfigModal
        module={configTarget}
        onOpenChange={(open) => { if (!open) setConfigTarget(null) }}
        onSave={(module, update) => {
          setConfigTarget(null)
          void updateModule(module, update, t('extensions.parametersSaved'))
        }}
      />

      <ExtensionUpdateModal
        review={updateReview}
        busy={updateBusy}
        onOpenChange={(open) => { if (!open) setUpdateReview(null) }}
        onApply={() => void applyExtensionUpdate()}
      />

      <ConfirmDialog
        open={pending?.kind === 'toggle'}
        onOpenChange={(open) => { if (!open) setPending(null) }}
        title={pending?.module.enabled
          ? t('extensions.disableTitle', { name: pending.module.id === 'builtin-wloc' ? t('settings.wlocTitle') : pending.module.name })
          : t('extensions.enableTitle', { name: pending?.module.id === 'builtin-wloc' ? t('settings.wlocTitle') : pending?.module.name ?? '' })}
        description={pending?.module.enabled ? t('extensions.disableBody') : t('extensions.enableBody')}
        confirmLabel={pending?.module.enabled ? t('extensions.toggleOff') : t('extensions.toggleOn')}
        cancelLabel={t('common.cancel')}
        danger={pending?.module.enabled}
        onConfirm={() => {
          if (pending) void updateModule(pending.module, { enabled: !pending.module.enabled }, t('extensions.updated'))
          setPending(null)
        }}
      />
      <ConfirmDialog
        open={pending?.kind === 'delete'}
        onOpenChange={(open) => { if (!open) setPending(null) }}
        title={t('extensions.deleteTitle', { name: pending?.module.name ?? '' })}
        description={t('extensions.deleteBody')}
        confirmLabel={t('extensions.delete')}
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
        title={t('extensions.acknowledgeTitle', { name: pending?.module.name ?? '' })}
        description={t('extensions.acknowledgeBody')}
        confirmLabel={t('extensions.acknowledge')}
        cancelLabel={t('common.cancel')}
        onConfirm={() => {
          if (pending) void updateModule(pending.module, { partial_allowed: true }, t('extensions.acknowledged'))
          setPending(null)
        }}
      />
    </div>
  )
}
