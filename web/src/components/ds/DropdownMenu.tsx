import type { ReactNode } from 'react'
import * as DropdownMenuPrimitive from '@radix-ui/react-dropdown-menu'
import { cn } from '../../lib/cn'

export interface DropdownMenuProps {
  trigger: ReactNode
  children: ReactNode
  align?: 'start' | 'center' | 'end'
  className?: string
}

export function DropdownMenu({ trigger, children, align = 'end', className }: DropdownMenuProps) {
  return (
    <DropdownMenuPrimitive.Root>
      <DropdownMenuPrimitive.Trigger asChild>{trigger}</DropdownMenuPrimitive.Trigger>
      <DropdownMenuPrimitive.Portal>
        <DropdownMenuPrimitive.Content
          align={align}
          sideOffset={6}
          className={cn(
            'ds-pop-in w-[240px] rounded-[13px] border border-border bg-card p-2 shadow-pop',
            className,
          )}
        >
          {children}
        </DropdownMenuPrimitive.Content>
      </DropdownMenuPrimitive.Portal>
    </DropdownMenuPrimitive.Root>
  )
}

export interface DropdownItemProps {
  onSelect?: (event: Event) => void
  danger?: boolean
  children: ReactNode
}

export function DropdownItem({ onSelect, danger, children }: DropdownItemProps) {
  return (
    <DropdownMenuPrimitive.Item
      onSelect={onSelect}
      className={cn(
        'flex cursor-pointer items-center gap-2.5 rounded-[8px] px-2.5 py-2 text-[12.5px] font-semibold outline-none data-[highlighted]:bg-input',
        danger && 'text-red data-[highlighted]:bg-[#fef2f2]',
      )}
    >
      {children}
    </DropdownMenuPrimitive.Item>
  )
}

export function DropdownSeparator() {
  return <DropdownMenuPrimitive.Separator className="my-2 h-px bg-divider" />
}
