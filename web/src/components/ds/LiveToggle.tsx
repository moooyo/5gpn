import { PauseIcon, PlayIcon } from '../icons'
import { cn } from '../../lib/cn'

export interface LiveToggleProps {
  /** True while the view is following the stream. */
  live: boolean
  onToggle: () => void
  /** Label while live, e.g. "live". */
  liveLabel: string
  /**
   * Label while paused. Required, and required to say what pausing DOES to the
   * data — the same button meant three different things across the three log
   * pages (stop polling, buffer and count, silently discard) and nothing on
   * screen distinguished them. A page that cannot answer "what happens to
   * frames that arrive now" should not have this control.
   */
  pausedLabel: string
  pauseAction: string
  resumeAction: string
  className?: string
}

/** The pause/resume pill shared by every live view. */
export function LiveToggle({
  live,
  onToggle,
  liveLabel,
  pausedLabel,
  pauseAction,
  resumeAction,
  className,
}: LiveToggleProps) {
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-label={live ? pauseAction : resumeAction}
      aria-pressed={!live}
      className={cn(
        'zds-state-layer inline-flex h-field shrink-0 items-center gap-2 rounded-pill px-3 text-label font-medium md:h-chip',
        live
          ? 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]'
          : 'bg-surface-container text-text-soft',
        className,
      )}
    >
      {live ? <PauseIcon className="h-4 w-4" aria-hidden="true" /> : <PlayIcon className="h-4 w-4" aria-hidden="true" />}
      {live ? liveLabel : pausedLabel}
    </button>
  )
}
