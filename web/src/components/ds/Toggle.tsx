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
        'relative h-[19px] w-[34px] shrink-0 cursor-pointer rounded-full bg-input-border outline-none transition-colors',
        'data-[state=checked]:bg-primary',
        'disabled:cursor-not-allowed disabled:opacity-50',
        className,
      )}
      {...aria}
    >
      <SwitchPrimitive.Thumb className="block h-[15px] w-[15px] shrink-0 translate-x-[2px] rounded-full bg-white shadow-sm transition-transform data-[state=checked]:translate-x-[17px]" />
    </SwitchPrimitive.Root>
  )
}
