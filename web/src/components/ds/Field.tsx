import type { InputHTMLAttributes, LabelHTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type LabelProps = LabelHTMLAttributes<HTMLLabelElement>

export function Label({ className, children, ...props }: LabelProps) {
  return (
    <label className={cn('text-label font-medium text-text-mid', className)} {...props}>
      {children}
    </label>
  )
}

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  mono?: boolean
}

export function Input({ mono, className, ...props }: InputProps) {
  return (
    <input
      className={cn(
        'input h-field w-full rounded-ctl border border-input-border bg-input px-3.5 text-body text-text-strong shadow-none outline-none',
        'placeholder:text-text-faint focus:border-primary focus:bg-card focus:ring-1 focus:ring-primary',
        'disabled:cursor-not-allowed disabled:opacity-50',
        mono && 'font-mono',
        className,
      )}
      {...props}
    />
  )
}

export interface FieldProps {
  label?: ReactNode
  error?: ReactNode
  supportingText?: ReactNode
  children: ReactNode
  className?: string
}

export function Field({ label, error, supportingText, children, className }: FieldProps) {
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      {label !== undefined ? <Label>{label}</Label> : null}
      {children}
      {error !== undefined ? <span className="text-label text-red">{error}</span> : null}
      {error === undefined && supportingText !== undefined ? <span className="text-label text-text-faint">{supportingText}</span> : null}
    </div>
  )
}
