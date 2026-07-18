import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Badge, Button, Card, ConfirmDialog, Field, Input, Toggle, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { ApiError } from '../../lib/api/http'
import type { WLOCInterceptView } from '../../lib/api/types'

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

export function WLOCInterceptCard({
  value,
  routeEnabled,
  onReload,
  onSaved,
}: {
  value: WLOCInterceptView | null
  routeEnabled: boolean
  onReload: () => Promise<WLOCInterceptView | null>
  onSaved: (value: WLOCInterceptView) => void
}) {
  const { t } = useTranslation()
  const [enabled, setEnabled] = useState(false)
  const [longitude, setLongitude] = useState('')
  const [latitude, setLatitude] = useState('')
  const [accuracy, setAccuracy] = useState('25')
  const [failClosed, setFailClosed] = useState(true)
  const [saving, setSaving] = useState(false)
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!value) return
    setEnabled(value.enabled)
    setLongitude(value.longitude === null ? '' : String(value.longitude))
    setLatitude(value.latitude === null ? '' : String(value.latitude))
    setAccuracy(String(value.accuracy))
    setFailClosed(value.fail_closed)
  }, [value])

  async function save() {
    if (!value || saving) return
    const parsedLongitude = longitude.trim() === '' ? null : Number(longitude)
    const parsedLatitude = latitude.trim() === '' ? null : Number(latitude)
    const parsedAccuracy = Number(accuracy)
    if (
      (enabled && (parsedLongitude === null || parsedLatitude === null)) ||
      (parsedLongitude !== null && (!Number.isFinite(parsedLongitude) || parsedLongitude < -180 || parsedLongitude > 180)) ||
      (parsedLatitude !== null && (!Number.isFinite(parsedLatitude) || parsedLatitude < -90 || parsedLatitude > 90)) ||
      !Number.isInteger(parsedAccuracy) ||
      parsedAccuracy < 1 ||
      parsedAccuracy > 100000
    ) {
      setError(t('settings.wlocInvalid'))
      return
    }
    setSaving(true)
    setError(null)
    try {
      const updated = await api.putWLOCIntercept({
        revision: value.revision,
        enabled,
        longitude: parsedLongitude,
        latitude: parsedLatitude,
        accuracy: parsedAccuracy,
        fail_closed: failClosed,
        max_body_bytes: value.max_body_bytes,
      })
      onSaved(updated)
      toast.success(t('settings.wlocSaved'))
    } catch (saveError) {
      if (saveError instanceof ApiError && saveError.status === 409) await onReload()
      setError(errorMessage(saveError, t('settings.wlocSaveFailed')))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Card className="p-[18px]" data-testid="wloc-intercept-card">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-[13px] font-bold text-text-strong">{t('settings.wlocTitle')}</span>
            <Badge tone={enabled && routeEnabled ? 'green' : enabled ? 'amber' : 'neutral'}>
              {enabled && routeEnabled ? t('settings.wlocActive') : enabled ? t('settings.wlocAwaitingRoute') : t('settings.ingressDisabled')}
            </Badge>
          </div>
          <p className="mt-1 text-[10.5px] leading-relaxed text-text-faint">{t('settings.wlocHint')}</p>
        </div>
        <Toggle
          checked={enabled}
          onCheckedChange={(checked) => {
            setEnabled(checked)
            setError(null)
          }}
          disabled={!value || saving}
          aria-label={t('settings.wlocToggle')}
        />
      </div>

      <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <Field label={t('settings.wlocLongitude')}>
          <Input aria-label={t('settings.wlocLongitude')} type="number" step="any" min={-180} max={180} value={longitude} onChange={(event) => setLongitude(event.target.value)} disabled={!value || saving} />
        </Field>
        <Field label={t('settings.wlocLatitude')}>
          <Input aria-label={t('settings.wlocLatitude')} type="number" step="any" min={-90} max={90} value={latitude} onChange={(event) => setLatitude(event.target.value)} disabled={!value || saving} />
        </Field>
        <Field label={t('settings.wlocAccuracy')}>
          <Input aria-label={t('settings.wlocAccuracy')} type="number" step={1} min={1} max={100000} value={accuracy} onChange={(event) => setAccuracy(event.target.value)} disabled={!value || saving} />
        </Field>
      </div>

      <div className="mt-3 flex flex-col gap-3 rounded-[10px] border border-divider bg-input/40 p-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="text-[11px] font-semibold text-text-mid">{t('settings.wlocFailClosed')}</div>
          <p className="mt-0.5 text-[10.5px] text-text-faint">{t('settings.wlocFailClosedHint')}</p>
        </div>
        <Toggle checked={failClosed} onCheckedChange={setFailClosed} disabled={!value || saving} aria-label={t('settings.wlocFailClosed')} />
      </div>

      {error ? <div role="alert" className="mt-3 rounded-lg border border-red/25 bg-red/5 px-3 py-2 text-[10.5px] text-red">{error}</div> : null}
      <div className="mt-3 flex justify-end border-t border-divider pt-3">
        <Button
          type="button"
          size="sm"
          disabled={!value || saving}
          onClick={() => (enabled && !value?.enabled ? setConfirmOpen(true) : void save())}
        >
          {saving ? t('common.saving') : t('common.save')}
        </Button>
      </div>

      <ConfirmDialog
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title={t('settings.wlocConfirmTitle')}
        description={t('settings.wlocConfirmBody')}
        confirmLabel={t('common.save')}
        cancelLabel={t('common.cancel')}
        onConfirm={() => void save()}
      />
    </Card>
  )
}
