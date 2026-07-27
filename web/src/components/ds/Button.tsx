import type { ButtonHTMLAttributes } from 'react'
import { cn } from '../../lib/cn'

export type ButtonVariant = 'primary' | 'tonal' | 'secondary' | 'elevated' | 'ghost' | 'danger'
export type ButtonSize = 'sm' | 'md'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
}

const variantClass: Record<ButtonVariant, string> = {
  primary: 'border-transparent bg-primary text-[var(--md-sys-color-on-primary)] shadow-none',
  tonal: 'border-transparent bg-primary-container text-on-primary-container shadow-none',
  secondary: 'border-outline bg-transparent text-primary shadow-none',
  elevated: 'border-transparent bg-surface-container-low text-primary shadow-[var(--md-sys-elevation-1)]',
  ghost: 'border-transparent bg-transparent text-primary shadow-none',
  danger: 'border-transparent bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)] shadow-none',
}

/**
 * `sm` is a DESKTOP density. On a phone every tappable thing is 44px, so the
 * small step starts at `h-field` and only shrinks from `sm` up — a 32px target
 * under a finger is the rule this console broke most often.
 */
const sizeClass: Record<ButtonSize, string> = {
  sm: 'h-field px-3.5 text-label sm:h-chip',
  md: 'h-field px-5 text-body sm:h-ctl',
}

export function Button({ variant = 'primary', size = 'md', className, type = 'button', ...props }: ButtonProps) {
  return (
    <button
      type={type}
      className={cn(
        'btn zds-state-layer min-h-0 rounded-pill font-semibold normal-case tracking-[.01em] transition-[box-shadow,background-color,color] duration-150',
        'disabled:pointer-events-none disabled:opacity-[.38]',
        variantClass[variant],
        sizeClass[size],
        className,
      )}
      {...props}
    />
  )
}
