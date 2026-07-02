import { createContext, useCallback, useContext, useState, type ReactNode } from 'react'

export type ToastKind = 'ok' | 'err'

interface Toast {
  id: number
  kind: ToastKind
  message: string
}

interface ToastCtx {
  push: (kind: ToastKind, message: string) => void
}

const Ctx = createContext<ToastCtx | null>(null)

let nextId = 1

/** Provides a small transient toast queue (top-right), auto-dismissing. */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])

  const push = useCallback((kind: ToastKind, message: string) => {
    const id = nextId++
    setToasts((t) => [...t, { id, kind, message }])
    window.setTimeout(() => {
      setToasts((t) => t.filter((x) => x.id !== id))
    }, 4200)
  }, [])

  const dismiss = (id: number) => setToasts((t) => t.filter((x) => x.id !== id))

  return (
    <Ctx.Provider value={{ push }}>
      {children}
      <div className="pointer-events-none fixed right-4 top-4 z-50 flex w-80 max-w-[calc(100vw-2rem)] flex-col gap-2">
        {toasts.map((t) => (
          <button
            key={t.id}
            onClick={() => dismiss(t.id)}
            className="pointer-events-auto panel panel-pad text-left"
            style={{
              padding: '12px 14px',
              borderLeft: `3px solid ${t.kind === 'ok' ? 'var(--v-direct)' : 'var(--danger)'}`,
            }}
          >
            <div
              className="eyebrow mb-1"
              style={{ color: t.kind === 'ok' ? 'var(--v-direct)' : 'var(--danger)' }}
            >
              {t.kind === 'ok' ? 'Done' : 'Error'}
            </div>
            <div className="font-mono text-xs" style={{ color: 'var(--text)', wordBreak: 'break-word' }}>
              {t.message}
            </div>
          </button>
        ))}
      </div>
    </Ctx.Provider>
  )
}

export function useToast(): ToastCtx {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useToast must be used within ToastProvider')
  return ctx
}
