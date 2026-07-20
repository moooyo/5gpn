import { Select as BaseSelect } from '@base-ui/react/select'
import { CSPProvider } from '@base-ui/react/csp-provider'
import { CheckIcon, ChevronDownIcon } from '../icons'
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
  ariaLabel?: string
}

export function Select({ value, onValueChange, items, placeholder, className, disabled, ariaLabel }: SelectProps) {
  return (
    <CSPProvider disableStyleElements>
    <BaseSelect.Root
      value={value}
      onValueChange={(next) => {
        if (next !== null) onValueChange(next)
      }}
      items={items}
      disabled={disabled}
    >
      <BaseSelect.Trigger
        aria-label={ariaLabel}
        className={cn(
          'flex min-h-11 items-center justify-between gap-3 rounded-[12px] border border-input-border bg-input px-3.5 text-[13px] text-text-strong outline-none',
          'transition-[border-color,background-color] data-[popup-open]:border-primary data-[popup-open]:bg-card',
          'disabled:cursor-not-allowed disabled:opacity-50',
          className,
        )}
      >
        <BaseSelect.Value className="min-w-0 flex-1 truncate data-[placeholder]:text-text-faint" placeholder={placeholder} />
        <BaseSelect.Icon>
          <ChevronDownIcon className="h-5 w-5 text-text-soft transition-transform data-[popup-open]:rotate-180" aria-hidden="true" />
        </BaseSelect.Icon>
      </BaseSelect.Trigger>
      <BaseSelect.Portal>
        <BaseSelect.Positioner align="start" sideOffset={6} alignItemWithTrigger={false} className="z-[82] outline-none">
          <BaseSelect.Popup className="zds-menu-popup min-w-[var(--anchor-width)] overflow-hidden outline-none">
            <BaseSelect.List className="max-h-[min(320px,var(--available-height))] overflow-y-auto p-1.5">
              {items.map((item) => (
                <BaseSelect.Item
                  key={item.value}
                  value={item.value}
                  className="grid cursor-pointer grid-cols-[20px_minmax(0,1fr)] items-center gap-2 rounded-[10px] px-2.5 py-2 text-[13px] text-text-mid outline-none data-[highlighted]:bg-surface-container-low data-[selected]:font-medium data-[selected]:text-primary"
                >
                  <BaseSelect.ItemIndicator>
                    <CheckIcon className="h-4 w-4" aria-hidden="true" />
                  </BaseSelect.ItemIndicator>
                  <BaseSelect.ItemText className="truncate">{item.label}</BaseSelect.ItemText>
                </BaseSelect.Item>
              ))}
            </BaseSelect.List>
          </BaseSelect.Popup>
        </BaseSelect.Positioner>
      </BaseSelect.Portal>
    </BaseSelect.Root>
    </CSPProvider>
  )
}
