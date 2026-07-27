import type { ReactNode } from 'react'
import { Card } from './Card'
import { Input } from './Field'
import { SearchIcon } from '../icons'
import { cn } from '../../lib/cn'

/**
 * One height policy for every log list: a viewport-relative band with a floor
 * and a ceiling. `chrome` is the vertical space the PAGE spends above and
 * below this card.
 *
 * The three log pages carried three near-identical clamps differing by 10–20px
 * for no stated reason, and one of them sized its table by row count instead —
 * so that page grew taller with every frame that arrived and never settled.
 */
export function logSurfaceHeight(chrome: number): string {
  return `clamp(280px, calc(100dvh - ${chrome}px), 560px)`
}

export interface LogSearchFieldProps {
  value: string
  onChange: (value: string) => void
  /** Accessible name. Required, not optional: two of the three log searches
   *  shipped with only a placeholder, which is not an accessible name. */
  label: string
  placeholder: string
  /** Row-level sizing only — the caller supplies `flex-1` or a fixed width.
   *  Deliberately NOT carried on the root: `flex-1` and `w-64` are different
   *  tailwind-merge groups, so a base `flex-1` would survive a caller's width
   *  and `flex-basis: 0%` would win the layout anyway. */
  className?: string
}

/**
 * The search input every log toolbar uses. Three hand-rolled copies differed in
 * height (31/36/44px), icon inset and background.
 *
 * Height is a flat `h-field` (44px) with no responsive step, which is the
 * handoff's rule for inputs at every width. This component used to be the only
 * place that dodged the breakpoint trap on purpose — the pages branch on `md`
 * (767px) while Tailwind's `sm` is 640px, so a step-down written at `sm` shrank
 * a control to its desktop size inside a still-mobile layout. Every step-down
 * moved to `md`, and `styles/scale.test.ts` now fails one written at `sm`, so
 * this input is flat because inputs are flat rather than to avoid a hazard.
 */
export function LogSearchField({ value, onChange, label, placeholder, className }: LogSearchFieldProps) {
  return (
    <div className={cn('relative min-w-0', className)}>
      <SearchIcon className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" />
      <Input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-label={label}
        placeholder={placeholder}
        className="h-field w-full rounded-pill bg-card pl-9 text-label"
      />
    </div>
  )
}

export interface LogSurfaceProps {
  /**
   * Vertical space the page spends above and below this card. LogSurface is
   * the only caller of `logSurfaceHeight` on an adopting page and hands the
   * result to `children`, so a page can no longer size a log list by row count
   * or invent its own clamp. Hand-maintained: add a row above the card, raise
   * this.
   */
  chrome: number
  /** Row 1. Omit for a card that starts at the toolbar. */
  title?: ReactNode
  /** Monospace pill beside the title — rows currently listed. */
  count?: number
  /**
   * Pause / clear. Placement is a rule, not a flag: the title row when there is
   * a title, the toolbar row otherwise — which is exactly where the adopting
   * pages put them today. A page wanting both a title and toolbar-row actions
   * has no way to say so, deliberately.
   */
  actions?: ReactNode
  /** Toolbar lead: filter chips, selects. */
  filters?: ReactNode
  /** Toolbar middle, grows to fill. Normally a <LogSearchField>. */
  search?: ReactNode
  /**
   * Full-bleed row between the toolbar and the list, rendered VERBATIM with no
   * wrapper. The caller owns its tone, role and padding, because "disconnected"
   * is a tonal banner with a reconnect button on one page and a bordered dot
   * row on the other — and a wrapper would stop the banner's container
   * background from spanning the card.
   */
  status?: ReactNode
  isEmpty?: boolean
  /** Replaces the list. Never gets the fixed height — an empty state that
   *  reserves 560px reads as a list that failed to paint. */
  empty?: ReactNode
  footer?: ReactNode
  footerMeta?: ReactNode
  /**
   * Render prop, not a node: the list must stay a DIRECT child of the card
   * element (e2e/mobile-plugin-logs.spec.ts asserts `virtual-scroll`'s parent
   * carries `card`), so the height cannot be applied by a wrapper here.
   */
  children: (height: string) => ReactNode
  className?: string
  testId?: string
}

/**
 * The shared chrome of a log page: title row, toolbar row, status slot, list,
 * footer — and one height policy.
 *
 * The three log pages had three of everything: three toolbars with different
 * padding, three empty/list ternaries, three footers, three hand-tuned height
 * clamps, and three search inputs at three heights. What they do NOT share is
 * what pausing means to their data, so this component has no `paused`, `live`,
 * `onClear` or `connected` prop and never renders a LiveToggle — it reserves
 * the slot those controls sit in and nothing more.
 *
 * The query log deliberately does not adopt this shell: its toolbar lives in a
 * separate tonal card, its pause sits in the page header, it has no clear and
 * no footer, and its body is a four-way state. It takes only LogSearchField
 * and the height policy.
 */
export function LogSurface({
  chrome,
  title,
  count,
  actions,
  filters,
  search,
  status,
  isEmpty = false,
  empty,
  footer,
  footerMeta,
  children,
  className,
  testId,
}: LogSurfaceProps) {
  const actionsOnToolbar = title === undefined && actions !== undefined
  const hasToolbar = filters !== undefined || search !== undefined || actionsOnToolbar

  return (
    <Card className={cn('overflow-hidden p-0 shadow-none', className)} data-testid={testId}>
      {title !== undefined ? (
        <div className="flex items-center gap-2.5 border-b border-divider px-3.5 py-3 md:px-[18px]">
          <span className="text-title font-semibold text-text-strong">{title}</span>
          {count !== undefined ? (
            <span className="rounded-pill bg-surface-container-low px-2 py-0.5 font-mono text-meta text-text-soft">{count}</span>
          ) : null}
          <div className="min-w-2 flex-1" />
          {actions}
        </div>
      ) : null}

      {hasToolbar ? (
        <div className="flex flex-col gap-2 border-b border-divider bg-bg px-3.5 py-2.5 sm:flex-row sm:items-center md:px-[18px]">
          {filters}
          {search}
          {actionsOnToolbar ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
        </div>
      ) : null}

      {status}

      {/* One child position, so toggling empty remounts the list exactly as the
          inline ternaries it replaces did. Rendering both and hiding one would
          keep a virtualizer mounted against a zero-height viewport. */}
      {isEmpty ? empty : children(logSurfaceHeight(chrome))}

      {footer !== undefined ? (
        <div className="flex items-center justify-between gap-3 border-t border-divider px-3.5 py-2 text-meta text-text-faint md:px-[18px]">
          <span>{footer}</span>
          {footerMeta !== undefined ? <span className="font-mono">{footerMeta}</span> : null}
        </div>
      ) : null}
    </Card>
  )
}
