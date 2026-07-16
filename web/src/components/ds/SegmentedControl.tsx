import { cn } from '../../lib/cn'

export interface SegmentedOption {
  value: string
  label: string
}

export interface SegmentedControlProps {
  value: string
  onChange: (value: string) => void
  options: SegmentedOption[]
  className?: string
}

export function SegmentedControl({ value, onChange, options, className }: SegmentedControlProps) {
  return (
    <div className={cn('flex rounded-[9px] bg-input p-[3px]', className)} role="tablist">
      {options.map((opt) => {
        const active = opt.value === value
        return (
          <button
            key={opt.value}
            type="button"
            role="tab"
            aria-selected={active}
            onClick={() => onChange(opt.value)}
            className={cn(
              'flex-1 cursor-pointer rounded-[7px] py-1.5 text-center text-[11.5px] font-semibold transition-colors',
              active ? 'bg-card text-primary shadow-[0_1px_3px_rgba(16,24,40,.12)]' : 'text-text-faint',
            )}
          >
            {opt.label}
          </button>
        )
      })}
    </div>
  )
}
