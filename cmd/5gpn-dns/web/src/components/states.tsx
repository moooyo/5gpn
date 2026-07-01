import type { ReactNode } from 'react'

/** An empty-state invitation (copy is a prompt to act, not a dead end). */
export function EmptyState({ title, hint }: { title: string; hint?: ReactNode }) {
  return (
    <div
      className="rounded-panel border border-dashed px-5 py-8 text-center"
      style={{ borderColor: 'var(--border)' }}
    >
      <div className="font-display text-sm font-semibold" style={{ color: 'var(--text)' }}>
        {title}
      </div>
      {hint && (
        <div className="mx-auto mt-1.5 max-w-md text-xs" style={{ color: 'var(--muted)' }}>
          {hint}
        </div>
      )}
    </div>
  )
}

/** A small spinner glyph (the accent ring). Honors reduced-motion via CSS. */
export function Spinner({ size = 16 }: { size?: number }) {
  return (
    <span
      aria-hidden
      style={{
        display: 'inline-block',
        width: size,
        height: size,
        border: '2px solid var(--border)',
        borderTopColor: 'var(--accent)',
        borderRadius: '50%',
        animation: 'spin 0.7s linear infinite',
      }}
    />
  )
}

/** A centered loading state for a whole view. */
export function Loading({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="flex items-center gap-3 py-10" style={{ color: 'var(--muted)' }}>
      <Spinner />
      <span className="font-mono text-sm">{label}</span>
    </div>
  )
}

/** An inline error notice: what happened, on a rose-tinted strip. */
export function ErrorNotice({ message, children }: { message: string; children?: ReactNode }) {
  return (
    <div
      className="rounded-panel px-4 py-3 text-xs"
      style={{
        border: '1px solid var(--danger)',
        background: 'color-mix(in srgb, var(--danger) 10%, transparent)',
        color: 'var(--text)',
      }}
      role="alert"
    >
      <span className="font-mono">{message}</span>
      {children}
    </div>
  )
}
