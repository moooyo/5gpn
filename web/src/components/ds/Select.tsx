import * as DropdownMenuPrimitive from '@radix-ui/react-dropdown-menu'
import { Check, ChevronDown } from 'lucide-react'
import { cn } from '../../lib/cn'

export interface SelectItem {
  value: string
  label: string
}

export interface SelectProps {
  value: string
  onValueChange: (value: string) => void
  items: SelectItem[]
  placeholder?: string
  className?: string
  disabled?: boolean
}

// Built on Radix DropdownMenu rather than @radix-ui/react-select: the latter's
// <Select.Viewport> unconditionally injects a literal <style> element (a
// scrollbar-hider rule) with no way to disable it — a real violation under the
// production `style-src-elem 'self'` CSP. DropdownMenu is already proven to
// inject zero <style> (see overlays.test.tsx) and gives the same keyboard
// nav + type-ahead, so we reimplement Select's public API on top of it.
export function Select({ value, onValueChange, items, placeholder, className, disabled }: SelectProps) {
  const selected = items.find((item) => item.value === value)

  return (
    <DropdownMenuPrimitive.Root>
      <DropdownMenuPrimitive.Trigger
        role="combobox"
        aria-haspopup="listbox"
        disabled={disabled}
        className={cn(
          'flex items-center justify-between gap-2 rounded-[10px] border border-input-border bg-input px-3 py-2 text-[13px] outline-none transition-colors',
          'data-[state=open]:border-primary/45 data-[state=open]:bg-card',
          disabled && 'cursor-not-allowed opacity-50',
          className,
        )}
      >
        <span className={cn('truncate', !selected && 'text-text-faint')}>{selected ? selected.label : placeholder}</span>
        <ChevronDown className="h-4 w-4 shrink-0 text-text-soft transition-transform data-[state=open]:rotate-180" />
      </DropdownMenuPrimitive.Trigger>
      <DropdownMenuPrimitive.Portal>
        <DropdownMenuPrimitive.Content
          role="listbox"
          align="start"
          sideOffset={6}
          style={{ minWidth: 'max(var(--radix-dropdown-menu-trigger-width), 9rem)' }}
          className="ds-pop-in z-50 max-h-[min(18rem,var(--radix-dropdown-menu-content-available-height))] overflow-y-auto rounded-[12px] border border-border bg-card p-1.5 shadow-pop"
        >
          {items.map((item) => {
            const isSelected = item.value === value
            return (
              <DropdownMenuPrimitive.Item
                key={item.value}
                role="option"
                aria-selected={isSelected}
                onSelect={() => onValueChange(item.value)}
                className={cn(
                  'flex cursor-pointer items-center justify-between gap-3 rounded-[8px] px-2.5 py-2 text-[13px] outline-none transition-colors',
                  'data-[highlighted]:bg-input',
                  isSelected ? 'font-semibold text-primary' : 'text-text-mid',
                )}
              >
                <span className="truncate">{item.label}</span>
                {isSelected && <Check className="h-4 w-4 shrink-0 text-primary" />}
              </DropdownMenuPrimitive.Item>
            )
          })}
        </DropdownMenuPrimitive.Content>
      </DropdownMenuPrimitive.Portal>
    </DropdownMenuPrimitive.Root>
  )
}
