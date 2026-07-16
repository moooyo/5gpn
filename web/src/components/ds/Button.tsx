import type { ButtonHTMLAttributes } from 'react'
import { cn } from '../../lib/cn'

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'
export type ButtonSize = 'sm' | 'md'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
}

const variantClass: Record<ButtonVariant, string> = {
  primary:
    'bg-[linear-gradient(135deg,var(--color-primary-2),var(--color-primary))] text-white shadow-[0_8px_18px_-8px_rgba(37,99,235,.6)] font-bold border border-transparent',
  secondary: 'bg-card border border-input-border text-text-mid font-semibold',
  ghost: 'bg-transparent border border-transparent text-text-soft font-semibold hover:bg-primary/10',
  danger: 'bg-transparent text-red border border-red/30 font-semibold hover:bg-red/10',
}

const sizeClass: Record<ButtonSize, string> = {
  sm: 'text-[11.5px] px-3 py-1.5',
  md: 'text-[13px] px-4 py-2',
}

export function Button({ variant = 'primary', size = 'md', className, ...props }: ButtonProps) {
  return (
    <button
      className={cn(
        'inline-flex items-center justify-center gap-1.5 rounded-[10px] transition-colors',
        'disabled:opacity-50 disabled:cursor-not-allowed',
        variantClass[variant],
        sizeClass[size],
        className,
      )}
      {...props}
    />
  )
}
