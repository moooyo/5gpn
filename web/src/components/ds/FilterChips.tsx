import { cn } from '../../lib/cn'

export interface FilterChipOption {
  value: string
  label: string
  /** Categorical slot or semantic colour shown as a leading swatch. */
  swatch?: string
  /** Matches in the current window. Rendered monospace beside the label so a
   *  chip answers "is there anything behind this" before it is clicked. */
  count?: number
}

export interface FilterChipsProps {
  options: FilterChipOption[]
  value: string
  onChange: (value: string) => void
  ariaLabel: string
  /** Horizontal scroll and 44px targets below `sm`, 32px chips above it. */
  scrollOnMobile?: boolean
  outlined?: boolean
  className?: string
}

/**
 * One shape for "pick one of a set of mutually exclusive filters".
 *
 * The console had three: a SegmentedControl on policy rules, square borderless
 * pills on the query log, and outlined round pills on the plugin log — the
 * same interaction wearing three costumes, each with its own height, radius
 * and type size. This is that control; the segmented control keeps its own job
 * (a small, fixed, always-visible set) and everything else routes here.
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
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={selected}
            onClick={() => onChange(option.value)}
            className={cn(
              'zds-state-layer flex h-field shrink-0 items-center gap-2 rounded-chip px-3 text-label font-medium sm:h-chip',
              outlined && 'border border-outline-variant/60 rounded-pill',
              selected ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft',
            )}
          >
            {option.swatch ? (
              <span className="zds-swatch shrink-0" style={{ background: option.swatch }} aria-hidden="true" />
            ) : null}
            {option.label}
            {option.count !== undefined ? (
              <span className="font-mono text-meta tabular-nums opacity-70">{option.count}</span>
            ) : null}
          </button>
        )
      })}
    </div>
  )
}
