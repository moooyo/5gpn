import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { AddIcon, RocketIcon } from '../../components/icons'
import { Button, Card, Modal, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { FallbackPolicyKind, PolicyRule } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { PolicyRuleDialog } from './PolicyRuleDialog'
import { PolicyRulesTable } from './PolicyRulesTable'
import { FallbackControl } from './FallbackControl'
import { diffPolicyRules, type PolicySnapshot } from './policy-dirty'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/** Drop id/order (server-assigned) — matches PolicyRuleDialog's buildBody.
 *  Used by the toggle handler, which otherwise round-trips the row's CURRENT
 *  content unchanged except for `enabled`. */
function contentOf(r: PolicyRule): Omit<PolicyRule, 'id' | 'order'> {
  return { matcher: r.matcher, intent: r.intent, enabled: r.enabled }
}

function clockOf(at: number): string {
  const date = new Date(at)
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** Unified policy-rule page backed by `/api/policy/rules` and
 *  `/api/policy/fallback`. It owns the dialogs and Apply action while the
 *  table receives only data and callbacks.
 *
 *  CRUD (toggle/reorder/delete/dialog-save) persists to the rule store
 *  immediately and reloads the list; Apply is the separate step that
 *  compiles and hot-reloads the live DNS policy. The gap between those two is
 *  page-level state, so it lives on the header card rather than inside the
 *  Apply button — see policy-dirty.ts.
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
  const [appliedSnapshot, setAppliedSnapshot] = useState<PolicySnapshot | null>(null)
  const [appliedAt, setAppliedAt] = useState<number | null>(null)
  // The fallback saves through the same write-now/apply-later path as a rule,
  // so it belongs in the same diff. FallbackControl still owns loading and
  // persisting it; the page only needs the settled value to compare.
  const [fallback, setFallback] = useState<FallbackPolicyKind | null>(null)
  // The resolve test links here with the rule its result matched. The
  // highlight fades on its own; the row itself is not otherwise special.
  const [searchParams, setSearchParams] = useSearchParams()
  const highlightId = searchParams.get('highlight')
  useEffect(() => {
    if (!highlightId) return
    const timer = setTimeout(() => {
      setSearchParams((params) => {
        const next = new URLSearchParams(params)
        next.delete('highlight')
        return next
      }, { replace: true })
    }, 2400)
    return () => clearTimeout(timer)
  }, [highlightId, setSearchParams])

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

  const current = useMemo<PolicySnapshot>(() => ({ rules, fallback }), [rules, fallback])
  const pending = useMemo(() => diffPolicyRules(appliedSnapshot, current), [appliedSnapshot, current])
  const dirty = pending.count > 0

  async function handleApply() {
    setApplying(true)
    try {
      await api.applyPolicy()
      setAppliedSnapshot(current)
      setAppliedAt(Date.now())
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

  const upToDate = appliedSnapshot !== null && !dirty

  return (
    <div className="flex flex-col gap-4" data-testid="page-policy-rules">
      {/* Whole card carries the state, not just the button: "three of my edits
          are not live" is a fact about the page, and it has to survive the
          operator scrolling past a single control. */}
      <Card
        variant="tonal"
        data-testid="policy-header"
        data-dirty={dirty ? 'true' : 'false'}
        className={cn(
          'flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:p-6',
          dirty && 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
        )}
      >
        <div className="min-w-[220px] flex-1">
          <h1 className={cn('text-headline font-medium', dirty ? 'text-inherit' : 'text-text-strong')}>{t('policyRules.title')}</h1>
          <p className={cn('mt-1.5 text-label leading-5', dirty ? 'text-inherit opacity-90' : 'text-text-faint')}>
            {dirty
              ? t('policyRules.pendingHint', { count: pending.count })
              : upToDate && appliedAt !== null
                ? t('policyRules.upToDateHint', { time: clockOf(appliedAt) })
                : t('policyRules.applyHint')}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button type="button" variant="tonal" onClick={() => setAddOpen(true)}>
            <AddIcon className="h-[18px] w-[18px]" aria-hidden="true" />
            {t('policyRules.newRule')}
          </Button>
          <Button
            type="button"
            // The brief fills this button with `warning` when dirty. The whole
            // card already carries that container colour, so a warning button
            // on it reads as one undifferentiated amber block; `primary` is
            // what keeps the action legible against the state it sits on.
            variant={upToDate ? 'secondary' : 'primary'}
            onClick={() => void handleApply()}
            disabled={applying || upToDate}
            data-testid="policy-apply"
          >
            <RocketIcon className="h-[18px] w-[18px]" aria-hidden="true" />
            {applying
              ? t('policyRules.applying')
              : upToDate
                ? t('policyRules.applyUpToDate')
                : t('policyRules.apply')}
            {dirty ? (
              <span className="ml-1 inline-flex min-w-5 items-center justify-center rounded-pill bg-[var(--md-sys-color-on-primary)] px-1.5 font-mono text-meta font-semibold text-primary">
                {pending.count}
              </span>
            ) : null}
          </Button>
        </div>
      </Card>

      <FallbackControl onPolicyChange={setFallback} pending={pending.fallbackPending} />

      {loading ? (
        <Card variant="tonal" className="p-6 text-center text-sm text-text-faint">{t('common.loading')}</Card>
      ) : (
        <PolicyRulesTable
          rules={rules}
          pendingIds={pending.ids}
          highlightId={highlightId}
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
          <p className="text-body text-text-mid">{t('policyRules.deleteConfirm', { name: deleteTarget.matcher.value })}</p>
        </Modal>
      ) : null}
    </div>
  )
}
