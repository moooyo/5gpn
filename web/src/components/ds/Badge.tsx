import type { CSSProperties, HTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type BadgeTone = 'green' | 'blue' | 'red' | 'amber' | 'cyan' | 'indigo' | 'neutral'

const toneClass: Record<BadgeTone, string> = {
  green: 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]',
  blue: 'bg-primary-container text-on-primary-container',
  red: 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]',
  amber: 'bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]',
  cyan: 'bg-secondary-container text-on-secondary-container',
  indigo: 'bg-tertiary-container text-tertiary',
  neutral: 'bg-surface-container text-text-soft',
}

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: BadgeTone
}

export function Badge({ tone = 'neutral', className, children, ...props }: BadgeProps) {
  return (
    <span className={cn('badge h-auto rounded-pill border-0 px-3 py-1 text-meta font-medium', toneClass[tone], className)} {...props}>
      {children}
    </span>
  )
}

export interface ChipProps {
  label?: ReactNode
  value: ReactNode
  className?: string
}

export function Chip({ label, value, className }: ChipProps) {
  return (
    <span className={cn('inline-flex items-center gap-1 rounded-chip bg-surface-container px-2.5 py-1 text-meta text-text-mid', className)}>
      {label !== undefined ? <span className="font-mono text-text-faint">{label}</span> : null}
      <span>{value}</span>
    </span>
  )
}

export interface StatusDotProps {
  color: string
  pulse?: boolean
  /** Square swatch instead of a dot. Used where the colour has to be read as
   *  a legend key rather than as a live indicator — a 8px round dot at the
   *  head of a mobile log row is too small to name a hue against. */
  square?: boolean
  className?: string
}

export function StatusDot({ color, pulse, square, className }: StatusDotProps) {
  return (
    <span
      className={cn(
        'inline-block',
        square ? 'zds-swatch' : 'h-2 w-2 rounded-pill',
        pulse && 'ds-pulse',
        className,
      )}
      style={{ background: color } satisfies CSSProperties}
    />
  )
}
