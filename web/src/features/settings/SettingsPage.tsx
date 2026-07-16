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
      const [u, e, tg] = await Promise.allSettled([api.getUpstreams(), api.getEcs(), api.getTgbot()])
      if (cancelled) return
      if (u.status === 'fulfilled') setUpstreams(u.value)
      if (e.status === 'fulfilled') setEcs(e.value)
      if (tg.status === 'fulfilled') setTgbot(tg.value)
    }

    void load()
    return () => {
      cancelled = true
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
