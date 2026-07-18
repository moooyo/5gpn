import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { CheckCircleIcon, ErrorIcon, InfoIcon } from '../icons'
import { cn } from '../../lib/cn'

export type ToastKind = 'success' | 'error' | 'info'

interface ToastItem {
  id: number
  kind: ToastKind
  message: string
}

const DISMISS_MS = 3500
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

function push(kind: ToastKind, message: string) {
  const id = Date.now() + Math.random()
  items = [...items, { id, kind, message }].slice(-4)
  emit()
  setTimeout(() => dismiss(id), DISMISS_MS)
}

export const toast = {
  success: (message: string) => push('success', message),
  error: (message: string) => push('error', message),
  info: (message: string) => push('info', message),
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
            className="ds-toast-in pointer-events-auto flex w-full items-center gap-3 rounded-[12px] bg-[var(--md-sys-color-inverse-surface)] px-4 py-3 text-[13px] text-[var(--md-sys-color-inverse-on-surface)] shadow-pop sm:min-w-[280px]"
          >
            <Icon className={cn('h-5 w-5 shrink-0', KIND_COLOR[item.kind])} aria-hidden="true" />
            <span className="min-w-0 flex-1">{item.message}</span>
          </div>
        )
      })}
    </div>,
    document.body,
  )
}
