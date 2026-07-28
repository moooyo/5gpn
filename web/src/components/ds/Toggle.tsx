import { Switch } from '@base-ui/react/switch'
import { CheckIcon } from '../icons'
import { cn } from '../../lib/cn'

export interface ToggleProps {
  checked: boolean
  onCheckedChange: (checked: boolean) => void
  disabled?: boolean
  className?: string
  title?: string
  'aria-label'?: string
}

/**
 * The switch. Its target is 44px on a phone while the track stays 32px, so the
 * root is a transparent hit box and the track lives in a child.
 *
 * That padding used to come from a `::before` reaching outside the root's own
 * border box, which was wrong in two ways at once. Any ancestor with
 * `overflow-hidden` silently clipped it — the policy-rule list is exactly such
 * a card, so every switch there really was a 32px target — and because a
 * pseudo-element is invisible to `getBoundingClientRect`, nothing could measure
 * the difference. A real box is both honest and un-clippable.
 */
export function Toggle({ checked, onCheckedChange, disabled, className, title, ...aria }: ToggleProps) {
  return (
    <Switch.Root
      nativeButton
      render={<button type="button" />}
      checked={checked}
      onCheckedChange={(next) => onCheckedChange(next)}
      disabled={disabled}
      title={title}
      className={cn(
        'group relative grid h-field w-[52px] shrink-0 cursor-pointer place-items-center border-0 bg-transparent p-0 outline-none md:h-chip',
        'disabled:cursor-not-allowed disabled:opacity-[.38]',
        className,
      )}
      {...aria}
    >
      {/* The track. `pointer-events-none` so every tap lands on the root, which
          is the element that is 44px. */}
      <span
        aria-hidden="true"
        className={cn(
          'pointer-events-none block h-chip w-full rounded-pill border-2 border-outline bg-surface-container-high',
          'transition-[background-color,border-color] duration-150',
          'group-data-checked:border-primary group-data-checked:bg-primary',
        )}
      />
      <Switch.Thumb
        className={cn(
          'pointer-events-none absolute left-1 top-1/2 grid h-4 w-4 -translate-y-1/2 place-items-center rounded-pill bg-outline text-primary',
          'transition-[width,height,translate,background-color] duration-150 data-checked:h-6 data-checked:w-6 data-checked:translate-x-5 data-checked:bg-[var(--md-sys-color-on-primary)]',
        )}
      >
        {checked ? <CheckIcon className="h-3.5 w-3.5" aria-hidden="true" /> : null}
      </Switch.Thumb>
    </Switch.Root>
  )
}
