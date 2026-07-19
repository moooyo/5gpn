import { useEffect, useState } from 'react'
import { useForm } from 'react-hook-form'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { Badge, Button, Card, ConfirmDialog, DataLine, Field, Input, Toggle, toast } from '../../components/ds'
import { ShieldFilledIcon } from '../../components/icons'
import { cn } from '../../lib/cn'
import { THEME_CATALOG, useTheme, type ThemeName } from '../../lib/theme'
import { api } from '../../lib/api/client'
import { ApiError } from '../../lib/api/http'
import type { CertStatus, ECSView, IngressModule, IngressModulesView, MITMSettingsView, TGBotUpdate, TGBotView, UpstreamsView } from '../../lib/api/types'
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

// ---- 1. DoT service ---------------------------------------------------------

export function AppearanceCard() {
  const { t } = useTranslation()
  const { theme, setTheme } = useTheme()
  return (
    <Card variant="tonal" className="p-5 sm:p-6" data-testid="appearance-card">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
        <div className="min-w-[220px] flex-1">
          <h2 className="text-[16px] font-medium text-text-strong">{t('settings.appearance')}</h2>
          <p className="mt-1 text-[11.5px] leading-5 text-text-faint">{t('settings.appearanceHint')}</p>
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-5" role="radiogroup" aria-label={t('settings.appearance')}>
          {THEME_CATALOG.map((item) => (
            <button
              key={item.name}
              type="button"
              role="radio"
              aria-checked={theme === item.name}
              onClick={() => setTheme(item.name as ThemeName)}
              className={cn(
                'zds-state-layer flex min-h-12 items-center gap-2 rounded-[12px] px-3 text-[11.5px] font-medium',
                theme === item.name ? 'bg-card text-primary shadow-[var(--md-sys-elevation-1)]' : 'text-text-mid',
              )}
            >
              <span className="h-4 w-4 shrink-0 rounded-full border-2 border-card" style={{ background: item.swatch }} />
              {t(`topbar.themeNames.${item.name}`)}
            </button>
          ))}
        </div>
      </div>
    </Card>
  )
}

export function DotServiceCard({ cert, dotDomain }: { cert?: CertStatus; dotDomain?: string }) {
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
    <Card className="p-5 sm:p-6">
      <div className="mb-1 text-[15px] font-medium text-text-strong">{t('settings.dotService')}</div>
      <div className="flex flex-col gap-2 border-b border-divider pb-3">
        <span className="text-[12.5px] font-semibold text-text-mid">{t('settings.dotDomain')}</span>
        <Input
          mono
          disabled
          readOnly
          value={dotDomain ?? ''}
          placeholder={t('common.loading')}
          aria-label={t('settings.dotDomain')}
        />
      </div>
      <DataLine className="border-b-0" label={t('settings.cert')} sub={sub}>
        <Badge tone={tone}>{label}</Badge>
      </DataLine>
    </Card>
  )
}

// ---- 2. Console -------------------------------------------------------------

export function ConsoleCard() {
  const { t } = useTranslation()

  return (
    <Card className="p-5 sm:p-6">
      <div className="mb-1 text-[15px] font-medium text-text-strong">{t('settings.consoleTitle')}</div>
      <DataLine label={t('settings.listenPort')} sub={t('settings.listenPortHint')}>
        <span className="font-mono text-[12.5px] font-bold text-primary">127.0.0.1:443</span>
      </DataLine>
      <DataLine className="border-b-0" label={t('settings.consoleAuth')} sub={t('settings.consoleAuthHint')}>
        <Badge tone="blue">Bearer</Badge>
      </DataLine>
    </Card>
  )
}

// ---- 3. MITM runtime ------------------------------------------------------

export function MITMSettingsCard({
  settings,
  hostCount,
  loadState,
  onReload,
  onSaved,
}: {
  settings: MITMSettingsView | null
  hostCount: number
  loadState: 'loading' | 'ready' | 'error'
  onReload: () => Promise<MITMSettingsView | null>
  onSaved: (value: MITMSettingsView) => void
}) {
  const { t } = useTranslation()
  const [busyField, setBusyField] = useState<'master' | 'http2' | 'quic' | null>(null)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [pendingMaster, setPendingMaster] = useState<boolean | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function apply(
    field: 'master' | 'http2' | 'quic',
    patch: Partial<Pick<MITMSettingsView, 'enabled' | 'http2' | 'quic_fallback_protection'>>,
  ) {
    if (!settings || busyField) return
    setBusyField(field)
    setError(null)
    try {
      const next = await api.putMITMSettings({
        revision: settings.revision,
        enabled: settings.enabled,
        http2: settings.http2,
        quic_fallback_protection: settings.quic_fallback_protection,
        ...patch,
      })
      onSaved(next)
      toast.success(field === 'master' ? t(next.enabled ? 'settings.mitmEnabled' : 'settings.mitmDisabled') : t('settings.mitmCapabilitySaved'))
    } catch (err) {
      const conflict = err instanceof ApiError && err.status === 409
      if (conflict || (err instanceof ApiError && err.status === 502)) await onReload()
      setError(conflict ? t('settings.mitmConflict') : errMessage(err, t('settings.mitmSaveFailed')))
    } finally {
      setBusyField(null)
    }
  }

  function requestMaster(enabled: boolean) {
    setPendingMaster(enabled)
    setConfirmOpen(true)
  }

  const ready = !!settings && loadState === 'ready'
  const statusEnabled = settings?.enabled ?? false

  return (
    <Card className="p-5 sm:p-6" data-testid="mitm-settings-card">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="text-[15px] font-medium text-text-strong">{t('settings.mitmTitle')}</div>
          <p className="mt-1 max-w-3xl text-[10.5px] leading-relaxed text-text-faint">{t('settings.mitmHint')}</p>
        </div>
        <Badge tone={statusEnabled ? 'green' : 'neutral'}>
          {busyField === 'master' ? t('common.saving') : statusEnabled ? t('settings.mitmRunning') : t('settings.mitmStopped')}
        </Badge>
      </div>

      {loadState === 'loading' && !settings ? (
        <div role="status" className="mt-4 rounded-[16px] bg-surface-container-low px-4 py-4 text-[10.5px] text-text-faint">
          {t('common.loading')}
        </div>
      ) : null}
      {loadState === 'error' ? (
        <div role="alert" className="mt-4 flex flex-col gap-2 rounded-[16px] bg-[var(--md-sys-color-error-container)] px-4 py-3 text-[10.5px] text-[var(--md-sys-color-on-error-container)] sm:flex-row sm:items-center sm:justify-between">
          <span>{t('settings.mitmLoadFailed')}</span>
          <Button type="button" variant="secondary" size="sm" onClick={() => void onReload()}>
            {t('common.reload')}
          </Button>
        </div>
      ) : null}

      <div className="mt-4 overflow-hidden rounded-[20px] bg-surface-container-low">
        <div className="flex items-start justify-between gap-4 px-4 py-4 sm:px-5">
          <div className="min-w-0">
            <div className="text-[13px] font-semibold text-text-strong">{t('settings.mitmMaster')}</div>
            <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('settings.mitmMasterHint')}</p>
          </div>
          <Toggle
            checked={settings?.enabled ?? false}
            onCheckedChange={requestMaster}
            disabled={!ready || busyField !== null}
            aria-label={t('settings.mitmMaster')}
          />
        </div>

        {settings?.enabled ? <div className="grid grid-cols-1 gap-2 border-t border-divider p-2 sm:p-3 lg:grid-cols-2" data-testid="mitm-capabilities">
          <div className="flex min-h-[112px] items-start justify-between gap-4 rounded-[16px] bg-card px-4 py-4 shadow-[var(--md-sys-elevation-1)]">
            <div className="min-w-0">
              <div className="text-[12.5px] font-semibold text-text-mid">{t('settings.mitmHTTP2')}</div>
              <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('settings.mitmHTTP2Hint')}</p>
            </div>
            <Toggle
              checked={settings.http2}
              onCheckedChange={(http2) => void apply('http2', { http2 })}
              disabled={!ready || busyField !== null}
              aria-label={t('settings.mitmHTTP2')}
            />
          </div>

          <div className="flex min-h-[112px] items-start justify-between gap-4 rounded-[16px] bg-card px-4 py-4 shadow-[var(--md-sys-elevation-1)]">
            <div className="min-w-0">
              <div className="text-[12.5px] font-semibold text-text-mid">{t('settings.mitmQUICFallback')}</div>
              <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('settings.mitmQUICFallbackHint')}</p>
            </div>
            <Toggle
              checked={settings.quic_fallback_protection}
              onCheckedChange={(quic_fallback_protection) => void apply('quic', { quic_fallback_protection })}
              disabled={!ready || busyField !== null}
              aria-label={t('settings.mitmQUICFallback')}
            />
          </div>
        </div> : (
          <div className="border-t border-divider px-4 py-3 text-[10.5px] leading-5 text-text-faint sm:px-5">
            {t('settings.mitmCapabilitiesWhenEnabled')}
          </div>
        )}
      </div>

      <p className="mt-3 rounded-[14px] bg-[var(--md-sys-color-warning-container)] px-4 py-3 text-[10.5px] leading-relaxed text-[var(--md-sys-color-on-warning-container)]">
        {t('settings.mitmSafety')}
      </p>
      {error ? (
        <div role="alert" className="mt-3 rounded-[12px] bg-[var(--md-sys-color-error-container)] px-3 py-2.5 text-[10.5px] leading-relaxed text-[var(--md-sys-color-on-error-container)]" data-testid="mitm-settings-error">
          {error}
        </div>
      ) : null}
      <div className="mt-3 flex justify-start border-t border-divider pt-3">
        <Link
          to="/extensions/hosts"
          className="zds-state-layer inline-flex min-h-9 items-center gap-2 rounded-full px-3 text-[11.5px] font-medium text-primary"
          data-testid="mitm-host-audit-link"
        >
          {t('settings.mitmAuditHosts', { count: hostCount })}
        </Link>
      </div>

      <ConfirmDialog
        open={confirmOpen}
        onOpenChange={(open) => {
          setConfirmOpen(open)
          if (!open) setPendingMaster(null)
        }}
        title={pendingMaster ? t('settings.mitmEnableConfirmTitle') : t('settings.mitmDisableConfirmTitle')}
        description={pendingMaster ? t('settings.mitmEnableConfirmBody') : t('settings.mitmDisableConfirmBody')}
        confirmLabel={pendingMaster ? t('settings.mitmEnableAction') : t('settings.mitmDisableAction')}
        cancelLabel={t('common.cancel')}
        danger={pendingMaster === false}
        onConfirm={() => {
          if (pendingMaster !== null) void apply('master', { enabled: pendingMaster })
          setPendingMaster(null)
        }}
      />
    </Card>
  )
}

// ---- 4. Ingress ports ----------------------------------------------------

function ingressDraft(modules: IngressModule[]): Record<string, boolean> {
  return Object.fromEntries(modules.map((module) => [module.id, module.enabled]))
}

export function IngressPortsCard({
  modules,
  loadState,
  onReload,
  onSaved,
}: {
  modules: IngressModulesView | null
  loadState: 'loading' | 'ready' | 'error'
  onReload: () => Promise<IngressModulesView | null>
  onSaved: (v: IngressModulesView) => void
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<Record<string, boolean>>({})
  const [saving, setSaving] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (modules) setDraft(ingressDraft(modules.modules))
  }, [modules])

  const changed =
    modules?.modules.filter((module) => (draft[module.id] ?? module.enabled) !== module.enabled) ?? []
  const pendingModule = changed.length === 1 ? changed[0] : null
  const enabling = changed.some((module) => draft[module.id])
  const changingQUICBlock = pendingModule?.id === 'block-quic-443'

  async function save() {
    if (!modules || changed.length === 0 || saving) return
    setSaving(true)
    setError(null)
    try {
      // Keep exactly one pending module change. Sequential writes would expose
      // a partially applied selection without an atomic batch API.
      if (changed.length !== 1) throw new Error(t('settings.ingressSaveFailed'))
      const module = changed[0]
      const next = await api.putIngressModule(module.id, !!draft[module.id], modules.revision)
      onSaved(next)
      toast.success(t('settings.ingressSaved'))
    } catch (err) {
      const conflict = err instanceof ApiError && err.status === 409
      if (conflict || (err instanceof ApiError && err.status === 502)) await onReload()
      setError(conflict ? t('settings.ingressConflict') : errMessage(err, t('settings.ingressSaveFailed')))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Card className="p-5 sm:p-6" data-testid="ingress-ports-card">
      <div className="mb-1 text-[15px] font-medium text-text-strong">{t('settings.ingressPorts')}</div>
      <p className="mb-3 text-[10.5px] leading-relaxed text-text-faint">{t('settings.ingressPortsHint')}</p>

      {loadState === 'loading' && !modules ? (
        <div role="status" className="rounded-[14px] bg-surface-container-low px-4 py-4 text-[10.5px] text-text-faint">
          {t('common.loading')}
        </div>
      ) : null}
      {loadState === 'error' ? (
        <div
          role="alert"
          className="mb-3 flex flex-col gap-2 rounded-[14px] bg-[var(--md-sys-color-error-container)] px-4 py-3 text-[10.5px] text-[var(--md-sys-color-on-error-container)] sm:flex-row sm:items-center sm:justify-between"
          data-testid="ingress-ports-load-error"
        >
          <span>{t('settings.ingressLoadFailed')}</span>
          <Button type="button" variant="secondary" size="sm" onClick={() => void onReload()}>
            {t('common.reload')}
          </Button>
        </div>
      ) : null}

      <div className="flex flex-col gap-3">
        {modules?.modules.map((module) => {
          const enabled = draft[module.id] ?? module.enabled
          const pending = enabled !== module.enabled
          const manageable = module.manageable && !saving && loadState === 'ready' && (!pendingModule || pendingModule.id === module.id)
          const blocksQUIC = module.id === 'block-quic-443'
          return (
            <div key={module.id} className="rounded-[16px] bg-surface-container-low p-4" data-testid={`ingress-module-${module.id}`}>
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-[12.5px] font-semibold text-text-mid">{t(`settings.ingressModules.${module.id}.name`)}</span>
                    <Badge tone={pending ? 'amber' : enabled ? 'green' : 'neutral'}>
                      {pending
                        ? enabled
                          ? t('settings.ingressPendingEnable')
                          : t('settings.ingressPendingDisable')
                        : enabled
                          ? t('settings.ingressEnabled')
                          : t('settings.ingressDisabled')}
                    </Badge>
                  </div>
                  <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">
                    {t(`settings.ingressModules.${module.id}.description`)}
                  </p>
                </div>
                <Toggle
                  checked={enabled}
                  onCheckedChange={(checked) => {
                    setDraft((current) => ({ ...current, [module.id]: checked }))
                    setError(null)
                  }}
                  disabled={!manageable}
                  aria-label={t('settings.ingressToggle', { name: t(`settings.ingressModules.${module.id}.name`) })}
                />
              </div>

              <div className="mt-3 flex flex-col gap-2 rounded-[12px] bg-card px-3.5 py-3 sm:flex-row sm:items-center">
                <span className="border-b border-divider pb-2 font-mono text-[16px] font-bold text-primary sm:border-b-0 sm:border-r sm:pb-0 sm:pr-3">
                  :{module.port}
                </span>
                <div className="flex flex-wrap gap-1.5" aria-label={t('settings.ingressProtocols')}>
                  {blocksQUIC ? <Badge tone="amber">{t('settings.ingressBlocked')}</Badge> : null}
                  {!blocksQUIC && module.networks.includes('tcp') ? <Badge tone="blue">{t('settings.ingressTcp')}</Badge> : null}
                  {module.networks.includes('udp') ? <Badge tone="cyan">{blocksQUIC ? t('settings.ingressUdp443') : t('settings.ingressUdp')}</Badge> : null}
                </div>
              </div>

              {module.manageable ? null : (
                <p className="mt-2 text-[10.5px] leading-relaxed text-text-faint">
                  {t('settings.ingressCustomConfig')}{' '}
                  <Link to="/mihomo-config" className="font-semibold text-primary underline-offset-2 hover:underline">
                    {t('settings.ingressOpenConfig')}
                  </Link>
                </p>
              )}
            </div>
          )
        })}
      </div>

      <p className="mt-4 rounded-[14px] bg-[var(--md-sys-color-warning-container)] px-4 py-3 text-[10.5px] leading-relaxed text-[var(--md-sys-color-on-warning-container)]">{t('settings.ingressSafety')}</p>
      {error ? (
        <div role="alert" className="mt-3 rounded-[12px] bg-[var(--md-sys-color-error-container)] px-3 py-2.5 text-[10.5px] leading-relaxed text-[var(--md-sys-color-on-error-container)]" data-testid="ingress-ports-error">
          {error}
        </div>
      ) : null}
      <div className="mt-3 flex justify-end border-t border-divider pt-3">
        <Button
          type="button"
          size="sm"
          disabled={!modules || loadState !== 'ready' || saving || changed.length === 0}
          onClick={() => setConfirmOpen(true)}
          data-testid="ingress-ports-save"
        >
          {saving ? t('common.saving') : t('settings.ingressSave')}
        </Button>
      </div>

      <ConfirmDialog
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title={changingQUICBlock
          ? t(enabling ? 'settings.quicBlockEnableConfirmTitle' : 'settings.quicBlockDisableConfirmTitle')
          : t(enabling ? 'settings.ingressEnableConfirmTitle' : 'settings.ingressDisableConfirmTitle')}
        description={changingQUICBlock
          ? t(enabling ? 'settings.quicBlockEnableConfirmBody' : 'settings.quicBlockDisableConfirmBody')
          : t(enabling ? 'settings.ingressEnableConfirmBody' : 'settings.ingressDisableConfirmBody')}
        confirmLabel={t('settings.ingressSave')}
        cancelLabel={t('common.cancel')}
        onConfirm={() => void save()}
      />
    </Card>
  )
}

// ---- 5. Telegram bot --------------------------------------------------------

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
    <Card className="p-5 sm:p-6">
      <div className="mb-2 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="text-[15px] font-medium text-text-strong">{t('settings.tgbot')}</div>
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
          className="mb-3 break-all rounded-[12px] bg-[var(--md-sys-color-error-container)] px-3 py-2.5 text-[10.5px] text-[var(--md-sys-color-on-error-container)]"
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

// ---- 6. Upstream DNS --------------------------------------------------------

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
    <Card className="p-5 sm:p-6" data-testid="upstreams-card">
      <div className="mb-1 text-[15px] font-medium text-text-strong">{t('settings.upstreams')}</div>
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

// ---- 7. ECS -----------------------------------------------------------------

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
    <Card className="p-5 sm:p-6">
      <div className="mb-1 text-[15px] font-medium text-text-strong">{t('settings.ecs')}</div>
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

// ---- 8. About strip ---------------------------------------------------------

export function AboutStrip({ version, className }: { version?: string; className?: string }) {
  const { t } = useTranslation()
  return (
    <Card className={cn('flex flex-col gap-3 border-0 p-4 shadow-none sm:flex-row sm:items-center', className)}>
      <span className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-primary-container text-on-primary-container">
        <ShieldFilledIcon className="h-5 w-5" aria-hidden="true" />
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-[13.5px] font-medium text-text-strong">{t('settings.aboutTitle')}</div>
        <div className="mt-0.5 text-[10.5px] text-text-faint">{t('settings.aboutSubtitle')}</div>
      </div>
      <div className="shrink-0 rounded-[8px] bg-surface-container px-3 py-2 font-mono text-[10.5px] text-text-faint">
        {t('settings.aboutVersion', { version: version ?? '—' })}
      </div>
    </Card>
  )
}
