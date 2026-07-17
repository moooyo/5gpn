import * as SwitchPrimitive from '@radix-ui/react-switch'
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
    <SwitchPrimitive.Root
      checked={checked}
      onCheckedChange={onCheckedChange}
      disabled={disabled}
      title={title}
      className={cn(
        'relative h-6 w-10 shrink-0 cursor-pointer rounded-full bg-input-border p-1 outline-none transition-colors',
        'focus-visible:ring-2 focus-visible:ring-primary/35',
        'data-[state=checked]:bg-primary',
        'disabled:cursor-not-allowed disabled:opacity-50',
        className,
      )}
      {...aria}
    >
      <SwitchPrimitive.Thumb className="block h-4 w-4 shrink-0 translate-x-0 rounded-full bg-white shadow-sm transition-transform data-[state=checked]:translate-x-4" />
    </SwitchPrimitive.Root>
  )
}
