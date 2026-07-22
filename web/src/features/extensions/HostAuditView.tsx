import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SearchIcon, ShieldLockIcon, WarningIcon } from '../../components/icons'
import { Badge, Button, Card, Input, SegmentedControl } from '../../components/ds'
import type { InterceptModule, InterceptModulesView, MITMSettingsView } from '../../lib/api/types'

type HostFilter = 'all' | 'active' | 'configured' | 'disabled' | 'wildcard'

interface HostEntry {
  host: string
  active: boolean
  wildcard: boolean
  duplicate: boolean
  overlap: boolean
  egressWinner?: InterceptModule
  egressShadowed: boolean
  dnsWinner?: InterceptModule
  dnsShadowed: boolean
  dnsPartialWinner?: InterceptModule
}

interface HostGroup {
  module: InterceptModule
  entries: HostEntry[]
}

function wildcardSuffix(pattern: string): string | null {
  const normalized = pattern.toLowerCase()
  return normalized.startsWith('*.') ? normalized.slice(2) : null
}

function patternMatchesHost(pattern: string, host: string): boolean {
  const normalizedPattern = pattern.toLowerCase()
  const normalizedHost = host.toLowerCase()
  const suffix = wildcardSuffix(normalizedPattern)
  return suffix === null
    ? normalizedPattern === normalizedHost
    : normalizedHost.length > suffix.length && normalizedHost.endsWith(`.${suffix}`)
}

function patternCovers(cover: string, target: string): boolean {
  const targetSuffix = wildcardSuffix(target)
  if (targetSuffix === null) return patternMatchesHost(cover, target)
  const coverSuffix = wildcardSuffix(cover)
  return coverSuffix !== null && (targetSuffix === coverSuffix || targetSuffix.endsWith(`.${coverSuffix}`))
}

function patternsOverlap(left: string, right: string): boolean {
  const leftSuffix = wildcardSuffix(left)
  const rightSuffix = wildcardSuffix(right)
  if (leftSuffix === null) return patternMatchesHost(right, left)
  if (rightSuffix === null) return patternMatchesHost(left, right)
  return leftSuffix === rightSuffix || leftSuffix.endsWith(`.${rightSuffix}`) || rightSuffix.endsWith(`.${leftSuffix}`)
}

export function HostAuditView({
  view,
  settings,
  moduleID,
  onClearModule,
}: {
  view: InterceptModulesView
  settings: MITMSettingsView | null
  moduleID?: string
  onClearModule: () => void
}) {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<HostFilter>('all')

  const activeHosts = useMemo(() => new Set(view.active_capture_hosts ?? []), [view.active_capture_hosts])
  const declarations = useMemo(() => {
    const owners = new Map<string, InterceptModule[]>()
    for (const module of view.modules) {
      for (const host of module.capture_hosts) owners.set(host, [...(owners.get(host) ?? []), module].sort((left, right) => left.execution_order - right.execution_order))
    }
    return owners
  }, [view.modules])

  const groups = useMemo<HostGroup[]>(() => {
    const needle = query.trim().toLocaleLowerCase()
    const orderedEnabled = [...view.modules].filter((candidate) => candidate.enabled).sort((left, right) => left.execution_order - right.execution_order)
    return view.modules.flatMap((module) => {
      if (moduleID && module.id !== moduleID) return []
      const moduleMatch = `${module.name} ${module.source_url ?? ''} ${module.source_digest}`.toLocaleLowerCase().includes(needle)
      const entries = module.capture_hosts
        .map((host) => {
          const egressWinner = declarations.get(host)?.find((owner) => owner.enabled && !!owner.egress_group)
          const overlappingModules = view.modules.filter((owner) => owner.id !== module.id && owner.capture_hosts.some((pattern) => patternsOverlap(pattern, host)))
          const dnsWinner = orderedEnabled.find((owner) => owner.capture_hosts.some((pattern) => patternCovers(pattern, host)))
          const dnsPartialWinner = dnsWinner?.id === module.id
            ? orderedEnabled.find((owner) => owner.execution_order < module.execution_order && owner.capture_hosts.some((pattern) => patternsOverlap(pattern, host) && !patternCovers(pattern, host)))
            : dnsWinner
              ? undefined
              : orderedEnabled.find((owner) => owner.capture_hosts.some((pattern) => patternsOverlap(pattern, host) && !patternCovers(pattern, host)))
          return {
            host,
            active: activeHosts.has(host),
            wildcard: host.startsWith('*.'),
            duplicate: (declarations.get(host) ?? []).length > 1,
            overlap: overlappingModules.length > 0,
            egressWinner,
            egressShadowed: !!egressWinner && egressWinner.id !== module.id,
            dnsWinner,
            dnsShadowed: !!dnsWinner && dnsWinner.id !== module.id,
            dnsPartialWinner,
          }
        })
        .filter((entry) => {
          if (needle && !moduleMatch && !entry.host.toLocaleLowerCase().includes(needle)) return false
          if (filter === 'active') return entry.active
          if (filter === 'configured') return module.enabled && !entry.active
          if (filter === 'disabled') return !module.enabled
          if (filter === 'wildcard') return entry.wildcard
          return true
        })
        .sort((left, right) => Number(right.active) - Number(left.active) || Number(left.wildcard) - Number(right.wildcard) || left.host.localeCompare(right.host))
      return entries.length > 0 ? [{ module, entries }] : []
    }).sort((left, right) => left.module.execution_order - right.module.execution_order)
  }, [activeHosts, declarations, filter, moduleID, query, view.modules])

  const declaredCount = view.modules.reduce((count, module) => count + module.capture_hosts.length, 0)
  const wildcardCount = view.modules.reduce((count, module) => count + module.capture_hosts.filter((host) => host.startsWith('*.')).length, 0)

  return (
    <div className="flex flex-col gap-4" data-testid="host-audit-view">
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          [t('extensions.hostAudit.declared'), declaredCount],
          [t('extensions.hostAudit.active'), activeHosts.size],
          [t('extensions.hostAudit.wildcards'), wildcardCount],
          [t('extensions.hostAudit.extensions'), view.modules.filter((module) => module.capture_hosts.length > 0).length],
        ].map(([label, value]) => (
          <Card key={String(label)} className="p-4 shadow-none">
            <div className="text-[10.5px] font-medium text-text-faint">{label}</div>
            <div className="mt-1 font-mono text-[25px] font-medium text-text-strong">{value}</div>
          </Card>
        ))}
      </div>

      <Card className="flex flex-col gap-3 p-4 shadow-none sm:flex-row sm:items-center">
        <div className="relative min-w-0 flex-1">
          <SearchIcon className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" />
          <Input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t('extensions.hostAudit.searchPlaceholder')}
            aria-label={t('extensions.hostAudit.search')}
            className="pl-10"
            data-testid="host-audit-search"
          />
        </div>
        <SegmentedControl
          value={filter}
          onChange={(value) => setFilter(value as HostFilter)}
          ariaLabel={t('extensions.hostAudit.filter')}
          className="grid-cols-3 sm:grid-cols-5"
          options={([
            ['all', t('extensions.filters.all')],
            ['active', t('extensions.hostAudit.active')],
            ['configured', t('extensions.hostAudit.configured')],
            ['disabled', t('extensions.disabled')],
            ['wildcard', t('extensions.hostAudit.wildcards')],
          ] as Array<[HostFilter, string]>).map(([value, label]) => ({ value, label }))}
        />
      </Card>

      {moduleID ? (
        <div className="flex items-center justify-between gap-3 rounded-[14px] bg-secondary-container px-4 py-3 text-[11.5px] text-on-secondary-container">
          <span>{t('extensions.hostAudit.scoped')}</span>
          <Button type="button" variant="secondary" size="sm" onClick={onClearModule}>{t('extensions.hostAudit.showAll')}</Button>
        </div>
      ) : null}

      {!settings?.enabled ? (
        <div className="flex items-start gap-2.5 rounded-[14px] bg-[var(--md-sys-color-warning-container)] px-4 py-3 text-[11px] leading-5 text-[var(--md-sys-color-on-warning-container)]">
          <WarningIcon className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          {t('extensions.hostAudit.masterOff')}
        </div>
      ) : null}

      {groups.length === 0 ? (
        <Card className="p-10 text-center shadow-none">
          <div className="text-[13px] font-medium text-text-strong">{t('extensions.hostAudit.empty')}</div>
          <div className="mt-1 text-[11.5px] text-text-faint">{t('extensions.hostAudit.emptyHint')}</div>
        </Card>
      ) : (
        <div className="space-y-3">
          {groups.map(({ module, entries }) => (
            <Card key={module.id} className="overflow-hidden p-0 shadow-none" data-testid={`host-group-${module.id}`}>
              <div className="flex flex-col gap-2 border-b border-divider px-4 py-3.5 sm:flex-row sm:items-center">
                <span className="grid h-9 w-9 shrink-0 place-items-center rounded-[10px] bg-primary-container text-on-primary-container">
                  <ShieldLockIcon className="h-4.5 w-4.5" aria-hidden="true" />
                </span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[13px] font-medium text-text-strong">{module.name}</div>
                  <div className="mt-0.5 truncate font-mono text-[9.5px] text-text-faint">{module.snapshot_digest}</div>
                </div>
                <div className="flex flex-wrap items-center gap-1.5">
                  <Badge tone={module.ready ? 'green' : module.enabled ? 'amber' : 'neutral'}>
                    {module.ready ? t('extensions.enabled') : module.enabled ? t('extensions.configured') : t('extensions.disabled')}
                  </Badge>
                  <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t('extensions.captureDNS.badge', { group: t(`extensions.captureDNS.${module.capture_dns}`) })}</Badge>
                  <Badge>{t('extensions.hostAudit.executionOrder', { order: module.execution_order })}</Badge>
                  <Badge>{t('extensions.hostAudit.hostCount', { count: entries.length })}</Badge>
                </div>
              </div>
              <div className="divide-y divide-divider">
                {entries.map((entry) => (
                  <div key={entry.host} className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center" data-host={entry.host}>
                    <code className="min-w-0 flex-1 break-all font-mono text-[12px] text-text-strong">{entry.host}</code>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <Badge tone={entry.wildcard ? 'indigo' : 'neutral'}>
                        {entry.wildcard ? t('extensions.hostAudit.wildcard') : t('extensions.hostAudit.exact')}
                      </Badge>
                      {entry.duplicate ? <Badge tone="amber">{t('extensions.hostAudit.duplicate')}</Badge> : null}
                      {entry.overlap && !entry.duplicate ? <Badge tone="amber">{t('extensions.hostAudit.overlap')}</Badge> : null}
                      {entry.duplicate ? <Badge tone="blue">{t('extensions.hostAudit.composed')}</Badge> : null}
                      {entry.dnsWinner?.id === module.id ? <Badge tone="green">{t('extensions.hostAudit.dnsWinner', { group: t(`extensions.captureDNS.${module.capture_dns}`) })}</Badge> : null}
                      {entry.dnsShadowed ? <Badge tone="amber">{t('extensions.hostAudit.dnsShadowed', { name: entry.dnsWinner?.name ?? '', group: entry.dnsWinner ? t(`extensions.captureDNS.${entry.dnsWinner.capture_dns}`) : '' })}</Badge> : null}
                      {entry.dnsPartialWinner ? <Badge tone="amber">{t('extensions.hostAudit.dnsPartiallyShadowed', { name: entry.dnsPartialWinner.name, group: t(`extensions.captureDNS.${entry.dnsPartialWinner.capture_dns}`) })}</Badge> : null}
                      {entry.egressWinner?.id === module.id ? <Badge tone="green">{t('extensions.hostAudit.egressWinner', { group: entry.egressWinner.egress_group })}</Badge> : null}
                      {entry.egressShadowed ? <Badge tone="amber">{t('extensions.hostAudit.egressShadowed', { name: entry.egressWinner?.name ?? '' })}</Badge> : null}
                      <Badge tone={entry.active ? 'green' : module.enabled ? 'amber' : 'neutral'}>
                        {entry.active ? t('extensions.hostAudit.running') : module.enabled ? t('extensions.hostAudit.notEffective') : t('extensions.disabled')}
                      </Badge>
                    </div>
                  </div>
                ))}
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
