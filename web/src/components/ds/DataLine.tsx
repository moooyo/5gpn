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
    <div className={cn('flex items-center justify-between gap-4 border-b border-divider py-3.5 last:border-b-0', className)}>
      <div className="flex flex-col gap-0.5">
        <span className="text-[13px] font-medium text-text-strong">{label}</span>
        {sub !== undefined ? <span className="text-[11.5px] leading-5 text-text-faint">{sub}</span> : null}
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
    <div className={cn('text-[11px] font-medium tracking-[.06em] text-text-faint', className)}>{children}</div>
  )
}
