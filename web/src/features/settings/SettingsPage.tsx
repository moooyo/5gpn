import { useCallback, useEffect, useRef, useState } from 'react'
import { useStatus } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import type { ECSView, IngressModulesView, MITMSettingsView, TGBotView, UpstreamsView } from '../../lib/api/types'
import { AboutStrip, AppearanceCard, ConsoleCard, DotServiceCard, EcsCard, IngressPortsCard, MITMSettingsCard, TgbotCard, UpstreamsCard } from './_cards'

/** Settings page — live config cards for the DoT service/cert, the
 *  control-plane console, the Telegram bot, upstream DNS groups and ECS,
 *  plus a build-info strip. DoT-domain change and admin-password change have
 *  no API yet (greenfield) and render as disabled controls with a tooltip. */
export default function SettingsPage() {
  const { status } = useStatus()

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
    <div className="flex flex-col gap-4" data-testid="page-settings">
      <AppearanceCard />
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <DotServiceCard cert={status?.cert} dotDomain={status?.dot_domain} />
        <ConsoleCard />
      </div>
      <MITMSettingsCard
        settings={mitmSettings}
        hostCount={mitmHostCount}
        loadState={mitmLoadState}
        onReload={loadMITMSettings}
        onSaved={setMITMSettings}
      />
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2 xl:items-start">
        <IngressPortsCard
          modules={ingressModules}
          loadState={ingressLoadState}
          onReload={loadIngressModules}
          onSaved={setIngressModules}
        />
        <TgbotCard tgbot={tgbot} onSaved={setTgbot} />
      </div>
      <UpstreamsCard upstreams={upstreams} onSaved={setUpstreams} />
      <EcsCard ecs={ecs} onSaved={setEcs} />
      <AboutStrip version={status?.version} />
    </div>
  )
}
