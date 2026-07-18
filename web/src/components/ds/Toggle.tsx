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
        'relative h-8 w-[52px] shrink-0 cursor-pointer rounded-full border-2 border-outline bg-surface-container-high p-0 outline-none',
        'transition-[background-color,border-color] duration-150 data-checked:border-primary data-checked:bg-primary',
        'disabled:cursor-not-allowed disabled:opacity-[.38]',
        className,
      )}
      {...aria}
    >
      <Switch.Thumb
        className={cn(
          'absolute left-1 top-1/2 grid h-4 w-4 -translate-y-1/2 place-items-center rounded-full bg-outline text-primary',
          'transition-[width,height,translate,background-color] duration-150 data-checked:h-6 data-checked:w-6 data-checked:translate-x-5 data-checked:bg-[var(--md-sys-color-on-primary)]',
        )}
      >
        {checked ? <CheckIcon className="h-3.5 w-3.5" aria-hidden="true" /> : null}
      </Switch.Thumb>
    </Switch.Root>
  )
}
