import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Card, SegmentedControl, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { FallbackPolicyKind, PolicyFallback } from '../../lib/api/types'

const POLICIES: FallbackPolicyKind[] = ['auto', 'direct', 'gateway']

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/** Segmented auto/direct/gateway control for `/api/policy/fallback`.
 *  Application routing for gateway-bound traffic belongs to the operator's
 *  mihomo config, never to this DNS-only control. Self-loads via
 *  getPolicyFallback.
 *
 *  A selection PERSISTS IMMEDIATELY to policy.json (like every rule edit —
 *  matching the page's "edits save immediately" model), so there is no separate
 *  save button; the page's single "应用" button remains the one activation that
 *  recompiles + reloads. */
export function FallbackControl() {
  const { t } = useTranslation()
  const [fb, setFb] = useState<PolicyFallback | null>(null)

  const load = useCallback(async () => {
    try {
      setFb(await api.getPolicyFallback())
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.fallback.loadFailed')))
    }
  }, [t])
  useEffect(() => void load(), [load])

  // Persist on selection, optimistic + revert-on-failure. No save button.
  const change = useCallback(
    async (policy: FallbackPolicyKind) => {
      setFb((cur) => {
        if (!cur || cur.policy === policy) return cur
        const next = { ...cur, policy }
        void api.putPolicyFallback(next).catch((err) => {
          setFb(cur) // revert to the pre-change value
          toast.error(errMessage(err, t('policyRules.fallback.saveFailed')))
        })
        return next
      })
    },
    [t],
  )

  if (!fb) return <Card variant="tonal" className="p-5 text-[13px] text-text-faint">{t('common.loading')}</Card>

  return (
    <Card className="grid gap-4 p-5 sm:grid-cols-[minmax(180px,.6fr)_minmax(300px,1fr)] sm:items-center sm:p-6">
      <div>
        <div className="text-[15px] font-medium text-text-strong">{t('policyRules.fallback.title')}</div>
        <div className="mt-1 text-[11.5px] leading-5 text-text-faint">{t('policyRules.fallback.hint')}</div>
      </div>
      <div>
        <SegmentedControl
          value={fb.policy}
          onChange={(v) => void change(v as FallbackPolicyKind)}
          options={POLICIES.map((p) => ({ value: p, label: t(`policyRules.fallback.policy.${p}`) }))}
          className="grid-cols-3"
          ariaLabel={t('policyRules.fallback.title')}
        />
        <div className="mt-2 text-[11px] text-text-faint">{t(`policyRules.fallback.policyHint.${fb.policy}`)}</div>
      </div>
    </Card>
  )
}
