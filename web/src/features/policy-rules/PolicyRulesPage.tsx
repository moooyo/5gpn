import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus } from 'lucide-react'
import { Button, Modal, toast } from '../../components/ds'
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

/** 策略规则 (unified policy rules) page shell — `/api/policy/rules` +
 *  `/api/policy/fallback` (UP-1), Task B4. Fetch once on mount (rules only —
 *  UP-4 made the policy binary, so there is no selector list to load
 *  alongside it), own every dialog (add/edit/delete) and the Apply action,
 *  hand the table nothing but data + callbacks (PolicyRulesTable, B3, is
 *  pure).
 *
 *  CRUD (toggle/reorder/delete/dialog-save) persists to the rule store
 *  immediately and reloads the list; Apply is the separate step that
 *  compiles + `mihomo -t` validates + hot-reloads the live policy, same
 *  persist-vs-apply split as before.
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
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-policy-rules">
      <div className="flex items-center justify-between gap-3">
        <div className="text-[11.5px] text-text-faint">{t('policyRules.applyHint')}</div>
        <div className="flex items-center gap-2">
          <Button type="button" size="sm" onClick={() => setAddOpen(true)}>
            <Plus className="h-3.5 w-3.5" aria-hidden="true" />
            {t('policyRules.newRule')}
          </Button>
          <Button type="button" size="sm" onClick={() => void handleApply()} disabled={applying} data-testid="policy-apply">
            {applying ? t('policyRules.applying') : t('policyRules.apply')}
          </Button>
        </div>
      </div>

      <FallbackControl />

      {loading ? (
        <div className="p-5 text-sm text-text-faint">{t('common.loading')}</div>
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
