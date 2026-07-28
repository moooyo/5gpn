import { useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import {
  AddIcon,
  ArrowDownIcon,
  ArrowUpIcon,
  ChevronDownIcon,
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
  SectionLabel,
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
import { useMediaQuery } from '../../lib/useMediaQuery'
import { useMITMTrustAcknowledgement } from '../../lib/mitmTrust'
import { HostAuditView } from './HostAuditView'
import { ExtensionInstallReview } from './ExtensionInstallReview'
import { RoutingRuleList } from './routing-rules'

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

/**
 * The one status the operator has to act on, if any.
 *
 * A card could carry up to thirteen badges, with "egress group missing" —
 * which stops the extension working at all — the same shape, size and row as
 * "persistent storage", a neutral fact about what it can do. Capability and
 * problem are different kinds of thing: capabilities stay as neutral chips
 * below, and the highest-priority problem becomes one banner with the action
 * that resolves it.
 */
type ExtensionStatusTone = 'error' | 'warning' | 'neutral'

interface ExtensionStatus {
  tone: ExtensionStatusTone
  key: string
  /** Route that fixes it, when there is one. */
  to?: string
  actionKey?: string
}

function statusOf(module: InterceptModule, options: { trusted: boolean; groupMissing: boolean }): ExtensionStatus | null {
  // Ordered by how badly the extension is broken, not by where the flag lives.
  if (options.groupMissing) {
    return { tone: 'error', key: 'extensions.statusEgressMissing', to: '/settings', actionKey: 'extensions.statusGoSettings' }
  }
  if (module.reason === 'settings-required') {
    return { tone: 'warning', key: 'extensions.statusSettingsRequired' }
  }
  if (module.enabled && module.reason === 'mitm-disabled') {
    return { tone: 'warning', key: 'extensions.statusMasterOff', to: '/settings', actionKey: 'extensions.statusGoSettings' }
  }
  if (module.enabled && !options.trusted) {
    return { tone: 'warning', key: 'extensions.statusTrustPending', to: '/setup-guide', actionKey: 'extensions.statusGoSetup' }
  }
  if (!module.enabled) return { tone: 'neutral', key: 'extensions.statusDisabled' }
  return null
}

const STATUS_TONE: Record<ExtensionStatusTone, string> = {
  error: 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]',
  warning: 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
  neutral: 'bg-surface-container text-text-soft',
}

/**
 * Neutral by construction: these say what the extension can do, and a colour
 * here would compete with the banner above for "something needs you".
 *
 * Kept local rather than shared with the marketplace's MetaChip. The two pages
 * describe the same object at two lifecycle stages, so one shared card is the
 * obvious next move — it was designed and rejected on evidence:
 *
 *   - The overlapping fields do not mean the same thing. `capture_dns` and a
 *     bound `egress_group` exist only after install and have no counterpart on
 *     MarketplaceEntryCapabilities, so a normalized model invites a default
 *     that makes a catalog entry assert a resolver group or an egress binding
 *     nobody has chosen. `manifest_digest` and `snapshot_digest` hash
 *     different bytes; equating them pre-empts the verification the install
 *     flow performs server-side.
 *   - `upstream_mapping_count` DOES exist on both, and the marketplace card
 *     deliberately renders it nowhere. A shared chip row lights it up with no
 *     fabrication and no type error, silently reversing the editorial rule
 *     that a card carries only what decides an install.
 *   - The difference between the two is disclosure DEPTH, not data: network
 *     origins, persistent storage, routing rules and settings are chips here
 *     and a collapsed count there. Normalizing flattens that on purpose.
 *
 * What the two pages genuinely share is the card LANGUAGE — status banner over
 * neutral capability chips, and one routing-rule renderer (`RoutingRuleList`)
 * — and that is already shared. See docs/architecture.md.
 */
/** How many capability chips a card shows below `md`. Seven chips at 390px
 *  wrap into three rows and push the card's own actions off the screen. */
const CHIP_CAP = 4

/**
 * One reviewable fact inside an extension dialog.
 *
 * Flat and divided rather than a stack of tonal cards. When every block in a
 * dialog carries the same fill, "the snapshot digest changed" and "this script
 * can send everything it sees to three origins" are drawn identically — and
 * these dialogs are the one place an operator is asked to tell those apart
 * before confirming. A tonal fill survives only where the tone itself carries
 * meaning: a warning, or the candidate side of a diff.
 */
function DialogSection({ label, children, className, ...rest }: {
  label?: ReactNode
  children: ReactNode
  className?: string
} & Omit<React.HTMLAttributes<HTMLElement>, 'children'>) {
  return (
    <section className={cn('border-b border-divider pb-4 last:border-b-0 last:pb-0', className)} {...rest}>
      {label !== undefined ? <SectionLabel className="mb-2">{label}</SectionLabel> : null}
      {children}
    </section>
  )
}

function CapabilityChip({ label, value, icon }: { label: string; value?: string | number; icon?: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-chip bg-surface-container px-2 py-0.5 text-meta text-text-soft">
      {icon}
      {label}
      {value !== undefined ? <b className="font-mono font-semibold text-text-mid">{value}</b> : null}
    </span>
  )
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
  const status = statusOf(module, { trusted, groupMissing })
  // Matches the breakpoint every page in this console branches its mobile
  // layout on. Tailwind's `sm` is 640px and would cap the row while the card is
  // still rendering its wide form.
  const isNarrow = useMediaQuery('(max-width: 767px)')

  // Built as a list so the narrow cap is a slice rather than seven separate
  // conditional renders that each have to know their own position.
  const capabilities: Array<{ key: string; node: ReactNode }> = [
    {
      key: 'capture',
      node: (
        <button
          key="capture"
          type="button"
          aria-label={t('extensions.auditHosts')}
          onClick={() => onAudit(module)}
          className="zds-state-layer inline-flex items-center gap-1 h-field rounded-chip bg-surface-container px-2 text-meta font-medium text-text-soft md:h-auto md:py-0.5"
        >
          <ShieldLockIcon className="h-3.5 w-3.5" aria-hidden="true" /> {t('extensions.captureCount', { count: module.capture_hosts.length })}
        </button>
      ),
    },
    ...(module.script_count > 0 ? [{ key: 'actions', node: <CapabilityChip key="actions" label={t('extensions.chipActions')} value={module.script_count} /> }] : []),
    ...(module.network_any ? [{ key: 'network', node: <CapabilityChip key="network" icon={<NetworkIcon className="h-3.5 w-3.5" aria-hidden="true" />} label={t('extensions.chipNetwork')} value={t('extensions.networkAnyChip')} /> }] : module.network_origins.length > 0 ? [{ key: 'network', node: <CapabilityChip key="network" icon={<NetworkIcon className="h-3.5 w-3.5" aria-hidden="true" />} label={t('extensions.chipNetwork')} value={module.network_origins.length} /> }] : []),
    { key: 'captureDns', node: <CapabilityChip key="captureDns" icon={<RouteIcon className="h-3.5 w-3.5" aria-hidden="true" />} label={t('extensions.chipCaptureDNS')} value={t(`extensions.captureDNS.${module.capture_dns}`)} /> },
    ...(module.egress_group ? [{ key: 'egress', node: <CapabilityChip key="egress" icon={<RouteIcon className="h-3.5 w-3.5" aria-hidden="true" />} label={t('extensions.chipEgress')} value={module.egress_group} /> }] : []),
    ...(mappingsCount > 0 ? [{ key: 'mappings', node: <CapabilityChip key="mappings" label={t('extensions.chipHostMappings')} value={mappingsCount} /> }] : []),
    ...(module.persistent_storage ? [{ key: 'storage', node: <CapabilityChip key="storage" label={t('extensions.capabilityStorage')} /> }] : []),
  ]

  return (
    <Card className="min-w-0 overflow-hidden border-0 shadow-[var(--md-sys-elevation-1)]" data-testid={`extension-${module.id}`}>
      <CardBody className="flex h-full min-h-[210px] flex-col gap-3 p-4.5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className={cn(
              'grid h-11 w-11 shrink-0 place-items-center rounded-ctl',
              module.enabled ? 'bg-primary-container text-on-primary-container' : 'bg-surface-container text-text-faint',
            )}>
              <ExtensionFilledIcon className="h-5 w-5" aria-hidden="true" />
            </span>
            <div className="min-w-0">
              <h2 className="truncate text-title font-medium leading-tight text-text-strong">{module.name}</h2>
              <p className="mt-1 truncate text-meta text-text-faint">
                {module.id} · v{module.extension_version}{imported ? ` · ${imported}` : ''}
              </p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <span className="rounded-pill bg-surface-container-low px-2 py-1 font-mono text-meta text-text-faint" aria-label={t('extensions.executionOrder', { order: module.execution_order })}>{String(module.execution_order).padStart(2, '0')}</span>
            <Toggle checked={module.enabled} onCheckedChange={() => onToggle(module)} disabled={toggleDisabled} aria-label={`${module.enabled ? t('extensions.toggleOff') : t('extensions.toggleOn')} · ${module.name}`} />
          </div>
        </div>

        {/* One banner, highest priority only, with the action that resolves it. */}
        {status ? (
          <div
            role={status.tone === 'error' ? 'alert' : 'status'}
            data-testid={`extension-status-${module.id}`}
            className={cn('flex flex-wrap items-center gap-2 rounded-ctl px-3 py-2 text-meta font-medium', STATUS_TONE[status.tone])}
          >
            {status.tone === 'error' ? <WarningIcon className="h-4 w-4 shrink-0" aria-hidden="true" /> : null}
            <span className="min-w-0 flex-1">{t(status.key, { group: module.egress_group })}</span>
            {status.to && status.actionKey ? (
              <Link to={status.to} className="zds-state-layer inline-flex h-field shrink-0 items-center rounded-pill px-2.5 font-semibold underline-offset-2 hover:underline md:h-auto md:py-1">
                {t(status.actionKey)}
              </Link>
            ) : null}
          </div>
        ) : null}

        {module.description ? <p className="line-clamp-2 min-h-10 text-label leading-5 text-text-soft">{module.description}</p> : <div className="min-h-10" />}

        {/* Capabilities: one neutral shape, numbers carried in monospace. The
            capture-host chip is a button because it opens the host audit, but
            it is toned like the rest — it is an inventory item, and painting
            one entry in primary made the row say "this one matters more" about
            a capability that is simply the first in the list.
            Below md the row is capped at four and the remainder becomes a
            count that opens the detail, because seven chips at 390px wrap into
            three rows and push the card's actions off a phone screen. */}
        <div className="flex flex-wrap items-center gap-1.5" data-testid={`capabilities-${module.id}`}>
          {(isNarrow ? capabilities.slice(0, CHIP_CAP) : capabilities).map((chip) => chip.node)}
          {isNarrow && capabilities.length > CHIP_CAP ? (
            <button
              type="button"
              onClick={() => onInspect(module)}
              className="zds-state-layer inline-flex items-center gap-1 h-field rounded-chip bg-surface-container px-2 text-meta font-medium text-text-soft md:h-auto md:py-0.5"
            >
              {t('extensions.capabilityMore', { count: capabilities.length - CHIP_CAP })}
            </button>
          ) : null}
        </div>

        {/* Neutral, and only as wide as it needs to be. This was a full-width
            bar in the SAME warning amber as the status banner above it, with
            85% of its width empty — so a card could show two identical alarm
            bars, one of which is a neutral disclosure. Amber has to keep
            meaning "this needs you". The rules themselves carry their own
            REJECT/DIRECT colour once opened. */}
        {routingRuleCount > 0 ? <details className="group self-start rounded-ctl bg-surface-container text-text-mid" data-testid={`routing-rules-${module.id}`}>
          <summary className="zds-state-layer flex cursor-pointer list-none items-center gap-1.5 rounded-ctl px-3 py-2 text-meta font-semibold marker:hidden">
            <RouteIcon className="h-3.5 w-3.5" aria-hidden="true" />
            {t('extensions.routingRulesInspect', { count: routingRuleCount })}
            <ChevronDownIcon className="h-3.5 w-3.5 transition-transform group-open:rotate-180" aria-hidden="true" />
          </summary>
          <div className="max-h-40 overflow-y-auto border-t border-divider px-3 py-2.5">
            <RoutingRuleList rules={module.routing_rules!} />
          </div>
        </details> : null}

        <div className="mt-auto flex min-w-0 flex-wrap items-center gap-1 border-t border-divider pt-3">
          <div className="flex shrink-0 items-center gap-0.5">
            <Button type="button" variant="ghost" size="sm" className="w-field px-0 md:w-chip" aria-label={t('extensions.moveUp', { name: module.name })} title={t('extensions.moveUp', { name: module.name })} disabled={!reorderEnabled || module.execution_order <= 1 || busy} onClick={() => onMove(module, -1)}><ArrowUpIcon className="h-4 w-4" /></Button>
            <Button type="button" variant="ghost" size="sm" className="w-field px-0 md:w-chip" aria-label={t('extensions.moveDown', { name: module.name })} title={t('extensions.moveDown', { name: module.name })} disabled={!reorderEnabled || module.execution_order >= total || busy} onClick={() => onMove(module, 1)}><ArrowDownIcon className="h-4 w-4" /></Button>
          </div>
          <span className="order-first flex min-w-0 basis-full items-center gap-1.5 pb-1 text-meta text-text-faint sm:order-none sm:basis-auto sm:pb-0 sm:flex-1">
            {module.source_url ? <CloudIcon className="h-4 w-4 shrink-0" aria-hidden="true" /> : <FileIcon className="h-4 w-4 shrink-0" aria-hidden="true" />}
            <span className="max-w-[180px] truncate sm:max-w-[260px]">{sourceLabel}</span>
            <code className="shrink-0 font-mono text-meta text-text-faint" title={module.snapshot_digest}>· {module.snapshot_digest.slice(0, 8)}</code>
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
        <div className="space-y-4">
          <DialogSection label={t('extensions.captureDNS.title')} data-testid="capture-dns-editor">
            <p className="text-meta leading-4 text-text-faint">{t('extensions.captureDNS.hint')}</p>
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
            <p className="mt-3 text-meta leading-4 text-text-soft">{t(`extensions.captureDNS.${captureDNS}Hint`)}</p>
          </DialogSection>
          <DialogSection label={t('extensions.egressGroupTitle')}>
            <p className="text-meta leading-4 text-text-faint">{t('extensions.egressGroupHint')}</p>
            {((module.egress_group_required && !module.egress_group) || (!!module.egress_group && !egressGroups.includes(module.egress_group))) ? <p role="alert" className="mt-3 text-label font-medium text-[var(--md-sys-color-error)]">{t('extensions.egressGroupMissingDetail', { group: module.egress_group || t('extensions.egressGroupUnset') })}</p> : null}
            <Select value={egressGroup} onValueChange={setEgressGroup} items={[{ value: DEFAULT_EGRESS_GROUP, label: t('extensions.egressGroupDefault') }, ...egressGroups.map((group) => ({ value: group, label: group }))]} placeholder={t('extensions.selectEgressGroup')} className="mt-3 w-full" />
          </DialogSection>
          {(module.settings ?? []).map((setting) => {
            const label = setting.label || setting.key
            const description = setting.description
            if (setting.type === 'location') {
              const location = asLocation(values[setting.key])
              return (
                <DialogSection key={setting.key} className="space-y-3">
                  <div>
                    <div className="text-body font-medium text-text-strong">{label}{setting.required ? ' *' : ''}</div>
                    {description ? <p className="mt-1 text-meta leading-4 text-text-faint">{description}</p> : null}
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
                </DialogSection>
              )
            }
            if (setting.type === 'boolean') {
              return (
                <DialogSection key={setting.key} className="flex items-start justify-between gap-4">
                  <div>
                    <div className="text-label font-medium text-text-strong">{label}</div>
                    {description ? <p className="mt-1 text-meta leading-4 text-text-faint">{description}</p> : null}
                  </div>
                  <Toggle checked={values[setting.key] === true} onCheckedChange={(checked) => setValues((current) => ({ ...current, [setting.key]: checked }))} aria-label={label} />
                </DialogSection>
              )
            }
            return (
              <DialogSection key={setting.key}>
                <Field label={`${label}${setting.required ? ' *' : ''}`}>
                {setting.type === 'select' ? (
                  <select aria-label={label} className="w-full rounded-ctl border border-input-border bg-input px-3 py-2.5 text-label text-text-strong outline-none" value={String(values[setting.key] ?? '')} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: event.target.value }))}>
                    <option value="">{t('extensions.selectSetting')}</option>
                    {(setting.options ?? []).map((option) => <option key={option} value={option}>{option}</option>)}
                  </select>
                ) : (
                  <Input aria-label={label} type={setting.type === 'number' ? 'number' : 'text'} min={setting.min} max={setting.max} value={String(values[setting.key] ?? '')} onChange={(event) => setValues((current) => ({ ...current, [setting.key]: setting.type === 'number' ? (event.target.value === '' ? undefined : Number(event.target.value)) : event.target.value }))} />
                )}
                {description ? <p className="mt-1 text-meta leading-4 text-text-faint">{description}</p> : null}
                </Field>
              </DialogSection>
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
          {review.current.enabled ? <div role="alert" className="rounded-ctl bg-[var(--md-sys-color-warning-container)] px-3.5 py-3 text-label text-[var(--md-sys-color-on-warning-container)]">{t('extensions.disableBeforeUpdate')}</div> : null}
          {/* The two sides of the diff keep their fills: that contrast IS the
              information. Everything below is divided instead. */}
          <DialogSection>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="rounded-card bg-surface-container-low p-4">
                <div className="text-meta font-medium text-text-faint">{t('extensions.currentSnapshot')} · v{review.current.extension_version}</div>
                <code className="mt-2 block break-all font-mono text-meta text-text-mid">{review.current.snapshot_digest}</code>
              </div>
              <div className="rounded-card bg-primary-container p-4 text-on-primary-container">
                <div className="text-meta font-medium opacity-70">{t('extensions.candidateSnapshot')} · v{review.candidate.extension_version}</div>
                <code className="mt-2 block break-all font-mono text-meta">{review.candidate.snapshot_digest}</code>
              </div>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <Badge tone="blue">{t('extensions.captureCount', { count: review.candidate.capture_hosts.length })}</Badge>
              <Badge tone="amber">{t('extensions.capabilityAction', { count: review.candidate.script_count })}</Badge>
              {review.candidate.actions?.some((action) => action.entry === 'proxy-compat') ? <Badge tone="amber">{t('extensions.proxyCompatTitle')}</Badge> : null}
              {(review.candidate.routing_rules?.length ?? 0) > 0 ? <Badge tone="amber">{t('extensions.capabilityRouting', { count: review.candidate.routing_rules!.length })}</Badge> : null}
              {review.candidate.network_any ? <Badge tone="amber">{t('extensions.networkAnyTitle')}</Badge> : review.candidate.network_origins.length > 0 ? <Badge tone="indigo">{t('extensions.capabilityNetwork', { count: review.candidate.network_origins.length })}</Badge> : null}
              {review.candidate.egress_group_required ? <Badge tone="cyan">{t('extensions.egressGroupTitle')}</Badge> : null}
              {(review.candidate.settings?.length ?? 0) > 0 ? <Badge tone="indigo">{t('extensions.settingsAction', { count: review.candidate.settings?.length ?? 0 })}</Badge> : null}
            </div>
          </DialogSection>
          <DialogSection data-testid="update-capture-dns">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <SectionLabel>{t('extensions.captureDNS.title')}</SectionLabel>
              <Badge tone={review.candidate.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${review.candidate.capture_dns}`)}</Badge>
            </div>
            <p className="mt-1.5 text-meta leading-4 text-text-soft">{t(`extensions.captureDNS.${review.candidate.capture_dns}Hint`)}</p>
          </DialogSection>
          <DialogSection label={t('extensions.captureHosts')}>
            <div className="flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-ctl bg-surface-container-low p-3">
              {review.candidate.capture_hosts.map((host) => <code key={host} className="rounded-chip bg-card px-2 py-1 font-mono text-meta text-text-mid">{host}</code>)}
            </div>
          </DialogSection>
          {review.candidate.network_any ? <DialogSection label={t('extensions.networkAnyTitle')}>
            <p className="rounded-ctl bg-[var(--md-sys-color-warning-container)] p-3 text-label leading-5 text-[var(--md-sys-color-on-warning-container)]">{t('extensions.networkAnyWarning')}</p>
          </DialogSection> : review.candidate.network_origins.length > 0 ? <DialogSection label={t('extensions.networkOriginsTitle')}>
            <div className="flex max-h-36 flex-wrap gap-1.5 overflow-y-auto rounded-ctl bg-[var(--md-sys-color-warning-container)] p-3 text-[var(--md-sys-color-on-warning-container)]">
              {review.candidate.network_origins.map((origin) => <code key={origin} title={origin} className="inline-block min-w-0 max-w-full break-all rounded-chip bg-[var(--md-sys-color-tint-inset)] px-2 py-1 font-mono text-meta">{origin}</code>)}
            </div>
          </DialogSection> : null}
          {(review.candidate.routing_rules?.length ?? 0) > 0 ? <DialogSection label={t('extensions.routingRulesTitle')}>
            <div className="max-h-40 overflow-y-auto rounded-ctl bg-[var(--md-sys-color-warning-container)] p-3 text-[var(--md-sys-color-on-warning-container)]">
              <RoutingRuleList rules={review.candidate.routing_rules!} />
            </div>
          </DialogSection> : null}
          <p className="text-meta leading-5 text-text-faint">{t('extensions.updateSafety')}</p>
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
        <p className="text-body leading-6 text-text-soft">{t('extensions.enableBody')}</p>
        {/* The two warning blocks keep their fill: "this can send everything it
            sees to these origins" and "this rewrites global routing" are the
            two facts this confirmation exists for. The neutral facts around
            them are divided instead of tinted, so the amber still means
            something when it appears. */}
        <DialogSection data-testid="enable-capture-dns">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <SectionLabel>{t('extensions.captureDNS.title')}</SectionLabel>
            <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge>
          </div>
          <p className="mt-1.5 text-meta leading-4 text-text-soft">{t(`extensions.captureDNS.${module.capture_dns}Hint`)}</p>
        </DialogSection>
        {module.network_any ? <section className="rounded-card bg-[var(--md-sys-color-warning-container)] p-4 text-label leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <div className="font-semibold">{t('extensions.networkAnyTitle')}</div>
          <p className="mt-1">{t('extensions.networkAnyWarning')}</p>
        </section> : module.network_origins.length > 0 ? <section className="rounded-card bg-[var(--md-sys-color-warning-container)] p-4 text-label leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <div className="font-semibold">{t('extensions.networkOriginsTitle')}</div>
          <p className="mt-1">{t('extensions.networkOriginsWarning')}</p>
          <div className="mt-3 flex max-h-32 flex-wrap gap-1.5 overflow-y-auto">
            {module.network_origins.map((origin) => <code key={origin} title={origin} className="inline-block min-w-0 max-w-full break-all rounded-chip bg-[var(--md-sys-color-tint-inset)] px-2 py-1 font-mono text-meta">{origin}</code>)}
          </div>
        </section> : <DialogSection label={t('extensions.networkOriginsTitle')}><p className="text-label text-text-soft">{t('extensions.networkOriginsNone')}</p></DialogSection>}
        {module.egress_group_required || module.egress_group ? <DialogSection label={t('extensions.egressGroupTitle')}><code className="block font-mono text-label text-text-strong">{module.egress_group || t('extensions.egressGroupUnset')}</code></DialogSection> : null}
        {(module.routing_rules?.length ?? 0) > 0 ? <section className="rounded-card bg-[var(--md-sys-color-warning-container)] p-4 text-label leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <div className="font-semibold">{t('extensions.routingRulesTitle')}</div>
          <p className="mt-1">{t('extensions.routingRulesWarning')}</p>
          <div className="mt-3 max-h-40 overflow-y-auto">
            <RoutingRuleList rules={module.routing_rules!} />
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
            <li key={id} className="flex min-w-0 flex-wrap items-center gap-2 rounded-chip bg-card px-2.5 py-2">
              <span className="grid h-5 w-5 shrink-0 place-items-center rounded-pill bg-surface-container text-meta font-semibold text-text-faint">{index + 1}</span>
              <span className="min-w-0 flex-1 truncate text-label font-medium text-text-strong">{module?.name ?? id}</span>
              {module ? <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge> : null}
              <code className="max-w-[42%] truncate font-mono text-meta text-text-faint" title={id}>{id}</code>
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
        <p className="text-body leading-6 text-text-soft">{t('extensions.reorderConfirmBody')}</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <section className="min-w-0 rounded-card bg-surface-container-low p-3">
            <h3 className="mb-2 text-label font-semibold text-text-faint">{t('extensions.reorderBefore')}</h3>
            {renderOrder(action.beforeOrder, 'extension-reorder-before')}
          </section>
          <section className="min-w-0 rounded-card bg-primary-container p-3">
            <h3 className="mb-2 text-label font-semibold text-on-primary-container">{t('extensions.reorderAfter')}</h3>
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
      {loading ? <div className="py-8 text-center text-label text-text-faint">{t('common.loading')}</div> : null}
      {!loading && snapshot ? (
        <div className="max-h-[68vh] space-y-4 overflow-y-auto pr-1">
          <section>
            <div className="mb-1.5 flex items-center justify-between gap-3 text-meta text-text-faint"><span className="font-bold uppercase tracking-[.08em]">{t('extensions.snapshotSource')}</span><code className="max-w-[70%] truncate" title={snapshot.source_digest}>{snapshot.source_digest}</code></div>
            <pre className="max-h-[280px] overflow-auto whitespace-pre-wrap break-words rounded-card bg-surface-container-low p-4 font-mono text-meta leading-relaxed text-text-mid">{snapshot.source_body}</pre>
          </section>
          {snapshot.scripts.map((script) => (
            <details key={script.id} className="rounded-card bg-surface-container-low px-4 py-3">
              <summary className="cursor-pointer text-label font-bold text-text-strong">{t('extensions.snapshotScript', { id: script.id })}<code className="ml-2 font-normal text-text-faint">{script.digest.slice(0, 12)}…</code></summary>
              {script.url ? <div className="mt-2 break-all text-meta text-primary">{script.url}</div> : null}
              <pre className="mt-2 max-h-[320px] overflow-auto whitespace-pre-wrap break-words rounded-ctl bg-card p-3 font-mono text-meta leading-relaxed text-text-mid">{script.body}</pre>
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
          <div className="flex items-start gap-2.5 rounded-card bg-surface-container-low px-4 py-3" data-testid="extension-install-url-info"><FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" /><p className="text-label leading-relaxed text-text-soft">{t('extensions.install.urlInfo')}</p></div>
        </div>
      ) : (
        <div className="space-y-4">
          <Field label={t('extensions.install.content')}>
            <textarea className="min-h-[240px] resize-y rounded-card border border-input-border bg-input px-4 py-3 font-mono text-label leading-5 text-text-strong outline-none focus:border-primary focus:bg-card" aria-label={t('extensions.install.content')} value={content} maxLength={2097152} placeholder={t('extensions.install.contentPlaceholder')} onChange={(event) => setContent(event.target.value)} />
            <label className="zds-state-layer mt-2 inline-flex cursor-pointer items-center gap-2 rounded-pill px-3 py-2 text-label font-medium text-primary"><UploadIcon className="h-4 w-4" /> {t('extensions.install.upload')}<input className="sr-only" type="file" accept=".yaml,.yml,.json,text/yaml,application/yaml,text/plain" onChange={(event) => void chooseFile(event)} /></label>
          </Field>
          <div className="flex items-start gap-2.5 rounded-card bg-surface-container-low px-4 py-3" data-testid="extension-install-local-info"><FileSearchIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" /><p className="text-label leading-relaxed text-text-soft">{t('extensions.install.localInfo')}</p></div>
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
  // The marketplace links here with `?update=<id>` when a source has moved
  // past the installed version. Replacing a snapshot is a reviewed action, so
  // the link opens this page's existing confirmation rather than carrying a
  // second copy of it.
  const requestedUpdateID = new URLSearchParams(location.search).get('update') ?? undefined
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

  const updateRequestHandled = useRef(false)
  useEffect(() => {
    if (!requestedUpdateID || !view || updateRequestHandled.current) return
    updateRequestHandled.current = true
    const target = view.modules.find((module) => module.id === requestedUpdateID)
    navigate('/extensions', { replace: true })
    if (target) void checkExtensionUpdate(target)
    else toast.error(t('extensions.updateTargetMissing', { id: requestedUpdateID }))
    // checkExtensionUpdate is a stable page-scoped function; re-running this
    // on every render would re-open the dialog the operator just dismissed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [requestedUpdateID, view])

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
    <div className="flex flex-col gap-3 md:gap-4" data-testid="page-extensions">
      <div className={cn('flex flex-col gap-3 rounded-card px-5 py-4 sm:flex-row sm:items-center sm:justify-between', trustState === 'ready' ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : trustState === 'master' ? 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]' : 'bg-primary-container text-on-primary-container')} data-testid="mitm-readiness-notice">
        <div className="flex items-start gap-2.5">{trustState === 'ready' ? <VerifiedIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" /> : <ShieldLockIcon className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />}<div><div className="text-body font-semibold">{t(`extensions.readiness.${trustState}.title`)}</div><p className="mt-0.5 text-label leading-relaxed opacity-80">{t(`extensions.readiness.${trustState}.body`, { count: activeCount })}</p></div></div>
        <Link className={cn('zds-state-layer inline-flex h-field shrink-0 items-center justify-center gap-1.5 rounded-pill px-5 text-label font-medium md:h-ctl', trustState === 'ready' ? 'bg-[var(--md-sys-color-tint-inset)]' : 'bg-primary text-[var(--md-sys-color-on-primary)]')} to={trustState === 'master' ? '/settings' : '/setup-guide'}>{trustState !== 'ready' ? <LinkIcon className="h-4 w-4" aria-hidden="true" /> : null}{t(`extensions.readiness.${trustState}.action`)}</Link>
      </div>

      {loading && !view ? <Card><CardBody className="text-center text-label text-text-faint">{t('common.loading')}</CardBody></Card> : null}
      {loadError && !view ? <Card><CardBody className="flex items-center justify-between gap-3"><span className="text-label text-red">{t('extensions.loadFailed')}</span><Button variant="secondary" size="sm" onClick={() => void load()}><RefreshIcon className="h-4 w-4" />{t('extensions.retry')}</Button></CardBody></Card> : null}

      {!showingHosts && view ? <>
        <div className="flex flex-col gap-3 px-1 lg:flex-row lg:items-center">
          <p className="min-w-[240px] flex-1 text-body leading-5 text-text-faint">{t('extensions.catalogSummary', { total: view.modules.length, enabled: activeCount })}{' '}<button type="button" className="zds-state-layer rounded-pill px-2 py-1 font-medium text-primary" onClick={() => void navigate('/extensions/hosts')}>{t('extensions.tabs.hosts', { count: hostCount })}</button></p>
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" variant="ghost" size="sm" className="w-9 px-0" aria-label={t('extensions.refresh')} title={t('extensions.refresh')} onClick={() => void load()} disabled={loading}><RefreshIcon className="h-4 w-4" /></Button>
            <a href={view.catalog_url} target="_blank" rel="noreferrer" aria-label={t('extensions.catalog')} title={t('extensions.catalog')} className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-primary md:h-row md:w-row"><ExternalLinkIcon className="h-4 w-4" aria-hidden="true" /></a>
            <Button type="button" variant="tonal" size="sm" disabled={busyID !== null} onClick={() => setInstallMode('url')}><LinkIcon className="h-4 w-4" />{t('extensions.addUrl')}</Button>
            <Button type="button" size="sm" disabled={busyID !== null} onClick={() => setInstallMode('local')}><AddIcon className="h-4 w-4" />{t('extensions.addLocal')}</Button>
          </div>
        </div>
        <div className="flex flex-col gap-3 px-1 sm:flex-row sm:items-center">
          <SegmentedControl value={filter} onChange={(value) => setFilter(value as ExtensionFilter)} ariaLabel={t('extensions.filterLabel')} className="grid-cols-2 sm:grid-cols-4" options={([['all', t('extensions.filters.all')], ['enabled', t('extensions.filters.enabled')], ['capture', t('extensions.filters.capture')], ['local', t('extensions.filters.local')]] as Array<[ExtensionFilter, string]>).map(([value, label]) => ({ value, label }))} />
          <div className="relative min-w-0 sm:ml-auto sm:w-[300px] sm:flex-none"><SearchIcon className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" /><Input value={search} onChange={(event) => setSearch(event.target.value)} aria-label={t('extensions.search')} placeholder={t('extensions.searchPlaceholder')} className="pl-10" /></div>
        </div>
        {!reorderModeAvailable && view.modules.length > 1 ? <p role="status" data-testid="extension-order-hint" className="px-1 text-meta leading-4 text-text-faint">{t('extensions.orderUnavailableHint')}</p> : null}
        {visibleModules.length > 0 ? <div className="space-y-3" aria-busy={busyID !== null}>{visibleModules.map((module) => <ExtensionCard key={module.id} module={module} busy={busyID !== null} trusted={acknowledged} egressGroups={view.available_egress_groups} reorderEnabled={reorderModeAvailable} total={view.modules.length} onMove={requestModuleMove} onToggle={(selected) => setPending({ kind: 'toggle', module: selected })} onDelete={(selected) => setPending({ kind: 'delete', module: selected })} onInspect={(selected) => void inspectModule(selected)} onConfigure={setConfigTarget} onAudit={(selected) => void navigate(`/extensions/hosts?plugin=${encodeURIComponent(selected.id)}`)} onCheckUpdate={(selected) => void checkExtensionUpdate(selected)} />)}</div> : <Card className="p-10 text-center shadow-none"><div className="text-body font-medium text-text-strong">{t('extensions.noMatches')}</div><div className="mt-1 text-label text-text-faint">{t('extensions.noMatchesHint')}</div></Card>}
        </> : null}

      {showingHosts && view ? <><div className="flex items-center justify-between gap-3 px-1"><p className="text-body text-text-faint">{t('extensions.hostAudit.intro')}</p><Button type="button" variant="secondary" size="sm" onClick={() => void navigate('/extensions')}>{t('extensions.backToCatalog')}</Button></div><HostAuditView view={view} settings={settings} moduleID={scopedModuleID} onClearModule={() => void navigate('/extensions/hosts')} /></> : null}

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
