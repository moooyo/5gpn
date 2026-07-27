import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Badge, Card, SegmentedControl, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { cn } from '../../lib/cn'
import type { FallbackPolicyKind, PolicyFallback } from '../../lib/api/types'

const POLICIES: FallbackPolicyKind[] = ['auto', 'direct', 'gateway']

export interface FallbackControlProps {
  /** Fires with every settled value so the page can diff it against the
   *  applied snapshot. `null` means "not loaded yet", not "no fallback". */
  onPolicyChange?: (policy: FallbackPolicyKind | null) => void
  /** The current value differs from the last applied one. */
  pending?: boolean
}

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
 *  recompiles + reloads.
 *
 *  Which is exactly why the value is reported upward: the page diffs it against
 *  the applied snapshot alongside the rules. While it was not, a fallback
 *  change left the count at 0, and a count of 0 disables Apply — so the one
 *  control that saves without applying was also the one whose change could not
 *  be applied. */
export function FallbackControl({ onPolicyChange, pending = false }: FallbackControlProps) {
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

  // Report every settled value, including the initial load and a failed
  // save's revert, so the page's diff never trails what is on screen.
  useEffect(() => {
    onPolicyChange?.(fb?.policy ?? null)
  }, [fb?.policy, onPolicyChange])

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

  if (!fb) return <Card variant="tonal" className="p-5 text-body text-text-faint">{t('common.loading')}</Card>

  return (
    <Card
      data-testid="policy-fallback"
      data-pending={pending ? 'true' : 'false'}
      className={cn(
        'grid gap-4 p-5 sm:grid-cols-[minmax(180px,.6fr)_minmax(300px,1fr)] sm:items-center sm:p-6',
        // Same 3px warning marker the pending rule rows carry, for the same
        // reason: the count in the header has to be traceable to a control.
        pending && 'border-l-[3px] border-l-[var(--md-sys-color-warning)]',
      )}
    >
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-title font-medium text-text-strong">{t('policyRules.fallback.title')}</span>
          {pending ? <Badge tone="amber">{t('policyRules.table.pendingTag')}</Badge> : null}
        </div>
        <div className="mt-1 text-label leading-5 text-text-faint">{t('policyRules.fallback.hint')}</div>
      </div>
      <div>
        <SegmentedControl
          value={fb.policy}
          onChange={(v) => void change(v as FallbackPolicyKind)}
          options={POLICIES.map((p) => ({ value: p, label: t(`policyRules.fallback.policy.${p}`) }))}
          className="grid-cols-3"
          ariaLabel={t('policyRules.fallback.title')}
        />
        <div className="mt-2 text-label text-text-faint">{t(`policyRules.fallback.policyHint.${fb.policy}`)}</div>
      </div>
    </Card>
  )
}
