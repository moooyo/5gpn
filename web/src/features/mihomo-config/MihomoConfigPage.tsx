import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { RotateCcw, ShieldCheck } from 'lucide-react'
import { Badge, Button, Card, CardHeader, ConfirmDialog, StatusDot, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { relativeTime } from '../../format'
import i18n from '../../i18n'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

const textareaClass =
  'w-full min-h-[440px] resize-y rounded-[10px] border border-input-border bg-input px-3 py-2.5 font-mono text-[12px] leading-relaxed text-text-strong outline-none disabled:opacity-60'

// The design doc's §4.4 table, in order — kept as data so the JSX below is a
// plain map rather than seven near-identical <li> blocks.
const INVARIANT_KEYS = ['controller', 'sniproxy', 'dns', 'console', 'zash', 'profile', 'antiloop'] as const

/** mihomo config editor (UP-4 §4, Task 11) — the operator edits the WHOLE
 *  effective mihomo config as one raw-text document (`/api/mihomo/config`).
 *  There is no daemon-owned region left to protect (the structured egress
 *  projection is gone) — instead the server enforces seven infrastructure
 *  invariants (§4.4, listed read-only below) it will refuse to let an edit
 *  delete, because those are the box's own lifelines: the controller, the
 *  sniproxy inbound, our DNS steering broker, the console/zash/profile SNI
 *  split, and the anti-loop guard. A rejected PUT/reset comes back as a 400 whose
 *  message names the missing invariant or carries `mihomo -t`'s stderr
 *  verbatim; that message is surfaced as a PERSISTENT banner (not just a
 *  toast, which auto-dismisses) and the editor's text is left exactly as
 *  the operator typed it — they need to fix it and resubmit, never lose
 *  the edit. */
export default function MihomoConfigPage() {
  const { t } = useTranslation()
  const [text, setText] = useState('')
  const [persistedText, setPersistedText] = useState('')
  const [loading, setLoading] = useState(true)
  const [appliedAt, setAppliedAt] = useState<string | undefined>(undefined)
  const [controllerReachable, setControllerReachable] = useState(false)
  const [controllerAuthenticated, setControllerAuthenticated] = useState(false)
  const [applying, setApplying] = useState(false)
  const [resetting, setResetting] = useState(false)
  const [resetOpen, setResetOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const dirty = !loading && text !== persistedText

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const cfg = await api.getMihomoConfig()
      setText(cfg.text)
      setPersistedText(cfg.text)
      setAppliedAt(cfg.applied_at)
      setControllerReachable(cfg.controller_reachable)
      setControllerAuthenticated(cfg.controller_authenticated)
    } catch (err) {
      // Read the current catalog at failure time without making the data
      // loader depend on useTranslation()'s `t` identity. A language change
      // must never re-fetch and overwrite an operator's in-progress YAML.
      toast.error(errMessage(err, i18n.t('mihomoConfig.loadFailed')))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => void load(), [load])

  useEffect(() => {
    if (!dirty) return
    const guard = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', guard)
    return () => window.removeEventListener('beforeunload', guard)
  }, [dirty])

  async function handleApply() {
    const submittedText = text
    setApplying(true)
    setError(null)
    try {
      const cfg = await api.putMihomoConfig(submittedText)
      // If the operator keeps typing while PUT is in flight, preserve that
      // newer text: only move the persisted baseline to what was submitted.
      setPersistedText(submittedText)
      setAppliedAt(cfg.applied_at)
      setControllerReachable(cfg.controller_reachable)
      setControllerAuthenticated(cfg.controller_authenticated)
      toast.success(t('mihomoConfig.applyOk'))
    } catch (err) {
      // Deliberately does NOT touch `text` — a rejected apply must never
      // clobber the operator's in-progress edit (see the header comment).
      const message = errMessage(err, t('mihomoConfig.applyFailed'))
      setError(message)
      toast.error(message)
    } finally {
      setApplying(false)
    }
  }

  async function handleReset() {
    setResetting(true)
    setError(null)
    try {
      const cfg = await api.resetMihomoConfig()
      setText(cfg.text)
      setPersistedText(cfg.text)
      setAppliedAt(cfg.applied_at)
      setControllerReachable(cfg.controller_reachable)
      setControllerAuthenticated(cfg.controller_authenticated)
      toast.success(t('mihomoConfig.resetOk'))
    } catch (err) {
      const message = errMessage(err, t('mihomoConfig.resetFailed'))
      setError(message)
      toast.error(message)
    } finally {
      setResetting(false)
    }
  }

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-mihomo-config">
      <p className="text-[12.5px] text-text-faint">{t('mihomoConfig.intro')}</p>

      <Card className="p-[18px]" data-testid="mihomo-config-editor" data-dirty={dirty ? 'true' : 'false'}>
        <div className="mb-3 flex flex-wrap items-center gap-2 text-[11.5px] font-semibold text-text-mid">
          <div className="flex items-center gap-1.5">
            <StatusDot
              color={!controllerReachable ? '#dc2626' : controllerAuthenticated ? '#16a34a' : '#d97706'}
              pulse={controllerReachable && controllerAuthenticated}
            />
            {!controllerReachable
              ? t('mihomoConfig.controllerUnreachable')
              : controllerAuthenticated
                ? t('mihomoConfig.controllerReachable')
                : t('mihomoConfig.controllerUnauthenticated')}
          </div>
          <span className="text-text-faint">·</span>
          <span className="font-normal text-text-faint">{t('mihomoConfig.appliedAt', { time: relativeTime(appliedAt) })}</span>
        </div>

        <div className="mb-1.5 text-[11px] font-semibold text-text-mid">{t('mihomoConfig.editorLabel')}</div>
        <textarea
          className={textareaClass}
          value={text}
          onChange={(e) => {
            setText(e.target.value)
            setError(null)
          }}
          disabled={loading}
          spellCheck={false}
          aria-label={t('mihomoConfig.editorLabel')}
          data-testid="mihomo-config-textarea"
        />

        {error ? (
          <div
            className="mt-2 rounded-[10px] border border-red/30 bg-red/10 p-3 text-[11.5px] text-red"
            data-testid="mihomo-config-error"
          >
            {error}
          </div>
        ) : null}

        <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-divider pt-3.5">
          <Button
            type="button"
            variant="secondary"
            onClick={() => setResetOpen(true)}
            disabled={loading || applying || resetting}
            data-testid="mihomo-config-reset"
          >
            <RotateCcw className="h-3.5 w-3.5" aria-hidden="true" />
            {resetting ? t('common.saving') : t('mihomoConfig.reset')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleApply()}
            disabled={loading || applying || resetting}
            data-testid="mihomo-config-apply"
          >
            <ShieldCheck className="h-3.5 w-3.5" aria-hidden="true" />
            {applying ? t('mihomoConfig.applying') : t('mihomoConfig.apply')}
          </Button>
        </div>
      </Card>

      <Card>
        <CardHeader title={t('mihomoConfig.invariantsTitle')} />
        <ul className="flex flex-col gap-2 p-4">
          {INVARIANT_KEYS.map((key) => (
            <li key={key} className="flex flex-wrap items-baseline gap-2 text-[11.5px]">
              <Badge tone="neutral">{t(`mihomoConfig.invariants.${key}.name`)}</Badge>
              <span className="text-text-faint">{t(`mihomoConfig.invariants.${key}.desc`)}</span>
            </li>
          ))}
        </ul>
      </Card>

      <ConfirmDialog
        open={resetOpen}
        onOpenChange={setResetOpen}
        title={t('mihomoConfig.resetConfirmTitle')}
        description={t('mihomoConfig.resetConfirmBody')}
        confirmLabel={t('mihomoConfig.reset')}
        cancelLabel={t('common.cancel')}
        danger
        onConfirm={() => void handleReset()}
      />
    </div>
  )
}
