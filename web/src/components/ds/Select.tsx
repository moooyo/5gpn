import { Select as BaseSelect } from '@base-ui/react/select'
import { CSPProvider } from '@base-ui/react/csp-provider'
import { CheckIcon, ChevronDownIcon } from '../icons'
import { cn } from '../../lib/cn'

export interface SelectItem {
  value: string
  label: string
  /** Optional trailing count used by compact filter menus. Zero is hidden. */
  count?: number
}

export interface SelectProps {
  value: string
  onValueChange: (value: string) => void
  items: SelectItem[]
  placeholder?: string
  className?: string
  disabled?: boolean
  ariaLabel?: string
  /** Compact log-filter treatment with a trailing count and no check column. */
  variant?: 'default' | 'compact-count'
}

export function Select({ value, onValueChange, items, placeholder, className, disabled, ariaLabel, variant = 'default' }: SelectProps) {
  const compact = variant === 'compact-count'
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
          'flex items-center justify-between rounded-ctl border border-input-border bg-input text-text-strong outline-none',
          compact ? 'h-row min-w-[176px] gap-2 px-3.5 pr-2 text-label font-medium' : 'min-h-field gap-3 px-3.5 text-body',
          'transition-[border-color,background-color] data-[popup-open]:border-primary data-[popup-open]:bg-card',
          'disabled:cursor-not-allowed disabled:opacity-50',
          className,
        )}
      >
        <BaseSelect.Value className="min-w-0 flex-1 truncate data-[placeholder]:text-text-faint" placeholder={placeholder} />
        <BaseSelect.Icon>
          <ChevronDownIcon className={cn(compact ? 'h-[19px] w-[19px]' : 'h-5 w-5', 'text-text-soft transition-transform data-[popup-open]:rotate-180')} aria-hidden="true" />
        </BaseSelect.Icon>
      </BaseSelect.Trigger>
      <BaseSelect.Portal>
        <BaseSelect.Positioner align="start" sideOffset={6} alignItemWithTrigger={false} className="z-[82] outline-none">
          <BaseSelect.Popup className={cn('zds-menu-popup min-w-[var(--anchor-width)] overflow-hidden outline-none', compact && 'min-w-[216px]')}>
            <BaseSelect.List className="max-h-[min(320px,var(--available-height))] overflow-y-auto p-1.5">
              {items.map((item) => (
                <BaseSelect.Item
                  key={item.value}
                  value={item.value}
                  className={cn(
                    'grid cursor-pointer items-center rounded-ctl text-text-mid outline-none data-[highlighted]:bg-surface-container-low data-[selected]:font-medium data-[selected]:text-primary',
                    compact
                      ? 'grid-cols-[minmax(0,1fr)_auto] gap-3 px-3 py-2 text-body data-[selected]:bg-surface-container-low'
                      : 'grid-cols-[20px_minmax(0,1fr)] gap-2 px-2.5 py-2 text-body',
                  )}
                >
                  {!compact ? <BaseSelect.ItemIndicator>
                    <CheckIcon className="h-4 w-4" aria-hidden="true" />
                  </BaseSelect.ItemIndicator> : null}
                  <BaseSelect.ItemText className="truncate">{item.label}</BaseSelect.ItemText>
                  {compact && item.count ? <span className="font-mono text-meta font-normal text-text-faint">{item.count}</span> : null}
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
