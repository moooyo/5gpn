import type { ReactElement, ReactNode } from 'react'
import { Popover } from '@base-ui/react/popover'
import { cn } from '../../lib/cn'

export interface DropdownMenuProps {
  trigger: ReactNode
  children: ReactNode
  align?: 'start' | 'center' | 'end'
  className?: string
}

/**
 * Profile-style popup that can contain form controls and tablists. A Popover
 * is used instead of role=menu because ARIA menus may only own menu items.
 */
export function DropdownMenu({ trigger, children, align = 'end', className }: DropdownMenuProps) {
  return (
    <Popover.Root>
      <Popover.Trigger render={trigger as ReactElement} />
      <Popover.Portal>
        <Popover.Positioner align={align} sideOffset={8} className="z-[80] outline-none">
          <Popover.Popup className={cn('zds-menu-popup w-[264px] p-2 outline-none', className)}>{children}</Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  )
}

export interface DropdownItemProps {
  onSelect?: (event: Event) => void
  danger?: boolean
  children: ReactNode
}

export function DropdownItem({ onSelect, danger, children }: DropdownItemProps) {
  return (
    <button
      type="button"
      onClick={(event) => onSelect?.(event.nativeEvent)}
      className={cn(
        'zds-state-layer flex w-full cursor-pointer items-center gap-3 rounded-[10px] px-3 py-2.5 text-left text-[13px] font-medium outline-none',
        danger ? 'text-red' : 'text-text-mid',
      )}
    >
      {children}
    </button>
  )
}

export function DropdownSeparator() {
  return <div role="separator" className="my-2 h-px bg-border" />
}
