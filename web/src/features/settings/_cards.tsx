import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import { Badge, Button, Card, DataLine, Field, Input, Toggle, toast } from '../../components/ds'
import { cn } from '../../lib/cn'
import { api } from '../../lib/api/client'
import type { CertStatus, ECSView, TGBotUpdate, TGBotView, UpstreamsView } from '../../lib/api/types'
import { UpstreamGroupEditor } from './UpstreamGroupEditor'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/** Parse a comma-separated admin-ID list into numeric Telegram user IDs. */
function parseAdmins(raw: string): number[] {
  return raw
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => Number(part))
    .filter((n) => Number.isFinite(n))
}

// ---- 1. DoT 服务 ------------------------------------------------------------

export function DotServiceCard({ cert }: { cert?: CertStatus }) {
  const { t } = useTranslation()

  let tone: 'green' | 'red' | 'neutral' = 'neutral'
  let label = t('common.loading')
  let sub: string | undefined

  // The backend OMITS `cert` entirely when it's unavailable, and it is also
  // `undefined` on first load (before the first /api/status poll resolves) —
  // either way, there is no evidence the cert is valid, so this branch must
  // NOT fall through to the green "valid" state.
  if (cert === undefined) {
    // tone/label stay at the neutral "no evidence yet" default above.
  } else if (cert.broken) {
    tone = 'red'
    label = cert.error && cert.error.length > 0 ? cert.error : t('settings.certError')
  } else if (cert.expired) {
    tone = 'red'
    label = t('settings.certExpired')
  } else {
    tone = 'green'
    label = t('settings.certValid')
    sub = `${t('settings.certPort')} · ${t('settings.certDaysRemaining', { count: cert.days_remaining })}`
  }

  return (
    <Card className="p-[18px]">
      <div className="mb-1 text-[13px] font-bold text-text-strong">{t('settings.dotService')}</div>
      <div className="flex flex-col gap-2 border-b border-divider pb-3">
        <span className="text-[12.5px] font-semibold text-text-mid">{t('settings.dotDomain')}</span>
        <Input
          mono
          disabled
          readOnly
          title={t('settings.greenfieldTip')}
          placeholder={t('settings.greenfieldTip')}
          aria-label={t('settings.dotDomain')}
        />
      </div>
      <DataLine className="border-b-0" label={t('settings.cert')} sub={sub}>
        <Badge tone={tone}>{label}</Badge>
      </DataLine>
    </Card>
  )
}

// ---- 2. 控制台 --------------------------------------------------------------

export function ConsoleCard() {
  const { t } = useTranslation()

  return (
    <Card className="p-[18px]">
      <div className="mb-1 text-[13px] font-bold text-text-strong">{t('settings.consoleTitle')}</div>
      <DataLine label={t('settings.listenPort')} sub={t('settings.listenPortHint')}>
        <span className="font-mono text-[12.5px] font-bold text-primary">127.0.0.1:443</span>
      </DataLine>
      <DataLine className="border-b-0" label={t('settings.adminAccount')} sub="admin">
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled
          title={t('settings.greenfieldTip')}
        >
          {t('settings.changePassword')}
        </Button>
      </DataLine>
    </Card>
  )
}

// ---- 3. Telegram Bot --------------------------------------------------------

interface TgbotFormValues {
  token: string
  admins: string
}

export function TgbotCard({
  tgbot,
  onSaved,
}: {
  tgbot: TGBotView | null
  onSaved: (v: TGBotView) => void
}) {
  const { t } = useTranslation()
  const {
    register,
    handleSubmit,
    reset,
    resetField,
    getValues,
    formState: { dirtyFields },
  } = useForm<TgbotFormValues>({ defaultValues: { token: '', admins: '' } })

  const state = tgbot ? tgbot.state : 'disabled'
  const adminsSnapshot = tgbot ? tgbot.admins.join(',') : null
  const stateTone =
    state === 'healthy' ? 'green' : state === 'degraded' ? 'red' : state === 'starting' ? 'amber' : 'neutral'

  useEffect(() => {
    if (adminsSnapshot !== null) reset({ token: '', admins: adminsSnapshot })
  }, [adminsSnapshot, reset])

  async function apply(update: TGBotUpdate) {
    try {
      const res = await api.putTgbot(update)
      onSaved(res)
      resetField('token', { defaultValue: '' })
      toast.success(t('settings.tgbotSaved'))
    } catch (err) {
      toast.error(errMessage(err, t('settings.tgbotSaveFailed')))
    }
  }

  async function onSubmit(values: TgbotFormValues) {
    const update: TGBotUpdate = { admins: parseAdmins(values.admins) }
    if (dirtyFields.token && values.token.trim().length > 0) update.token = values.token.trim()
    await apply(update)
  }

  async function onToggle(checked: boolean) {
    if (!tgbot) return
    const admins = parseAdmins(getValues('admins'))
    if (checked) {
      const typedToken = getValues('token').trim()
      if (!tgbot.token_set && typedToken.length === 0) {
        toast.error(t('settings.tgbotNeedToken'))
        return
      }
      await apply({ admins, ...(typedToken.length > 0 ? { token: typedToken } : {}) })
    } else {
      await apply({ admins, token: '' })
    }
  }

  return (
    <Card className="p-[18px]">
      <div className="mb-2 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="text-[13px] font-bold text-text-strong">{t('settings.tgbot')}</div>
          <Badge tone={stateTone}>{t(`settings.tgbotState_${state}`)}</Badge>
        </div>
        <Toggle
          checked={!!tgbot?.token_set}
          onCheckedChange={(checked) => void onToggle(checked)}
          disabled={!tgbot}
          aria-label={t('settings.tgbotStatus')}
        />
      </div>
      {tgbot?.last_error ? (
        <div
          role="alert"
          className="mb-2 break-all rounded-lg border border-red/25 bg-red/5 px-3 py-2 text-[10.5px] text-red"
        >
          {tgbot.last_error}
        </div>
      ) : null}
      <form onSubmit={(e) => void handleSubmit(onSubmit)(e)} className="flex flex-col">
        <Field
          label={t('settings.tgbotToken')}
          className="border-b border-divider py-3 first:pt-0"
        >
          <Input
            type="password"
            autoComplete="off"
            placeholder={tgbot?.token_set ? t('settings.tgbotTokenKeep') : t('settings.tgbotTokenPlaceholder')}
            {...register('token')}
          />
          <span className="text-[10.5px] text-text-faint">{t('settings.tgbotTokenHint')}</span>
        </Field>
        <Field label={t('settings.tgbotAdmins')} className="py-3">
          <Input mono placeholder={t('settings.tgbotAdminsPlaceholder')} {...register('admins')} />
          <span className="text-[10.5px] text-text-faint">{t('settings.tgbotAdminsHint')}</span>
        </Field>
        <div className="flex justify-end pt-1">
          <Button type="submit" size="sm" disabled={!tgbot} data-testid="tgbot-save">
            {t('settings.tgbotSave')}
          </Button>
        </div>
      </form>
    </Card>
  )
}

// ---- 4. 上游 DNS -------------------------------------------------------------

export function UpstreamsCard({
  upstreams,
  onSaved,
}: {
  upstreams: UpstreamsView | null
  onSaved: (v: UpstreamsView) => void
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<UpstreamsView>({ china: [], trust: [] })
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (upstreams) setDraft({ china: [...upstreams.china], trust: [...upstreams.trust] })
  }, [upstreams])

  async function onSubmit() {
    if (draft.china.length === 0 || draft.trust.length === 0) return
    setSaving(true)
    try {
      const res = await api.putUpstreams(draft)
      onSaved(res)
      toast.success(t('settings.upstreamsSaved'))
    } catch (err) {
      toast.error(errMessage(err, t('settings.upstreamsSaveFailed')))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Card className="p-[18px]" data-testid="upstreams-card">
      <div className="mb-1 text-[13px] font-bold text-text-strong">{t('settings.upstreams')}</div>
      <p className="mb-3 text-[10.5px] leading-relaxed text-text-faint">{t('settings.upstreamsHint')}</p>
      <div className="flex flex-col gap-3">
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <UpstreamGroupEditor
            group="china"
            entries={draft.china}
            disabled={!upstreams || saving}
            onChange={(china) => setDraft((current) => ({ ...current, china }))}
          />
          <UpstreamGroupEditor
            group="trust"
            entries={draft.trust}
            disabled={!upstreams || saving}
            onChange={(trust) => setDraft((current) => ({ ...current, trust }))}
          />
        </div>
        <div className="flex justify-end">
          <Button
            type="button"
            size="sm"
            disabled={!upstreams || saving || draft.china.length === 0 || draft.trust.length === 0}
            onClick={() => void onSubmit()}
            data-testid="upstreams-save"
          >
            {saving ? t('common.saving') : t('settings.upstreamsSave')}
          </Button>
        </div>
      </div>
    </Card>
  )
}

// ---- 5. ECS -----------------------------------------------------------------

interface EcsFormValues {
  subnet: string
}

export function EcsCard({ ecs, onSaved }: { ecs: ECSView | null; onSaved: (v: ECSView) => void }) {
  const { t } = useTranslation()
  const { register, handleSubmit, reset } = useForm<EcsFormValues>({ defaultValues: { subnet: '' } })

  useEffect(() => {
    if (ecs) reset({ subnet: ecs.subnet })
  }, [ecs, reset])

  async function onSubmit(values: EcsFormValues) {
    try {
      const subnet = values.subnet.trim()
      const res = await api.putEcs(subnet)
      onSaved(res)
      reset({ subnet: res.subnet })
      toast.success(res.subnet ? t('settings.ecsSaved', { subnet: res.subnet }) : t('settings.ecsDisabled'))
    } catch (err) {
      toast.error(errMessage(err, t('settings.ecsSaveFailed')))
    }
  }

  return (
    <Card className="p-[18px]">
      <div className="mb-1 text-[13px] font-bold text-text-strong">{t('settings.ecs')}</div>
      <p className="mb-3 text-[10.5px] leading-relaxed text-text-faint">{t('settings.ecsHint')}</p>
      <form
        onSubmit={(e) => void handleSubmit(onSubmit)(e)}
        className="flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <Field label={t('settings.ecsSubnet')} className="flex-1">
          <Input mono placeholder="122.96.30.0" {...register('subnet')} />
        </Field>
        <Button type="submit" size="sm" disabled={!ecs} data-testid="ecs-save">
          {t('settings.ecsSave')}
        </Button>
      </form>
    </Card>
  )
}

// ---- 6. About strip ----------------------------------------------------------

export function AboutStrip({ version, className }: { version?: string; className?: string }) {
  const { t } = useTranslation()
  return (
    <Card className={cn('flex items-center justify-between p-[15px_18px]', className)}>
      <div className="text-[11.5px] text-text-faint">{t('settings.aboutTitle')}</div>
      <div className="font-mono text-[11px] text-text-faint">
        {t('settings.aboutVersion', { version: version ?? '—' })}
      </div>
    </Card>
  )
}
