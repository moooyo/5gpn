import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button, Field, Input, Label, Modal, Select, Toggle, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { Intent, MatcherKind, PolicyMatcher, PolicyRule, SubscriptionFormat } from '../../lib/api/types'

const INTENTS: Intent[] = ['block', 'direct', 'proxy']
const KINDS: MatcherKind[] = ['domain', 'domain-suffix', 'domain-keyword', 'subscription']
const FORMATS: SubscriptionFormat[] = ['plain', 'gfwlist', 'dnsmasq', 'hosts']

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

// Structural mirror of policy_rules.go's validateSubscriptionURLScheme: only
// http/https is accepted (the fetcher never dials anything else). This is a
// client-side pre-check only — the backend re-validates on submit regardless.
function isValidSubscriptionUrl(value: string): boolean {
  try {
    const u = new URL(value)
    return u.protocol === 'http:' || u.protocol === 'https:'
  } catch {
    return false
  }
}

export interface PolicyRuleDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Present -> edit this rule (its id is kept); absent -> add a new one. */
  rule?: PolicyRule | null
  onSaved: () => void
}

interface FormState {
  kind: MatcherKind
  value: string
  format: SubscriptionFormat
  interval: string
  intent: Intent
  enabled: boolean
}

function initial(rule: PolicyRule | null | undefined): FormState {
  if (rule) {
    return {
      kind: rule.matcher.kind,
      value: rule.matcher.value,
      format: rule.matcher.format ?? 'plain',
      interval: rule.matcher.interval ?? '24h0m0s',
      intent: rule.intent,
      enabled: rule.enabled,
    }
  }
  return {
    kind: 'domain-suffix',
    value: '',
    format: 'plain',
    interval: '24h0m0s',
    intent: 'block',
    enabled: true,
  }
}

/** Add/edit dialog for one unified policy rule. The matcher kind controls
 *  whether the URL/format/interval subscription fields
 *  show (only `kind === 'subscription'` fetches a remote list; the domain
 *  family kinds are a bare literal). Intent (block/direct/proxy) carries no
 *  extra fields: `proxy` means only
 *  "steer to the gateway", and there is no selector to pick here; what
 *  happens to that traffic afterwards is the operator's mihomo config,
 *  edited elsewhere. Built on ds/Modal + ds/Select; the kind/intent pickers
 *  are small data-testid-bearing radiogroup buttons rather than
 *  ds/SegmentedControl because SegmentedControl's options don't carry a
 *  per-item testid hook. */
export function PolicyRuleDialog({ open, onOpenChange, rule, onSaved }: PolicyRuleDialogProps) {
  const { t } = useTranslation()
  const editing = rule ?? null
  const [form, setForm] = useState<FormState>(() => initial(editing))
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const isSub = form.kind === 'subscription'

  function set<K extends keyof FormState>(k: K, v: FormState[K]) {
    setForm((f) => ({ ...f, [k]: v }))
    setError(null)
  }

  function reset() {
    setForm(initial(editing))
    setError(null)
  }

  function handleOpenChange(next: boolean) {
    if (!next) reset()
    onOpenChange(next)
  }

  function buildBody(): Omit<PolicyRule, 'id' | 'order'> | null {
    const value = form.value.trim()
    if (!value) {
      setError(t('policyRules.dialog.errValueRequired'))
      return null
    }
    if (isSub && !isValidSubscriptionUrl(value)) {
      setError(t('policyRules.dialog.errUrlInvalid'))
      return null
    }
    const interval = form.interval.trim()
    if (isSub && !interval) {
      setError(t('policyRules.dialog.errIntervalRequired'))
      return null
    }
    const matcher: PolicyMatcher = form.kind === 'subscription'
      ? { kind: 'subscription', value, format: form.format, interval }
      : { kind: form.kind, value }
    return {
      matcher,
      intent: form.intent,
      enabled: form.enabled,
    }
  }

  async function handleSave() {
    const body = buildBody()
    if (!body) return
    setSubmitting(true)
    try {
      if (editing) await api.updatePolicyRule(editing.id, body)
      else await api.createPolicyRule(body)
      toast.success(editing ? t('policyRules.dialog.editOk') : t('policyRules.dialog.createOk'))
      onSaved()
      handleOpenChange(false)
    } catch (err) {
      toast.error(errMessage(err, t('policyRules.dialog.saveFailed')))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Modal
      open={open}
      onOpenChange={handleOpenChange}
      title={editing ? t('policyRules.dialog.editTitle') : t('policyRules.dialog.addTitle')}
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => handleOpenChange(false)}>
            {t('common.cancel')}
          </Button>
          <Button
            type="button"
            size="sm"
            onClick={() => void handleSave()}
            disabled={submitting}
            data-testid="policy-rule-dialog-save"
          >
            {editing ? t('common.save') : t('common.add')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {/* matcher kind — a small radio-style row so each option carries a stable testid */}
        <Field label={t('policyRules.dialog.kindLabel')}>
          <div className="grid grid-cols-2 gap-1 rounded-[12px] bg-surface-container p-1 sm:grid-cols-4" role="radiogroup">
            {KINDS.map((k) => (
              <button
                key={k}
                type="button"
                role="radio"
                aria-checked={form.kind === k}
                data-testid={`policy-rule-kind-${k}`}
                onClick={() => set('kind', k)}
                className={
                  form.kind === k
                    ? 'zds-state-layer rounded-[9px] bg-card px-2.5 py-2 text-[11.5px] font-medium text-primary shadow-[var(--md-sys-elevation-1)]'
                    : 'zds-state-layer rounded-[9px] px-2.5 py-2 text-[11.5px] text-text-faint'
                }
              >
                {t(`policyRules.kind.${k}`)}
              </button>
            ))}
          </div>
        </Field>

        <Field label={isSub ? t('policyRules.dialog.urlLabel') : t('policyRules.dialog.valueLabel')}>
          <Input
            mono
            autoFocus
            value={form.value}
            onChange={(e) => set('value', e.target.value)}
            placeholder={isSub ? 'https://example.com/list.txt' : 'example.com'}
            data-testid="policy-rule-value"
          />
        </Field>

        {isSub ? (
          <>
            <div data-testid="policy-rule-format-field">
              <Field label={t('policyRules.dialog.formatLabel')}>
                <Select
                  value={form.format}
                  onValueChange={(v) => set('format', v as SubscriptionFormat)}
                  items={FORMATS.map((f) => ({ value: f, label: f }))}
                />
              </Field>
            </div>
            <div data-testid="policy-rule-interval-field">
              <Field label={t('policyRules.dialog.intervalLabel')}>
                <Input mono value={form.interval} onChange={(e) => set('interval', e.target.value)} placeholder="24h0m0s" />
              </Field>
            </div>
          </>
        ) : null}

        {/* Intent is a bare DNS-steering decision. */}
        <Field label={t('policyRules.dialog.intentLabel')}>
          <div className="grid grid-cols-3 gap-1 rounded-[12px] bg-surface-container p-1" role="radiogroup">
            {INTENTS.map((i) => (
              <button
                key={i}
                type="button"
                role="radio"
                aria-checked={form.intent === i}
                data-testid={`policy-rule-intent-${i}`}
                onClick={() => set('intent', i)}
                className={
                  form.intent === i
                    ? 'zds-state-layer rounded-[9px] bg-card px-2.5 py-2 text-[11.5px] font-medium text-primary shadow-[var(--md-sys-elevation-1)]'
                    : 'zds-state-layer rounded-[9px] px-2.5 py-2 text-[11.5px] text-text-faint'
                }
              >
                {t(`policyRules.intent.${i}`)}
              </button>
            ))}
          </div>
        </Field>

        <div className="flex items-center justify-between rounded-[12px] bg-surface-container-low px-3.5 py-3">
          <Label>{t('policyRules.dialog.enabledLabel')}</Label>
          <Toggle
            checked={form.enabled}
            onCheckedChange={(checked) => set('enabled', checked)}
            aria-label={t('policyRules.dialog.enabledLabel')}
          />
        </div>

        {error ? <div className="rounded-[10px] bg-[var(--md-sys-color-error-container)] px-3 py-2 text-[11.5px] text-[var(--md-sys-color-on-error-container)]">{error}</div> : null}
      </div>
    </Modal>
  )
}
