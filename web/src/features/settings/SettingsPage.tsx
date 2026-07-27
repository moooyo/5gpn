import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useStatus } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import { cn } from '../../lib/cn'
import type { ECSView, IngressModulesView, MITMSettingsView, TGBotView, UpstreamsView } from '../../lib/api/types'
import { AppearanceCard, ConsoleCard, DotServiceCard, EcsCard, IngressPortsCard, MITMSettingsCard, StatsResetCard, TgbotCard, UpstreamsCard } from './_cards'

/**
 * Ten cards in one straight column with no headings, no anchors and 3000+px of
 * scroll: reaching 上游 DNS meant scrolling past certificates, console, stats,
 * MITM, ingress ports and Telegram. Five sections with a sticky index turn
 * that into one click.
 */
const SECTIONS = [
  { id: 'appearance', labelKey: 'settings.sectionAppearance' },
  { id: 'service', labelKey: 'settings.sectionService' },
  { id: 'intercept', labelKey: 'settings.sectionIntercept' },
  { id: 'ingress', labelKey: 'settings.sectionIngress' },
  { id: 'resolution', labelKey: 'settings.sectionResolution' },
] as const

type SectionId = (typeof SECTIONS)[number]['id']

/** Settings page — live config cards for the DoT service/cert, the
 *  control-plane console, the Telegram bot, upstream DNS groups and ECS,
 *  plus a build-info strip. DoT-domain change and admin-password change have
 *  no API yet (greenfield) and render as disabled controls with a tooltip. */
export default function SettingsPage() {
  const { status, mihomo, intercept } = useStatus()

  const [upstreams, setUpstreams] = useState<UpstreamsView | null>(null)
  const [ecs, setEcs] = useState<ECSView | null>(null)
  const [tgbot, setTgbot] = useState<TGBotView | null>(null)
  const [ingressModules, setIngressModules] = useState<IngressModulesView | null>(null)
  const [ingressLoadState, setIngressLoadState] = useState<'loading' | 'ready' | 'error'>('loading')
  const ingressLoadSequence = useRef(0)
  const [mitmSettings, setMITMSettings] = useState<MITMSettingsView | null>(null)
  const [mitmHostCount, setMITMHostCount] = useState(0)
  const [mitmLoadState, setMITMLoadState] = useState<'loading' | 'ready' | 'error'>('loading')
  const mitmLoadSequence = useRef(0)

  const loadIngressModules = useCallback(async (): Promise<IngressModulesView | null> => {
    const sequence = ++ingressLoadSequence.current
    setIngressLoadState('loading')
    try {
      const value = await api.getIngressModules()
      if (sequence !== ingressLoadSequence.current) return null
      setIngressModules(value)
      setIngressLoadState('ready')
      return value
    } catch {
      if (sequence !== ingressLoadSequence.current) return null
      setIngressLoadState('error')
      return null
    }
  }, [])

  const loadMITMSettings = useCallback(async (): Promise<MITMSettingsView | null> => {
    const sequence = ++mitmLoadSequence.current
    setMITMLoadState('loading')
    try {
      const [settingsResult, extensionsResult] = await Promise.allSettled([
        api.getMITMSettings(),
        api.getInterceptModules(),
      ])
      if (sequence !== mitmLoadSequence.current) return null
      if (extensionsResult.status === 'fulfilled') {
        setMITMHostCount(extensionsResult.value.modules.reduce((count, extension) => count + extension.capture_hosts.length, 0))
      }
      if (settingsResult.status === 'rejected') throw settingsResult.reason
      const value = settingsResult.value
      setMITMSettings(value)
      setMITMLoadState('ready')
      return value
    } catch {
      if (sequence !== mitmLoadSequence.current) return null
      setMITMLoadState('error')
      return null
    }
  }, [])

  useEffect(() => {
    let cancelled = false

    async function load() {
      const [u, e] = await Promise.allSettled([api.getUpstreams(), api.getEcs()])
      if (cancelled) return
      if (u.status === 'fulfilled') setUpstreams(u.value)
      if (e.status === 'fulfilled') setEcs(e.value)
    }

    void load()
    void loadIngressModules()
    void loadMITMSettings()
    return () => {
      cancelled = true
      ingressLoadSequence.current++
      mitmLoadSequence.current++
    }
  }, [loadIngressModules, loadMITMSettings])

  // Bot lifecycle can move starting → healthy/degraded independently after a
  // save or gateway-network recovery. Poll single-flight and abort on unmount;
  // scheduling the next request only after the current one settles prevents
  // overlapping GETs on a slow Telegram/control path.
  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let controller: AbortController | undefined

    async function pollTgbot() {
      controller = new AbortController()
      try {
        const value = await api.getTgbot(controller.signal)
        if (!cancelled) setTgbot(value)
      } catch {
        // Keep the last known state; the normal control-plane status surfaces
        // connectivity failures elsewhere.
      } finally {
        if (!cancelled) timer = setTimeout(() => void pollTgbot(), 5_000)
      }
    }

    void pollTgbot()
    return () => {
      cancelled = true
      controller?.abort()
      if (timer !== undefined) clearTimeout(timer)
    }
  }, [])

  return (
    <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:gap-6" data-testid="page-settings">
      <SettingsNav
        version={status?.version}
        zashVersion={status?.zash_version}
        mihomoVersion={mihomo?.version}
        sidecarVersion={intercept?.version}
      />

      <div className="flex min-w-0 flex-1 flex-col gap-6">
        <SettingsSection id="appearance">
          <AppearanceCard />
        </SettingsSection>

        <SettingsSection id="service">
          {/* Both two-column groups use the same breakpoint. They used to split
              at `md` and `xl`, so between 768 and 1279px the top of the page
              was two columns and the bottom one — which reads as broken layout,
              not as a decision. */}
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <DotServiceCard cert={status?.cert} dotDomain={status?.dot_domain} />
            <ConsoleCard />
          </div>
          <StatsResetCard stats={status?.stats} />
        </SettingsSection>

        <SettingsSection id="intercept">
          <MITMSettingsCard
            settings={mitmSettings}
            hostCount={mitmHostCount}
            loadState={mitmLoadState}
            onReload={loadMITMSettings}
            onSaved={setMITMSettings}
          />
        </SettingsSection>

        <SettingsSection id="ingress">
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2 lg:items-start">
            <IngressPortsCard
              modules={ingressModules}
              loadState={ingressLoadState}
              onReload={loadIngressModules}
              onSaved={setIngressModules}
            />
            <TgbotCard tgbot={tgbot} onSaved={setTgbot} />
          </div>
        </SettingsSection>

        <SettingsSection id="resolution">
          <UpstreamsCard upstreams={upstreams} onSaved={setUpstreams} />
          <EcsCard ecs={ecs} onSaved={setEcs} />
        </SettingsSection>
      </div>
    </div>
  )
}

function SettingsSection({ id, children }: { id: SectionId; children: React.ReactNode }) {
  const { t } = useTranslation()
  const section = SECTIONS.find((candidate) => candidate.id === id)!
  return (
    <section
      id={`settings-${id}`}
      aria-labelledby={`settings-${id}-heading`}
      // Cleared by the sticky index above it on narrow widths.
      className="flex scroll-mt-24 flex-col gap-4"
    >
      <h2 id={`settings-${id}-heading`} className="px-1 text-label font-medium uppercase tracking-[.08em] text-text-faint">
        {t(section.labelKey)}
      </h2>
      {children}
    </section>
  )
}

/** Sticky index: a 180px rail beside the content from `lg`, a horizontally
 *  scrolling row of section pills below it. The version block rides along
 *  because it is the first thing anyone looks up when something is wrong —
 *  it used to be a strip at the very bottom of 3000px of scroll. */
function SettingsNav({
  version,
  zashVersion,
  mihomoVersion,
  sidecarVersion,
}: {
  version?: string
  zashVersion?: string
  mihomoVersion?: string
  sidecarVersion?: string
}) {
  const { t } = useTranslation()
  const [active, setActive] = useState<SectionId>('appearance')

  useEffect(() => {
    if (typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((entry) => entry.isIntersecting)
        if (visible.length === 0) return
        const top = visible.reduce((best, entry) => (entry.boundingClientRect.top < best.boundingClientRect.top ? entry : best))
        const id = top.target.id.replace(/^settings-/, '') as SectionId
        setActive(id)
      },
      { rootMargin: '-96px 0px -60% 0px' },
    )
    for (const section of SECTIONS) {
      const node = document.getElementById(`settings-${section.id}`)
      if (node) observer.observe(node)
    }
    return () => observer.disconnect()
  }, [])

  const go = (id: SectionId) => {
    setActive(id)
    document.getElementById(`settings-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  // The two unknowns are not the same unknown. 5gpn-dns and mihomo are always
  // part of an install, so not knowing a version is itself worth reporting;
  // the zashboard panel is optional and the sidecar only reports one while it
  // is running, so a dash there would claim "installed but unidentified" about
  // something that may simply not be there.
  const versions: Array<[string, string]> = [
    [t('settings.aboutVersionLabel'), version ?? '—'],
    [t('settings.aboutMihomoLabel'), mihomoVersion ?? '—'],
    ...(sidecarVersion ? [[t('settings.aboutSidecarLabel'), sidecarVersion] as [string, string]] : []),
    ...(zashVersion ? [[t('settings.aboutZashLabel'), zashVersion] as [string, string]] : []),
  ]

  return (
    <nav
      aria-label={t('settings.sectionsLabel')}
      data-testid="settings-nav"
      className="sticky top-0 z-10 -mx-1 bg-bg px-1 py-2 lg:top-4 lg:w-[180px] lg:shrink-0 lg:py-0"
    >
      <div className="flex gap-1.5 overflow-x-auto lg:flex-col lg:overflow-visible">
        {SECTIONS.map((section) => (
          <button
            key={section.id}
            type="button"
            onClick={() => go(section.id)}
            aria-current={active === section.id ? 'true' : undefined}
            className={cn(
              'zds-state-layer inline-flex h-field shrink-0 items-center rounded-pill px-3.5 text-left text-label font-medium lg:w-full',
              active === section.id ? 'bg-secondary-container text-on-secondary-container' : 'text-text-mid',
            )}
          >
            {t(section.labelKey)}
          </button>
        ))}
      </div>
      <div className="mt-4 hidden flex-col gap-1.5 rounded-card bg-surface-container-low p-3 lg:flex">
        <div className="text-meta font-medium uppercase tracking-[.08em] text-text-faint">{t('settings.aboutVersionsTitle')}</div>
        {versions.map(([label, value]) => (
          <div key={label} className="flex items-baseline justify-between gap-2">
            <span className="text-meta text-text-faint">{label}</span>
            <span className="min-w-0 truncate font-mono text-meta text-text-mid" title={`${label} ${value}`}>{value}</span>
          </div>
        ))}
      </div>
    </nav>
  )
}
