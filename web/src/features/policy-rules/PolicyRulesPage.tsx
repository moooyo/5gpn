import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AddIcon, RocketIcon } from '../../components/icons'
import { Button, Card, Modal, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { PolicyRule } from '../../lib/api/types'
import { PolicyRuleDialog } from './PolicyRuleDialog'
import { PolicyRulesTable } from './PolicyRulesTable'
import { FallbackControl } from './FallbackControl'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/** Drop id/order (server-assigned) — matches PolicyRuleDialog's buildBody.
 *  Used by the toggle handler, which otherwise round-trips the row's CURRENT
 *  content unchanged except for `enabled`. */
function contentOf(r: PolicyRule): Omit<PolicyRule, 'id' | 'order'> {
  return { matcher: r.matcher, intent: r.intent, enabled: r.enabled }
}

/** Unified policy-rule page backed by `/api/policy/rules` and
 *  `/api/policy/fallback`. It owns the dialogs and Apply action while the
 *  table receives only data and callbacks.
 *
 *  CRUD (toggle/reorder/delete/dialog-save) persists to the rule store
 *  immediately and reloads the list; Apply is the separate step that
 *  compiles and hot-reloads the live DNS policy.
 *
 *  This page is DNS-only. Post-steering egress is the operator's complete
 *  mihomo config, edited on its own page. */
export default function PolicyRulesPage() {
  const { t } = useTranslation()
  const [rules, setRules] = useState<PolicyRule[]>([])
  const [loading, setLoading] = useState(true)
  const [applying, setApplying] = useState(false)
  const [addOpen, setAddOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<PolicyRule | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<PolicyRule | null>(null)

  const load = useCallback(async () => {
    try {
      setRules(await api.getPolicyRules())
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.loadFailed')))
    } finally {
      setLoading(false)
    }
  }, [t])
  useEffect(() => void load(), [load])

  async function handleApply() {
    setApplying(true)
    try {
      await api.applyPolicy()
      toast.success(t('policyRules.applyOk'))
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.applyFailed')))
    } finally {
      setApplying(false)
    }
  }

  async function handleToggle(rule: PolicyRule) {
    try {
      await api.updatePolicyRule(rule.id, { ...contentOf(rule), enabled: !rule.enabled })
      await load()
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.saveFailed')))
    }
  }
  async function handleReorder(ids: string[]) {
    try {
      await api.reorderPolicyRules(ids)
      await load()
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.saveFailed')))
    }
  }
  async function handleDelete() {
    if (!deleteTarget) return
    try {
      await api.deletePolicyRule(deleteTarget.id)
      toast.success(t('policyRules.deleteOk'))
      setDeleteTarget(null)
      await load()
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.deleteFailed')))
    }
  }

  return (
    <div className="flex flex-col gap-4" data-testid="page-policy-rules">
      <Card variant="tonal" className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:p-6">
        <div className="min-w-[220px] flex-1">
          <h1 className="text-[17px] font-medium text-text-strong">{t('policyRules.title')}</h1>
          <p className="mt-1.5 text-[12px] leading-5 text-text-faint">{t('policyRules.applyHint')}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button type="button" variant="tonal" onClick={() => setAddOpen(true)}>
            <AddIcon className="h-[18px] w-[18px]" aria-hidden="true" />
            {t('policyRules.newRule')}
          </Button>
          <Button type="button" onClick={() => void handleApply()} disabled={applying} data-testid="policy-apply">
            <RocketIcon className="h-[18px] w-[18px]" aria-hidden="true" />
            {applying ? t('policyRules.applying') : t('policyRules.apply')}
          </Button>
        </div>
      </Card>

      <FallbackControl />

      {loading ? (
        <Card variant="tonal" className="p-6 text-center text-sm text-text-faint">{t('common.loading')}</Card>
      ) : (
        <PolicyRulesTable
          rules={rules}
          onEdit={setEditTarget}
          onDelete={setDeleteTarget}
          onToggle={(r) => void handleToggle(r)}
          onReorder={(ids) => void handleReorder(ids)}
        />
      )}

      {addOpen ? (
        <PolicyRuleDialog
          open={addOpen}
          onOpenChange={setAddOpen}
          onSaved={() => {
            setAddOpen(false)
            void load()
          }}
        />
      ) : null}
      {editTarget ? (
        <PolicyRuleDialog
          open
          onOpenChange={(o) => {
            if (!o) setEditTarget(null)
          }}
          rule={editTarget}
          onSaved={() => {
            setEditTarget(null)
            void load()
          }}
        />
      ) : null}
      {deleteTarget ? (
        <Modal
          open
          onOpenChange={(o) => {
            if (!o) setDeleteTarget(null)
          }}
          title={t('policyRules.deleteTitle')}
          footer={
            <>
              <Button type="button" variant="secondary" size="sm" onClick={() => setDeleteTarget(null)}>
                {t('common.cancel')}
              </Button>
              <Button
                type="button"
                variant="danger"
                size="sm"
                onClick={() => void handleDelete()}
                data-testid="policy-rule-delete-confirm"
              >
                {t('common.delete')}
              </Button>
            </>
          }
        >
          <p className="text-[13px] text-text-mid">{t('policyRules.deleteConfirm', { name: deleteTarget.matcher.value })}</p>
        </Modal>
      ) : null}
    </div>
  )
}
