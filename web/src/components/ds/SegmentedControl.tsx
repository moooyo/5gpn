import { Tabs } from '@base-ui/react/tabs'
import { cn } from '../../lib/cn'

export interface SegmentedOption {
  value: string
  label: string
  swatch?: string
}

export interface SegmentedControlProps {
  value: string
  onChange: (value: string) => void
  options: SegmentedOption[]
  className?: string
  ariaLabel?: string
}

export function SegmentedControl({ value, onChange, options, className, ariaLabel }: SegmentedControlProps) {
  return (
    <Tabs.Root value={value} onValueChange={(next) => onChange(String(next))}>
      <Tabs.List
        aria-label={ariaLabel}
        className={cn('grid min-w-0 grid-cols-2 gap-1 rounded-[12px] bg-surface-container p-1', className)}
      >
        {options.map((option) => (
          <Tabs.Tab
            key={option.value}
            value={option.value}
            className={(state) => cn(
              'zds-state-layer flex min-h-11 min-w-0 flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-[9px] px-2 text-[11.5px] font-medium outline-none transition-colors sm:min-h-8',
              state.active ? 'bg-card text-primary shadow-[var(--md-sys-elevation-1)]' : 'text-text-faint',
            )}
          >
            {option.swatch ? <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: option.swatch }} /> : null}
            <span className="truncate">{option.label}</span>
          </Tabs.Tab>
        ))}
      </Tabs.List>
    </Tabs.Root>
  )
}
