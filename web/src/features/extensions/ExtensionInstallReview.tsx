import { useTranslation } from 'react-i18next'
import { Badge } from '../../components/ds'
import { InterceptModule } from '../../lib/api/types'

/** Displays only the module returned after the server has stored its snapshot. */
export function ExtensionInstallReview({ module }: { module: InterceptModule }) {
  const { t } = useTranslation()
  return (
    <div className="space-y-4" data-testid="extension-install-review">
      <div className="rounded-[16px] bg-primary-container p-4 text-on-primary-container">
        <div className="text-[14px] font-medium">{module.name} · v{module.extension_version}</div>
        <p className="mt-1 font-mono text-[10px] opacity-75">{module.id}</p>
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-[12px] bg-surface-container-low p-3"><div className="text-[10px] text-text-faint">{t('extensions.captureHosts')}</div><div className="mt-1 font-mono text-[18px]">{module.capture_hosts.length}</div></div>
        <div className="rounded-[12px] bg-surface-container-low p-3"><div className="text-[10px] text-text-faint">{t('extensions.actions')}</div><div className="mt-1 font-mono text-[18px]">{module.script_count}</div></div>
        <div className="rounded-[12px] bg-surface-container-low p-3"><div className="text-[10px] text-text-faint">{t('extensions.settings')}</div><div className="mt-1 font-mono text-[18px]">{module.settings?.length ?? 0}</div></div>
      </div>
      <div className="flex flex-wrap gap-1.5">{module.capture_hosts.map((host) => <code key={host} className="rounded-[7px] bg-surface-container-low px-2 py-1 font-mono text-[10px]">{host}</code>)}</div>
      <section className="space-y-2 rounded-[14px] bg-surface-container-low p-3" aria-label={t('extensions.install.snapshotDetails')}>
        <div className="flex flex-wrap items-center gap-1.5"><Badge tone="neutral">{t('extensions.disabled')}</Badge>{module.persistent_storage ? <Badge tone="indigo">{t('extensions.capabilityStorage')}</Badge> : null}{module.egress_group_required ? <Badge tone="cyan">{t('marketplace.egressRequired')}</Badge> : null}</div>
        <div className="flex flex-wrap items-start justify-between gap-2 rounded-[10px] bg-card p-2.5" data-testid="install-capture-dns">
          <div><div className="text-[10px] text-text-faint">{t('extensions.captureDNS.title')}</div><p className="mt-1 text-[10px] leading-4 text-text-soft">{t(`extensions.captureDNS.${module.capture_dns}Hint`)}</p></div>
          <Badge tone={module.capture_dns === 'china' ? 'amber' : 'blue'}>{t(`extensions.captureDNS.${module.capture_dns}`)}</Badge>
        </div>
        <div className="grid gap-2 sm:grid-cols-2"><div><div className="text-[10px] text-text-faint">{t('extensions.install.sourceDigest')}</div><code className="mt-1 block break-all font-mono text-[9.5px] text-text-mid">{module.source_digest}</code></div><div><div className="text-[10px] text-text-faint">{t('extensions.install.snapshotDigest')}</div><code className="mt-1 block break-all font-mono text-[9.5px] text-text-mid">{module.snapshot_digest}</code></div></div>
        <div><div className="text-[10px] text-text-faint">{t('extensions.networkOriginsTitle')}</div>{module.network_origins.length ? <div className="mt-1 flex flex-wrap gap-1.5">{module.network_origins.map((origin) => <code key={origin} className="max-w-full break-all rounded-[7px] bg-card px-2 py-1 font-mono text-[9.5px] text-text-mid">{origin}</code>)}</div> : <p className="mt-1 text-[10.5px] text-text-faint">{t('extensions.networkOriginsNone')}</p>}</div>
        {(module.routing_rules?.length ?? 0) > 0 ? <div><div className="text-[10px] text-text-faint">{t('extensions.routingRulesTitle')}</div><div className="mt-1 space-y-1.5">{module.routing_rules!.map((rule, index) => <code key={`${index}:${JSON.stringify(rule)}`} className="block break-all rounded-[7px] bg-[var(--md-sys-color-warning-container)] px-2 py-1 font-mono text-[9.5px] text-[var(--md-sys-color-on-warning-container)]">{JSON.stringify(rule)}</code>)}</div></div> : null}
      </section>
      <p className="text-[11px] leading-5 text-text-faint">{t('extensions.install.reviewBody')}</p>
    </div>
  )
}
