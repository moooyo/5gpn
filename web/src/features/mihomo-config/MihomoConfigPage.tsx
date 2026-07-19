import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ResetIcon, VerifiedIcon } from '../../components/icons'
import { Badge, Button, Card, ConfirmDialog, StatusDot, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { ApiError } from '../../lib/api/http'
import type { MihomoConfig } from '../../lib/api/types'
import { relativeTime } from '../../format'
import i18n from '../../i18n'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

const textareaClass =
  'w-full min-h-[430px] resize-y rounded-[12px] border border-transparent bg-surface-container-low px-4 py-4 font-mono text-[12.5px] leading-[1.7] text-text-strong outline-none transition-[border-color,background-color,box-shadow] focus:border-primary focus:bg-card focus:shadow-[inset_0_0_0_1px_var(--md-sys-color-primary)] disabled:opacity-60'

// Kept as data so the JSX below is a plain map rather than seven near-identical
// list items.
const INVARIANT_KEYS = ['controller', 'secret', 'gateway', 'dns', 'console', 'zash', 'antiloop'] as const

/** The operator edits the complete effective mihomo config as one raw-text
 *  document (`/api/mihomo/config`). The server enforces seven infrastructure
 *  invariants, listed read-only below, and refuses to let an edit
 *  delete, because those are the box's own lifelines: the controller, the
 *  gateway ingress, our DNS steering broker, the console/zash SNI
 *  split, and the anti-loop guard. PUT/reset also carry the exact-byte
 *  revision loaded with the editor so another raw or module edit produces a
 *  409 rather than a lost update. A validation rejection names the missing
 *  invariant or carries `mihomo -t`'s stderr verbatim; that message is
 *  surfaced as a PERSISTENT banner (not just a
 *  toast, which auto-dismisses) and the editor's text is left exactly as
 *  the operator typed it — they need to fix it and resubmit, never lose
 *  the edit. */
export default function MihomoConfigPage() {
  const { t } = useTranslation()
  const [text, setText] = useState('')
  const [persistedText, setPersistedText] = useState('')
  const [revision, setRevision] = useState('')
  const [loading, setLoading] = useState(true)
  const [appliedAt, setAppliedAt] = useState<string | undefined>(undefined)
  const [controllerReachable, setControllerReachable] = useState(false)
  const [controllerAuthenticated, setControllerAuthenticated] = useState(false)
  const [applying, setApplying] = useState(false)
  const [resetting, setResetting] = useState(false)
  const [resetOpen, setResetOpen] = useState(false)
  const [reloadOpen, setReloadOpen] = useState(false)
  const [conflict, setConflict] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const dirty = !loading && text !== persistedText

  const acceptSnapshot = useCallback((cfg: MihomoConfig, replaceEditor: boolean) => {
    if (replaceEditor) setText(cfg.text)
    setPersistedText(cfg.text)
    setRevision(cfg.revision)
    setAppliedAt(cfg.applied_at)
    setControllerReachable(cfg.controller_reachable)
    setControllerAuthenticated(cfg.controller_authenticated)
  }, [])

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const cfg = await api.getMihomoConfig()
      acceptSnapshot(cfg, true)
      setConflict(false)
      setError(null)
    } catch (err) {
      // Read the current catalog at failure time without making the data
      // loader depend on useTranslation()'s `t` identity. A language change
      // must never re-fetch and overwrite an operator's in-progress YAML.
      toast.error(errMessage(err, i18n.t('mihomoConfig.loadFailed')))
    } finally {
      setLoading(false)
    }
  }, [acceptSnapshot])
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
      const cfg = await api.putMihomoConfig(submittedText, revision)
      // If the operator keeps typing while PUT is in flight, preserve that
      // newer text: only move the persisted baseline to what was submitted.
      acceptSnapshot(cfg, false)
      setConflict(false)
      toast.success(t('mihomoConfig.applyOk'))
    } catch (err) {
      // Deliberately does NOT touch `text` — a rejected apply must never
      // clobber the operator's in-progress edit (see the header comment).
      const revisionConflict = err instanceof ApiError && err.status === 409
      let requiresReload = revisionConflict
      if (err instanceof ApiError && err.status === 502) {
        try {
          const current = await api.getMihomoConfig()
          if (current.text === submittedText) {
            acceptSnapshot(current, false)
          } else {
            requiresReload = true
          }
        } catch {
          // Keep the submitted editor text and old snapshot if the follow-up
          // read also fails. The persistent apply error remains visible.
          requiresReload = true
        }
      }
      setConflict(requiresReload)
      const message = revisionConflict
        ? t('mihomoConfig.revisionConflict')
        : errMessage(err, t('mihomoConfig.applyFailed'))
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
      const cfg = await api.resetMihomoConfig(revision)
      acceptSnapshot(cfg, true)
      setConflict(false)
      toast.success(t('mihomoConfig.resetOk'))
    } catch (err) {
      const revisionConflict = err instanceof ApiError && err.status === 409
      let requiresReload = revisionConflict
      if (err instanceof ApiError && err.status === 502) {
        try {
          acceptSnapshot(await api.getMihomoConfig(), true)
        } catch {
          // Preserve the current editor when the final on-disk state cannot
          // be read after a failed controller reload.
          requiresReload = true
        }
      }
      setConflict(requiresReload)
      const message = revisionConflict
        ? t('mihomoConfig.revisionConflict')
        : errMessage(err, t('mihomoConfig.resetFailed'))
      setError(message)
      toast.error(message)
    } finally {
      setResetting(false)
    }
  }

  return (
    <div className="flex flex-col gap-4" data-testid="page-mihomo-config">
      <p className="px-1 text-[12.5px] leading-5 text-text-faint">{t('mihomoConfig.intro')}</p>

      <div className="grid gap-4 xl:grid-cols-2 xl:items-start">
      <Card className="p-5" data-testid="mihomo-config-editor" data-dirty={dirty ? 'true' : 'false'}>
        <div className="mb-4 flex flex-wrap items-center gap-2 text-[11.5px] font-medium text-text-mid">
          <div className="flex items-center gap-1.5">
            <StatusDot
              color={!controllerReachable ? 'var(--color-red)' : controllerAuthenticated ? 'var(--color-green)' : 'var(--color-amber)'}
            />
            {!controllerReachable
              ? t('mihomoConfig.controllerUnreachable')
              : controllerAuthenticated
                ? t('mihomoConfig.controllerReachable')
                : t('mihomoConfig.controllerUnauthenticated')}
          </div>
          <span className="text-text-faint">·</span>
          <span className="font-normal text-text-faint">{t('mihomoConfig.appliedAt', { time: relativeTime(appliedAt) })}</span>
          <div className="flex-1" />
          {dirty ? <Badge tone="amber">{t('mihomoConfig.unsaved')}</Badge> : null}
          {revision ? <code className="rounded-[7px] bg-surface-container px-2.5 py-1 font-mono text-[10px] text-text-faint">rev {revision.slice(0, 4)}…{revision.slice(-4)}</code> : null}
        </div>

        <textarea
          className={textareaClass}
          value={text}
          onChange={(e) => {
            setText(e.target.value)
            if (!conflict) setError(null)
          }}
          disabled={loading}
          spellCheck={false}
          aria-label={t('mihomoConfig.editorLabel')}
          data-testid="mihomo-config-textarea"
        />

        {error ? (
          <div
            className="mt-3 flex flex-col gap-2 rounded-[14px] bg-[var(--md-sys-color-error-container)] p-3.5 text-[11.5px] text-[var(--md-sys-color-on-error-container)] sm:flex-row sm:items-center sm:justify-between"
            data-testid="mihomo-config-error"
            role="alert"
          >
            <span>{error}</span>
            {conflict ? (
              <Button type="button" variant="secondary" size="sm" onClick={() => setReloadOpen(true)}>
                {t('mihomoConfig.reloadCurrent')}
              </Button>
            ) : null}
          </div>
        ) : null}

        <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-divider pt-4">
          <Button
            type="button"
            variant="secondary"
            onClick={() => setResetOpen(true)}
            disabled={loading || !revision || conflict || applying || resetting}
            data-testid="mihomo-config-reset"
          >
            <ResetIcon className="h-4 w-4" aria-hidden="true" />
            {resetting ? t('common.saving') : t('mihomoConfig.reset')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleApply()}
            disabled={loading || !revision || conflict || applying || resetting}
            data-testid="mihomo-config-apply"
          >
            <VerifiedIcon className="h-4 w-4" aria-hidden="true" />
            {applying ? t('mihomoConfig.applying') : t('mihomoConfig.apply')}
          </Button>
        </div>
      </Card>

      <Card className="p-5">
        <h2 className="text-[15px] font-medium text-text-strong">{t('mihomoConfig.invariantsTitle')}</h2>
        <p className="mt-1 text-[11px] text-text-faint">{t('mihomoConfig.invariantsHint')}</p>
        <ul className="mt-4 divide-y divide-divider">
          {INVARIANT_KEYS.map((key) => (
            <li key={key} className="flex items-start gap-3 px-1 py-3.5 text-[11.5px]">
              <VerifiedIcon className="mt-0.5 h-4 w-4 shrink-0 text-green" aria-hidden="true" />
              <div>
                <div className="font-medium text-text-strong">{t(`mihomoConfig.invariants.${key}.name`)}</div>
                <div className="mt-1 leading-5 text-text-faint">{t(`mihomoConfig.invariants.${key}.desc`)}</div>
              </div>
            </li>
          ))}
        </ul>
      </Card>
      </div>

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
      <ConfirmDialog
        open={reloadOpen}
        onOpenChange={setReloadOpen}
        title={t('mihomoConfig.reloadConfirmTitle')}
        description={t('mihomoConfig.reloadConfirmBody')}
        confirmLabel={t('mihomoConfig.reloadCurrent')}
        cancelLabel={t('common.cancel')}
        onConfirm={() => void load()}
      />
    </div>
  )
}
