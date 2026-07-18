import type { HTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type CardVariant = 'surface' | 'tonal' | 'hero'

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  variant?: CardVariant
}

const variantClass: Record<CardVariant, string> = {
  surface: 'zds-card',
  tonal: 'zds-card zds-card-tonal',
  hero: 'zds-card zds-card-hero',
}

export function Card({ variant = 'surface', className, ...props }: CardProps) {
  return <div className={cn('card', variantClass[variant], className)} {...props} />
}

export interface CardHeaderProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title?: ReactNode
}

export function CardHeader({ title, children, className, ...props }: CardHeaderProps) {
  return (
    <div className={cn('flex items-center justify-between gap-3 border-b border-border px-5 py-4', className)} {...props}>
      {title !== undefined ? <div className="text-[15px] font-semibold text-text-strong">{title}</div> : null}
      {children}
    </div>
  )
}

export type CardBodyProps = HTMLAttributes<HTMLDivElement>

export function CardBody({ className, ...props }: CardBodyProps) {
  return <div className={cn('p-5', className)} {...props} />
}
