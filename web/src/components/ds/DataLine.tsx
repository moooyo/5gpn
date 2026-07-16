import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

export interface DataLineProps {
  label: ReactNode
  sub?: ReactNode
  children?: ReactNode
  className?: string
}

export function DataLine({ label, sub, children, className }: DataLineProps) {
  return (
    <div className={cn('flex items-center justify-between gap-3 border-b border-divider py-3', className)}>
      <div className="flex flex-col gap-0.5">
        <span className="text-[12.5px] font-semibold text-text-mid">{label}</span>
        {sub !== undefined ? <span className="text-[10.5px] text-text-faint">{sub}</span> : null}
      </div>
      {children !== undefined ? <div className="flex items-center">{children}</div> : null}
    </div>
  )
}

export interface SectionLabelProps {
  children: ReactNode
  className?: string
}

export function SectionLabel({ children, className }: SectionLabelProps) {
  return (
    <div className={cn('text-[10px] font-semibold uppercase tracking-wide text-text-faint', className)}>{children}</div>
  )
}
