import { useEffect, useState } from 'react'
import { useStatus } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import type { ECSView, TGBotView, UpstreamsView } from '../../lib/api/types'
import { AboutStrip, ConsoleCard, DotServiceCard, EcsCard, TgbotCard, UpstreamsCard } from './_cards'

/** 设置 (Settings) page — live config cards for the DoT service/cert, the
 *  control-plane console, the Telegram bot, upstream DNS groups and ECS,
 *  plus a build-info strip. DoT-domain change and admin-password change have
 *  no API yet (greenfield) and render as disabled controls with a tooltip. */
export default function SettingsPage() {
  const { status } = useStatus()

  const [upstreams, setUpstreams] = useState<UpstreamsView | null>(null)
  const [ecs, setEcs] = useState<ECSView | null>(null)
  const [tgbot, setTgbot] = useState<TGBotView | null>(null)

  useEffect(() => {
    let cancelled = false

    async function load() {
      const [u, e] = await Promise.allSettled([api.getUpstreams(), api.getEcs()])
      if (cancelled) return
      if (u.status === 'fulfilled') setUpstreams(u.value)
      if (e.status === 'fulfilled') setEcs(e.value)
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [])

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
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-settings">
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <DotServiceCard cert={status?.cert} />
        <ConsoleCard />
      </div>
      <TgbotCard tgbot={tgbot} onSaved={setTgbot} />
      <UpstreamsCard upstreams={upstreams} onSaved={setUpstreams} />
      <EcsCard ecs={ecs} onSaved={setEcs} />
      <AboutStrip version={status?.version} />
    </div>
  )
}
