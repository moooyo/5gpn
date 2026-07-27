import { Tabs as BaseTabs } from '@base-ui/react/tabs'
import { cn } from '../../lib/cn'

export interface TabItem {
  value: string
  label: string
}

export interface TabsProps {
  value: string
  onValueChange: (value: string) => void
  items: TabItem[]
  className?: string
}

export function Tabs({ value, onValueChange, items, className }: TabsProps) {
  return (
    <BaseTabs.Root value={value} onValueChange={(next) => onValueChange(String(next))}>
      <BaseTabs.List className={cn('flex gap-1 rounded-pill bg-surface-container p-1', className)}>
        {items.map((item) => (
          <BaseTabs.Tab
            key={item.value}
            value={item.value}
            className={(state) => cn(
              'zds-state-layer min-h-field cursor-pointer rounded-pill px-4 text-body font-medium outline-none transition-colors md:min-h-row',
              state.active ? 'bg-secondary-container text-on-secondary-container' : 'text-text-soft',
            )}
          >
            {item.label}
          </BaseTabs.Tab>
        ))}
      </BaseTabs.List>
    </BaseTabs.Root>
  )
}
