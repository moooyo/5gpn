import { useTranslation } from 'react-i18next'
import { Badge, SectionLabel } from '../../components/ds'
import { cn } from '../../lib/cn'
import { InterceptModule } from '../../lib/api/types'
import { RoutingRuleList } from './routing-rules'

/** One reviewable fact. Flat and divided rather than tonal blocks inside a
 *  tonal block: the identity header keeps its fill because it names what is
 *  being installed, and everything below is separated instead of tinted so a
 *  digest and a network origin are not drawn as the same kind of thing. */
function Row({ label, children, className, ...rest }: {
  label?: string
  children: React.ReactNode
  className?: string
} & Omit<React.HTMLAttributes<HTMLDivElement>, 'children'>) {
  return (
    <div className={cn('border-b border-divider pb-3 last:border-b-0 last:pb-0', className)} {...rest}>
      {label ? <SectionLabel className="mb-1.5">{label}</SectionLabel> : null}
      {children}
    </div>
  )
}

/** Displays only the module returned after the server has stored its snapshot. */
export function ExtensionInstallReview({ module }: { module: InterceptModule }) {
  const { t } = useTranslation()
  return (
    <div className="space-y-3" data-testid="extension-install-review">
      <div className="rounded-card bg-primary-container p-4 text-on-primary-container">
        <div className="text-title font-medium">{module.name} · v{module.extension_version}</div>
        <p className="mt-1 font-mono text-meta opacity-75">{module.id}</p>
      </div>
      <Row>
        <div className="grid gap-3 sm:grid-cols-3">
          <div><div className="text-meta text-text-faint">{t('extensions.captureHosts')}</div><div className="mt-1 font-mono text-headline text-text-strong">{module.capture_hosts.length}</div></div>
          <div><div className="text-meta text-text-faint">{t('extensions.actions')}</div><div className="mt-1 font-mono text-headline text-text-strong">{module.script_count}</div></div>
          <div><div className="text-meta text-text-faint">{t('extensions.settings')}</div><div className="mt-1 font-mono text-headline text-text-strong">{module.settings?.length ?? 0}</div></div>
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-1.5"><Badge tone="neutral">{t('extensions.disabled')}</Badge>{module.persistent_storage ? <Badge tone="indigo">{t('extensions.capabilityStorage')}</Badge> : null}{module.egress_group_required ? <Badge tone="cyan">{t('marketplace.egressRequired')}</Badge> : null}</div>
      </Row>
      <Row label={t('extensions.captureHosts')}>
        <div className="flex flex-wrap gap-1.5">{module.capture_hosts.map((host) => <code key={host} className="rounded-chip bg-surface-container-low px-2 py-1 font-mono text-meta text-text-mid">{host}</code>)}</div>
      </Row>
      <Row className="flex flex-wrap items-start justify-between gap-2" data-testid="install-capture-dns">
        <div><SectionLabel>{t('extensions.captureDNS.title')}</SectionLabel><p className="mt-1 text-meta leading-4 text-text-soft">{t(`extensions.captureDNS.${module.capture_dns}Hint`)}</p></div>
        <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge>
      </Row>
      <Row aria-label={t('extensions.install.snapshotDetails')}>
        <div className="grid gap-2 sm:grid-cols-2"><div><div className="text-meta text-text-faint">{t('extensions.install.sourceDigest')}</div><code className="mt-1 block break-all font-mono text-meta text-text-mid">{module.source_digest}</code></div><div><div className="text-meta text-text-faint">{t('extensions.install.snapshotDigest')}</div><code className="mt-1 block break-all font-mono text-meta text-text-mid">{module.snapshot_digest}</code></div></div>
      </Row>
      <Row label={module.network_any ? t('extensions.networkAnyTitle') : t('extensions.networkOriginsTitle')}>
        {module.network_any ? <p className="text-meta leading-4 text-[var(--md-sys-color-on-warning-container)]">{t('extensions.networkAnyWarning')}</p> : module.network_origins.length ? <div className="flex flex-wrap gap-1.5">{module.network_origins.map((origin) => <code key={origin} className="max-w-full break-all rounded-chip bg-surface-container-low px-2 py-1 font-mono text-meta text-text-mid">{origin}</code>)}</div> : <p className="text-meta text-text-faint">{t('extensions.networkOriginsNone')}</p>}
      </Row>
      {(module.routing_rules?.length ?? 0) > 0 ? <Row label={t('extensions.routingRulesTitle')}><RoutingRuleList rules={module.routing_rules!} /></Row> : null}
      <p className="text-label leading-5 text-text-faint">{t('extensions.install.reviewBody')}</p>
    </div>
  )
}
