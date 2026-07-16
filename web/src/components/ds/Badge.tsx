import type { CSSProperties, HTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type BadgeTone = 'green' | 'blue' | 'red' | 'amber' | 'cyan' | 'indigo' | 'neutral'

// Tint classes map 1:1 to the @theme color tokens in styles/theme.css so the
// rendered rgba matches the handoff exactly (green=--color-green, blue=--color-primary,
// amber=--color-amber-2, cyan=--color-cyan-3, indigo=--color-indigo, neutral=divider/text-soft).
const toneClass: Record<BadgeTone, string> = {
  green: 'bg-green/10 text-green',
  blue: 'bg-primary/10 text-primary',
  red: 'bg-red/10 text-red',
  amber: 'bg-amber-2/12 text-amber-2',
  cyan: 'bg-cyan-3/12 text-cyan-3',
  indigo: 'bg-indigo/12 text-indigo',
  neutral: 'bg-divider text-text-soft',
}

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: BadgeTone
}

export function Badge({ tone = 'neutral', className, children, ...props }: BadgeProps) {
  return (
    <span
      className={cn('inline-flex items-center rounded-[7px] px-2.5 py-1 text-[11px] font-semibold', toneClass[tone], className)}
      {...props}
    >
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
    <span
      className={cn(
        'inline-flex items-center gap-1 rounded-[6px] border border-border bg-input px-2 py-0.5 text-[10.5px] text-text-mid',
        className,
      )}
    >
      {label !== undefined ? <span className="font-mono text-text-faint">{label}</span> : null}
      <span>{value}</span>
    </span>
  )
}

export interface StatusDotProps {
  color: string
  pulse?: boolean
  className?: string
}

// `color` is a runtime value (per-row health status etc.) so it is applied via
// inline style, never a runtime-injected <style> tag. The pulse animation itself
// is a static, build-time class (`ds-pulse`) backed by the `@keyframes pulse`
// declared in styles/index.css's base layer.
export function StatusDot({ color, pulse, className }: StatusDotProps) {
  return (
    <span
      className={cn('inline-block h-[7px] w-[7px] rounded-full', pulse && 'ds-pulse', className)}
      style={{ background: color } satisfies CSSProperties}
    />
  )
}
