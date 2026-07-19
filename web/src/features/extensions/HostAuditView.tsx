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
}

interface HostGroup {
  module: InterceptModule
  entries: HostEntry[]
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

  const activeHosts = useMemo(() => new Set(view.active_hosts ?? []), [view.active_hosts])
  const declarations = useMemo(() => {
    const owners = new Map<string, number>()
    for (const module of view.modules) {
      for (const host of module.hosts) owners.set(host, (owners.get(host) ?? 0) + 1)
    }
    return owners
  }, [view.modules])

  const groups = useMemo<HostGroup[]>(() => {
    const needle = query.trim().toLocaleLowerCase()
    return view.modules.flatMap((module) => {
      if (moduleID && module.id !== moduleID) return []
      const moduleMatch = `${module.name} ${module.source_url ?? ''} ${module.source_digest}`.toLocaleLowerCase().includes(needle)
      const entries = module.hosts
        .map((host) => ({
          host,
          active: activeHosts.has(host),
          wildcard: host.startsWith('*.'),
          duplicate: (declarations.get(host) ?? 0) > 1,
        }))
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
    }).sort((left, right) => Number(right.module.ready) - Number(left.module.ready) || left.module.name.localeCompare(right.module.name))
  }, [activeHosts, declarations, filter, moduleID, query, view.modules])

  const declaredCount = view.modules.reduce((count, module) => count + module.hosts.length, 0)
  const wildcardCount = view.modules.reduce((count, module) => count + module.hosts.filter((host) => host.startsWith('*.')).length, 0)

  return (
    <div className="flex flex-col gap-4" data-testid="host-audit-view">
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          [t('extensions.hostAudit.declared'), declaredCount],
          [t('extensions.hostAudit.active'), activeHosts.size],
          [t('extensions.hostAudit.wildcards'), wildcardCount],
          [t('extensions.hostAudit.extensions'), view.modules.filter((module) => module.hosts.length > 0).length],
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
                  <div className="truncate text-[13px] font-medium text-text-strong">{module.id === 'builtin-wloc' ? t('settings.wlocTitle') : module.name}</div>
                  <div className="mt-0.5 truncate font-mono text-[9.5px] text-text-faint">{module.snapshot_digest}</div>
                </div>
                <div className="flex flex-wrap items-center gap-1.5">
                  <Badge tone={module.ready ? 'green' : module.enabled ? 'amber' : 'neutral'}>
                    {module.ready ? t('extensions.enabled') : module.enabled ? t('extensions.configured') : t('extensions.disabled')}
                  </Badge>
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
