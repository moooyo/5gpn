import { useTranslation } from 'react-i18next'
import { Badge } from '../../components/ds'
import { InterceptModule } from '../../lib/api/types'
import { RoutingRuleList } from './routing-rules'

/** Displays only the module returned after the server has stored its snapshot. */
export function ExtensionInstallReview({ module }: { module: InterceptModule }) {
  const { t } = useTranslation()
  return (
    <div className="space-y-4" data-testid="extension-install-review">
      <div className="rounded-card bg-primary-container p-4 text-on-primary-container">
        <div className="text-title font-medium">{module.name} · v{module.extension_version}</div>
        <p className="mt-1 font-mono text-meta opacity-75">{module.id}</p>
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-ctl bg-surface-container-low p-3"><div className="text-meta text-text-faint">{t('extensions.captureHosts')}</div><div className="mt-1 font-mono text-headline">{module.capture_hosts.length}</div></div>
        <div className="rounded-ctl bg-surface-container-low p-3"><div className="text-meta text-text-faint">{t('extensions.actions')}</div><div className="mt-1 font-mono text-headline">{module.script_count}</div></div>
        <div className="rounded-ctl bg-surface-container-low p-3"><div className="text-meta text-text-faint">{t('extensions.settings')}</div><div className="mt-1 font-mono text-headline">{module.settings?.length ?? 0}</div></div>
      </div>
      <div className="flex flex-wrap gap-1.5">{module.capture_hosts.map((host) => <code key={host} className="rounded-chip bg-surface-container-low px-2 py-1 font-mono text-meta">{host}</code>)}</div>
      <section className="space-y-2 rounded-card bg-surface-container-low p-3" aria-label={t('extensions.install.snapshotDetails')}>
        <div className="flex flex-wrap items-center gap-1.5"><Badge tone="neutral">{t('extensions.disabled')}</Badge>{module.persistent_storage ? <Badge tone="indigo">{t('extensions.capabilityStorage')}</Badge> : null}{module.egress_group_required ? <Badge tone="cyan">{t('marketplace.egressRequired')}</Badge> : null}</div>
        <div className="flex flex-wrap items-start justify-between gap-2 rounded-ctl bg-card p-2.5" data-testid="install-capture-dns">
          <div><div className="text-meta text-text-faint">{t('extensions.captureDNS.title')}</div><p className="mt-1 text-meta leading-4 text-text-soft">{t(`extensions.captureDNS.${module.capture_dns}Hint`)}</p></div>
          <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge>
        </div>
        <div className="grid gap-2 sm:grid-cols-2"><div><div className="text-meta text-text-faint">{t('extensions.install.sourceDigest')}</div><code className="mt-1 block break-all font-mono text-meta text-text-mid">{module.source_digest}</code></div><div><div className="text-meta text-text-faint">{t('extensions.install.snapshotDigest')}</div><code className="mt-1 block break-all font-mono text-meta text-text-mid">{module.snapshot_digest}</code></div></div>
        <div><div className="text-meta text-text-faint">{t('extensions.networkOriginsTitle')}</div>{module.network_origins.length ? <div className="mt-1 flex flex-wrap gap-1.5">{module.network_origins.map((origin) => <code key={origin} className="max-w-full break-all rounded-chip bg-card px-2 py-1 font-mono text-meta text-text-mid">{origin}</code>)}</div> : <p className="mt-1 text-meta text-text-faint">{t('extensions.networkOriginsNone')}</p>}</div>
        {(module.routing_rules?.length ?? 0) > 0 ? <div><div className="text-meta text-text-faint">{t('extensions.routingRulesTitle')}</div><div className="mt-1 space-y-1.5"><RoutingRuleList rules={module.routing_rules!} /></div></div> : null}
      </section>
      <p className="text-label leading-5 text-text-faint">{t('extensions.install.reviewBody')}</p>
    </div>
  )
}
