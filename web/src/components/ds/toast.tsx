import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { CheckCircleIcon, ErrorIcon, InfoIcon } from '../icons'
import { cn } from '../../lib/cn'

export type ToastKind = 'success' | 'error' | 'info'

/** A single inline action rendered at the trailing edge of a toast. Reserved
 *  for undoing something the operator just did — a destructive-looking action
 *  whose state is cheap to restore (the plugin-log clear watermark, say) is
 *  far better served by an undo than by a confirmation dialog in front of it. */
export interface ToastAction {
  label: string
  onClick: () => void
}

export interface ToastOptions {
  action?: ToastAction
  /** Overrides the default dismiss delay. An undo needs longer than a plain
   *  acknowledgement — the operator has to read it, decide, and reach it. */
  durationMs?: number
}

interface ToastItem {
  id: number
  kind: ToastKind
  message: string
  action?: ToastAction
}

const DISMISS_MS = 3500
/** Undo toasts default to this instead: long enough to notice and act on. */
export const TOAST_UNDO_MS = 8000
let items: ToastItem[] = []
const listeners = new Set<(next: ToastItem[]) => void>()

function emit() {
  listeners.forEach((listener) => listener(items))
}

function subscribe(listener: (next: ToastItem[]) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function dismiss(id: number) {
  items = items.filter((item) => item.id !== id)
  emit()
}

function push(kind: ToastKind, message: string, options?: ToastOptions) {
  const id = Date.now() + Math.random()
  items = [...items, { id, kind, message, action: options?.action }].slice(-4)
  emit()
  setTimeout(() => dismiss(id), options?.durationMs ?? (options?.action ? TOAST_UNDO_MS : DISMISS_MS))
}

export const toast = {
  success: (message: string, options?: ToastOptions) => push('success', message, options),
  error: (message: string, options?: ToastOptions) => push('error', message, options),
  info: (message: string, options?: ToastOptions) => push('info', message, options),
}

const KIND_ICON = {
  success: CheckCircleIcon,
  error: ErrorIcon,
  info: InfoIcon,
}

const KIND_COLOR: Record<ToastKind, string> = {
  success: 'text-green',
  error: 'text-red',
  info: 'text-primary',
}

export function Toaster() {
  const [current, setCurrent] = useState<ToastItem[]>(() => items)
  useEffect(() => subscribe(setCurrent), [])

  return createPortal(
    <div
      className="pointer-events-none fixed bottom-4 left-4 right-4 z-[90] flex flex-col items-end gap-2 sm:left-auto sm:max-w-[420px]"
      aria-live="polite"
      aria-atomic="false"
    >
      {current.map((item) => {
        const Icon = KIND_ICON[item.kind]
        return (
          <div
            key={item.id}
            role={item.kind === 'error' ? 'alert' : 'status'}
            className="ds-toast-in pointer-events-auto flex w-full items-center gap-3 rounded-ctl bg-[var(--md-sys-color-inverse-surface)] px-4 py-3 text-body text-[var(--md-sys-color-inverse-on-surface)] shadow-pop sm:min-w-[280px]"
          >
            <Icon className={cn('h-5 w-5 shrink-0', KIND_COLOR[item.kind])} aria-hidden="true" />
            <span className="min-w-0 flex-1">{item.message}</span>
            {item.action ? (
              <button
                type="button"
                onClick={() => {
                  item.action?.onClick()
                  dismiss(item.id)
                }}
                className="zds-state-layer -my-1 -mr-2 h-field shrink-0 rounded-pill px-3 text-body font-semibold md:h-ctl text-[var(--md-sys-color-primary-fixed-dim)]"
              >
                {item.action.label}
              </button>
            ) : null}
          </div>
        )
      })}
    </div>,
    document.body,
  )
}
