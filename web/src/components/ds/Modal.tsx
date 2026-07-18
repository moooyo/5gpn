import { useEffect, type ReactNode } from 'react'
import { Dialog } from '@base-ui/react/dialog'
import { CloseIcon } from '../icons'
import { cn } from '../../lib/cn'

export interface ModalProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title?: ReactNode
  descriptionId?: string
  children: ReactNode
  footer?: ReactNode
  className?: string
}

export function Modal({ open, onOpenChange, title, descriptionId, children, footer, className }: ModalProps) {
  useEffect(() => {
    if (!open) return
    document.body.classList.add('ds-scroll-locked')
    return () => document.body.classList.remove('ds-scroll-locked')
  }, [open])

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="zds-dialog-backdrop" />
        <Dialog.Popup aria-describedby={descriptionId} className={cn('zds-dialog-popup p-6', className)}>
          <div className="mb-4 flex items-start justify-between gap-4">
            {title !== undefined ? (
              <Dialog.Title className="text-[20px] font-medium leading-7 text-text-strong">{title}</Dialog.Title>
            ) : (
              <Dialog.Title className="sr-only">Dialog</Dialog.Title>
            )}
            <Dialog.Close
              aria-label="Close"
              className="zds-state-layer -mr-2 -mt-2 grid h-10 w-10 shrink-0 cursor-pointer place-items-center rounded-full text-text-soft"
            >
              <CloseIcon className="h-5 w-5" aria-hidden="true" />
            </Dialog.Close>
          </div>
          {children}
          {footer !== undefined ? <div className="mt-6 flex flex-wrap items-center justify-end gap-2">{footer}</div> : null}
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
