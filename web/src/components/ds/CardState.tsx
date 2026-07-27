import type { ReactNode } from 'react'
import { Button } from './Button'
import { cn } from '../../lib/cn'

export type CardLoadState = 'loading' | 'ready' | 'error'

/**
 * The three states a config card can be in, in one place.
 *
 * Every settings card used to answer this question for itself, and answer it
 * differently: two of them had a real three-state (a loading row, an error row
 * with a retry button, then the content), while the rest rendered their
 * controls against `undefined` — an empty input and a disabled button, which
 * looks exactly like a card whose value is genuinely empty. A card that cannot
 * be told apart from a loaded one while it is still loading is a card that
 * lies about the system.
 *
 * The loading and error rows are BANNERS, not replacements: the content stays
 * mounted underneath. That is deliberate and matches what the two cards that
 * already had a three-state did — a failed reload must not take away controls
 * the operator can still read.
 */
export interface CardStateProps {
  state: CardLoadState
  /** Shown in the error row. */
  errorText: ReactNode
  /** Omit when there is nothing useful to retry. */
  onRetry?: () => void
  retryLabel: string
  loadingText: string
  /** Suppress the loading row once stale-but-usable content exists, so a
   *  background refresh does not flash a banner over a populated card. */
  hasContent?: boolean
  /** Render the loading state as N skeleton rows instead of a text row, for a
   *  card whose content is a fixed set of fields. A card that showed a skeleton
   *  and nothing else could not report a failure at all — which is how two of
   *  them ended up sitting on a skeleton forever when their one load rejected. */
  skeletonRows?: number
  className?: string
  testId?: string
}

export function CardState({
  state,
  errorText,
  onRetry,
  retryLabel,
  loadingText,
  hasContent = false,
  skeletonRows,
  className,
  testId,
}: CardStateProps) {
  if (state === 'loading' && !hasContent) {
    if (skeletonRows !== undefined) return <CardSkeleton rows={skeletonRows} className={className} />
    return (
      <div role="status" className={cn('rounded-card bg-surface-container-low px-4 py-4 text-meta text-text-faint', className)}>
        {loadingText}
      </div>
    )
  }
  if (state === 'error') {
    return (
      <div
        role="alert"
        data-testid={testId}
        className={cn(
          'flex flex-col gap-2 rounded-card bg-[var(--md-sys-color-error-container)] px-4 py-3 text-meta text-[var(--md-sys-color-on-error-container)] sm:flex-row sm:items-center sm:justify-between',
          className,
        )}
      >
        <span>{errorText}</span>
        {onRetry ? (
          <Button type="button" variant="secondary" size="sm" onClick={onRetry}>
            {retryLabel}
          </Button>
        ) : null}
      </div>
    )
  }
  return null
}

/**
 * Placeholder rows for a card whose data has not arrived. Used by the cards
 * that previously rendered live controls bound to `undefined`, where an empty
 * field was indistinguishable from a field whose value really is empty.
 */
export function CardSkeleton({ rows = 2, className }: { rows?: number; className?: string }) {
  return (
    <div role="status" aria-busy="true" className={cn('flex flex-col gap-2.5', className)} data-testid="card-skeleton">
      {Array.from({ length: rows }, (_, index) => (
        <span
          key={index}
          aria-hidden="true"
          className="ds-pulse block h-field rounded-ctl bg-surface-container-low"
          style={{ width: index === rows - 1 ? '62%' : '100%' }}
        />
      ))}
    </div>
  )
}
