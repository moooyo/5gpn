import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { CheckCircle2, Info, XCircle } from 'lucide-react'
import { cn } from '../../lib/cn'

export type ToastKind = 'success' | 'error' | 'info'

interface ToastItem {
  id: number
  kind: ToastKind
  message: string
}

const DISMISS_MS = 3500

let items: ToastItem[] = []
const listeners = new Set<(items: ToastItem[]) => void>()

function emit() {
  const snapshot = items
  listeners.forEach((listener) => listener(snapshot))
}

function subscribe(listener: (items: ToastItem[]) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function dismiss(id: number) {
  items = items.filter((item) => item.id !== id)
  emit()
}

function push(kind: ToastKind, message: string) {
  const id = Date.now() + Math.random()
  items = [...items, { id, kind, message }]
  emit()
  setTimeout(() => dismiss(id), DISMISS_MS)
}

export const toast = {
  success: (message: string) => push('success', message),
  error: (message: string) => push('error', message),
  info: (message: string) => push('info', message),
}

const KIND_ICON: Record<ToastKind, typeof CheckCircle2> = {
  success: CheckCircle2,
  error: XCircle,
  info: Info,
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
    <div className="fixed bottom-4 right-4 z-[60] flex flex-col gap-2 items-end">
      {current.map((item) => {
        const Icon = KIND_ICON[item.kind]
        return (
          <div
            key={item.id}
            className={cn(
              'ds-toast-in flex min-w-[220px] max-w-[360px] items-center gap-2 rounded-[10px] border border-border bg-card px-3.5 py-2.5 text-[12.5px] shadow-pop',
            )}
          >
            <Icon className={cn('h-4 w-4 shrink-0', KIND_COLOR[item.kind])} />
            <span className="text-text-strong">{item.message}</span>
          </div>
        )
      })}
    </div>,
    document.body,
  )
}
