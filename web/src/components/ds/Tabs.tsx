import * as TabsPrimitive from '@radix-ui/react-tabs'
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

// Triggers only — the tab panel content is rendered by the caller based on `value`.
export function Tabs({ value, onValueChange, items, className }: TabsProps) {
  return (
    <TabsPrimitive.Root value={value} onValueChange={onValueChange}>
      <TabsPrimitive.List className={cn('flex', className)}>
        {items.map((item) => {
          const active = item.value === value
          return (
            <TabsPrimitive.Trigger
              key={item.value}
              value={item.value}
              className={cn(
                // font-weight stays constant across states: a bold-vs-semibold
                // swap on activation changes the label's width and makes the
                // tab row jitter. The active tab is distinguished by colour +
                // the primary underline, not by getting heavier.
                'cursor-pointer border-b-[2.5px] px-4 pb-3.5 pt-3 text-[13px] font-semibold outline-none',
                active ? 'border-primary text-primary' : 'border-transparent text-text-soft',
              )}
            >
              {item.label}
            </TabsPrimitive.Trigger>
          )
        })}
      </TabsPrimitive.List>
    </TabsPrimitive.Root>
  )
}
