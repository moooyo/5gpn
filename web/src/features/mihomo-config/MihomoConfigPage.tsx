import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ChevronDownIcon,
  MenuIcon,
  MyLocationIcon,
  ResetIcon,
  VerifiedIcon,
} from '../../components/icons'
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  DropdownItem,
  DropdownMenu,
  StatusDot,
  toast,
} from '../../components/ds'
import { api } from '../../lib/api/client'
import { ApiError } from '../../lib/api/http'
import type { MihomoConfig } from '../../lib/api/types'
import { relativeTime } from '../../format'
import { cn } from '../../lib/cn'
import i18n from '../../i18n'
import { lineDiff, lineRange, parseErrorLine } from './config-text'

function errMessage(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/** Line box height in px. Shared by the textarea, the gutter and the scroll
 *  maths for "jump to line N", so the three cannot drift a pixel apart.
 *
 *  This only holds while one logical line occupies exactly one line box, which
 *  is why the textarea sets `wrap="off"`. Soft wrapping silently broke both:
 *  the gutter prints one number per logical line, so the first wrapped line
 *  pushed every number below it out of step with the text, and jumpToLine's
 *  `(line - 1) * LINE_HEIGHT` drifted by the accumulated wrap. At a phone width
 *  almost every YAML line wraps, so the gutter was wrong there by default. */
const LINE_HEIGHT = 22

const textareaClass =
  'w-full min-h-[560px] resize-y overflow-x-auto rounded-r-ctl border border-transparent bg-surface-container-low py-4 pl-3 pr-4 font-mono text-body leading-[22px] text-text-strong outline-none transition-[border-color,background-color,box-shadow] focus:border-primary focus:bg-card focus:shadow-[inset_0_0_0_1px_var(--md-sys-color-primary)] disabled:opacity-60'

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
  const [invariantsOpen, setInvariantsOpen] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const gutterRef = useRef<HTMLDivElement | null>(null)
  const dirty = !loading && text !== persistedText

  const errorLine = useMemo(() => parseErrorLine(error), [error])
  const diff = useMemo(() => (dirty ? lineDiff(persistedText, text) : null), [dirty, persistedText, text])
  const lineCount = useMemo(() => text.split('\n').length, [text])

  /** Select the offending line and bring it into view. The number was already
   *  printed in the banner; this is what makes it reachable. */
  const jumpToLine = useCallback((line: number) => {
    const textarea = textareaRef.current
    if (!textarea) return
    const { start, end } = lineRange(text, line)
    textarea.focus()
    textarea.setSelectionRange(start, end)
    const target = (line - 1) * LINE_HEIGHT - textarea.clientHeight / 2 + LINE_HEIGHT
    textarea.scrollTop = Math.max(0, target)
    if (gutterRef.current) gutterRef.current.scrollTop = textarea.scrollTop
  }, [text])

  // A rejection that names no line is almost always a missing infrastructure
  // invariant rather than a YAML syntax error, and that is precisely when the
  // seven-item list is worth reading — so it opens itself only then.
  useEffect(() => {
    if (error && errorLine === null) setInvariantsOpen(true)
  }, [error, errorLine])

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
    <div className="flex flex-col gap-3 md:gap-4" data-testid="page-mihomo-config">
      <p className="px-1 text-label text-text-faint">{t('mihomoConfig.intro')}</p>

      {/* The editor owns the full width. Seven lines of static prose used to
          take half of a 1440px screen at `xl:grid-cols-2`, squeezing several
          hundred lines of YAML into the other half. */}
      <Card className="p-5" data-testid="mihomo-config-editor" data-dirty={dirty ? 'true' : 'false'}>
        <div className="mb-4 flex flex-wrap items-center gap-2 text-label font-medium text-text-mid">
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
          {/* applied_at is the fact an operator acts on; `rev` is an optimistic
              lock token. They used to be the other way round — the token in a
              code block, the timestamp in smaller grey text beside it. */}
          <span className="font-normal text-text-faint">{t('mihomoConfig.appliedAt', { time: relativeTime(appliedAt) })}</span>
          <div className="flex-1" />
          {dirty ? (
            <Badge tone="amber">
              {diff
                ? t('mihomoConfig.unsavedDiff', { added: diff.added, removed: diff.removed })
                : t('mihomoConfig.unsaved')}
            </Badge>
          ) : null}
          {revision ? <span className="font-mono text-meta font-normal text-text-faint">rev {revision.slice(0, 4)}…{revision.slice(-4)}</span> : null}
        </div>

        {error ? (
          <div
            className="mb-3 flex flex-col gap-2 rounded-card bg-[var(--md-sys-color-error-container)] p-3.5 text-label text-[var(--md-sys-color-on-error-container)] sm:flex-row sm:items-center sm:justify-between"
            data-testid="mihomo-config-error"
            role="alert"
          >
            <span className="min-w-0 break-words">{error}</span>
            <div className="flex shrink-0 flex-wrap items-center gap-2">
              {errorLine !== null ? (
                <Button type="button" variant="secondary" size="sm" onClick={() => jumpToLine(errorLine)} data-testid="mihomo-config-jump">
                  <MyLocationIcon className="h-4 w-4" aria-hidden="true" />
                  {t('mihomoConfig.jumpToLine', { line: errorLine })}
                </Button>
              ) : null}
              {conflict ? (
                <Button type="button" variant="secondary" size="sm" onClick={() => setReloadOpen(true)}>
                  {t('mihomoConfig.reloadCurrent')}
                </Button>
              ) : null}
            </div>
          </div>
        ) : null}

        {/* Gutter + textarea share one line box so the numbers stay aligned;
            indentation is the most common YAML mistake and the editor gave no
            way to see which line the validator meant. */}
        <div className="flex overflow-hidden rounded-ctl">
          <div
            ref={gutterRef}
            aria-hidden="true"
            data-testid="mihomo-config-gutter"
            // No max height: the textarea is resize-y, and a capped gutter ran
            // out of numbers as soon as the operator dragged the editor taller.
            // As a flex item it stretches to whatever height the textarea has.
            className="shrink-0 select-none overflow-hidden bg-surface-container py-4 pl-3 pr-2 text-right font-mono text-meta leading-[22px] text-text-faint"
          >
            {Array.from({ length: lineCount }, (_, index) => (
              <div
                key={index}
                className={cn(
                  'tabular-nums',
                  errorLine === index + 1 && 'bg-[var(--md-sys-color-error-container)] font-semibold text-[var(--md-sys-color-on-error-container)]',
                )}
              >
                {index + 1}
              </div>
            ))}
          </div>
          <textarea
            ref={textareaRef}
            className={textareaClass}
            // One logical line per line box — see LINE_HEIGHT. The brief also
            // asks for the offending line to carry an error background; that
            // needs an overlay tracking scrollTop in state, which re-renders a
            // multi-thousand-line document on every scroll frame. The gutter
            // number is tinted instead, and jumping selects the line, so the
            // line is still identified in the body without that cost.
            wrap="off"
            value={text}
            onChange={(e) => {
              setText(e.target.value)
              if (!conflict) setError(null)
            }}
            onScroll={(event) => {
              if (gutterRef.current) gutterRef.current.scrollTop = event.currentTarget.scrollTop
            }}
            disabled={loading}
            spellCheck={false}
            aria-label={t('mihomoConfig.editorLabel')}
            data-testid="mihomo-config-textarea"
          />
        </div>

        {/* Seven read-once facts, folded to one row. It expands on demand, and
            by itself when a rejection names no line — which is what a missing
            invariant looks like. */}
        <div className="mt-4 overflow-hidden rounded-card border border-border" data-testid="mihomo-config-invariants">
          <button
            type="button"
            onClick={() => setInvariantsOpen((open) => !open)}
            aria-expanded={invariantsOpen}
            className="zds-state-layer flex w-full items-center gap-2 px-4 py-3 text-left text-label font-medium text-text-strong"
          >
            <VerifiedIcon className="h-4 w-4 shrink-0 text-green" aria-hidden="true" />
            <span className="min-w-0 flex-1">{t('mihomoConfig.invariantsTitle')}</span>
            <span className="shrink-0 rounded-chip bg-[var(--md-sys-color-success-container)] px-2 py-0.5 font-mono text-meta text-[var(--md-sys-color-on-success-container)]">
              {INVARIANT_KEYS.length} ✓
            </span>
            <ChevronDownIcon className={cn('h-4 w-4 shrink-0 text-text-faint transition-transform', invariantsOpen && 'rotate-180')} aria-hidden="true" />
          </button>
          {invariantsOpen ? (
            <div className="border-t border-divider px-4 pb-2">
              <p className="pt-3 text-meta text-text-faint">{t('mihomoConfig.invariantsHint')}</p>
              <ul className="mt-2 divide-y divide-divider">
                {INVARIANT_KEYS.map((key) => (
                  <li key={key} className="flex items-start gap-3 px-1 py-3 text-label">
                    <VerifiedIcon className="mt-0.5 h-4 w-4 shrink-0 text-green" aria-hidden="true" />
                    <div>
                      <div className="font-medium text-text-strong">{t(`mihomoConfig.invariants.${key}.name`)}</div>
                      <div className="mt-1 leading-5 text-text-faint">{t(`mihomoConfig.invariants.${key}.desc`)}</div>
                    </div>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>

        {/* Pinned below `md`. The editor is 560px tall before the invariants
            panel, so on a phone the row that validates and publishes an edit
            sat past the end of a long scroll from the edit itself. `sticky`
            keeps it inside the card's own column rather than over the page. */}
        <div className={cn(
          'mt-5 flex flex-wrap items-center justify-end gap-2 border-t border-divider pt-4',
          'sticky bottom-0 z-10 bg-card pb-2 md:static md:bg-transparent md:pb-0',
        )} data-testid="mihomo-config-actions">
          {/* Discard is the reversible one, so it stays in the open. Reset —
              which throws away the entire operator-owned config — moved into
              the overflow: it used to sit permanently in the bottom-left
              corner at the same visual weight as a secondary action, at the
              opposite end of the row from Apply. */}
          <Button
            type="button"
            variant="secondary"
            onClick={() => setText(persistedText)}
            disabled={!dirty || applying || resetting}
            data-testid="mihomo-config-discard"
          >
            {t('mihomoConfig.discard')}
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
          <DropdownMenu
            align="end"
            className="w-[280px]"
            trigger={
              <button
                type="button"
                aria-label={t('mihomoConfig.moreActions')}
                className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-soft md:h-ctl md:w-ctl"
              >
                <MenuIcon className="h-4 w-4" aria-hidden="true" />
              </button>
            }
          >
            <DropdownItem
              danger
              onSelect={() => {
                if (loading || !revision || conflict || applying || resetting) return
                setResetOpen(true)
              }}
            >
              <ResetIcon className="h-4 w-4" aria-hidden="true" />
              {resetting ? t('common.saving') : t('mihomoConfig.reset')}
            </DropdownItem>
          </DropdownMenu>
        </div>
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
