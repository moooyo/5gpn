import { useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import {
  AddIcon,
  ArrowDownIcon,
  ArrowUpIcon,
  CloudIcon,
  DeleteIcon,
  ExtensionFilledIcon,
  ExternalLinkIcon,
  FileIcon,
  FileSearchIcon,
  LinkIcon,
  NetworkIcon,
  RefreshIcon,
  RouteIcon,
  SearchIcon,
  ShieldLockIcon,
  TuneIcon,
  UploadIcon,
  VerifiedIcon,
  WarningIcon,
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
  Select,
  SegmentedControl,
  Toggle,
  toast,
} from '../../components/ds'
import { api } from '../../lib/api/client'
import type {
  InterceptCaptureDNS,
  InterceptLocationValue,
  InterceptModule,
  InterceptModuleSetting,
  InterceptModuleSnapshot,
  InterceptModulesView,
  MITMSettingsView,
} from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { useMITMTrustAcknowledgement } from '../../lib/mitmTrust'
import { HostAuditView } from './HostAuditView'
import { ExtensionInstallReview } from './ExtensionInstallReview'

import { LocationPicker, type LocationPoint } from './LocationPicker'

type InstallMode = 'url' | 'local'
type ExtensionFilter = 'all' | 'enabled' | 'capture' | 'local'
type PendingReorderAction = {
  kind: 'reorder'
  module: InterceptModule
  revision: string
  beforeOrder: string[]
  afterOrder: string[]
}
type PendingAction = { kind: 'toggle' | 'delete'; module: InterceptModule } | PendingReorderAction | null
const DEFAULT_EGRESS_GROUP = '__5gpn_ui_terminal_target__'

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

function settingInitialValue(setting: InterceptModuleSetting): unknown {
  return setting.value !== undefined ? setting.value : setting.default
}

function settingReady(setting: InterceptModuleSetting, value: unknown): boolean {
  if (!setting.required && (value === undefined || value === null || value === '')) return true
  if (setting.type === 'boolean') return typeof value === 'boolean'
  if (setting.type === 'number') return typeof value === 'number' && Number.isFinite(value) && (setting.min === undefined || value >= setting.min) && (setting.max === undefined || value <= setting.max)
  if (setting.type === 'location') {
    const location = value as Partial<InterceptLocationValue> | undefined
    return !!location && Number.isFinite(location.longitude) && Number.isFinite(location.latitude) && Number.isFinite(location.accuracy) &&
      Number(location.longitude) >= -180 && Number(location.longitude) <= 180 && Number(location.latitude) >= -90 && Number(location.latitude) <= 90 &&
      Number(location.accuracy) >= 1 && Number(location.accuracy) <= 100000
  }
  return typeof value === 'string' && value.trim() !== '' && (setting.type !== 'select' || (setting.options ?? []).includes(value))
}

function asLocation(value: unknown): LocationPoint {
  const location = value && typeof value === 'object' ? value as Partial<InterceptLocationValue> : {}
  return {
    longitude: typeof location.longitude === 'number' ? location.longitude : undefined,
    latitude: typeof location.latitude === 'number' ? location.latitude : undefined,
    accuracy: typeof location.accuracy === 'number' && Number.isFinite(location.accuracy) ? location.accuracy : 25,
  }
}

function ExtensionCard({
  module,
  busy,
  trusted,
  egressGroups,
  reorderEnabled,
  total,
  onToggle,
  onDelete,
  onInspect,
  onConfigure,
  onAudit,
  onCheckUpdate,
  onMove,
}: {
  module: InterceptModule
  busy: boolean
  trusted: boolean
  egressGroups: string[]
  reorderEnabled: boolean
  total: number
  onToggle: (module: InterceptModule) => void
  onDelete: (module: InterceptModule) => void
  onInspect: (module: InterceptModule) => void
  onConfigure: (module: InterceptModule) => void
  onAudit: (module: InterceptModule) => void
  onCheckUpdate: (module: InterceptModule) => void
  onMove: (module: InterceptModule, direction: -1 | 1) => void
}) {
  const { t, i18n } = useTranslation()
  const imported = module.imported_at ? new Intl.DateTimeFormat(i18n.language, { dateStyle: 'medium' }).format(new Date(module.imported_at)) : ''
  const settingsCount = module.settings?.length ?? 0
  const mappingsCount = module.upstream_mappings?.length ?? 0
  const routingRuleCount = module.routing_rules?.length ?? 0
  const sourceLabel = sourceHost(module.source_url) || t('extensions.localSnapshot')
  const canArmWhileMasterOff = module.reason === 'mitm-disabled'
  const groupMissing = (module.egress_group_required && !module.egress_group) || (!!module.egress_group && !egressGroups.includes(module.egress_group))
  const toggleDisabled = busy || (!module.enabled && (groupMissing || (!module.ready && !canArmWhileMasterOff)))
  const trustWarning = module.enabled && !trusted

  return (
    <Card className="min-w-0 overflow-hidden border-0 shadow-[var(--md-sys-elevation-1)]" data-testid={`extension-${module.id}`}>
      <CardBody className="flex h-full min-h-[210px] flex-col gap-3 p-4.5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className={cn(
              'grid h-11 w-11 shrink-0 place-items-center rounded-[12px]',
              module.enabled ? 'bg-primary-container text-on-primary-container' : 'bg-surface-container text-text-faint',
            )}>
              <ExtensionFilledIcon className="h-5 w-5" aria-hidden="true" />
            </span>
            <div className="min-w-0">
              <h2 className="truncate text-[14.5px] font-medium leading-tight text-text-strong">{module.name}</h2>
              <p className="mt-1 truncate text-[10.5px] text-text-faint">
                {module.id} · v{module.extension_version}{imported ? ` · ${imported}` : ''}
              </p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <span className="rounded-full bg-surface-container-low px-2 py-1 font-mono text-[10px] text-text-faint" aria-label={t('extensions.executionOrder', { order: module.execution_order })}>{String(module.execution_order).padStart(2, '0')}</span>
            <Toggle checked={module.enabled} onCheckedChange={() => onToggle(module)} disabled={toggleDisabled} aria-label={`${module.enabled ? t('extensions.toggleOff') : t('extensions.toggleOn')} · ${module.name}`} />
          </div>
        </div>

        {module.description ? <p className="line-clamp-2 min-h-10 text-[11.5px] leading-5 text-text-soft">{module.description}</p> : <div className="min-h-10" />}

        <div className="flex flex-wrap items-center gap-1.5">
          {!module.enabled ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="neutral">{t('extensions.disabled')}</Badge> : null}
          {module.script_count > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.capabilityAction', { count: module.script_count })}</Badge> : null}
          {module.network_origins.length > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="indigo"><NetworkIcon className="mr-1 inline h-3.5 w-3.5" aria-hidden="true" />{t('extensions.capabilityNetwork', { count: module.network_origins.length })}</Badge> : null}
          {module.egress_group ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="cyan"><RouteIcon className="mr-1 inline h-3.5 w-3.5" aria-hidden="true" />{t('extensions.capabilityEgress', { group: module.egress_group })}</Badge> : null}
          <button type="button" aria-label={t('extensions.auditHosts')} onClick={() => onAudit(module)} className="zds-state-layer inline-flex items-center gap-1 rounded-[6px] bg-primary-container px-2.5 py-0.5 text-[11px] font-medium text-on-primary-container">
            <ShieldLockIcon className="h-3.5 w-3.5" aria-hidden="true" /> {t('extensions.captureCount', { count: module.capture_hosts.length })}
          </button>
          <Badge className="rounded-[6px] px-2.5 py-0.5" tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>
            <RouteIcon className="mr-1 inline h-3.5 w-3.5" aria-hidden="true" />{t('extensions.captureDNS.badge', { group: t(`extensions.captureDNS.${module.capture_dns}`) })}
          </Badge>
          {mappingsCount > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="cyan">{t('extensions.capabilityHost', { count: mappingsCount })}</Badge> : null}
          {routingRuleCount > 0 ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.capabilityRouting', { count: routingRuleCount })}</Badge> : null}
          {module.persistent_storage ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="indigo">{t('extensions.capabilityStorage')}</Badge> : null}
          {trustWarning ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.trustPending')}</Badge> : null}
          {module.enabled && module.reason === 'mitm-disabled' ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber">{t('extensions.masterPending')}</Badge> : null}
          {module.reason === 'settings-required' ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="blue">{t('extensions.settingsRequired')}</Badge> : null}
          {groupMissing ? <Badge className="rounded-[6px] px-2.5 py-0.5" tone="amber"><WarningIcon className="mr-1 inline h-3.5 w-3.5" aria-hidden="true" />{t('extensions.egressGroupMissing')}</Badge> : null}
        </div>

        {routingRuleCount > 0 ? <details className="group rounded-[10px] bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]" data-testid={`routing-rules-${module.id}`}>
          <summary className="zds-state-layer cursor-pointer list-none rounded-[10px] px-3 py-2 text-[10.5px] font-semibold marker:hidden">{t('extensions.routingRulesInspect', { count: routingRuleCount })}</summary>
          <div className="max-h-40 space-y-1.5 overflow-y-auto border-t border-[rgb(0_0_0_/_10%)] px-3 py-2.5">
            {module.routing_rules!.map((rule, index) => <code key={`${index}:${JSON.stringify(rule)}`} className="block break-all rounded-[7px] bg-[rgb(0_0_0_/_8%)] px-2 py-1 font-mono text-[9.5px]">{JSON.stringify(rule)}</code>)}
          </div>
        </details> : null}

        <div className="mt-auto flex min-w-0 flex-wrap items-center gap-1 border-t border-divider pt-3">
          <div className="flex shrink-0 items-center gap-0.5">
            <Button type="button" variant="ghost" size="sm" className="h-10 w-10 px-0 sm:h-8 sm:w-8" aria-label={t('extensions.moveUp', { name: module.name })} title={t('extensions.moveUp', { name: module.name })} disabled={!reorderEnabled || module.execution_order <= 1 || busy} onClick={() => onMove(module, -1)}><ArrowUpIcon className="h-4 w-4" /></Button>
            <Button type="button" variant="ghost" size="sm" className="h-10 w-10 px-0 sm:h-8 sm:w-8" aria-label={t('extensions.moveDown', { name: module.name })} title={t('extensions.moveDown', { name: module.name })} disabled={!reorderEnabled || module.execution_order >= total || busy} onClick={() => onMove(module, 1)}><ArrowDownIcon className="h-4 w-4" /></Button>
          </div>
          <span className="order-first flex min-w-0 basis-full items-center gap-1.5 pb-1 text-[10.5px] text-text-faint sm:order-none sm:basis-auto sm:pb-0 sm:flex-1">
            {module.source_url ? <CloudIcon className="h-4 w-4 shrink-0" aria-hidden="true" /> : <FileIcon className="h-4 w-4 shrink-0" aria-hidden="true" />}
            <span className="max-w-[180px] truncate sm:max-w-[104px]">{sourceLabel}</span>
            <code className="shrink-0 font-mono text-[9px] text-text-faint" title={module.snapshot_digest}>· {module.snapshot_digest.slice(0, 8)}</code>
          </span>
          {module.source_url ? (
            <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0" aria-label={t('extensions.checkUpdate')} title={t('extensions.checkUpdate')} disabled={busy} onClick={() => onCheckUpdate(module)}>
              <RefreshIcon className="h-4 w-4" />
            </Button>
          ) : null}
          <Button type="button" variant="secondary" size="sm" className="shrink-0" disabled={busy} onClick={() => onConfigure(module)}>
            <TuneIcon className="h-4 w-4" /> {settingsCount > 0 ? t('extensions.settingsAction', { count: settingsCount }) : t('extensions.configureAction')}
          </Button>
          <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0" aria-label={t('extensions.inspect')} title={t('extensions.inspect')} disabled={busy} onClick={() => onInspect(module)}>
            <FileSearchIcon className="h-4 w-4" />
          </Button>
          <Button type="button" variant="ghost" size="sm" className="w-8 shrink-0 px-0 text-[var(--md-sys-color-error)]" aria-label={t('extensions.delete')} title={t('extensions.delete')} disabled={busy || module.enabled} onClick={() => onDelete(module)}>
            <DeleteIcon className="h-4 w-4" />
          </Button>
        </div>
      </CardBody>
    </Card>
  )
}

function ExtensionSettingsModal({
  module,
  egressGroups,
  onOpenChange,
  onSave,
}: {
  module: InterceptModule | null
  egressGroups: string[]
  onOpenChange: (open: boolean) => void
  onSave: (module: InterceptModule, settings: Record<string, unknown>, egressGroup?: string, captureDNS?: InterceptCaptureDNS) => void
}) {
  const { t } = useTranslation()
  const [values, setValues] = useState<Record<string, unknown>>({})
  const [egressGroup, setEgressGroup] = useState(DEFAULT_EGRESS_GROUP)
  const [captureDNS, setCaptureDNS] = useState<InterceptCaptureDNS>('trust')

  useEffect(() => {
    setValues(Object.fromEntries((module?.settings ?? []).map((setting) => [setting.key, settingInitialValue(setting)])))
    setEgressGroup(module?.egress_group && egressGroups.includes(module.egress_group) ? module.egress_group : DEFAULT_EGRESS_GROUP)
    setCaptureDNS(module?.capture_dns ?? 'trust')
  }, [egressGroups, module])

  const initial = Object.fromEntries((module?.settings ?? []).map((setting) => [setting.key, settingInitialValue(setting)]))
  const changed = !!module && JSON.stringify(values) !== JSON.stringify(initial)
  const ready = (module?.settings ?? []).every((setting) => settingReady(setting, values[setting.key]))
  const selectedEgressGroup = egressGroup === DEFAULT_EGRESS_GROUP ? '' : egressGroup
  const egressChanged = !!module && selectedEgressGroup !== (module.egress_group ?? '')
  const captureDNSChanged = !!module && captureDNS !== module.capture_dns
  const egressReady = !module?.egress_group_required || (selectedEgressGroup !== '' && egressGroups.includes(selectedEgressGroup))
  const hasLocation = module?.settings?.some((setting) => setting.type === 'location') ?? false

  return (
    <Modal
      open={!!module}
      onOpenChange={onOpenChange}
      title={module ? t('extensions.configureTitle', { name: module.name }) : ''}
      className={hasLocation ? 'w-[min(96vw,920px)]' : undefined}
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button>
          <Button type="button" size="sm" disabled={!module || (!changed && !egressChanged && !captureDNSChanged) || !ready || !egressReady} onClick={() => module && onSave(module, Object.fromEntries((module.settings ?? []).map((setting) => [setting.key, values[setting.key] ?? null])), egressChanged ? selectedEgressGroup : undefined, captureDNSChanged ? captureDNS : undefined)}>{t('common.save')}</Button>
        </>
      }
    >
      {module ? (
        <div className="space-y-5">
          <section className="rounded-[14px] bg-surface-container-low p-4" data-testid="capture-dns-editor">
            <div className="text-[12px] font-medium text-text-strong">{t('extensions.captureDNS.title')}</div>
            <p className="mt-1 text-[10.5px] leading-4 text-text-faint">{t('extensions.captureDNS.hint')}</p>
            <SegmentedControl
              value={captureDNS}
              onChange={(value) => setCaptureDNS(value as InterceptCaptureDNS)}
              ariaLabel={t('extensions.captureDNS.title')}
              className="mt-3 grid-cols-2"
              options={([
                ['trust', t('extensions.captureDNS.trust')],
                ['china', t('extensions.captureDNS.china')],
              ] as Array<[InterceptCaptureDNS, string]>).map(([value, label]) => ({ value, label }))}
            />
            <p className="mt-3 text-[10.5px] leading-4 text-text-soft">{t(`extensions.captureDNS.${captureDNS}Hint`)}</p>
          </section>
          <section className="rounded-[14px] bg-surface-container-low p-4">
            <div className="text-[12px] font-medium text-text-strong">{t('extensions.egressGroupTitle')}</div>
            <p className="mt-1 text-[10.5px] leading-4 text-text-faint">{t('extensions.egressGroupHint')}</p>
            {((module.egress_group_required && !module.egress_group) || (!!module.egress_group && !egressGroups.includes(module.egress_group))) ? <p role="alert" className="mt-3 text-[11px] font-medium text-[var(--md-sys-color-error)]">{t('extensions.egressGroupMissingDetail', { group: module.egress_group || t('extensions.egressGroupUnset') })}</p> : null}
            <Select value={egressGroup} onValueChange={setEgressGroup} items={[{ value: DEFAULT_EGRESS_GROUP, label: t('extensions.egressGroupDefault') }, ...egressGroups.map((group) => ({ value: group, label: group }))]} placeholder={t('extensions.selectEgressGroup')} className="mt-3 w-full" />
          </section>
          {(module.settings ?? []).map((setting) => {
            const label = setting.label || setting.key
            const description = setting.description
            if (setting.type === 'location') {
              const location = asLocation(values[setting.key])
              return (
                <section key={setting.key} className="space-y-3">
                  <div>
                    <div className="text-[12.5px] font-medium text-text-strong">{label}{setting.required ? ' *' : ''}</div>
                    {description ? <p className="mt-1 text-[10.5px] leading-4 text-text-faint">{description}</p> : null}
                  </div>
                  <LocationPicker value={location} onChange={(next) => setValues((current) => ({ ...current, [setting.key]: next }))} />
                  <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                    <Field label={t('extensions.location.longitude')}>
                      <Input aria-label={t('extensions.location.longitude')} type="number" step="any" min={-180} max={180} value={location.longitude ?? ''} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: { ...location, longitude: event.target.value === '' ? undefined : Number(event.target.value) } }))} />
                    </Field>
                    <Field label={t('extensions.location.latitude')}>
                      <Input aria-label={t('extensions.location.latitude')} type="number" step="any" min={-90} max={90} value={location.latitude ?? ''} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: { ...location, latitude: event.target.value === '' ? undefined : Number(event.target.value) } }))} />
                    </Field>
                    <Field label={t('extensions.location.accuracy')}>
                      <Input aria-label={t('extensions.location.accuracy')} type="number" step={1} min={1} max={100000} value={location.accuracy} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: { ...location, accuracy: Number(event.target.value) } }))} />
                    </Field>
                  </div>
                </section>
              )
            }
            if (setting.type === 'boolean') {
              return (
                <div key={setting.key} className="flex items-start justify-between gap-4 rounded-[14px] bg-surface-container-low p-4">
                  <div>
                    <div className="text-[12px] font-medium text-text-strong">{label}</div>
                    {description ? <p className="mt-1 text-[10.5px] leading-4 text-text-faint">{description}</p> : null}
                  </div>
                  <Toggle checked={values[setting.key] === true} onCheckedChange={(checked) => setValues((current) => ({ ...current, [setting.key]: checked }))} aria-label={label} />
                </div>
              )
            }
            return (
              <Field key={setting.key} label={`${label}${setting.required ? ' *' : ''}`}>
                {setting.type === 'select' ? (
                  <select aria-label={label} className="w-full rounded-[10px] border border-input-border bg-input px-3 py-2.5 text-[12px] text-text-strong outline-none" value={String(values[setting.key] ?? '')} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: event.target.value }))}>
                    <option value="">{t('extensions.selectSetting')}</option>
                    {(setting.options ?? []).map((option) => <option key={option} value={option}>{option}</option>)}
                  </select>
                ) : (
                  <Input aria-label={label} type={setting.type === 'number' ? 'number' : 'text'} min={setting.min} max={setting.max} value={String(values[setting.key] ?? '')} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: setting.type === 'number' ? (event.target.value === '' ? undefined : Number(event.target.value)) : event.target.value }))} />
                )}
                {description ? <p className="mt-1 text-[10.5px] leading-4 text-text-faint">{description}</p> : null}
              </Field>
            )
          })}
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
          <Button type="button" size="sm" disabled={!review || review.current.enabled || busy} onClick={onApply}>{busy ? t('common.saving') : t('extensions.applyUpdate')}</Button>
        </>
      }
    >
      {review ? (
        <div className="space-y-4">
          {review.current.enabled ? <div role="alert" className="rounded-[12px] bg-[var(--md-sys-color-warning-container)] px-3.5 py-3 text-[11px] text-[var(--md-sys-color-on-warning-container)]">{t('extensions.disableBeforeUpdate')}</div> : null}
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-[14px] bg-surface-container-low p-4">
              <div className="text-[10.5px] font-medium text-text-faint">{t('extensions.currentSnapshot')} · v{review.current.extension_version}</div>
              <code className="mt-2 block break-all font-mono text-[10.5px] text-text-mid">{review.current.snapshot_digest}</code>
            </div>
            <div className="rounded-[14px] bg-primary-container p-4 text-on-primary-container">
              <div className="text-[10.5px] font-medium opacity-70">{t('extensions.candidateSnapshot')} · v{review.candidate.extension_version}</div>
              <code className="mt-2 block break-all font-mono text-[10.5px]">{review.candidate.snapshot_digest}</code>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone="blue">{t('extensions.captureCount', { count: review.candidate.capture_hosts.length })}</Badge>
            <Badge tone="amber">{t('extensions.capabilityAction', { count: review.candidate.script_count })}</Badge>
            {(review.candidate.routing_rules?.length ?? 0) > 0 ? <Badge tone="amber">{t('extensions.capabilityRouting', { count: review.candidate.routing_rules!.length })}</Badge> : null}
            {review.candidate.network_origins.length > 0 ? <Badge tone="indigo">{t('extensions.capabilityNetwork', { count: review.candidate.network_origins.length })}</Badge> : null}
            {review.candidate.egress_group_required ? <Badge tone="cyan">{t('extensions.egressGroupTitle')}</Badge> : null}
            {(review.candidate.settings?.length ?? 0) > 0 ? <Badge tone="indigo">{t('extensions.settingsAction', { count: review.candidate.settings?.length ?? 0 })}</Badge> : null}
          </div>
          <section className="rounded-[14px] bg-surface-container-low p-3.5" data-testid="update-capture-dns">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="text-[11px] font-medium text-text-faint">{t('extensions.captureDNS.title')}</div>
              <Badge tone={review.candidate.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${review.candidate.capture_dns}`)}</Badge>
            </div>
            <p className="mt-1.5 text-[10.5px] leading-4 text-text-soft">{t(`extensions.captureDNS.${review.candidate.capture_dns}Hint`)}</p>
          </section>
          <div>
            <div className="mb-2 text-[11px] font-medium text-text-faint">{t('extensions.captureHosts')}</div>
            <div className="flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-[12px] bg-surface-container-low p-3">
              {review.candidate.capture_hosts.map((host) => <code key={host} className="rounded-[7px] bg-card px-2 py-1 font-mono text-[10px] text-text-mid">{host}</code>)}
            </div>
          </div>
          {review.candidate.network_origins.length > 0 ? <div>
            <div className="mb-2 text-[11px] font-medium text-text-faint">{t('extensions.networkOriginsTitle')}</div>
            <div className="flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-[12px] bg-[var(--md-sys-color-warning-container)] p-3 text-[var(--md-sys-color-on-warning-container)]">
              {review.candidate.network_origins.map((origin) => <code key={origin} title={origin} className="inline-block min-w-0 max-w-full break-all rounded-[7px] bg-[rgb(0_0_0_/_8%)] px-2 py-1 font-mono text-[10px]">{origin}</code>)}
            </div>
          </div> : null}
          {(review.candidate.routing_rules?.length ?? 0) > 0 ? <div>
            <div className="mb-2 text-[11px] font-medium text-text-faint">{t('extensions.routingRulesTitle')}</div>
            <div className="max-h-40 space-y-1.5 overflow-y-auto rounded-[12px] bg-[var(--md-sys-color-warning-container)] p-3 text-[var(--md-sys-color-on-warning-container)]">
              {review.candidate.routing_rules!.map((rule, index) => <code key={`${index}:${JSON.stringify(rule)}`} className="block break-all rounded-[7px] bg-[rgb(0_0_0_/_8%)] px-2 py-1 font-mono text-[10px]">{JSON.stringify(rule)}</code>)}
            </div>
          </div> : null}
          <p className="text-[10.5px] leading-5 text-text-faint">{t('extensions.updateSafety')}</p>
        </div>
      ) : null}
    </Modal>
  )
}

function EnableExtensionModal({
  module,
  onOpenChange,
  onConfirm,
}: {
  module: InterceptModule | null
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const { t } = useTranslation()
  return (
    <Modal
      open={!!module}
      onOpenChange={onOpenChange}
      title={module ? t('extensions.enableTitle', { name: module.name }) : ''}
      className="w-[min(94vw,580px)]"
      footer={<><Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button><Button type="button" size="sm" onClick={onConfirm}>{t('extensions.toggleOn')}</Button></>}
    >
      {module ? <div className="space-y-4">
        <p className="text-[12.5px] leading-6 text-text-soft">{t('extensions.enableBody')}</p>
        <section className="rounded-[14px] bg-primary-container p-4 text-on-primary-container" data-testid="enable-capture-dns">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-[11px] font-semibold">{t('extensions.captureDNS.title')}</div>
            <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge>
          </div>
          <p className="mt-1.5 text-[10.5px] leading-4 opacity-80">{t(`extensions.captureDNS.${module.capture_dns}Hint`)}</p>
        </section>
        {module.network_origins.length > 0 ? <section className="rounded-[14px] bg-[var(--md-sys-color-warning-container)] p-4 text-[11.5px] leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <div className="font-semibold">{t('extensions.networkOriginsTitle')}</div>
          <p className="mt-1">{t('extensions.networkOriginsWarning')}</p>
          <div className="mt-3 flex max-h-32 flex-wrap gap-1.5 overflow-y-auto">
            {module.network_origins.map((origin) => <code key={origin} title={origin} className="inline-block min-w-0 max-w-full break-all rounded-[7px] bg-[rgb(0_0_0_/_8%)] px-2 py-1 font-mono text-[10px]">{origin}</code>)}
          </div>
        </section> : <section className="rounded-[14px] bg-surface-container-low p-4 text-[11.5px] text-text-soft"><div className="font-medium text-text-strong">{t('extensions.networkOriginsTitle')}</div><p className="mt-1">{t('extensions.networkOriginsNone')}</p></section>}
        {module.egress_group_required || module.egress_group ? <section className="rounded-[14px] bg-surface-container-low p-4"><div className="text-[11px] font-medium text-text-faint">{t('extensions.egressGroupTitle')}</div><code className="mt-1.5 block font-mono text-[12px] text-text-strong">{module.egress_group || t('extensions.egressGroupUnset')}</code></section> : null}
        {(module.routing_rules?.length ?? 0) > 0 ? <section className="rounded-[14px] bg-[var(--md-sys-color-warning-container)] p-4 text-[11.5px] leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <div className="font-semibold">{t('extensions.routingRulesTitle')}</div>
          <p className="mt-1">{t('extensions.routingRulesWarning')}</p>
          <div className="mt-3 max-h-40 space-y-1.5 overflow-y-auto">
            {module.routing_rules!.map((rule, index) => <code key={`${index}:${JSON.stringify(rule)}`} className="block break-all rounded-[7px] bg-[rgb(0_0_0_/_8%)] px-2 py-1 font-mono text-[10px]">{JSON.stringify(rule)}</code>)}
          </div>
        </section> : null}
      </div> : null}
    </Modal>
  )
}

function ReorderExtensionModal({
  action,
  modules,
  onOpenChange,
  onConfirm,
}: {
  action: PendingReorderAction | null
  modules: InterceptModule[]
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}) {
  const { t } = useTranslation()
  const modulesByID = new Map(modules.map((module) => [module.id, module]))

  function renderOrder(order: string[], testID: string) {
    return (
      <ol className="space-y-1.5" data-testid={testID}>
        {order.map((id, index) => {
          const module = modulesByID.get(id)
          return (
            <li key={id} className="flex min-w-0 flex-wrap items-center gap-2 rounded-[9px] bg-card px-2.5 py-2">
              <span className="grid h-5 w-5 shrink-0 place-items-center rounded-full bg-surface-container text-[10px] font-semibold text-text-faint">{index + 1}</span>
              <span className="min-w-0 flex-1 truncate text-[11.5px] font-medium text-text-strong">{module?.name ?? id}</span>
              {module ? <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge> : null}
              <code className="max-w-[42%] truncate font-mono text-[9.5px] text-text-faint" title={id}>{id}</code>
            </li>
          )
        })}
      </ol>
    )
  }

  return (
    <Modal
      open={!!action}
      onOpenChange={onOpenChange}
      title={action ? t('extensions.reorderConfirmTitle', { name: action.module.name }) : ''}
      className="w-[min(94vw,760px)]"
      footer={<><Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>{t('common.cancel')}</Button><Button type="button" size="sm" onClick={onConfirm}>{t('extensions.reorderConfirmAction')}</Button></>}
    >
      {action ? <div className="space-y-4">
        <p className="text-[12.5px] leading-6 text-text-soft">{t('extensions.reorderConfirmBody')}</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <section className="min-w-0 rounded-[14px] bg-surface-container-low p-3">
            <h3 className="mb-2 text-[11px] font-semibold text-text-faint">{t('extensions.reorderBefore')}</h3>
            {renderOrder(action.beforeOrder, 'extension-reorder-before')}
          </section>
          <section className="min-w-0 rounded-[14px] bg-primary-container p-3">
            <h3 className="mb-2 text-[11px] font-semibold text-on-primary-container">{t('extensions.reorderAfter')}</h3>
            {renderOrder(action.afterOrder, 'extension-reorder-after')}
          </section>
        </div>
      </div> : null}
    </Modal>
  )
}

function SnapshotModal({ open, loading, snapshot, onOpenChange }: { open: boolean; loading: boolean; snapshot: InterceptModuleSnapshot | null; onOpenChange: (open: boolean) => void }) {
  const { t } = useTranslation()
  return (
    <Modal open={open} onOpenChange={onOpenChange} title={snapshot ? t('extensions.snapshotTitle', { name: snapshot.name }) : t('extensions.snapshotLoading')} className="w-[min(94vw,780px)]" footer={<Button type="button" variant="secondary" onClick={() => onOpenChange(false)}>{t('extensions.snapshotClose')}</Button>}>
      {loading ? <div className="py-8 text-center text-[12px] text-text-faint">{t('common.loading')}</div> : null}
      {!loading && snapshot ? (
        <div className="max-h-[68vh] space-y-4 overflow-y-auto pr-1">
          <section>
            <div className="mb-1.5 flex items-center justify-between gap-3 text-[10.5px] text-text-faint"><span className="font-bold uppercase tracking-[.08em]">{t('extensions.snapshotSource')}</span><code className="max-w-[70%] truncate" title={snapshot.source_digest}>{snapshot.source_digest}</code></div>
            <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap break-words rounded-[14px] bg-surface-container-low p-4 font-mono text-[10.5px] leading-relaxed text-text-mid">{snapshot.source_body}</pre>
          </section>
          {snapshot.scripts.map((script) => (
            <details key={script.id} className="rounded-[14px] bg-surface-container-low px-4 py-3">
              <summary className="cursor-pointer text-[11px] font-bold text-text-strong">{t('extensions.snapshotScript', { id: script.id })}<code className="ml-2 font-normal text-text-faint">{script.digest.slice(0, 12)}…</code></summary>
              {script.url ? <div className="mt-2 break-all text-[10px] text-primary">{script.url}</div> : null}
              <pre className="mt-2 max-h-[320px] overflow-auto whitespace-pre-wrap break-words rounded-[10px] bg-card p-3 font-mono text-[10.5px] leading-relaxed text-text-mid">{script.body}</pre>
            </details>
          ))}
        </div>
      ) : null}
    </Modal>
  )
}

function InstallExtensionModal({
  mode,
  revision,
  existingIDs,
  onOpenChange,
  onInstalled,
}: {
  mode: InstallMode | null
  revision: string
  existingIDs: string[]
  onOpenChange: (open: boolean) => void
  onInstalled: (view: InterceptModulesView) => void
}) {
  const { t } = useTranslation()
  const [url, setURL] = useState('')
  const [content, setContent] = useState('')
  const [busy, setBusy] = useState(false)
  const [review, setReview] = useState<InterceptModule | null>(null)

  function close() {
    setReview(null)
    onOpenChange(false)
  }

  async function submit() {
    if (!mode || (mode === 'url' ? !url.trim() : !content.trim())) {
      toast.error(t('extensions.install.required'))
      return
    }
    setBusy(true)
    try {
      const view = await api.importInterceptModule({ revision, ...(mode === 'url' ? { url: url.trim() } : { content }) })
      onInstalled(view)
      const installed = view.modules.find((module) => !existingIDs.includes(module.id)) ?? null
      setReview(installed)
      setURL('')
      setContent('')
      toast.success(t('extensions.install.success'))
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.install.failed')))
    } finally {
      setBusy(false)
    }
  }

  async function chooseFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    if (!file) return
    if (file.size > 2 * 1024 * 1024) {
      toast.error(t('extensions.install.tooLarge'))
      return
    }
    setContent(await file.text())
  }

  return (
    <Modal
      open={mode !== null}
      onOpenChange={(open) => { if (!open) close() }}
      title={mode === 'url' ? t('extensions.install.urlTitle') : t('extensions.install.localTitle')}
      className="w-[min(94vw,680px)]"
      footer={review ? <Button type="button" onClick={close}>{t('extensions.install.closeReview')}</Button> : <><Button type="button" variant="secondary" onClick={close}>{t('common.cancel')}</Button><Button type="button" disabled={busy} onClick={() => void submit()}>{busy ? t('extensions.install.installing') : t(mode === 'url' ? 'extensions.install.submitUrl' : 'extensions.install.submitLocal')}</Button></>}
    >
      {review ? <ExtensionInstallReview module={review} /> : mode === 'url' ? (
        <div className="space-y-4">
          <Field label={t('extensions.install.url')}><Input aria-label={t('extensions.install.url')} maxLength={4096} mono value={url} placeholder={t('extensions.install.urlPlaceholder')} onChange={(event) => setURL(event.target.value)} /></Field>
          <div className="flex items-start gap-2.5 rounded-[14px] bg-surface-container-low px-4 py-3" data-testid="extension-install-url-info"><FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" /><p className="text-[11px] leading-relaxed text-text-soft">{t('extensions.install.urlInfo')}</p></div>
        </div>
      ) : (
        <div className="space-y-4">
          <Field label={t('extensions.install.content')}>
            <textarea className="min-h-[240px] resize-y rounded-[14px] border border-input-border bg-input px-4 py-3 font-mono text-[12px] leading-5 text-text-strong outline-none focus:border-primary focus:bg-card" aria-label={t('extensions.install.content')} value={content} maxLength={2097152} placeholder={t('extensions.install.contentPlaceholder')} onChange={(event) => setContent(event.target.value)} />
            <label className="zds-state-layer mt-2 inline-flex cursor-pointer items-center gap-2 rounded-full px-3 py-2 text-[11.5px] font-medium text-primary"><UploadIcon className="h-4 w-4" /> {t('extensions.install.upload')}<input className="sr-only" type="file" accept=".yaml,.yml,.json,text/yaml,application/yaml,text/plain" onChange={(event) => void chooseFile(event)} /></label>
          </Field>
          <div className="flex items-start gap-2.5 rounded-[14px] bg-surface-container-low px-4 py-3" data-testid="extension-install-local-info"><FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" /><p className="text-[11px] leading-relaxed text-text-soft">{t('extensions.install.localInfo')}</p></div>
        </div>
      )}
    </Modal>
  )
}

export default function ExtensionsPage() {
  const { t } = useTranslation()
  const location = useLocation()
  const navigate = useNavigate()
  const { acknowledged } = useMITMTrustAcknowledgement()
  const [view, setView] = useState<InterceptModulesView | null>(null)
  const [settings, setSettings] = useState<MITMSettingsView | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [installMode, setInstallMode] = useState<InstallMode | null>(null)
  const [filter, setFilter] = useState<ExtensionFilter>('all')
  const [search, setSearch] = useState('')
  const [configTarget, setConfigTarget] = useState<InterceptModule | null>(null)
  const [updateReview, setUpdateReview] = useState<{ current: InterceptModule; candidate: InterceptModule } | null>(null)
  const [updateBusy, setUpdateBusy] = useState(false)
  const [busyID, setBusyID] = useState<string | null>(null)
  const mutationLock = useRef(false)
  const [pending, setPending] = useState<PendingAction>(null)
  const [snapshotOpen, setSnapshotOpen] = useState(false)
  const [snapshotLoading, setSnapshotLoading] = useState(false)
  const [snapshot, setSnapshot] = useState<InterceptModuleSnapshot | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(false)
    const [modulesResult, settingsResult] = await Promise.allSettled([api.getInterceptModules(), api.getMITMSettings()])
    if (modulesResult.status === 'fulfilled') setView(modulesResult.value)
    else setLoadError(true)
    if (settingsResult.status === 'fulfilled') setSettings(settingsResult.value)
    setLoading(false)
  }, [])

  useEffect(() => { void load() }, [load])

  const visibleModules = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase()
    return (view?.modules ?? []).filter((module) => {
      if (filter === 'enabled' && !module.enabled) return false
      if (filter === 'capture' && module.capture_hosts.length === 0) return false
      if (filter === 'local' && module.source_url) return false
      if (!needle) return true
      return `${module.id} ${module.name} ${module.description ?? ''} ${module.source_url ?? ''} ${module.capture_hosts.join(' ')}`.toLocaleLowerCase().includes(needle)
    }).sort((left, right) => left.execution_order - right.execution_order)
  }, [filter, search, view?.modules])
  const hostCount = useMemo(() => view?.modules.reduce((count, module) => count + module.capture_hosts.length, 0) ?? 0, [view?.modules])
  const activeCount = useMemo(() => view?.modules.filter((module) => module.enabled).length ?? 0, [view?.modules])
  const reorderModeAvailable = filter === 'all' && search.trim() === ''
  const showingHosts = location.pathname === '/extensions/hosts'
  const scopedModuleID = new URLSearchParams(location.search).get('plugin') ?? undefined
  const trustState = !acknowledged ? 'trust' : !settings?.enabled ? 'master' : 'ready'

  function beginModuleMutation(id: string): boolean {
    if (mutationLock.current) return false
    mutationLock.current = true
    setBusyID(id)
    return true
  }

  function finishModuleMutation() {
    mutationLock.current = false
    setBusyID(null)
  }

  async function updateModule(module: InterceptModule, update: { enabled?: boolean; settings?: Record<string, unknown>; egress_group?: string; capture_dns?: InterceptCaptureDNS }, success: string) {
    if (!view || !beginModuleMutation(module.id)) return
    try {
      setView(await api.putInterceptModule(module.id, { revision: view.revision, ...update }))
      toast.success(success)
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateFailed')))
      void load()
    } finally {
      finishModuleMutation()
    }
  }

  function requestModuleMove(module: InterceptModule, direction: -1 | 1) {
    if (!view || !reorderModeAvailable || mutationLock.current) return
    const beforeOrder = [...view.execution_order]
    const afterOrder = [...beforeOrder]
    const index = afterOrder.indexOf(module.id)
    const target = index + direction
    if (index < 0 || target < 0 || target >= afterOrder.length) return
    ;[afterOrder[index], afterOrder[target]] = [afterOrder[target], afterOrder[index]]
    setPending({ kind: 'reorder', module, revision: view.revision, beforeOrder, afterOrder })
  }

  async function confirmModuleMove(action: PendingReorderAction) {
    if (!view || view.revision !== action.revision || view.execution_order.join('\n') !== action.beforeOrder.join('\n')) {
      toast.error(t('extensions.orderChanged'))
      void load()
      return
    }
    if (!beginModuleMutation(action.module.id)) return
    try {
      setView(await api.reorderInterceptModules(action.revision, action.afterOrder))
      toast.success(t('extensions.orderSaved'))
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.orderFailed')))
      void load()
    } finally {
      finishModuleMutation()
    }
  }

  async function deleteModule(module: InterceptModule) {
    if (!view || !beginModuleMutation(module.id)) return
    try {
      setView(await api.deleteInterceptModule(module.id, view.revision))
      toast.success(t('extensions.deleted'))
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateFailed')))
      void load()
    } finally {
      finishModuleMutation()
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
    if (!view || !module.source_url || !beginModuleMutation(module.id)) return
    try {
      const result = await api.checkInterceptModuleUpdate(module.id, view.revision)
      if (result.state === 'unchanged' || !result.candidate) toast.success(t('extensions.updateUnchanged'))
      else setUpdateReview({ current: module, candidate: result.candidate })
    } catch (error) {
      toast.error(errorMessage(error, t('extensions.updateCheckFailed')))
      void load()
    } finally {
      finishModuleMutation()
    }
  }

  async function applyExtensionUpdate() {
    if (!view || !updateReview) return
    setUpdateBusy(true)
    try {
      setView(await api.applyInterceptModuleUpdate(updateReview.current.id, view.revision, updateReview.candidate.snapshot_digest))
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
      <div className={cn('flex flex-col gap-3 rounded-[20px] px-5 py-4 sm:flex-row sm:items-center sm:justify-between', trustState === 'ready' ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : trustState === 'master' ? 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]' : 'bg-primary-container text-on-primary-container')} data-testid="mitm-readiness-notice">
        <div className="flex items-start gap-2.5">{trustState === 'ready' ? <VerifiedIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" /> : <ShieldLockIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />}<div><div className="text-[12.5px] font-semibold">{t(`extensions.readiness.${trustState}.title`)}</div><p className="mt-0.5 text-[11px] leading-relaxed opacity-80">{t(`extensions.readiness.${trustState}.body`, { count: activeCount })}</p></div></div>
        <Link className={cn('zds-state-layer inline-flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-full px-5 text-[12px] font-medium', trustState === 'ready' ? 'bg-[rgb(0_0_0_/_8%)]' : 'bg-primary text-[var(--md-sys-color-on-primary)]')} to={trustState === 'master' ? '/settings' : '/setup-guide'}>{trustState !== 'ready' ? <LinkIcon className="h-4 w-4" aria-hidden="true" /> : null}{t(`extensions.readiness.${trustState}.action`)}</Link>
      </div>

      {loading && !view ? <Card><CardBody className="text-center text-[12px] text-text-faint">{t('common.loading')}</CardBody></Card> : null}
      {loadError && !view ? <Card><CardBody className="flex items-center justify-between gap-3"><span className="text-[12px] text-red">{t('extensions.loadFailed')}</span><Button variant="secondary" size="sm" onClick={() => void load()}><RefreshIcon className="h-4 w-4" />{t('extensions.retry')}</Button></CardBody></Card> : null}

      {!showingHosts && view ? <>
        <div className="flex flex-col gap-3 px-1 lg:flex-row lg:items-center">
          <p className="min-w-[240px] flex-1 text-[12.5px] leading-5 text-text-faint">{t('extensions.catalogSummary', { total: view.modules.length, enabled: activeCount })}{' '}<button type="button" className="zds-state-layer rounded-full px-2 py-1 font-medium text-primary" onClick={() => void navigate('/extensions/hosts')}>{t('extensions.tabs.hosts', { count: hostCount })}</button></p>
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" variant="ghost" size="sm" className="w-9 px-0" aria-label={t('extensions.refresh')} title={t('extensions.refresh')} onClick={() => void load()} disabled={loading}><RefreshIcon className="h-4 w-4" /></Button>
            <a href={view.catalog_url} target="_blank" rel="noreferrer" aria-label={t('extensions.catalog')} title={t('extensions.catalog')} className="zds-state-layer grid h-9 w-9 place-items-center rounded-full text-primary"><ExternalLinkIcon className="h-4 w-4" aria-hidden="true" /></a>
            <Button type="button" variant="tonal" size="sm" disabled={busyID !== null} onClick={() => setInstallMode('url')}><LinkIcon className="h-4 w-4" />{t('extensions.addUrl')}</Button>
            <Button type="button" size="sm" disabled={busyID !== null} onClick={() => setInstallMode('local')}><AddIcon className="h-4 w-4" />{t('extensions.addLocal')}</Button>
          </div>
        </div>
        <div className="flex flex-col gap-3 px-1 sm:flex-row sm:items-center">
          <SegmentedControl value={filter} onChange={(value) => setFilter(value as ExtensionFilter)} ariaLabel={t('extensions.filterLabel')} className="grid-cols-2 sm:grid-cols-4" options={([['all', t('extensions.filters.all')], ['enabled', t('extensions.filters.enabled')], ['capture', t('extensions.filters.capture')], ['local', t('extensions.filters.local')]] as Array<[ExtensionFilter, string]>).map(([value, label]) => ({ value, label }))} />
          <div className="relative min-w-0 sm:ml-auto sm:w-[300px] sm:flex-none"><SearchIcon className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" /><Input value={search} onChange={(event) => setSearch(event.target.value)} aria-label={t('extensions.search')} placeholder={t('extensions.searchPlaceholder')} className="pl-10" /></div>
        </div>
        {!reorderModeAvailable && view.modules.length > 1 ? <p role="status" data-testid="extension-order-hint" className="px-1 text-[10.5px] leading-4 text-text-faint">{t('extensions.orderUnavailableHint')}</p> : null}
        {visibleModules.length > 0 ? <div className="space-y-3" aria-busy={busyID !== null}>{visibleModules.map((module) => <ExtensionCard key={module.id} module={module} busy={busyID !== null} trusted={acknowledged} egressGroups={view.available_egress_groups} reorderEnabled={reorderModeAvailable} total={view.modules.length} onMove={requestModuleMove} onToggle={(selected) => setPending({ kind: 'toggle', module: selected })} onDelete={(selected) => setPending({ kind: 'delete', module: selected })} onInspect={(selected) => void inspectModule(selected)} onConfigure={setConfigTarget} onAudit={(selected) => void navigate(`/extensions/hosts?plugin=${encodeURIComponent(selected.id)}`)} onCheckUpdate={(selected) => void checkExtensionUpdate(selected)} />)}</div> : <Card className="p-10 text-center shadow-none"><div className="text-[13px] font-medium text-text-strong">{t('extensions.noMatches')}</div><div className="mt-1 text-[11.5px] text-text-faint">{t('extensions.noMatchesHint')}</div></Card>}
        </> : null}

      {showingHosts && view ? <><div className="flex items-center justify-between gap-3 px-1"><p className="text-[12.5px] text-text-faint">{t('extensions.hostAudit.intro')}</p><Button type="button" variant="secondary" size="sm" onClick={() => void navigate('/extensions')}>{t('extensions.backToCatalog')}</Button></div><HostAuditView view={view} settings={settings} moduleID={scopedModuleID} onClearModule={() => void navigate('/extensions/hosts')} /></> : null}

      {view ? <InstallExtensionModal mode={installMode} revision={view.revision} existingIDs={view.modules.map((module) => module.id)} onOpenChange={(open) => { if (!open) setInstallMode(null) }} onInstalled={setView} /> : null}
      <SnapshotModal open={snapshotOpen} loading={snapshotLoading} snapshot={snapshot} onOpenChange={setSnapshotOpen} />
      <ExtensionSettingsModal module={configTarget} egressGroups={view?.available_egress_groups ?? []} onOpenChange={(open) => { if (!open) setConfigTarget(null) }} onSave={(module, nextSettings, egressGroup, captureDNS) => { setConfigTarget(null); void updateModule(module, { settings: nextSettings, ...(egressGroup !== undefined ? { egress_group: egressGroup } : {}), ...(captureDNS !== undefined ? { capture_dns: captureDNS } : {}) }, t('extensions.settingsSaved')) }} />
      <ExtensionUpdateModal review={updateReview} busy={updateBusy} onOpenChange={(open) => { if (!open) setUpdateReview(null) }} onApply={() => void applyExtensionUpdate()} />
      <EnableExtensionModal module={pending?.kind === 'toggle' && !pending.module.enabled ? pending.module : null} onOpenChange={(open) => { if (!open) setPending(null) }} onConfirm={() => { if (pending) void updateModule(pending.module, { enabled: true }, t('extensions.updated')); setPending(null) }} />
      <ReorderExtensionModal action={pending?.kind === 'reorder' ? pending : null} modules={view?.modules ?? []} onOpenChange={(open) => { if (!open) setPending(null) }} onConfirm={() => { if (pending?.kind === 'reorder') void confirmModuleMove(pending); setPending(null) }} />
      <ConfirmDialog open={pending?.kind === 'toggle' && !!pending.module.enabled} onOpenChange={(open) => { if (!open) setPending(null) }} title={t('extensions.disableTitle', { name: pending?.module.name ?? '' })} description={t('extensions.disableBody')} confirmLabel={t('extensions.toggleOff')} cancelLabel={t('common.cancel')} danger onConfirm={() => { if (pending) void updateModule(pending.module, { enabled: false }, t('extensions.updated')); setPending(null) }} />
      <ConfirmDialog open={pending?.kind === 'delete'} onOpenChange={(open) => { if (!open) setPending(null) }} title={t('extensions.deleteTitle', { name: pending?.module.name ?? '' })} description={t('extensions.deleteBody')} confirmLabel={t('extensions.delete')} cancelLabel={t('common.cancel')} danger onConfirm={() => { if (pending) void deleteModule(pending.module); setPending(null) }} />
    </div>
  )
}
