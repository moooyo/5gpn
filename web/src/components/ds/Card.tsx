import type { HTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type CardProps = HTMLAttributes<HTMLDivElement>

export function Card({ className, ...props }: CardProps) {
  return <div className={cn('bg-card border border-border rounded-card shadow-card', className)} {...props} />
}

export interface CardHeaderProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title?: ReactNode
}

export function CardHeader({ title, children, className, ...props }: CardHeaderProps) {
  return (
    <div
      className={cn('flex items-center justify-between gap-2 border-b border-divider px-4 py-3', className)}
      {...props}
    >
      {title !== undefined ? <div className="text-[13px] font-bold text-text-strong">{title}</div> : null}
      {children}
    </div>
  )
}

export type CardBodyProps = HTMLAttributes<HTMLDivElement>

export function CardBody({ className, ...props }: CardBodyProps) {
  return <div className={cn('p-4', className)} {...props} />
}
