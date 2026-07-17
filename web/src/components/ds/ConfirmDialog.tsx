import { useId, type ReactNode } from 'react'
import { Button } from './Button'
import { Modal } from './Modal'

export interface ConfirmDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: ReactNode
  /** Body copy — explain what will change, in the interface's voice. */
  description?: ReactNode
  confirmLabel: string
  cancelLabel: string
  /** Style the confirm button as a destructive action (red). */
  danger?: boolean
  onConfirm: () => void
}

/** A small yes/no confirmation over ds/Modal — the standard guard in front of
 *  a destructive, one-click action (e.g. removing a rule entry). Confirming
 *  runs `onConfirm` and closes; cancelling / Esc / overlay-click just closes. */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  cancelLabel,
  danger,
  onConfirm,
}: ConfirmDialogProps) {
  const descriptionId = useId()
  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={title}
      descriptionId={description !== undefined ? descriptionId : undefined}
      className="w-[min(92vw,400px)]"
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => onOpenChange(false)}>
            {cancelLabel}
          </Button>
          <Button
            type="button"
            size="sm"
            variant={danger ? 'danger' : 'primary'}
            onClick={() => {
              onConfirm()
              onOpenChange(false)
            }}
          >
            {confirmLabel}
          </Button>
        </>
      }
    >
      {description !== undefined ? (
        <p id={descriptionId} className="text-[13px] leading-relaxed text-text-soft">{description}</p>
      ) : null}
    </Modal>
  )
}
