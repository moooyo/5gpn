import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

export interface FilterChipOption {
  value: string
  label: string
  /** Categorical slot or semantic colour shown as a leading swatch. */
  swatch?: string
  /** Matches in the current window. Rendered monospace beside the label so a
   *  chip answers "is there anything behind this" before it is clicked. */
  count?: number
  /** Status dot drawn before the label — a property of the thing being filtered
   *  on (a stale marketplace source), not of the filter. */
  dot?: string
  /** Rides inside the chip, after the label, and is NOT part of the button:
   *  a per-chip menu whose click must not also change the filter. */
  trailing?: ReactNode
  /** Native tooltip for the chip's button. */
  title?: string
  /** Announced with the label for a status a swatch alone cannot carry. */
  srLabel?: string
}

export interface FilterChipsProps {
  options: FilterChipOption[]
  value: string
  onChange: (value: string) => void
  ariaLabel: string
  /** Horizontal scroll and 44px targets below `sm`, 32px chips above it. */
  scrollOnMobile?: boolean
  outlined?: boolean
  /** Larger, outlined chips for a short set that heads a page rather than
   *  sitting inside a toolbar. Still steps to 44px on mobile. */
  size?: 'sm' | 'md'
  className?: string
}

/**
 * One shape for "pick one of a set of mutually exclusive filters".
 *
 * The console had three: a SegmentedControl on policy rules, square borderless
 * pills on the query log, and outlined round pills on the plugin log — the
 * same interaction wearing three costumes, each with its own height, radius
 * and type size. This is that control.
 *
 * Two shapes stay out of it, both deliberately:
 * - The SegmentedControl on policy rules keeps its own job — a small, fixed,
 *   always-visible set where every option is worth showing as one control.
 * - The resolve test's recent-lookup row LOOKS like this and is not: clicking
 *   an entry re-shows a past result rather than filtering anything, and its
 *   `aria-pressed` marks which result is on screen. Routing it here would make
 *   a history read as a filter.
 * Everything that actually filters routes here, including the marketplace's
 * source chips, which is what `trailing` and `dot` exist for.
 *
 * Colour comes from the caller because only the caller knows whether it is
 * naming a category (chart slot) or a state (semantic role) — the distinction
 * that made five decisions render in three colours when it was ignored.
 */
export function FilterChips({
  options,
  value,
  onChange,
  ariaLabel,
  scrollOnMobile = true,
  outlined = false,
  size = 'sm',
  className,
}: FilterChipsProps) {
  return (
    <div
      role="group"
      aria-label={ariaLabel}
      className={cn(
        'flex items-center gap-1.5',
        scrollOnMobile
          ? '-mx-1 overflow-x-auto px-1 pb-1 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0 sm:pb-0'
          : 'flex-wrap',
        className,
      )}
    >
      {options.map((option) => {
        const selected = option.value === value
        // The chip box and the button that changes the filter are the same
        // element, unless something else has to sit inside the chip without
        // inheriting its click — then the box wraps and the button shrinks to
        // its own content.
        const box = cn(
          'h-field shrink-0 md:h-chip',
          size === 'md' ? 'rounded-pill px-4.5 text-body md:h-ctl' : 'rounded-chip px-3 text-label',
          outlined && size !== 'md' && 'rounded-pill border border-outline-variant/60',
          size === 'md' && 'border border-outline-variant/60',
          'font-medium',
          selected ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft',
        )
        const chip = (
          <button
            type="button"
            aria-pressed={selected}
            onClick={() => onChange(option.value)}
            title={option.title}
            className={cn(
              'zds-state-layer flex shrink-0 items-center gap-2 outline-none',
              // With a trailing slot the wrapper carries the chip's box, but
              // the button still has to fill it — otherwise the visible chip is
              // 44px while the part that actually changes the filter is as
              // short as its own text.
              option.trailing ? 'h-full min-w-0' : box,
            )}
          >
            {option.dot ? <span className="h-2 w-2 shrink-0 rounded-pill" style={{ background: option.dot }} aria-hidden="true" /> : null}
            {option.swatch ? (
              <span className="zds-swatch shrink-0" style={{ background: option.swatch }} aria-hidden="true" />
            ) : null}
            <span className="min-w-0 truncate">{option.label}</span>
            {option.count !== undefined ? (
              <span className={cn('font-mono text-meta tabular-nums', selected ? 'opacity-80' : 'opacity-70')}>{option.count}</span>
            ) : null}
            {option.srLabel ? <span className="sr-only">{option.srLabel}</span> : null}
          </button>
        )
        if (!option.trailing) return <div key={option.value} className="contents">{chip}</div>
        return (
          <span key={option.value} className={cn('inline-flex items-center pr-1', box)}>
            {chip}
            {option.trailing}
          </span>
        )
      })}
    </div>
  )
}
