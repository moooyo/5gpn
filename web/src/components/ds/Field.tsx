import type { InputHTMLAttributes, LabelHTMLAttributes, ReactNode } from 'react'
import { cn } from '../../lib/cn'

export type LabelProps = LabelHTMLAttributes<HTMLLabelElement>

export function Label({ className, children, ...props }: LabelProps) {
  return (
    <label className={cn('text-[11px] font-semibold text-text-mid', className)} {...props}>
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
        'rounded-[10px] border border-input-border bg-input px-3 py-2.5 text-[13px] text-text-strong outline-none',
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
  children: ReactNode
  className?: string
}

export function Field({ label, error, children, className }: FieldProps) {
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      {label !== undefined ? <Label>{label}</Label> : null}
      {children}
      {error !== undefined ? <span className="text-[11px] text-red">{error}</span> : null}
    </div>
  )
}
