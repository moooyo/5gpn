import type { ReactNode } from 'react'
import * as DialogPrimitive from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import { cn } from '../../lib/cn'

export interface ModalProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title?: ReactNode
  children: ReactNode
  footer?: ReactNode
  className?: string
}

export function Modal({ open, onOpenChange, title, children, footer, className }: ModalProps) {
  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 bg-[rgba(16,24,40,.35)]" />
        <DialogPrimitive.Content
          aria-describedby={undefined}
          className={cn(
            'fixed left-1/2 top-1/2 w-[min(92vw,480px)] -translate-x-1/2 -translate-y-1/2 rounded-card border border-border bg-card p-5 shadow-pop',
            className,
          )}
        >
          <div className="mb-3 flex items-center justify-between">
            {title !== undefined ? (
              <DialogPrimitive.Title className="text-[15px] font-bold text-text-strong">{title}</DialogPrimitive.Title>
            ) : (
              <DialogPrimitive.Title className="sr-only">Dialog</DialogPrimitive.Title>
            )}
            <DialogPrimitive.Close aria-label="Close" className="cursor-pointer text-text-soft outline-none">
              <X className="h-4 w-4" />
            </DialogPrimitive.Close>
          </div>
          {children}
          {footer !== undefined ? <div className="mt-4 flex items-center justify-end gap-2">{footer}</div> : null}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  )
}
